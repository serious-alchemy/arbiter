defmodule Arbiter.Board.SnapshotWalkTest do
  @moduledoc """
  `Snapshot.derive/1` handed a `:walk` (DC6, provider-dynamic-concurrency §4,
  §10.1): the board carries the scheduler walk *beside* today's plan, and
  nothing today's plan decides moves — I1 (no `:walk`, no walk) and I2 (the
  same promotion and the same holds, whatever the walk says).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Board.Snapshot

  @now ~U[2026-10-10 12:00:00Z]
  @claude {"acct-claude", "claude"}
  @gpt {"acct-agy", "antigravity:claude_and_gpt_models"}

  defp issue(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      attrs
    )
  end

  defp input(overrides) do
    Map.merge(
      %{
        issues: [],
        workers: [],
        blocked_by: %{},
        changed_files: %{},
        now: @now,
        slots_total: 4,
        quota: :ok,
        paused: false
      },
      Map.new(overrides)
    )
  end

  defp walk(candidates, pools \\ nil) do
    %{
      pools: pools || %{@claude => %{budget: 3, seats: 3}, @gpt => %{budget: 2, seats: 0}},
      nodes: %{"local" => %{cap: 6, used: 3}},
      candidates: candidates
    }
  end

  test "without :walk the board carries no walk (I1)" do
    board = Snapshot.derive(input(issues: [issue("bd-1")]))
    refute Map.has_key?(board, :walk)
    assert board.promote == "bd-1"
  end

  test "with :walk the walk rides beside today's plan, which is unchanged" do
    issues = [issue("bd-a", %{priority: 1}), issue("bd-b", %{priority: 2})]

    # bd-a can only use the full claude pool; bd-b can use agy's free one.
    candidates = %{
      "bd-a" => [%{pool: @claude, nodes: ["local"]}],
      "bd-b" => [%{pool: @claude, nodes: ["local"]}, %{pool: @gpt, nodes: ["local"]}]
    }

    today = Snapshot.derive(input(issues: issues))
    shadowed = Snapshot.derive(input(issues: issues, walk: walk(candidates)))

    assert Map.delete(shadowed, :walk) == today
    assert today.promote == "bd-a"

    assert %{promote: "bd-b", placements: [%{id: "bd-b", pool: @gpt, node: "local"}]} =
             shadowed.walk

    assert %{wait_cause: {:capacity, :provider}} =
             Enum.find(shadowed.walk.entries, &(&1.id == "bd-a"))

    # The capacity sets the walk ran against ride with it, for the record.
    assert shadowed.walk.pools == walk(candidates).pools
    assert shadowed.walk.nodes == walk(candidates).nodes
  end

  test "the walk holds on the 15 s retry window, not on today's capacity-folded constraint" do
    issues = [issue("bd-a", %{priority: 1}), issue("bd-b", %{priority: 2})]
    everywhere = fn _card -> [%{pool: @gpt, nodes: ["local"]}] end

    shadowed =
      Snapshot.derive(
        input(
          issues: issues,
          # bd-814vuy's per-workspace pool hold: capacity, which the walk replaces.
          card_constraint: %{"bd-a" => {:hold, "claude:default at capacity"}},
          # bd-814vuy's 15 s hold after a refused dispatch: the card's own.
          dispatch_holds: %{"bd-b" => {:hold, "dispatch refused (account at capacity)"}},
          walk: walk(everywhere)
        )
      )

    assert shadowed.promote == nil
    assert shadowed.walk.promote == "bd-a"

    assert %{wait_cause: :own_hold} =
             Enum.find(shadowed.walk.entries, &(&1.id == "bd-b"))
  end

  @tag capture_log: true
  test "a walk that cannot be planned is left out; today's board is never lost to it" do
    issues = [issue("bd-a")]
    today = Snapshot.derive(input(issues: issues))

    broken = [
      # A malformed pool (no budget at all).
      walk(fn _ -> [%{pool: @claude, nodes: ["local"]}] end, %{@claude => %{seats: 0}}),
      # A candidates function that raises.
      walk(fn _ -> raise "boom" end),
      # Something that is not a walk at all.
      %{pools: :nope, nodes: :nope, candidates: :nope}
    ]

    for walk <- broken do
      board = Snapshot.derive(input(issues: issues, walk: walk))
      refute Map.has_key?(board, :walk)
      assert board == today
    end
  end

  # ---- I2 at the board ----------------------------------------------------------

  defp issue_gen(id) do
    gen all(
          state <- member_of([:queued, :queued, :queued, :active, :merging, :backlog]),
          priority <- integer(0..4),
          ws <- member_of(["ws-1", "ws-2"])
        ) do
      issue(id, %{state: state, priority: priority, workspace_id: ws})
    end
  end

  defp holds_gen(ids, phrase) do
    gen all(held <- list_of(member_of(ids), max_length: 3)) do
      Map.new(held, &{&1, {:hold, phrase}})
    end
  end

  defp capacity_gen(ids) do
    gen all(
          claude <- fixed_map(%{budget: integer(0..3), seats: integer(0..3)}),
          gpt <- fixed_map(%{budget: integer(0..3), seats: integer(0..3)}),
          local <- fixed_map(%{cap: integer(0..4), used: integer(0..4)}),
          picks <-
            fixed_list(
              Enum.map(ids, fn _ -> member_of([[@claude], [@gpt], [@claude, @gpt], []]) end)
            )
        ) do
      candidates =
        ids
        |> Enum.zip(picks)
        |> Map.new(fn {id, pools} -> {id, Enum.map(pools, &%{pool: &1, nodes: ["local"]})} end)

      %{
        pools: %{@claude => claude, @gpt => gpt},
        nodes: %{"local" => local},
        candidates: candidates
      }
    end
  end

  property "I2: whatever the walk says, today's promotion and every hold are unchanged" do
    ids = Enum.map(1..6, &"bd-#{&1}")

    check all(
            issues <- fixed_list(Enum.map(ids, &issue_gen/1)),
            slots_total <- integer(0..5),
            quota <- member_of([:ok, :ok, {:hold, "blocked — quota exhausted"}]),
            paused <- member_of([false, false, false, true]),
            card_constraint <- holds_gen(ids, "claude:default at capacity"),
            dispatch_holds <- holds_gen(ids, "dispatch refused"),
            card_guardrail <- holds_gen(ids, "no eligible model"),
            capacity <- capacity_gen(ids),
            max_runs: 200
          ) do
      base =
        input(
          issues: issues,
          slots_total: slots_total,
          quota: quota,
          paused: paused,
          card_constraint: card_constraint,
          dispatch_holds: dispatch_holds,
          card_guardrail: card_guardrail
        )

      today = Snapshot.derive(base)
      shadowed = Snapshot.derive(Map.put(base, :walk, capacity))

      assert Map.delete(shadowed, :walk) == today
      assert is_map(shadowed.walk)
    end
  end
end
