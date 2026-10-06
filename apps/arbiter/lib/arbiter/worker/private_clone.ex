defmodule Arbiter.Worker.PrivateClone do
  @moduledoc """
  Git layout B for container workers (bd-4wy1w1, P5 of
  `docs/design/podman-worker-containers.md` §3.2): a private checkout with its
  **own** `.git` directory that borrows the main repo's objects read-only
  through `objects/info/alternates`, in place of a linked worktree registered
  in the main repo.

  A linked worktree keeps its refs, config and hooks in the main repo's common
  dir, so a container would need that dir mounted read-write, and the P1 spike
  showed a worker could then rewrite a sibling's branch. A private clone owns
  its refs: nothing it writes reaches the main repo until Arbiter fetches its
  branch back (`sync_back/1`).

  ## Shape

  `create/3` builds what `git clone --shared` would, by hand, so that only the
  base ref is copied (a `--shared` clone copies every main branch as an
  `origin/*` ref and points `origin` at the main checkout):

    * the checkout lives at `Worktree.worktree_path(branch)`, the leaf a linked
      worktree would use, so every consumer that derives the path from the
      branch finds it;
    * `.git/objects/info/alternates` names the main repo's objects dir; the
      clone's own store starts empty;
    * `origin` is the main repo's `origin` URL (the forge) and the clone has
      `origin/<base>` plus a local `<base>`, so every host-side read that ran
      in a linked worktree (ReviewGate's push gate, `update_from_target`,
      MergeQueue's push and rebase) runs unchanged;
    * the branch starts at `origin/<base>`, freshly fetched in the main repo,
      or at the main repo's own `<branch>` when it already has one;
    * `arbiter.mainRepo`, `arbiter.branch` and `arbiter.base` in the clone's
      config name where it came from (`clone?/1`, `main_repo/1`).

  ## Sync-back

  `sync_back/1` fetches the clone's branch into the main repo
  (`+refs/heads/<branch>:refs/heads/<branch>`): the ref and the objects the
  worker created. After it, everything that reads the branch by name in the
  main repo (the Direct merger, GitLab's open, the conflict resolver's
  divergence check, close-time branch reaping) sees what a linked worktree
  would have shown it. `remove/1` syncs back before deleting, so a branch
  outlives its checkout as it does in layout A.

  ## Pins, against gc in the main repo

  The clone reads borrowed objects from the main repo's store, which `git gc`
  may prune once nothing in the main repo reaches them (a rewritten or
  deleted ref). So the main repo keeps refs under
  `refs/arbiter/workers/<leaf>/` while the clone lives: `base` (the commit it
  started from), `target` (its `origin/<base>`) and `head` (its branch at the
  last sync-back). `core.alternateRefsPrefixes` limits the alternate refs a
  host-side fetch in the clone may treat as "already have" to those pins, so
  fetch negotiation does not start borrowing history only a sibling's branch
  reaches. `remove/1` deletes the pins after the directory is gone.

  ## What a container may write

  Host-side git keeps running in this checkout after a container worker has
  had it (the push gate, merges, `leftover_work/2`), so a planted hook,
  `core.fsmonitor`, alternates path or `commondir` would run on the host. The
  same holes are what `Arbiter.Worker.Jail` closes for a linked worktree.
  `mounts/1` returns the container mount set that closes them: the checkout
  and its `.git` (a mount point of its own, so it cannot be renamed or
  replaced by a `gitdir:` file) read-write, `config`, `hooks`, `commondir` and
  `objects/info/alternates` read-only on top, and the main repo's objects as
  an overlay. `create/3` writes `commondir` itself, as `"."` (the gitdir
  itself, which git treats exactly like no file at all), so there is a file
  to make read-only.

  ## When `.git` is swapped anyway (bd-6t7u81, #390)

  The mount of `.git` itself is what stops a worker renaming it away
  (`mv .git .git2`) and recreating one with its own `config` and `hooks`. A
  layout without that mount (a node-side or cluster shadow clone, a regression
  in the mount set) loses that, and every host-side git in the tree would then
  read the worker's `core.fsmonitor`, `core.hooksPath` or hooks. So the host
  does not take the directory on trust:

    * `create/3` records the `.git` directory's identity (device and inode) in
      the **main repo** (`<common-dir>/arbiter-clones/<leaf>`, which no
      container mounts writable), the one place the worker's config edits
      cannot reach;
    * `verify/1` accepts a `.git` only if it is the recorded directory, its
      `config` holds nothing but the keys `create/3` and the host's own pushes
      write (no `core.fsmonitor`, `core.hooksPath`, `filter.*`, transport-helper
      urls, ...), and its `hooks/` holds no hook. `mounts/1`, `sync_back/1`,
      `refresh_base/2` and `Worktree`'s own git calls in a clone run it first;
    * `cmd/3` runs a host-side git in a worker checkout behind `guard/1` (the
      ReviewGate's diff and status, the mergers, `PushState`, the commit gate's
      status and fingerprint all do);
    * `settle/1` runs when the worker signals `arb done`, with its container
      stopped and before the commit gate: it puts the recorded directory back,
      sets an impostor aside as `.git.tampered`, and the run fails
      `:tampered_clone` instead of routing the tree on to review or merge.
      `reclaim/1` is the same undo at a container's teardown.

  A git the host runs through none of these (a call site added later that uses
  `System.cmd("git", ...)` directly in a worker checkout) is not covered: use
  `cmd/3`. Between `settle/1` and a later `cmd/3` the worker has nothing
  running (its container is removed first), so the check is not racing it.
  """

  require Logger

  alias Arbiter.MCP.AgentConfig
  alias Arbiter.Worker.Worktree

  @pin_root "refs/arbiter/workers/"
  @commondir_guard ".\n"
  @lock_retries 3

  # Passed to the git that reads a clone's config (an upload-pack, started by a
  # fetch from it) as a belt over `verify/1`'s braces: command-line config
  # outranks the repo's own and reaches the upload-pack it spawns.
  @safe_config [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.alternateRefsCommand="
  ]

  @typedoc "Absolute path to a private clone (or a candidate)."
  @type path :: String.t()

  # -- create / attach ------------------------------------------------------------

  @doc """
  Create (or reuse) the private clone for `branch` of `repo_path`, cut from
  the freshly fetched `origin/<base_branch>`, or from `repo_path`'s own
  `<branch>` when it has one (a redispatch after a sync-back, where layout A
  would `attach/2` to the surviving branch). Same fetch-first guarantee as
  `Worktree.create/3`: a missing `origin` or base aborts.

  Idempotent for a clone already on `branch`. A clone whose provisioning was
  interrupted (no branch checked out) is rebuilt. Anything else at the leaf
  is refused: a linked worktree (`{:layout_mismatch, path}`), or a clone on a
  different branch (the same "different branch" error as `Worktree.create/3`,
  which `Dispatch` already knows how to recover from for a detached tree).
  """
  @spec create(path(), String.t() | nil, String.t(), [String.t()] | nil) ::
          {:ok, path()} | {:error, term()}
  def create(repo_path, branch, base_branch, seed_paths \\ nil)

  def create(_repo_path, branch, _base_branch, _seed_paths) when branch in [nil, ""],
    do: {:error, :invalid_branch_name}

  def create(repo_path, branch, base_branch, seed_paths)
      when is_binary(repo_path) and is_binary(branch) and is_binary(base_branch) do
    open(branch, fn path ->
      provision_new(repo_path, path, branch, base_branch, seed_paths)
    end)
  end

  @doc """
  Create (or reuse) the private clone for an **existing** `branch` of
  `repo_path`: its local `<branch>`, else its `origin/<branch>` (tracked, as
  `git worktree add <path> <branch>` does). Never cuts a new branch; a name
  the main repo does not know is an error. With `base_branch`, the main
  repo's current `origin/<base_branch>` is copied in as well (no fetch, as
  `Worktree.attach/2` does none).
  """
  @spec attach(path(), String.t() | nil, String.t() | nil, [String.t()] | nil) ::
          {:ok, path()} | {:error, term()}
  def attach(repo_path, branch, base_branch \\ nil, seed_paths \\ nil)

  def attach(_repo_path, branch, _base_branch, _seed_paths) when branch in [nil, ""],
    do: {:error, :invalid_branch_name}

  def attach(repo_path, branch, base_branch, seed_paths)
      when is_binary(repo_path) and is_binary(branch) do
    open(branch, fn path ->
      provision_attached(repo_path, path, branch, base_branch, seed_paths)
    end)
  end

  defp open(branch, provision) do
    path = Worktree.worktree_path(branch)

    cond do
      not File.exists?(path) -> provision.(path)
      clone?(path) -> reuse(path, branch, provision)
      true -> {:error, {:layout_mismatch, path}}
    end
  end

  defp reuse(path, branch, provision) do
    # A worker's swapped `.git` is put right (or refused) before any git runs in it.
    _ = reclaim(path)

    with :ok <- verify(path), do: reuse_verified(path, branch, provision)
  end

  defp reuse_verified(path, branch, provision) do
    case Worktree.checked_out_branch(path) do
      {:ok, ^branch} ->
        {:ok, path}

      {:ok, _other} ->
        {:error, {:git_failed, "worktree exists at #{path} on a different branch"}}

      {:error, _} ->
        # No readable HEAD: a provision cut short before its checkout. Nothing
        # ran in it, so rebuild it rather than strand every later dispatch.
        Logger.info("PrivateClone: rebuilding the unfinished clone at #{path}")

        with :ok <- remove(path), do: provision.(path)
    end
  end

  defp provision_new(repo, path, branch, base, seed_paths) do
    with :ok <- Worktree.fetch_origin(repo, base),
         {:ok, base_sha} <- origin_ref(repo, base) do
      checkout_from =
        case local_branch_sha(repo, branch) do
          # A fresh branch is cut from `origin/<base>` by name so it tracks it,
          # as `git worktree add -b <branch> <path> origin/<base>` does.
          nil -> "origin/" <> base
          sha -> sha
        end

      provision(%{
        repo: repo,
        path: path,
        branch: branch,
        base: base,
        base_sha: base_sha,
        start: resolve!(checkout_from, base_sha),
        checkout_from: checkout_from,
        remote_refs: [{"refs/remotes/origin/" <> base, base_sha}],
        seed_paths: seed_paths
      })
    end
  end

  defp provision_attached(repo, path, branch, base, seed_paths) do
    base_sha = base && rev(repo, "refs/remotes/origin/#{base}")
    base_refs = if base_sha, do: [{"refs/remotes/origin/" <> base, base_sha}], else: []

    {start, checkout_from, branch_refs} =
      case {local_branch_sha(repo, branch), rev(repo, "refs/remotes/origin/#{branch}")} do
        {sha, _} when is_binary(sha) ->
          {sha, sha, []}

        {nil, sha} when is_binary(sha) ->
          {sha, "origin/" <> branch, [{"refs/remotes/origin/" <> branch, sha}]}

        {nil, nil} ->
          {nil, nil, []}
      end

    if start do
      provision(%{
        repo: repo,
        path: path,
        branch: branch,
        base: base_sha && base,
        base_sha: base_sha,
        start: start,
        checkout_from: checkout_from,
        remote_refs: base_refs ++ branch_refs,
        seed_paths: seed_paths
      })
    else
      {:error, {:git_failed, "invalid reference: #{branch} (not in #{repo})"}}
    end
  end

  defp resolve!("origin/" <> _, base_sha), do: base_sha
  defp resolve!(sha, _base_sha), do: sha

  defp provision(%{repo: repo, path: path, branch: branch} = plan) do
    with {:ok, objects} <- objects_dir(repo),
         {:ok, format} <- object_format(repo) do
      File.mkdir_p!(Path.dirname(path))
      plan = Map.merge(plan, %{leaf: Path.basename(path), objects: objects, format: format})

      case build(plan) do
        :ok ->
          :ok = Worktree.seed_compiled_deps(repo, path, plan.seed_paths)
          :ok = Worktree.ensure_deps_fetched(path)
          _ = AgentConfig.add_to_git_exclude(path, [".arbiter/"])
          Logger.info("PrivateClone: created #{path} (#{branch} of #{repo})")
          {:ok, path}

        {:error, _} = error ->
          discard(plan)
          error
      end
    end
  end

  # The order matters: the marker first (so even a clone cut short here is
  # recognisably ours), the pins before anything in the clone points at a
  # borrowed object, the checkout last.
  defp build(plan) do
    %{path: path, repo: repo, leaf: leaf} = plan
    dot_git = Path.join(path, ".git")

    with {:ok, _} <-
           git(["init", "-q", "-b", plan.branch, "--object-format=" <> plan.format, path],
             cd: Path.dirname(path)
           ),
         :ok <- set_markers(path, repo, plan.branch, plan.base),
         :ok <- record_identity(repo, path, leaf),
         :ok <- record_ledger(path, repo),
         :ok <- File.write(Path.join(dot_git, "objects/info/alternates"), plan.objects <> "\n"),
         :ok <- File.write(Path.join(dot_git, "commondir"), @commondir_guard),
         :ok <- File.mkdir_p(Path.join(dot_git, "hooks")),
         :ok <- configure(repo, path, leaf),
         :ok <- pin(repo, leaf, "base", plan.start),
         :ok <- if(plan.base_sha, do: pin(repo, leaf, "target", plan.base_sha), else: :ok),
         :ok <- update_refs(path, plan.remote_refs),
         {:ok, _} <- git(["checkout", "-q", "-B", plan.branch, plan.checkout_from], cd: path),
         :ok <- local_base(plan) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, {:git_failed, inspect(reason)}}
      {:error, _} = error -> error
    end
  end

  defp set_markers(path, repo, branch, base) do
    [{"arbiter.mainRepo", Path.expand(repo)}, {"arbiter.branch", branch}, {"arbiter.base", base}]
    |> Enum.reject(&is_nil(elem(&1, 1)))
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      case git(["config", key, value], cd: path) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp update_refs(path, refs) do
    Enum.reduce_while(refs, :ok, fn {ref, sha}, :ok ->
      case git(["update-ref", ref, sha], cd: path) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A linked worktree resolves a bare `<base>` (`git log <base>..HEAD`, the
  # Driver's `has_commits_ahead?(path, "main")`) through the main repo's refs.
  defp local_base(%{base: nil}), do: :ok
  defp local_base(%{branch: branch, base: base}) when branch == base, do: :ok

  defp local_base(%{path: path, base: base, base_sha: sha}) do
    with {:ok, _} <- git(["update-ref", "refs/heads/" <> base, sha], cd: path), do: :ok
  end

  # `origin` is the main repo's forge remote, so host-side fetches, pushes and
  # `ls-remote`s from the clone go where a linked worktree's went. The commit
  # identity is copied in so a container, which sees no global git config,
  # can still commit.
  defp configure(repo, path, leaf) do
    with :ok <- copy_origin(repo, path),
         :ok <- copy_effective(repo, path, "user.name"),
         :ok <- copy_effective(repo, path, "user.email"),
         {:ok, _} <-
           git(["config", "core.alternateRefsPrefixes", pin_prefix(leaf)], cd: path) do
      :ok
    end
  end

  # A main repo with no `origin` (a local-only repo `attach/3` still serves;
  # `create/3` has already refused one) leaves the clone without one too, as a
  # linked worktree of it would be.
  defp copy_origin(repo, path) do
    case git(["remote", "get-url", "origin"], cd: repo) do
      {:ok, url} ->
        with {:ok, _} <- git(["remote", "add", "origin", String.trim(url)], cd: path),
             do: copy_pushurls(repo, path)

      {:error, _} ->
        :ok
    end
  end

  # The value git would use in the main repo (local over global), set once.
  defp copy_effective(repo, path, key) do
    case git(["config", "--get", key], cd: repo) do
      {:ok, value} ->
        with {:ok, _} <- git(["config", key, String.trim(value)], cd: path), do: :ok

      # Unset in the main repo and globally: nothing to copy.
      {:error, _} ->
        :ok
    end
  end

  # `pushurl` is a list, and only the main repo's own entries belong to its
  # `origin`.
  defp copy_pushurls(repo, path) do
    case git(["config", "--local", "--get-all", "remote.origin.pushurl"], cd: repo) do
      {:ok, values} ->
        values
        |> String.split("\n", trim: true)
        |> Enum.reduce_while(:ok, fn value, :ok ->
          case git(["config", "--add", "remote.origin.pushurl", value], cd: path) do
            {:ok, _} -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  defp discard(%{repo: repo, path: path, leaf: leaf}) do
    _ = File.rm_rf(path)
    unpin(repo, leaf)
  end

  # -- identity -----------------------------------------------------------------

  @doc """
  Whether `path` is a private clone made by `create/3`: its `.git` is a real
  directory (not a `gitdir:` file or a symlink) whose config names a main
  repo. Reads the config file directly, never through `commondir`.
  """
  @spec clone?(term()) :: boolean()
  def clone?(path) when is_binary(path), do: marker(path, "mainRepo") != nil
  def clone?(_), do: false

  @doc "The main repo a private clone borrows from, or `nil` for anything else."
  @spec main_repo(term()) :: path() | nil
  def main_repo(path) when is_binary(path), do: marker(path, "mainRepo")
  def main_repo(_), do: nil

  @doc "The task branch a private clone was made for, or `nil`."
  @spec branch(term()) :: String.t() | nil
  def branch(path) when is_binary(path), do: marker(path, "branch")
  def branch(_), do: nil

  defp marker(path, key) do
    dot_git = Path.join(path, ".git")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dot_git),
         {:ok, value} <-
           git(["config", "--file", Path.join(dot_git, "config"), "--get", "arbiter." <> key],
             cd: nil
           ),
         value when value != "" <- String.trim(value) do
      value
    else
      _ -> nil
    end
  end

  @doc """
  The private clones of `repo_path` under the worktree root, as
  `%{path: path, branch: branch}` (`Worktree.list/1`'s shape). Only leaves
  whose `.git` is a directory are read, so linked worktrees cost an `lstat`.
  """
  @spec list(path()) :: [%{path: path(), branch: String.t() | nil}]
  def list(repo_path) when is_binary(repo_path) do
    root = Arbiter.Config.Paths.worktree_root()
    repo = Path.expand(repo_path)

    case File.ls(root) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            path = Path.join(root, name),
            match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(path, ".git"))),
            main_repo(path) == repo,
            do: %{path: path, branch: branch(path)}

      {:error, _} ->
        []
    end
  end

  # -- sync-back ------------------------------------------------------------------

  @doc """
  Fetch the clone's branch into its main repo: `refs/heads/<branch>` there is
  force-updated to the clone's tip (the clone is the branch's only writer, as
  a linked worktree is), the objects come with it, and the `head` and
  `target` pins move along. The clone's `origin/<branch>` (what its pushes
  reached) is carried into the main repo's, fast-forward only. Returns the
  synced sha.
  """
  @spec sync_back(path()) :: {:ok, String.t()} | {:error, term()}
  def sync_back(path) when is_binary(path) do
    with {:ok, repo, branch} <- trusted_identity(path) do
      leaf = Path.basename(path)

      refspecs = [
        "+refs/heads/#{branch}:refs/heads/#{branch}",
        "+refs/heads/#{branch}:" <> pin_ref(leaf, "head")
      ]

      with {:ok, _} <- fetch_into(repo, path, refspecs),
           {:ok, sha} <- git(["rev-parse", "refs/heads/" <> branch], cd: repo) do
        carry_remote_ref(repo, path, branch)
        repin_target(repo, path, leaf)
        {:ok, String.trim(sha)}
      else
        {:error, {:git_failed, msg}} -> {:error, {:sync_back_failed, msg}}
      end
    end
  end

  defp identity(path) do
    repo = main_repo(path)
    branch = branch(path)

    if is_binary(repo) and is_binary(branch) and File.dir?(repo),
      do: {:ok, repo, branch},
      else: {:error, :not_a_private_clone}
  end

  # `identity/1` for a git that is about to run in the clone: the same, once
  # the clone's `.git` has been verified.
  defp trusted_identity(path) do
    with {:ok, repo, branch} <- identity(path),
         :ok <- verify(path),
         do: {:ok, repo, branch}
  end

  @doc """
  Copy the main repo's current `origin/<base>` into the clone (and re-pin
  it), so the clone's `origin/<base>` means what it means in a linked
  worktree, which shares the main repo's refs: whatever the main repo last
  fetched. For callers that decide something from a fresh main-repo fetch
  (`Worktree.reset_if_merged/4`). `base` defaults to the one the clone was
  cut from; `:ok` when there is neither.
  """
  @spec refresh_base(path(), String.t() | nil) :: :ok | {:error, term()}
  def refresh_base(path, base \\ nil) when is_binary(path) do
    with {:ok, repo, _branch} <- trusted_identity(path) do
      case base || marker(path, "base") do
        nil -> :ok
        base -> copy_ref(repo, path, Path.basename(path), base)
      end
    end
  end

  defp copy_ref(repo, path, leaf, base) do
    case rev(repo, "refs/remotes/origin/" <> base) do
      nil ->
        {:error, {:missing_origin_ref, "origin/#{base} does not resolve in #{repo}"}}

      sha ->
        with :ok <- pin(repo, leaf, "target", sha),
             {:ok, _} <- git(["update-ref", "refs/remotes/origin/" <> base, sha], cd: path),
             do: :ok
    end
  end

  # A push from a linked worktree moves the main repo's own
  # `origin/<branch>`, which is how close-time reaping (`leftover_work/2`,
  # `delete_merged_branch/3`) knows the commits are on the forge. A clone's
  # push moves only the clone's copy, so carry it over: fast-forward only (no
  # `+`), so a newer view the main repo fetched itself is never rolled back.
  # Best-effort, like the main repo's own next fetch that would correct it.
  defp carry_remote_ref(repo, path, branch) do
    ref = "refs/remotes/origin/" <> branch

    if rev(path, ref), do: _ = fetch_into(repo, path, ["#{ref}:#{ref}"])
    :ok
  end

  # Best-effort: a clone without an `origin/<base>` (deleted by the worker) just
  # keeps its previous `target` pin.
  defp repin_target(repo, path, leaf) do
    case marker(path, "base") do
      nil ->
        :ok

      base ->
        _ = fetch_into(repo, path, ["+refs/remotes/origin/#{base}:" <> pin_ref(leaf, "target")])
        :ok
    end
  end

  # Upload-pack runs in the clone, reading only its own (host-written,
  # container-read-only) config. Two syncs of one clone racing for the same ref
  # lock retry rather than fail.
  defp fetch_into(repo, path, refspecs, attempt \\ 1) do
    args =
      @safe_config ++
        [
          "fetch",
          "--quiet",
          "--no-tags",
          "--no-write-fetch-head",
          "--no-recurse-submodules",
          path
        ] ++ refspecs

    case git(args, cd: repo) do
      {:error, {:git_failed, msg}} = error ->
        if attempt < @lock_retries and lock_contention?(msg),
          do: fetch_into(repo, path, refspecs, attempt + 1),
          else: error

      other ->
        other
    end
  end

  defp lock_contention?(msg),
    do: String.contains?(msg, "cannot lock ref") or String.contains?(msg, ".lock")

  # -- removal --------------------------------------------------------------------

  @doc """
  Remove a private clone: sync its branch back (best-effort; a clone whose
  branch is gone is still removed), delete the directory, then drop its pins.
  `:ok` when nothing is there.
  """
  @spec remove(path()) :: :ok | {:error, term()}
  def remove(path) when is_binary(path) do
    cond do
      not File.exists?(path) ->
        :ok

      clone?(path) ->
        repo = main_repo(path)
        leaf = Path.basename(path)
        maybe_sync_back(path)

        case File.rm_rf(path) do
          {:ok, _} ->
            if File.dir?(repo), do: unpin(repo, leaf)
            _ = File.rm(ledger_file(path))
            Logger.info("PrivateClone: removed #{path}")
            :ok

          {:error, reason, file} ->
            {:error, {:git_failed, "rm_rf failed at #{file}: #{inspect(reason)}"}}
        end

      true ->
        {:error, :not_a_private_clone}
    end
  end

  # A clone with no branch (a provision cut short, or a worker that deleted it)
  # has nothing to carry back.
  defp maybe_sync_back(path) do
    with branch when is_binary(branch) <- branch(path),
         sha when is_binary(sha) <- local_branch_sha(path, branch),
         {:error, reason} <- sync_back(path) do
      Logger.warning(
        "PrivateClone: could not sync #{path} back before removing it: #{inspect(reason)}"
      )
    end

    :ok
  end

  # -- the container mount set --------------------------------------------------------

  @readonly_in_git_dir ~w(config hooks commondir objects/info/alternates)

  @doc """
  The `Arbiter.Worker.Container.wrap/2` mount options for running a worker in
  the private clone at `path`: `:worktree`, `:git_dir`, `:objects` (the main
  repo's objects dir, which `Container` mounts as an overlay) and
  `:readonly_paths` (`.git/config`, `hooks`, `commondir` and
  `objects/info/alternates`).

  Refuses anything that is not a private clone, and a clone whose alternates
  no longer name its main repo's objects or whose `.git` is not a plain
  directory (`{:tampered, why}`): a container is only ever handed the layout
  `create/3` built.
  """
  @spec mounts(path()) :: {:ok, keyword()} | {:error, term()}
  def mounts(path) when is_binary(path) do
    dot_git = Path.join(path, ".git")

    with {:ok, repo, _branch} <- trusted_identity(path),
         {:ok, objects} <- objects_dir(repo),
         # Every clone a container is handed is on the ledger (one made before
         # the ledger existed gets its entry here), so `guard/1` knows it.
         :ok <- record_ledger(path, repo),
         :ok <- check_alternates(dot_git, objects),
         readonly = Enum.map(@readonly_in_git_dir, &Path.join(dot_git, &1)),
         :ok <- check_guards(readonly) do
      {:ok, [worktree: path, git_dir: dot_git, objects: objects, readonly_paths: readonly]}
    end
  end

  defp check_alternates(dot_git, objects) do
    case File.read(Path.join(dot_git, "objects/info/alternates")) do
      {:ok, contents} ->
        if String.split(contents, "\n", trim: true) == [objects],
          do: :ok,
          else: {:error, {:tampered, "objects/info/alternates no longer names #{objects}"}}

      {:error, reason} ->
        {:error, {:tampered, "objects/info/alternates unreadable: #{inspect(reason)}"}}
    end
  end

  defp check_guards(paths) do
    case Enum.reject(paths, &match?({:ok, %File.Stat{}}, File.lstat(&1))) do
      [] ->
        if File.read(Enum.find(paths, &String.ends_with?(&1, "/commondir"))) ==
             {:ok, @commondir_guard},
           do: :ok,
           else: {:error, {:tampered, "commondir is not the \".\" guard"}}

      missing ->
        {:error, {:tampered, "missing #{Enum.join(missing, ", ")}"}}
    end
  end

  # -- verifying the .git directory --------------------------------------------------------

  @tampered_suffix ".git.tampered"

  # The keys `create/3` writes, and the host's own `push -u` / checkout adds.
  # Everything else a config can carry that git acts on (`core.fsmonitor`,
  # `core.hooksPath`, `core.sshCommand`, `core.pager`, `filter.*`, `diff.*`,
  # `include.*`, `core.worktree`, `credential.*`, `remote.*.uploadpack`, ...)
  # is refused by omission.
  @config_keys ~w(
    core.repositoryformatversion core.filemode core.bare core.logallrefupdates core.symlinks
    core.ignorecase core.precomposeunicode core.alternaterefsprefixes extensions.objectformat
    user.name user.email commit.gpgsign remote.origin.fetch remote.origin.tagopt
  )
  @branch_key ~r/^branch\..+\.(remote|merge|rebase|pushremote)$/
  @url_keys ~w(remote.origin.url remote.origin.pushurl)
  @transport_helper ~r/^[A-Za-z0-9][A-Za-z0-9+.-]*::/

  @doc """
  Whether the clone's `.git` is the one `create/3` built and the host may run
  git in: the directory whose identity `create/3` recorded in the main repo (a
  clone with no record, from before the record existed, is judged on content
  alone), a plain directory with a regular-file `config` holding only the keys
  the host writes (never one git would execute something for) and a `hooks/`
  with no hook in it, and no `config.worktree`.

  `{:error, {:tampered, why}}` for a clone that fails; `{:error,
  :not_a_private_clone}` for a path whose `.git` names no main repo. Reads the
  config as data (`git config --file`), which executes nothing.
  """
  @spec verify(path()) :: :ok | {:error, {:tampered, String.t()} | :not_a_private_clone}
  def verify(path) when is_binary(path) do
    dot_git = Path.join(path, ".git")

    with :ok <- check_dot_git_dir(dot_git),
         repo when is_binary(repo) <- marker(path, "mainRepo") || {:error, :not_a_private_clone},
         :ok <- check_recorded(repo, Path.basename(path), dot_git),
         :ok <- check_config_file(dot_git),
         :ok <- check_config_keys(dot_git),
         :ok <- check_hooks_dir(dot_git) do
      check_commondir(dot_git)
    end
  end

  @doc """
  `verify/1` for a git about to run in `path`, when `path` is a checkout leaf
  of the worktree root (a private clone, or something posing as one). A `.git`
  directory must verify (one that names no main repo is refused too). A
  `.git` file or symlink at a leaf that is on the private-clone ledger
  (`ledgered?/1`: `create/3` built it, or a container was handed it) is refused
  whatever it says, since a worker can write a `gitdir:` file naming a fake
  `<repo>/.git/worktrees/<name>` in any directory it can write, and nothing in
  such a file shows the repo is not the worker's. At a leaf that was never a
  private clone (a layout-A linked worktree, which no container is handed) a
  `.git` file is accepted when its `gitdir:` names a
  `<repo>/.git/worktrees/<name>` outside the checkout (`linked_gitdir/1`); a
  `.git` symlink is refused outright. `:ok` for a path that is not a checkout
  leaf (a repo outside the root is not a worker's) or has no `.git` at all.
  """
  @spec guard(term()) :: :ok | {:error, {:tampered, String.t()}}
  def guard(path) when is_binary(path) do
    with true <- checkout_leaf?(path),
         {:ok, %File.Stat{type: type}} <- File.lstat(Path.join(path, ".git")) do
      case type do
        :directory ->
          case verify(path) do
            {:error, :not_a_private_clone} -> tampered(".git names no main repo")
            other -> other
          end

        :regular ->
          if ledgered?(path),
            do: tampered(".git is a file, and this checkout is a private clone"),
            else: linked_gitdir(path)

        other ->
          tampered(".git is a #{other}, not a directory or a worktree file")
      end
    else
      _ -> :ok
    end
  end

  def guard(_), do: :ok

  @doc """
  `System.cmd("git", args, [cd: path] ++ opts)` for host-side git run in a
  worker's checkout: `guard/1` first, so a worker's replacement `.git` (whose
  config would make `git status` / `git diff` run `core.fsmonitor`, a diff or
  textconv driver, or a hook) is never run git in. A refused path answers like
  a failed git (`{message, 128}`), so a caller's non-zero branch handles it
  and a gate built on the answer cannot read it as a pass. Every host-side
  git that runs in a worker checkout goes through this or `Worktree`'s runner
  (bd-6t7u81).
  """
  @spec cmd(term(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(path, args, opts \\ []) when is_list(args) do
    case guard(path) do
      :ok ->
        System.cmd("git", args, [cd: path] ++ opts)

      {:error, {:tampered, why}} ->
        {"refusing to run git in #{path}: .git is not the one it was created with (#{why})", 128}
    end
  end

  @doc """
  The completion-time check on the checkout at `path`, once nothing of the
  worker's runs any more: `:ok` for a path that is not a checkout leaf of the
  worktree root or is a layout-A linked worktree (never a private clone: a
  `.git` file at a ledgered leaf is a swap, however it reads; at any other
  leaf `guard/1`'s rule applies, a `gitdir:` file that points anywhere else is
  not one), otherwise `reclaim/1`. `{:error, {:tampered, why}}` means the worker swapped the
  clone's `.git` (it has been put right, but the run is not to be trusted: the
  caller fails closed rather than routing the tree on to review or merge).
  """
  @spec settle(term()) :: :ok | {:error, {:tampered, String.t()}}
  def settle(path) when is_binary(path) do
    if checkout_leaf?(path) and not linked_worktree?(path), do: reclaim(path), else: :ok
  end

  def settle(_), do: :ok

  defp linked_worktree?(path),
    do:
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(path, ".git"))) and
        not ledgered?(path) and linked_gitdir(path) == :ok

  # -- the private-clone ledger ------------------------------------------------------------

  # What `.git` cannot say about itself: a worker can replace it with a file
  # naming a "linked worktree" of a repo it built in a directory it can write,
  # which `linked_gitdir/1` cannot tell from a real one. So the host keeps,
  # beside the worktree root (a container is handed one clone, never the root
  # or its parent), one file per private-clone leaf naming its main repo. A
  # leaf is a private clone when that file exists and the main repo still holds
  # the identity record for it (which `unpin/2` drops with the clone, so a
  # leaf name reused for a layout-A worktree is not taken for one).
  defp ledger_file(path) do
    expanded = Path.expand(path)
    Path.join(Path.dirname(expanded) <> ".private-clones", Path.basename(expanded))
  end

  defp record_ledger(path, repo) do
    file = ledger_file(path)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, repo <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {:git_failed, "private-clone ledger: #{inspect(reason)}"}}
    end
  end

  defp ledgered?(path) do
    with {:ok, repo} <- File.read(ledger_file(path)),
         repo = String.trim(repo),
         true <- repo != "" and File.dir?(repo) do
      File.exists?(identity_file(repo, Path.basename(Path.expand(path))))
    else
      _ -> false
    end
  end

  # A `.git` file the host may follow: `gitdir: <repo>/.git/worktrees/<name>`
  # with the target outside the checkout, so the config git reads is the main
  # repo's, not one the worker could have written.
  defp linked_gitdir(path) do
    checkout = Path.expand(path)

    with {:ok, "gitdir:" <> rest} <- File.read(Path.join(path, ".git")),
         target = rest |> String.trim() |> Path.expand(checkout),
         false <- target == checkout or String.starts_with?(target, checkout <> "/"),
         "worktrees" <- target |> Path.dirname() |> Path.basename(),
         ".git" <- target |> Path.dirname() |> Path.dirname() |> Path.basename() do
      :ok
    else
      _ -> tampered(".git is a file that does not name a linked worktree of another repo")
    end
  end

  # A direct child of the worktree root: where a private clone lives.
  defp checkout_leaf?(path),
    do: Path.dirname(Path.expand(path)) == Path.expand(Arbiter.Config.Paths.worktree_root())

  defp tampered(why), do: {:error, {:tampered, why}}

  defp check_dot_git_dir(dot_git) do
    case File.lstat(dot_git) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> tampered(".git is a #{type}, not a directory")
      {:error, reason} -> tampered(".git is unreadable: #{inspect(reason)}")
    end
  end

  defp check_recorded(repo, leaf, dot_git) do
    with {:ok, recorded} <- File.read(identity_file(repo, leaf)),
         {:ok, current} <- dir_identity(dot_git) do
      if String.trim(recorded) == current,
        do: :ok,
        else: tampered(".git is not the directory the clone was created with")
    else
      # No record: a clone from before there was one.
      {:error, :enoent} -> :ok
      {:error, reason} -> tampered("the .git identity record is unreadable: #{inspect(reason)}")
    end
  end

  defp check_config_file(dot_git) do
    case File.lstat(Path.join(dot_git, "config")) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> tampered("config is a #{type}, not a file")
      {:error, reason} -> tampered("config is unreadable: #{inspect(reason)}")
    end
  end

  defp check_config_keys(dot_git) do
    case git(["config", "--file", Path.join(dot_git, "config"), "--list", "-z"], cd: nil) do
      {:ok, out} ->
        out
        |> String.split("\0", trim: true)
        |> Enum.map(&String.split(&1, "\n", parts: 2))
        |> Enum.find(fn [key | value] -> not config_allowed?(key, List.first(value)) end)
        |> case do
          nil -> :ok
          [key | _] -> tampered("config sets #{key}, which a clone's config never does")
        end

      {:error, _} ->
        tampered("config does not parse")
    end
  end

  defp config_allowed?(key, value) do
    cond do
      key in @config_keys -> true
      String.starts_with?(key, "arbiter.") -> true
      Regex.match?(@branch_key, key) -> true
      key in @url_keys -> is_binary(value) and safe_url?(value)
      true -> false
    end
  end

  # Not an option, not a transport helper (`ext::<command>` runs one).
  defp safe_url?(value),
    do: not String.starts_with?(value, "-") and not Regex.match?(@transport_helper, value)

  defp check_hooks_dir(dot_git) do
    hooks = Path.join(dot_git, "hooks")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(hooks),
         {:ok, names} <- File.ls(hooks) do
      case Enum.reject(names, &String.ends_with?(&1, ".sample")) do
        [] -> :ok
        found -> tampered("hooks/ holds #{Enum.join(Enum.sort(found), ", ")}")
      end
    else
      _ -> tampered("hooks is not a plain directory")
    end
  end

  # `create/3`'s "." guard is a git no-op; anything else points git's common
  # dir (refs, config, hooks) somewhere the worker chose. A per-worktree
  # config is only read behind `extensions.worktreeConfig`, which the key
  # check refuses, but its presence is refused too.
  defp check_commondir(dot_git) do
    cond do
      File.read(Path.join(dot_git, "commondir")) != {:ok, @commondir_guard} ->
        tampered("commondir is not the \".\" guard")

      File.exists?(Path.join(dot_git, "config.worktree")) ->
        tampered("config.worktree exists")

      true ->
        :ok
    end
  end

  # -- reclaiming a swapped .git ---------------------------------------------------------------

  @doc """
  Put the clone at `path` right after a container has had it: `:ok` when its
  `.git` verifies; otherwise the impostor `.git` (anything at `.git` that does
  not verify) is renamed to `.git.tampered` (kept as evidence, never read) and,
  when the directory `create/3` recorded is still at the top of the checkout
  (a worker's `mv .git .git2`), put back as `.git`. Returns
  `{:error, {:tampered, why}}` either way, saying which. A checkout left with
  no `.git` is not a git repository to the host's git, which is the safe state.

  For a path a container was handed (`mounts/1` refused anything that was not
  a clone), which is why a `.git` naming no main repo is treated as an
  impostor too.
  """
  @spec reclaim(path()) :: :ok | {:error, {:tampered, String.t()}}
  def reclaim(path) when is_binary(path) do
    case verify(path) do
      :ok ->
        :ok

      {:error, reason} ->
        why = tamper_reason(reason)
        aside = set_impostor_aside(path)

        case restore_recorded(path) do
          :ok ->
            Logger.error(
              "PrivateClone: #{path}: #{why}; the recorded .git is back, the replacement " <>
                "is at #{aside || "(none)"}"
            )

            tampered("#{why}; restored the original .git")

          :error ->
            Logger.error(
              "PrivateClone: #{path}: #{why}; the original .git was not found, " <>
                "the replacement is at #{aside || "(none)"}"
            )

            tampered("#{why}; the original .git was not found")
        end
    end
  end

  defp tamper_reason({:tampered, why}), do: why
  defp tamper_reason(:not_a_private_clone), do: ".git names no main repo"

  defp set_impostor_aside(path) do
    dot_git = Path.join(path, ".git")

    case File.lstat(dot_git) do
      {:ok, _} ->
        target = unused_name(path, @tampered_suffix)
        if File.rename(dot_git, target) == :ok, do: target, else: nil

      {:error, _} ->
        nil
    end
  end

  defp unused_name(dir, base) do
    free = fn name -> match?({:error, _}, File.lstat(Path.join(dir, name))) end

    name =
      Enum.find([base | Enum.map(1..50, &"#{base}-#{&1}")], free) ||
        "#{base}-#{System.unique_integer([:positive])}"

    Path.join(dir, name)
  end

  # The recorded directory, by identity, among the checkout's top-level
  # entries (where `mv .git <name>` from the checkout root puts it).
  defp restore_recorded(path) do
    with {:ok, names} <- File.ls(path),
         original when is_binary(original) <- Enum.find_value(names, &recorded_at(path, &1)),
         :ok <- File.rename(original, Path.join(path, ".git")) do
      :ok
    else
      _ -> :error
    end
  end

  defp recorded_at(path, name) do
    candidate = Path.join(path, name)
    leaf = Path.basename(path)

    with false <- String.starts_with?(name, @tampered_suffix),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(candidate),
         true <- File.regular?(Path.join(candidate, "config")),
         repo when is_binary(repo) <- candidate_repo(candidate),
         {:ok, recorded} <- File.read(identity_file(repo, leaf)),
         {:ok, current} <- dir_identity(candidate),
         true <- String.trim(recorded) == current do
      candidate
    else
      _ -> nil
    end
  end

  defp candidate_repo(dir) do
    case git(["config", "--file", Path.join(dir, "config"), "--get", "arbiter.mainRepo"],
           cd: nil
         ) do
      {:ok, value} -> String.trim(value)
      {:error, _} -> nil
    end
  end

  # -- the identity record --------------------------------------------------------------------

  # Kept in the main repo's common dir: a container is handed the clone and an
  # overlay of the objects, never this, so it cannot move it with the `.git`.
  defp identity_file(repo, leaf) do
    case objects_dir(repo) do
      {:ok, objects} -> Path.join([Path.dirname(objects), "arbiter-clones", leaf])
      {:error, _} -> Path.join([repo, ".git", "arbiter-clones", leaf])
    end
  end

  defp dir_identity(dir) do
    with {:ok, %File.Stat{inode: inode, major_device: major, minor_device: minor}} <-
           File.lstat(dir),
         do: {:ok, "#{major}:#{minor}:#{inode}"}
  end

  defp record_identity(repo, path, leaf) do
    file = identity_file(repo, leaf)

    with {:ok, id} <- dir_identity(Path.join(path, ".git")),
         :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, id <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {:git_failed, inspect(reason)}}
    end
  end

  defp forget_identity(repo, leaf) do
    if File.dir?(repo), do: File.rm(identity_file(repo, leaf))
  end

  # -- pins -------------------------------------------------------------------------

  @doc "The ref prefix a clone at leaf `leaf` keeps its pins under in the main repo."
  @spec pin_prefix(String.t()) :: String.t()
  def pin_prefix(leaf) when is_binary(leaf), do: @pin_root <> leaf <> "/"

  defp pin_ref(leaf, name), do: pin_prefix(leaf) <> name

  defp pin(repo, leaf, name, sha) do
    with {:ok, _} <- git(["update-ref", pin_ref(leaf, name), sha], cd: repo), do: :ok
  end

  @doc "Delete every pin under `pin_prefix(leaf)` in `repo`. Best-effort."
  @spec unpin(path(), String.t()) :: :ok
  def unpin(repo, leaf) when is_binary(repo) and is_binary(leaf) do
    case git(["for-each-ref", "--format=%(refname)", pin_prefix(leaf)], cd: repo) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.each(&git(["update-ref", "-d", &1], cd: repo))

      {:error, _} ->
        :ok
    end

    _ = forget_identity(repo, leaf)
    :ok
  end

  # -- the sweeper ----------------------------------------------------------------------

  @orphan_min_age_ms 60 * 60_000

  @doc """
  Private clones under `root` that can never be used again: the main repo
  they borrow objects from, or its objects dir, is gone. A clone is judged by
  its own `.git/config` (it says which repo it borrows from), never by what is
  around it; a directory that is not provably a clone is never named.
  `:min_age_ms` (default one hour, on that config file's mtime) spares a clone
  mid-creation.
  """
  @spec orphaned(path(), keyword()) :: [path()]
  def orphaned(root, opts \\ []) when is_binary(root) do
    min_age_s = div(Keyword.get(opts, :min_age_ms, @orphan_min_age_ms), 1000)
    cutoff = System.os_time(:second) - min_age_s

    root
    |> leaves()
    |> Enum.filter(&dead?(&1, cutoff))
  end

  defp leaves(root) do
    case File.ls(root) do
      {:ok, names} -> names |> Enum.sort() |> Enum.map(&Path.join(root, &1))
      {:error, _} -> []
    end
  end

  defp dead?(path, cutoff) do
    with {:ok, %File.Stat{mtime: mtime}} <-
           File.stat(Path.join(path, ".git/config"), time: :posix),
         true <- mtime <= cutoff,
         repo when is_binary(repo) <- main_repo(path) do
      not File.dir?(repo) or not alternates_present?(path)
    else
      _ -> false
    end
  end

  defp alternates_present?(path) do
    case File.read(Path.join(path, ".git/objects/info/alternates")) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> Enum.all?(&File.dir?/1)
      {:error, _} -> false
    end
  end

  @doc "The main repos the private clones under `root` borrow from (existing ones)."
  @spec main_repos(path()) :: [path()]
  def main_repos(root) when is_binary(root) do
    root
    |> leaves()
    |> Enum.map(&main_repo/1)
    |> Enum.filter(&(is_binary(&1) and File.dir?(&1)))
    |> Enum.uniq()
  end

  @doc """
  Delete the pins in `repo` whose leaf under `root` is no longer a private
  clone of `repo` (removed out of band, or the removal stopped between the
  directory and the refs). Returns the refs deleted.
  """
  @spec sweep_pins(path(), path()) :: [String.t()]
  def sweep_pins(repo, root) when is_binary(repo) and is_binary(root) do
    expanded = Path.expand(repo)

    case git(["for-each-ref", "--format=%(refname)", @pin_root], cd: repo) do
      {:ok, out} ->
        for ref <- String.split(out, "\n", trim: true),
            leaf = ref |> String.replace_prefix(@pin_root, "") |> String.split("/") |> hd(),
            main_repo(Path.join(root, leaf)) != expanded,
            match?({:ok, _}, git(["update-ref", "-d", ref], cd: repo)),
            do: ref

      {:error, _} ->
        []
    end
  end

  # -- main repo facts ----------------------------------------------------------------

  defp origin_ref(repo, base) do
    case git(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{base}^{commit}"],
           cd: repo
         ) do
      {:ok, sha} ->
        {:ok, String.trim(sha)}

      {:error, _} ->
        {:error,
         {:missing_origin_ref,
          "origin/#{base} does not resolve in #{repo} after fetch; " <>
            "refusing to branch from stale local state"}}
    end
  end

  defp local_branch_sha(repo, branch), do: rev(repo, "refs/heads/" <> branch)

  # The commit `ref` names in `repo`, or `nil`.
  defp rev(repo, ref) do
    case git(["rev-parse", "--verify", "--quiet", ref <> "^{commit}"], cd: repo) do
      {:ok, sha} -> String.trim(sha)
      {:error, _} -> nil
    end
  end

  defp objects_dir(repo) do
    with {:ok, common} <-
           git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cd: repo) do
      {:ok, Path.join(String.trim(common), "objects")}
    end
  end

  defp object_format(repo) do
    case git(["rev-parse", "--show-object-format"], cd: repo) do
      {:ok, format} -> {:ok, String.trim(format)}
      {:error, _} = error -> error
    end
  end

  # -- internals ----------------------------------------------------------------------

  defp git(args, opts) do
    cd = Keyword.get(opts, :cd)

    if is_binary(cd) and not File.dir?(cd) do
      {:error, {:git_failed, "cwd does not exist: #{cd}"}}
    else
      cmd_opts = if cd, do: [stderr_to_stdout: true, cd: cd], else: [stderr_to_stdout: true]

      case System.cmd("git", args, cmd_opts) do
        {output, 0} -> {:ok, output}
        {output, _nonzero} -> {:error, {:git_failed, String.trim(output)}}
      end
    end
  rescue
    e in ErlangError -> {:error, {:git_failed, Exception.message(e)}}
  end
end
