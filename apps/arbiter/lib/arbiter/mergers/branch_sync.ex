defmodule Arbiter.Mergers.BranchSync do
  @moduledoc """
  Sync an MR branch with its target by a **merge commit** pushed as a plain
  fast-forward (`merge.sync_strategy: merge`), instead of the forge's rebase
  endpoint (`merge.sync_strategy: rebase`).

  GitLab's `PUT /merge_requests/:iid/rebase` rewrites every commit of the
  worker branch and force-pushes it. That breaks "never rewrite worker
  branches", and because every commit gets a new SHA the head a reviewer ruled
  on stops being an ancestor of the new head, so rulings and reviews are voided
  on each sync. GitHub's update-branch already merges the base in; this gives
  GitLab the same shape.

  ## What the merge path does

  In the ticket's own worktree (`sync/5` attaches it; `merge_in/3` takes any
  checkout of the branch):

    1. fetch `origin/<branch>` and `origin/<target>`;
    2. bring the local branch up to `origin/<branch>` without discarding a
       commit (`Worktree.align_branch/3`; a diverged branch is refused);
    3. `git merge --no-edit origin/<target>`;
    4. `git push origin HEAD:refs/heads/<branch>` — never `--force`: a push the
       remote would only take as a rewrite is rejected and surfaces as an error.

  A merge that conflicts is aborted (`git merge --abort`), nothing is pushed,
  and `{:error, {:conflict, files}}` comes back. Callers treat any sync error
  as "route to the conflict path", where the forge's own `conflicting` flag
  hands the MR to the existing conflict resolver — which owns resolution, not
  this module.

  ## Config

  `merge.sync_strategy` — `"merge"` (default) or `"rebase"`; per repo through
  `merge.repos.<repo>.sync_strategy`. Only the GitLab adapter reads it (GitHub
  always merges). **GitLab projects whose merge method is fast-forward or
  semi-linear cannot take merge commits in the MR branch and need `rebase`.**
  """

  require Logger

  alias Arbiter.Mergers
  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitLayout
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Worktree

  @type reason ::
          :no_repo_path
          | :dirty_worktree
          | {:wrong_branch, String.t()}
          | {:conflict, [String.t()]}
          | {:diverged, String.t(), String.t()}
          | {:fetch_failed, String.t()}
          | {:push_failed, String.t()}
          | {:git_failed, String.t()}
          | {:worktree_failed, term()}

  @doc """
  The sync strategy for `repo` in `workspace`: `:merge` (default) or `:rebase`.
  An unrecognised value falls back to the default rather than failing a sync.
  """
  @spec strategy(Workspace.t() | nil, String.t() | nil) :: :merge | :rebase
  def strategy(workspace, repo) do
    case workspace |> Mergers.merge_config(repo) |> Map.get("sync_strategy") do
      value when value in ["rebase", :rebase] -> :rebase
      _ -> :merge
    end
  end

  @doc """
  Merge `origin/<target>` into `branch` in the ticket worktree of `repo` and push
  it. Attaches the existing worktree for `branch` (idempotent) under the layout
  the ticket's own runs use. See `merge_in/3` for the result.
  """
  @spec sync(Workspace.t() | nil, String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, :synced | :up_to_date} | {:error, reason()}
  def sync(workspace, repo, branch, target, opts \\ []) do
    repo_path =
      Keyword.get_lazy(opts, :repo_path, fn -> LocalCompare.repo_path(workspace, repo) end)

    with {:ok, repo_path} <- usable(repo_path),
         {:ok, path} <- attach(workspace, repo, repo_path, branch, target) do
      merge_in(path, branch, target)
    end
  end

  @doc """
  Merge `origin/<target>` into `branch` in the checkout at `path` (which must be on
  `branch` and clean) and push `branch` to `origin` without force.

  `{:ok, :synced}` after a pushed merge commit, `{:ok, :up_to_date}` when the branch
  already contains the target tip (nothing pushed), else `{:error, reason}`.
  """
  @spec merge_in(String.t(), String.t(), String.t()) ::
          {:ok, :synced | :up_to_date} | {:error, reason()}
  def merge_in(path, branch, target)
      when is_binary(path) and is_binary(branch) and is_binary(target) do
    with :ok <- on_branch(path, branch),
         :ok <- clean(path),
         {:ok, tips} <- fetch_tips(path, branch, target),
         {:ok, _} <- Worktree.align_branch(path, branch, Map.fetch!(tips, branch)),
         {:ok, result} <- merge_target(path, target) do
      push(path, branch, result)
    end
  end

  defp usable(path) when is_binary(path) and path != "", do: {:ok, path}
  defp usable(_), do: {:error, :no_repo_path}

  defp attach(workspace, repo, repo_path, branch, target) do
    layout = GitLayout.for_workspace(workspace, repo)

    case Worktree.attach(repo_path, branch, layout: layout, base: target) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp on_branch(path, branch) do
    case Worktree.current_branch(path) do
      {:ok, ^branch} -> :ok
      {:ok, other} -> {:error, {:wrong_branch, other}}
      {:error, {:git_failed, msg}} -> {:error, {:git_failed, msg}}
    end
  end

  # A half-finished operation or a dirty tree is somebody's work in progress (a
  # live run in the same worktree): merging over it could swallow or lose it.
  defp clean(path) do
    case Worktree.has_uncommitted?(path) do
      {:ok, false} ->
        if Worktree.in_progress_operation(path), do: {:error, :dirty_worktree}, else: :ok

      {:ok, true} ->
        {:error, :dirty_worktree}

      {:error, {:git_failed, msg}} ->
        {:error, {:git_failed, msg}}
    end
  end

  defp fetch_tips(path, branch, target) do
    case Worktree.fetch_origin_tips(path, Enum.uniq([branch, target])) do
      {:ok, tips} -> {:ok, tips}
      {:error, {:fetch_failed, msg}} -> {:error, {:fetch_failed, msg}}
    end
  end

  defp merge_target(path, target) do
    before = Worktree.head_sha(path)

    case git(path, ["merge", "--no-edit", "origin/" <> target], identity_env(path)) do
      {_out, 0} ->
        if Worktree.head_sha(path) == before, do: {:ok, :up_to_date}, else: {:ok, :synced}

      {out, _status} ->
        merge_failed(path, out)
    end
  end

  # A conflicting merge leaves MERGE_HEAD and unmerged paths; collect them and
  # put the worktree back before reporting. Any other failure is a git error.
  defp merge_failed(path, out) do
    if Worktree.in_progress_operation(path) == :merge do
      files = Worktree.unmerged_files(path)
      _ = Worktree.abort_in_progress(path)
      {:error, {:conflict, files}}
    else
      {:error, {:git_failed, String.trim(out)}}
    end
  end

  defp push(_path, _branch, :up_to_date), do: {:ok, :up_to_date}

  defp push(path, branch, :synced) do
    # No `--force`/`--force-with-lease`: the merge commit descends from the
    # remote tip we just aligned to, so this is a fast-forward or it fails.
    case git(path, ["push", "origin", "HEAD:refs/heads/" <> branch], []) do
      {_out, 0} ->
        {:ok, :synced}

      {out, _status} ->
        Logger.warning("BranchSync: push of #{branch} rejected: #{String.trim(out)}")
        {:error, {:push_failed, String.trim(out)}}
    end
  end

  # The merge commit needs a committer. A checkout that has none configured gets
  # Arbiter's, via the environment so no config is written.
  defp identity_env(path) do
    case git(path, ["config", "user.email"], []) do
      {email, 0} when email != "" and email != "\n" ->
        []

      _ ->
        [
          {"GIT_AUTHOR_NAME", "arbiter"},
          {"GIT_AUTHOR_EMAIL", "arbiter@localhost"},
          {"GIT_COMMITTER_NAME", "arbiter"},
          {"GIT_COMMITTER_EMAIL", "arbiter@localhost"}
        ]
    end
  end

  defp git(path, args, env) do
    PrivateClone.cmd(path, args, stderr_to_stdout: true, env: env)
  rescue
    e in ErlangError -> {Exception.message(e), 127}
  end
end
