defmodule Arbiter.Worker.DriverTest do
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Driver
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.Watchdog
  alias Arbiter.TestWorkflows
  alias Arbiter.Workflows.Machine

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "driver-test-ws", prefix: "dt"})
    {:ok, ws: ws}
  end

  describe "tick → completed" do
    test "drives a Three workflow to :completed and closes the task", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "three", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)

      # Move task to :active so :close is a legal transition.
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert Machine.status(machine_pid) == :completed

      # The :close action's after_action hook tears the worker down; once
      # the task is closed it should no longer be registered or alive.
      assert Worker.whereis(task.id) == nil
      refute Process.alive?(worker_pid)

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end
  end

  describe "tick → failed" do
    test "marks worker :failed and leaves task :active on workflow error", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Failing, task.id, %{})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      worker_snap = Worker.state(worker_pid)
      assert worker_snap.outcome == :failed

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :active
    end
  end

  describe "max_ticks backstop" do
    test "stops and fails the worker when max_ticks is exceeded", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "loop", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1,
          max_ticks: 1
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      worker_snap = Worker.state(worker_pid)
      assert worker_snap.outcome == :failed
      assert match?({:driver_timeout, 1}, worker_snap.meta[:failure_reason])
    end
  end

  describe "monitor: machine dies mid-run" do
    test "marks worker :failed when the machine process dies", %{ws: ws} do
      # Machine.start uses start_link, so killing it would crash this test
      # process via the link. Trap exits to convert that into a message.
      Process.flag(:trap_exit, true)

      {:ok, task} = Ash.create(Issue, %{title: "mdied", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      # Pause the machine so the driver doesn't race us to completion.
      :ok = Machine.pause(machine_pid)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 10
        )

      ref = Process.monitor(driver_pid)

      # Kill the machine; driver should observe :DOWN and stop.
      Process.exit(machine_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      worker_snap = Worker.state(worker_pid)
      assert worker_snap.outcome == :failed
      assert worker_snap.meta[:failure_reason] == :machine_died
    end
  end

  # bd-146u20 / #2053: on an application stop the machine supervisor goes down
  # before the worker supervisor, so the Driver sees its Machine die first. That
  # is the node stopping, not a machine crash — the worker's own terminate/2
  # records the run :interrupted moments later, and failing it first turned a
  # resumable interruption into a :machine_died failure nobody resumed.
  describe "monitor: machine shut down with the node" do
    setup %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "mshutdown", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      :ok = Worker.advance(worker_pid, :implement)
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      :ok = Machine.pause(machine_pid)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          claude_driven: true,
          interval_ms: 10
        )

      on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)

      {:ok, worker_pid: worker_pid, machine_pid: machine_pid, driver_pid: driver_pid}
    end

    test "a :shutdown exit leaves the worker for its own terminate/2", ctx do
      ref = Process.monitor(ctx.driver_pid)

      :ok =
        DynamicSupervisor.terminate_child(Arbiter.Workflows.MachineSupervisor, ctx.machine_pid)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000
      assert Worker.state(ctx.worker_pid).state == :working
    end

    test "any exit while the node is stopping leaves the worker alone", ctx do
      previous = Application.fetch_env(:arbiter, :worker_node_stopping_override)
      Application.put_env(:arbiter, :worker_node_stopping_override, true)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, :worker_node_stopping_override, v)
          :error -> Application.delete_env(:arbiter, :worker_node_stopping_override)
        end
      end)

      ref = Process.monitor(ctx.driver_pid)
      # A machine that overran its shutdown budget is killed, not shut down.
      Process.exit(ctx.machine_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000
      assert Worker.state(ctx.worker_pid).state == :working
    end
  end

  describe "integration via Dispatch" do
    test "Dispatch with default opts starts a driver that closes the task", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "via-dispatch", workspace_id: ws.id})

      {:ok, result} = Dispatch.dispatch(task.id, force: true, repo: "r", interval_ms: 1)
      assert is_pid(result.driver_pid)

      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end
  end

  describe "claude_driven mode" do
    test "closes the task when the worker's run finishes :succeeded", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-complete", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      # Driver should NOT have ticked the workflow — Machine stays :idle.
      Process.sleep(50)
      assert Machine.status(machine_pid) == :idle

      # Monitor before triggering completion (bd-9j4znl) — `interval_ms: 5` is
      # fast enough for the Driver to tick and exit before a monitor() call
      # placed after the trigger, delivering a spurious `:noproc` DOWN.
      ref = Process.monitor(driver_pid)

      # Simulate Claude printing "arb done": advance worker then complete it.
      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :claude_done)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end

    # bd-9so315: the Watchdog completes the worker with `:merged` both when it
    # observes an MR merged and when it auto-merges itself, and this loop closes
    # the task ~1s later — long before the MergeQueue's next poll. That made the
    # Driver a third merge-finalize path that bypassed the verification funnel.
    test "a verify_after_deploy task parks instead of closing on a :merged completion", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "cd-merged-flagged",
          workspace_id: ws.id,
          verify_after_deploy: true
        })

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)

      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :merged)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :verifying
      assert %DateTime{} = reloaded.awaiting_verification_at

      assert [escalation] = Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id)
      assert escalation.subject =~ "awaiting verification"

      # ...and the parked task leaves the state only through a recorded
      # restart-and-observe verdict, which persists the evidence.
      {:ok, verified} =
        Arbiter.Tasks.Verification.record_outcome(
          reloaded,
          "observed",
          "restarted; the merged path runs on the live server"
        )

      assert verified.state == :closed
      assert verified.verification_outcome == :observed
      assert verified.verification_evidence =~ "restarted"
    end

    test "an unflagged task still closes on a :merged completion", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-merged-plain", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)

      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :merged)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
      assert Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id) == []
    end

    # The flag is about observing *merged* code on the running server. A worker
    # that finished without a merge has nothing deployed to observe, so it must
    # still close rather than strand itself at :verifying.
    test "a verify_after_deploy task closes on a non-merge completion", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "cd-done-flagged",
          workspace_id: ws.id,
          verify_after_deploy: true
        })

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)

      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :claude_done)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end

    test "leaves the task :active when the worker transitions to :failed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      :ok = Worker.fail(worker_pid, :claude_crashed)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :active
    end

    # bd-6dxqkg (#372): the tick budget (30 min by default) ran out while the
    # agent was still working; the Driver gave up and stopped, so when the run
    # later finished nobody closed the ticket and it held its slot forever.
    for type <- [:research, :task] do
      test "outlives the tick budget while a #{type} worker is live, then closes the task",
           %{ws: ws} do
        {:ok, task} =
          Ash.create(Issue, %{
            title: "cd-overrun",
            workspace_id: ws.id,
            issue_type: unquote(type),
            notes: "findings write-up"
          })

        {:ok, worker_pid} =
          Worker.start(
            task_id: task.id,
            repo: "r",
            workspace_id: ws.id,
            meta: %{issue_type: unquote(type)}
          )

        {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
        {:ok, machine_pid} = Machine.start(machine_id)
        put_state!(task, :active)
        :ok = Worker.advance(worker_pid, :running)

        {:ok, driver_pid} =
          Driver.start(
            task_id: task.id,
            worker_pid: worker_pid,
            machine_id: machine_id,
            machine_pid: machine_pid,
            interval_ms: 5,
            max_ticks: 3,
            claude_driven: true
          )

        ref = Process.monitor(driver_pid)
        refute_receive {:DOWN, ^ref, :process, _pid, _}, 100

        :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

        # The real completion path: the session reader's `arb done` message.
        send(worker_pid, {:__claude_session_done__, "arb done"})
        assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

        assert Ash.get!(Issue, task.id).state == :closed

        # The coordinator's /events stream hears about it too.
        task_id = task.id
        assert_receive {:event, %{topic: "worker_done", task_id: ^task_id}}, 1_000
      end
    end

    test "past the tick budget, an auth-death failure returns the task to Ready", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-auth", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 3,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      refute_receive {:DOWN, ^ref, :process, _pid, _}, 100

      :ok =
        Worker.fail(worker_pid, %Arbiter.Worker.StopReason{
          category: :auth_expired,
          summary: "401"
        })

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000
      assert Ash.get!(Issue, task.id).state == :queued
    end

    test "past the tick budget, a worker that fails stops the driver and leaves the task :active",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-stuck", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 3,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      refute_receive {:DOWN, ^ref, :process, _pid, _}, 100

      :ok = Worker.fail(worker_pid, :claude_crashed)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert Ash.get!(Issue, task.id).state == :active
    end

    # bd-d1jp4r: ticks must not consume budget while the worker is parked on
    # something else's decision. A long worker run + review gate was exhausting
    # the 30-minute tick budget before the merge, leaving the task stranded at
    # :active. bd-741sid: a run no longer parks on its open PR — opening it
    # ends the run and the ticket's Watchdog takes it — so the parked state is
    # waiting on the review gate, and a run that ends with its PR open is no
    # close.
    test "does not count ticks while the worker is waiting on the review gate", %{ws: ws} do
      StubMerger.reset()

      {:ok, task} = Ash.create(Issue, %{title: "cd-arg-freeze", workspace_id: ws.id})
      put_state!(task, :active)

      StubMerger.next_open_ref("!drv1")
      worker_pid = park_at_review_gate(task, ws)
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)

      # max_ticks: 2 — would expire after 2 cycles while :working, but should
      # NOT expire while the worker is waiting on the review gate.
      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 2,
          claude_driven: true
        )

      # Let the driver run several cycles while the run waits on the review gate.
      # With the fix, ticks don't increment here, so max_ticks: 2 won't fire.
      Process.sleep(60)

      assert Process.alive?(driver_pid),
             "driver should still be alive (ticks frozen while waiting on the review gate)"

      # Monitor before triggering completion (bd-9j4znl) — see comment above.
      ref = Process.monitor(driver_pid)

      # The gate approves; the run opens its PR and ends there.
      :ok = Worker.review_gate_verdict(worker_pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # The Driver did not close the task: it is Merging, its PR in the hands
      # of the ticket's Watchdog.
      reloaded = Ash.get!(Issue, task.id)

      assert {reloaded.state, reloaded.pr_ref} == {:merging, "!drv1"}

      assert Watchdog.alive?(task.id)
    end

    # bd-d1jp4r: driver must close the task even when max_ticks fires at the
    # exact moment the worker's run finishes :succeeded (the Watchdog race).
    test "closes the task at max_ticks if the worker's run already succeeded", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "cd-maxtick-done", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      # Complete the worker BEFORE the driver even starts — simulates the Watchdog
      # completing the worker in the same moment max_ticks fires.
      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :merged)

      # Start the driver with max_ticks: 0 so it fires the max_ticks guard on
      # the very first check_worker message.
      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 0,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Even though max_ticks was hit, task must be closed because the run succeeded.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end

    # bd-7b46wd: if the tick budget is exhausted by active worker work and the
    # max_ticks guard fires while the worker has *already handed off* to the
    # ReviewGate (waiting on the review gate), the driver must NOT stop — the
    # gate drives the worker to finished. Stopping here was stranding tasks
    # that were legitimately mid-merge, and the bd-d1jp4r fix only covered the
    # already-succeeded case. bd-741sid: the approved run ends with its PR
    # open, and the ticket's Watchdog closes the ticket when the PR merges.
    test "keeps waiting at max_ticks while the worker waits on the review gate, then the merge closes the task",
         %{ws: ws} do
      StubMerger.reset()

      {:ok, task} = Ash.create(Issue, %{title: "cd-maxtick-awaiting", workspace_id: ws.id})
      put_state!(task, :active)

      # The Watchdog polls promptly once the PR is open, so the merge below is
      # what finishes the task.
      StubMerger.next_open_ref("!drv2")
      StubMerger.queue_get("!drv2", [%{status: :merged}])

      worker_pid =
        park_at_review_gate(task, ws, %{watchdog_interval_ms: 20, watchdog_initial_delay_ms: 0})

      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)

      # max_ticks: 0 → the t >= m guard fires on the very first check. With the
      # worker waiting on the review gate the driver must reschedule, not stop.
      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          max_ticks: 0,
          claude_driven: true
        )

      Process.sleep(40)

      assert Process.alive?(driver_pid),
             "driver must keep waiting at max_ticks while worker is externally owned"

      {:ok, %Issue{state: :active}} = Ash.get(Issue, task.id)

      # The gate approves: the run opens its PR and ends, and the driver's next
      # guarded check lets it go rather than stranding the task.
      ref = Process.monitor(driver_pid)
      :ok = Worker.review_gate_verdict(worker_pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # The ticket's Watchdog sees the merge and closes the task.
      wait_until(fn -> Ash.get!(Issue, task.id).state == :closed end)
    end
  end

  # A worker whose run is done and parked on its ReviewGate (`review_spawn:
  # false`, so the verdict is delivered by hand exactly as the gate would),
  # with the stub merger for the PR it opens on approval. The ticket's
  # Watchdog is parked unless `extra_meta` says otherwise.
  defp park_at_review_gate(task, ws, extra_meta \\ %{}) do
    meta =
      Map.merge(
        %{
          branch: "feature/#{task.id}",
          target_branch: "main",
          review_required: true,
          review_spawn: false,
          merger_adapter_override: StubMerger,
          merger_workspace_override: ws,
          watchdog_interval_ms: 60_000,
          watchdog_initial_delay_ms: 60_000
        },
        extra_meta
      )

    {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id, meta: meta)
    on_exit(fn -> stop_quietly(pid) end)
    on_exit(fn -> stop_quietly(Watchdog.whereis(task.id)) end)

    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(pid)) end)
    pid
  end

  defp stop_quietly(nil), do: :ok

  defp stop_quietly(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
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
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  describe "cleanup_worktree opt" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "drv-cw-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      # Worktree.create fetches from origin/<base>; provide a bare upstream.
      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "wt")
      File.mkdir_p!(worktree_root)

      prior_wt = Application.get_env(:arbiter, :worktree_root)
      Application.put_env(:arbiter, :worktree_root, worktree_root)

      on_exit(fn ->
        if prior_wt,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt),
          else: Application.delete_env(:arbiter, :worktree_root)

        File.rm_rf!(tmp)
      end)

      # Create a real worktree we can verify is gone after.
      {:ok, wt_path} = Arbiter.Worker.Worktree.create(repo, "feature/dt-test", "main")

      %{wt_path: wt_path, repo: repo}
    end

    # bd-4wy1w1 (P5): the same reap for a private clone (git layout B), on
    # both terminal paths, takes the clone's gc pins in the main repo with it.
    for {label, fail?} <- [{"successful completion", false}, {"a failed worker", true}] do
      test "removes a private clone and its pins on #{label}", %{ws: ws, repo: repo} do
        {:ok, clone} =
          Arbiter.Worker.Worktree.create(repo, "feature/dt-clone", "main", layout: :private_clone)

        pins = Arbiter.Worker.PrivateClone.pin_prefix(Path.basename(clone))
        {:ok, task} = Ash.create(Issue, %{title: "cw-clone", workspace_id: ws.id})
        {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
        {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
        {:ok, machine_pid} = Machine.start(machine_id)
        put_state!(task, :active)

        {:ok, driver_pid} =
          Driver.start(
            task_id: task.id,
            worker_pid: worker_pid,
            machine_id: machine_id,
            machine_pid: machine_pid,
            interval_ms: 5,
            claude_driven: unquote(fail?),
            worktree_path: clone,
            cleanup_worktree: true
          )

        ref = Process.monitor(driver_pid)
        if unquote(fail?), do: :ok = Worker.fail(worker_pid, :claude_crashed)
        assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

        refute File.dir?(clone)
        {left, 0} = System.cmd("git", ["-C", repo, "for-each-ref", "--format=%(refname)", pins])
        assert left == ""
      end
    end

    test "removes the worktree on successful completion when opted in", %{
      ws: ws,
      wt_path: wt_path
    } do
      {:ok, task} = Ash.create(Issue, %{title: "cw", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      refute File.dir?(wt_path)
    end

    test "leaves the worktree alone by default", %{ws: ws, wt_path: wt_path} do
      {:ok, task} = Ash.create(Issue, %{title: "no-cw", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1,
          worktree_path: wt_path
          # cleanup_worktree default: false
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert File.dir?(wt_path)
    end

    test "skips cleanup when the worktree has uncommitted changes", %{ws: ws, wt_path: wt_path} do
      # Make the worktree dirty.
      File.write!(Path.join(wt_path, "scratch.txt"), "dirty\n")

      {:ok, task} = Ash.create(Issue, %{title: "dirty", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Still there — uncommitted changes protect operator inspection.
      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, "scratch.txt"))
    end

    test "removes the worktree when the worker fails (claude_driven :failed path)", %{
      ws: ws,
      wt_path: wt_path
    } do
      {:ok, task} = Ash.create(Issue, %{title: "cw-fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      :ok = Worker.fail(worker_pid, :claude_crashed)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      refute File.dir?(wt_path)
    end

    test "kills a live agent before reaping the worktree — no orphaned agent in a deleted cwd (bd-7a0pi8)",
         %{ws: ws, wt_path: wt_path} do
      {:ok, task} = Ash.create(Issue, %{title: "cw-live-fail", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      # A LIVE agent whose cwd is the worktree the Driver is about to reap. This
      # is the run-7abf4049 shape: the run gets failed while the agent process
      # is still alive. If teardown removes the worktree without stopping the
      # agent first, the agent keeps issuing commands in a deleted cwd.
      {:ok, port} =
        ClaudeSession.start(
          owner: worker_pid,
          worktree_path: wt_path,
          command: ["sh", "-c", "sleep 60"]
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      :ok = Worker.fail(worker_pid, :no_commits_at_completion)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Worktree reaped AND the agent is dead — the agent can no longer run any
      # command against the deleted cwd.
      refute File.dir?(wt_path)

      {_, code} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
      assert code != 0, "agent os process #{os_pid} should be dead after teardown"
    end

    # bd-bmmj4w: the `:close` hook refuses to delete a worktree a live worker
    # still owns; this second removal path must obey the same rule. A
    # sub-worker (`<task_id>:fixpass`) is one the Driver never started and
    # never stops, so its agent can still be mid-run in the directory the
    # Driver is about to reap.
    test "skips cleanup while a sub-worker for the task is still live", %{
      ws: ws,
      wt_path: wt_path
    } do
      {:ok, task} = Ash.create(Issue, %{title: "cw-live-sub", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")

      # bd-8tjcms: `Worker.start/1` now refuses a second *active* worker for one
      # task. In production this fixture's shape is reached with the primary
      # waiting on the review gate or finished (which the guard allows); here
      # the primary is `:starting`, so opt out explicitly to keep building the
      # same state.
      {:ok, fixpass_pid} =
        Worker.start(
          task_id: task.id,
          registry_key: task.id <> ":fixpass",
          repo: "r",
          allow_concurrent_task_worker: true
        )

      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      # The :failed branch reaps the worktree without closing the task, so
      # nothing else stops the sub-worker first.
      :ok = Worker.fail(worker_pid, :claude_crashed)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert Process.alive?(fixpass_pid)
      assert File.dir?(wt_path), "worktree reaped while a :fixpass sub-worker was still live"

      Worker.stop(fixpass_pid)
    end

    # bd-bspakl: the Watchdog registers under `<task_id>:watchdog` in this same
    # registry (so `retry_auto_resolve/1` can look it up by task_id), but it
    # owns no worktree — only the forge poll loop and dispatching sub-workers,
    # which register (and block) under their own keys. Unlike a real
    # `:fixpass` sub-worker above, a live watchdog entry must NOT block reap.
    test "does not skip cleanup for a live :watchdog registry entry", %{
      ws: ws,
      wt_path: wt_path
    } do
      {:ok, task} = Ash.create(Issue, %{title: "cw-live-watchdog", workspace_id: ws.id})

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")

      # bd-8tjcms: a real `<task_id>:watchdog` entry is an
      # `Arbiter.Worker.Watchdog`, not an `Arbiter.Worker`, so the
      # single-active-worker guard never sees it. This stand-in *is* a Worker,
      # so it has to opt out to stay a faithful stand-in.
      {:ok, watchdog_pid} =
        Worker.start(
          task_id: task.id,
          registry_key: task.id <> Arbiter.Worker.Watchdog.registry_suffix(),
          repo: "r",
          allow_concurrent_task_worker: true
        )

      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      :ok = Worker.fail(worker_pid, :claude_crashed)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      assert Process.alive?(watchdog_pid)
      refute File.dir?(wt_path), "worktree leaked while only a :watchdog entry was still live"

      Worker.stop(watchdog_pid)
    end

    test "skips cleanup when the worktree has commits ahead of base", %{ws: ws, wt_path: wt_path} do
      # Commit a new file in the worktree, then have a clean working tree.
      File.write!(Path.join(wt_path, "new.txt"), "claude wrote me\n")
      {_, 0} = System.cmd("git", ["-C", wt_path, "add", "new.txt"])
      {_, 0} = System.cmd("git", ["-C", wt_path, "commit", "-q", "-m", "claude contribution"])

      # Confirm the precondition: clean worktree, 1 commit ahead.
      {:ok, false} = Arbiter.Worker.Worktree.has_uncommitted?(wt_path)
      {:ok, true} = Arbiter.Worker.Worktree.has_commits_ahead?(wt_path, "main")

      {:ok, task} = Ash.create(Issue, %{title: "ahead", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 1,
          worktree_path: wt_path,
          cleanup_worktree: true
        )

      ref = Process.monitor(driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      # Still there — committed-but-unpushed work is preserved.
      assert File.dir?(wt_path)
      assert File.exists?(Path.join(wt_path, "new.txt"))
    end
  end

  describe "review_only long-lived engagement (bd-cw3w9p)" do
    test "Driver exits without closing the task when worker is review_only and its run succeeds",
         %{ws: ws} do
      # bd-cw3w9p: review_only tasks are long-lived ReviewPatrol engagements.
      # When the worker's run finishes :succeeded the Driver must stop but NOT call
      # close_task — the task remains :active for future review cycles.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "rp-open",
          workspace_id: ws.id
        })

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r", meta: %{review_only: true})
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      # Monitor before triggering completion — `interval_ms: 5` is fast enough
      # that the Driver can tick and exit between the trigger and a
      # monitor() call placed after it, delivering a spurious `:noproc` DOWN
      # instead of `:normal` under load (bd-9j4znl).
      ref = Process.monitor(driver_pid)

      :ok = Worker.advance(worker_pid, :running)
      :ok = Worker.complete(worker_pid, :claude_done)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :active
    end
  end

  describe "Watchdog auto-close (Bd-191)" do
    test "closes task when worker completes with an mr_ref (Watchdog merge)", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "watchdog-close",
          workspace_id: ws.id
        })

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      {:ok, machine_id} = Machine.attach(TestWorkflows.Three, task.id, %{x: "v"})
      {:ok, machine_pid} = Machine.start(machine_id)
      put_state!(task, :active)

      {:ok, driver_pid} =
        Driver.start(
          task_id: task.id,
          worker_pid: worker_pid,
          machine_id: machine_id,
          machine_pid: machine_pid,
          interval_ms: 5,
          claude_driven: true
        )

      ref = Process.monitor(driver_pid)

      # Simulate a worker completion with mr_ref (from Watchdog merge)
      :ok = Worker.advance(worker_pid, :running)
      # Directly set the mr_ref via the worker's meta to simulate Watchdog completion
      :ok = Worker.report(worker_pid, :mr_ref, "direct:test-branch")
      # Now complete the worker
      :ok = Worker.complete(worker_pid, :merged)

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.state == :closed
    end
  end
end
