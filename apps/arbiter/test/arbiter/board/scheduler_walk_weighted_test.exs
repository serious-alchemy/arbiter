defmodule Arbiter.Board.SchedulerWalkWeightedTest do
  @moduledoc """
  Weighted seats in the walk (DC11, bd-8lsfey; design
  `provider-dynamic-concurrency.md` §3.4 phase 2): a pool may carry the
  weighted `load` of its seats, and a candidate the `weight` of the seat it
  would take. The walk then plans what `Arbiter.Accounts.SeatCheck` will admit:
  `load + weight ≤ budget`, with the ceiling `cap` still counting seats (I3).
  Without them it is the seat count, as before.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Scheduler

  @claude {"acct-claude", "claude"}

  defp card(id), do: %{id: id, scope: MapSet.new(), blocked_by: [], conflicts_with: []}

  @open_node %{"local" => %{cap: 20, used: 0, label: "local"}}
  @full_node %{"local" => %{cap: 1, used: 1, label: "local"}}

  defp plan(pool, weight, ids \\ ["bd-1", "bd-2", "bd-3", "bd-4"], nodes \\ @open_node) do
    candidate = Map.merge(%{pool: @claude, nodes: ["local"]}, weight)

    Scheduler.plan(%{
      ready: Enum.map(ids, &card/1),
      running: [],
      conflict_claims: %{},
      paused: false,
      walk: %{
        pools: %{@claude => Map.merge(%{label: "claude:default"}, pool)},
        nodes: nodes,
        candidates: fn _card -> [candidate] end
      }
    })
  end

  defp placed(plan), do: Enum.map(plan.placements, & &1.id)

  test "no load and no weight: the seat count decides, as before" do
    assert placed(plan(%{budget: 3, seats: 1}, %{})) == ["bd-1", "bd-2"]
  end

  test "a heavy card does not fit beside heavy seats the count would allow" do
    pool = %{budget: 5, seats: 2, load: 4.0}

    assert placed(plan(pool, %{weight: 2.0})) == []
    assert placed(plan(pool, %{weight: 1.0})) == ["bd-1"]
  end

  test "light cards fill the budget by weight, and each placement adds its weight" do
    pool = %{budget: 5, seats: 2, load: 4.0}

    assert placed(plan(pool, %{weight: 0.5})) == ["bd-1", "bd-2"]
  end

  test "light seats leave room past the seat count" do
    pool = %{budget: 2, seats: 2, load: 1.0}

    assert placed(plan(pool, %{weight: 0.5})) == ["bd-1", "bd-2"]
    # The unweighted view of the same pool is full.
    assert placed(plan(%{budget: 2, seats: 2}, %{})) == []
  end

  test "I3: the ceiling counts seats however light they weigh" do
    pool = %{budget: 4, seats: 2, load: 1.0, cap: 3}

    assert placed(plan(pool, %{weight: 0.5})) == ["bd-1"]
  end

  test "I3: a link's share counts seats too, however light they weigh" do
    pool = %{budget: 4, seats: 1, load: 0.5}

    assert placed(plan(pool, %{weight: 0.5, share: 2})) == ["bd-1"]
  end

  test "an empty pool takes one card heavier than the budget, no more" do
    pool = %{budget: 2, seats: 0, load: 0.0}

    assert placed(plan(pool, %{weight: 3.0})) == ["bd-1"]
    assert placed(plan(%{budget: 0, seats: 0, load: 0.0}, %{weight: 3.0})) == []
  end

  test "agreement with SeatCheck: the share limits seats, the budget limits weight" do
    # Budget 10, share 3, two weight-2 seats: 2 < 3 seats and 6 ≤ 10. The
    # candidate carries the share beside the pool's unshared budget.
    pool = %{budget: 10, seats: 2, load: 4.0}

    assert placed(plan(pool, %{weight: 2.0, share: 3})) == ["bd-1"]
    # The share still counts seats: a third seat fills it.
    assert placed(plan(%{pool | seats: 3, load: 6.0}, %{weight: 2.0, share: 3})) == []
  end

  describe "the pool-full diagnosis" do
    test "a pool with room only for less than the lightest weight is full" do
      # Load 1.5 of 2: `load < budget`, yet no seat weighs under 1.
      pool = %{budget: 2, seats: 1, load: 1.5, min_weight: 1.0, label: "claude:default"}
      plan = plan(pool, %{weight: 1.0}, ["bd-1"], @full_node)

      assert Enum.find(plan.entries, &(&1.id == "bd-1")).wait_cause == {:capacity, :provider}
    end

    test "a pool a lighter seat still fits is not blamed" do
      pool = %{budget: 2, seats: 1, load: 1.5, min_weight: 0.5, label: "claude:default"}
      plan = plan(pool, %{weight: 0.5}, ["bd-1"], @full_node)

      assert Enum.find(plan.entries, &(&1.id == "bd-1")).wait_cause == {:capacity, :node}
    end
  end

  test "a card the pool cannot take reads as waiting for the pool" do
    plan = plan(%{budget: 3, seats: 2, load: 3.0, label: "claude:default"}, %{weight: 1.0})

    assert [] == placed(plan)
    assert Enum.find(plan.entries, &(&1.id == "bd-1")).wait_cause == {:capacity, :provider}
  end
end
