defmodule Arbiter.Worker.Image.RepoSource do
  @moduledoc """
  Which checkout and which branch an image is planned from (bd-9r5jdt).

  The checkout is the repo's registered path (the workspace's `repo_paths`
  entry, else the global `:arbiter, :repo_paths`): the main clone, never a
  worker's worktree. The branch is the repo's **default branch**: the effective
  `merge.base` (per-repo override, else workspace-level) or `"main"`. A task's
  own `target_branch`, or a per-repo integration branch, is deliberately not
  consulted: the image definition is read from the branch PRs merge into, so
  nothing a worker can push reaches it (design §2.2 and §8).
  """

  alias Arbiter.Mergers
  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  @type t :: %{repo: String.t(), path: String.t(), default_branch: String.t()}

  @doc """
  Resolve `repo` (a `repo_paths` key). With no `workspace` ref, the first
  workspace that registers the repo wins, else the global registry; a
  `workspace` (id or name) restricts the lookup to that one.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def resolve(repo, workspace_ref \\ nil)

  def resolve(repo, _workspace_ref) when not is_binary(repo) or repo == "",
    do: {:error, "a repo name is required"}

  def resolve(repo, workspace_ref) do
    with {:ok, workspaces} <- candidates(workspace_ref) do
      {workspace, path} = find(workspaces, repo)

      if is_binary(path) and path != "" do
        {:ok,
         %{
           repo: repo,
           path: path,
           default_branch: (workspace && Mergers.base_branch(workspace, repo)) || "main"
         }}
      else
        {:error, "repo #{inspect(repo)} is not registered (see `arb repo list`)"}
      end
    end
  end

  defp candidates(nil), do: {:ok, load_workspaces()}

  defp candidates(ref) do
    case Enum.filter(load_workspaces(), &(&1.id == ref or &1.name == ref)) do
      [] -> {:error, "workspace #{inspect(ref)} not found"}
      found -> {:ok, found}
    end
  end

  defp find(workspaces, repo) do
    Enum.find_value(workspaces, {nil, global_path(repo)}, fn ws ->
      case LocalCompare.repo_path(ws, repo) do
        nil -> nil
        path -> if registered_in?(ws, repo), do: {ws, path}
      end
    end)
  end

  defp registered_in?(%Workspace{config: %{"repo_paths" => paths}}, repo) when is_map(paths),
    do: RepoConfig.find_entry(paths, repo) != nil

  defp registered_in?(_, _), do: false

  defp global_path(repo),
    do: RepoConfig.find_path(Application.get_env(:arbiter, :repo_paths, %{}), repo)

  defp load_workspaces do
    Ash.read!(Workspace)
  rescue
    _ -> []
  end
end
