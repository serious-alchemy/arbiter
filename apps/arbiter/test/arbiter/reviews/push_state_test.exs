defmodule Arbiter.Reviews.PushStateTest do
  @moduledoc """
  bd-2jkrqu: the primitive that answers "is the head we are about to review (or
  about to tell a human to merge) actually ON the remote branch the PR points
  at?".

  The incident this comes from (vs-5l45oz, MR !228): a fix round committed
  `edadf22c` in the worktree and never pushed. The reviewer read the local
  worktree, marked every finding `[ADDRESSED]`, and the park escalation then
  told a human "the branch is pushed … merge it by hand". The MR still held
  the unfixed `8deed4e5`.

  Every assertion here runs against a real git repo with a real bare origin —
  push state is a git fact, and a stubbed one would not have caught the bug.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Reviews.PushState

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "push-state-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  # ---- helpers -------------------------------------------------------------

  defp git!(args, cd) do
    {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    out
  end

  defp git(args, cd), do: System.cmd("git", args, cd: cd, stderr_to_stdout: true)

  defp init_repo(tmp, opts \\ []) do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    git!(["init", "-q", "-b", "main", "."], repo)
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)

    if Keyword.get(opts, :origin, true) do
      bare = Path.join(tmp, "origin.git")
      git!(["init", "-q", "--bare", "-b", "main", bare], tmp)
      git!(["remote", "add", "origin", bare], repo)
      git!(["push", "-q", "origin", "main"], repo)
    end

    repo
  end

  defp commit(repo, name) do
    File.write!(Path.join(repo, name), "#{name}\n")
    git!(["add", name], repo)
    git!(["commit", "-q", "-m", name], repo)
    sha(repo, "HEAD")
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp branch(repo, name) do
    git!(["checkout", "-q", "-b", name], repo)
    name
  end

  # ---- inspect_branch/3 ----------------------------------------------------

  describe "inspect_branch/3" do
    test "a branch whose HEAD is the remote tip is :in_sync and counts as pushed",
         %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)

      state = PushState.inspect_branch(repo, b)

      assert state.status == :in_sync
      assert state.local_head == sha(repo, "HEAD")
      assert state.remote_head == state.local_head
      assert PushState.verdict(state) == :pushed
    end

    test "a local commit ahead of origin is :ahead and counts as unpushed (the vs-5l45oz shape)",
         %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      pushed = commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)
      local = commit(repo, "fix.txt")

      state = PushState.inspect_branch(repo, b)

      assert state.status == :ahead
      assert state.local_head == local
      assert state.remote_head == pushed
      assert PushState.verdict(state) == :unpushed
      assert PushState.describe(state) =~ "NOT pushed"
    end

    test "a branch that was never pushed is :no_remote_branch and counts as unpushed",
         %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      commit(repo, "a.txt")

      state = PushState.inspect_branch(repo, b)

      assert state.status == :no_remote_branch
      assert state.remote_head == nil
      assert PushState.verdict(state) == :unpushed
    end

    test "a local branch behind the remote still counts as pushed", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      behind = commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)
      ahead = commit(repo, "b.txt")
      git!(["push", "-q", "origin", b], repo)
      git!(["reset", "-q", "--hard", behind], repo)

      state = PushState.inspect_branch(repo, b)

      assert state.status == :behind
      assert state.remote_head == ahead
      assert PushState.verdict(state) == :pushed
    end

    test "a repo with no origin remote is :no_origin and the verdict is :unknown (fail open)",
         %{tmp: tmp} do
      repo = init_repo(tmp, origin: false)
      b = branch(repo, "feature/x")
      commit(repo, "a.txt")

      state = PushState.inspect_branch(repo, b)

      assert state.status == :no_origin
      assert PushState.verdict(state) == :unknown
    end

    # bd-2jkrqu review round 1, finding 1: the repo-as-worktree shape. HEAD is
    # on `main`, `feature/x` is a local branch one commit ahead and checked out
    # nowhere. `rev-parse HEAD` answers for `main`, so comparing it against
    # `origin/feature/x` — and worse, pushing it there — is about the wrong
    # commit entirely.
    test "a worktree that is not checked out on the branch is :not_on_branch / :unknown",
         %{tmp: tmp} do
      repo = init_repo(tmp)
      git!(["branch", "feature/x"], repo)
      # advance feature/x without checking it out
      git!(["checkout", "-q", "feature/x"], repo)
      feature_head = commit(repo, "a.txt")
      git!(["checkout", "-q", "main"], repo)
      main_head = sha(repo, "HEAD")
      refute main_head == feature_head

      state = PushState.inspect_branch(repo, "feature/x")

      assert state.status == :not_on_branch
      assert state.checked_out == "main"
      assert PushState.verdict(state) == :unknown
      assert PushState.describe(state) =~ "not on `feature/x`"
      refute PushState.describe(state) =~ "NOT pushed"
    end

    test "a detached HEAD is :not_on_branch, not an accusation", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      head = commit(repo, "a.txt")
      git!(["checkout", "-q", "--detach", head], repo)

      state = PushState.inspect_branch(repo, b)

      assert state.status == :not_on_branch
      assert PushState.verdict(state) == :unknown
    end

    test "no worktree path or no branch is :unknown, never a false accusation" do
      assert PushState.verdict(PushState.inspect_branch(nil, "feature/x")) == :unknown
      assert PushState.verdict(PushState.inspect_branch("/nonexistent/xyz", "b")) == :unknown
      assert PushState.verdict(PushState.inspect_branch("/tmp", nil)) == :unknown
    end
  end

  # ---- ensure_pushed/3 -----------------------------------------------------

  describe "ensure_pushed/3" do
    test "pushes a local commit that origin does not have", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      git!(["push", "-q", "-u", "origin", b], repo)
      local = commit(repo, "fix.txt")

      assert {:ok, :pushed, state} = PushState.ensure_pushed(repo, b)
      assert state.status == :in_sync
      assert state.remote_head == local
      assert sha(repo, "origin/" <> b) == local
    end

    test "publishes a branch origin has never seen", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      local = commit(repo, "a.txt")

      assert {:ok, :pushed, state} = PushState.ensure_pushed(repo, b)
      assert state.remote_head == local
      assert PushState.verdict(state) == :pushed
    end

    test "an already-pushed head is a no-op", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)

      assert {:ok, :already_pushed, state} = PushState.ensure_pushed(repo, b)
      assert state.status == :in_sync
    end

    test "a diverged branch errors instead of force-pushing over the remote", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      base = commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)

      # Another clone advances the remote; the local branch rewrites its own tip.
      other = Path.join(tmp, "other")
      git!(["clone", "-q", Path.join(tmp, "origin.git"), other], tmp)
      git!(["config", "user.email", "o@example.com"], other)
      git!(["config", "user.name", "O"], other)
      git!(["config", "commit.gpgsign", "false"], other)
      git!(["checkout", "-q", b], other)
      remote_only = commit(other, "theirs.txt")
      git!(["push", "-q", "origin", b], other)

      git!(["reset", "-q", "--hard", base], repo)
      mine = commit(repo, "mine.txt")

      assert {:error, _reason, state} = PushState.ensure_pushed(repo, b)
      assert state.status == :diverged
      assert PushState.verdict(state) == :unpushed

      # The remote was NOT clobbered.
      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/" <> b) == remote_only
      assert sha(repo, "HEAD") == mine
    end

    # The write this guard must never make (bd-2jkrqu review round 1, finding 1):
    # `git push origin HEAD:refs/heads/feature/x` from a worktree sitting on
    # `main` publishes `main`'s tip AS the PR branch. Where the remote branch
    # already exists and is an ancestor, it fast-forwards the real PR branch
    # onto unrelated content.
    test "a worktree on another branch pushes nothing and moves no ref on origin",
         %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      published = commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)
      commit(repo, "unpushed.txt")
      git!(["checkout", "-q", "main"], repo)
      main_head = sha(repo, "HEAD")

      # The shape where the damage is worst: origin/<branch> exists and main is
      # its ancestor, so a push would silently fast-forward it onto main.
      assert {_, 0} =
               System.cmd("git", ["merge-base", "--is-ancestor", main_head, published],
                 cd: repo,
                 stderr_to_stdout: true
               )

      assert {:ok, :unknown, state} = PushState.ensure_pushed(repo, b)
      assert state.status == :not_on_branch

      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/" <> b) == published
    end

    test "a worktree on another branch creates no ref for a branch origin has never seen",
         %{tmp: tmp} do
      repo = init_repo(tmp)
      git!(["checkout", "-q", "-b", "feature/x"], repo)
      commit(repo, "a.txt")
      git!(["checkout", "-q", "main"], repo)

      assert {:ok, :unknown, _state} = PushState.ensure_pushed(repo, "feature/x")

      git!(["fetch", "-q", "origin"], repo)
      assert sha(repo, "origin/feature/x") == nil

      {out, _} = git(["ls-remote", "--heads", "origin", "feature/x"], repo)
      assert String.trim(out) == "", "a ref was created on origin: #{out}"
    end

    test "a repo with no origin fails open rather than escalating", %{tmp: tmp} do
      repo = init_repo(tmp, origin: false)
      b = branch(repo, "feature/x")
      commit(repo, "a.txt")

      assert {:ok, :unknown, state} = PushState.ensure_pushed(repo, b)
      assert state.status == :no_origin
    end
  end

  # ---- ensure_pushed/3: a rebased own branch (bd-4axlg0) --------------------
  #
  # A podman fix round rebases its branch onto current main and commits; the
  # host (which holds the forge credential) must deliver that rewrite. The
  # rewrite is a lease-pinned push, allowed only when the remote branch holds
  # nothing Arbiter has not got: its head is the one Arbiter last pushed
  # (`:expected_remote`), or every remote-only commit is patch-equivalent to a
  # commit the rewritten history still carries.

  describe "ensure_pushed/3 delivering a rebase of the ticket's own branch" do
    test "pushes the rebase when the remote head is the one Arbiter last pushed", %{tmp: tmp} do
      {repo, b, pushed} = rebased_branch(tmp, amend: true)
      local = sha(repo, "HEAD")
      assert local != pushed

      assert {:ok, :pushed, state} = PushState.ensure_pushed(repo, b, expected_remote: pushed)
      assert state.status == :in_sync
      assert remote_sha(tmp, b) == local
    end

    test "pushes a clean rebase whose commits are patch-equivalent, with no recorded head",
         %{tmp: tmp} do
      {repo, b, pushed} = rebased_branch(tmp)
      local = sha(repo, "HEAD")
      assert local != pushed

      assert {:ok, :pushed, _state} = PushState.ensure_pushed(repo, b)
      assert remote_sha(tmp, b) == local
    end

    test "refuses when a third party pushed a commit Arbiter did not, even with a recorded head",
         %{tmp: tmp} do
      {repo, b, pushed} = rebased_branch(tmp)
      theirs = third_party_push(tmp, b)

      assert {:error, :diverged, state} =
               PushState.ensure_pushed(repo, b, expected_remote: pushed)

      assert state.status == :diverged
      assert remote_sha(tmp, b) == theirs
    end

    test "refuses an unrecorded rebase when the remote carries a unique commit", %{tmp: tmp} do
      {repo, b, _pushed} = rebased_branch(tmp, amend: true)
      theirs = third_party_push(tmp, b)

      assert {:error, :diverged, _state} = PushState.ensure_pushed(repo, b)
      assert remote_sha(tmp, b) == theirs
    end

    test "the lease holds if the remote moves between the check and the push", %{tmp: tmp} do
      {repo, b, pushed} = rebased_branch(tmp, amend: true)

      # A third party lands a commit after our check, just as the push starts.
      other = clone_other(tmp)
      git!(["checkout", "-q", b], other)
      theirs = commit(other, "theirs.txt")
      hook = Path.join([repo, ".git", "hooks", "pre-push"])

      File.write!(hook, """
      #!/bin/sh
      unset GIT_DIR
      git -C #{other} push -q origin #{b}
      exit 0
      """)

      File.chmod!(hook, 0o755)

      assert {:error, :push_failed, _state} =
               PushState.ensure_pushed(repo, b, expected_remote: pushed)

      assert remote_sha(tmp, b) == theirs
    end

    test "rewrites only the ticket's own branch", %{tmp: tmp} do
      {repo, b, pushed} = rebased_branch(tmp, amend: true)
      main_before = remote_sha(tmp, "main")

      assert {:ok, :pushed, _} = PushState.ensure_pushed(repo, b, expected_remote: pushed)
      assert remote_sha(tmp, "main") == main_before
    end

    test "a worktree on another branch still pushes nothing", %{tmp: tmp} do
      {repo, b, pushed} = rebased_branch(tmp, amend: true)
      git!(["checkout", "-q", "main"], repo)

      assert {:ok, :unknown, _} = PushState.ensure_pushed(repo, b, expected_remote: pushed)
      assert remote_sha(tmp, b) == pushed
    end
  end

  # origin/main moves on; the feature branch (already pushed) is rebased onto it.
  # `amend: true` also rewrites a commit's content, so its patch-id changes.
  defp rebased_branch(tmp, opts \\ []) do
    repo = init_repo(tmp)
    b = branch(repo, "feature/x")
    commit(repo, "a.txt")
    commit(repo, "b.txt")
    git!(["push", "-q", "-u", "origin", b], repo)
    pushed = sha(repo, "HEAD")

    other = clone_other(tmp)
    git!(["checkout", "-q", "main"], other)
    commit(other, "main-moved.txt")
    git!(["push", "-q", "origin", "main"], other)

    git!(["fetch", "-q", "origin"], repo)
    git!(["rebase", "-q", "origin/main"], repo)

    if Keyword.get(opts, :amend, false) do
      File.write!(Path.join(repo, "b.txt"), "amended while resolving\n")
      git!(["commit", "-q", "-a", "--amend", "--no-edit"], repo)
    end

    {repo, b, pushed}
  end

  defp clone_other(tmp) do
    other = Path.join(tmp, "other")

    unless File.dir?(other) do
      git!(["clone", "-q", Path.join(tmp, "origin.git"), other], tmp)
      git!(["config", "user.email", "o@example.com"], other)
      git!(["config", "user.name", "O"], other)
      git!(["config", "commit.gpgsign", "false"], other)
    end

    other
  end

  defp third_party_push(tmp, b) do
    other = clone_other(tmp)
    git!(["checkout", "-q", b], other)
    theirs = commit(other, "theirs.txt")
    git!(["push", "-q", "origin", b], other)
    theirs
  end

  defp remote_sha(tmp, b) do
    git!(["rev-parse", "refs/heads/" <> b], Path.join(tmp, "origin.git")) |> String.trim()
  end

  # ---- reviewable_head/3 ---------------------------------------------------

  describe "reviewable_head/3" do
    test "returns the head when it is on the remote branch", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      head = commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)

      assert {:ok, ^head} = PushState.reviewable_head(repo, b)
    end

    test "refuses an unpushed local head", %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)
      commit(repo, "fix.txt")

      assert {:error, {:head_not_pushed, state}} = PushState.reviewable_head(repo, b)
      assert state.status == :ahead
    end

    test "falls back to the local head when the worktree is on another branch",
         %{tmp: tmp} do
      repo = init_repo(tmp)
      b = branch(repo, "feature/x")
      commit(repo, "a.txt")
      git!(["push", "-q", "-u", "origin", b], repo)
      commit(repo, "unpushed.txt")
      git!(["checkout", "-q", "main"], repo)
      main_head = sha(repo, "HEAD")

      assert {:ok, ^main_head} = PushState.reviewable_head(repo, b)
    end

    test "fails open when push state cannot be determined", %{tmp: tmp} do
      repo = init_repo(tmp, origin: false)
      b = branch(repo, "feature/x")
      head = commit(repo, "a.txt")

      assert {:ok, ^head} = PushState.reviewable_head(repo, b)
    end
  end
end
