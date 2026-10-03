defmodule Arbiter.Board.SnapshotRankPinnedTest do
  @moduledoc """
  ES6 (`docs/design/epic-aware-scheduling.md` §4): a card an operator dragged
  (`rank_pinned`) sorts first within its band on the board, in Backlog and in
  Ready, and never leaves the band it is in.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.{Dependencies, Issue, Rank, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rps-#{System.unique_integer([:positive])}", prefix: "rps"})

    {:ok, ws: ws}
  end

  defp backlog(ws, priority, parent \\ nil) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "t-#{System.unique_integer([:positive])}",
        workspace_id: ws.id,
        priority: priority,
        acceptance: "- ok"
      })

    if parent, do: {:ok, _} = Dependencies.add(parent.id, issue.id, :parent_of)
    issue
  end

  defp ready(ws, priority, parent \\ nil) do
    {:ok, issue} = Ash.update(backlog(ws, priority, parent), %{}, action: :promote)
    issue
  end

  defp ids(cards), do: Enum.map(cards, & &1.id)

  test "a pinned Ready card sorts first in its band and stays inside it", %{ws: ws} do
    p1 = ready(ws, 1)
    a = ready(ws, 2)
    b = ready(ws, 2)
    c = ready(ws, 2)
    {:ok, _} = Rank.move(c, %{position: :bottom, pin: true})

    snapshot = Snapshot.load(workspace_id: ws.id)

    assert ids(snapshot.ready) == [p1.id, c.id, a.id, b.id]
    assert Enum.find(snapshot.ready, &(&1.id == c.id)).card.rank_pinned
    refute Enum.find(snapshot.ready, &(&1.id == a.id)).card.rank_pinned
  end

  test "a pinned Backlog card sorts first in its band", %{ws: ws} do
    a = backlog(ws, 2)
    b = backlog(ws, 2)
    {:ok, _} = Rank.move(b, %{position: :bottom, pin: true})

    snapshot = Snapshot.load(workspace_id: ws.id)

    assert ids(snapshot.backlog) == [b.id, a.id]
  end

  test "pinned outranks the lifted-children own-priority order inside a floored band", %{ws: ws} do
    {:ok, epic} = Ash.create(Issue, %{title: "epic", workspace_id: ws.id, issue_type: :epic})
    {:ok, _} = Ash.update(epic, %{floor_priority: 1}, action: :set_floor)

    p3 = ready(ws, 3, epic)
    p4 = ready(ws, 4, epic)
    {:ok, _} = Rank.move(p4, %{position: :bottom, pin: true})

    snapshot = Snapshot.load(workspace_id: ws.id)

    assert ids(snapshot.ready) == [p4.id, p3.id]
  end

  test "with nothing pinned the order is today's {priority, rank}", %{ws: ws} do
    a = ready(ws, 2)
    b = ready(ws, 1)
    c = ready(ws, 2)

    assert ids(Snapshot.load(workspace_id: ws.id).ready) == [b.id, a.id, c.id]
  end
end
