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
  alias Arbiter.Test.GitFixture
  alias Arbiter.Test.StubFixRoundDispatcher
  alias Arbiter.Worker
  alias Arbiter.Worker.ConflictAbortFindings
  alias Arbiter.Worker.PrivateClone

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
  defp park_on(ws, repo, branch, verdict, meta, rounds, recorded \\ nil) do
    {:ok, task} =
      Ash.create(Issue, %{title: "conflicted task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)
    :ok = seed_feature_branch(repo, branch)
    # Recorded before the verdict reaches the author, as the gate does.
    record_conflict_rounds(task, rounds, recorded || conflict_findings())

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

  defp record_conflict_rounds(task, n, findings, offset \\ 0)

  defp record_conflict_rounds(_task, 0, _findings, _offset), do: :ok

  defp record_conflict_rounds(task, n, findings, offset) do
    for round <- (offset + 1)..(offset + n) do
      {:ok, _} =
        Ash.create(Round, %{
          task_id: task.id,
          round: round,
          role: :review,
          verdict: :request_changes,
          findings: findings,
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

  defp new_ws do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pc-#{System.unique_integer([:positive])}",
        prefix: "pc",
        config: %{"review" => %{"required" => true}}
      })

    ws
  end

  defp findings_at(head, files \\ ["a.ex"]),
    do: ConflictAbortFindings.findings(%{branch: "feature/x", target_branch: "main"}, files, head)

  describe "podman fix-round worktree (private clone), bd-6sosvl" do
    # A podman worker's checkout is a private clone (git layout B) whose
    # `origin/<target>` is a copy the host made when it was cut. The gate's
    # conflict round ran in it with nothing to merge: the container can't fetch,
    # and the target ref was stale or absent. The host has to hand it over.
    setup do
      fixture = GitFixture.forge_and_checkout(%{"README.md" => "seed\n"})
      branch = "feature/bd-6sosvl-#{System.unique_integer([:positive])}"
      {:ok, clone} = PrivateClone.create(fixture.checkout, branch, "main")

      GitFixture.commit!(clone, %{"README.md" => "branch version\n"}, "branch edit")

      # The target advances on the forge, behind the clone's back, into the same file.
      GitFixture.git!(fixture.seed, ["pull", "-q", "origin", "main"])
      forge_tip = GitFixture.commit!(fixture.seed, %{"README.md" => "fleet version\n"}, "fleet")
      GitFixture.git!(fixture.seed, ["push", "-q", "origin", "main"])

      Map.merge(fixture, %{clone: clone, branch: branch, forge_tip: forge_tip})
    end

    defp park_in_clone(ctx, rounds) do
      ws = new_ws()

      {:ok, task} =
        Ash.create(Issue, %{title: "podman conflict", workspace_id: ws.id, issue_type: :feature})

      task = put_state!(task, :active)
      record_conflict_rounds(task, rounds, conflict_findings())

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: ctx.branch,
            repo_path: ctx.checkout,
            worktree_path: ctx.clone,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            review_spawn: false
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn ->
        match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(pid))
      end)

      :ok = Worker.review_gate_verdict(pid, {:request_changes, conflict_findings()})
      task
    end

    test "the host provisions the CURRENT origin/<target> before the conflict round is dispatched",
         ctx do
      # Stale: the clone's origin/main is what it was cut with, not the forge tip.
      refute GitFixture.git!(ctx.clone, ["rev-parse", "origin/main"]) == ctx.forge_tip

      park_in_clone(ctx, 1)
      wait_until(fn -> StubFixRoundDispatcher.dispatch_count() == 1 end)

      assert GitFixture.git!(ctx.clone, ["rev-parse", "origin/main"]) == ctx.forge_tip
      assert [%{conflict: true, target_branch: "main"}] = StubFixRoundDispatcher.dispatches()

      # What the container then does: merge it. It conflicts, so the file is
      # unmerged, not "fatal: ambiguous argument".
      assert {out, 1} = git(["merge", "--no-edit", "origin/main"], ctx.clone)
      assert out =~ "CONFLICT"
      _ = git(["merge", "--abort"], ctx.clone)
    end

    test "a clone that lost origin/<target> gets it back", ctx do
      GitFixture.git!(ctx.clone, ["update-ref", "-d", "refs/remotes/origin/main"])

      park_in_clone(ctx, 1)
      wait_until(fn -> StubFixRoundDispatcher.dispatch_count() == 1 end)

      assert GitFixture.git!(ctx.clone, ["rev-parse", "origin/main"]) == ctx.forge_tip
    end

    test "a target ref the host cannot provision escalates once with that reason, no round",
         ctx do
      GitFixture.git!(ctx.clone, ["update-ref", "-d", "refs/remotes/origin/main"])
      GitFixture.git!(ctx.clone, ["remote", "set-url", "origin", Path.join(ctx.root, "gone.git")])

      task = park_in_clone(ctx, 1)
      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)

      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert [{task_id, _, 0, {:no_target_ref, detail}}] = StubFixRoundDispatcher.escalations()
      assert task_id == task.id
      assert detail =~ "origin/main"
    end
  end

  describe "no-progress conflict rounds, bd-6sosvl" do
    test "a second rejection at the same head escalates instead of dispatching again",
         %{repo: repo, ws: ws} do
      stuck = findings_at("abc123")
      task = park_on(ws, repo, "feature/np1", {:request_changes, stuck}, %{}, 2, stuck)

      wait_until(fn -> StubFixRoundDispatcher.escalations() != [] end)
      assert StubFixRoundDispatcher.dispatch_count() == 0
      assert [{task_id, _, 0, :conflict_no_progress}] = StubFixRoundDispatcher.escalations()
      assert task_id == task.id
    end

    test "a second rejection at a NEW head is progress", %{
      repo: repo,
      ws: ws
    } do
      task = park_on(ws, repo, "feature/np2", {:request_changes, findings_at("def456")}, %{}, 0)
      record_conflict_rounds(task, 1, findings_at("abc123"))
      refute ConflictAbortFindings.no_progress?(task.id)
      record_conflict_rounds(task, 1, findings_at("def456"), 1)
      refute ConflictAbortFindings.no_progress?(task.id)
    end

    test "the same head twice is no progress; an unknown head never is", %{
      repo: repo,
      ws: ws
    } do
      task = park_on(ws, repo, "feature/np3", {:request_changes, findings_at("abc123")}, %{}, 0)
      record_conflict_rounds(task, 2, findings_at("abc123"))
      assert ConflictAbortFindings.no_progress?(task.id)

      task2 = park_on(ws, repo, "feature/np4", {:request_changes, conflict_findings()}, %{}, 0)
      record_conflict_rounds(task2, 2, conflict_findings())
      refute ConflictAbortFindings.no_progress?(task2.id)
    end
  end
end
