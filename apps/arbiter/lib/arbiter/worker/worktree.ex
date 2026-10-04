defmodule Arbiter.Worker.Worktree do
  require Logger

  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.ReleaseEnv

  @moduledoc """
  Thin wrapper around `git worktree` for the Phase 4 worker orchestrator.

  Each function shells out to the local `git` CLI via `System.cmd/3` and
  normalizes results into tagged tuples (`{:ok, _}` / `{:error, _}`).

  ## Worktree root

  Worktrees are created under a configurable root directory, resolved by
  `Arbiter.Config.Paths.worktree_root/0` (env var → app config →
  `$HOME`-relative default). Override via:

      config :arbiter, :worktree_root, "/some/other/dir"

  or at runtime with `Application.put_env/3` (tests rely on this), or the
  `ARBITER_WORKTREE_ROOT` environment variable.

  The branch name is mapped to a directory leaf by replacing `/` with `-`,
  so `feature/gte-009-worktree` lives at
  `<root>/feature-gte-009-worktree`.

  ## Design notes

  * `create/3` and `cleanup/1` are idempotent — re-running either with the
    same inputs is a no-op rather than an error.
  * `cleanup/1` does NOT delete the branch; branch lifecycle is the caller's
    concern (`delete_branch/3` for a branch that never got a commit,
    `delete_merged_branch/3` for one whose commits are all on the forge).
  * `has_uncommitted?/1` returns `{:ok, boolean}` (not a raw bool) so callers
    have a consistent shape and we can add metadata later without breaking
    them.

  ## Git layouts (bd-4wy1w1)

  A worker checkout is a **linked worktree** of the main repo by default
  (`git worktree add`; layout A). With `layout: :private_clone`, `create/4`
  and `attach/3` build an `Arbiter.Worker.PrivateClone` at the same leaf
  instead (layout B): its own `.git`, the main repo's objects borrowed through
  alternates, nothing registered in the main repo. That is the layout a
  container worker gets, since mounting a linked worktree means mounting the
  main repo's shared refs read-write. Everything else here works on either:
  `cleanup/1`, `repo_path/1`, `reset_if_merged/4` and `list/1` know a clone,
  and `sync_back/1` / `sync_branch/2` carry a clone's branch into the main
  repo for the readers that look it up there by name.
  """

  # Mix envs that workers actually use. `test` is the minimum; `dev` is
  # included because some dispatched workers compile in dev mode.
  @seed_envs ~w(test dev)

  @typedoc "Absolute path to a git repository or worktree."
  @type path :: String.t()

  @typedoc "Reason returned in `{:error, reason}` tuples."
  @type error_reason ::
          :invalid_branch_name
          | :invalid_path
          | {:git_failed, String.t()}
          | {:not_a_git_repo, path()}
          | {:fetch_failed, String.t()}
          | {:missing_origin_remote, String.t()}
          | {:missing_origin_ref, String.t()}

  @doc """
  Create a worktree at `<worktree_root>/<sanitized_branch_name>/` checked out
  on `branch_name`, branching from the upstream tip of `base_branch`
  (`origin/<base_branch>`).

  Before creating the worktree, fetches `<base_branch>` from `origin` in
  `repo_path`, so every worker starts on current upstream regardless of the
  repo checkout's drift (stale local base, dirty working tree, or HEAD on an
  unrelated branch). If `origin` is not configured or the ref cannot be
  resolved after the fetch, the call aborts with a clear error rather than
  silently falling back to a stale local base.

  Idempotent: if the target directory already exists and is on the requested
  branch, returns `{:ok, path}` without re-invoking git (no fetch either, so
  re-provisioning a still-good worktree is cheap).

  `layout: :private_clone` builds a git-layout-B private clone at the same
  path instead (`PrivateClone.create/3`, see "Git layouts" above), which also
  starts from the main repo's own `<branch>` when it has one, where a linked
  worktree would fail "already exists" and need `attach/2`. A clean linked
  worktree already at the leaf on this branch is replaced by a clone of it;
  anything else there is `{:error, {:layout_mismatch, path}}`.
  """
  @spec create(path(), String.t() | nil, String.t(), keyword()) ::
          {:ok, path()} | {:error, term()}
  def create(repo_path, branch_name, base_branch, opts \\ [])
  def create(_repo_path, "", _base_branch, _opts), do: {:error, :invalid_branch_name}
  def create(_repo_path, nil, _base_branch, _opts), do: {:error, :invalid_branch_name}

  def create(repo_path, branch_name, base_branch, opts)
      when is_binary(repo_path) and is_binary(branch_name) and is_binary(base_branch) and
             is_list(opts) do
    seed_paths = seed_paths(opts)

    case layout(opts) do
      :private_clone -> create_clone(repo_path, branch_name, base_branch, seed_paths)
      :linked_worktree -> create_linked(repo_path, branch_name, base_branch, seed_paths)
    end
  end

  defp layout(opts), do: Keyword.get(opts, :layout, :linked_worktree)

  # bd-2jerqw: the resolved `worker.repos.<repo>.seed_paths` (`SeedPaths.resolve/2`),
  # or nil for the built-in set. Every provisioning entry point takes it as the
  # `:seed_paths` option and hands it to `seed_compiled_deps/3`.
  defp seed_paths(opts), do: Keyword.get(opts, :seed_paths)

  # The leaf may hold the linked worktree an earlier run left before the
  # workspace switched to a container backend. Its branch and commits live in
  # the main repo, so a clean one on this branch is replaced by a clone of that
  # same branch; one holding uncommitted work (or mid-rebase) is refused.
  defp create_clone(repo_path, branch_name, base_branch, seed_paths) do
    case PrivateClone.create(repo_path, branch_name, base_branch, seed_paths) do
      {:error, {:layout_mismatch, path}} = mismatch ->
        if replaceable_linked?(path, branch_name) do
          Logger.info("Worktree: replacing the linked worktree at #{path} with a private clone")

          with :ok <- cleanup_linked(path),
               do: PrivateClone.create(repo_path, branch_name, base_branch, seed_paths)
        else
          mismatch
        end

      other ->
        other
    end
  end

  defp replaceable_linked?(path, branch_name) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(path, ".git"))) and
      checked_out_branch(path) == {:ok, branch_name} and
      in_progress_operation(path) == nil and
      has_uncommitted?(path) == {:ok, false}
  end

  defp create_linked(repo_path, branch_name, base_branch, seed_paths) do
    path = worktree_path(branch_name)

    result =
      if File.dir?(path) do
        case checked_out_branch(path) do
          {:ok, ^branch_name} ->
            {:ok, path}

          {:ok, _other} ->
            {:error, {:git_failed, "worktree exists at #{path} on a different branch"}}

          {:error, _} = err ->
            err
        end
      else
        File.mkdir_p!(Path.dirname(path))

        with :ok <- ensure_origin_remote(repo_path),
             :ok <- fetch_origin_branch(repo_path, base_branch),
             :ok <- ensure_origin_ref(repo_path, base_branch),
             {:ok, _stdout} <-
               run_git(
                 ["worktree", "add", path, "-b", branch_name, "origin/" <> base_branch],
                 cd: repo_path
               ) do
          :ok = seed_compiled_deps(repo_path, path, seed_paths)
          :ok = ensure_deps_fetched(path)
          {:ok, path}
        end
      end

    with {:ok, wt_path} <- result do
      _ = ensure_arbiter_exclude(wt_path)
      {:ok, wt_path}
    end
  end

  @doc """
  Create a **detached** worktree at `<worktree_root>/<sanitized_name>/`,
  checked out at the upstream tip of `base_branch` (`origin/<base_branch>`)
  with no branch of its own.

  Counterpart to `create/3` for dispatches whose deliverable is not a branch —
  `task`-type audits/spikes and reviews (bd-9r1tta). They previously ran
  straight from the *shared* local checkout, which on a developer machine is a
  human contributor's working directory: an arbitrary HEAD, arbitrarily many
  commits behind `origin`. An audit reading that tree reports the state of the
  world as of whenever the contributor last pulled, with full confidence and
  file:line citations — the fabricated "PHI encryption was never merged"
  finding this function exists to prevent.

  Same fetch-first guarantee as `create/3`: `origin` must exist, the fetch must
  succeed, and `origin/<base_branch>` must resolve, or the call errors rather
  than silently falling back to stale local state.

  Detached rather than branched on purpose: nothing here is meant to be
  committed or pushed, so there is no branch to leave behind and no way for an
  audit to accidentally commit onto one the merge path would pick up.

  Reads the source repo, writes only `.git/worktrees/<leaf>` and the new
  directory: the source checkout's HEAD, index, working tree, and unpushed
  commits are never touched.

  Idempotent, but NOT a no-op on re-provision: a directory already at the target
  path is **re-pointed** at the freshly-fetched `origin/<base_branch>` rather
  than reused as-is. Reusing it would re-open exactly the hole this function
  closes — the leaf is keyed to the task, and a worktree outlives its run
  (`CleanupWorktree` removes it only on close, and skips a dirty one), so a
  re-dispatched audit would otherwise read the *first* dispatch's snapshot of
  upstream, however old it has since become. Nothing in a detached inspect
  checkout is meant to be preserved, so re-pointing clobbers nothing.

  Refuses (rather than re-pointing) if the existing directory is on a *branch* —
  that is someone else's worktree and may hold unpushed commits. A directory
  that is not a live worktree at all (metadata pruned, interrupted `worktree
  add`, plain leftover dir) is reclaimed and provisioned fresh.
  """
  @spec create_detached(path(), String.t(), String.t(), keyword()) ::
          {:ok, path()} | {:error, error_reason()}
  def create_detached(repo_path, name, base_branch, opts \\ [])
  def create_detached(_repo_path, "", _base_branch, _opts), do: {:error, :invalid_branch_name}
  def create_detached(_repo_path, nil, _base_branch, _opts), do: {:error, :invalid_branch_name}

  def create_detached(repo_path, name, base_branch, opts)
      when is_binary(repo_path) and is_binary(name) and is_binary(base_branch) and is_list(opts) do
    path = worktree_path(name)
    seed_paths = seed_paths(opts)

    result =
      if File.dir?(path) do
        refresh_or_recreate_detached(repo_path, path, base_branch, seed_paths)
      else
        add_detached(repo_path, path, base_branch, seed_paths)
      end

    with {:ok, wt_path} <- result do
      _ = ensure_arbiter_exclude(wt_path)
      {:ok, wt_path}
    end
  end

  @inspect_suffix "-inspect"

  @doc """
  The worktree name a *detached inspect* checkout for `base_name` uses.

  Deliberately distinct from the branch leaf `create/3` would use for the same
  task (`<base_name>` vs `<base_name>#{@inspect_suffix}`). One task can need
  both — an audit that is later re-filed as code work, or the
  `provision_worktree: true` escape hatch on a `task`-type task — and sharing a
  leaf makes the two collide: `create/3` finds a detached HEAD there, reports
  "worktree exists … on a different branch", and the dispatch hard-fails until
  someone removes the directory by hand. Separate leaves also mean a path's
  *name* tells you whether it may hold work: a branch worktree can, an inspect
  checkout never does.

  `Issue.Changes.CleanupWorktree` reclaims both leaves on close, so the split
  does not leak worktrees.
  """
  @spec inspect_name(String.t()) :: String.t()
  def inspect_name(base_name) when is_binary(base_name), do: base_name <> @inspect_suffix

  @doc """
  The directory a detached inspect checkout for `base_name` lives at —
  `worktree_path(inspect_name(base_name))`.
  """
  @spec inspect_path(String.t()) :: path()
  def inspect_path(base_name) when is_binary(base_name),
    do: base_name |> inspect_name() |> worktree_path()

  @doc """
  Return `{:ok, true}` if the worktree at `path` has a detached HEAD (no branch),
  `{:ok, false}` if it is on a branch, `{:error, reason}` if `path` is not a
  readable git worktree.

  Lets callers distinguish a detached *inspect* checkout — which holds nothing
  worth preserving and is safe to re-point or throw away — from a branch
  worktree, which may hold unpushed commits (bd-9r1tta).

  A branch worktree stopped mid-rebase is *not* detached, although `git rebase`
  detaches HEAD while it replays: it is still that branch's worktree, and may
  hold work (bd-4olwyg). See `checked_out_branch/1`.
  """
  @spec detached?(path()) :: {:ok, boolean()} | {:error, error_reason()}
  def detached?(path) when is_binary(path) do
    with {:ok, branch} <- checked_out_branch(path) do
      {:ok, branch == "HEAD"}
    end
  end

  # An existing directory at the inspect leaf: re-point it at current upstream if
  # it is the detached checkout we left there, reclaim-and-recreate if it is not a
  # live worktree at all, refuse if it is on a branch (not ours to clobber).
  defp refresh_or_recreate_detached(repo_path, path, base_branch, seed_paths) do
    case checked_out_branch(path) do
      {:ok, "HEAD"} ->
        repoint_detached(repo_path, path, base_branch, seed_paths)

      {:ok, branch} ->
        {:error,
         {:git_failed,
          "worktree exists at #{path} on branch #{branch}, not a detached inspect " <>
            "checkout; refusing to re-point it (it may hold unpushed commits)"}}

      {:error, _} ->
        # The directory is not a live git worktree — git's metadata was pruned,
        # a `worktree add` was interrupted, or something left a plain directory
        # behind. Reclaim it (`cleanup/1` also drops any stale registration) and
        # provision fresh, rather than failing this task's dispatch forever.
        _ = cleanup(path)
        add_detached(repo_path, path, base_branch, seed_paths)
    end
  end

  # `--force`: the tree is ours and disposable, so a scratch file a prior agent
  # left modified must not block the re-point. Same fetch-first guarantee as the
  # fresh path — the checkout target is the ref the fetch just advanced.
  defp repoint_detached(repo_path, path, base_branch, seed_paths) do
    with :ok <- ensure_origin_remote(repo_path),
         :ok <- fetch_origin_branch(repo_path, base_branch),
         :ok <- ensure_origin_ref(repo_path, base_branch),
         {:ok, _stdout} <-
           run_git(["checkout", "--detach", "--force", "origin/" <> base_branch], cd: path) do
      :ok = seed_compiled_deps(repo_path, path, seed_paths)
      :ok = ensure_deps_fetched(path)
      {:ok, path}
    end
  end

  defp add_detached(repo_path, path, base_branch, seed_paths) do
    File.mkdir_p!(Path.dirname(path))

    with :ok <- ensure_origin_remote(repo_path),
         :ok <- fetch_origin_branch(repo_path, base_branch),
         :ok <- ensure_origin_ref(repo_path, base_branch),
         {:ok, _stdout} <- add_detached_git(repo_path, path, base_branch) do
      :ok = seed_compiled_deps(repo_path, path, seed_paths)
      :ok = ensure_deps_fetched(path)
      {:ok, path}
    end
  end

  # A leaf still registered in `.git/worktrees` whose directory is gone makes
  # `worktree add` fail permanently ("is a missing but already registered
  # worktree"), which would strand every future dispatch of that task. Prune the
  # stale registration once and retry.
  defp add_detached_git(repo_path, path, base_branch) do
    args = ["worktree", "add", "--detach", path, "origin/" <> base_branch]

    case run_git(args, cd: repo_path) do
      {:error, {:git_failed, msg}} = err ->
        if String.contains?(msg, "already registered") do
          _ = run_git(["worktree", "prune"], cd: repo_path)
          run_git(args, cd: repo_path)
        else
          err
        end

      other ->
        other
    end
  end

  # bd-bhrji9: `.arbiter/INBOX` (Arbiter.Messages.WorktreeDelivery) is written
  # into the worktree out-of-band, whenever a coordinator/sibling message
  # arrives — independent of, and not gated by, MCP config injection
  # (`Arbiter.MCP.inject_config?/0`). It never got the same `info/exclude`
  # protection bd-9q966y gave `.mcp.json`/`.gemini/`/`.codex/`, since it predates
  # that fix and lives in a different module entirely. Excluding it here, once
  # per worktree at creation, guarantees the entry exists before any message can
  # ever be delivered — regardless of MCP provider or whether config injection
  # is enabled. Best-effort: `add_to_git_exclude/2` already swallows its own
  # errors so a git hiccup never blocks worktree provisioning.
  @spec ensure_arbiter_exclude(path()) :: :ok
  defp ensure_arbiter_exclude(path),
    do: Arbiter.MCP.AgentConfig.add_to_git_exclude(path, [".arbiter/"])

  @doc """
  Refresh `repo_path`'s remote-tracking ref for `base_branch` from `origin`.

  Refs only: this updates `refs/remotes/origin/<base_branch>` and touches
  nothing else — not HEAD, not the index, not the working tree, not any local
  branch. Safe to call on a checkout a human is actively working in.

  For callers that must keep using a shared checkout as their cwd (local code
  review, which diffs against local branches) but still need `origin/<base>` to
  mean *current* upstream rather than whenever the contributor last pulled
  (bd-9r1tta).

  Returns `:ok` or `{:error, reason}`; callers generally treat it as
  best-effort.
  """
  @spec fetch_origin(path(), String.t()) :: :ok | {:error, error_reason()}
  def fetch_origin(repo_path, base_branch)
      when is_binary(repo_path) and is_binary(base_branch) do
    with :ok <- ensure_origin_remote(repo_path) do
      fetch_origin_branch(repo_path, base_branch)
    end
  end

  defp ensure_origin_remote(repo_path) do
    case run_git(["remote", "get-url", "origin"], cd: repo_path) do
      {:ok, _} ->
        :ok

      {:error, {:git_failed, msg}} ->
        {:error,
         {:missing_origin_remote,
          "repo at #{repo_path} has no `origin` remote configured; " <>
            "branching from a stale local base is unsafe. git: #{msg}"}}
    end
  end

  # Shallow `--no-tags` keeps the fetch fast — we only need the tip of the
  # target branch. `--prune` drops deleted remote refs so a renamed integration
  # branch doesn't leave a dangling `origin/<old>` that resolves but is stale.
  defp fetch_origin_branch(repo_path, base_branch) do
    case run_git(["fetch", "--no-tags", "--prune", "origin", base_branch], cd: repo_path) do
      {:ok, _} ->
        :ok

      {:error, {:git_failed, msg}} ->
        {:error,
         {:fetch_failed, "git fetch origin #{base_branch} failed in #{repo_path}: #{msg}"}}
    end
  end

  defp ensure_origin_ref(repo_path, base_branch) do
    ref = "refs/remotes/origin/" <> base_branch

    case run_git(["rev-parse", "--verify", "--quiet", ref], cd: repo_path) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error,
         {:missing_origin_ref,
          "origin/#{base_branch} does not resolve in #{repo_path} after fetch; " <>
            "refusing to branch from stale local state"}}
    end
  end

  @doc """
  If `branch_name` already exists — either as a live worktree, or merely as a
  branch ref left behind after its worktree was torn down (`:await_verification`
  runs `CleanupWorktree` the moment a PR merges, well before a `ticket_verify
  failed` reopen can redispatch onto it) — reset it to `origin/<base_branch>`
  so a redispatch starts clean instead of reusing a branch with nothing left
  to contribute (bd-8ssxap). Two independent signals trigger the reset:

    * **Ancestry** — the branch's own tip is already an ancestor of the
      freshly-fetched `origin/<base_branch>`. This only fires for a
      merge-commit-preserving merge strategy; it never fires after a squash
      merge, since a squash produces a brand-new commit on the base branch
      that the old branch tip is never an ancestor of.
    * **`force: true`** (caller-supplied, via `opts`) — the caller believes,
      from task state (e.g. `verification_outcome == :failed`, which only
      happens after a PR merged and then failed verification in production),
      that the branch MAY already be fully upstream via a squash merge,
      where ancestry never fires. But `verification_outcome == :failed`
      stays true for the whole re-work round — it only clears once the
      *next* PR merges — so `force` alone would also fire on every later
      dispatch in that round, after round-2 work is committed. To guard
      against that, `force: true` only resets when the branch's *tree
      content* is already identical to `ref` (no diff between them): true
      right after the squash lands, false again the moment anything new is
      committed on the branch.

  Call this BEFORE `create/3`, which is otherwise idempotent-without-a-fetch
  for an already-existing worktree, and whose "already exists" fallback
  (`attach/2`) simply checks out whatever a pre-existing *branch ref* already
  points to — either path would happily hand the stale, fully-merged branch
  straight back to the worker, the empty-PR redispatch bug this function
  exists to prevent.

  A live worktree is never hard-reset while it has uncommitted changes
  (staged, unstaged, or untracked — see `has_uncommitted?/1`), even under
  `force: true`: those changes are exactly what `Dispatch.resume/2` exists to
  preserve, and destroying them silently would be worse than leaving a stale
  branch in place. Callers on a resume path should additionally avoid calling
  this function at all (skip straight to `{:ok, :kept}`), since a resumed
  worktree's whole point is continuity from its preserved state.

  Returns:

    * `{:ok, :reset}` — the branch was merged (by ancestry or `force:
      true`) and had no uncommitted changes; hard-reset (in place, if a
      worktree exists) or force-moved (if only the ref survived) to the
      current `origin/<base_branch>` tip.
    * `{:ok, :kept}` — `branch_name` does not exist yet at all (nothing to
      reset; `create/3` will cut a fresh one), it has commits that are NOT
      merged and `force` was not given (genuine unmerged work — a normal
      changes-requested redispatch must keep it), or a live worktree has
      uncommitted changes that a hard reset would destroy.
    * `{:error, reason}` — `origin` is missing, the fetch failed, or the reset
      itself failed. Callers should fail the dispatch rather than silently
      reusing an un-checked branch.
  """
  @spec reset_if_merged(path(), String.t(), String.t(), keyword()) ::
          {:ok, :reset | :kept} | {:error, error_reason()}
  def reset_if_merged(repo_path, branch_name, base_branch, opts \\ [])
      when is_binary(repo_path) and is_binary(branch_name) and is_binary(base_branch) and
             is_list(opts) do
    path = worktree_path(branch_name)
    force? = Keyword.get(opts, :force, false)

    with :ok <- ensure_origin_remote(repo_path),
         :ok <- fetch_origin_branch(repo_path, base_branch),
         :ok <- ensure_origin_ref(repo_path, base_branch) do
      ref = "origin/" <> base_branch

      cond do
        File.dir?(path) ->
          with :ok <- refresh_clone_base(path, base_branch) do
            reset_worktree_if_merged(path, branch_name, ref, force?)
          end

        branch_ref_exists?(repo_path, branch_name) ->
          reset_branch_ref_if_merged(repo_path, branch_name, ref, force?)

        true ->
          {:ok, :kept}
      end
    end
  end

  # A private clone's `origin/<base>` is its own ref, not the one the fetch
  # above just moved: copy the main repo's in, so the ancestry check and the
  # reset see current upstream as they do in a linked worktree.
  defp refresh_clone_base(path, base_branch) do
    if PrivateClone.clone?(path), do: PrivateClone.refresh_base(path, base_branch), else: :ok
  end

  defp reset_worktree_if_merged(path, branch_name, ref, force?) do
    if should_reset?(branch_name, ref, path, force?) do
      case has_uncommitted?(path) do
        {:ok, true} ->
          {:ok, :kept}

        {:ok, false} ->
          with {:ok, _} <- run_git(["checkout", branch_name], cd: path),
               {:ok, _} <- run_git(["reset", "--hard", ref], cd: path) do
            {:ok, :reset}
          end

        {:error, _} = err ->
          err
      end
    else
      {:ok, :kept}
    end
  end

  defp reset_branch_ref_if_merged(repo_path, branch_name, ref, force?) do
    if should_reset?(branch_name, ref, repo_path, force?) do
      case run_git(["branch", "-f", branch_name, ref], cd: repo_path) do
        {:ok, _} -> {:ok, :reset}
        {:error, _} = err -> err
      end
    else
      {:ok, :kept}
    end
  end

  # `force?` alone is not enough: it stays true for the whole re-work round
  # (`verification_outcome` only clears once the NEXT pr merges), so a
  # naive `force? or ancestor?` would also blow away round-2 commits made
  # after the first, legitimate reset. Only treat the branch as stale when
  # merging it into `ref` would change nothing — i.e. every change on the
  # branch is already contained in `ref`. That is true right after a
  # squash-merge lands it on the base (however many commits were squashed,
  # and regardless of how much `ref` has since moved on with unrelated
  # merges), and false again the moment new work is committed on the branch.
  #
  # A plain `git diff --quiet ref branch` (tried in an earlier round) only
  # catches the instant-after-squash case: once anything else merges into
  # `ref`, the two trees diverge even though the branch itself still has no
  # unique content, and the stale branch would wrongly be kept. `git cherry`
  # does not work either — a squash of more than one commit produces a
  # patch-id matching neither original commit.
  defp should_reset?(branch_name, ref, cd, force?) do
    ancestor?(branch_name, ref, cd) or (force? and merge_is_noop?(branch_name, ref, cd))
  end

  defp ancestor?(branch_name, ref, cd) do
    case run_git(["merge-base", "--is-ancestor", branch_name, ref], cd: cd) do
      {:ok, _} -> true
      {:error, _not_ancestor} -> false
    end
  end

  # True when merging `branch_name` into `ref` produces a tree identical to
  # `ref`'s own tree — the branch contributes nothing `ref` doesn't already
  # have.
  defp merge_is_noop?(branch_name, ref, cd) do
    with {:ok, ref_tree} <- run_git(["rev-parse", ref <> "^{tree}"], cd: cd),
         {:ok, merged_tree} <- run_git(["merge-tree", "--write-tree", ref, branch_name], cd: cd) do
      String.trim(ref_tree) == first_line(merged_tree)
    else
      {:error, _} -> false
    end
  end

  defp first_line(output) do
    output |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  defp branch_ref_exists?(repo_path, branch_name) do
    case run_git(["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch_name],
           cd: repo_path
         ) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Attach a worktree at `<worktree_root>/<sanitized_branch_name>/` to an
  **existing** branch — no `-b`, no new branch creation.

  Counterpart to `create/3`. Use it when you need a worktree checked out on
  a branch that already exists in the repo — typically because a remote PR
  was opened against it. The merge queue's conflict-resolver worker
  (`Arbiter.Workflows.MergeQueue.ConflictResolver`) is the primary caller: it
  rebases the existing PR branch in place, so it must NOT create a new
  branch that would shadow the PR's head ref.

  Idempotent on the same-branch path: if the target directory already exists
  and is on the requested branch, returns `{:ok, path}` without re-invoking
  git. If the directory exists on a different branch, returns
  `{:error, {:git_failed, _}}` rather than silently switching it.

  "On the requested branch" includes a worktree stopped mid-rebase of it
  (`checked_out_branch/1`, bd-4olwyg): it is returned as-is, with the rebase
  still in progress. Aborting it is the caller's call — only the caller knows
  whether a live run is still working in it (`abort_in_progress/1`).

  `layout: :private_clone` (with `base:` naming the target branch, whose
  `origin/<base>` is then copied in) attaches a git-layout-B private clone
  instead (`PrivateClone.attach/3`).
  """
  @spec attach(path(), String.t() | nil, keyword()) :: {:ok, path()} | {:error, term()}
  def attach(repo_path, branch_name, opts \\ [])
  def attach(_repo_path, "", _opts), do: {:error, :invalid_branch_name}
  def attach(_repo_path, nil, _opts), do: {:error, :invalid_branch_name}

  def attach(repo_path, branch_name, opts)
      when is_binary(repo_path) and is_binary(branch_name) and is_list(opts) do
    seed_paths = seed_paths(opts)

    case layout(opts) do
      :private_clone ->
        PrivateClone.attach(repo_path, branch_name, Keyword.get(opts, :base), seed_paths)

      :linked_worktree ->
        attach_linked(repo_path, branch_name, seed_paths)
    end
  end

  defp attach_linked(repo_path, branch_name, seed_paths) do
    path = worktree_path(branch_name)

    if File.dir?(path) do
      case checked_out_branch(path) do
        {:ok, ^branch_name} ->
          {:ok, path}

        {:ok, _other} ->
          {:error, {:git_failed, "worktree exists at #{path} on a different branch"}}

        {:error, _} = err ->
          err
      end
    else
      File.mkdir_p!(Path.dirname(path))

      case run_git(["worktree", "add", path, branch_name], cd: repo_path) do
        {:ok, _stdout} ->
          :ok = seed_compiled_deps(repo_path, path, seed_paths)
          :ok = ensure_deps_fetched(path)
          {:ok, path}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Remove the worktree rooted at `worktree_path`.

  Idempotent: returns `:ok` whether or not the worktree existed. Uses
  `git worktree remove --force` first so dirty worktrees are still cleaned up;
  follows with a best-effort `File.rm_rf/1` on the leaf dir to handle the case
  where git's metadata is already gone.

  A private clone (layout B) is removed by `PrivateClone.remove/1`: its branch
  is synced back into the main repo first, so it outlives the checkout as a
  linked worktree's branch does, and the clone's gc pins go with it.
  """
  @spec cleanup(path()) :: :ok | {:error, term()}
  def cleanup(worktree_path) when is_binary(worktree_path) do
    if PrivateClone.clone?(worktree_path),
      do: PrivateClone.remove(worktree_path),
      else: cleanup_linked(worktree_path)
  end

  def cleanup(_), do: {:error, :invalid_path}

  defp cleanup_linked(worktree_path) do
    # Try to ask git nicely first. We don't know the parent repo from just
    # the worktree path, so we run `git -C <worktree>` which lets git itself
    # walk up to its parent repo via the gitdir link file.
    _ = run_git(["worktree", "remove", "--force", worktree_path], cd: worktree_path)

    # Whether or not git succeeded (it won't if the worktree was never created,
    # or was already removed but the dir lingered), make sure the directory is
    # gone on disk.
    case File.rm_rf(worktree_path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, {:git_failed, "rm_rf failed: #{inspect(reason)}"}}
    end
  end

  @doc """
  Delete the local branch `branch_name` in `repo_path` — but only when it
  carries no commits beyond `base_ref` (e.g. `"origin/main"`), so the branch
  is provably nothing but a pointer into history the base already has.

  For reclaiming the branch a failed dispatch cut and never committed to
  (bd-21bmdh); `cleanup/1` removes the directory, this removes the ref. Run it
  after `cleanup/1`: git refuses to delete a branch a worktree still has
  checked out. Returns `:ok` (deleted, or already absent),
  `{:error, :has_commits}` when the branch holds work, or `{:error, reason}`.
  An unresolvable `base_ref` reads as `:has_commits` — never delete on doubt.
  """
  @spec delete_branch(path(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_branch(repo_path, branch_name, base_ref)
      when is_binary(repo_path) and is_binary(branch_name) and is_binary(base_ref) do
    _ = run_git(["worktree", "prune"], cd: repo_path)

    if local_branch?(repo_path, branch_name) do
      with :ok <- branch_only_base?(repo_path, branch_name, base_ref),
           {:ok, _} <- run_git(["branch", "-D", branch_name], cd: repo_path) do
        :ok
      end
    else
      :ok
    end
  end

  defp local_branch?(repo_path, branch_name) do
    match?(
      {:ok, _},
      run_git(["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch_name], cd: repo_path)
    )
  end

  defp branch_only_base?(repo_path, branch_name, base_ref) do
    case run_git(["rev-list", "--count", base_ref <> ".." <> branch_name], cd: repo_path) do
      {:ok, count} -> if String.trim(count) == "0", do: :ok, else: {:error, :has_commits}
      {:error, _} -> {:error, :has_commits}
    end
  end

  @doc """
  Return the FULL 40-character HEAD SHA for the worktree at `path`, or `nil` on
  any error.

  The full form deliberately, not the abbreviated one: every caller compares it
  against a SHA a forge reported, and forges report 40 hex characters.
  """
  @spec head_sha(path()) :: String.t() | nil
  def head_sha(path) when is_binary(path) do
    case run_git(["rev-parse", "HEAD"], cd: path) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          sha -> sha
        end

      {:error, _} ->
        nil
    end
  end

  def head_sha(_path), do: nil

  @doc """
  Return the current branch name for the worktree at `path`.
  """
  @spec current_branch(path()) :: {:ok, String.t()} | {:error, error_reason()}
  def current_branch(path) when is_binary(path) do
    case run_git(["rev-parse", "--abbrev-ref", "HEAD"], cd: path) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, _} = err -> err
    end
  end

  @doc """
  The branch the worktree at `path` belongs to: `current_branch/1`, except that a
  worktree stopped mid-rebase names the branch being rebased rather than `"HEAD"`.

  `git rebase` detaches HEAD while it replays, so `current_branch/1` reads a
  branch worktree left mid-rebase as a detached checkout. That is how bd-4olwyg's
  wedge happened: resume refused the worktree as detached (`:no_outpost`) while
  `attach/2` refused it as "on a different branch", both of the same directory.
  Returns `{:ok, "HEAD"}` for a genuinely detached checkout.
  """
  @spec checked_out_branch(path()) :: {:ok, String.t()} | {:error, error_reason()}
  def checked_out_branch(path) when is_binary(path) do
    case current_branch(path) do
      {:ok, "HEAD"} -> {:ok, rebasing_branch(path) || "HEAD"}
      other -> other
    end
  end

  @doc """
  The git operation stopped part-way in the worktree at `path`: `:rebase` (a
  `rebase-merge/` or `rebase-apply/` directory), `:merge` (`MERGE_HEAD`), or
  `nil` when none is (or `path` is not a readable worktree).
  """
  @spec in_progress_operation(path()) :: :rebase | :merge | nil
  def in_progress_operation(path) when is_binary(path) do
    case git_dir(path) do
      {:ok, dir} ->
        cond do
          rebase_dir(dir) != nil -> :rebase
          File.exists?(Path.join(dir, "MERGE_HEAD")) -> :merge
          true -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  The paths with unresolved conflicts in the worktree at `path`, or `[]`.
  """
  @spec unmerged_files(path()) :: [String.t()]
  def unmerged_files(path) when is_binary(path) do
    case run_git(["diff", "--name-only", "--diff-filter=U"], cd: path) do
      {:ok, out} -> String.split(out, "\n", trim: true)
      {:error, _} -> []
    end
  end

  @doc """
  Abort whatever rebase or merge is stopped part-way in the worktree at `path`,
  putting its branch back where it was before the operation began.

  `{:ok, :rebase | :merge}` for what was aborted, `{:ok, nil}` when nothing was in
  progress. For a run that ended mid-operation (bd-4olwyg): its half-resolved
  state is not a deliverable, and leaving it behind makes the worktree read as
  detached to every later dispatch and resume. Nothing committed on the branch
  is lost — an abort restores the branch's pre-operation tip.
  """
  @spec abort_in_progress(path()) :: {:ok, :rebase | :merge | nil} | {:error, error_reason()}
  def abort_in_progress(path) when is_binary(path) do
    case in_progress_operation(path) do
      nil -> {:ok, nil}
      op -> with {:ok, _} <- run_git([Atom.to_string(op), "--abort"], cd: path), do: {:ok, op}
    end
  end

  @doc """
  The sha `branch` points at on `origin`, read live with `git ls-remote` from the
  checkout at `path` — `nil` when origin has no such branch or cannot be reached.

  Live rather than `refs/remotes/origin/<branch>`, which only moves on a fetch: a
  pass's own push updates it, but a stale local ref is exactly what must not pass
  for "the PR head" when deciding whether a pass delivered anything (bd-4olwyg).
  """
  @spec remote_head(path(), String.t()) :: String.t() | nil
  def remote_head(path, branch) when is_binary(path) and is_binary(branch) do
    ref = "refs/heads/" <> branch

    case run_git(["ls-remote", "origin", ref], cd: path) do
      # stderr is folded into the output, so match the ref's own line rather than
      # trusting the first token (a warning would otherwise pass for a sha).
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, "\t") do
            [sha, ^ref] -> sha
            _ -> nil
          end
        end)

      {:error, _} ->
        nil
    end
  end

  defp git_dir(path) do
    with {:ok, out} <- run_git(["rev-parse", "--absolute-git-dir"], cd: path) do
      {:ok, String.trim(out)}
    end
  end

  defp rebase_dir(git_dir) do
    ["rebase-merge", "rebase-apply"]
    |> Enum.map(&Path.join(git_dir, &1))
    |> Enum.find(&File.dir?/1)
  end

  # `head-name` holds the ref being rebased (`refs/heads/<branch>`), or
  # `detached HEAD` when the rebase itself started from one.
  defp rebasing_branch(path) do
    with {:ok, dir} <- git_dir(path),
         rebase when is_binary(rebase) <- rebase_dir(dir),
         {:ok, head_name} <- File.read(Path.join(rebase, "head-name")),
         "refs/heads/" <> branch <- String.trim(head_name) do
      branch
    else
      _ -> nil
    end
  end

  # Top-level build-artifact paths that git may report as untracked even
  # though they should be ignored. `seed_compiled_deps/2` copies `deps` and
  # `_build/<env>/lib` into every per-task worktree (real `cp -a` copies, not
  # symlinks — see the "Why copy, not symlink" section on that function's
  # doc). A real `deps`/`_build` directory should already match the target
  # repo's own directory-only `/deps/` `/_build/` gitignore patterns, so
  # `git status --porcelain` shouldn't report them at all. These two entries
  # are belt-and-suspenders: if a target repo's `.gitignore` doesn't cover
  # them, or a partial/interrupted seed leaves an unexpected top-level entry,
  # an untracked `deps`/`_build` root must still not false-fail the commit
  # gate on genuinely-committed work — the inverse of the bug the gate exists
  # to catch. See bd-dg0gs6 / #172 (originally filed against a symlink-based
  # seed that was never actually implemented — see bd-6040y1).
  #
  # `.mcp.json` / `.gemini/` / `.codex/` are Arbiter-injected agent-config files
  # (see bd-9q966y). `.arbiter/` is the coordinator mailbox delivery
  # directory (`Arbiter.Messages.WorktreeDelivery`, bd-bhrji9) — not a secret,
  # but equally an out-of-band Arbiter artifact that must never land in a
  # contributor commit. All four are gitignored via `info/exclude` (written by
  # `Arbiter.MCP.AgentConfig.write/3` / `add_to_git_exclude/2`, called from
  # `Arbiter.Worker.Worktree.create/3` for `.arbiter/`), so they should never
  # appear in `git status` output. Keeping them here is belt-and-suspenders: if
  # the exclude was not written, an untracked instance must not false-fail the
  # gate. The commit gate separately checks `has_injected_config_in_commits?/2`
  # to catch the harder case where one of these files was explicitly staged and
  # committed.
  #
  # Operator-configured `seed_paths` (bd-2jerqw) are not in this compile-time
  # list: they differ per repo, so `seed_compiled_deps/3` records the ones it
  # copied in the worktree's own git dir and `seeded_entry?/3` consults that.
  @ignored_artifact_paths ~w(deps deps/ _build _build/ .hex .hex/ .mcp.json .gemini/ .codex/ .arbiter .arbiter/ .run-server.sh)

  @doc """
  Return `{:ok, true}` if the worktree at `path` has any uncommitted changes
  (staged, unstaged, or untracked), else `{:ok, false}`.

  Untracked build-artifact roots (`deps`, `_build`) are ignored — see
  `@ignored_artifact_paths` — so a worktree whose only "change" is an
  unexpected `deps`/`_build` root reads as clean.
  """
  @spec has_uncommitted?(path()) :: {:ok, boolean()} | {:error, error_reason()}
  def has_uncommitted?(path) when is_binary(path) do
    case run_git(["status", "--porcelain"], cd: path) do
      {:ok, output} ->
        seeds = seeded_paths(path)

        dirty? =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&(artifact_entry?(&1) or seeded_entry?(path, &1, seeds)))
          |> Enum.any?()

        {:ok, dirty?}

      {:error, _} = err ->
        err
    end
  end

  # A porcelain line is `XY <path>` (two status chars, a space, then the path).
  # Returns true when the path is one of the known build-artifact roots, so the
  # caller can disregard a leaked `deps`/`_build` entry without masking real
  # untracked source files (e.g. `lib/deps_helper.ex` still counts).
  defp artifact_entry?(<<_status::binary-size(2), " ", rest::binary>>),
    do: String.trim(rest) in @ignored_artifact_paths

  defp artifact_entry?(_line), do: false

  # bd-2jerqw: an untracked porcelain entry that lies wholly under a path
  # `seed_compiled_deps/3` copied in. A collapsed `?? dir/` is expanded, since
  # git folds `priv/plts/` into `priv/` when nothing else under `priv/` is
  # tracked; it only counts when every untracked file in it is seeded.
  defp seeded_entry?(_path, _line, []), do: false

  defp seeded_entry?(path, <<"?? ", rest::binary>>, seeds) do
    entry = String.trim(rest)

    cond do
      under_seed?(String.trim_trailing(entry, "/"), seeds) ->
        true

      String.ends_with?(entry, "/") ->
        case run_git(["ls-files", "--others", "--exclude-standard", "--", entry], cd: path) do
          {:ok, out} ->
            files = String.split(out, "\n", trim: true)
            files != [] and Enum.all?(files, &under_seed?(&1, seeds))

          {:error, _} ->
            false
        end

      true ->
        false
    end
  end

  defp seeded_entry?(_path, _line, _seeds), do: false

  defp under_seed?(file, seeds),
    do: Enum.any?(seeds, &(file == &1 or String.starts_with?(file, &1 <> "/")))

  @doc """
  Return `{:ok, true}` if the worktree's current branch has commits not
  present on `base_ref` (default `"main"`), else `{:ok, false}`.

  Counterpart to `has_uncommitted?/1`. Together they let a cleanup policy
  ask "is it safe to throw this worktree away?": safe means **no**
  uncommitted changes AND **no** commits-ahead-of-base. The latter
  matters for local-only repos where the worktree branch is the only
  copy of those commits.

  When the base ref doesn't resolve (e.g., the parent repo has no `main`),
  returns `{:ok, true}` to be safe — we'd rather skip cleanup than delete
  potentially-valuable commits.
  """
  @spec has_commits_ahead?(path(), String.t()) :: {:ok, boolean()} | {:error, error_reason()}
  def has_commits_ahead?(path, base_ref \\ "main") when is_binary(path) do
    case run_git(["rev-list", "--count", base_ref <> "..HEAD"], cd: path) do
      {:ok, count_str} ->
        case Integer.parse(String.trim(count_str)) do
          {0, _} -> {:ok, false}
          {n, _} when n > 0 -> {:ok, true}
          _ -> {:ok, true}
        end

      {:error, _} ->
        # Base ref doesn't exist or git failed — conservative: assume there
        # might be commits worth preserving.
        {:ok, true}
    end
  end

  # Arbiter-injected paths that must NEVER appear in a committed diff. `.mcp.json`
  # / `.gemini/` / `.codex/` carry per-spawn bearer tokens (bd-9q966y); `.arbiter/`
  # is the coordinator/sibling mailbox delivery directory (bd-bhrji9) — not a
  # secret, but an out-of-band Arbiter artifact that must equally never reach a
  # contributor commit. Each entry is either a filename (exact match) or a
  # directory prefix (ends with "/", matches any path within it).
  @injected_config_patterns ~w(.mcp.json .gemini/ .codex/ .arbiter/)

  @doc """
  Return `{:ok, true}` if the branch's own committed diff (relative to its
  merge-base with `base_ref`, NOT a literal `base_ref..HEAD` two-dot diff)
  contains any Arbiter-injected path (`.mcp.json`, `.gemini/`, `.codex/`,
  `.arbiter/`), else `{:ok, false}`.

  These paths must NEVER appear in commits: the first three carry per-spawn
  bearer tokens; `.arbiter/` is the mailbox delivery directory. This check is the
  commit-gate backstop (bd-9q966y) for the case where `info/exclude` protection
  was bypassed and the file was explicitly staged and committed.

  Uses `merge_base/2` (bd-4ltc3e) rather than diffing straight against
  `base_ref`'s current tip: a literal `base_ref..HEAD` diff also picks up
  files that changed on `base_ref` itself after the branch was cut. If
  `base_ref` later gained its own (unrelated) commit touching one of these
  paths, every branch forked before it would false-trip on a diff it never
  produced — exactly what a reviewer's `base...HEAD` (three-dot) compare
  avoids. Only *added* paths count (`--diff-filter=A`): a target repo that
  legitimately tracks its own `.codex/*` (bd-9q25ck) has those paths at the
  merge-base, so a worker editing them is not an injected-config leak.
  Fails open on any git error so a transient hiccup does not strand
  a completion.
  """
  @spec has_injected_config_in_commits?(path(), String.t()) ::
          {:ok, boolean()} | {:error, error_reason()}
  def has_injected_config_in_commits?(path, base_ref \\ "main") when is_binary(path) do
    with base when is_binary(base) <- merge_base(path, base_ref),
         {:ok, output} <-
           run_git(["diff", "--name-only", "--diff-filter=A", base <> "..HEAD", "--"], cd: path) do
      changed = String.split(output, "\n", trim: true)
      found? = Enum.any?(changed, &injected_config_path?/1)
      {:ok, found?}
    else
      _ -> {:ok, false}
    end
  end

  defp injected_config_path?(file) do
    Enum.any?(@injected_config_patterns, fn pat ->
      if String.ends_with?(pat, "/"),
        do: String.starts_with?(file, pat) or file == String.trim_trailing(pat, "/"),
        else: file == pat
    end)
  end

  # ---- close-time leftovers (bd-9iv4qd) ------------------------------------

  # Untracked paths a build or a tool run regenerates, never authored work.
  # Directory names match at any depth (`scripts/__pycache__/`); the top-level
  # `deps`/`_build` roots are already in `@ignored_artifact_paths`.
  @junk_dirs ~w(__pycache__ node_modules .pytest_cache .mypy_cache .ruff_cache .elixir_ls .tox .venv .gradle)
  @junk_files ~w(.DS_Store)
  @junk_extensions ~w(.pyc .pyo)

  # Injected agent config carries per-spawn bearer tokens (bd-9q966y): a patch
  # saved into task notes must never include it.
  @patch_pathspec [
    ".",
    ":(exclude).mcp.json",
    ":(exclude).gemini",
    ":(exclude).codex",
    ":(exclude).arbiter"
  ]
  @patch_limit 60_000
  @untracked_file_limit 50

  @orphan_min_age_ms 60 * 60_000

  @typedoc "What `leftover_work/2` found still held only in a worktree."
  @type leftover :: %{
          path: path(),
          changes: [String.t()],
          unpushed: non_neg_integer(),
          patch: String.t()
        }

  @doc """
  What the worktree at `path` still holds that exists nowhere else, or `nil`
  when removing it loses nothing.

  Work is any of:

    * a staged or modified tracked file — except Arbiter-injected agent config
      (`.mcp.json`, `.gemini/`, ...), which is regenerated per spawn;
    * an untracked file that is not build junk (`__pycache__`, `_build`,
      `deps`, `node_modules`, `*.pyc`, injected config, ...);
    * a commit on `HEAD` reachable from no remote-tracking ref.

  `:pushed_shas` names commits known to be on the forge even when no local
  remote ref reaches them any more — the head a squash-merged PR merged, whose
  branch the forge then deleted. Commits reachable from one of them are not
  unpushed; unknown SHAs are ignored.

  Returns `{:ok, %{path, changes, unpushed, patch}}` when there is work, where
  `changes` are the `git status --porcelain` lines that count, `unpushed` the
  number of unpushed commits, and `patch` a readable (truncated) diff of all of
  it with injected config excluded. A git failure is `{:error, reason}` — the
  caller must treat that as "might hold work".
  """
  @spec leftover_work(path(), keyword()) :: {:ok, leftover() | nil} | {:error, error_reason()}
  def leftover_work(path, opts \\ []) when is_binary(path) do
    not_pushed = not_pushed_revs(path, Keyword.get(opts, :pushed_shas, []))

    with {:ok, status} <- run_git(["status", "--porcelain"], cd: path),
         {:ok, unpushed} <- count_revs(path, ["HEAD" | not_pushed]) do
      changes =
        status |> String.split("\n", trim: true) |> Enum.reject(&leftover_noise?(path, &1))

      if changes == [] and unpushed == 0 do
        {:ok, nil}
      else
        {:ok,
         %{
           path: path,
           changes: changes,
           unpushed: unpushed,
           patch: leftover_patch(path, changes, unpushed, not_pushed)
         }}
      end
    end
  end

  @doc """
  Delete the local branch `branch_name` in `repo_path` once nothing on it is
  held only locally: every commit is reachable from a remote-tracking ref or
  from one of `:pushed_shas` (see `leftover_work/2`).

  For reaping a merged task's branch (bd-9iv4qd) — unlike `delete_branch/3`,
  which only reclaims a branch with no commits at all. Run it after
  `cleanup/1`: git refuses to delete a branch a worktree has checked out.
  Returns `:ok` (deleted, or already absent), `{:error, :unpushed}`, or
  `{:error, reason}`.
  """
  @spec delete_merged_branch(path(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete_merged_branch(repo_path, branch_name, opts \\ [])
      when is_binary(repo_path) and is_binary(branch_name) do
    _ = run_git(["worktree", "prune"], cd: repo_path)

    if local_branch?(repo_path, branch_name) do
      not_pushed = not_pushed_revs(repo_path, Keyword.get(opts, :pushed_shas, []))

      case count_revs(repo_path, ["refs/heads/" <> branch_name | not_pushed]) do
        {:ok, 0} ->
          with {:ok, _} <- run_git(["branch", "-D", branch_name], cd: repo_path), do: :ok

        {:ok, _} ->
          {:error, :unpushed}

        {:error, _} = err ->
          err
      end
    else
      :ok
    end
  end

  @doc """
  The repository a linked worktree belongs to — the directory holding its
  common git dir — or `nil` when `path` is not a git checkout. For a private
  clone (layout B) that is the main repo it borrows from, not the clone.
  """
  @spec repo_path(path()) :: path() | nil
  def repo_path(path) when is_binary(path) do
    case PrivateClone.main_repo(path) do
      nil -> common_dir_repo(path)
      main -> main
    end
  end

  defp common_dir_repo(path) do
    case run_git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cd: path) do
      {:ok, out} ->
        common = String.trim(out)
        if Path.basename(common) == ".git", do: Path.dirname(common), else: common

      {:error, _} ->
        nil
    end
  end

  @doc """
  Top-level directories under `root` that are dead worktree leaves: their
  `.git` is a `gitdir: <path>` file whose metadata directory no longer exists
  (pruned, or its repository was deleted), so no `git worktree` command will
  ever reclaim them.

  Deliberately narrow (bd-9iv4qd). A directory with no `.git` file is never
  named, even an empty one: the worktree root on a real box also holds things
  Arbiter never made (a database socket or data directory, a plain clone), and
  nothing proves such a directory was ever a worktree. A live worktree's
  gitdir exists by construction, so it is never named either. `:min_age_ms`
  (default one hour, on the `.git` file's mtime) spares a leaf mid-creation.

  Also names the dead private clones (git layout B) under `root`: a clone
  whose main repo or borrowed objects dir is gone (`PrivateClone.orphaned/2`).
  """
  @spec orphaned_leaves(path(), keyword()) :: [path()]
  def orphaned_leaves(root, opts \\ []) when is_binary(root) do
    min_age_ms = Keyword.get(opts, :min_age_ms, @orphan_min_age_ms)
    cutoff = System.os_time(:second) - div(min_age_ms, 1000)

    linked =
      case File.ls(root) do
        {:ok, names} ->
          names
          |> Enum.sort()
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(&orphaned_leaf?(&1, cutoff))

        {:error, _} ->
          []
      end

    Enum.sort(linked ++ PrivateClone.orphaned(root, min_age_ms: min_age_ms))
  end

  defp orphaned_leaf?(leaf, cutoff) do
    marker = Path.join(leaf, ".git")

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(leaf),
         {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.lstat(marker, time: :posix),
         true <- mtime <= cutoff,
         {:ok, contents} <- File.read(marker),
         "gitdir: " <> gitdir <- String.trim(contents) do
      not File.dir?(Path.expand(gitdir, leaf))
    else
      _ -> false
    end
  end

  # `--not --remotes <known shas>`: the exclusion half of a rev-list for "held
  # only locally". An unknown SHA would fail the whole rev-list, so each is
  # checked first and dropped when git does not have it.
  defp not_pushed_revs(cd, shas) do
    known =
      Enum.filter(shas, fn sha ->
        is_binary(sha) and sha != "" and
          match?({:ok, _}, run_git(["cat-file", "-e", sha <> "^{commit}"], cd: cd))
      end)

    ["--not", "--remotes" | known]
  end

  defp count_revs(cd, revs) do
    with {:ok, out} <- run_git(["rev-list", "--count" | revs], cd: cd) do
      case Integer.parse(String.trim(out)) do
        {n, _} -> {:ok, n}
        :error -> {:error, {:git_failed, "unparseable rev-list count: #{out}"}}
      end
    end
  end

  # A porcelain `?? dir/` line collapses a whole untracked directory, so
  # `scripts/` holding nothing but `scripts/__pycache__/` has to be looked into.
  defp leftover_noise?(path, <<"?? ", rest::binary>>) do
    entry = String.trim(rest)

    junk_path?(entry) or (String.ends_with?(entry, "/") and untracked_files(path, entry) == []) or
      seeded_entry?(path, "?? " <> entry, seeded_paths(path))
  end

  defp leftover_noise?(_path, <<_status::binary-size(2), " ", rest::binary>>),
    do: injected_config_path?(String.trim(rest))

  defp leftover_noise?(_path, _line), do: false

  defp junk_path?(file) do
    segments = file |> String.trim_trailing("/") |> String.split("/")

    file in @ignored_artifact_paths or injected_config_path?(file) or
      String.starts_with?(file, ".claude/skills/") or
      Enum.any?(segments, &(&1 in @junk_dirs)) or
      List.last(segments) in @junk_files or
      Path.extname(file) in @junk_extensions
  end

  defp leftover_patch(path, changes, unpushed, not_pushed) do
    untracked = for "?? " <> rest <- changes, do: String.trim(rest)
    tracked? = Enum.any?(changes, &(not String.starts_with?(&1, "?? ")))

    [
      tracked? &&
        {"uncommitted changes", git_text(path, ["diff", "HEAD", "--" | @patch_pathspec])},
      untracked != [] && {"untracked files", untracked_patch(path, untracked)},
      unpushed > 0 &&
        {"unpushed commits",
         git_text(
           path,
           ["log", "-p", "--reverse", "--format=commit %H%n%n    %s%n", "HEAD"] ++
             not_pushed ++ ["--" | @patch_pathspec]
         )}
    ]
    |> Enum.filter(&is_tuple/1)
    |> Enum.map_join("\n", fn {title, body} -> "### #{title}\n\n#{body}\n" end)
    |> truncate_patch()
  end

  defp untracked_patch(path, entries) do
    entries
    |> Enum.flat_map(&untracked_files(path, &1))
    |> Enum.take(@untracked_file_limit)
    |> Enum.map_join("\n", fn file ->
      # `--no-index` exits 1 when the files differ, which they always do here.
      case System.cmd("git", ["diff", "--no-index", "--", "/dev/null", file],
             cd: path,
             stderr_to_stdout: true
           ) do
        {out, code} when code in [0, 1] -> out
        {_out, _code} -> "(could not diff #{file})\n"
      end
    end)
  rescue
    _ -> Enum.join(entries, "\n")
  end

  # A porcelain `?? dir/` entry collapses a whole untracked directory.
  defp untracked_files(path, entry) do
    if String.ends_with?(entry, "/") do
      case run_git(["ls-files", "--others", "--exclude-standard", "--", entry], cd: path) do
        {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.reject(&junk_path?/1)
        # Unlistable: keep the entry so it still counts as work.
        {:error, _} -> [entry]
      end
    else
      [entry]
    end
  end

  defp git_text(path, args) do
    case run_git(args, cd: path) do
      {:ok, out} -> out
      {:error, reason} -> "(git #{hd(args)} failed: #{inspect(reason)})"
    end
  end

  defp truncate_patch(patch) do
    if byte_size(patch) <= @patch_limit do
      patch
    else
      String.slice(patch, 0, @patch_limit) <>
        "\n… (truncated at #{@patch_limit} characters; the worktree still holds all of it)\n"
    end
  end

  @typedoc """
  Completion-readiness verdict from `completion_state/2`.

    * `:ready` — the worktree is clean AND the branch has commits ahead of base.
    * `:uncommitted` — the worktree has staged/unstaged/untracked changes (the
      "worker edited but forgot to commit" case bd-ofql8k targets).
    * `:no_commits` — the worktree is clean but the branch has no commits
      ahead of base (the "worker signalled done without doing any work" case).
  """
  @type completion :: :ready | :uncommitted | :no_commits

  @doc """
  Snapshot the worktree's completion-readiness against `base_ref` (default
  `"main"`): is it safe to hand off to the review gate / merger?

  Returns:

    * `{:ok, :ready}` — clean tree AND ≥1 commit ahead of `base_ref`.
    * `{:ok, :uncommitted}` — the worktree has uncommitted changes; the
      review gate / merger must NOT see it (the per-task branch HEAD does
      not yet include those edits, so they're invisible to `git diff
      base..HEAD`). This is the bd-ofql8k root cause.
    * `{:ok, :no_commits}` — clean tree but the branch has no commits
      ahead of `base_ref`. Either no work was done, or commits landed
      somewhere else.
    * `{:error, reason}` — git couldn't be queried.

  `:uncommitted` wins over `:no_commits` when both apply: an edited-but-
  uncommitted worktree is the actionable signal ("commit it"), and the
  absence of commits is a downstream consequence of that.
  """
  @spec completion_state(path(), String.t()) ::
          {:ok, completion()} | {:error, error_reason()}
  def completion_state(path, base_ref \\ "main") when is_binary(path) do
    with {:ok, dirty?} <- has_uncommitted?(path),
         {:ok, ahead?} <- has_commits_ahead?(path, base_ref) do
      cond do
        dirty? -> {:ok, :uncommitted}
        not ahead? -> {:ok, :no_commits}
        true -> {:ok, :ready}
      end
    end
  end

  @doc """
  Bring the worktree's current branch up to date with `target_branch` by
  fetching `origin/<target_branch>` and merging it into the branch.

  Run before a code review so the reviewer sees the branch against the CURRENT
  target tip rather than the (possibly older) base it was cut from. When the
  target advances mid-run, an un-updated branch makes the target's unrelated
  commits look like the branch's own work — the bd-ased52 false-reject. Merging
  (rather than rebasing) keeps history append-only, so a branch with an
  already-open PR does not need a force-push.

  Returns:

    * `{:ok, :up_to_date}` — `origin/<target>` was already an ancestor of HEAD;
      nothing to merge.
    * `{:ok, :merged}` — `origin/<target>` merged cleanly into the branch.
    * `{:error, {:conflict, %{files: [path], output: raw}}}` — the merge hit
      textual conflicts; the merge was ABORTED so the worktree is left clean on
      the branch's own HEAD (never half-merged). The caller must NOT review a
      conflicted branch — it should escalate for resolution (mirrors #97).
    * `{:error, reason}` — `origin` is missing, the fetch failed, or git failed
      for another reason. Callers should treat this as fail-open (proceed
      without the update); a merge-base diff still isolates the branch's own
      changes.
  """
  @spec update_from_target(path(), String.t()) ::
          {:ok, :up_to_date | :merged}
          | {:error, {:conflict, %{files: [String.t()], output: String.t()}} | error_reason()}
  def update_from_target(path, target_branch)
      when is_binary(path) and is_binary(target_branch) do
    ref = "origin/" <> target_branch

    with :ok <- ensure_origin_remote(path),
         :ok <- fetch_origin_branch(path, target_branch),
         :ok <- ensure_origin_ref(path, target_branch) do
      merge_target(path, ref)
    end
  end

  # Merge `ref` (origin/<target>) into the current branch. If `ref` is already
  # an ancestor of HEAD there is nothing to do. On a conflicted merge, capture
  # the conflicting paths (while the index still holds them), abort, and report
  # the conflict — never leave the worktree half-merged.
  defp merge_target(path, ref) do
    case run_git(["merge-base", "--is-ancestor", ref, "HEAD"], cd: path) do
      {:ok, _} ->
        {:ok, :up_to_date}

      {:error, _not_ancestor} ->
        case run_git(["merge", "--no-edit", ref], cd: path) do
          {:ok, _} -> {:ok, :merged}
          {:error, {:git_failed, output}} -> abort_merge(path, output)
        end
    end
  end

  defp abort_merge(path, output) do
    conflicts =
      case run_git(["diff", "--name-only", "--diff-filter=U"], cd: path) do
        {:ok, out} -> String.split(out, "\n", trim: true)
        {:error, _} -> []
      end

    _ = run_git(["merge", "--abort"], cd: path)

    if conflicts == [] do
      # A non-conflict merge failure (e.g. local changes would be overwritten);
      # surface as a generic git error so the caller fails open.
      {:error, {:git_failed, output}}
    else
      {:error, {:conflict, %{files: conflicts, output: output}}}
    end
  end

  @doc """
  Fetch the task branch from origin and fast-forward the local checkout if it
  is behind the remote tip.

  Call this BEFORE computing the merge-base or head_sha so the ReviewGate
  always sees the commits the implementer pushed, even when the local worktree
  was somehow left behind (e.g. commits made in a different git context and
  pushed directly to `origin/<branch>` without updating the local ref).

  Returns:

    * `{:ok, :up_to_date}` — local HEAD already matches `origin/<branch>`.
    * `{:ok, :synced}` — local branch fast-forwarded to `origin/<branch>`.
    * `{:error, reason}` — fetch failed, the remote ref does not exist, or the
      local branch has diverged from the remote (not a fast-forward). Callers
      should treat this as fail-open and proceed; the merge-base diff still
      isolates the branch's own changes if origin/<branch> is unreachable.
  """
  @spec sync_from_origin(path(), String.t()) ::
          {:ok, :up_to_date | :synced} | {:error, error_reason()}
  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def sync_from_origin(path, branch)
      when is_binary(path) and is_binary(branch) do
    with :ok <- ensure_origin_remote(path),
         :ok <- fetch_origin_branch(path, branch),
         :ok <- ensure_origin_ref(path, branch) do
      ref = "origin/" <> branch

      case run_git(["merge-base", "--is-ancestor", "HEAD", ref], cd: path) do
        {:ok, _} ->
          # HEAD is an ancestor of origin/<branch> — local is at or behind remote.
          # Check if HEAD == remote tip (already up to date) or behind (need ff).
          case run_git(["rev-parse", "HEAD"], cd: path) do
            {:ok, local_sha} ->
              case run_git(["rev-parse", ref], cd: path) do
                {:ok, remote_sha} when local_sha == remote_sha ->
                  {:ok, :up_to_date}

                {:ok, _remote_sha} ->
                  # Local is behind remote — fast-forward.
                  # Pre-existing nesting 5 — baselined when bd-4x2yhq first
                  # wired Credo up. Thresholds stay at the tool's own default so new
                  # code is held to it; see the note in .credo.exs.
                  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                  case run_git(["merge", "--ff-only", ref], cd: path) do
                    {:ok, _} -> {:ok, :synced}
                    {:error, _} = err -> err
                  end

                {:error, _} = err ->
                  err
              end

            {:error, _} = err ->
              err
          end

        {:error, _} ->
          # HEAD is NOT an ancestor of origin/<branch> — branches have diverged
          # or origin/<branch> is a different line. Do not force-reset; fail so
          # the caller can proceed without the sync (fail-open at call site).
          {:error,
           {:git_failed,
            "local branch `#{branch}` has diverged from origin/#{branch}; cannot fast-forward"}}
      end
    end
  end

  @doc """
  Reconcile the worktree's current branch with `origin/<branch>` before a
  push, tolerating genuine divergence instead of failing closed like
  `sync_from_origin/2` does.

  A ReviewGate implementer round pushes its fix commit straight to
  `origin/<branch>`; the main worker's worktree never sees it. If the main
  worker later commits its own work (e.g. a merge-title amend) before
  pushing, the two branches have genuinely diverged — not merely "local is
  behind". A plain push is rejected non-fast-forward; a blind pull would
  merge-commit; a force-push would destroy the implementer's work. Rebasing
  the worktree's own commits onto the remote tip is the only move that keeps
  both sides and leaves a plain (non-force) push valid afterward (bd-3doy0y).

  Returns:

    * `{:ok, :up_to_date}` — local HEAD already matches `origin/<branch>`.
    * `{:ok, :synced}` — local was behind; fast-forwarded to the remote tip.
    * `{:ok, :rebased}` — local and remote had diverged; local's own commits
      were rebased onto the remote tip. HEAD is now strictly ahead of
      `origin/<branch>` and a plain push will succeed.
    * `{:ok, :ahead}` — `origin/<branch>` is already an ancestor of HEAD (e.g.
      the branch merged it in via its own merge commit at some point). Local
      is strictly ahead with nothing to reconcile; a plain push will succeed
      without rebasing (bd-cdrr58 — rebasing here would replay commits whose
      content the branch already carries, producing false conflicts).
    * `{:error, {:diverged_conflict, %{files: [path], output: raw}}}` — the
      rebase hit textual conflicts. The rebase was ABORTED so the worktree is
      left clean on its own original HEAD (never half-rebased). The caller
      must not force-push here — it should escalate for manual resolution.
    * `{:error, reason}` — `origin` is missing or the fetch failed.
  """
  @spec rebase_onto_origin(path(), String.t()) ::
          {:ok, :up_to_date | :synced | :rebased | :ahead}
          | {:error,
             {:diverged_conflict, %{files: [String.t()], output: String.t()}} | error_reason()}
  # Pre-existing complexity 12 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def rebase_onto_origin(path, branch)
      when is_binary(path) and is_binary(branch) do
    with :ok <- ensure_origin_remote(path),
         :ok <- fetch_origin_branch(path, branch),
         :ok <- ensure_origin_ref(path, branch) do
      ref = "origin/" <> branch

      case run_git(["merge-base", "--is-ancestor", "HEAD", ref], cd: path) do
        {:ok, _} ->
          # HEAD is an ancestor of origin/<branch> — local is at or behind
          # remote. Same-tip check mirrors sync_from_origin/2.
          case {run_git(["rev-parse", "HEAD"], cd: path), run_git(["rev-parse", ref], cd: path)} do
            {{:ok, sha}, {:ok, sha}} ->
              {:ok, :up_to_date}

            {{:ok, _local_sha}, {:ok, _remote_sha}} ->
              # Pre-existing nesting 4 — baselined when bd-4x2yhq first
              # wired Credo up. Thresholds stay at the tool's own default so new
              # code is held to it; see the note in .credo.exs.
              # credo:disable-for-next-line Credo.Check.Refactor.Nesting
              case run_git(["merge", "--ff-only", ref], cd: path) do
                {:ok, _} -> {:ok, :synced}
                {:error, _} = err -> err
              end

            {{:error, _} = err, _} ->
              err

            {_, {:error, _} = err} ->
              err
          end

        {:error, _} ->
          # HEAD is NOT an ancestor of origin/<branch>. Check the other
          # direction before assuming genuine divergence: if origin/<branch>
          # is itself an ancestor of HEAD, the branch already carries
          # everything on the remote (e.g. via its own prior `git merge
          # origin/main`) and a rebase would only replay already-integrated
          # content, risking false conflicts (bd-cdrr58).
          case run_git(["merge-base", "--is-ancestor", ref, "HEAD"], cd: path) do
            {:ok, _} ->
              {:ok, :ahead}

            {:error, _} ->
              # Neither is an ancestor of the other — genuine divergence.
              # Rebase the worktree's own commits onto the remote tip instead
              # of failing closed.
              rebase_onto(path, ref)
          end
      end
    end
  end

  # Rebase HEAD onto `ref`. On success the worktree's own commits sit on top
  # of `ref`, strictly ahead of it. On conflict, capture the conflicting
  # paths (while the index still holds them), abort back to the pre-rebase
  # HEAD, and report the conflict — mirrors abort_merge/2.
  defp rebase_onto(path, ref) do
    case run_git(["rebase", "--autostash", ref], cd: path) do
      {:ok, _} ->
        {:ok, :rebased}

      {:error, {:git_failed, output}} ->
        abort_rebase(path, output)
    end
  end

  defp abort_rebase(path, output) do
    conflicts = unmerged_files(path)

    _ = run_git(["rebase", "--abort"], cd: path)

    if conflicts == [] do
      {:error, {:git_failed, output}}
    else
      {:error, {:diverged_conflict, %{files: conflicts, output: output}}}
    end
  end

  @doc """
  Return the SHA of the merge-base (fork point) between the worktree's HEAD and
  `target_branch`, preferring the fetched `origin/<target>` ref and falling
  back to the local `<target>` ref.

  The merge-base is the commit the branch was cut from. Diffing
  `<merge_base>..HEAD` shows ONLY the branch's own changes — even when the
  target advanced after the branch was cut, and even after `update_from_target/2`
  merged the target in (the merge-base then equals the target tip). This is the
  diff a reviewer must use to avoid mis-attributing the target's later commits
  to the branch (bd-ased52). Returns `nil` if neither ref resolves or git fails.
  """
  @spec merge_base(path(), String.t()) :: String.t() | nil
  def merge_base(path, target_branch)
      when is_binary(path) and is_binary(target_branch) do
    Enum.find_value(["origin/" <> target_branch, target_branch], fn ref ->
      case run_git(["merge-base", ref, "HEAD"], cd: path) do
        {:ok, out} ->
          case String.trim(out) do
            "" -> nil
            sha -> sha
          end

        {:error, _} ->
          nil
      end
    end)
  end

  @doc """
  Push the worktree at `path` to a remote.

  ## Options

    * `:remote` — remote name (default `"origin"`).
    * `:set_upstream` — when `true`, passes `-u` to git push.
    * `:branch` — explicit branch ref to push; defaults to the worktree's
      current branch.
  """
  @spec push(path(), keyword()) :: {:ok, String.t()} | {:error, error_reason()}
  def push(path, opts \\ []) when is_binary(path) and is_list(opts) do
    remote = Keyword.get(opts, :remote, "origin")
    set_upstream = Keyword.get(opts, :set_upstream, false)

    with {:ok, branch} <- resolve_branch(path, opts) do
      args =
        ["push"] ++
          if(set_upstream, do: ["-u"], else: []) ++
          [remote, branch]

      run_git(args, cd: path)
    end
  end

  @doc """
  Carry a private clone's branch into its main repo (`PrivateClone.sync_back/1`).
  `:ok` for a linked worktree, whose branch already lives in the main repo.

  For the moments a clone's commits must be visible in the main repo: the end
  of a worker run, and before anything that reads the branch there by name.
  """
  @spec sync_back(path()) :: :ok | {:error, term()}
  def sync_back(path) when is_binary(path) do
    if PrivateClone.clone?(path) do
      with {:ok, _sha} <- PrivateClone.sync_back(path), do: :ok
    else
      :ok
    end
  end

  @doc """
  Refresh `repo_path`'s `<branch_name>` from the private clone at
  `worktree_path(branch_name)`, if that is a clone of `repo_path`; `:ok`
  otherwise. For readers that find a branch by name in the main repo (the
  Direct merger, the conflict resolver's divergence check, a review
  checkout's local fallback): with a linked worktree that ref *is* the
  worker's branch, with a clone it is only as fresh as the last sync-back.
  """
  @spec sync_branch(path(), String.t()) :: :ok | {:error, term()}
  def sync_branch(repo_path, branch_name) when is_binary(repo_path) and is_binary(branch_name) do
    path = worktree_path(branch_name)

    if PrivateClone.main_repo(path) == Path.expand(repo_path),
      do: sync_back(path),
      else: :ok
  end

  @doc """
  Compute the directory a worktree for `branch_name` lives at.

  Public so callers (and tests) can predict the path without invoking git.
  """
  @spec worktree_path(String.t()) :: path()
  def worktree_path(branch_name) when is_binary(branch_name) do
    root = Arbiter.Config.Paths.worktree_root()
    leaf = String.replace(branch_name, "/", "-")
    Path.join(root, leaf)
  end

  @doc """
  List the linked worktrees attached to the repo at `repo_path`, excluding
  the main worktree, followed by its private clones (layout B) under the
  worktree root, which git does not know about.

  Each entry is a map with `:path` and `:branch`. Returns `[]` if the path
  isn't a git repo, git isn't on PATH, or anything else goes wrong — this
  is a "best effort" stat helper, not a strict API.
  """
  @spec list(path()) :: [%{path: path(), branch: String.t() | nil}]
  def list(repo_path) when is_binary(repo_path) do
    linked =
      case run_git(["worktree", "list", "--porcelain"], cd: repo_path) do
        {:ok, output} ->
          output
          |> parse_worktree_list()
          # First entry is the main worktree; the user wants linked ones only.
          |> Enum.drop(1)

        {:error, _} ->
          []
      end

    linked ++ PrivateClone.list(repo_path)
  end

  defp parse_worktree_list(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_worktree_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_worktree_block(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, " ", parts: 2) do
        ["worktree", path] -> Map.put(acc, :path, path)
        ["branch", ref] -> Map.put(acc, :branch, strip_branch_ref(ref))
        _ -> acc
      end
    end)
    |> case do
      %{path: _} = entry -> Map.put_new(entry, :branch, nil)
      _ -> nil
    end
  end

  defp strip_branch_ref("refs/heads/" <> name), do: name
  defp strip_branch_ref(other), do: other

  @doc """
  Seed the worktree's `deps/` and `_build/<env>/lib/` with the fetched and
  pre-compiled dependencies from `source_repo`, so workers can run `mix
  test` without a `mix deps.get` network fetch or a full dep recompile.

  `seed_paths` (bd-2jerqw) swaps that built-in set for an operator-chosen one
  — see "Configuring what is seeded" below. `nil` (the default) is the
  built-in set described in the rest of this doc, unchanged.

  ## Why copy, not symlink

  Symlinks into the source repo's `deps`/`_build` are live write-through
  paths: a `mix deps.get`, a `mix.lock` bump, or a dep recompile inside the
  worktree would write straight into the source repo's shared directories —
  corrupting live artifacts (bd-cwov25) or, worse, racing against every other
  worktree concurrently dispatched against the same source repo. Copying
  gives the worktree full ownership of its deps; the source repo is never
  touched again.

  ## Implementation

  Uses `cp -a --reflink=auto` — a correct full copy on ext4, and automatically
  a near-free CoW block-level copy on btrfs/xfs if the host ever migrates.

  ## Excluded dirs

  `arbiter`, `arbiter_web`, `arbiter_cli` are skipped from the `_build` copy —
  they must compile fresh per-branch in the worktree so cross-branch
  contamination is impossible (bd-cwov25). All other compiled deps in
  `_build/<env>/lib/` are copied. `deps/` itself needs no such filter: it
  only ever contains fetched dependencies, never the umbrella apps.

  ## Envs seeded

  Both `test` and `dev` `_build` envs are seeded (workers use `test`; some
  dispatched workers compile in `dev`). `deps/` is env-independent and seeded
  once. A missing source dir is silently skipped so this function is safe to
  call on a repo that has never been compiled or had deps fetched.

  Best-effort: failures are swallowed so a seeding issue never blocks
  worktree provisioning.

  ## Configuring what is seeded

  `worker.repos.<repo>.seed_paths` in the workspace config is a list of
  repo-relative paths, deep-merged over a workspace-level
  `worker.seed_paths` exactly like `merge.repos.<repo>`
  (`Arbiter.Worker.SeedPaths.resolve/2`). Unset at both levels, the built-in
  set above applies. Set, the list **replaces** it: each entry is copied with
  `cp -a --reflink=auto` when it exists in the source repo and not yet in the
  worktree, and nothing else is. A per-repo list does not extend the
  workspace-level one, and an empty list seeds nothing.

  An umbrella that wants its own compiled apps and dialyzer PLTs too (the
  built-in filter deliberately skips the umbrella's own apps):

      {"worker": {"repos": {"my_umbrella": {
        "seed_paths": ["deps", "_build/test/lib", "_build/dev/lib", "priv/plts"]
      }}}}

  A single-app Mix project, adding its PLTs and JS dependencies to the
  defaults (the defaults must be restated: the list replaces them):

      {"worker": {"repos": {"my_app": {
        "seed_paths": ["deps", "_build/test", "_build/dev", "priv/plts", "assets/node_modules"]
      }}}}

  An entry that is absolute, has a `..` segment, or names `.git` is never
  copied and logs a warning. Copying stays the mechanism for the reason in
  "Why copy, not symlink": a symlink writes through to the source repo and
  lets concurrent workers clobber each other.

  A configured path the target repo does not gitignore would read as an
  untracked file to the commit gate. Each entry this call actually copies is
  therefore recorded in a worktree-private file (`<git-dir>/arbiter-seed-paths`,
  never the shared `info/exclude`), and `has_uncommitted?/1` and `leftover_work/2`
  disregard untracked files under those paths. An entry that was not copied
  (missing from the source, or already in the worktree) is never recorded, so it
  cannot hide real work.
  """
  @spec seed_compiled_deps(path(), path(), [String.t()] | nil) :: :ok
  def seed_compiled_deps(source_repo, worktree_path, seed_paths \\ nil)

  def seed_compiled_deps(source_repo, worktree_path, seed_paths)
      when is_binary(source_repo) and is_binary(worktree_path) and is_list(seed_paths) do
    copied =
      seed_paths
      |> Enum.flat_map(&safe_seed_entry/1)
      |> Enum.uniq()
      |> Enum.filter(&seed_entry(source_repo, worktree_path, &1))

    record_seeded_paths(worktree_path, copied)
    :ok
  rescue
    error ->
      Logger.warning(
        "Worktree: seeding #{worktree_path} from seed_paths failed: #{inspect(error)}"
      )

      :ok
  end

  def seed_compiled_deps(source_repo, worktree_path, nil)
      when is_binary(source_repo) and is_binary(worktree_path) do
    seed_deps_dir(source_repo, worktree_path)

    Enum.each(@seed_envs, fn env ->
      source_lib = Path.join([source_repo, "_build", env, "lib"])
      dest_lib = Path.join([worktree_path, "_build", env, "lib"])

      if File.dir?(source_lib) do
        File.mkdir_p!(dest_lib)

        source_lib
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join([source_repo, "deps", &1])))
        |> Enum.each(fn dep ->
          source_dep = Path.join(source_lib, dep)
          dest_dep = Path.join(dest_lib, dep)

          # Pre-existing nesting 4 — baselined when bd-4x2yhq first
          # wired Credo up. Thresholds stay at the tool's own default so new
          # code is held to it; see the note in .credo.exs.
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          unless File.exists?(dest_dep) do
            System.cmd("cp", ["-a", "--reflink=auto", source_dep, dest_dep],
              stderr_to_stdout: true
            )
          end
        end)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  def seed_compiled_deps(_source_repo, _worktree_path, other) do
    Logger.warning("Worktree: ignoring non-list seed_paths #{inspect(other)}")
    :ok
  end

  # One `seed_paths` entry → `[normalised_relative_path]`, or `[]` plus a
  # warning when it is not a plain path inside the repo. Nothing absolute, no
  # `..`, nothing in `.git`: a seed path must not reach outside the source
  # repo or copy its object store into a worker's tree.
  defp safe_seed_entry(entry) when is_binary(entry) do
    segments = entry |> String.split("/", trim: true) |> Enum.reject(&(&1 == "."))

    reason =
      cond do
        Path.type(entry) == :absolute -> "absolute paths are not allowed"
        segments == [] -> "empty path"
        ".." in segments -> "`..` segments are not allowed"
        ".git" in segments -> "`.git` is never copied"
        true -> nil
      end

    if reason do
      Logger.warning("Worktree: skipping seed_paths entry #{inspect(entry)}: #{reason}")
      []
    else
      [Enum.join(segments, "/")]
    end
  end

  defp safe_seed_entry(entry) do
    Logger.warning("Worktree: skipping seed_paths entry #{inspect(entry)}: not a string")
    []
  end

  # Copy one validated entry. Returns true only when this call put it there.
  defp seed_entry(source_repo, worktree_path, rel) do
    source = Path.join(source_repo, rel)
    dest = Path.join(worktree_path, rel)

    cond do
      not path_present?(source) -> false
      path_present?(dest) -> false
      symlinked_parent?(worktree_path, rel) -> warn_seed_failure(rel, "a parent is a symlink")
      true -> copy_seed_entry(source, dest, rel)
    end
  end

  defp copy_seed_entry(source, dest, rel) do
    File.mkdir_p!(Path.dirname(dest))

    case System.cmd("cp", ["-a", "--reflink=auto", source, dest], stderr_to_stdout: true) do
      {_out, 0} -> true
      {out, code} -> warn_seed_failure(rel, "cp exited #{code}: #{String.trim(out)}")
    end
  rescue
    error -> warn_seed_failure(rel, inspect(error))
  end

  defp warn_seed_failure(rel, why) do
    Logger.warning("Worktree: could not seed #{inspect(rel)}: #{why}")
    false
  end

  # `File.exists?/1` follows symlinks, so a dangling one would read as absent.
  defp path_present?(path), do: match?({:ok, _}, File.lstat(path))

  # A tracked symlink such as `priv -> /elsewhere` would make `priv/plts` land
  # outside the worktree.
  defp symlinked_parent?(worktree_path, rel) do
    rel
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(worktree_path, &Path.join(&2, &1))
    |> Enum.any?(&match?({:ok, %File.Stat{type: :symlink}}, File.lstat(&1)))
  end

  @seed_record_file "arbiter-seed-paths"

  # The worktree's own admin dir (`.git/worktrees/<leaf>` for a linked
  # worktree, `.git` for a clone). Unlike `info/exclude` this is not shared
  # with the source repo or sibling worktrees.
  defp seed_record_path(worktree_path) do
    case run_git(["rev-parse", "--absolute-git-dir"], cd: worktree_path) do
      {:ok, out} -> Path.join(String.trim(out), @seed_record_file)
      {:error, _} -> nil
    end
  end

  defp record_seeded_paths(_worktree_path, []), do: :ok

  defp record_seeded_paths(worktree_path, copied) do
    case seed_record_path(worktree_path) do
      nil ->
        :ok

      file ->
        merged = Enum.uniq(seeded_paths(worktree_path) ++ copied)
        File.write!(file, Enum.join(merged, "\n") <> "\n")
    end
  end

  # What `seed_compiled_deps/3` recorded as copied into `worktree_path`.
  defp seeded_paths(worktree_path) do
    with file when is_binary(file) <- seed_record_path(worktree_path),
         {:ok, body} <- File.read(file) do
      String.split(body, "\n", trim: true)
    else
      _ -> []
    end
  end

  # Copy each top-level deps/<dep> dir from source_repo into worktree_path,
  # skipping any that already exist in the destination. Mirrors the _build
  # copy loop above, minus the deps/<name> existence filter (not applicable —
  # deps/ IS the set of fetched dependencies).
  defp seed_deps_dir(source_repo, worktree_path) do
    source_deps = Path.join(source_repo, "deps")
    dest_deps = Path.join(worktree_path, "deps")

    if File.dir?(source_deps) do
      File.mkdir_p!(dest_deps)

      source_deps
      |> File.ls!()
      |> Enum.each(fn dep ->
        source_dep = Path.join(source_deps, dep)
        dest_dep = Path.join(dest_deps, dep)

        unless File.exists?(dest_dep) do
          System.cmd("cp", ["-a", "--reflink=auto", source_dep, dest_dep], stderr_to_stdout: true)
        end
      end)
    end
  end

  # Run `mix deps.get` for Mix projects to ensure any new dependencies added
  # to the branch are fetched. Non-Mix repos (no mix.exs) skip this step.
  # Failures are logged but do not fail provisioning (best-effort).
  #
  # bd-2oelme: routed through `ReleaseEnv.cmd/3` — under a systemd OTP release
  # the coordinator's own env carries ROOTDIR/BINDIR/RELEASE_*, and a `mix`
  # child that inherits them boots against the release's bundled ERTS and dies
  # with `cannot get bootfile` instead of fetching deps.
  #
  # Public (`@doc false`) only so the release-env spawn test can drive this one
  # spawn without provisioning a real worktree.
  @doc false
  @spec ensure_deps_fetched(path()) :: :ok
  def ensure_deps_fetched(worktree_path) when is_binary(worktree_path) do
    mix_exs = Path.join(worktree_path, "mix.exs")

    if File.exists?(mix_exs) do
      case ReleaseEnv.cmd("mix", ["deps.get"], cd: worktree_path, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, _nonzero} ->
          Logger.warning("mix deps.get failed in #{worktree_path}: #{String.trim(output)}")

          :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  # ---- internals ----------------------------------------------------------

  defp resolve_branch(path, opts) do
    case Keyword.get(opts, :branch) do
      nil -> current_branch(path)
      branch when is_binary(branch) -> {:ok, branch}
    end
  end

  defp run_git(args, opts) do
    cd = Keyword.get(opts, :cd)

    if is_binary(cd) and not File.dir?(cd) do
      {:error, {:git_failed, "cwd does not exist: #{cd}"}}
    else
      case System.cmd("git", args, stderr_to_stdout: true, cd: cd) do
        {output, 0} -> {:ok, output}
        {output, _nonzero} -> {:error, {:git_failed, String.trim(output)}}
      end
    end
  rescue
    e in ErlangError ->
      # `System.cmd` raises if git isn't on PATH.
      {:error, {:git_failed, Exception.message(e)}}
  end
end
