defmodule Arbiter.Worker.SeedPaths do
  @moduledoc """
  Resolves `worker.repos.<repo>.seed_paths` (bd-2jerqw): the repo-relative
  paths `Arbiter.Worker.Worktree.seed_compiled_deps/3` copies from the source
  repo into a fresh worker checkout.

  The block resolves like `merge.repos.<repo>` (`Arbiter.Mergers.merge_config/2`):
  `config["worker"]["repos"][repo]` is deep-merged over the workspace-level
  `config["worker"]`, with the repo key matched the way `repo_paths` keys are
  (`Arbiter.Tasks.RepoConfig.find_entry/2`: exact, slug-normalised, then the
  bare name of an `owner/name`). A list is a leaf in the merge, so a per-repo
  `seed_paths` **replaces** the workspace-level one rather than extending it.

      {"worker": {
        "seed_paths": ["deps"],
        "repos": {"arbiter": {"seed_paths": ["deps", "_build/test/lib", "priv/plts"]}}
      }}

  `resolve/2` returns `nil` when nothing is configured — the caller then seeds
  exactly the built-in default set. `[]` is a configured value: seed nothing.
  A value that is not a list of strings reads as unset (`ValidateConfig`
  refuses it on write; this is the read-side guard for a hand-edited row).
  """

  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace.Changes.PatchConfig

  @doc """
  The configured seed paths for `repo` in `workspace` (a `Workspace`, any
  config-bearing map, or `nil`), or `nil` when unset.
  """
  @spec resolve(term(), String.t() | nil) :: [String.t()] | nil
  def resolve(%{config: %{"worker" => %{} = worker}}, repo) do
    case effective(worker, repo) do
      %{"seed_paths" => [_ | _] = paths} -> valid_list(paths)
      %{"seed_paths" => []} -> []
      _ -> nil
    end
  end

  def resolve(_workspace, _repo), do: nil

  defp valid_list(paths), do: if(Enum.all?(paths, &is_binary/1), do: paths)

  defp effective(worker, repo) do
    {repos, base} = Map.pop(worker, "repos")

    with true <- is_binary(repo) and repo != "" and is_map(repos),
         %{} = override <- RepoConfig.find_entry(repos, repo) do
      PatchConfig.deep_merge(base, Map.delete(override, "repos"))
    else
      _ -> base
    end
  end
end
