defmodule Arbiter.Board.SchedulerWalkPropertyTest do
  @moduledoc """
  Properties of the scheduler walk (DC6, `docs/design/provider-dynamic-concurrency.md`
  §4, §11):

    * **I4** — with one pool, one machine, no repo or fair-share config and the
      budget equal to today's cap, the walk's first placement is today's
      `promote`, whatever the queue, its holds and its claims.
    * the walk never places more than a layer has room for, and accounts for
      every Ready card exactly once.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Board.Scheduler

  @files ~w(lib/a.ex lib/b.ex lib/c.ex lib/d.ex)
  @pool {"acct", "claude"}

  # ---- generators ------------------------------------------------------------

  defp scope_gen, do: list_of(member_of(@files), max_length: 2)

  defp card_gen(id, peers) do
    gen all(
          priority <- one_of([constant(nil), integer(0..4)]),
          rank <- one_of([constant(nil), integer(0..5)]),
          age <- integer(0..1_000),
          scope <- scope_gen(),
          blocked? <- frequency([{5, constant(false)}, {1, constant(true)}]),
          conflicts <- list_of(member_of(peers), max_length: 2),
          state <- frequency([{8, constant(:queued)}, {1, constant(:active)}])
        ) do
      %{
        id: id,
        priority: priority,
        rank: rank,
        created_at: DateTime.add(~U[2026-10-01 00:00:00Z], age, :second),
        scope: scope,
        blocked_by: if(blocked?, do: ["bd-blocker"], else: []),
        conflicts_with: Enum.uniq(conflicts) -- [id],
        state: state
      }
    end
  end

  defp board_gen do
    gen all(
          n <- integer(0..7),
          m <- integer(0..3),
          ids = Enum.map(1..n//1, &"bd-#{&1}"),
          running_ids = Enum.map(1..m//1, &"run-#{&1}"),
          cards <- fixed_list(Enum.map(ids, &card_gen(&1, ids ++ running_ids))),
          running_scopes <- fixed_list(Enum.map(running_ids, fn _ -> scope_gen() end)),
          claimed <- list_of(member_of(["run-1", "run-2", "run-3"]), max_length: 2),
          guarded <- list_of(member_of(["bd-1", "bd-2", "bd-3"]), max_length: 2),
          refused <- list_of(member_of(["bd-1", "bd-2", "bd-4"]), max_length: 2),
          paused <- frequency([{6, constant(false)}, {1, constant(true)}])
        ) do
      %{
        ready: Enum.shuffle(cards),
        running:
          Enum.zip_with(running_ids, running_scopes, &%{task_id: &1, scope: MapSet.new(&2)}),
        conflict_claims: Map.new(claimed, &{&1, "running"}),
        card_guardrail: Map.new(guarded, &{&1, {:hold, "no eligible model"}}),
        dispatch_holds:
          Map.new(refused, &{&1, {:hold, "dispatch refused (account at capacity)"}}),
        paused: paused
      }
    end
  end

  defp legacy(board, slots_free) do
    Scheduler.plan(%{
      ready: board.ready,
      running: board.running,
      conflict_claims: board.conflict_claims,
      slots_free: slots_free,
      quota: :ok,
      card_guardrail: board.card_guardrail,
      # The board hands the 15 s retry window to the head-of-line plan as part of
      # the constraint map (`Snapshot.derive/1`).
      card_constraint: board.dispatch_holds,
      paused: board.paused
    })
  end

  defp walk(board, walk) do
    board
    |> Map.take([:ready, :running, :conflict_claims, :card_guardrail, :dispatch_holds, :paused])
    |> Map.put(:walk, walk)
    |> Scheduler.plan()
  end

  # ---- I4 ----------------------------------------------------------------------

  property "I4: one pool, one machine, budget = cap — the first placement is today's promote" do
    check all(
            board <- board_gen(),
            cap <- integer(0..4),
            seats <- integer(0..5),
            machine_cap <- integer(0..8),
            max_runs: 400
          ) do
      # Today's cap is the budget; the machine is either generous (the pool
      # binds) or the same number (both bind together).
      machine_cap = max(machine_cap, cap)
      slots_free = max(cap - seats, 0)

      walk =
        walk(board, %{
          pools: %{@pool => %{budget: cap, seats: seats}},
          nodes: %{"local" => %{cap: machine_cap + seats, used: seats}},
          candidates: fn _card -> [%{pool: @pool, nodes: ["local"]}] end
        })

      assert walk.promote == legacy(board, slots_free).promote
    end
  end

  # ---- capacity safety ---------------------------------------------------------

  @pool_ids [{"a", "claude"}, {"b", "codex"}, {"c", "agy:gemini"}]
  @node_ids ["local", "node-a", "node-b"]

  # Each known id is present or absent, so a candidate can name an unknown pool
  # or machine too.
  defp some_of(ids, value_gen) do
    gen all(values <- fixed_list(Enum.map(ids, fn _ -> one_of([constant(nil), value_gen]) end))) do
      ids |> Enum.zip(values) |> Enum.reject(&is_nil(elem(&1, 1))) |> Map.new()
    end
  end

  defp capacity_gen do
    gen all(
          pools <- some_of(@pool_ids, fixed_map(%{budget: integer(0..3), seats: integer(0..3)})),
          nodes <- some_of(@node_ids, fixed_map(%{cap: integer(0..3), used: integer(0..3)})),
          picks <-
            list_of(
              fixed_map(%{
                pools: list_of(member_of(@pool_ids), max_length: 3),
                nodes: list_of(member_of(@node_ids), min_length: 1, max_length: 3)
              }),
              length: 8
            )
        ) do
      candidates = fn card ->
        index = card.id |> String.trim_leading("bd-") |> String.to_integer()
        pick = Enum.at(picks, rem(index, 8))
        Enum.map(Enum.uniq(pick.pools), &%{pool: &1, nodes: Enum.uniq(pick.nodes)})
      end

      %{pools: pools, nodes: nodes, candidates: candidates}
    end
  end

  property "no pool or machine is ever given more placements than it has room for" do
    check all(board <- board_gen(), capacity <- capacity_gen(), max_runs: 300) do
      plan = walk(board, capacity)

      for {id, pool} <- capacity.pools do
        placed = Enum.count(plan.placements, &(&1.pool == id))
        assert placed <= max(pool.budget - pool.seats, 0)
      end

      for {id, node} <- capacity.nodes do
        placed = Enum.count(plan.placements, &(&1.node == id))
        assert placed <= max(node.cap - node.used, 0)
      end

      # Placed only on pools and machines the walk was told about.
      assert Enum.all?(plan.placements, &Map.has_key?(capacity.pools, &1.pool))
      assert Enum.all?(plan.placements, &Map.has_key?(capacity.nodes, &1.node))
    end
  end

  property "every Ready card gets one entry; the placed ones are exactly the placements" do
    check all(board <- board_gen(), capacity <- capacity_gen(), max_runs: 300) do
      plan = walk(board, capacity)

      assert Enum.sort(Enum.map(plan.entries, & &1.id)) ==
               Enum.sort(Enum.map(board.ready, & &1.id))

      placed = for %{state: state, id: id} <- plan.entries, state in [:next, :starting], do: id
      assert placed == Enum.map(plan.placements, & &1.id)
      assert plan.promote == List.first(placed)

      for entry <- plan.entries do
        if entry.state in [:next, :starting],
          do: assert(entry.wait_cause == nil and is_map(entry.pair)),
          else: assert(entry.wait_cause != nil and entry.pair == nil)
      end

      # Nothing placed in one pass conflicts with, or overlaps, another placement.
      for %{id: a} <- plan.placements, %{id: b} <- plan.placements, a < b do
        card_a = Enum.find(board.ready, &(&1.id == a))
        card_b = Enum.find(board.ready, &(&1.id == b))
        refute b in card_a.conflicts_with or a in card_b.conflicts_with
        assert MapSet.disjoint?(MapSet.new(card_a.scope), MapSet.new(card_b.scope))
      end
    end
  end
end
