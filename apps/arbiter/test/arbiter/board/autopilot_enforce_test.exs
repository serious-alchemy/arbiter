defmodule Arbiter.Board.AutopilotEnforceTest do
  @moduledoc """
  Autopilot under `scheduler_admission: enforce` (DC8, design
  `provider-dynamic-concurrency.md` §4.3, §4.4, §10.1-§10.2):

    * the walk decides: the pass dispatches the walk's first placement on a pool
      in `enforce`, with its pair riding in as `planned: %{account_id, pool,
      node}`;
    * the reverse shadow: beside it, `admission_shadow` records what today's
      plan would have done (`pick`, `agrees`, `comparable`, `cause`);
    * a board with no walk (its inputs failed) dispatches today's card, as
      `legacy` would;
    * a budget that rises plans a pass, like a freed slot; a fall does not;
    * a resume deferred for a slot is replayed when its own pool has a seat,
      whatever the board's slot count says.

  `legacy` and `shadow` are `Arbiter.Board.AutopilotAdmissionTest`'s.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Autopilot

  @pool {"acct", "claude"}
  @other_pool {"acct-2", "codex"}

  defp entry(id, state, opts \\ []) do
    %{
      id: id,
      state: state,
      reason: Keyword.get(opts, :reason, "next up — dispatching..."),
      hold: Keyword.get(opts, :hold),
      card: %{id: id}
    }
  end

  # Today's plan: `legacy` is `{promote, ready}`; the walk places `placements`.
  defp board(legacy_promote, legacy_ready, placements, opts \\ []) do
    walk_entries =
      for %{id: id} = placement <- placements do
        %{entry(id, :next) | hold: nil}
        |> Map.merge(%{wait_cause: nil, pair: %{pool: placement.pool, node: placement.node}})
      end

    base = %{
      ready: legacy_ready,
      backlog: [],
      blocked: [],
      in_progress: [],
      merging: [],
      verifying: [],
      closed_today: [],
      attention: [],
      promote: legacy_promote,
      slots_total: 4,
      slots_free: Keyword.get(opts, :slots_free, 4),
      quota: :ok,
      paused: false,
      now: DateTime.utc_now()
    }

    if Keyword.get(opts, :walk?, true) do
      Map.put(base, :walk, %{
        promote: placements |> List.first() |> then(&(&1 && &1.id)),
        placements: placements,
        entries: walk_entries,
        pools: %{
          @pool => %{budget: 3, seats: 1, cap: 3, label: "claude:default", reason: "5h"},
          @other_pool => %{budget: 2, seats: 0, cap: nil, label: "codex:default", reason: "5h"}
        },
        nodes: %{"local" => %{cap: 6, used: 1, label: "local"}}
      })
    else
      base
    end
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
      snapshot: fn _opts -> board_fun.() end,
      dispatch: fn id, extra ->
        send(test, {:dispatched, id, extra})
        {:ok, %{task_id: id}}
      end,
      record_shadow: fn attrs ->
        send(test, {:shadow_event, attrs})
        :ok
      end,
      resume: fn task_id, kind, opts ->
        send(test, {:resumed, task_id, kind, opts})
        {:ok, %{task_id: task_id}}
      end
    ]

    {:ok, pid} = Autopilot.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "the walk decides" do
    test "the walk's placement goes, with its planned pair and the reverse shadow" do
      legacy = [entry("bd-1", :next), entry("bd-2", :queued, reason: "1 ahead in queue")]
      placements = [%{id: "bd-2", pool: @pool, node: "local"}]
      pid = start(:enforce, fn -> board("bd-1", legacy, placements) end)

      assert {:ok, "bd-2"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-2", extra}

      assert extra[:planned] == %{account_id: "acct", pool: "claude", node: "local"}

      assert %{
               "policy" => "enforce",
               "dispatched" => "bd-2",
               "pick" => "bd-1",
               "agrees" => false,
               "comparable" => true,
               "cause" => "queued",
               "reason" => "1 ahead in queue",
               "account_id" => "acct",
               "pool" => "claude",
               "node" => "local",
               "placements" => 1
             } = extra[:admission_shadow]
    end

    test "when today's plan agrees, the record says so" do
      legacy = [entry("bd-1", :next)]
      placements = [%{id: "bd-1", pool: @pool, node: "local"}]
      pid = start(:enforce, fn -> board("bd-1", legacy, placements) end)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-1", extra}
      assert %{"agrees" => true, "comparable" => true, "cause" => nil} = extra[:admission_shadow]
    end

    test "a card today would hold goes, and the record names today's hold" do
      legacy = [
        entry("bd-1", :blocked, hold: {:quota, "5h ahead of pace"}, reason: "blocked — quota")
      ]

      placements = [%{id: "bd-1", pool: @pool, node: "local"}]
      pid = start(:enforce, fn -> board(nil, legacy, placements) end)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-1", extra}

      assert %{
               "pick" => nil,
               "agrees" => false,
               "comparable" => false,
               "cause" => "legacy_hold",
               "legacy_hold" => "quota",
               "reason" => "blocked — quota"
             } = extra[:admission_shadow]
    end

    test "with nothing placed, nothing goes — whatever today's plan would promote" do
      legacy = [entry("bd-1", :next)]
      pid = start(:enforce, fn -> board("bd-1", legacy, []) end)

      assert :idle = Autopilot.tick(pid)
      refute_received {:dispatched, _, _}
    end

    test "an unmetered pool's placement plans its machine only" do
      legacy = [entry("bd-1", :next)]
      placements = [%{id: "bd-1", pool: {:unmetered, "ollama"}, node: "local"}]
      pid = start(:enforce, fn -> board("bd-1", legacy, placements) end)

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-1", extra}
      assert extra[:planned] == %{account_id: nil, pool: nil, node: "local"}
    end

    test "the hold-change event is still written, once per change" do
      legacy = [entry("bd-1", :next)]
      pid = start(:enforce, fn -> board("bd-1", legacy, []) end)

      assert :idle = Autopilot.tick(pid)
      assert_received {:shadow_event, %{policy: "enforce", legacy_pick: "bd-1", walk_pick: nil}}

      assert :idle = Autopilot.tick(pid)
      refute_received {:shadow_event, _}
    end
  end

  @tag capture_log: true
  test "a walk with no entries or placements is today's plan's, and an idle pass survives it" do
    legacy = [entry("bd-1", :blocked, hold: :no_slot, reason: "blocked — no free worker slot")]
    broken = Map.put(board(nil, legacy, [], walk?: false), :walk, %{promote: nil})
    pid = start(:enforce, fn -> broken end)

    assert :idle = Autopilot.tick(pid)
    assert Process.alive?(pid)
    assert [%{id: "bd-1"}] = :sys.get_state(pid).holds
  end

  test "a board without a walk dispatches today's card, with no record (fail safe)" do
    legacy = [entry("bd-1", :next)]
    pid = start(:enforce, fn -> board("bd-1", legacy, [], walk?: false) end)

    assert {:ok, "bd-1"} = Autopilot.tick(pid)
    assert_received {:dispatched, "bd-1", []}
  end

  describe "per-account modes (O11)" do
    test "the first placement on a pool in enforce goes; a shadow pool's does not" do
      legacy = [entry("bd-1", :next), entry("bd-2", :queued)]

      placements = [
        %{id: "bd-1", pool: @pool, node: "local"},
        %{id: "bd-2", pool: @other_pool, node: "local"}
      ]

      pool_mode = fn
        @other_pool -> :enforce
        _ -> :shadow
      end

      pid =
        start(:enforce, fn -> board("bd-1", legacy, placements) end,
          pool_mode: pool_mode,
          install_mode: :shadow
        )

      assert {:ok, "bd-2"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-2", extra}
      assert extra[:planned].account_id == "acct-2"
      assert extra[:admission_shadow]["policy"] == "enforce"
    end

    test "with no placement on an enforce pool, today's card goes with the forward record" do
      legacy = [entry("bd-1", :next)]
      placements = [%{id: "bd-1", pool: @pool, node: "local"}]

      pid =
        start(:enforce, fn -> board("bd-1", legacy, placements) end,
          pool_mode: fn _ -> :shadow end,
          install_mode: :shadow
        )

      assert {:ok, "bd-1"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-1", extra}
      refute Keyword.has_key?(extra, :planned)
      assert %{"policy" => "shadow", "pick" => "bd-1"} = extra[:admission_shadow]
    end
  end

  describe "a budget change (E8)" do
    test "enforce: a rise plans a pass, like a freed seat" do
      legacy = [entry("bd-1", :next)]
      placements = [%{id: "bd-1", pool: @pool, node: "local"}]
      pid = start(:enforce, fn -> board("bd-1", legacy, placements) end)

      send(pid, {:budget_changed, %{account: "acct", pool: "claude"}, 1, 2, "5h"})
      assert_receive {:dispatched, "bd-1", _extra}, 1_000
    end

    test "enforce: a fall plans nothing" do
      legacy = [entry("bd-1", :next)]
      placements = [%{id: "bd-1", pool: @pool, node: "local"}]
      pid = start(:enforce, fn -> board("bd-1", legacy, placements) end)

      send(pid, {:budget_changed, %{account: "acct", pool: "claude"}, 2, 1, "5h"})
      refute_receive {:dispatched, _, _}, 200
    end

    test "legacy: a rise plans nothing" do
      legacy = [entry("bd-1", :next)]
      pid = start(:legacy, fn -> board("bd-1", legacy, [], walk?: false) end)

      send(pid, {:budget_changed, %{account: "acct", pool: "claude"}, 1, 2, "5h"})
      refute_receive {:dispatched, _, _}, 200
    end
  end

  describe "a resume deferred for a slot" do
    test "enforce: replayed when its pool has a seat, though the board has no free slot" do
      test = self()
      legacy = [entry("bd-1", :next)]

      pid =
        start(:enforce, fn -> board(nil, legacy, [], slots_free: 0) end,
          slot_room: fn task_id, _kind ->
            send(test, {:asked, task_id})
            true
          end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert {:resumed, "bd-parked"} = Autopilot.tick(pid)
      assert_received {:asked, "bd-parked"}
      assert_received {:resumed, "bd-parked", :resume, opts}
      assert opts[:slot_admitted] == true
    end

    test "enforce: waits while its pool is full" do
      legacy = [entry("bd-1", :next)]

      pid =
        start(:enforce, fn -> board(nil, legacy, [], slots_free: 4) end,
          slot_room: fn _task_id, _kind -> false end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert :idle = Autopilot.tick(pid)
      refute_received {:resumed, _, _, _}
    end

    test "legacy: the board's free slots decide, and no seat is asked" do
      legacy = [entry("bd-1", :next)]

      pid =
        start(:legacy, fn -> board(nil, legacy, [], slots_free: 1, walk?: false) end,
          slot_room: fn _task_id, _kind -> flunk("legacy must not ask for a seat") end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert {:resumed, "bd-parked"} = Autopilot.tick(pid)
    end
  end

  describe "a deferred resume its pool cannot admit (bd-7twuru)" do
    @blocked_pool {"acct-codex", "codex"}

    defp placement(id, pool), do: %{id: id, pool: pool, node: "local"}

    test "does not hold Ready cards of other pools" do
      placements = [placement("bd-ready", @pool)]

      pid =
        start(:enforce, fn -> board(nil, [entry("bd-ready", :next)], placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn "bd-parked" -> "acct-codex" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert {:ok, "bd-ready"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-ready", _}
      refute_received {:resumed, _, _, _}
      assert Autopilot.status(pid).deferred_resumes == ["bd-parked"]
    end

    test "still goes before Ready cards of its own pool" do
      placements = [placement("bd-same", @blocked_pool)]

      pid =
        start(:enforce, fn -> board(nil, [entry("bd-same", :next)], placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn "bd-parked" -> "acct-codex" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert :idle = Autopilot.tick(pid)
      refute_received {:dispatched, _, _}
    end

    test "blocks the account Dispatch recorded, not the implementer's" do
      placements = [placement("bd-ready", @pool)]

      pid =
        start(:enforce, fn -> board(nil, [entry("bd-ready", :next)], placements) end,
          slot_room: fn _task_id, _kind -> false end,
          # the implementer is on the Ready card's (claude) account
          resume_account: fn "bd-parked" -> "acct" end
        )

      :ok =
        Autopilot.defer_resume(pid, "bd-parked", :resume, waiting_account: "acct-codex")

      assert {:ok, "bd-ready"} = Autopilot.tick(pid)
      assert_received {:dispatched, "bd-ready", _}
      refute_received {:resumed, _, _, _}
      assert [%{opts: opts}] = :sys.get_state(pid).deferred_resumes
      refute Keyword.has_key?(opts, :waiting_account)
    end

    test "an entry without a recorded account falls back to the implementer's" do
      placements = [placement("bd-ready", @pool)]

      pid =
        start(:enforce, fn -> board(nil, [entry("bd-ready", :next)], placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn "bd-parked" -> "acct" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      assert :idle = Autopilot.tick(pid)
      refute_received {:dispatched, _, _}
    end

    test "parks naming the recorded account" do
      test = self()

      pid =
        start(:enforce, fn -> board(nil, [], []) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn _ -> "acct" end,
          park_after: 2,
          escalate: fn id, reason, prio ->
            send(test, {:escalated, id, reason, prio})
            :ok
          end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, waiting_account: "acct-codex")
      for _ <- 1..4, do: Autopilot.tick(pid)

      assert_received {:escalated, "bd-parked", {:deferred_resume_parked, "acct-codex", 2}, _}
      refute_received {:escalated, _, _, _}
    end

    test "is parked with an attention item after N stalled ticks, once" do
      test = self()

      pid =
        start(:enforce, fn -> board(nil, [], []) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn _ -> "acct-codex" end,
          park_after: 3,
          escalate: fn id, reason, prio ->
            send(test, {:escalated, id, reason, prio})
            :ok
          end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])
      for _ <- 1..5, do: Autopilot.tick(pid)

      assert_received {:escalated, "bd-parked", {:deferred_resume_parked, "acct-codex", 3}, _}
      refute_received {:escalated, _, _, _}
    end

    test "status lists deferred resumes with their age, and a hold is logged" do
      import ExUnit.CaptureLog
      placements = [placement("bd-same", @blocked_pool)]

      pid =
        start(:enforce, fn -> board(nil, [entry("bd-same", :next)], placements) end,
          slot_room: fn _task_id, _kind -> false end,
          resume_account: fn _ -> "acct-codex" end
        )

      :ok = Autopilot.defer_resume(pid, "bd-parked", :resume, [])

      log = capture_log(fn -> Autopilot.tick(pid) end)
      assert log =~ "holding Ready behind deferred resume bd-parked"
      assert log =~ "acct-codex"

      assert [%{task_id: "bd-parked", age_ms: age, wait: :slot}] =
               Autopilot.status(pid).deferred_resume_details

      assert is_integer(age) and age >= 0
    end
  end
end
