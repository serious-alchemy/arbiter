defmodule Arbiter.Workflows.MergedPRFinalizerSupervisor do
  @moduledoc """
  DynamicSupervisor for MergedPRFinalizer processes — one per (workspace, repo)
  pair configured for GitHub merges. Mirrors `PRPatrolSupervisor` in structure.

  At application boot, `start_for_existing_workspaces/0` enumerates every
  workspace and starts a finalizer for those with a GitHub merge config. New
  workspaces start their finalizer via the
  `Arbiter.Tasks.Workspace.Changes.StartMergedPRFinalizer` after_action hook.

  A workspace `:update` / `:patch_config` that changes `config` runs
  `reconcile/1` (via `Arbiter.Tasks.Workspace.Changes.ReconcileMergedPRFinalizer`)
  so the running finalizers follow the new config without a restart
  (bd-6dghdv): one whose repo the workspace no longer resolves to is stopped,
  and a finalizer is started for every repo that now resolves.

  All three auto-start paths are gated by the `:arbiter, :auto_start_refineries`
  config flag — disabled in `test`, enabled everywhere else.

  ## Registry

  Each finalizer registers under `workspace_id` (single-repo workspace) or
  `"workspace_id:owner/repo"` (multi-repo), with the repo it sweeps as the
  registry value — which is what lets `reconcile/1` tell a finalizer pinned to
  a stale repo from a current one without calling into it.

  Poll interval is read from `:arbiter, :merged_pr_finalizer_interval_ms`
  (default 120s — less frequent than PRPatrol's 60s since merged PRs are a
  lower-urgency recovery path).
  """

  require Logger

  alias Arbiter.{Mergers, Tasks.Workspace}
  alias Arbiter.Mergers.ForgeRepos
  alias Arbiter.ProcessTeardown
  alias Arbiter.Workflows.MergedPRFinalizer

  @registry Arbiter.Workflows.MergedPRFinalizerRegistry
  @forge_opts [log: "MergedPRFinalizerSupervisor"]

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
  Start a MergedPRFinalizer for each repo configured in the workspace's GitHub
  merge config. Returns `:skip` when the adapter doesn't support `get/1` or
  when no repos can be derived from the workspace config.

  Idempotent: a duplicate start returns `{:error, {:already_started, pid}}`.
  """
  @spec start_finalizer(Workspace.t(), keyword()) :: DynamicSupervisor.on_start_child() | :skip
  def start_finalizer(%Workspace{} = workspace, opts \\ []) do
    repos = finalizer_repos(workspace)
    adapter = resolve_adapter(workspace, repos)

    cond do
      is_nil(adapter) or not function_exported?(adapter, :get, 1) ->
        Logger.info(
          "MergedPRFinalizerSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "merge adapter #{inspect(adapter)} does not support get/1"
        )

        :skip

      repos == [] ->
        Logger.info(
          "MergedPRFinalizerSupervisor: skip workspace #{workspace.id} (#{workspace.name}) — " <>
            "no repos resolvable (set merge.config.repo / merge.config.project_id, " <>
            "or a repo_paths map whose repos have a github/gitlab origin remote)"
        )

        :skip

      true ->
        desired = desired_children(workspace.id, repos)
        stop_stale_children(workspace.id, desired)

        results =
          Enum.map(desired, fn {registry_key, repo} ->
            child_opts =
              opts
              |> Keyword.put(:repo, repo)
              |> Keyword.put(:workspace_id, workspace.id)
              |> Keyword.put_new(:interval_ms, finalizer_interval_ms())
              |> Keyword.put(:name, via(registry_key, repo))

            result = DynamicSupervisor.start_child(__MODULE__, {MergedPRFinalizer, child_opts})

            Logger.info(
              "MergedPRFinalizerSupervisor: finalizer #{repo} workspace #{workspace.id} (#{workspace.name}): #{inspect(result)}"
            )

            result
          end)

        List.first(results, :skip)
    end
  end

  @doc """
  Bring the workspace's running finalizers in line with its current config
  (bd-6dghdv). Stops every finalizer of this workspace whose registry key or
  repo is no longer what the config resolves to — all of them when the
  workspace no longer qualifies for a finalizer at all — then starts any that
  are missing. A finalizer whose repo is unchanged keeps running (and keeps its
  sweep cursor).

  Called after a workspace `:update` / `:patch_config` that changes `config`.
  Returns what `start_finalizer/2` does, or `:skip` once everything is stopped.
  """
  @spec reconcile(Workspace.t()) :: DynamicSupervisor.on_start_child() | :skip
  def reconcile(%Workspace{} = workspace) do
    case start_finalizer(workspace) do
      :skip ->
        stop_stale_children(workspace.id, [])
        :skip

      result ->
        result
    end
  end

  @doc "Return the pid registered under `workspace_id`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc false
  def via(workspace_id), do: {:via, Registry, {@registry, workspace_id}}

  @doc false
  def via(registry_key, repo), do: {:via, Registry, {@registry, registry_key, repo}}

  @doc """
  Whether finalizers should auto-start. Shares the `:auto_start_refineries`
  config flag — false in test, true everywhere else.
  """
  @spec auto_start?() :: boolean()
  def auto_start? do
    Application.get_env(:arbiter, :auto_start_refineries, true)
  end

  @doc """
  Enumerate every workspace and start a MergedPRFinalizer for those with a
  GitHub merge config. Best-effort. Called from the application supervision
  tree's boot Task.
  """
  @spec start_for_existing_workspaces() :: :ok
  def start_for_existing_workspaces do
    case Ash.read(Workspace) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn ws ->
          case start_finalizer(ws) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              :ok

            :skip ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "MergedPRFinalizerSupervisor: failed to start finalizer for workspace #{ws.id}: " <>
                  inspect(reason)
              )
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "MergedPRFinalizerSupervisor: failed to enumerate workspaces at boot: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "MergedPRFinalizerSupervisor: enumeration crashed at boot: #{Exception.message(e)}"
      )

      :ok
  end

  # `{registry_key, repo}` for each finalizer the workspace should run: a
  # single repo registers under the bare workspace id, several under
  # "workspace_id:owner/repo".
  defp desired_children(workspace_id, [repo]), do: [{workspace_id, repo}]

  defp desired_children(workspace_id, repos),
    do: Enum.map(repos, &{"#{workspace_id}:#{&1}", &1})

  # Stop every finalizer of this workspace that is not in `desired` — covers a
  # registry-scheme change (a repo count crossing 1↔N) as well as a finalizer
  # still pinned to a repo the workspace no longer resolves to (bd-6dghdv).
  defp stop_stale_children(workspace_id, desired) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.filter(fn {key, _pid, _repo} -> workspace_key?(key, workspace_id) end)
    |> Enum.reject(fn {key, _pid, repo} -> {key, repo} in desired end)
    |> Enum.each(fn {key, pid, repo} ->
      Logger.info(
        "MergedPRFinalizerSupervisor: stopping stale finalizer #{key} (repo=#{inspect(repo)}) — " <>
          "workspace #{workspace_id} now resolves to #{inspect(Enum.map(desired, &elem(&1, 1)))}"
      )

      ProcessTeardown.stop_child(__MODULE__, pid)
    end)
  end

  defp workspace_key?(workspace_id, workspace_id), do: true

  defp workspace_key?(key, workspace_id) when is_binary(key),
    do: String.starts_with?(key, workspace_id <> ":")

  defp workspace_key?(_key, _workspace_id), do: false

  # bd-73zv62: the adapter of the repo the first finalized slug belongs to, or
  # the workspace-level one when nothing is finalized.
  defp resolve_adapter(workspace, repos) do
    adapter = Mergers.for_workspace(scope(workspace, List.first(repos)))
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  @doc """
  The repos (`"owner/repo"` slugs, or GitLab project ids) the workspace's
  config resolves to — one finalizer each. `MergedPRFinalizer` re-checks its
  own repo against this every tick (bd-6dghdv).
  """
  # Resolved per repo against its effective merge block
  # (`Arbiter.Mergers.ForgeRepos`, bd-73zv62): a repo on a
  # `merge.repos.<repo>.strategy = "direct"` override gets no finalizer.
  @spec finalizer_repos(Workspace.t()) :: [String.t()]
  def finalizer_repos(%Workspace{} = workspace), do: ForgeRepos.slugs(workspace, @forge_opts)

  @doc """
  `workspace` narrowed to the repo the finalized forge `repo` slug belongs to
  (`Arbiter.Mergers.ForgeRepos.scope/3`, bd-73zv62).
  """
  @spec scope(Workspace.t(), String.t() | nil) :: Workspace.t()
  def scope(%Workspace{} = workspace, repo), do: ForgeRepos.scope(workspace, repo, @forge_opts)

  defp finalizer_interval_ms do
    Application.get_env(:arbiter, :merged_pr_finalizer_interval_ms, 120_000)
  end
end
