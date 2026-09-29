defmodule Arbiter.Workflows.ReviewPatrolSupervisor do
  @moduledoc """
  DynamicSupervisor for `ReviewPatrol` processes — one per (workspace, repo)
  pair configured for GitHub merges. The reviewer-side counterpart of
  `PRPatrolSupervisor`, kept as a SEPARATE module and process registry
  (`Arbiter.Workflows.ReviewPatrolRegistry`) so the two patrols never share a
  registration namespace.

  Repo derivation, the single-repo vs multi-repo registry-key scheme, stale
  1↔N reconciliation, and boot/create-time auto-start all mirror
  `PRPatrolSupervisor` exactly — see that module for the full rationale. The
  only differences here are the process module (`ReviewPatrol`), the registry,
  and the poll-interval config key (`:review_patrol_interval_ms`).

  Both auto-start paths are gated by the same `:arbiter, :auto_start_refineries`
  flag PRPatrol uses — disabled in `test`, enabled everywhere else.

  Following a workspace config edit (bd-7feiul) also mirrors PRPatrolSupervisor:
  each patrol registers with its repo as the registry value, `reconcile/1` (run
  by `Arbiter.Tasks.Workspace.Changes.ReconcilePatrols` on a workspace `:update`
  / `:patch_config` that changes `config`) stops every patrol pinned to a repo
  the workspace no longer resolves to and re-runs the gated `start_patrol/2`,
  and `ensure_started/2` sweeps stale patrols the same way before starting.
  """

  require Logger

  alias Arbiter.{Mergers, Tasks.Workspace}
  alias Arbiter.Mergers.ForgeRepos
  alias Arbiter.ProcessTeardown
  alias Arbiter.Worker.ReviewAutomation
  alias Arbiter.Workflows.{PatrolRepoScope, ReviewPatrol}

  @registry Arbiter.Workflows.ReviewPatrolRegistry
  @forge_opts [log: "ReviewPatrolSupervisor"]

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start:
        {DynamicSupervisor, :start_link,
         [Keyword.merge([name: __MODULE__, strategy: :one_for_one], opts)]},
      type: :supervisor
    }
  end

  @doc """
  Start a ReviewPatrol for each repo configured in the workspace's GitHub merge
  config. Returns `:skip` when the adapter doesn't support `get/1` or when no
  repos can be derived from the workspace config.

  Single-repo workspaces start one patrol registered under `workspace_id`;
  multi-repo workspaces start one patrol per repo, registered under
  `"workspace_id:owner/repo"`. Idempotent: a duplicate start returns
  `{:error, {:already_started, pid}}`.
  """
  @spec start_patrol(Workspace.t(), keyword()) :: DynamicSupervisor.on_start_child() | :skip
  def start_patrol(%Workspace{} = workspace, opts \\ []) do
    repos = patrol_repos(workspace)
    do_start_patrol(workspace, resolve_adapter(workspace, repos), repos, opts)
  end

  defp do_start_patrol(workspace, adapter, repos, opts) do
    cond do
      not supported_adapter?(adapter) ->
        Logger.info(
          "ReviewPatrolSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "merge adapter #{inspect(adapter)} does not support get/1"
        )

        :skip

      repos == [] ->
        Logger.info(
          "ReviewPatrolSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "no repos resolvable (set merge.config.repo / merge.config.project_id, " <>
            "or a repo_paths map whose repos have a github/gitlab origin remote)"
        )

        :skip

      true ->
        desired = desired_children(workspace.id, repos)
        stop_stale_children(workspace.id, desired)

        results =
          Enum.map(desired, fn {registry_key, repo} ->
            cond do
              off_mode?(workspace, repo) ->
                stop_if_running(registry_key)

                Logger.info(
                  "ReviewPatrolSupervisor: skip patrol #{repo} workspace #{workspace.id} " <>
                    "(#{workspace.name}) — review_automation resolves to :off for this repo"
                )

                :skip

              # Lazy-start gate (bd-7tr11p): only patrol a repo that actually has
              # an open engagement to watch. A repo with none costs nothing — no
              # process, no polling — until one is opened (the PatrolLifecycle
              # subscriber re-invokes this on the lifecycle event, and a running
              # patrol self-terminates once its last engagement closes). Cheap DB
              # read, never a forge call, so an idle-fleet boot starts zero
              # patrols.
              not ReviewPatrol.has_open_engagement?(workspace.id, repo) ->
                Logger.info(
                  "ReviewPatrolSupervisor: skip patrol #{repo} workspace #{workspace.id} " <>
                    "(#{workspace.name}) — no open engagement to watch"
                )

                :skip

              true ->
                start_repo(workspace, repo, registry_key, opts)
            end
          end)

        List.first(results, :skip)
    end
  end

  @doc """
  Bring the workspace's running patrols in line with its current config
  (bd-7feiul). Stops every patrol of this workspace whose registry key or repo
  is no longer what the config resolves to — all of them when the workspace no
  longer qualifies for a patrol at all — then re-runs the gated start, so a
  replacement (or a patrol for a newly resolved repo) starts only where the
  lazy-start gate (bd-7tr11p) finds an open engagement and the repo is not
  `:off`. A patrol whose repo is unchanged keeps running, with its per-repo
  rate-limit state intact.

  Called after a workspace `:update` / `:patch_config` that changes `config`.
  Returns what `start_patrol/2` does, or `:skip`.
  """
  @spec reconcile(Workspace.t()) :: DynamicSupervisor.on_start_child() | :skip
  def reconcile(%Workspace{} = workspace) do
    repos = patrol_repos(workspace)
    adapter = resolve_adapter(workspace, repos)

    if supported_adapter?(adapter) and repos != [] do
      do_start_patrol(workspace, adapter, repos, [])
    else
      stop_stale_children(workspace.id, [])
      :skip
    end
  end

  @doc """
  Ensure a patrol is running for the repo a just-opened engagement belongs to,
  WITHOUT re-reading the database (bd-7tr11p). Called by the `PatrolLifecycle`
  subscriber on the lifecycle event: the event itself is proof that an
  engagement exists, so this starts the repo's patrol optimistically rather than
  gating on a DB read that could race the not-yet-committed create. `ref` is the
  engagement's `source_pr`; the repo is resolved from it against the workspace
  config. Still respects `:off` mode (an off repo is never patrolled).
  Idempotent; returns `:skip` when the ref names no repo this workspace patrols
  or that repo is `:off`.
  """
  @spec ensure_started(Workspace.t(), String.t()) ::
          DynamicSupervisor.on_start_child() | :skip
  def ensure_started(%Workspace{} = workspace, ref) when is_binary(ref) do
    repos = patrol_repos(workspace)
    adapter = resolve_adapter(workspace, repos)

    with true <- supported_adapter?(adapter),
         repo when is_binary(repo) <- resolve_demand_repo(ref, repos),
         false <- off_mode?(workspace, repo) do
      desired = desired_children(workspace.id, repos)
      # A patrol still pinned to a repo the config has moved away from may hold
      # this very registry key (bd-7feiul) — replace it rather than collapse
      # into `{:already_started, stale_pid}`.
      stop_stale_children(workspace.id, desired)
      {registry_key, ^repo} = List.keyfind(desired, repo, 1)
      start_repo(workspace, repo, registry_key, [])
    else
      _ -> :skip
    end
  end

  # Resolve the repo a demand-start ref belongs to, against the workspace's
  # patrolled repos. A qualified ref must name one of them; a bare ref can only
  # come from a single-repo workspace, so it maps to the sole repo.
  defp resolve_demand_repo(ref, repos) do
    case PatrolRepoScope.repo_of_ref(ref) do
      {:ok, slug} -> if slug in repos, do: slug, else: nil
      :bare -> if match?([_], repos), do: hd(repos), else: nil
    end
  end

  # Start one repo's patrol under its registry key. Shared by the gated boot
  # loop and the demand-start path. Idempotent via the DynamicSupervisor.
  defp start_repo(workspace, repo, registry_key, opts) do
    child_opts =
      opts
      |> Keyword.put(:repo, repo)
      |> Keyword.put(:workspace_id, workspace.id)
      |> Keyword.put_new(:interval_ms, patrol_interval_ms())
      |> Keyword.put(:name, via(registry_key, repo))

    result = DynamicSupervisor.start_child(__MODULE__, {ReviewPatrol, child_opts})

    Logger.info(
      "ReviewPatrolSupervisor: patrol #{repo} workspace #{workspace.id} (#{workspace.name}): #{inspect(result)}"
    )

    result
  end

  # A repo whose LIVE `review_automation.repo_overrides[repo_name]` (or,
  # absent an override, `review_automation.default`) resolves to `:off` has no
  # reviewer we'd ever dispatch against it — ReviewPatrol's own tick logic
  # already downgrades an in-flight engagement to no-dispatch behavior in this
  # case (see `ReviewPatrol.automation_mode/3`), but the PATROL PROCESS ITSELF
  # still started and ticked GitHub every interval regardless (bd-4brb2j: this
  # was true of both `apex_audio` at `:flag` and `atlas` at
  # `:report_only` in the incident — closing that gap for the strictly-worse
  # `:off` case here is the highest-value, lowest-risk slice of that finding).
  # Checked at author-independent granularity (`repo_override_mode/2`, no PR
  # author needed), same as ReviewPatrol's own live re-check.
  defp off_mode?(%Workspace{} = workspace, repo) do
    repo_name = ReviewPatrol.repo_name_for_repo(workspace, repo)

    case ReviewAutomation.repo_override_mode(workspace.config, repo_name) do
      :off -> true
      nil -> default_off?(workspace.config)
      _ -> false
    end
  end

  defp default_off?(%{"review_automation" => %{"default" => default}}),
    do: ReviewAutomation.normalize(default) == :off

  defp default_off?(_config), do: false

  defp stop_if_running(registry_key) do
    case Registry.lookup(@registry, registry_key) do
      [{pid, _}] ->
        Logger.info(
          "ReviewPatrolSupervisor: stopping patrol #{registry_key} — review_automation flipped to :off"
        )

        ProcessTeardown.stop_child(__MODULE__, pid)

      _ ->
        :ok
    end
  end

  @doc """
  Return the pid of the ReviewPatrol registered under `workspace_id`, or `nil`.
  For multi-repo workspaces use `whereis_all/1`.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc """
  Return all `{registry_key, pid}` pairs for a workspace, covering both
  single-repo patrols (registered under `workspace_id`) and multi-repo patrols
  (registered under `"workspace_id:owner/repo"`).
  """
  @spec whereis_all(String.t()) :: [{String.t(), pid()}]
  def whereis_all(workspace_id) when is_binary(workspace_id) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {key, _pid} ->
      key == workspace_id or String.starts_with?(key, workspace_id <> ":")
    end)
  end

  @doc """
  Nudge every running patrol for a workspace to re-check whether its repo still
  has an open engagement (bd-7tr11p). Sends each an async `:recheck`; a patrol
  whose last engagement has closed terminates itself (`:transient`, so it stays
  down). Called by the `PatrolLifecycle` subscriber when a watched item closes,
  so an idle repo's patrol is reaped promptly rather than on its next scheduled
  tick.
  """
  @spec recheck_all(String.t()) :: :ok
  def recheck_all(workspace_id) when is_binary(workspace_id) do
    for {_key, pid} <- whereis_all(workspace_id), is_pid(pid) do
      send(pid, :recheck)
    end

    :ok
  end

  @doc false
  def via(workspace_id), do: {:via, Registry, {@registry, workspace_id}}

  @doc false
  def via(registry_key, repo), do: {:via, Registry, {@registry, registry_key, repo}}

  @doc """
  Whether patrols should auto-start. Shares the `:auto_start_refineries` config
  flag with `PRPatrolSupervisor` / `MergeQueueSupervisor` — false in test, true
  everywhere else.
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:arbiter, :auto_start_refineries, true)
  end

  @doc """
  Enumerate every workspace and start a ReviewPatrol for those with a GitHub
  merge config. Best-effort: a per-workspace failure is logged but does not
  block the others. Called from the application supervision tree's boot Task.
  """
  @spec start_for_existing_workspaces() :: :ok
  def start_for_existing_workspaces do
    case Ash.read(Workspace) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn ws ->
          case start_patrol(ws) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              :ok

            :skip ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "ReviewPatrolSupervisor: failed to start patrol for workspace #{ws.id}: " <>
                  inspect(reason)
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "ReviewPatrolSupervisor: failed to enumerate workspaces at boot: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "ReviewPatrolSupervisor: enumeration crashed at boot: #{Exception.message(e)}"
      )

      :ok
  end

  # `{registry_key, repo}` for each patrol the workspace's config resolves to: a
  # single repo registers under the bare workspace id, several under
  # "workspace_id:owner/repo".
  defp desired_children(workspace_id, [repo]), do: [{workspace_id, repo}]

  defp desired_children(workspace_id, repos),
    do: Enum.map(repos, &{"#{workspace_id}:#{&1}", &1})

  # Stop every patrol of this workspace that is not in `desired` — a 1↔N
  # registry-scheme change as well as a patrol still pinned to a repo the
  # workspace no longer resolves to under an unchanged key (bd-7feiul).
  defp stop_stale_children(workspace_id, desired) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.filter(fn {key, _pid, _repo} -> workspace_key?(key, workspace_id) end)
    |> Enum.reject(fn {key, _pid, repo} -> {key, repo} in desired end)
    |> Enum.each(fn {key, pid, repo} ->
      Logger.info(
        "ReviewPatrolSupervisor: stopping stale patrol #{key} (repo=#{inspect(repo)}) — " <>
          "workspace #{workspace_id} now resolves to #{inspect(Enum.map(desired, &elem(&1, 1)))}"
      )

      ProcessTeardown.stop_child(__MODULE__, pid)
    end)
  end

  defp workspace_key?(workspace_id, workspace_id), do: true

  defp workspace_key?(key, workspace_id) when is_binary(key),
    do: String.starts_with?(key, workspace_id <> ":")

  defp workspace_key?(_key, _workspace_id), do: false

  defp supported_adapter?(adapter),
    do: not is_nil(adapter) and function_exported?(adapter, :get, 1)

  # Resolve the merge adapter for a workspace, or nil on unknown strategy.
  # Load it before `start_patrol/2`'s `function_exported?/3` guard inspects it —
  # see bd-1hn1qw (mirrors PRPatrolSupervisor).
  # bd-73zv62: the adapter of the repo the first patrolled slug belongs to, or
  # the workspace-level one when nothing is patrolled.
  defp resolve_adapter(workspace, repos) do
    adapter = Mergers.for_workspace(scope(workspace, List.first(repos)))
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  @doc """
  The repos (`"owner/repo"` slugs, or GitLab project ids) the workspace's
  config resolves to — one patrol each: single-repo (merge.config.repo set) or
  multi-repo (one per repo, derived from each repo's origin remote), as in
  PRPatrolSupervisor. `ReviewPatrol` re-checks its own repo against this every
  tick (bd-7feiul). Empty when none resolve.
  """
  # Resolved per repo against its effective merge block
  # (`Arbiter.Mergers.ForgeRepos`, bd-73zv62): a repo on a
  # `merge.repos.<repo>.strategy = "direct"` override gets no patrol.
  @spec patrol_repos(Workspace.t()) :: [String.t()]
  def patrol_repos(%Workspace{} = workspace), do: ForgeRepos.slugs(workspace, @forge_opts)

  @doc """
  `workspace` narrowed to the repo the patrolled forge `repo` slug belongs to
  (`Arbiter.Mergers.ForgeRepos.scope/3`, bd-73zv62).
  """
  @spec scope(Workspace.t(), String.t() | nil) :: Workspace.t()
  def scope(%Workspace{} = workspace, repo), do: ForgeRepos.scope(workspace, repo, @forge_opts)

  defp patrol_interval_ms do
    Application.get_env(:arbiter, :review_patrol_interval_ms, 60_000)
  end
end
