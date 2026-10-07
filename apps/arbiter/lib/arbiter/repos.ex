defmodule Arbiter.Repos do
  @moduledoc """
  Core context for repos — named repository checkouts that workers operate on.

  A repo is discovered from three sources:
    * each workspace's `config["repo_paths"]` map,
    * the application-env fallback `:arbiter, :repo_paths` (`source: "(app)"`),
    * any repo name a live worker is running against that isn't configured
      anywhere (`source: "(unconfigured)"`).

  Repo listing is workspace-aware and does not collapse same-named repos
  across workspaces (parity audit P-24, D-C-31).
  """

  require Ash.Query

  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Worktree

  @type repo :: %{
          name: String.t(),
          path: String.t() | nil,
          source: String.t(),
          workers: non_neg_integer(),
          worktrees: non_neg_integer(),
          workspace_id: String.t() | nil
        }

  @doc """
  List registered repos with their path, source, active worker count, and git worktree count.

  Options:
    * `:workspace_id` — filter to repos configured in this workspace
    * `:workspace` — filter to repos in this `%Workspace{}` struct
  """
  @spec list(keyword()) :: [repo()]
  def list(opts \\ []) do
    workspaces = load_workspaces(opts)
    workers_by_repo = group_workers_by_repo()

    ws_entries = collect_workspace_repos(workspaces)
    ws_names = MapSet.new(ws_entries, & &1.name)

    # App-env fallback applies globally when not scoped to a specific workspace
    scoped? = Keyword.has_key?(opts, :workspace_id) or Keyword.has_key?(opts, :workspace)

    app_entries =
      if scoped? do
        []
      else
        collect_app_repos(ws_names)
      end

    configured_names =
      ws_names
      |> MapSet.union(MapSet.new(app_entries, & &1.name))

    worker_entries =
      if scoped? do
        []
      else
        repos_from_workers(workers_by_repo, configured_names)
      end

    (ws_entries ++ app_entries ++ worker_entries)
    |> Enum.map(fn entry ->
      path = entry.path

      worktree_count =
        case path do
          nil -> 0
          p when is_binary(p) -> safe_worktree_count(p)
        end

      %{
        name: entry.name,
        path: path,
        source: entry.source,
        workspace_id: entry.workspace_id,
        workers: Map.get(workers_by_repo, entry.name, 0),
        worktrees: worktree_count
      }
    end)
    |> Enum.sort_by(&{&1.name, &1.source})
  end

  @doc """
  Find a single repo by name, returning `{:ok, repo}` or `{:error, {:not_found, msg}}`.
  Accepts the same options as `list/1`.
  """
  @spec get(String.t(), keyword()) :: {:ok, repo()} | {:error, {:not_found, String.t()}}
  def get(name, opts \\ []) when is_binary(name) do
    repos = list(opts)

    case Enum.find(repos, fn repo -> repo.name == name end) do
      nil -> {:error, {:not_found, "repo #{inspect(name)} not found"}}
      repo -> {:ok, repo}
    end
  end

  # ---- internal helpers ----

  defp load_workspaces(opts) do
    cond do
      ws = Keyword.get(opts, :workspace) ->
        case ws do
          %Workspace{} -> [ws]
          _ -> []
        end

      ws_id = Keyword.get(opts, :workspace_id) ->
        Workspace
        |> Ash.Query.filter(id == ^ws_id or name == ^ws_id)
        |> Ash.read!()

      true ->
        Ash.read!(Workspace)
    end
  rescue
    _ -> []
  end

  defp collect_workspace_repos(workspaces) do
    Enum.flat_map(workspaces, fn ws ->
      ws_repo_paths =
        case ws.config do
          %{"repo_paths" => paths} when is_map(paths) -> paths
          _ -> %{}
        end

      Enum.map(ws_repo_paths, fn {name, raw} ->
        %{
          name: name,
          path: RepoConfig.repo_path_from_config(raw),
          source: ws.name,
          workspace_id: ws.id
        }
      end)
    end)
  end

  defp collect_app_repos(ws_names) do
    :arbiter
    |> Application.get_env(:repo_paths, %{})
    |> Enum.reject(fn {name, _raw} -> MapSet.member?(ws_names, name) end)
    |> Enum.map(fn {name, raw} ->
      %{
        name: name,
        path: RepoConfig.repo_path_from_config(raw),
        source: "(app)",
        workspace_id: nil
      }
    end)
  end

  defp repos_from_workers(workers_by_repo, configured_names) do
    workers_by_repo
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(configured_names, &1))
    |> Enum.map(fn name ->
      %{
        name: name,
        path: nil,
        source: "(unconfigured)",
        workspace_id: nil
      }
    end)
  end

  defp group_workers_by_repo do
    try do
      Worker.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      repo = p.repo || "(none)"
      Map.update(acc, repo, 1, &(&1 + 1))
    end)
  end

  defp safe_worktree_count(path) do
    Worktree.list(path) |> length()
  rescue
    _ -> 0
  end
end
