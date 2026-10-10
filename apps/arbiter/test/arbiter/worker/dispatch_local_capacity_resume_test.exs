defmodule Arbiter.Worker.DispatchLocalCapacityResumeTest do
  @moduledoc """
  bd-b2iigy: every follow-up spawn of a ticket with a preserved worktree — a
  briefing or session resume, a Reconciler or auto-resume, a re-dispatch of an
  In-progress ticket — is admitted through `Arbiter.Nodes.LocalCapacity`. At the
  primary's cap it is held (a human resume is refused with the hold, an
  automatic one is deferred to the scheduler as `held_for: :local_capacity`),
  never started over the cap, and the prior worker is left exactly as it was.

  Driven end to end against a real git repo and real workers
  (`Arbiter.Test.ResumeSlotFixture`): A is In progress with its worker parked
  `:failed`, B is In progress with a live worker on the primary, and the
  primary's cap is overridden to 1.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.{ResumeSlotFixture, StubResumeDeferrer}
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "local-cap-resume-#{System.unique_integer([:positive])}",
        prefix: "lcr#{System.unique_integer([:positive])}"
      })

    ResumeSlotFixture.setup_repo!()
    StubResumeDeferrer.reset()
    on_exit(fn -> Arbiter.Settings.set_nodes_local_max_workers(nil) end)

    {:ok, a} = Ash.create(Issue, %{title: "task A (cut off)", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B (running)", workspace_id: ws.id})

    # A stays In progress (`release: nil`): it holds its board slot, so
    # `ResumeSlot` lets the resume through and only the primary's cap is in play.
    first = ResumeSlotFixture.park!(a, nil)
    ResumeSlotFixture.admit!(ws, b)

    # A recorded session, so `resume_session/2` has something to continue.
    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: a.id,
        workspace_id: ws.id,
        repo: ResumeSlotFixture.repo(),
        step: :work,
        provider: "claude",
        session_id: "sess-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

    %{ws: ws, a: a, b: b, first: first}
  end

  defp cap!(n), do: {:ok, ^n} = Arbiter.Nodes.set_local_max_workers(n, nil)

  describe "at the primary's cap (cap 1, B live)" do
    test "a human resume is refused as held, and the parked worker is untouched",
         %{a: a, b: b, first: first} do
      cap!(1)

      assert {:error, {:no_node_capacity, info}} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["true"])

      assert info.cap == 1
      assert info.kind == :resume
      assert info.holders |> Enum.any?(&String.starts_with?(&1, b.id))
      assert info.phrase =~ "held — local capacity full (cap 1, 1 running)"

      assert Worker.whereis(a.id) == first.worker_pid
      assert Worker.state(first.worker_pid).outcome == :failed
    end

    test "a human session resume is refused the same way", %{a: a, first: first} do
      cap!(1)

      assert {:error, {:no_node_capacity, %{kind: :resume}}} =
               Dispatch.resume_session(a.id, start_driver: false, claude_command: ["true"])

      assert Worker.whereis(a.id) == first.worker_pid
    end

    test "an automatic resume is deferred as held for local capacity, nothing started",
         %{a: a, first: first} do
      cap!(1)
      task_id = a.id

      assert {:ok, %{deferred: true, task_id: ^task_id, cap: 1, holders: [_]}} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 revise_feedback: "address the review",
                 start_driver: false
               )

      assert [{^task_id, :resume, opts}] = StubResumeDeferrer.deferrals()
      assert opts[:held_for] == :local_capacity
      assert opts[:revise_feedback] == "address the review"
      assert opts[:resume_origin] == :automatic

      assert Worker.whereis(a.id) == first.worker_pid
    end

    test "an automatic session resume is deferred the same way", %{a: a} do
      cap!(1)
      task_id = a.id

      assert {:ok, %{deferred: true, task_id: ^task_id}} =
               Dispatch.resume_session(a.id, resume_origin: :automatic, start_driver: false)

      assert [{^task_id, :resume_session, opts}] = StubResumeDeferrer.deferrals()
      assert opts[:held_for] == :local_capacity
    end

    test "a deferral nobody can take is a refusal, never a bypass", %{a: a} do
      cap!(1)

      assert {:error, {:no_node_capacity, _}} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: fn _, _, _ -> {:error, :no_scheduler} end,
                 start_driver: false
               )
    end

    test "force resumes over the cap (recorded)", %{a: a, first: first} do
      cap!(1)

      assert {:ok, result} =
               Dispatch.resume(a.id,
                 start_driver: false,
                 claude_command: ["sleep", "2"],
                 force_slot: true,
                 slot_override_actor: "coordinator"
               )

      assert result.worker_pid != first.worker_pid
    end

    test "a re-dispatch of the In-progress ticket (its worker gone) is held too",
         %{a: a, first: first} do
      cap!(1)
      :ok = Worker.stop(first.worker_pid, :normal)
      assert Worker.whereis(a.id) == nil

      assert {:error, {:no_node_capacity, %{kind: :redispatch}}} =
               Dispatch.dispatch(a.id,
                 repo: ResumeSlotFixture.repo(),
                 start_driver: false,
                 claude_command: ["true"]
               )

      assert Worker.whereis(a.id) == nil
    end
  end

  # The production drain end to end: the real `Autopilot.defer_resume/4` queues
  # the held resume, and the Autopilot's own default replay (`Dispatch.resume/2`
  # with `slot_admitted: true`, its default `LocalCapacity.check/3` room test)
  # starts it once B's slot frees — with the board showing no free slot at all.
  test "the scheduler replays a held resume for real once the primary has room",
       %{a: a, b: b, first: first} do
    cap!(1)

    {:ok, autopilot} =
      Arbiter.Board.Autopilot.start_link(
        name: nil,
        paused: true,
        interval_ms: :never,
        debounce_ms: 60_000,
        topics: [],
        registry_settled?: fn -> true end,
        snapshot: fn _ -> %{promote: nil, ready: [], slots_free: 0} end
      )

    assert {:ok, %{deferred: true, held_for: :local_capacity}} =
             Dispatch.resume(a.id,
               resume_origin: :automatic,
               defer_resume: &Arbiter.Board.Autopilot.defer_resume(autopilot, &1, &2, &3),
               start_driver: false,
               claude_command: ["sleep", "2"]
             )

    assert Arbiter.Board.Autopilot.status(autopilot).held_local_capacity == [a.id]
    assert :paused = Arbiter.Board.Autopilot.tick(autopilot)
    assert Worker.whereis(a.id) == first.worker_pid

    :ok = Worker.stop(b.id, :normal)
    task_id = a.id
    assert {:resumed, ^task_id} = Arbiter.Board.Autopilot.tick(autopilot, 30_000)

    resumed = Worker.whereis(a.id)
    assert resumed not in [nil, first.worker_pid]
    assert Worker.state(resumed).meta[:resume] == true
    assert Arbiter.Board.Autopilot.status(autopilot).held_local_capacity == []
  end

  describe "with room on the primary" do
    test "a resume goes through and takes the second slot (cap 2, B live)", %{a: a, first: first} do
      cap!(2)

      assert {:ok, result} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["sleep", "2"])

      assert result.worker_pid != first.worker_pid
      assert StubResumeDeferrer.deferrals() == []
    end

    test "a ticket's own run never counts against its resume (cap 1, A alone)",
         %{a: a, b: b} do
      cap!(1)
      Worker.stop(b.id, :normal)

      assert {:ok, _result} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["sleep", "2"])
    end
  end

  describe "with no override" do
    test "the hardware suggestion applies (enforced), and a resume under it is admitted",
         %{a: a} do
      ResumeSlotFixture.put_local_cap(nil)
      assert %{source: :suggestion} = Arbiter.Nodes.LocalCapacity.cap()

      assert {:ok, _result} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["sleep", "2"])
    end
  end
end
