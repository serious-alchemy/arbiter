defmodule Arbiter.Worker.DispatchResumeSlotTest do
  @moduledoc """
  bd-92mx1m: `Dispatch.resume/2` and `Dispatch.resume_session/2` consult
  `Arbiter.Worker.ResumeSlot` before re-entering a task. Driven end to end
  against a real git repo and real workers, so the gate is proven where it
  actually sits — after the resume's own validity checks, before the prior
  worker is stopped.

  bd-asxw4e: a ticket holds a slot exactly while it is In progress (`:active`).
  So the full cap here is A Merging on its open PR (no slot) and B In
  progress (the one slot); a resume of A must acquire a slot, and a resume of
  a ticket still In progress passes through uncapped.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.{ResumeSlotFixture, StubResumeDeferrer}
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Reconciler
  alias Arbiter.Workflows.MergeQueue.{AutoResumeDispatcher, ReviseDispatcher}
  alias Arbiter.Workflows.ReviewGateFixRoundDispatcher

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-slot-dispatch-#{System.unique_integer([:positive])}",
        prefix: "rsd#{System.unique_integer([:positive])}"
      })

    ResumeSlotFixture.setup_repo!()
    StubResumeDeferrer.reset()

    {:ok, a} = Ash.create(Issue, %{title: "task A (parked)", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B (admitted)", workspace_id: ws.id})

    %{ws: ws, a: a, b: b}
  end

  # Task A ran and parked (its worker lingers :failed), and its PR opened: it
  # is Merging, which holds no slot. `release: nil` keeps it In progress.
  defp park_a(a, fail_opts \\ [], release \\ :merging),
    do: ResumeSlotFixture.park!(a, fail_opts, release)

  # Task B was admitted into the slot A freed: In progress.
  defp admit_b(ws, b), do: ResumeSlotFixture.admit!(ws, b)

  defp overrides(ws), do: ResumeSlotFixture.overrides(ws)

  describe "a full cap (cap 1, A Merging, B In progress)" do
    test "a human resume of A is refused, naming the cap and B; the parked worker is untouched",
         %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)

      assert {:error, {:slot_cap_full, info}} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["true"])

      assert info.cap == 1
      assert info.holders == [b.id]
      # Refused before `stop_prior_worker/1`: nothing about A changed.
      assert Worker.whereis(a.id) == first.worker_pid
      assert Worker.state(first.worker_pid).status == :failed
      assert overrides(ws) == []
    end

    test "with force it is admitted, over the cap, and the override is recorded",
         %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)

      assert {:ok, result} =
               Dispatch.resume(a.id,
                 start_driver: false,
                 claude_command: ["sleep", "2"],
                 force_slot: true,
                 slot_override_actor: "coordinator"
               )

      assert result.worker_pid != first.worker_pid
      assert Worker.state(result.worker_pid).meta[:slot_cap_override] == true
      # Admitted into a slot, so back In progress: the round holds it.
      assert Ash.get!(Issue, a.id).state == :active

      assert [event] = overrides(ws)
      assert event.payload["task_id"] == a.id
      assert event.payload["holders"] == [b.id]
      assert event.payload["actor"] == "coordinator"
    end
  end

  describe "an automatic resume of a task that released its slot" do
    test "is deferred to the scheduler at a full cap — not failed, not bypassed",
         %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)
      me = self()

      defer = fn task_id, kind, opts ->
        send(me, {:deferred, task_id, kind, opts})
        :ok
      end

      assert {:ok, %{deferred: true, task_id: task_id, cap: 1, holders: holders}} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: defer,
                 revise_feedback: "address the review",
                 start_driver: false
               )

      assert task_id == a.id
      assert holders == [b.id]
      assert_received {:deferred, ^task_id, :resume, opts}
      # The resume is replayed with the caller's own options, minus the seam.
      assert opts[:revise_feedback] == "address the review"
      assert opts[:resume_origin] == :automatic
      refute Keyword.has_key?(opts, :defer_resume)

      # Nothing was started or stopped.
      assert Worker.whereis(a.id) == first.worker_pid
    end

    # The production drain end to end: the real `Autopilot.defer_resume/4`
    # queues it, and the Autopilot's own default replay — `Dispatch.resume/2`
    # with `slot_admitted: true` — starts it once its board shows a free slot,
    # without being re-refused by B still holding the cap.
    test "the scheduler replays it for real once a slot frees", %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)
      {:ok, free} = Agent.start_link(fn -> 0 end)

      {:ok, autopilot} =
        Arbiter.Board.Autopilot.start_link(
          name: nil,
          paused: true,
          interval_ms: :never,
          debounce_ms: 60_000,
          topics: [],
          snapshot: fn _ -> %{promote: nil, ready: [], slots_free: Agent.get(free, & &1)} end
        )

      assert {:ok, %{deferred: true}} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: &Arbiter.Board.Autopilot.defer_resume(autopilot, &1, &2, &3),
                 start_driver: false,
                 claude_command: ["sleep", "2"]
               )

      assert :paused = Arbiter.Board.Autopilot.tick(autopilot)
      assert Worker.whereis(a.id) == first.worker_pid

      Agent.update(free, fn _ -> 1 end)
      task_id = a.id
      assert {:resumed, ^task_id} = Arbiter.Board.Autopilot.tick(autopilot, 30_000)

      resumed = Worker.whereis(a.id)
      assert resumed not in [nil, first.worker_pid]
      assert Worker.state(resumed).meta[:resume] == true
      assert overrides(ws) == []
      # The slot it was admitted into is its own now: A is In progress again.
      assert Ash.get!(Issue, a.id).state == :active
    end

    test "a deferral nobody can take is a refusal, never a bypass", %{ws: ws, a: a, b: b} do
      park_a(a)
      admit_b(ws, b)

      assert {:error, {:slot_cap_full, _}} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: fn _, _, _ -> {:error, :no_scheduler} end,
                 start_driver: false
               )
    end
  end

  # Acceptance 3 / the PR's caller list: every automatic path tags its resume
  # `:automatic`, so a slot-released task at a full cap is deferred to the
  # scheduler (`:resume_deferrer`, a recording stub under test) — never
  # refused like a human's, never let over the cap.
  describe "every automatic caller defers at a full cap" do
    setup %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)
      %{first: first}
    end

    defp assert_deferred(result, task_id) do
      assert {:ok, %{deferred: true, task_id: ^task_id}} = result
      assert [{^task_id, :resume, opts}] = StubResumeDeferrer.deferrals()
      assert opts[:resume_origin] == :automatic
      opts
    end

    test "MergeQueue revise", %{a: a, first: first} do
      a.id
      |> then(&ReviseDispatcher.dispatch(%{task_id: &1, feedback: [], start_claude: false}))
      |> assert_deferred(a.id)

      assert Worker.whereis(a.id) == first.worker_pid
    end

    test "Watchdog auto-resume", %{a: a} do
      opts =
        %{task_id: a.id, attempt: 2}
        |> AutoResumeDispatcher.resume()
        |> assert_deferred(a.id)

      # The attempt counter rides the replay, so the budget still binds.
      assert opts[:awaiting_review_resume_attempts] == 2
    end

    test "ReviewGate fix round (on a ticket no longer In progress)", %{a: a} do
      %{task_id: a.id, attempt: 1, verdict: :request_changes, findings: "x"}
      |> ReviewGateFixRoundDispatcher.dispatch()
      |> assert_deferred(a.id)
    end
  end

  describe "the boot reconciler" do
    # After a reboot nothing is registered for A. A ticket still In progress
    # holds its own slot, whatever cut its run off, so the reconciler resumes
    # it for real at a full cap rather than deferring it.
    test "resumes a ticket In progress uncapped", %{ws: ws, a: a, b: b} do
      first = park_a(a, [], nil)
      admit_b(ws, b)
      Worker.stop(a.id, :normal)
      refute Process.alive?(first.worker_pid)

      assert {:ok, %{resumed: 1, escalated: 0}} =
               Reconciler.reconcile_resumable_tasks(
                 resume_fun: fn issue ->
                   Dispatch.resume(issue.id,
                     resume_origin: :automatic,
                     start_driver: false,
                     claude_command: ["sleep", "2"]
                   )
                 end
               )

      assert StubResumeDeferrer.deferrals() == []
      assert Worker.whereis(a.id) not in [nil, first.worker_pid]
      assert overrides(ws) == []
    end
  end

  describe "a resume of a task that still holds its slot" do
    # Acceptance 1: the fix-round shape. The ReviewGate fails the author only
    # so the implementer round can replace it (`slot_handoff`); the ticket is
    # still In progress, so the round spawns even though the cap is full —
    # #1969/#1995's no-deadlock rule.
    test "a ReviewGate fix round spawns at a full cap", %{ws: ws, a: a, b: b} do
      first = park_a(a, [slot_handoff: true], nil)
      admit_b(ws, b)

      assert {:ok, result} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: fn _, _, _ -> flunk("a held slot must not defer") end,
                 review_gate_fix_round_attempts: 1,
                 start_driver: false,
                 claude_command: ["sleep", "2"]
               )

      assert result.worker_pid != first.worker_pid
      assert overrides(ws) == []
    end
  end

  describe "resume_session/2" do
    test "is gated the same way", %{ws: ws, a: a, b: b} do
      park_a(a)
      admit_b(ws, b)

      {:ok, _} =
        Ash.create(UsageEvent, %{
          task_id: a.id,
          workspace_id: ws.id,
          repo: "rs/repo",
          step: :work,
          provider: "claude",
          session_id: "sess-#{:erlang.unique_integer([:positive])}",
          occurred_at: DateTime.utc_now()
        })

      assert {:error, {:slot_cap_full, %{holders: [holder]}}} =
               Dispatch.resume_session(a.id, start_driver: false, preflight: false)

      assert holder == b.id
    end
  end
end
