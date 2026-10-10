defmodule Arbiter.Board.SchedulerWalkTest do
  @moduledoc """
  The scheduler walk (DC6, `docs/design/provider-dynamic-concurrency.md` §4):
  `Scheduler.plan/1` handed a `:walk` builds capacity sets, places each card on
  a (pool, machine) pair, skips a card that fits nowhere instead of stopping
  the queue, and places as many cards as there is capacity for. Every entry
  carries a `wait_cause`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Scheduler

  @claude {"acct-claude", "claude"}
  @gemini {"acct-agy", "antigravity:gemini_models"}
  @gpt {"acct-agy", "antigravity:claude_and_gpt_models"}

  defp card(id, opts \\ []) do
    %{
      id: id,
      scope: MapSet.new(Keyword.get(opts, :files, [])),
      blocked_by: Keyword.get(opts, :blocked_by, []),
      conflicts_with: Keyword.get(opts, :conflicts_with, [])
    }
  end

  defp pool(budget, seats, opts \\ []) do
    Map.merge(%{budget: budget, seats: seats}, Map.new(opts))
  end

  defp machine(cap, used, opts \\ []) do
    Map.merge(%{cap: cap, used: used}, Map.new(opts))
  end

  # Every card can run on `pools`, in that order, on the local machine.
  defp everywhere(pools), do: fn _card -> Enum.map(pools, &%{pool: &1, nodes: ["local"]}) end

  defp walk(overrides) do
    overrides = Map.new(overrides)

    walk =
      Map.merge(
        %{
          pools: %{@claude => pool(3, 0, label: "claude:default")},
          nodes: %{"local" => machine(6, 0, label: "local")},
          candidates: everywhere([@claude])
        },
        Map.get(overrides, :walk, %{})
      )

    Scheduler.plan(
      overrides
      |> Map.delete(:walk)
      |> then(&Map.merge(%{ready: [], running: [], conflict_claims: %{}, paused: false}, &1))
      |> Map.put(:walk, walk)
    )
  end

  defp entry(plan, id), do: Enum.find(plan.entries, &(&1.id == id))

  describe "placement" do
    test "places the head on its first open pool and the machine, as the next dispatch" do
      plan = walk(ready: [card("bd-1"), card("bd-2")])

      assert plan.promote == "bd-1"

      assert %{state: :next, wait_cause: nil, pair: %{pool: @claude, node: "local"}} =
               entry(plan, "bd-1")
    end

    test "places as many cards as the capacity sets hold; the rest read as starting" do
      plan = walk(ready: [card("bd-1"), card("bd-2"), card("bd-3"), card("bd-4")])

      assert Enum.map(plan.placements, & &1.id) == ["bd-1", "bd-2", "bd-3"]
      assert %{state: :next} = entry(plan, "bd-1")
      assert %{state: :starting, wait_cause: nil, reason: reason} = entry(plan, "bd-2")
      assert reason =~ "claude:default"
      assert reason =~ "local"

      # The pool is full after three: the fourth waits its turn, behind them.
      assert %{state: :queued, wait_cause: :queued, reason: "3 ahead in queue"} =
               entry(plan, "bd-4")
    end

    test "a full machine bounds the placements as a full pool does" do
      plan =
        walk(
          ready: [card("bd-1"), card("bd-2"), card("bd-3")],
          walk: %{nodes: %{"local" => machine(2, 1, label: "local")}}
        )

      assert Enum.map(plan.placements, & &1.id) == ["bd-1"]
      assert %{state: :queued, wait_cause: :queued} = entry(plan, "bd-2")
    end

    test "seats already taken count against the budget" do
      plan =
        walk(
          ready: [card("bd-1"), card("bd-2")],
          walk: %{pools: %{@claude => pool(3, 2, label: "claude:default")}}
        )

      assert Enum.map(plan.placements, & &1.id) == ["bd-1"]
    end

    test "an unlimited pool is bounded by the machine alone" do
      plan =
        walk(
          ready: Enum.map(1..4, &card("bd-#{&1}")),
          walk: %{
            pools: %{@claude => pool(:unlimited, 9)},
            nodes: %{"local" => machine(3, 0)}
          }
        )

      assert length(plan.placements) == 3
    end
  end

  describe "capacity sets first (§4.1)" do
    test "with no open pool the walk stops at once and evaluates no card's candidates" do
      test = self()

      candidates = fn card ->
        send(test, {:evaluated, card.id})
        [%{pool: @claude, nodes: ["local"]}]
      end

      plan =
        walk(
          ready: [card("bd-1"), card("bd-2")],
          walk: %{
            pools: %{@claude => pool(3, 3, label: "claude:default")},
            candidates: candidates
          }
        )

      assert plan.promote == nil
      assert plan.placements == []

      for id <- ["bd-1", "bd-2"] do
        assert %{state: :blocked, wait_cause: {:capacity, :provider}, reason: reason} =
                 entry(plan, id)

        assert reason =~ "waiting for capacity"
        assert reason =~ "claude:default 3 of 3"
      end

      refute_received {:evaluated, _}
    end

    test "with no open machine every card waits on the node layer" do
      plan =
        walk(
          ready: [card("bd-1")],
          walk: %{nodes: %{"local" => machine(6, 6, label: "local")}}
        )

      assert %{state: :blocked, wait_cause: {:capacity, :node}, reason: reason} =
               entry(plan, "bd-1")

      assert reason =~ "local 6 of 6"
    end

    test "a card's own hold still outranks an empty capacity set" do
      plan =
        walk(
          ready: [card("bd-1", blocked_by: ["bd-9"])],
          walk: %{pools: %{@claude => pool(1, 1)}}
        )

      assert %{state: :blocked, wait_cause: :own_hold, hold: {:blocked_by, ["bd-9"]}} =
               entry(plan, "bd-1")
    end
  end

  describe "skip, not stop (§4.2)" do
    test "a card whose pools are all full is skipped with its own reason; the next card goes" do
      candidates = fn
        %{id: "bd-a"} -> [%{pool: @claude, nodes: ["local"]}, %{pool: @gemini, nodes: ["local"]}]
        %{id: "bd-b"} -> [%{pool: @claude, nodes: ["local"]}, %{pool: @gpt, nodes: ["local"]}]
      end

      plan =
        walk(
          ready: [card("bd-a"), card("bd-b")],
          walk: %{
            pools: %{
              @claude => pool(3, 3, label: "claude:default"),
              @gemini =>
                pool(0, 0, label: "antigravity:default gemini", reason: "weekly over its line"),
              @gpt => pool(4, 0, label: "antigravity:default claude-gpt")
            },
            candidates: candidates
          }
        )

      assert %{state: :blocked, wait_cause: {:capacity, :provider}, reason: reason} =
               entry(plan, "bd-a")

      assert reason =~ "waiting for claude:default: 3 of 3 seats"
      assert reason =~ "antigravity:default gemini: 0 of 0 seats (weekly over its line)"

      assert plan.promote == "bd-b"
      assert %{state: :next, pair: %{pool: @gpt, node: "local"}} = entry(plan, "bd-b")
    end

    test "a skipped card is first in line again: it keeps its place ahead of later cards" do
      candidates = fn
        %{id: "bd-p0"} -> [%{pool: @gemini, nodes: ["local"]}]
        _ -> [%{pool: @claude, nodes: ["local"]}]
      end

      plan =
        walk(
          ready: [card("bd-p0"), card("bd-1"), card("bd-2")],
          walk: %{
            pools: %{@claude => pool(1, 0), @gemini => pool(2, 2)},
            candidates: candidates
          }
        )

      assert %{wait_cause: {:capacity, :provider}} = entry(plan, "bd-p0")
      assert Enum.map(plan.placements, & &1.id) == ["bd-1"]
      # bd-2 counts the skipped P0 ahead of it as well as the placed card.
      assert %{state: :queued, reason: "2 ahead in queue"} = entry(plan, "bd-2")
    end

    test "the first open pool in the card's own order wins" do
      plan =
        walk(
          ready: [card("bd-1")],
          walk: %{
            pools: %{@claude => pool(3, 0), @gpt => pool(3, 0)},
            candidates: everywhere([@gpt, @claude])
          }
        )

      assert %{pair: %{pool: @gpt}} = entry(plan, "bd-1")
    end

    test "a policy-workspace budget on the candidate binds tighter than the pool's" do
      candidates = fn _card -> [%{pool: @claude, nodes: ["local"], budget: 1}] end

      plan =
        walk(
          ready: [card("bd-1"), card("bd-2")],
          walk: %{pools: %{@claude => pool(3, 0)}, candidates: candidates}
        )

      assert Enum.map(plan.placements, & &1.id) == ["bd-1"]
      assert %{wait_cause: {:capacity, :provider}, reason: reason} = entry(plan, "bd-2")
      assert reason =~ "1 of 1 seats"
    end

    test "an exempt budget lets an exempt card past a pool the others see as full" do
      candidates = fn
        %{id: "bd-p0"} -> [%{pool: @claude, nodes: ["local"], budget: 3}]
        _ -> [%{pool: @claude, nodes: ["local"]}]
      end

      plan =
        walk(
          ready: [card("bd-1"), card("bd-p0")],
          walk: %{
            pools: %{@claude => pool(2, 2, exempt_budget: 3)},
            candidates: candidates
          }
        )

      assert %{wait_cause: {:capacity, :provider}} = entry(plan, "bd-1")
      assert Enum.map(plan.placements, & &1.id) == ["bd-p0"]
    end

    test "a card fitting a pool but no machine names the node layer" do
      candidates = fn
        %{id: "bd-remote"} -> [%{pool: @claude, nodes: ["node-a"]}]
        _ -> [%{pool: @claude, nodes: ["local"]}]
      end

      plan =
        walk(
          ready: [card("bd-remote"), card("bd-local")],
          walk: %{
            nodes: %{
              "local" => machine(2, 0, label: "local"),
              "node-a" => machine(1, 1, label: "node-a")
            },
            candidates: candidates
          }
        )

      assert %{state: :blocked, wait_cause: {:capacity, :node}, reason: reason} =
               entry(plan, "bd-remote")

      assert reason =~ "no machine slot"
      assert reason =~ "node-a 1 of 1"
      assert plan.promote == "bd-local"
    end

    test "a pool with no published budget is closed, not assumed open" do
      plan =
        walk(
          ready: [card("bd-1")],
          walk: %{candidates: everywhere([@gemini])}
        )

      assert %{wait_cause: {:capacity, :provider}, reason: reason} = entry(plan, "bd-1")
      assert reason =~ "no budget"
    end

    test "a card no provider can take is skipped on the provider layer" do
      plan =
        walk(
          ready: [card("bd-1"), card("bd-2")],
          walk: %{
            candidates: fn
              %{id: "bd-1"} -> {:none, "claude:default paused (maintenance)"}
              _ -> [%{pool: @claude, nodes: ["local"]}]
            end
          }
        )

      assert %{state: :blocked, wait_cause: {:capacity, :provider}, reason: reason} =
               entry(plan, "bd-1")

      assert reason =~ "claude:default paused (maintenance)"
      assert plan.promote == "bd-2"
    end

    test "a card the candidate evaluation holds on its own is an own hold" do
      plan =
        walk(
          ready: [card("bd-1"), card("bd-2")],
          walk: %{
            candidates: fn
              %{id: "bd-1"} -> {:hold, {:provider_constraint, "require codex: none attached"}}
              _ -> [%{pool: @claude, nodes: ["local"]}]
            end
          }
        )

      assert %{
               state: :blocked,
               wait_cause: :own_hold,
               hold: {:provider_constraint, _},
               reason: "held — provider constraint (require codex: none attached)"
             } = entry(plan, "bd-1")

      assert %{state: :next} = entry(plan, "bd-2")
    end

    test "a candidate map is accepted in place of a function" do
      plan =
        walk(
          ready: [card("bd-1")],
          walk: %{candidates: %{"bd-1" => [%{pool: @claude, nodes: ["local"]}]}}
        )

      assert plan.promote == "bd-1"
    end
  end

  describe "pairs: the machine for a pool (§4.2)" do
    test "a node group is ranked by load, then name; a later group is only a fallback" do
      nodes = %{
        "local" => machine(4, 0, label: "local"),
        "node-a" => machine(4, 3, label: "node-a"),
        "node-b" => machine(4, 1, label: "node-b"),
        "node-c" => machine(2, 1, label: "node-c", constrained?: true)
      }

      # prefer_remote: unconstrained nodes, then the primary, then constrained nodes.
      groups = [["node-a", "node-b"], ["local"], ["node-c"]]
      candidates = fn _card -> [%{pool: @claude, nodes: groups}] end

      plan =
        walk(
          ready: Enum.map(1..6, &card("bd-#{&1}")),
          walk: %{pools: %{@claude => pool(9, 0)}, nodes: nodes, candidates: candidates}
        )

      assert Enum.map(plan.placements, & &1.node) ==
               ["node-b", "node-b", "node-a", "node-b", "local", "local"]
    end
  end

  describe "own holds and claims across placements" do
    test "a card conflicting with a card placed this pass is held as dispatching" do
      plan =
        walk(ready: [card("bd-1"), card("bd-2", conflicts_with: ["bd-1"]), card("bd-3")])

      assert %{state: :blocked, wait_cause: :own_hold, reason: reason} = entry(plan, "bd-2")
      assert reason =~ "dispatching"
      assert Enum.map(plan.placements, & &1.id) == ["bd-1", "bd-3"]
    end

    test "a card named by a placed card's conflicts is held even if it does not name it back" do
      plan = walk(ready: [card("bd-1", conflicts_with: ["bd-2"]), card("bd-2"), card("bd-3")])

      assert %{wait_cause: :own_hold, hold: {:conflicts_with, "bd-1"}} = entry(plan, "bd-2")
      assert Enum.map(plan.placements, & &1.id) == ["bd-1", "bd-3"]
    end

    test "a card overlapping the files of a card placed this pass is held" do
      plan =
        walk(
          ready: [
            card("bd-1", files: ["lib/a.ex"]),
            card("bd-2", files: ["lib/a.ex"]),
            card("bd-3", files: ["lib/b.ex"])
          ]
        )

      assert %{wait_cause: :own_hold, hold: {:file_overlap, ["lib/a.ex"], "bd-1"}} =
               entry(plan, "bd-2")

      assert Enum.map(plan.placements, & &1.id) == ["bd-1", "bd-3"]
    end

    test "the 15 s retry window is an own hold" do
      plan =
        walk(
          ready: [card("bd-1"), card("bd-2")],
          dispatch_holds: %{"bd-1" => {:hold, "claude:default at capacity (cap 3)"}}
        )

      assert %{state: :blocked, wait_cause: :own_hold} = entry(plan, "bd-1")
      assert plan.promote == "bd-2"
    end

    test "a guardrail hold is an own hold" do
      plan =
        walk(
          ready: [card("bd-1"), card("bd-2")],
          card_guardrail: %{"bd-1" => {:hold, "no eligible model"}}
        )

      assert %{wait_cause: :own_hold, reason: "held — guardrail (no eligible model)"} =
               entry(plan, "bd-1")

      assert plan.promote == "bd-2"
    end

    test "paused places nothing and every free card says so" do
      plan = walk(ready: [card("bd-1"), card("bd-2", blocked_by: ["bd-9"])], paused: true)

      assert plan.promote == nil
      assert plan.placements == []

      assert %{state: :blocked, wait_cause: :paused, reason: "scheduler paused"} =
               entry(plan, "bd-1")

      assert %{wait_cause: :own_hold} = entry(plan, "bd-2")
    end

    test "the legacy-only inputs do not hold the walk: quota, card quota, constraint and slots" do
      plan =
        walk(
          ready: [card("bd-1")],
          quota: {:hold, "blocked — quota exhausted"},
          card_quota: %{"bd-1" => {:hold, "5h ahead of pace"}},
          card_constraint: %{"bd-1" => {:hold, "claude:default at capacity"}},
          slots_free: 0
        )

      assert plan.promote == "bd-1"
    end
  end

  describe "the repo layer" do
    test "a full repo skips the card with the repo's reason; another repo's card goes" do
      candidates = fn
        %{id: "bd-vstim"} -> [%{pool: @claude, nodes: ["local"], repo: "default/vstim"}]
        _ -> [%{pool: @claude, nodes: ["local"], repo: "default/arbiter"}]
      end

      plan =
        walk(
          ready: [card("bd-vstim"), card("bd-arb")],
          walk: %{
            repos: %{"default/vstim" => %{cap: 2, used: 2, label: "vstim"}},
            candidates: candidates
          }
        )

      assert %{wait_cause: {:capacity, :repo}, reason: "repo vstim: 2 of 2 implementer runs"} =
               entry(plan, "bd-vstim")

      assert plan.promote == "bd-arb"
    end
  end

  describe "the queue order" do
    test "the walk keeps the ES3 order" do
      plan =
        walk(
          ready: [
            Map.merge(card("bd-low"), %{priority: 3}),
            Map.merge(card("bd-high"), %{priority: 1})
          ]
        )

      assert Enum.map(plan.entries, & &1.id) == ["bd-high", "bd-low"]
      assert plan.promote == "bd-high"
    end
  end

  test "without :walk the plan is today's: no placements key, no wait_cause" do
    plan = Scheduler.plan(%{ready: [card("bd-1")], slots_free: 1, quota: :ok})

    assert plan.promote == "bd-1"
    refute Map.has_key?(plan, :placements)
    refute Enum.any?(plan.entries, &Map.has_key?(&1, :wait_cause))
  end
end
