defmodule Arbiter.Workflows.DispatchQueueHeldFixRoundTest do
  @moduledoc """
  bd-6omte4: a ReviewGate fix round refused by the quota gate.

  On bd-aro53b (2026-09-25) an agy fix round came back `{:quota_held, id}`.
  The round had been queued in the workspace's `DispatchQueue`, not dropped,
  but the coordinator was told it FAILED to dispatch. Thirteen minutes later
  the coordinator re-dispatched the task on Claude, and nothing cancelled the
  held agy round: the next drain would have replayed it onto a task with a
  live worker on its worktree.

  Driven end to end through the real `ReviewGateFixRoundDispatcher`,
  `Dispatch.resume/2`, the quota gate and the queue, on a real repo
  (`Arbiter.Test.ResumeSlotFixture`) with every agent CLI stubbed.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.{Current, Run}
  alias Arbiter.Workflows.{DispatchQueue, DispatchQueueSupervisor}
  alias Arbiter.Workflows.ReviewGateFixRoundDispatcher, as: FixRound

  @findings "VERDICT: REQUEST_CHANGES\n- [high] feature.txt:1 needs a guard"

  # Records each drain re-dispatch, so a drain can be asserted without
  # spawning a worker.
  defmodule RecordingDispatcher do
    def dispatch(task_id, opts) do
      send(Application.get_env(:arbiter, :held_fix_round_test_pid), {:drained, task_id, opts})
      {:ok, %{task_id: task_id}}
    end
  end

  # The real `Dispatch.dispatch/2`, minus the Driver: the drained round spawns
  # a real worker (on the stubbed CLI) without a workflow driving it on.
  defmodule NoDriverDispatcher do
    def dispatch(task_id, opts) do
      result = Dispatch.dispatch(task_id, Keyword.put(opts, :start_driver, false))
      send(Application.get_env(:arbiter, :held_fix_round_test_pid), {:real_drain, result})
      result
    end
  end

  setup do
    Application.put_env(:arbiter, :held_fix_round_test_pid, self())
    on_exit(fn -> Application.delete_env(:arbiter, :held_fix_round_test_pid) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "held-fix-round-#{System.unique_integer([:positive])}",
        prefix: "hfr#{System.unique_integer([:positive])}",
        config: %{"quota" => %{"on_exhaustion" => "throttle"}}
      })

    ResumeSlotFixture.setup_repo!()
    # Nothing else holds a slot: the parked ticket's resume is never deferred.
    {:ok, _} = Arbiter.Settings.set_nodes_local_max_workers(5)

    {:ok, task} = Ash.create(Issue, %{title: "rejected by the gate", workspace_id: ws.id})
    # Dispatched, then rejected by the ReviewGate: its worker lingers
    # `:failed`, the ticket stays In progress.
    first = ResumeSlotFixture.park!(task, nil)

    %{ws: ws, task: task, first: first}
  end

  defp start_queue(ws, dispatcher) do
    {:ok, pid} =
      DispatchQueueSupervisor.start_dispatch_queue(ws.id,
        dispatcher: dispatcher,
        auto_subscribe: false
      )

    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(DispatchQueueSupervisor, pid) end)
    pid
  end

  defp seed_quota(ws, attrs) do
    Ash.create!(
      AnthropicQuota,
      Map.merge(
        %{
          provider_account_id: quota_account_id!(ws.id),
          provider: "claude",
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
  end

  defp over_cap(ws), do: seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99})
  defp headroom(ws), do: seed_quota(ws, %{status_5h: "allowed", utilization_5h: 0.10})

  # The round the worker dispatches after a second REQUEST_CHANGES verdict.
  defp fix_round(task, attempt \\ 2) do
    FixRound.dispatch(%{
      task_id: task.id,
      workspace_id: task.workspace_id,
      attempt: attempt,
      verdict: :request_changes,
      findings: @findings,
      findings_digest: FixRound.findings_digest(@findings),
      claude_command: ["sleep", "30"]
    })
  end

  defp prior_run_id(task) do
    require Ash.Query

    Run
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.read!()
    |> List.first()
    |> Map.fetch!(:id)
  end

  defp drain_and_settle(pid) do
    :ok = DispatchQueue.drain(pid)
    # The drain hands its dispatches to a Task; its log and cast land after.
    Process.sleep(200)
    _ = DispatchQueue.state(pid)
  end

  describe "a fix round the quota gate holds" do
    test "is queued, and reads as held for quota on its provider, not failed",
         %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)

      assert {:error, {:quota_held, id}} = fix_round(task)
      assert id == task.id

      [item] = DispatchQueue.state(pid).items
      held = DispatchQueue.describe(item)
      assert held.intent == "ReviewGate fix round 2"
      assert held.fix_round == 2
      assert held.provider == :claude
      # The gate's own reason, not just "quota".
      assert held.reason =~ "quota exhausted"

      # The ticket's run reads as held, with the provider and the reason.
      %{current: current} = Current.show(task.id)
      assert current.phase == :held_for_quota
      assert current.held.fix_round == 2
      assert current.held.reason == held.reason
      assert Arbiter.Worker.Phase.label(current.phase) == "held for quota, will resume"
    end

    test "raises no run_crashed attention, and holds no scheduler slot, while held (bd-zkmvia)",
         %{ws: ws, task: task} do
      start_queue(ws, RecordingDispatcher)
      task = Ash.get!(Issue, task.id)

      # Before the hold: the rejected ticket is In progress and holds a slot.
      assert Arbiter.Tasks.SlotGate.holds_slot?(task)
      assert Arbiter.Accounts.Concurrency.workspace_live_count(ws.id, :claude) == 1

      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)

      # ...nor an account slot: the lingering worker record is not counted.
      assert Arbiter.Accounts.Concurrency.workspace_live_count(ws.id, :claude) == 0
      refute Arbiter.Tasks.SlotGate.holds_slot?(task)
      assert Arbiter.Tasks.SlotGate.slots_used([task]) == 0
      assert Arbiter.Tasks.Lifecycle.view(task, %{runs: [], held: true}).attention == nil
      assert Arbiter.Tasks.Lifecycle.view(task, %{runs: []}).attention == nil
    end

    test "re-takes its slot when the hold is released", %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      task = Ash.get!(Issue, task.id)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)
      refute Arbiter.Tasks.SlotGate.holds_slot?(task)

      headroom(ws)
      drain_and_settle(pid)

      assert Arbiter.Tasks.SlotGate.holds_slot?(task)
    end

    test "stays held at a full cap: the drain re-runs the admission check",
         %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)

      # Another ticket now fills the only slot.
      {:ok, _} = Arbiter.Settings.set_nodes_local_max_workers(1)
      {:ok, other} = Ash.create(Issue, %{title: "took the slot", workspace_id: ws.id})
      {:ok, %Issue{state: :active}} = Issue.start_work(other)

      headroom(ws)
      drain_and_settle(pid)
      refute_received {:drained, _, _}
      assert [%{task_id: id}] = DispatchQueue.state(pid).items
      assert id == task.id

      # The slot frees: the next drain releases it.
      {:ok, _} = Arbiter.Settings.set_nodes_local_max_workers(5)
      drain_and_settle(pid)
      assert_received {:drained, ^id, _opts}
    end

    test "drains as the same fix round: round number, findings, prior run",
         %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      prior = prior_run_id(task)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)

      headroom(ws)
      drain_and_settle(pid)

      assert_received {:drained, task_id, opts}
      assert task_id == task.id
      # A resume of the preserved worktree, not a fresh dispatch...
      assert opts[:resume] == true
      assert opts[:resumed_from_run_id] == prior
      # ...as fix round 2, briefed with the reviewer's findings.
      assert opts[:review_gate_fix_round_attempts] == 2
      assert opts[:review_gate_findings_digest] == FixRound.findings_digest(@findings)
      assert opts[:resume_context] =~ "fix round 2"
      assert opts[:resume_context] =~ "feature.txt:1 needs a guard"
      assert DispatchQueue.state(pid).items == []
    end

    test "a real drain starts the round's worker as fix round 2, linked to the prior run",
         %{ws: ws, task: task} do
      pid = start_queue(ws, NoDriverDispatcher)
      prior = prior_run_id(task)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)
      # The resume already stopped the rejected worker; nothing is running.
      assert Worker.whereis(task.id) == nil

      headroom(ws)
      :ok = DispatchQueue.drain(pid)
      assert_receive {:real_drain, {:ok, %{worker_pid: worker}}}, 5_000
      assert Worker.whereis(task.id) == worker
      assert is_pid(worker)
      meta = Worker.state(worker).meta
      assert meta[:review_gate_fix_round_attempts] == 2
      assert meta[:review_gate_findings_digest] == FixRound.findings_digest(@findings)
      assert Ash.get!(Run, Worker.state(worker).run_id).resumed_from_run_id == prior
      assert DispatchQueue.state(pid).items == []
    end
  end

  describe "a held fix round for a task that has moved on" do
    # bd-aro53b verbatim, mirrored: the fix round is held on one provider, then
    # the coordinator re-dispatches the task by hand on another that has
    # headroom (there agy was held and Claude went ahead; here Claude is held
    # and agy goes ahead — the gate reads each provider's own snapshot).
    test "a manual re-dispatch on another provider cancels it; the drain replays nothing",
         %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)
      assert DispatchQueue.held?(ws.id, task.id)

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   Dispatch.resume(task.id,
                     agent_type: :gemini,
                     start_driver: false,
                     claude_command: ["sleep", "30"]
                   )

          assert is_pid(result.worker_pid)
        end)

      refute DispatchQueue.held?(ws.id, task.id)
      assert log =~ "dropped the held ReviewGate fix round 2 for #{task.id}"
      assert log =~ "the task was dispatched again"

      headroom(ws)
      drain_and_settle(pid)
      refute_received {:drained, _, _}
    end

    # The same shape where the re-dispatch raced the cancel, or predates it:
    # the drain itself refuses and says why.
    test "a drain refuses it once the task has a newer run, and logs why",
         %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)

      {:ok, newer} =
        Ash.create(Run, %{
          task_id: task.id,
          workspace_id: ws.id,
          repo: ResumeSlotFixture.repo(),
          kind: :implement,
          state: :finished,
          outcome: :succeeded,
          started_at: DateTime.utc_now()
        })

      headroom(ws)
      log = capture_log(fn -> drain_and_settle(pid) end)

      refute_received {:drained, _, _}
      assert log =~ "not draining the held ReviewGate fix round 2 for #{task.id}"
      assert log =~ "the task was re-dispatched after it was held (run #{newer.id})"
      assert DispatchQueue.state(pid).items == []
    end

    test "a drain refuses it while a worker is live on the task", %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)

      live = ResumeSlotFixture.admit!(ws, task)
      assert is_pid(live)

      headroom(ws)
      log = capture_log(fn -> drain_and_settle(pid) end)

      refute_received {:drained, _, _}
      assert log =~ "a worker is live on the task"
      assert Worker.whereis(task.id) == live
    end

    test "stopping the task cancels it", %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)
      assert Worker.whereis(task.id) == nil

      log = capture_log(fn -> assert :ok = Worker.stop(task.id, :normal) end)

      refute DispatchQueue.held?(ws.id, task.id)
      assert log =~ "the task was stopped"

      headroom(ws)
      drain_and_settle(pid)
      refute_received {:drained, _, _}
    end

    test "a drain refuses it once the task left In progress", %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)

      {:ok, %Issue{state: :merging}} =
        Issue.pr_opened(task.id, "https://example.test/pull/#{task.id}")

      headroom(ws)
      log = capture_log(fn -> drain_and_settle(pid) end)

      refute_received {:drained, _, _}
      assert log =~ "the task moved from active to merging after it was held"
    end

    test "closing the task drops it", %{ws: ws, task: task} do
      pid = start_queue(ws, RecordingDispatcher)
      over_cap(ws)
      assert {:error, {:quota_held, _}} = fix_round(task)

      {:ok, _} = Ash.update(Ash.get!(Issue, task.id), %{}, action: :close)

      headroom(ws)
      drain_and_settle(pid)
      refute_received {:drained, _, _}
    end
  end
end
