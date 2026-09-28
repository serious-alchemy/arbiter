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

  alias Arbiter.{Mergers, Tasks.RepoConfig, Tasks.Workspace}
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.ProcessTeardown
  alias Arbiter.Workflows.MergedPRFinalizer

  @registry Arbiter.Workflows.MergedPRFinalizerRegistry

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
    adapter = resolve_adapter(workspace)
    repos = finalizer_repos(workspace)

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

  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)
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
  # Pre-existing complexity 13 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  @spec finalizer_repos(Workspace.t()) :: [String.t()]
  def finalizer_repos(%Workspace{} = workspace) do
    config = workspace.config || %{}

    case get_in(config, ["merge", "strategy"]) do
      "github" ->
        owner = get_in(config, ["merge", "config", "owner"])
        repo = get_in(config, ["merge", "config", "repo"])

        if is_binary(owner) and owner != "" and is_binary(repo) and repo != "" do
          ["#{owner}/#{repo}"]
        else
          repos_from_repo_paths(config)
        end

      "gitlab" ->
        case get_in(config, ["merge", "config", "project_id"]) do
          v when is_integer(v) -> ["#{v}"]
          v when is_binary(v) and v != "" -> [v]
          _ -> repos_from_repo_paths(config)
        end

      _ ->
        []
    end
  end

  defp repos_from_repo_paths(config) do
    case Map.get(config, "repo_paths") do
      repo_map when is_map(repo_map) ->
        repo_map
        |> Map.values()
        |> Enum.map(&RepoConfig.repo_path_from_config/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn path ->
          case RepoResolver.from_remote(path) do
            {:ok, {owner, repo}} ->
              ["#{owner}/#{repo}"]

            {:error, err} ->
              Logger.info(
                "MergedPRFinalizerSupervisor: could not derive repo for path #{path} " <>
                  "(skipping): #{inspect(err)}"
              )

              []
          end
        end)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp finalizer_interval_ms do
    Application.get_env(:arbiter, :merged_pr_finalizer_interval_ms, 120_000)
  end
end
