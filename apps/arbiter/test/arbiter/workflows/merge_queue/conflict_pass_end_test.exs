defmodule Arbiter.Workflows.MergeQueue.ConflictPassEndTest do
  @moduledoc """
  bd-4olwyg: how a conflict pass's run ends.

  The incident pass (run `9cbd9a3c…`) was stopped 19 seconds in by its ticket's
  Watchdog, mid-rebase with nothing pushed, and recorded `succeeded`. Its
  worktree stayed mid-rebase, so resume found "no preserved worktree" and the
  next conflict dispatch failed on "worktree exists … on a different branch".
  Its ticket stayed In progress with no run, holding the only slot.

  Each pass here spawns through `ConflictResolver.resolve/1` with
  `start_claude: false` against a real repo and a bare `origin`, with the agent's
  side played by git commands in the pass's worktree.
  """

  # async: false — spawns workers under the global Arbiter.Worker.Supervisor and
  # flips :worktree_root app env.
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Watchdog, Worktree}
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueue.ConflictResolver

  setup do
    tmp = Path.join(System.tmp_dir!(), "cpe-#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    remote = Path.join(tmp, "remote.git")
    File.mkdir_p!(repo)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    configure!(repo)
    :ok = commit!(repo, "README.md", "hello\n", "i")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(repo, ["remote", "add", "origin", remote])
    {_, 0} = git(repo, ["push", "-q", "origin", "main"])

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cpe-ws-#{System.unique_integer([:positive])}",
        prefix: "cpe#{System.unique_integer([:positive])}"
      })

    issue = conflicting_ticket(ws, repo)
    inert_lane!(issue)

    {:ok, ws: ws, repo: repo, issue: issue, branch: BranchNamer.derive(issue)}
  end

  test "a pass that signals done mid-rebase is failed, names the state, and is aborted", %{
    ws: ws,
    repo: repo,
    issue: issue,
    branch: branch
  } do
    %{worker_pid: pid, worktree_path: wt} = conflict_pass!(ws, repo, issue)
    start_head = remote_head(repo, branch)
    :ok = start_rebase!(wt)

    signal_done(pid)

    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    run = conflict_run!(issue.id)
    assert run.outcome == :failed
    assert run.failure_reason =~ "conflict_unresolved"
    assert run.failure_reason =~ "mid-rebase"
    assert run.failure_summary =~ String.slice(start_head, 0, 8)

    assert Worktree.in_progress_operation(wt) == nil
    assert {:ok, ^branch} = Worktree.current_branch(wt)
    assert Ash.get!(Issue, issue.id).state == :merging
  end

  test "a pass that signals done without pushing is failed", %{ws: ws, repo: repo, issue: issue} do
    %{worker_pid: pid} = conflict_pass!(ws, repo, issue)

    signal_done(pid)

    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    assert conflict_run!(issue.id).failure_reason =~ "without pushing"
    assert Ash.get!(Issue, issue.id).state == :merging
  end

  test "a pass that pushed its resolution succeeds", %{
    ws: ws,
    repo: repo,
    issue: issue,
    branch: branch
  } do
    %{worker_pid: pid, worktree_path: wt} = conflict_pass!(ws, repo, issue)
    :ok = start_rebase!(wt)
    File.write!(Path.join(wt, "README.md"), "resolved\n")
    {_, 0} = git(wt, ["add", "README.md"])
    {_, 0} = git(wt, ["-c", "core.editor=true", "rebase", "--continue"])
    {_, 0} = git(wt, ["push", "-q", "--force-with-lease", "origin", branch])

    ref = Process.monitor(pid)
    signal_done(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert conflict_run!(issue.id).outcome == :succeeded
    assert Ash.get!(Issue, issue.id).state == :merging
  end

  # The incident's own path: the pass never signalled done — its Watchdog
  # `Worker.stop`ped it (`:normal`) mid-rebase, which `terminate/2` recorded as
  # a success, and nothing sent the ticket back to Merging.
  test "a pass stopped mid-rebase is failed, aborted, and gives its slot back", %{
    ws: ws,
    repo: repo,
    issue: issue,
    branch: branch
  } do
    %{worker_pid: pid, worktree_path: wt} = conflict_pass!(ws, repo, issue)
    :ok = start_rebase!(wt)
    assert Ash.get!(Issue, issue.id).state == :active

    :ok = Worker.stop(pid, :normal)

    run = conflict_run!(issue.id)
    assert run.outcome == :failed
    assert run.failure_reason =~ "mid-rebase"
    assert Worktree.in_progress_operation(wt) == nil
    assert {:ok, ^branch} = Worktree.current_branch(wt)
    assert Ash.get!(Issue, issue.id).state == :merging
  end

  # AC3: a stale worktree a finished run left mid-rebase no longer fails the
  # next dispatch on "worktree exists"; the new pass starts from a clean branch.
  test "the next pass reuses a worktree a finished run left mid-rebase", %{
    ws: ws,
    repo: repo,
    issue: issue,
    branch: branch
  } do
    %{worker_pid: first, worktree_path: wt} = conflict_pass!(ws, repo, issue)
    :ok = Worker.stop(first, :normal)
    :ok = start_rebase!(wt)
    assert {:ok, "HEAD"} = Worktree.current_branch(wt)

    assert %{worker_pid: second, worktree_path: ^wt} = conflict_pass!(ws, repo, issue)
    assert is_pid(second)
    assert Worktree.in_progress_operation(wt) == nil
    assert {:ok, ^branch} = Worktree.current_branch(wt)
  end

  # ---- fixtures -------------------------------------------------------------

  # A ticket Merging with PR #77 whose branch conflicts with main on README.md.
  defp conflicting_ticket(ws, repo) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "conflicts", workspace_id: ws.id, acceptance: "- works"})

    branch = BranchNamer.derive(issue)
    {_, 0} = git(repo, ["checkout", "-q", "-b", branch])
    :ok = commit!(repo, "README.md", "branch side\n", "branch edit")
    {_, 0} = git(repo, ["push", "-q", "origin", branch])
    {_, 0} = git(repo, ["checkout", "-q", "main"])
    :ok = commit!(repo, "README.md", "main side\n", "main edit")
    {_, 0} = git(repo, ["push", "-q", "origin", "main"])

    issue
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)
    |> Ash.update!(%{pr_ref: "#77"}, action: :open_pr)
  end

  defp conflict_pass!(ws, repo, issue) do
    {:ok, %{worker_pid: pid} = info} =
      ConflictResolver.resolve(%{
        task_id: issue.id,
        workspace_id: ws.id,
        repo_path: repo,
        repo: "test/repo",
        start_claude: false
      })

    on_exit(fn -> stop_quietly(pid) end)
    info
  end

  # The agent's side: fetch the target and start the rebase, which stops on the
  # README.md conflict.
  defp start_rebase!(wt) do
    configure!(wt)
    {_, 0} = git(wt, ["fetch", "-q", "origin", "main"])
    {_, status} = git(wt, ["rebase", "origin/main"])
    assert status != 0
    assert Worktree.in_progress_operation(wt) == :rebase
    :ok
  end

  defp signal_done(pid) do
    send(pid, {:__claude_session_done__, "sentinel"})
    _ = :sys.get_state(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp conflict_run!(task_id) do
    [run] =
      Run
      |> Ash.Query.filter(task_id == ^task_id and kind == :conflict)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()

    run
  end

  defp remote_head(repo, branch), do: Worktree.remote_head(repo, branch)

  # A ticket that goes back to Merging has its Watchdog restarted from the
  # row: give it a lane on the stub forge that never polls in a test's time.
  defp inert_lane!(issue) do
    lane = PullRequest.lane(adapter: StubMerger, interval_ms: 60_000, initial_delay_ms: 60_000)
    Ash.update!(Ash.get!(Issue, issue.id), %{merge_watch: lane}, action: :record_merge_watch)

    on_exit(fn ->
      case Watchdog.whereis(issue.id) do
        nil -> :ok
        pid -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, pid)
      end
    end)
  end

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

  defp stop_quietly(pid),
    do: Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
end
