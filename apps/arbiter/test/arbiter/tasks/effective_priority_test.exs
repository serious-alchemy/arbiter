defmodule Arbiter.Tasks.EffectivePriorityTest do
  @moduledoc """
  ES4 (bd-4sw689, `docs/design/epic-aware-scheduling.md` §6.3, §9): the one read
  of a ticket's effective priority for every surface that is not the board —
  `fields/2` (what `ticket_show` and `GET /api/issues/:id` add), `effective/1`
  (what `DispatchQueue` orders held intents by) and `order/1` (the §4 key over a
  list of tickets).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.EffectivePriority
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ep-#{System.unique_integer([:positive])}",
        prefix: "ep#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      Arbiter.Settings.set_scheduling_epic_floors_enabled(nil)
      Arbiter.Settings.set_scheduling_max_lifted_in_flight(nil)
    end)

    %{ws: ws}
  end

  defp epic(ws, floor) do
    {:ok, epic} = Ash.create(Issue, %{title: "Epic", workspace_id: ws.id, issue_type: :epic})

    if floor do
      {:ok, epic} = Ash.update(epic, %{floor_priority: floor}, action: :set_floor)
      epic
    else
      epic
    end
  end

  defp queued(ws, priority, parent \\ nil) do
    {:ok, created} =
      Ash.create(Issue, %{
        title: "t-#{System.unique_integer([:positive])}",
        workspace_id: ws.id,
        priority: priority,
        acceptance: "- it works"
      })

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    if parent, do: {:ok, _} = Dependencies.add(parent.id, issue.id, :parent_of)
    issue
  end

  defp started(ws, priority, parent) do
    {:ok, issue} = Ash.update(queued(ws, priority, parent), %{}, action: :start)
    issue
  end

  describe "fields/1" do
    test "no floor anywhere: own priority, no via, no lift", %{ws: ws} do
      parent = epic(ws, nil)
      child = queued(ws, 3, parent)
      parentless = queued(ws, 1)

      assert EffectivePriority.fields(child) ==
               %{effective_priority: 3, priority_via: nil, priority_lift: nil}

      assert EffectivePriority.fields(parentless) ==
               %{effective_priority: 1, priority_via: nil, priority_lift: nil}
    end

    test "a floored epic lifts its child and names itself", %{ws: ws} do
      parent = epic(ws, 1)
      child = queued(ws, 3, parent)
      parent_id = parent.id

      assert %{effective_priority: 1, priority_via: ^parent_id, priority_lift: "applied"} =
               EffectivePriority.fields(child)
    end

    test "a floor worse than the own priority is no lift", %{ws: ws} do
      parent = epic(ws, 3)
      child = queued(ws, 1, parent)

      assert EffectivePriority.fields(child) ==
               %{effective_priority: 1, priority_via: nil, priority_lift: nil}
    end

    test "the kill switch ignores every floor", %{ws: ws} do
      parent = epic(ws, 1)
      child = queued(ws, 3, parent)
      {:ok, false} = Arbiter.Settings.set_scheduling_epic_floors_enabled(false)

      assert EffectivePriority.fields(child) ==
               %{effective_priority: 3, priority_via: nil, priority_lift: nil}
    end

    test "at the lift cap the card keeps its own priority and says capped", %{ws: ws} do
      parent = epic(ws, 1)
      _in_flight = started(ws, 3, parent)
      child = queued(ws, 3, parent)
      {:ok, 1} = Arbiter.Settings.set_scheduling_max_lifted_in_flight(1)
      parent_id = parent.id

      assert %{effective_priority: 3, priority_via: ^parent_id, priority_lift: "capped"} =
               EffectivePriority.fields(child)
    end
  end

  describe "effective/1" do
    test "is the lifted priority for a floored child and the own priority otherwise", %{ws: ws} do
      parent = epic(ws, 1)

      assert EffectivePriority.effective(queued(ws, 4, parent)) == 1
      assert EffectivePriority.effective(queued(ws, 4)) == 4
    end

    test "an unreadable ticket reads as P2", %{ws: _ws} do
      assert EffectivePriority.effective(nil) == 2
    end
  end

  describe "order/1" do
    test "with no floors it is today's {priority, rank, created_at}", %{ws: ws} do
      parent = epic(ws, nil)
      a = queued(ws, 2, parent)
      b = queued(ws, 0)
      c = queued(ws, 2)
      d = queued(ws, 4, parent)

      expected = Arbiter.Board.Scheduler.order([a, b, c, d])

      assert Enum.map(EffectivePriority.order([d, c, b, a]), & &1.id) ==
               Enum.map(expected, & &1.id)
    end

    test "a floor puts the lifted child ahead of a better-own-priority parentless ticket", %{
      ws: ws
    } do
      parent = epic(ws, 1)
      plain = queued(ws, 2)
      child = queued(ws, 4, parent)

      assert Enum.map(EffectivePriority.order([plain, child]), & &1.id) == [child.id, plain.id]
    end

    test "an empty list is an empty list" do
      assert EffectivePriority.order([]) == []
    end
  end
end
