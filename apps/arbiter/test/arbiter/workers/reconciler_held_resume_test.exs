defmodule Arbiter.Workers.ReconcilerHeldResumeTest do
  @moduledoc """
  bd-3fbj83: a resume held for the primary's own capacity lived only in
  `Arbiter.Board.Autopilot`'s memory, so a restart orphaned its ticket: In
  progress, no worker, holding a slot. The deferral now leaves a `held_resume`
  marker on the ticket and the boot sweep puts the entry back in the queue.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.HeldResume
  alias Arbiter.Workers.Reconciler

  import Arbiter.LifecycleFixtures, only: [put_state!: 3]

  defp active_ticket! do
    {:ok, ws} = Ash.create(Workspace, %{name: "held-resume-ws", prefix: "hr"})
    {:ok, issue} = Ash.create(Issue, %{title: "held resume", workspace_id: ws.id})
    put_state!(issue, :active, [])
  end

  defp start_autopilot do
    start_supervised!(
      {Autopilot,
       name: nil,
       interval_ms: :never,
       debounce_ms: 60_000,
       topics: [],
       follow_up: false,
       paused: false,
       registry_settled?: fn -> true end,
       snapshot: fn _ ->
         %{
           ready: [],
           backlog: [],
           blocked: [],
           in_progress: [],
           merging: [],
           verifying: [],
           closed_today: [],
           attention: [],
           promote: nil,
           slots_total: 2,
           slots_free: 0,
           quota: :ok,
           paused: false,
           now: DateTime.utc_now()
         }
       end,
       dispatch: fn id -> {:ok, %{task_id: id}} end,
       resume: fn id, _kind, _opts -> {:ok, %{task_id: id}} end,
       local_room: fn _id -> false end,
       priority: fn _id -> 2 end,
       escalate: fn _id, _reason, _n -> :ok end}
    )
  end

  test "a held resume survives a restart: the sweep re-queues it as held" do
    issue = active_ticket!()

    # Before the restart: the deferral leaves its marker on the ticket.
    HeldResume.mark(issue.id, :resume)
    assert :resume = HeldResume.stored_kind(Ash.get!(Issue, issue.id))

    # The restart: a fresh autopilot has an empty queue.
    pid = start_autopilot()
    assert Autopilot.status(pid).held_local_capacity == []

    assert {:ok, %{restarted: [%{task_id: id, phase: :resume}]}} =
             Reconciler.reconcile_held_resumes(
               defer_fun: &Autopilot.defer_resume(pid, &1, &2, &3)
             )

    assert id == issue.id
    assert Autopilot.status(pid).held_local_capacity == [issue.id]
    assert [id] == Reconciler.restarted_ids([{:ok, %{restarted: [%{task_id: id}]}}])

    # Held until the queue replays or drops it, so a second restart re-queues it.
    assert :resume = HeldResume.stored_kind(Ash.get!(Issue, issue.id))
  end

  test "a replayed resume clears the marker" do
    issue = active_ticket!()
    HeldResume.mark(issue.id, :resume)
    HeldResume.clear(issue.id)

    refute HeldResume.stored_kind(Ash.get!(Issue, issue.id))

    assert {:ok, %{restarted: []}} =
             Reconciler.reconcile_held_resumes(defer_fun: fn _, _, _ -> flunk("nothing held") end)
  end

  test "a ticket that is not In progress is not re-queued" do
    issue = active_ticket!()
    HeldResume.mark(issue.id, :resume)
    put_state!(issue, :closed, [])

    assert {:ok, %{restarted: []}} =
             Reconciler.reconcile_held_resumes(defer_fun: fn _, _, _ -> flunk("closed") end)
  end

  test "an autopilot that is not running leaves the ticket to the resume sweep" do
    issue = active_ticket!()
    HeldResume.mark(issue.id, :resume)

    assert {:ok, %{restarted: [], not_restarted: [%{task_id: id, reason: :not_running}]}} =
             Reconciler.reconcile_held_resumes(
               defer_fun: fn _, _, _ -> {:error, :not_running} end
             )

    assert id == issue.id
  end
end
