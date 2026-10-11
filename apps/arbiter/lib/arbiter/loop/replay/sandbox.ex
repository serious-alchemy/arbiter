defmodule Arbiter.Loop.Replay.Sandbox do
  @moduledoc """
  The isolated checkout an offline replay runs in (R15, bd-c7lx65;
  `docs/design/paced-quota-routing-signals.md` §7.2): the closed task's repo at
  its base commit, where nothing the replayed model does can reach the main
  repo, its remote or the merged change.

  `create/3` builds a repository of its own rather than a linked worktree. A
  linked worktree shares the main repo's refs and config: the merged change
  would be one `git log --all` away, and its `origin` one `git push` away. The
  sandbox instead

    * has its own `.git`, borrowing the main repo's objects read-only through
      `objects/info/alternates` (the pattern `Arbiter.Worker.PrivateClone`
      uses), so creating it copies nothing and anything it writes stays in its
      own object store;
    * has exactly one ref, `refs/heads/replay` at the base commit, so nothing
      after the base (the merged change included) is reachable from it;
    * has **no remote**, so `git push` and `git fetch` have nowhere to go;
    * carries a local identity, so the replayed model can commit.

  It lives outside the worktree root, under the replay's own directory, and
  `remove/1` deletes it. Every git call goes through
  `Arbiter.Nodes.Checkout.Git` (the user's and system git config ignored, no
  hooks, no prompts).
  """

  alias Arbiter.Nodes.Checkout.Git

  @branch "replay"

  @type change :: %{files: [String.t()], patch: String.t()}

  @doc """
  Build the sandbox at `dir` (which must not exist) from the repo checked out at
  `repo_path`, at `base_sha`. `{:error, {:unknown_commit, sha}}` when the main
  repo does not have the commit; a half-built sandbox is removed.
  """
  @spec create(Path.t(), String.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def create(repo_path, base_sha, dir) do
    with :ok <- absent(dir),
         {:ok, common} <- common_dir(repo_path),
         :ok <- commit?(common, base_sha) do
      case build(Path.join(common, "objects"), base_sha, dir) do
        :ok ->
          {:ok, dir}

        {:error, _} = error ->
          remove(dir)
          error
      end
    end
  end

  defp build(objects, base_sha, dir) do
    git_dir = Path.join(dir, ".git")

    with :ok <- File.mkdir_p(dir),
         {:ok, _} <- Git.run(["init", "-q", "-b", @branch, dir]),
         :ok <- File.write(Path.join([git_dir, "objects", "info", "alternates"]), objects <> "\n"),
         {:ok, _} <- git(dir, ["update-ref", "refs/heads/" <> @branch, base_sha]),
         {:ok, _} <- git(dir, ["reset", "-q", "--hard", base_sha]),
         {:ok, _} <- git(dir, ["config", "user.name", "arbiter replay"]),
         {:ok, _} <- git(dir, ["config", "user.email", "replay@arbiter.invalid"]),
         {:ok, _} <- git(dir, ["config", "commit.gpgsign", "false"]) do
      :ok
    end
  end

  @doc """
  Add `paths` to the sandbox's own `info/exclude` (never the main repo's): the
  dependency trees seeded into it, so `change/2` does not read them as the
  replay's work.
  """
  @spec exclude(Path.t(), [String.t()]) :: :ok | {:error, term()}
  def exclude(_dir, []), do: :ok

  def exclude(dir, paths) do
    file = Path.join([dir, ".git", "info", "exclude"])

    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, Enum.map_join(paths, "", &("/" <> String.trim_leading(&1, "/") <> "\n")), [
        :append
      ])
    end
  end

  @doc """
  Everything the replay changed against `base_sha`: committed, staged,
  unstaged and untracked (but not ignored or excluded) files, as the sorted
  list of paths and the unified diff. Read through a scratch index, so the
  sandbox's own index is untouched.
  """
  @spec change(Path.t(), String.t()) :: {:ok, change()} | {:error, term()}
  def change(dir, base_sha) do
    index = Path.join([dir, ".git", "replay-change-#{System.unique_integer([:positive])}.index"])
    env = [{"GIT_INDEX_FILE", index}]

    try do
      with {:ok, _} <- git(dir, ["read-tree", "HEAD"], env),
           {:ok, _} <- git(dir, ["add", "-A"], env),
           {:ok, names} <-
             git(dir, ["diff", "--cached", "--name-only", "-z", "--no-renames", base_sha], env),
           {:ok, patch} <-
             git(dir, ["diff", "--cached", "--no-color", "--no-renames", base_sha], env) do
        {:ok, %{files: split_z(names), patch: patch}}
      end
    after
      File.rm(index)
    end
  end

  @doc """
  Whether the committed change, `base_sha..HEAD`, nets to nothing: the live
  ReviewGate's empty-net-diff guard, under which an APPROVE does not converge.
  """
  @spec committed_empty?(Path.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def committed_empty?(dir, base_sha) do
    case git(dir, ["diff", "--quiet", base_sha, "HEAD"]) do
      {:ok, _} -> {:ok, true}
      {:error, {:git, 1, _}} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  @doc "The merged change in the main repo at `repo_path`: `base_sha..head_sha`."
  @spec known_good(Path.t(), String.t(), String.t()) :: {:ok, change()} | {:error, term()}
  def known_good(repo_path, base_sha, head_sha) do
    with {:ok, common} <- common_dir(repo_path),
         {:ok, names} <-
           Git.run(["diff", "--name-only", "-z", "--no-renames", base_sha, head_sha],
             git_dir: common
           ),
         {:ok, patch} <-
           Git.run(["diff", "--no-color", "--no-renames", base_sha, head_sha], git_dir: common) do
      {:ok, %{files: split_z(names), patch: patch}}
    end
  end

  @doc "Delete the sandbox. Idempotent."
  @spec remove(Path.t()) :: :ok
  def remove(dir) do
    File.rm_rf(dir)
    :ok
  end

  @doc """
  The main repo's common git dir (the one holding its objects and refs), for
  the checkout at `repo_path`, linked worktree or not.
  """
  @spec common_dir(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def common_dir(repo_path) do
    if File.dir?(repo_path) do
      case Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cd: repo_path) do
        {:ok, dir} -> {:ok, dir}
        {:error, {:git, _, out}} -> {:error, {:not_a_repo, repo_path, out}}
      end
    else
      {:error, {:not_a_repo, repo_path, "no such directory"}}
    end
  end

  defp absent(dir), do: if(File.exists?(dir), do: {:error, {:exists, dir}}, else: :ok)

  defp commit?(common, sha) do
    if Git.exists?(common, sha <> "^{commit}"), do: :ok, else: {:error, {:unknown_commit, sha}}
  end

  defp git(dir, args, env \\ []),
    do: Git.run(args, git_dir: Path.join(dir, ".git"), work_tree: dir, cd: dir, env: env)

  defp split_z(""), do: []
  defp split_z(out), do: out |> String.split(<<0>>, trim: true) |> Enum.sort()
end
