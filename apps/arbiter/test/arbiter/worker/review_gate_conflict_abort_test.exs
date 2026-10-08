defmodule Arbiter.Worker.ReviewGateConflictAbortTest do
  @moduledoc """
  bd-1u15tl: a ReviewGate rejection that is only the gate's own "branch
  conflicts with its target, merge aborted" message is not a code finding, so it
  must not spend the author's fix-round budget (bd-7fjfgv, PR #463, was
  escalated "fix rounds exhausted after 1 round(s)" by two of them).
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubFixRoundDispatcher
  alias Arbiter.Worker
  alias Arbiter.Worker.ConflictAbortFindings

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
    repo
  end

  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    StubFixRoundDispatcher.reset()

    tmp = Path.join(System.tmp_dir!(), "rg_conflict-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "conflict-ws-#{System.unique_integer([:positive])}",
        prefix: "cf",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp conflict_findings(files \\ ["lib/a_controller.ex"]),
    do: ConflictAbortFindings.findings(%{branch: "feature/x", target_branch: "main"}, files)

  # The author parks on a verdict handed to it directly, the way the gate
  # delivers one (`review_spawn: false` skips starting a real gate).
  defp park_on(ws, repo, branch, verdict, meta, rounds) do
    {:ok, task} =
      Ash.create(Issue, %{title: "conflicted task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)
    :ok = seed_feature_branch(repo, branch)
    # Recorded before the verdict reaches the author, as the gate does.
    record_conflict_rounds(task, rounds)

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta:
          Map.merge(
            %{
              branch: branch,
              repo_path: repo,
              target_branch: "main",
              merge_title: "Merge #{task.id}",
              review_required: true,
              review_spawn: false
            },
            meta
          )
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(pid)) end)
    :ok = Worker.review_gate_verdict(pid, verdict)
    task
  end

  defp record_conflict_rounds(_task, 0), do: :ok

  defp record_conflict_rounds(task, n) do
    for round <- 1..n do
      {:ok, _} =
        Ash.create(Round, %{
          task_id: task.id,
          round: round,
          role: :review,
          verdict: :request_changes,
          findings: conflict_findings(),
          converged: false
        })
    end
  end

  test "the gate's conflict message is recognised, and a code finding is not" do
    assert ConflictAbortFindings.escalation?(conflict_findings())
    refute ConflictAbortFindings.escalation?("VERDICT: REQUEST_CHANGES\n- a real finding")
    refute ConflictAbortFindings.escalation?(nil)
  end

  test "a conflict rejection dispatches a round without spending the fix-round budget",
       %{repo: repo, ws: ws} do
    # The budget is already spent: a code finding now would be `:budget_exhausted`.
    meta = %{review_gate_fix_round_attempts: 1, review_gate_findings_digest: "abc123"}
    _task = park_on(ws, repo, "feature/c1", {:request_changes, conflict_findings()}, meta, 1)

    wait_until(fn -> StubFixRoundDispatcher.dispatch_count() == 1 end)

    assert [args] = StubFixRoundDispatcher.dispatches()
    assert args.conflict == true
    # Not one more than were already run, and the real findings' digest is kept.
    assert args.attempt == 1
    assert args.findings_digest == "abc123"
    assert StubFixRoundDispatcher.escalations() == []
  end

  test "the same budget still exhausts on a code finding", %{repo: repo, ws: ws} do
    _task =
      park_on(
        ws,
        repo,
        "feature/c2",
        {:request_changes, "VERDICT: REQUEST_CHANGES\n- bug"},
        %{review_gate_fix_round_attempts: 1},
        0
      )

    wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)
    assert StubFixRoundDispatcher.dispatch_count() == 0
    assert [{_, _, 1, :budget_exhausted}] = StubFixRoundDispatcher.escalations()
  end

  test "conflict rounds are bounded on their own account", %{repo: repo, ws: ws} do
    rounds = ConflictAbortFindings.max_rounds() + 1
    task = park_on(ws, repo, "feature/c3", {:request_changes, conflict_findings()}, %{}, rounds)

    wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)
    assert StubFixRoundDispatcher.dispatch_count() == 0
    assert [{task_id, _, 0, :conflict_rounds_exhausted}] = StubFixRoundDispatcher.escalations()
    assert task_id == task.id
  end
end
