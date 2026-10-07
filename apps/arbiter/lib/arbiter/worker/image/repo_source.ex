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
  alias Arbiter.Tasks.Workspaces

  @type t :: %{repo: String.t(), path: String.t(), default_branch: String.t()}

  @doc """
  Resolve `repo` (a `repo_paths` key). A `workspace` (id or name, resolved by
  `Arbiter.Tasks.Workspaces`) restricts the lookup to that one. With none, the
  lookup spans every workspace and the global registry: one registrant (or
  several agreeing on the checkout path) is unambiguous, while a repo
  registered at different paths in several workspaces is an error naming them
  rather than a silent pick of whichever sorts first.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def resolve(repo, workspace_ref \\ nil)

  def resolve(repo, _workspace_ref) when not is_binary(repo) or repo == "",
    do: {:error, "a repo name is required"}

  def resolve(repo, workspace_ref) do
    with {:ok, workspaces} <- candidates(workspace_ref),
         {:ok, {workspace, path}} <- find(workspaces, repo) do
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
    case Workspaces.fetch(ref) do
      {:ok, ws} -> {:ok, [ws]}
      {:error, {_kind, message}} -> {:error, message}
    end
  end

  defp find(workspaces, repo) do
    registrants =
      for ws <- workspaces,
          path = LocalCompare.repo_path(ws, repo),
          path != nil and registered_in?(ws, repo),
          do: {ws, path}

    case Enum.uniq_by(registrants, &elem(&1, 1)) do
      [] -> {:ok, {nil, global_path(repo)}}
      [found] -> {:ok, found}
      _many -> {:error, ambiguous(repo, registrants)}
    end
  end

  defp ambiguous(repo, registrants) do
    names = registrants |> Enum.map(fn {ws, _} -> ws.name end) |> Enum.sort() |> Enum.join(", ")

    "repo #{inspect(repo)} is registered at different paths in several workspaces; pass workspace (name or id): #{names}"
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
