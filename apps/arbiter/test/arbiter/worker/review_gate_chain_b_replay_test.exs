defmodule Arbiter.Worker.ReviewGateChainBReplayTest do
  @moduledoc """
  Chain B, replayed (bd-9zuvbh / P9, design #1635 §4.6).

  Four incidents — bd-6dxit2, bd-869mmg, bd-1xss5z, bd-c6tdbu — and four
  different defects, all ending in the same place: **a failed run on work that
  was fine.** §4.6's whole point is that the ending is a policy choice, not a
  parsing problem, and class C removes it without touching the parser (which
  stays bd-3hb4ih's ticket).

  One test per shape, each driving the real gate with a real reviewer fixture
  and asserting the same four things:

    1. the run row finishes `:failed` with a review-gate cause, and — unlike a
       genuine rejection — the ticket is parked (since bd-1uu19b the park lives
       on the ticket, not in a `:review_parked` run status);
    2. the task carries the park reason a human can act on;
    3. **exactly one** coordinator escalation (invariant I3);
    4. nothing merged — the content half of the guard is still closed.

  Shape 4 (bd-c6tdbu, second half) no longer parks: bd-93cnn9 found it firing
  twice in production on a clean APPROVE (bd-6d3h8m / PR #2074, bd-9inpfa / PR
  #2084), so a no-op fix round after an approval-gap rejection now merges
  instead, honoring the reviewer's own verdict.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.{Run, RunState}

  @print_timeout Path.expand("../../fixtures/review_print_timeout.sh", __DIR__)
  @no_verdict_auth_prose Path.expand("../../fixtures/review_no_verdict_auth_prose.sh", __DIR__)
  @unaddressed Path.expand("../../fixtures/review_unaddressed_finding.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)
  @revise_commit_once Path.expand("../../fixtures/revise_commit_once.sh", __DIR__)

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

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
  end

  defp wait_until(fun, timeout) do
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
    tmp = Path.join(System.tmp_dir!(), "chain_b-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "chainb-ws-#{System.unique_integer([:positive])}",
        prefix: "cb",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "chain-b task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)
    task
  end

  # Start a real author + a real gate over `repo`, and wait for the gate to
  # reach its terminal state.
  defp run_gate(task, repo, extra_meta) do
    branch = "feature/chain-b"
    :ok = seed_feature_branch(repo, branch)

    meta =
      Map.merge(
        %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          worktree_path: repo,
          review_timeout_ms: 5_000
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end, 10_000)
    pid
  end

  # The run row for the AUTHORING worker (the reviewer's own passes run under
  # their own `<task>#review…` ids and are irrelevant here).
  defp author_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  defp escalations(ws, task) do
    "admiral"
    |> Message.inbox(workspace_id: ws.id)
    |> Enum.filter(&(&1.directive_ref == task.id and &1.kind == :escalation))
  end

  # The four assertions every chain-B shape must now satisfy.
  defp assert_parked(task, ws, repo, reason) do
    parked = Ash.get!(Issue, task.id)

    assert parked.attention_cause == reason
    assert %DateTime{} = parked.attention_since

    run = author_run(task.id)
    assert run.state == :finished

    assert run.outcome == :failed,
           "run was #{RunState.label(run.state, run.outcome)}, expected finished (failed)"

    assert run.failure_reason in [":review_gate_inconclusive", ":review_gate_rejected"]

    assert [escalation] = escalations(ws, task)
    assert escalation.subject =~ "parked"
    assert escalation.body =~ "was NOT failed"

    assert merge_commit_count(repo) == 0
  end

  # bd-6dxit2 / bd-869mmg: the reviewer said something the scan could not parse
  # as a verdict. Today: `:review_gate_inconclusive`, run failed, 52 runs /
  # $226.97. Under class C: one page, parked, run intact.
  test "shape 1 — a verdict the gate cannot parse parks instead of failing the run",
       %{repo: repo, ws: ws} do
    task = new_task(ws)
    run_gate(task, repo, %{review_command: [@no_verdict_auth_prose]})

    assert_parked(task, ws, repo, :inconclusive)
  end

  # bd-1xss5z: the reviewer's own print timeout truncates the review and the CLI
  # still exits 0 with a terminal SUCCESS event. The truncation is still a bug;
  # it stops costing a run.
  test "shape 2 — a reviewer print timeout parks instead of failing the run",
       %{repo: repo, ws: ws} do
    task = new_task(ws)
    run_gate(task, repo, %{review_command: [@print_timeout]})

    assert_parked(task, ws, repo, :reviewer_timeout)

    assert [escalation] = escalations(ws, task)
    assert escalation.body =~ "timed out"
  end

  # bd-c6tdbu, first half: the `:unaddressed_findings` guard (G10) refuses an
  # honest APPROVE over an observation it read as an open finding, the re-prompt
  # budget goes, and the round cap arrives. The APPROVE is still NOT accepted —
  # content stays fail-closed — but the run no longer dies for it.
  test "shape 3 — a verdict guard that exhausts its budget at the round cap parks",
       %{repo: repo, ws: ws} do
    task = new_task(ws)

    run_gate(task, repo, %{
      review_rounds: 2,
      review_command: [@unaddressed, "NOT_ADDRESSED"],
      revise_command: [@revise_commit]
    })

    assert_parked(task, ws, repo, :verdict_guard_exhausted)

    # AC3 — content stays fail-closed. The reviewer's APPROVE was refused, not
    # quietly honoured because the run no longer fails: nothing merged (asserted
    # above), the task never got a reviewed-SHA stamp, and no `:reviewed`
    # coverage row was written for the head.
    parked = Ash.get!(Issue, task.id)
    assert parked.state == :active
    assert parked.last_reviewed_sha == nil
    assert Ash.read!(Arbiter.Reviews.Coverage.Entry) == []
  end

  # bd-c6tdbu, second half — superseded by bd-93cnn9: the fix round the
  # gap-rejected APPROVE forced had nothing to fix, so HEAD did not move. This
  # USED to park behind a human decision (naming the open finding, bd-c6tdbu's
  # own AC4); observed live twice in production (bd-6d3h8m / PR #2074, bd-9inpfa
  # / PR #2084), both times the fix round correctly found nothing to change and
  # the park cost a slot and a coordinator hand-ruling on work already
  # approved. A no-op fix round is evidence FOR the reviewer's own APPROVE, not
  # grounds to override it — so the gate now merges instead, the same as any
  # other converging round.
  test "shape 4 — a no-op fix round after an approval-gap rejection merges instead of parking",
       %{repo: repo, ws: ws} do
    task = new_task(ws)
    branch = "feature/chain-b"
    :ok = seed_feature_branch(repo, branch)

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          worktree_path: repo,
          review_timeout_ms: 5_000,
          review_rounds: 3,
          review_command: [@unaddressed, "NOT_ADDRESSED"],
          revise_command: [@revise_commit_once]
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(
      fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end,
      10_000
    )

    assert merge_commit_count(repo) == 1
    refute Ash.get!(Issue, task.id) |> Arbiter.Tasks.ReviewPark.parked?()
    assert escalations(ws, task) == []
  end

  # Round 1 review finding: a reviewer that could never be SPAWNED (quota gate
  # refusal, no outpost, an adapter error out of `start_worker_session/4`) is the
  # same no-verdict liveness failure as a reviewer session that dies one step
  # later — and it fires on every revise round's re-review too, so leaving it
  # failing would let a round-2 spawn failure kill a run whose round-1 work was
  # fine. It parks as `:reviewer_failed`.
  test "a reviewer that cannot be spawned parks instead of failing the run",
       %{repo: repo, ws: ws} do
    task = new_task(ws)

    run_gate(task, repo, %{
      review_command: [Path.join(repo, "no-such-reviewer-executable")]
    })

    assert_parked(task, ws, repo, :reviewer_failed)
  end

  # AC4's other half: re-running the review is one of the two human actions that
  # resolve a park, and it has to clear it *when the gate starts* — not when the
  # next verdict lands — or `arb prime` keeps showing a park somebody is already
  # working on.
  test "re-running the review clears an existing park", %{repo: repo, ws: ws} do
    task = new_task(ws)
    {:ok, :claimed, _} = Arbiter.Tasks.ReviewPark.park(task.id, :inconclusive)

    run_gate(task, repo, %{review_command: [@no_verdict_auth_prose]})

    # The re-run cleared the old park; this run reached its own terminal and
    # parked again, which is a fresh episode with its own page.
    assert [_one] = escalations(ws, task)
    assert Ash.get!(Issue, task.id).attention_cause == :inconclusive
  end
end
