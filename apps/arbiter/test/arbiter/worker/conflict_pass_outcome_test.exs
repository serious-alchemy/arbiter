defmodule Arbiter.Worker.ConflictPassOutcomeTest do
  # bd-4olwyg: a conflict pass that ended mid-rebase, without pushing, was
  # recorded `succeeded`. The verdict reads the pass's worktree and the PR
  # branch's remote head; these tests drive it against real git.
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ConflictPassOutcome
  alias Arbiter.Worker.Worktree

  @branch "bugfix/bd-cpo-probe"

  setup do
    tmp = Path.join(System.tmp_dir!(), "cpo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    remote = Path.join(tmp, "remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])

    wt = Path.join(tmp, "wt")
    {_, 0} = System.cmd("git", ["clone", "-q", remote, wt], stderr_to_stdout: true)
    configure!(wt)
    :ok = commit!(wt, "README.md", "hello\n", "initial")
    {_, 0} = git(wt, ["push", "-q", "origin", "HEAD:main"])
    {_, 0} = git(wt, ["checkout", "-q", "-b", @branch])
    :ok = commit!(wt, "README.md", "branch side\n", "branch edit")
    {_, 0} = git(wt, ["push", "-q", "-u", "origin", @branch])

    start_head = Worktree.remote_head(wt, @branch)
    assert is_binary(start_head)

    meta = %{
      role: :conflict_resolver,
      worktree_path: wt,
      conflict_resolver_branch: @branch,
      conflict_start_head: start_head
    }

    %{tmp: tmp, remote: remote, wt: wt, meta: meta, start_head: start_head}
  end

  describe "Worktree.remote_head/2" do
    test "is the branch's sha on origin, nil for a branch origin lacks", %{wt: wt} do
      {sha, 0} = git(wt, ["rev-parse", "HEAD"])
      assert Worktree.remote_head(wt, @branch) == String.trim(sha)
      assert Worktree.remote_head(wt, "no/such-branch") == nil
    end
  end

  describe "verdict/1" do
    test "the incident: stopped mid-rebase with nothing pushed is unresolved", %{
      tmp: tmp,
      remote: remote,
      wt: wt,
      meta: meta,
      start_head: start_head
    } do
      :ok = advance_main!(tmp, remote, "README.md", "main side\n")
      {_, 0} = git(wt, ["fetch", "-q", "origin", "main"])
      {_, status} = git(wt, ["rebase", "origin/main"])
      assert status != 0

      assert {:unresolved, reason} = ConflictPassOutcome.verdict(meta)
      assert reason =~ "mid-rebase"
      assert reason =~ "README.md"
      assert reason =~ String.slice(start_head, 0, 8)
    end

    test "a clean worktree whose PR head never moved is unresolved", %{
      meta: meta,
      start_head: start_head
    } do
      assert {:unresolved, reason} = ConflictPassOutcome.verdict(meta)
      assert reason =~ "without pushing"
      assert reason =~ String.slice(start_head, 0, 8)
    end

    test "a pushed resolution is resolved", %{wt: wt, meta: meta} do
      :ok = commit!(wt, "RESOLVED.md", "done\n", "resolve")
      {_, 0} = git(wt, ["push", "-q", "origin", @branch])

      assert ConflictPassOutcome.verdict(meta) == :resolved
    end

    test "a push that left a later rebase stopped part-way is still unresolved", %{
      tmp: tmp,
      remote: remote,
      wt: wt,
      meta: meta
    } do
      :ok = commit!(wt, "RESOLVED.md", "done\n", "resolve")
      {_, 0} = git(wt, ["push", "-q", "origin", @branch])
      :ok = advance_main!(tmp, remote, "README.md", "main side\n")
      {_, 0} = git(wt, ["fetch", "-q", "origin", "main"])
      {_, status} = git(wt, ["rebase", "origin/main"])
      assert status != 0

      assert {:unresolved, reason} = ConflictPassOutcome.verdict(meta)
      assert reason =~ "mid-rebase"
    end

    test "a push that still conflicts with the target's current tip is unresolved", %{
      tmp: tmp,
      remote: remote,
      wt: wt,
      meta: meta
    } do
      # The target moves on, and the pass pushes without ever having seen it
      # (a rebase onto a stale `origin/main`): the head moves, the PR still conflicts.
      :ok = advance_main!(tmp, remote, "README.md", "main side\n")
      :ok = commit!(wt, "RESOLVED.md", "done\n", "resolve")
      {_, 0} = git(wt, ["push", "-q", "origin", @branch])
      pushed = Worktree.remote_head(wt, @branch)

      assert {:unresolved, reason} = ConflictPassOutcome.verdict(with_target(meta, wt))
      assert reason =~ "still conflicts"
      assert reason =~ "main"
      assert reason =~ String.slice(pushed, 0, 8)
    end

    test "a push that merges cleanly with the target's current tip is resolved", %{
      tmp: tmp,
      remote: remote,
      wt: wt,
      meta: meta
    } do
      :ok = advance_main!(tmp, remote, "OTHER.md", "main side\n")
      :ok = commit!(wt, "RESOLVED.md", "done\n", "resolve")
      {_, 0} = git(wt, ["push", "-q", "origin", @branch])

      assert ConflictPassOutcome.verdict(with_target(meta, wt)) == :resolved
    end

    test "fails open when the target cannot be fetched", %{wt: wt, meta: meta} do
      :ok = commit!(wt, "RESOLVED.md", "done\n", "resolve")
      {_, 0} = git(wt, ["push", "-q", "origin", @branch])

      meta = meta |> with_target(wt) |> Map.put(:target_branch, "no-such-target")
      assert ConflictPassOutcome.verdict(meta) == :resolved
    end

    test "fails open when the pass never recorded where it started", %{meta: meta} do
      assert ConflictPassOutcome.verdict(Map.delete(meta, :conflict_start_head)) == :resolved
      assert ConflictPassOutcome.verdict(%{role: :conflict_resolver}) == :resolved
    end

    test "fails open when the remote head cannot be read", %{meta: meta, wt: wt} do
      {_, 0} = git(wt, ["remote", "remove", "origin"])

      assert ConflictPassOutcome.verdict(meta) == :resolved
    end
  end

  describe "settle_worktree/1" do
    test "aborts a rebase the pass left stopped, restoring the branch", %{
      tmp: tmp,
      remote: remote,
      wt: wt,
      meta: meta,
      start_head: start_head
    } do
      :ok = advance_main!(tmp, remote, "README.md", "main side\n")
      {_, 0} = git(wt, ["fetch", "-q", "origin", "main"])
      {_, status} = git(wt, ["rebase", "origin/main"])
      assert status != 0

      assert ConflictPassOutcome.settle_worktree(meta) == {:ok, :rebase}
      assert Worktree.in_progress_operation(wt) == nil
      assert {:ok, @branch} = Worktree.current_branch(wt)
      {head, 0} = git(wt, ["rev-parse", "HEAD"])
      assert String.trim(head) == start_head
    end

    test "is a no-op on a clean worktree or a meta without one", %{meta: meta} do
      assert ConflictPassOutcome.settle_worktree(meta) == {:ok, nil}
      assert ConflictPassOutcome.settle_worktree(%{}) == {:ok, nil}
    end
  end

  # The pass's meta as `ConflictResolver` records it: the target and the main repo
  # (here the same checkout) the host refreshes `origin/<target>` in.
  defp with_target(meta, repo), do: Map.merge(meta, %{target_branch: "main", repo_path: repo})

  defp git(path, args), do: System.cmd("git", ["-C", path | args], stderr_to_stdout: true)

  defp configure!(path) do
    {_, 0} = git(path, ["config", "user.email", "t@e.com"])
    {_, 0} = git(path, ["config", "user.name", "T"])
    {_, 0} = git(path, ["config", "commit.gpgsign", "false"])
    :ok
  end

  defp commit!(path, file, content, msg) do
    File.write!(Path.join(path, file), content)
    {_, 0} = git(path, ["add", file])
    {_, 0} = git(path, ["commit", "-q", "-m", msg])
    :ok
  end

  defp advance_main!(tmp, remote, file, content) do
    clone = Path.join(tmp, "advance-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", "-b", "main", remote, clone])
    configure!(clone)
    :ok = commit!(clone, file, content, "advance main")
    {_, 0} = git(clone, ["push", "-q", "origin", "main"])
    :ok
  end
end
