defmodule Arbiter.Board.SchedulerWalkFairShareTest do
  @moduledoc """
  Workspace fair share in the scheduler walk (DC10,
  `docs/design/provider-dynamic-concurrency.md` §5.3): on a pool whose account
  is `budget_split: fair`, a card from a workspace at its weighted share is
  skipped for that pool when another workspace is under its share and has an
  eligible Ready card for the pool in the same effective band. P0 is exempt, an
  idle share is borrowed, and the card may still land on another pool.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Scheduler

  @pool {"acct-claude", "claude"}
  @other {"acct-codex", "codex"}

  defp card(id, ws, opts \\ []) do
    %{
      id: id,
      workspace_id: ws,
      priority: Keyword.get(opts, :priority, 1),
      effective_priority: Keyword.get(opts, :effective_priority),
      scope: MapSet.new(),
      blocked_by: [],
      conflicts_with: []
    }
  end

  defp fair(seats, weights \\ %{}) do
    %{seats: seats, weights: weights, labels: %{"a" => "ws-a", "b" => "ws-b", "c" => "ws-c"}}
  end

  # Every card can run on `pools`, in that order, on the local machine.
  defp everywhere(pools), do: fn _card -> Enum.map(pools, &%{pool: &1, nodes: ["local"]}) end

  defp plan(ready, opts) do
    pool = %{
      budget: Keyword.get(opts, :budget, 4),
      seats: Keyword.get(opts, :seats, 0),
      label: "claude:default",
      fair: Keyword.get(opts, :fair)
    }

    pool = if pool.fair == nil, do: Map.delete(pool, :fair), else: pool

    Scheduler.plan(%{
      ready: ready,
      running: [],
      conflict_claims: %{},
      paused: false,
      walk: %{
        pools: Map.merge(%{@pool => pool}, Keyword.get(opts, :extra_pools, %{})),
        nodes: %{"local" => %{cap: 20, used: 0, label: "local"}},
        candidates: Keyword.get(opts, :candidates, everywhere([@pool]))
      }
    })
  end

  defp entry(plan, id), do: Enum.find(plan.entries, &(&1.id == id))

  test "a workspace at its share yields to another under its share in the same band" do
    # budget 4, equal weights: a share of 2 each. a holds 2, b holds 0.
    plan =
      plan([card("a1", "a"), card("a2", "a"), card("b1", "b")],
        seats: 2,
        fair: fair(%{"a" => 2})
      )

    assert %{state: :blocked, wait_cause: {:capacity, :provider}, reason: reason} =
             entry(plan, "a1")

    assert reason =~ "fair share"
    assert reason =~ "ws-a"
    assert reason =~ "ws-b"
    assert %{state: :blocked} = entry(plan, "a2")
    assert plan.promote == "b1"
  end

  test "with no other workspace waiting the share is borrowed" do
    plan = plan([card("a1", "a"), card("a2", "a")], seats: 2, fair: fair(%{"a" => 2}))

    assert plan.promote == "a1"
    assert Enum.map(plan.placements, & &1.id) == ["a1", "a2"]
  end

  test "an account on queue (no fair config) is decided by the order alone" do
    plan = plan([card("a1", "a"), card("b1", "b")], seats: 2)

    assert plan.promote == "a1"
  end

  test "a workspace under its share is placed even with another workspace waiting" do
    plan = plan([card("a1", "a"), card("b1", "b")], seats: 1, fair: fair(%{"a" => 1}))

    assert plan.promote == "a1"
  end

  test "an own-P0 card is never skipped for fair share" do
    plan =
      plan([card("a1", "a", priority: 0), card("b1", "b", priority: 0)],
        seats: 2,
        fair: fair(%{"a" => 2})
      )

    assert plan.promote == "a1"
  end

  test "another workspace's card in a lower band does not make the card yield" do
    plan =
      plan([card("a1", "a", priority: 1), card("b1", "b", priority: 3)],
        seats: 2,
        fair: fair(%{"a" => 2})
      )

    assert plan.promote == "a1"
  end

  test "the band is the effective priority, not the card's own" do
    # b1 is P3 on its own but sits under a P1 epic floor: the same band as a1.
    plan =
      plan(
        [card("a1", "a", priority: 1), card("b1", "b", priority: 3, effective_priority: 1)],
        seats: 2,
        fair: fair(%{"a" => 2})
      )

    assert plan.promote == "b1"
  end

  test "weights set the entitlement" do
    ready = [card("a1", "a"), card("b1", "b")]

    # a:b = 3:1 over 4 seats is 3 and 1. a at 2 is under its share: placed.
    under = plan(ready, seats: 2, fair: fair(%{"a" => 2}, %{"a" => 3, "b" => 1}))
    assert under.promote == "a1"

    # a at 3 has its share and b has none of its 1: a yields.
    at = plan(ready, seats: 3, fair: fair(%{"a" => 3}, %{"a" => 3, "b" => 1}))
    assert at.promote == "b1"
  end

  test "a workspace at its share does not yield to one that already holds its share" do
    plan =
      plan([card("a1", "a"), card("b1", "b")],
        seats: 4,
        budget: 5,
        fair: fair(%{"a" => 2, "b" => 2}, %{"a" => 1, "b" => 1})
      )

    # shares are 2.5 each: b at 2 is under, so a (at 2, under 2.5) is placed
    assert plan.promote == "a1"
  end

  test "a workspace with no demand on the pool does not dilute the shares" do
    # c holds nothing and has no card: it is not a demander, so the shares are
    # budget/2, not budget/3.
    plan =
      plan([card("a1", "a"), card("b1", "b")],
        seats: 2,
        fair: fair(%{"a" => 2}, %{"a" => 1, "b" => 1, "c" => 1})
      )

    assert plan.promote == "b1"
  end

  test "a card that cannot use the pool is not demand on it" do
    candidates = fn
      %{id: "b1"} -> [%{pool: @other, nodes: ["local"]}]
      _card -> [%{pool: @pool, nodes: ["local"]}]
    end

    plan =
      plan([card("a1", "a"), card("b1", "b")],
        seats: 2,
        fair: fair(%{"a" => 2}),
        candidates: candidates,
        extra_pools: %{@other => %{budget: 2, seats: 0, label: "codex:default"}}
      )

    assert plan.promote == "a1"
  end

  test "a skipped card may still be placed on another pool" do
    candidates = fn _card ->
      [%{pool: @pool, nodes: ["local"]}, %{pool: @other, nodes: ["local"]}]
    end

    plan =
      plan([card("a1", "a"), card("b1", "b")],
        seats: 2,
        fair: fair(%{"a" => 2}),
        candidates: candidates,
        extra_pools: %{@other => %{budget: 2, seats: 0, label: "codex:default"}}
      )

    assert [%{id: "a1", pool: @other}, %{id: "b1", pool: @pool}] = plan.placements
  end

  test "placements made in the walk count toward a workspace's seats" do
    # a holds 1 of its 2; a1 takes the second, so a2 is over share and yields to b1.
    plan =
      plan([card("a1", "a"), card("a2", "a"), card("b1", "b")],
        seats: 1,
        fair: fair(%{"a" => 1})
      )

    assert Enum.map(plan.placements, & &1.id) == ["a1", "b1"]
    assert %{state: :blocked} = entry(plan, "a2")
  end

  test "a workspace that holds seats but has no waiting card is still a demander" do
    # b holds 1 seat and nothing queued: shares are 2 each; a holds 2 with no
    # one under share waiting, so a borrows.
    plan = plan([card("a1", "a")], seats: 3, fair: fair(%{"a" => 2, "b" => 1}))

    assert plan.promote == "a1"
  end

  test "an unlimited pool is never split" do
    plan =
      plan([card("a1", "a"), card("b1", "b")],
        budget: :unlimited,
        seats: 5,
        fair: fair(%{"a" => 5})
      )

    assert plan.promote == "a1"
  end
end
