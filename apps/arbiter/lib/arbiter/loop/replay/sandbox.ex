defmodule Arbiter.Loop.Replay.Sandbox do
  @moduledoc """
  The isolated checkout an offline replay runs in on the host (R15,
  bd-c7lx65; `docs/design/paced-quota-routing-signals.md` §7.2): the closed
  task's repo at its base commit, where nothing the replayed model does can
  reach the main repo, its remote or the merged change.

  `create/3` builds a repository of its own rather than a linked worktree. A
  linked worktree shares the main repo's refs and config: the merged change
  would be one `git log --all` away, and its `origin` one `git push` away. The
  sandbox instead

    * has its own `.git` holding **its own copy of the base's history**, and
      nothing else. It is built borrowing the main repo's objects through
      `objects/info/alternates`, then repacked and cut loose (what `git clone
      --dissociate` does), so no object after the base, the merged commit
      included, is in it even by id, and it reads nothing from the main repo
      (a jail that hides the main repo, as agy's does, leaves it working);
    * has exactly one ref, `refs/heads/work` at the base commit. The name is
      neutral: nothing in the checkout tells the replayed model it is
      re-running solved work;
    * has **no remote**, so `git push` and `git fetch` have nowhere to go;
    * carries a local identity, so the replayed model can commit.

  ## Host git after a replay

  The replayed model can write the sandbox's `.git`, and git runs programs a
  repository's own config names (an external diff, a filter driver, an
  included config). So every host-side git call after a replay is preceded by
  `verify/2` against the `seal/1` taken when the sandbox was built: the config
  is byte for byte the one the harness wrote, `.git` is still a directory, and
  nothing redirects it (`commondir`, `config.worktree`). Diffs also never run
  an external diff or a textconv, and host git runs with the server's secrets
  unset (`Arbiter.Worker.SpawnEnv`).

  It lives outside the worktree root, under the replay's own directory, and
  `remove/1` deletes it. Every git call goes through
  `Arbiter.Nodes.Checkout.Git` (the user's and system git config ignored, no
  hooks, no prompts).
  """

  alias Arbiter.Nodes.Checkout.Git
  alias Arbiter.Worker.SpawnEnv

  @branch "work"
  @no_remote "file:///dev/null/arbiter-replay-has-no-remote"

  @type change :: %{files: [String.t()], patch: String.t()}
  @type seal :: %{config: binary()}

  @doc "The one branch a sandbox has, checked out at the base commit."
  @spec branch() :: String.t()
  def branch, do: @branch

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
    alternates = Path.join([dir, ".git", "objects", "info", "alternates"])

    with :ok <- File.mkdir_p(dir),
         {:ok, _} <- Git.run(["init", "-q", "-b", @branch, dir]),
         :ok <- File.write(alternates, objects <> "\n"),
         {:ok, _} <- git(dir, ["update-ref", "refs/heads/" <> @branch, base_sha]),
         # Copy what the one ref reaches into the sandbox's own pack, then stop
         # borrowing: nothing after the base comes along.
         {:ok, _} <- git(dir, ["repack", "-a", "-d", "-q"]),
         :ok <- File.rm(alternates),
         {:ok, _} <- git(dir, ["reset", "-q", "--hard", base_sha]),
         {:ok, _} <- git(dir, ["config", "user.name", "arbiter replay"]),
         {:ok, _} <- git(dir, ["config", "user.email", "replay@arbiter.invalid"]),
         {:ok, _} <- git(dir, ["config", "commit.gpgsign", "false"]) do
      :ok
    end
  end

  @doc """
  What `verify/2` holds the sandbox at `dir` to: its `.git/config` as the
  harness left it. Take it once the harness is done configuring the sandbox,
  before any model runs in it.
  """
  @spec seal(Path.t()) :: seal()
  def seal(dir), do: %{config: config_digest(dir)}

  @doc """
  Whether host git may run in the sandbox at `dir`: `.git` is still a plain
  directory, its `config` is the sealed one, and no `commondir` or
  `config.worktree` redirects or extends it. `{:error, {:tampered, why}}`
  otherwise. Reads files only; runs no git.
  """
  @spec verify(Path.t(), seal()) :: :ok | {:error, {:tampered, String.t()}}
  def verify(dir, %{config: sealed}) do
    dot_git = Path.join(dir, ".git")

    cond do
      not match?({:ok, %File.Stat{type: :directory}}, File.lstat(dot_git)) ->
        tampered(".git is no longer a directory")

      not match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(dot_git, "config"))) ->
        tampered(".git/config is no longer a regular file")

      config_digest(dir) != sealed ->
        tampered(".git/config was changed after the sandbox was sealed")

      File.exists?(Path.join(dot_git, "commondir")) ->
        tampered(".git/commondir redirects the repository")

      File.exists?(Path.join(dot_git, "config.worktree")) ->
        tampered(".git/config.worktree extends the config")

      true ->
        :ok
    end
  end

  defp config_digest(dir) do
    case File.read(Path.join([dir, ".git", "config"])) do
      {:ok, body} -> :crypto.hash(:sha256, body)
      {:error, reason} -> {:unreadable, reason}
    end
  end

  defp tampered(why), do: {:error, {:tampered, why}}

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
  sandbox's own index is untouched. After a replay, call it only on a sandbox
  that `verify/2` passes.
  """
  @spec change(Path.t(), String.t()) :: {:ok, change()} | {:error, term()}
  def change(dir, base_sha) do
    index = Path.join([dir, ".git", "replay-change-#{System.unique_integer([:positive])}.index"])
    env = [{"GIT_INDEX_FILE", index}]

    try do
      with {:ok, _} <- git(dir, ["read-tree", "HEAD"], env),
           {:ok, _} <- git(dir, ["add", "-A"], env),
           {:ok, names} <- git(dir, diff(["--cached", "--name-only", "-z", base_sha]), env),
           {:ok, patch} <- git(dir, diff(["--cached", "--no-color", base_sha]), env) do
        {:ok, %{files: split_z(names), patch: patch}}
      end
    after
      File.rm(index)
    end
  end

  @doc """
  Whether the committed change, `base_sha..HEAD`, nets to nothing: the live
  ReviewGate's empty-net-diff guard, under which an APPROVE does not converge.
  After a replay, call it only on a sandbox that `verify/2` passes.
  """
  @spec committed_empty?(Path.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def committed_empty?(dir, base_sha) do
    case git(dir, diff(["--quiet", base_sha, "HEAD"])) do
      {:ok, _} -> {:ok, true}
      {:error, {:git, 1, _}} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  # A diff that runs no program the repository's config could name.
  defp diff(args), do: ["diff", "--no-ext-diff", "--no-textconv", "--no-renames" | args]

  @doc "The merged change in the main repo at `repo_path`: `base_sha..head_sha`."
  @spec known_good(Path.t(), String.t(), String.t()) :: {:ok, change()} | {:error, term()}
  def known_good(repo_path, base_sha, head_sha) do
    with {:ok, common} <- common_dir(repo_path),
         {:ok, names} <- Git.run(diff(["--name-only", "-z", base_sha, head_sha]), git_dir: common),
         {:ok, patch} <- Git.run(diff(["--no-color", base_sha, head_sha]), git_dir: common) do
      {:ok, %{files: split_z(names), patch: patch}}
    end
  end

  @doc """
  Point `origin` of the checkout at `dir` nowhere, for fetches as well as
  pushes. A container can only be handed an `Arbiter.Worker.PrivateClone`,
  whose review clone keeps the forge as `origin` for reads; a replay in one
  must not be able to fetch the merged change. (`PrivateClone.verify/1`
  accepts the URL keys, so the clone stays mountable.)
  """
  @spec disconnect(Path.t()) :: :ok | {:error, term()}
  def disconnect(dir) do
    case git(dir, ["config", "remote.origin.url", @no_remote]) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "The branch the checkout at `dir` has checked out."
  @spec current_branch(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def current_branch(dir), do: git(dir, ["symbolic-ref", "--short", "HEAD"])

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

  defp git(dir, args, env \\ []) do
    Git.run(args,
      git_dir: Path.join(dir, ".git"),
      work_tree: dir,
      cd: dir,
      env: scrubbed() ++ env
    )
  end

  # The server's own environment, unset for host git in a replay's checkout
  # (its secrets among it), leaving the GIT_* names `Checkout.Git` sets itself.
  defp scrubbed do
    []
    |> SpawnEnv.cmd_env(nil)
    |> Enum.reject(fn {name, _} -> String.starts_with?(name, "GIT_") end)
  end

  defp split_z(""), do: []
  defp split_z(out), do: out |> String.split(<<0>>, trim: true) |> Enum.sort()
end
