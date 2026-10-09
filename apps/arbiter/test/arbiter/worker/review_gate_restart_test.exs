defmodule Arbiter.Worker.ReviewGateRestartTest do
  @moduledoc """
  bd-2yt0d2 / #291 — a server restart must not strand a ReviewGate pass.

  Real git (a bare origin and a linked worktree), a real author `Worker`, the
  real gate and real reviewer / implementer `Worker`s running shell fixtures.
  "The node dies" is played the way an application stop plays it: the author
  and the pass workers are shut down with `:shutdown` (their `terminate/2`
  stamps the run), and the gate — which does not trap exits — is killed with
  no `terminate/2`, so only what the ticket recorded survives. The boot sweep
  (`Reconciler.reconcile_review_passes/1`) then has to bring each pass back
  with no coordinator action.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.CircuitBreaker
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle.Projection
  alias Arbiter.Tasks.SlotGate
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Worker.ReviewPass
  alias Arbiter.Workers.Reconciler
  alias Arbiter.Workers.Run

  @probe Path.expand("../../fixtures/review_ci_probe.sh", __DIR__)
  @reject_once Path.expand("../../fixtures/review_reject_once.sh", __DIR__)
  @revise_hang Path.expand("../../fixtures/revise_hang.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-rs-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-rs-#{System.unique_integer([:positive])}",
        prefix: "rr",
        config: %{
          "review" => %{"required" => true, "require_ci_green" => false},
          "review_gate" => %{"max_fix_rounds" => 0}
        }
      })

    %{repo: repo, tmp: tmp, ws: ws}
  end

  describe "a review pass running when the node stops" do
    test "restarts on the same head with no coordinator action and reaches a verdict", ctx do
      rig = rig(ctx, "feature/rs-1")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)

      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)
      assert %{"phase" => "reviewing", "round" => 1} = pass_marker(rig)

      node_stops(rig, gate)

      # AC2: the runs say the server stopped under them — not failed.
      assert_interrupted(rig.task.id)
      assert_interrupted(rig.task.id <> "#review")
      assert Ash.get!(Issue, rig.task.id).attention_resume_attempts == 0

      # Restarted: nothing resident, the ticket still holds its slot, and the
      # marker is what says a pass was cut off.
      assert Worker.whereis(rig.task.id) == nil
      assert SlotGate.holds_slot?(Ash.get!(Issue, rig.task.id))

      assert {:ok, %{rearmed: 1, failed: 0, restarted: [entry], not_restarted: []}} =
               Reconciler.reconcile_review_passes(rearm_fun: rearm_fun(rig, command: [@probe]))

      assert %{task_id: task_id, phase: :reviewing, round: 1} = entry
      assert task_id == rig.task.id

      assert_received {:rearmed, {:ok, regate}}
      assert_gate_reports(regate)

      assert passes(rig) == 2
      assert reviewed_head(rig) == rig.head
      assert [%{verdict: :approve, round: 1}] = review_rounds(rig)
      assert implement_runs(rig) == 1
      assert Ash.get!(Issue, rig.task.id).attention_resume_attempts == 0
    end

    test "keeps the resume sweep off the ticket the pass sweep restarted", ctx do
      rig = rig(ctx, "feature/rs-2")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)
      node_stops(rig, gate)

      assert {:ok, %{restarted: [_]} = passes} =
               Reconciler.reconcile_review_passes(rearm_fun: rearm_fun(rig, command: [@probe]))

      assert_received {:rearmed, {:ok, regate}}

      # The restarted gate may already have delivered and cleared its marker;
      # the boot hands the restarted ids on so the resume sweep never races it.
      assert {:ok, %{resumed: 0, escalated: 0}} =
               Reconciler.reconcile_resumable_tasks(
                 skip_ids: Reconciler.restarted_ids([passes]),
                 resume_fun: fn issue -> flunk("resumed #{issue.id}") end
               )

      assert_gate_reports(regate)
    end

    test "keeps the open-PR sweep from handing the restarted ticket to the patrols", ctx do
      rig = rig(ctx, "feature/rs-2b")
      :ok = Arbiter.Tasks.PullRequest.record_review_gate(rig.task.id, %{pr_ref: "#7"})
      Ash.update!(Ash.get!(Issue, rig.task.id), %{pr_ref: "#7"}, action: :update)

      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3, pr_ref: "#7")
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)
      node_stops(rig, gate)

      assert {:ok, %{restarted: [_]} = passes} =
               Reconciler.reconcile_review_passes(rearm_fun: rearm_fun(rig, command: [@probe]))

      assert_received {:rearmed, {:ok, regate}}

      assert {:ok, %{watched: 0, rewatched: 0, escalated: 0}} =
               Reconciler.reconcile_open_pr_tasks(
                 skip_ids: Reconciler.restarted_ids([passes]),
                 watch_fun: fn issue -> flunk("watched #{issue.id}") end,
                 rewatch_fun: fn issue -> flunk("re-watched #{issue.id}") end
               )

      assert_gate_reports(regate)
    end

    test "a pass nobody cut off (author stopped on purpose) is not restarted", ctx do
      rig = rig(ctx, "feature/rs-3")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)

      # An operator stopping the author: the gate goes with it, and takes its
      # marker along — nothing to revive at the next boot.
      ref = Process.monitor(gate)
      :ok = GenServer.stop(rig.author, :normal)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 5_000
      stop_workers(rig, :shutdown)

      assert pass_marker(rig) == nil

      assert {:ok, %{rearmed: 0, failed: 0, restarted: [], not_restarted: []}} =
               Reconciler.reconcile_review_passes(
                 rearm_fun: fn issue -> flunk("rearmed #{issue.id}") end
               )
    end
  end

  describe "a reviewer killed by the server stopping (bd-cqppxr / #615)" do
    test "is interrupted, not parked reviewer_failed, and the round is re-dispatched", ctx do
      rig = rig(ctx, "feature/rs-615")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)

      # The node is stopping: the reviewer's subprocess is SIGKILLed (137) and
      # that exit reaches the gate before the gate itself is stopped.
      put_app_env(:arbiter, :worker_node_stopping_override, true)
      gate_ref = Process.monitor(gate)
      send(gate, {:worker_exited, rig.task.id <> "#review", 137})
      assert_receive {:DOWN, ^gate_ref, :process, ^gate, :shutdown}, 5_000

      # No park, no escalation, and the marker survives for the boot sweep.
      refute Arbiter.Tasks.ReviewPark.parked?(Ash.get!(Issue, rig.task.id))
      assert %{"phase" => "reviewing", "round" => 1} = pass_marker(rig)

      :ok = GenServer.stop(rig.author, :shutdown)
      stop_workers(rig, :shutdown)
      put_app_env(:arbiter, :worker_node_stopping_override, false)

      assert {:ok, %{rearmed: 1, restarted: [%{phase: :reviewing, round: 1}]}} =
               Reconciler.reconcile_review_passes(rearm_fun: rearm_fun(rig, command: [@probe]))

      assert_received {:rearmed, {:ok, regate}}
      assert_gate_reports(regate)

      assert [%{verdict: :approve, round: 1}] = review_rounds(rig)
      refute Arbiter.Tasks.ReviewPark.parked?(Ash.get!(Issue, rig.task.id))
    end

    test "an exit that lands just BEFORE the node sees itself stopping is still interrupted",
         ctx do
      rig = rig(ctx, "feature/rs-615c")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)

      put_app_env(:arbiter, :worker_exit_grace_ms, 300)
      put_app_env(:arbiter, :worker_node_stopping_override, false)
      gate_ref = Process.monitor(gate)
      send(gate, {:worker_exited, rig.task.id <> "#review", 143})
      _ = :sys.get_state(gate)
      refute_received {:DOWN, ^gate_ref, _, _, _}

      # The node flips to stopping inside the grace window.
      put_app_env(:arbiter, :worker_node_stopping_override, true)
      assert_receive {:DOWN, ^gate_ref, :process, ^gate, :shutdown}, 5_000

      refute Arbiter.Tasks.ReviewPark.parked?(Ash.get!(Issue, rig.task.id))
      assert %{"phase" => "reviewing", "round" => 1} = pass_marker(rig)
      stop_workers(rig, :shutdown)
      put_app_env(:arbiter, :worker_node_stopping_override, false)
    end

    test "a kill with the node NOT stopping still parks reviewer_failed", ctx do
      rig = rig(ctx, "feature/rs-615b")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)

      put_app_env(:arbiter, :worker_node_stopping_override, false)
      gate_ref = Process.monitor(gate)
      send(gate, {:worker_exited, rig.task.id <> "#review", 137})
      assert_receive {:DOWN, ^gate_ref, :process, ^gate, :normal}, 5_000

      assert Arbiter.Tasks.ReviewPark.reason(Ash.get!(Issue, rig.task.id)) == :reviewer_failed
    end
  end

  describe "an implementer fix round (#review#impl) running when the node stops" do
    test "restarts the round on the same head and the gate reaches a verdict", ctx do
      rig = rig(ctx, "feature/rs-4")

      gate =
        start_gate(rig, ctx, command: [@reject_once], revise_command: [@revise_hang], rounds: 3)

      wait_until(fn -> match?(%{"phase" => "revising"}, pass_marker(rig)) end, 15_000)
      assert %{"phase" => "revising", "round" => 1} = pass_marker(rig)
      assert Worker.whereis(rig.task.id <> "#review#impl1")

      node_stops(rig, gate)

      assert_interrupted(rig.task.id)
      assert_interrupted(rig.task.id <> "#review#impl1")
      assert Ash.get!(Issue, rig.task.id).attention_resume_attempts == 0

      assert {:ok, %{rearmed: 1, failed: 0, restarted: [entry], not_restarted: []}} =
               Reconciler.reconcile_review_passes(
                 rearm_fun:
                   rearm_fun(rig, command: [@reject_once], revise_command: [@revise_commit])
               )

      assert %{phase: :revising, round: 1} = entry
      assert_received {:rearmed, {:ok, regate}}
      assert_gate_reports(regate)

      # The fix landed and round 2's reviewer approved it.
      assert File.read!(Path.join(rig.wt, "guard.txt")) =~ "anchored guard"

      assert [%{round: 1, verdict: :request_changes}, %{round: 2, verdict: :approve}] =
               review_rounds(rig)

      assert Worker.whereis(rig.task.id) == nil
      assert implement_runs(rig) == 1
      assert Ash.get!(Issue, rig.task.id).attention_resume_attempts == 0
    end
  end

  describe "the ticket while a pass is cut off" do
    test "reads as working, not crashed, and the marker is a believable one", ctx do
      rig = rig(ctx, "feature/rs-5")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)
      node_stops(rig, gate)

      issue = Ash.get!(Issue, rig.task.id)
      assert %{"phase" => "reviewing"} = ReviewPass.current(issue)
      view = Projection.view(issue)
      refute view.attention in [:run_crashed, :worker_stopped]

      # Past its window the marker is no longer believed.
      later = DateTime.add(DateTime.utc_now(), 3 * 3_600, :second)
      assert ReviewPass.current(issue, later) == nil
    end
  end

  describe "Reconciler.reconcile_review_passes/1" do
    test "a pass that cannot be restarted is listed with its reason and cleared", ctx do
      rig = rig(ctx, "feature/rs-6")
      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)
      node_stops(rig, gate)

      assert {:ok, %{rearmed: 0, failed: 1, restarted: [], not_restarted: [entry]}} =
               Reconciler.reconcile_review_passes(rearm_fun: fn _ -> {:error, :no_worktree} end)

      assert %{task_id: task_id, reason: :no_worktree} = entry
      assert task_id == rig.task.id

      # Cleared, so the ordinary resume takes the ticket.
      assert pass_marker(rig) == nil
      me = self()

      assert {:ok, %{resumed: 1}} =
               Reconciler.reconcile_resumable_tasks(
                 resume_fun: fn issue ->
                   send(me, {:resumed, issue.id})
                   {:ok, %{}}
                 end
               )

      assert_received {:resumed, id}
      assert id == rig.task.id
    end

    test "rearm_pass/2 refuses a ticket with no marker or no worktree", ctx do
      rig = rig(ctx, "feature/rs-7")
      assert {:error, :no_review_pass} = ReviewGate.rearm_pass(rig.task.id)

      gate = start_gate(rig, ctx, command: [@probe, "HOLD"], rounds: 3)
      wait_until(fn -> passes(rig) == 1 and pass_marker(rig) != nil end)
      node_stops(rig, gate)
      File.rm_rf!(rig.wt)

      assert {:error, :no_worktree} = ReviewGate.rearm_pass(rig.task.id)
    end

    test "is a no-op off the primary instance", _ctx do
      assert {:ok, :skipped} = Reconciler.reconcile_review_passes(primary?: false)
    end
  end

  describe "the resume sweep's own report" do
    test "counts only what restarted; a deferred resume is listed, not counted", ctx do
      {:ok, a} = Ash.create(Issue, %{title: "a", workspace_id: ctx.ws.id, issue_type: :feature})
      {:ok, b} = Ash.create(Issue, %{title: "b", workspace_id: ctx.ws.id, issue_type: :feature})
      {:ok, c} = Ash.create(Issue, %{title: "c", workspace_id: ctx.ws.id, issue_type: :feature})
      for t <- [a, b, c], do: put_state!(t, :active)

      resume = fn
        %{id: id} when id == a.id -> {:ok, %{}}
        %{id: id} when id == b.id -> {:ok, %{deferred: true}}
        %{id: id} when id == c.id -> {:error, :no_outpost}
      end

      assert {:ok,
              %{
                resumed: 1,
                deferred: 1,
                escalated: 1,
                restarted: [a_id],
                not_restarted: not_restarted
              }} = Reconciler.reconcile_resumable_tasks(resume_fun: resume)

      assert a_id == a.id

      assert Enum.sort_by(not_restarted, & &1.task_id) ==
               Enum.sort_by(
                 [
                   %{task_id: b.id, reason: :deferred},
                   %{task_id: c.id, reason: {:unresumable, :no_outpost}}
                 ],
                 & &1.task_id
               )
    end
  end

  # ---- the node stopping -----------------------------------------------------

  # The author and every pass worker are shut down the way a supervisor stops
  # them (`terminate/2` stamps their runs); the gate is killed outright.
  defp node_stops(rig, gate) do
    :ok = GenServer.stop(rig.author, :shutdown)

    gate_ref = Process.monitor(gate)
    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^gate_ref, :process, ^gate, _}, 5_000

    stop_workers(rig, :shutdown)
    wait_until(fn -> Worker.whereis(rig.task.id) == nil end)
  end

  defp stop_workers(rig, reason) do
    for suffix <- ["#review", "#review#impl1", "#review#r2"],
        pid = Worker.whereis(rig.task.id <> suffix),
        is_pid(pid) do
      ref = Process.monitor(pid)
      # The gate stopping itself with the author may have got there first.
      try do
        GenServer.stop(pid, reason)
      catch
        :exit, _ -> :ok
      end

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    :ok
  end

  defp assert_interrupted(task_id) do
    run =
      Run
      |> Ash.Query.filter(task_id == ^task_id)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()
      |> List.first()

    assert run, "no run row for #{task_id}"
    assert run.state == :finished
    assert run.outcome == :interrupted
    assert run.failure_reason == "server shutdown"
  end

  defp rearm_fun(rig, extra) do
    me = self()

    fn issue ->
      assert issue.id == rig.task.id
      result = ReviewGate.rearm_pass(issue.id, gate_opts(extra))
      send(me, {:rearmed, result})
      result
    end
  end

  defp assert_gate_reports(gate) do
    ref = Process.monitor(gate)
    assert_receive {:DOWN, ^ref, :process, ^gate, reason}, 30_000
    assert reason in [:normal, :noproc]
  end

  # ---- reads -------------------------------------------------------------------

  defp pass_marker(rig), do: Ash.get!(Issue, rig.task.id).review_gate_state["pass"]

  defp review_rounds(rig) do
    Round
    |> Ash.Query.filter(task_id == ^rig.task.id and role == :review)
    |> Ash.read!()
    |> Enum.sort_by(& &1.round)
  end

  defp implement_runs(rig) do
    Run
    |> Ash.Query.filter(task_id == ^rig.task.id and kind == :implement)
    |> Ash.read!()
    |> length()
  end

  defp common_dir(rig) do
    {dir, 0} = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], rig.wt)
    String.trim(dir)
  end

  defp passes(rig) do
    case File.read(Path.join(common_dir(rig), "review_ci_passes")) do
      {:ok, n} ->
        case Integer.parse(String.trim(n)) do
          {count, ""} -> count
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp reviewed_head(rig),
    do: Path.join(common_dir(rig), "review_ci_reviewed_head") |> File.read!() |> String.trim()

  defp gate_opts(extra) do
    Keyword.merge([timeout_ms: 15_000, rounds: 3, command: [@probe]], extra)
  end

  # ---- git rig -----------------------------------------------------------------

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  # A feature branch with one commit, in its own worktree, already pushed.
  defp rig(ctx, branch) do
    {:ok, task} =
      Ash.create(Issue, %{title: "restart task", workspace_id: ctx.ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    git!(["checkout", "-q", "-b", branch], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "feature work"], ctx.repo)
    git!(["checkout", "-q", "main"], ctx.repo)

    wt = Path.join(ctx.tmp, "wt-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: ctx.repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["push", "-q", "-u", "origin", branch], wt)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", ctx.repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    %{
      task: task,
      branch: branch,
      wt: wt,
      head: sha(wt, "HEAD"),
      author: start_author(task, ctx, branch, wt)
    }
  end

  defp start_author(task, ctx, branch, wt) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ctx.ws.id,
        meta: %{
          branch: branch,
          repo_path: ctx.repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    author
  end

  defp start_gate(rig, ctx, opts) do
    {:ok, gate} =
      ReviewGate.start(
        Keyword.merge(
          [
            author: rig.author,
            task_id: rig.task.id,
            workspace_id: ctx.ws.id,
            repo: "trib/repo",
            worktree_path: rig.wt,
            branch: rig.branch,
            target_branch: "main",
            timeout_ms: 15_000
          ],
          opts
        )
      )

    gate
  end

  defp wait_until(fun, timeout \\ 5_000) do
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
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end
end
