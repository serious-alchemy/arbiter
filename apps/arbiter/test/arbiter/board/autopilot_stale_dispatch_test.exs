defmodule Arbiter.Board.AutopilotStaleDispatchTest do
  @moduledoc """
  bd-545yem: a promotion still recorded as `dispatching` for a ticket that has
  since closed (or whose task process is gone) pinned the one-promotion-at-a-time
  slot and froze the whole board. The autopilot sweeps such an entry on its next
  pass, and on `pause/1` / `resume/1`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  defp board(promote) do
    %{
      ready: [
        %{id: "bd-2", state: :next, reason: "next up", card: %{id: "bd-2"}}
      ],
      backlog: [],
      blocked: [],
      in_progress: [],
      merging: [],
      verifying: [],
      closed_today: [],
      attention: [],
      promote: promote,
      slots_total: 4,
      slots_free: 4,
      quota: :ok,
      paused: false,
      now: DateTime.utc_now()
    }
  end

  # `closed` is an Agent holding the ids of closed tickets.
  defp start(opts \\ []) do
    test = self()
    {:ok, closed} = Agent.start_link(fn -> MapSet.new() end)

    defaults = [
      name: nil,
      interval_ms: :never,
      debounce_ms: 60_000,
      topics: [],
      follow_up: false,
      paused: false,
      registry_settled?: fn -> true end,
      ticket_closed?: fn id -> Agent.get(closed, &MapSet.member?(&1, id)) end,
      snapshot: fn _ -> board("bd-1") end,
      dispatch: fn id ->
        send(test, {:dispatched, id, self()})

        if id == "bd-1" do
          receive do
            :release -> {:ok, %{task_id: id}}
          end
        else
          {:ok, %{task_id: id}}
        end
      end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    {pid, closed}
  end

  # Starts the hung promotion of bd-1 and returns the task pid.
  defp hang_promotion(pid) do
    test = self()
    spawn_link(fn -> send(test, {:tick_outcome, Autopilot.tick(pid)}) end)
    assert_receive {:dispatched, "bd-1", task}, 2_000
    assert %{dispatching: "bd-1"} = Autopilot.status(pid)
    task
  end

  defp close!(closed, id), do: Agent.update(closed, &MapSet.put(&1, id))

  test "a tick sweeps a promotion whose ticket closed and kills its task" do
    {pid, closed} = start()
    task = hang_promotion(pid)
    ref = Process.monitor(task)

    close!(closed, "bd-1")
    # Nothing left to promote once bd-1 is closed.
    :sys.replace_state(pid, fn s -> %{s | snapshot: fn _ -> board(nil) end} end)

    assert :idle = Autopilot.tick(pid)

    assert %{dispatching: nil} = Autopilot.status(pid)
    assert_receive {:DOWN, ^ref, :process, ^task, _}
    # The tick that started it is answered, not left parked.
    assert_receive {:tick_outcome, {:error, :ticket_closed}}
  end

  test "the next promotion proceeds after the stale one is swept" do
    {pid, closed} = start()
    hang_promotion(pid)

    close!(closed, "bd-1")
    :sys.replace_state(pid, fn s -> %{s | snapshot: fn _ -> board("bd-2") end} end)

    assert {:ok, "bd-2"} = Autopilot.tick(pid)
    assert_receive {:dispatched, "bd-2", _}
  end

  test "an open ticket's in-flight promotion is left alone" do
    {pid, _closed} = start()
    task = hang_promotion(pid)

    assert {:busy, "bd-1"} = Autopilot.tick(pid)
    assert %{dispatching: "bd-1"} = Autopilot.status(pid)

    send(task, :release)
    assert_receive {:tick_outcome, {:ok, "bd-1"}}
  end

  test "pause and resume clear a promotion whose ticket closed" do
    {pid, closed} = start()
    hang_promotion(pid)
    close!(closed, "bd-1")

    assert :ok = Autopilot.pause(pid)
    assert %{dispatching: nil} = Autopilot.status(pid)
    assert_receive {:tick_outcome, {:error, :ticket_closed}}

    {pid, closed} = start()
    hang_promotion(pid)
    close!(closed, "bd-1")

    assert :ok = Autopilot.resume(pid)
    assert %{dispatching: nil} = Autopilot.status(pid)
  end

  test "a promotion whose task process is gone is swept on the next tick" do
    {pid, _closed} = start(snapshot: fn _ -> board(nil) end)

    # A task that died with its DOWN never delivered: the entry names a pid
    # that is dead and a monitor ref that will never fire.
    {dead, mref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^mref, :process, ^dead, _}

    :sys.replace_state(pid, fn s ->
      %{s | dispatching: %{ref: make_ref(), id: "bd-1", waiters: [], pid: dead}}
    end)

    assert {:busy, "bd-1"} = Autopilot.tick(pid)
    _ = :sys.get_state(pid)
    assert %{dispatching: nil} = Autopilot.status(pid)
  end
end
