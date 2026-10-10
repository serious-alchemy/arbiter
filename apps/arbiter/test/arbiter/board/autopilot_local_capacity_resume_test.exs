defmodule Arbiter.Board.AutopilotLocalCapacityResumeTest do
  @moduledoc """
  bd-b2iigy: an automatic resume held by the primary's own cap
  (`Arbiter.Nodes.LocalCapacity`, `held_for: :local_capacity`) waits in the
  scheduler's deferred queue and is replayed — highest ticket priority first —
  the moment the primary has room. It is a different wait from the board slot:
  the ticket is already In progress, so a free board slot is neither needed nor
  enough.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  defp board(slots_free) do
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
      slots_free: slots_free,
      quota: :ok,
      paused: false,
      now: DateTime.utc_now()
    }
  end

  # `room` is an Agent holding how many local slots are free; `priorities` maps
  # a ticket to its priority (0 = highest).
  defp start(opts) do
    test = self()
    {:ok, room} = Agent.start_link(fn -> Keyword.get(opts, :room, 0) end)
    priorities = Keyword.get(opts, :priorities, %{})

    defaults = [
      name: nil,
      interval_ms: :never,
      debounce_ms: 60_000,
      topics: [],
      follow_up: false,
      paused: false,
      registry_settled?: fn -> true end,
      snapshot: fn _ -> board(Keyword.get(opts, :slots_free, 0)) end,
      dispatch: fn id -> {:ok, %{task_id: id}} end,
      resume: fn task_id, kind, resume_opts ->
        send(test, {:resumed, task_id, kind, resume_opts})

        # A replay takes the local slot it was waiting for.
        Agent.update(room, &max(&1 - 1, 0))
        {:ok, %{task_id: task_id}}
      end,
      local_room: fn _task_id -> Agent.get(room, & &1) > 0 end,
      priority: fn id -> Map.get(priorities, id, 2) end,
      escalate: fn id, reason, n -> send(test, {:escalated, id, reason, n}) end
    ]

    {:ok, pid} =
      Autopilot.start_link(
        Keyword.merge(defaults, Keyword.drop(opts, [:room, :priorities, :slots_free]))
      )

    {pid, room}
  end

  defp free_local_slots(room, n), do: Agent.update(room, fn _ -> n end)

  test "a resume held for local capacity waits while the primary is full, board slots or not" do
    {pid, _room} = start(room: 0, slots_free: 3)

    :ok = Autopilot.defer_resume(pid, "bd-a", :resume, held_for: :local_capacity)

    assert :idle = Autopilot.tick(pid)
    refute_received {:resumed, _, _, _}

    status = Autopilot.status(pid)
    assert status.deferred_resumes == ["bd-a"]
    assert status.held_local_capacity == ["bd-a"]
  end

  test "it replays when the primary has room, with no board slot free, and the marker is dropped" do
    {pid, room} = start(room: 0, slots_free: 0)
    :ok = Autopilot.defer_resume(pid, "bd-a", :resume, held_for: :local_capacity, attempt: 1)

    free_local_slots(room, 1)
    assert {:resumed, "bd-a"} = Autopilot.tick(pid)

    assert_received {:resumed, "bd-a", :resume, opts}
    assert opts[:attempt] == 1
    assert opts[:slot_admitted] == true
    refute Keyword.has_key?(opts, :held_for)
    assert Autopilot.status(pid).held_local_capacity == []
  end

  test "held resumes replay in ticket priority order, one per free slot, not all at once" do
    {pid, room} =
      start(room: 0, priorities: %{"bd-p3" => 3, "bd-p0" => 0, "bd-p1" => 1, "bd-p2" => 2})

    # Arrival order is the reverse of priority order.
    for id <- ["bd-p3", "bd-p2", "bd-p1", "bd-p0"] do
      :ok = Autopilot.defer_resume(pid, id, :resume, held_for: :local_capacity)
    end

    free_local_slots(room, 2)
    assert {:resumed, "bd-p0"} = Autopilot.tick(pid)
    assert {:resumed, "bd-p1"} = Autopilot.tick(pid)

    # The cap's worth is out; the rest wait for slots to free.
    assert :idle = Autopilot.tick(pid)
    assert Autopilot.status(pid).held_local_capacity == ["bd-p3", "bd-p2"]

    free_local_slots(room, 1)
    assert {:resumed, "bd-p2"} = Autopilot.tick(pid)
    free_local_slots(room, 1)
    assert {:resumed, "bd-p3"} = Autopilot.tick(pid)
  end

  test "equal priorities keep their arrival order" do
    {pid, room} = start(room: 0)
    :ok = Autopilot.defer_resume(pid, "bd-first", :resume, held_for: :local_capacity)
    :ok = Autopilot.defer_resume(pid, "bd-second", :resume_session, held_for: :local_capacity)

    free_local_slots(room, 1)
    assert {:resumed, "bd-first"} = Autopilot.tick(pid)
  end

  test "a resume deferred for a board slot is unaffected by local room, and does not block a held one" do
    {pid, room} = start(room: 1, slots_free: 0)
    :ok = Autopilot.defer_resume(pid, "bd-slot", :resume, [])
    :ok = Autopilot.defer_resume(pid, "bd-local", :resume, held_for: :local_capacity)

    # No board slot is free, so the slot-deferred resume waits; the local one
    # is not behind it.
    assert {:resumed, "bd-local"} = Autopilot.tick(pid)
    refute_received {:resumed, "bd-slot", _, _}
    assert Autopilot.status(pid).deferred_resumes == ["bd-slot"]
    free_local_slots(room, 1)
  end

  test "a ticket is deferred once: a second deferral replaces the first and keeps one entry" do
    {pid, _room} = start(room: 0)
    :ok = Autopilot.defer_resume(pid, "bd-a", :resume, held_for: :local_capacity, attempt: 1)
    :ok = Autopilot.defer_resume(pid, "bd-a", :resume_session, held_for: :local_capacity)

    assert Autopilot.status(pid).deferred_resumes == ["bd-a"]
  end

  test "a replay the primary holds again goes back to waiting, once, without escalating" do
    test = self()
    name = :"autopilot_local_hold_#{System.unique_integer([:positive])}"
    {:ok, room} = Agent.start_link(fn -> 1 end)

    {pid, _} =
      start(
        name: name,
        room: 1,
        local_room: fn _ -> Agent.get(room, & &1) > 0 end,
        resume: fn task_id, kind, opts ->
          # Lost the slot between the check and the dispatch: Dispatch defers it again.
          send(test, {:replayed, task_id})
          Agent.update(room, fn _ -> 0 end)

          :ok =
            Autopilot.defer_resume(
              name,
              task_id,
              kind,
              Keyword.put(opts, :held_for, :local_capacity)
            )

          {:ok, %{deferred: true, task_id: task_id}}
        end
      )

    :ok = Autopilot.defer_resume(pid, "bd-a", :resume, held_for: :local_capacity)

    assert {:deferred, "bd-a"} = Autopilot.tick(pid)
    assert_received {:replayed, "bd-a"}
    refute_received {:escalated, _, _, _}
    assert Autopilot.status(pid).held_local_capacity == ["bd-a"]

    # Still held: nothing replays until there is room again.
    assert :idle = Autopilot.tick(pid)
    refute_received {:replayed, _}
  end

  test "cancel_deferred drops a held resume" do
    {pid, room} = start(room: 0)
    :ok = Autopilot.defer_resume(pid, "bd-closed", :resume, held_for: :local_capacity)
    assert :ok = Autopilot.cancel_deferred(pid, "bd-closed")

    free_local_slots(room, 1)
    assert :idle = Autopilot.tick(pid)
    assert Autopilot.status(pid).held_local_capacity == []
  end

  test "a held resume's replay that finds the worker already running is dropped quietly" do
    {pid, room} =
      start(room: 0, resume: fn _, _, _ -> {:error, {:worker_active, :running}} end)

    :ok = Autopilot.defer_resume(pid, "bd-raced", :resume, held_for: :local_capacity)
    free_local_slots(room, 1)

    assert {:error, {:worker_active, :running}} = Autopilot.tick(pid)
    refute_received {:escalated, _, _, _}
    assert Autopilot.status(pid).deferred_resumes == []
  end
end
