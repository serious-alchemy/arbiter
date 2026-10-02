defmodule Arbiter.Reports.BurnUpTest do
  @moduledoc """
  bd-cl2rtd: epic burn-up (reports design v2, §5.7). The pure half
  (`burn_up/4`) is checked against a seven-child epic traced by hand; the DB
  half (`load/3`) against real `issues`, `dependencies` and
  `ticket_transitions` rows.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Reports.BurnUp
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Dependency, Issue, TicketTransition, Workspace}

  defp at(s), do: DateTime.from_naive!(NaiveDateTime.from_iso8601!(s), "Etc/UTC")
  defp iso(time), do: %{at(time) | microsecond: {0, 6}} |> DateTime.to_iso8601()

  defp edge(id, time, weight), do: %{child_id: id, at: at(time), weight: weight}
  defp row(id, state, time), do: %{ticket_id: id, to_state: state, at: at(time)}

  # An epic with seven children, 2026-09-01 .. 2026-09-07, traced by hand.
  #
  #       attached     weight  history
  #  c1   09-01        1 (D1)  closed 09-02
  #  c2   09-01        2 (D2)  closed 09-03, REOPENED 09-05, closed again 09-07
  #  c3   09-01        3 (D3)  closed 09-04
  #  c4   09-02        0.5     closed 09-02 (same day it was attached)
  #  c5   09-03        2 (nil) closed 09-06
  #  c6   09-03        4 (D4)  never closes
  #  c7   09-05        1 (D1)  closed 09-04 — *before* it was attached
  defp epic_edges do
    [
      edge("c1", "2026-09-01 08:00:00", 1),
      edge("c2", "2026-09-01 08:00:00", 2),
      edge("c3", "2026-09-01 08:00:00", 3),
      edge("c4", "2026-09-02 09:00:00", 0.5),
      edge("c5", "2026-09-03 09:00:00", 2),
      edge("c6", "2026-09-03 09:00:00", 4),
      edge("c7", "2026-09-05 09:00:00", 1)
    ]
  end

  defp epic_rows do
    [
      row("c1", :active, "2026-09-01 09:00:00"),
      row("c1", :closed, "2026-09-02 10:00:00"),
      row("c2", :active, "2026-09-01 09:00:00"),
      row("c2", :closed, "2026-09-03 10:00:00"),
      row("c2", :queued, "2026-09-05 10:00:00"),
      row("c2", :closed, "2026-09-07 10:00:00"),
      row("c3", :active, "2026-09-01 09:00:00"),
      row("c3", :closed, "2026-09-04 10:00:00"),
      row("c4", :active, "2026-09-02 09:30:00"),
      row("c4", :closed, "2026-09-02 17:00:00"),
      row("c5", :active, "2026-09-03 10:00:00"),
      row("c5", :closed, "2026-09-06 10:00:00"),
      row("c6", :active, "2026-09-03 10:00:00"),
      row("c7", :active, "2026-09-03 10:00:00"),
      row("c7", :closed, "2026-09-04 10:00:00")
    ]
  end

  describe "burn_up/4" do
    test "traces the seven-child epic day by day" do
      line = BurnUp.burn_up(epic_edges(), epic_rows(), ~D[2026-09-01], ~D[2026-09-07])

      assert Enum.map(line, & &1.day) ==
               Date.range(~D[2026-09-01], ~D[2026-09-07]) |> Enum.to_list()

      assert Enum.map(line, & &1.scope) == [3, 4, 6, 6, 7, 7, 7]
      # 09-05: c2 reopens (-1) and c7 enters scope already closed (+1)
      assert Enum.map(line, & &1.done) == [0, 2, 3, 4, 4, 5, 6]
      assert Enum.map(line, & &1.scope_weight) == [6, 6.5, 12.5, 12.5, 13.5, 13.5, 13.5]
      assert Enum.map(line, & &1.done_weight) == [0, 1.5, 3.5, 6.5, 5.5, 7.5, 9.5]
    end

    test "a reopened child steps the done line down, and back up when it re-closes" do
      edges = [edge("a", "2026-09-01 08:00:00", 1), edge("b", "2026-09-01 08:00:00", 1)]

      rows = [
        row("a", :closed, "2026-09-01 12:00:00"),
        row("b", :closed, "2026-09-01 12:00:00"),
        row("b", :queued, "2026-09-02 12:00:00"),
        row("b", :closed, "2026-09-03 12:00:00")
      ]

      line = BurnUp.burn_up(edges, rows, ~D[2026-09-01], ~D[2026-09-03])

      assert Enum.map(line, & &1.done) == [2, 1, 2]
      assert Enum.map(line, & &1.scope) == [2, 2, 2]
    end

    test "done never exceeds scope, and a child without transitions is never done" do
      edges = [edge("a", "2026-09-03 08:00:00", 1), edge("b", "2026-09-01 08:00:00", 1)]
      rows = [row("a", :closed, "2026-09-01 12:00:00")]

      line = BurnUp.burn_up(edges, rows, ~D[2026-09-01], ~D[2026-09-03])

      assert Enum.map(line, &{&1.scope, &1.done}) == [{1, 0}, {1, 0}, {2, 1}]
    end

    test "an inverted window has no points" do
      assert BurnUp.burn_up(epic_edges(), epic_rows(), ~D[2026-09-08], ~D[2026-09-07]) == []
    end
  end

  describe "load/3" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{name: "bu-#{System.unique_integer([:positive])}", prefix: "bu"})

      {:ok, ws: ws}
    end

    defp child!(ws, epic, difficulty, edge_time, steps) do
      issue =
        Ash.create!(Issue, %{title: "c", workspace_id: ws.id, difficulty: difficulty})

      Ash.create!(Dependency, %{from_issue_id: epic.id, to_issue_id: issue.id, type: :parent_of})

      Repo.query!("UPDATE dependencies SET created_at = ? WHERE to_issue_id = ?", [
        iso(edge_time),
        issue.id
      ])

      Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [issue.id])

      Enum.reduce(steps, nil, fn {state, time}, from ->
        TicketTransition
        |> Ash.Changeset.for_create(:record, %{
          ticket_id: issue.id,
          workspace_id: ws.id,
          from_state: from,
          to_state: state,
          transition: if(from, do: "unnamed", else: "create"),
          at: at(time),
          source: "backfill"
        })
        |> Ash.create!()

        state
      end)

      issue
    end

    test "reads scope from the edges and done from the transitions", %{ws: ws} do
      epic = Ash.create!(Issue, %{title: "e", workspace_id: ws.id, issue_type: :epic})

      Repo.query!("UPDATE issues SET created_at = ? WHERE id = ?", [
        iso("2026-09-01 08:00:00"),
        epic.id
      ])

      child!(ws, epic, 1, "2026-09-01 08:00:00", [
        {:active, "2026-09-01 09:00:00"},
        {:closed, "2026-09-02 09:00:00"}
      ])

      child!(ws, epic, 3, "2026-09-02 08:00:00", [
        {:active, "2026-09-02 09:00:00"},
        {:closed, "2026-09-02 12:00:00"},
        {:queued, "2026-09-03 12:00:00"}
      ])

      line = BurnUp.load(epic.id, "all", ~U[2026-09-03 18:00:00Z])

      assert Enum.map(line, & &1.day) == [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]
      assert Enum.map(line, & &1.scope) == [1, 2, 2]
      assert Enum.map(line, & &1.done) == [0, 2, 1]
      assert Enum.map(line, & &1.scope_weight) == [1, 4, 4]
      assert Enum.map(line, & &1.done_weight) == [0, 4, 1]

      assert [%{day: ~D[2026-09-02]}, _] =
               BurnUp.load(epic.id, "1d", ~U[2026-09-03 18:00:00Z])
    end

    test "an epic with no children, or none selected, has no points", %{ws: ws} do
      epic = Ash.create!(Issue, %{title: "e", workspace_id: ws.id, issue_type: :epic})
      assert BurnUp.load(epic.id) == []
      assert BurnUp.load("") == []
    end
  end
end
