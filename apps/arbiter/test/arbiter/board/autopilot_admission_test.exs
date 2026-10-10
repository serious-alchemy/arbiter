defmodule Arbiter.Board.AutopilotAdmissionTest do
  @moduledoc """
  Autopilot under `scheduler_admission` (DC6, provider-dynamic-concurrency
  §10.1-§10.2):

    * `legacy` asks the board for nothing new, dispatches with exactly today's
      options and records nothing (I1);
    * `shadow` (and `enforce`, until DC8 wires it) dispatches exactly what
      `legacy` would (I2), with the walk's decision riding on the dispatch as
      `admission_shadow`, and writes an event row only when either side's
      outcome changes.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Board.Autopilot

  @pool {"acct", "claude"}

  defp entry(id, state, opts \\ []) do
    %{
      id: id,
      state: state,
      reason: Keyword.get(opts, :reason, "next up — dispatching..."),
      hold: Keyword.get(opts, :hold),
      card: %{id: id}
    }
  end

  defp walk(placements, entries) do
    %{
      promote: placements |> List.first() |> then(&(&1 && &1.id)),
      placements: placements,
      entries: entries,
      pools: %{@pool => %{budget: 3, seats: 1, cap: 3, label: "claude:default", reason: "5h"}},
      nodes: %{"local" => %{cap: 6, used: 1, label: "local"}}
    }
  end

  # Today promotes `promote`; the walk would place `walk_pick`.
  defp board(promote, walk_pick, opts) do
    ready = [
      entry("bd-1", if(promote == "bd-1", do: :next, else: :queued)),
      entry("bd-2", :queued)
    ]

    walk_entries =
      for id <- ["bd-1", "bd-2"] do
        if id == walk_pick,
          do:
            %{entry(id, :next) | hold: nil}
            |> Map.merge(%{wait_cause: nil, pair: %{pool: @pool, node: "local"}}),
          else:
            entry(id, :blocked, reason: "waiting for claude:default: 3 of 3 seats")
            |> Map.merge(%{wait_cause: {:capacity, :provider}, pair: nil})
      end

    placements = if walk_pick, do: [%{id: walk_pick, pool: @pool, node: "local"}], else: []

    base = %{
      ready: ready,
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
      paused: Keyword.get(opts, :paused, false),
      now: DateTime.utc_now()
    }

    if Keyword.get(opts, :walk?, true),
      do: Map.put(base, :walk, walk(placements, walk_entries)),
      else: base
  end

  defp start(mode, board_fun, opts \\ []) do
    test = self()

    defaults = [
      name: nil,
      paused: false,
      interval_ms: :never,
      debounce_ms: 20,
      topics: [],
      follow_up: false,
      registry_settled?: fn -> true end,
      admission: fn -> mode end,
      snapshot: fn opts ->
        send(test, {:snapshot_opts, opts})
        board_fun.(opts)
      end,
      dispatch: fn id, extra ->
        send(test, {:dispatched, id, extra})
        {:ok, %{task_id: id}}
      end,
      record_shadow: fn attrs ->
        send(test, {:shadow_event, attrs})
        :ok
      end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "legacy (I1)" do
    test "asks the board for nothing new, dispatches with today's options, records nothing" do
      pid = start(:legacy, fn _ -> board("bd-1", "bd-2", walk?: false) end)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_received {:snapshot_opts, opts}
      refute Keyword.has_key?(opts, :admission)
      assert_received {:dispatched, "bd-1", []}
      refute_received {:shadow_event, _}
    end

    test "a legacy pass ignores a walk the board happens to carry" do
      pid = start(:legacy, fn _ -> board("bd-1", "bd-2", []) end)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-1", []}
      refute_received {:shadow_event, _}
    end
  end

  for mode <- [:shadow, :enforce] do
    describe "#{mode}" do
      test "dispatches today's card, with the walk's decision riding on it" do
        mode = unquote(mode)
        pid = start(mode, fn _ -> board("bd-1", "bd-2", []) end)

        assert {:ok, "bd-1"} = Autopilot.tick(pid)
        assert_received {:snapshot_opts, opts}
        assert Keyword.get(opts, :admission) == mode

        assert_received {:dispatched, "bd-1", [admission_shadow: record]}

        assert %{
                 "policy" => policy,
                 "dispatched" => "bd-1",
                 "pick" => "bd-2",
                 "agrees" => false,
                 "cause" => "capacity:provider"
               } = record

        assert policy == to_string(mode)
      end

      test "writes an event when an outcome changes, and only then" do
        mode = unquote(mode)
        {:ok, boards} = Agent.start_link(fn -> board(nil, "bd-2", []) end)
        on_exit(fn -> if Process.alive?(boards), do: Agent.stop(boards) end)

        pid = start(mode, fn _ -> Agent.get(boards, & &1) end)

        assert :idle = Autopilot.tick(pid)
        assert_received {:shadow_event, %{legacy_pick: nil, walk_pick: "bd-2", policy: policy}}
        assert policy == to_string(mode)

        # The same outcome again: nothing new is written.
        assert :idle = Autopilot.tick(pid)
        refute_received {:shadow_event, _}

        # The walk's pick changes: one more row.
        Agent.update(boards, fn _ -> board(nil, "bd-1", []) end)
        assert :idle = Autopilot.tick(pid)
        assert_received {:shadow_event, %{walk_pick: "bd-1"}}
      end

      test "a board without a walk dispatches as legacy and records nothing" do
        pid = start(unquote(mode), fn _ -> board("bd-1", nil, walk?: false) end)

        assert {:ok, "bd-1"} = Autopilot.tick(pid)
        assert_received {:dispatched, "bd-1", []}
        refute_received {:shadow_event, _}
      end
    end
  end

  @tag capture_log: true
  test "a walk the shadow cannot read records nothing and still dispatches today's card" do
    broken = Map.put(board("bd-1", nil, walk?: false), :walk, %{promote: "bd-2"})
    pid = start(:shadow, fn _ -> broken end)

    assert {:ok, "bd-1"} = Autopilot.tick(pid)
    assert_receive {:dispatched, "bd-1", []}
    refute_received {:shadow_event, _}
    assert Process.alive?(pid)
  end

  test "a one-argument dispatch seam is still called under shadow, with the id alone" do
    test = self()

    pid =
      start(:shadow, fn _ -> board("bd-1", "bd-1", []) end,
        dispatch: fn id ->
          send(test, {:dispatched_1, id})
          {:ok, %{task_id: id}}
        end
      )

    assert {:ok, "bd-1"} = Autopilot.tick(pid)
    assert_received {:dispatched_1, "bd-1"}
  end

  test "switching back to legacy forgets the last signature" do
    {:ok, mode} = Agent.start_link(fn -> :shadow end)
    on_exit(fn -> if Process.alive?(mode), do: Agent.stop(mode) end)

    pid =
      start(:shadow, fn _ -> board(nil, "bd-2", []) end,
        admission: fn -> Agent.get(mode, & &1) end
      )

    assert :idle = Autopilot.tick(pid)
    assert_received {:shadow_event, _}

    Agent.update(mode, fn _ -> :legacy end)
    assert :idle = Autopilot.tick(pid)
    refute_received {:shadow_event, _}

    # Back in shadow: the first pass records again, from a clean slate.
    Agent.update(mode, fn _ -> :shadow end)
    assert :idle = Autopilot.tick(pid)
    assert_received {:shadow_event, _}
  end

  # ---- I2 at the Autopilot ------------------------------------------------------

  defp board_gen do
    gen all(
          promote <- member_of([nil, "bd-1", "bd-2"]),
          walk_pick <- member_of([nil, "bd-1", "bd-2"]),
          walk? <- boolean(),
          head_hold <-
            member_of([:no_slot, {:quota, "5h ahead of pace"}, {:blocked_by, ["bd-9"]}])
        ) do
      board = board(promote, walk_pick, walk?: walk?)

      if promote,
        do: board,
        else:
          Map.update!(board, :ready, fn [first | rest] ->
            [%{first | state: :blocked, hold: head_hold, reason: "held"} | rest]
          end)
    end
  end

  property "I2: under shadow and enforce, every pass dispatches what legacy dispatches" do
    check all(board <- board_gen(), mode <- member_of([:shadow, :enforce]), max_runs: 60) do
      outcomes =
        for admission <- [:legacy, mode] do
          pid = start(admission, fn _ -> board end)
          outcome = Autopilot.tick(pid)

          dispatched =
            receive do
              {:dispatched, id, _extra} -> id
            after
              0 -> nil
            end

          holds = :sys.get_state(pid).holds
          GenServer.stop(pid)
          flush()
          {outcome, dispatched, holds}
        end

      [legacy, shadowed] = outcomes
      assert shadowed == legacy
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
