defmodule Arbiter.Tasks.TicketTransitionTest do
  @moduledoc """
  bd-5gkqdr (reports design v2, §4.2): every change of a ticket's lifecycle
  `state` appends one `ticket_transitions` row, in the same statement as the
  state write.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, Lifecycle, TicketTransition, Workspace}
  alias Arbiter.TicketTransitionsInvariant

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "tt-#{System.unique_integer([:positive])}", prefix: "tt"})

    {:ok, ws: ws}
  end

  defp ticket(ws, attrs \\ %{}) do
    Ash.create!(
      Issue,
      Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- it works"}, attrs)
    )
  end

  defp rows(issue), do: TicketTransition.for_ticket!(issue.id)

  # Makes every insert into `ticket_transitions` fail for the rest of the test
  # (the sandbox rolls the trigger back with everything else).
  defp break_the_writer! do
    Repo.query!("""
    CREATE TRIGGER test_ticket_transitions_fail BEFORE INSERT ON ticket_transitions
    BEGIN SELECT RAISE(ABORT, 'ticket_transitions insert failed'); END
    """)
  end

  describe "creation" do
    test "writes one nil → backlog row at the ticket's created_at", %{ws: ws} do
      issue = ticket(ws, %{repo: "org/app"})

      assert [row] = rows(issue)
      assert row.ticket_id == issue.id
      assert row.workspace_id == ws.id
      assert row.repo == "org/app"
      assert row.from_state == nil
      assert row.to_state == :backlog
      assert row.transition == "create"
      assert row.close_reason == nil
      assert row.at == issue.created_at
      assert row.source == "live"
      assert row.origin == nil
    end

    test "the row's id is a UUIDv7 string", %{ws: ws} do
      [row] = ws |> ticket() |> rows()
      assert row.id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end
  end

  describe "a named transition" do
    test "writes one row with its from, to, name and the write's clock reading", %{ws: ws} do
      issue = ticket(ws)
      {:ok, queued} = Ash.update(issue, %{}, action: :promote)

      assert [_create, row] = rows(issue)
      assert row.from_state == :backlog
      assert row.to_state == :queued
      assert row.transition == "promote"
      assert row.at == queued.updated_at
      assert DateTime.compare(row.at, issue.created_at) == :gt
    end

    test "a close records its close_reason; the reopen clears it", %{ws: ws} do
      {:ok, closed} = ws |> ticket() |> Ash.update(%{close_reason: :wont_do}, action: :close)
      {:ok, _reopened} = Ash.update(closed, %{}, action: :reopen)

      assert [_create, close, reopen] = rows(closed)

      assert {close.transition, close.to_state, close.close_reason} ==
               {"close", :closed, :wont_do}

      assert {reopen.transition, reopen.from_state, reopen.to_state} ==
               {"reopen", :closed, :queued}

      assert reopen.close_reason == nil
    end

    test "a repeat (return_to_work then open_pr again) is a row each time", %{ws: ws} do
      issue = ticket(ws)

      for action <- [:promote, :start, :open_pr, :return_to_work, :open_pr] do
        {:ok, _} =
          issue |> Map.get(:id) |> then(&Ash.get!(Issue, &1)) |> Ash.update(%{}, action: action)
      end

      assert Enum.map(rows(issue), & &1.transition) ==
               ~w(create promote start open_pr return_to_work open_pr)

      TicketTransitionsInvariant.assert_holds!(ws.id)
    end

    test "the :pr_closed door is recorded as the return_to_work it applies", %{ws: ws} do
      issue = ticket(ws)
      {:ok, issue} = Ash.update(issue, %{}, action: :promote)
      {:ok, issue} = Ash.update(issue, %{}, action: :start)
      {:ok, issue} = Ash.update(issue, %{}, action: :open_pr)
      {:ok, _} = Ash.update(issue, %{detail: "closed"}, action: :pr_closed)

      assert %TicketTransition{transition: "return_to_work", from_state: :merging} =
               List.last(rows(issue))
    end
  end

  describe "no state change, no row" do
    test "an idempotent legacy door on a ticket already there writes nothing", %{ws: ws} do
      {:ok, queued} = ws |> ticket() |> Ash.update(%{}, action: :promote_to_ready)
      before = rows(queued)

      {:ok, %Issue{state: :queued}} = Ash.update(queued, %{}, action: :promote_to_ready)
      assert rows(queued) == before

      {:ok, backlog} = Ash.update(queued, %{}, action: :return_to_backlog)
      {:ok, %Issue{state: :backlog}} = Ash.update(backlog, %{}, action: :return_to_backlog)
      assert length(rows(queued)) == length(before) + 1
    end

    test "a refused transition writes nothing", %{ws: ws} do
      issue = ticket(ws)
      assert {:error, _} = Ash.update(issue, %{}, action: :open_pr)
      assert [%{transition: "create"}] = rows(issue)
    end

    test "an :update that is not a transition writes nothing", %{ws: ws} do
      issue = ticket(ws)
      {:ok, _} = Ash.update(issue, %{title: "renamed", notes: "n"})
      assert [%{transition: "create"}] = rows(issue)
    end
  end

  describe "a failing insert fails the write (§8 risk 5)" do
    test "the transition is rolled back: the ticket stays where it was", %{ws: ws} do
      issue = ticket(ws)
      break_the_writer!()

      assert {:error, _} = Ash.update(issue, %{}, action: :promote)

      assert Ash.get!(Issue, issue.id).state == :backlog
      assert [%{transition: "create"}] = rows(issue)
    end

    test "a close is rolled back too, close_reason included", %{ws: ws} do
      issue = ticket(ws)
      break_the_writer!()

      assert {:error, _} = Ash.update(issue, %{close_reason: :wont_do}, action: :close)

      assert %Issue{state: :backlog, close_reason: nil} = Ash.get!(Issue, issue.id)
    end

    test "the create is rolled back: no ticket without its creation row", %{ws: ws} do
      break_the_writer!()

      assert {:error, _} =
               Ash.create(Issue, %{title: "never", workspace_id: ws.id, acceptance: "- x"})

      assert Issue |> Ash.Query.filter(workspace_id == ^ws.id) |> Ash.read!() == []
    end
  end

  describe "rows written around Ash" do
    test "a raw state write is recorded, named by the table when the move is in it", %{ws: ws} do
      issue = ticket(ws)

      Repo.query!("UPDATE issues SET state = 'queued' WHERE id = ?", [issue.id])
      Repo.query!("UPDATE issues SET state = 'verifying' WHERE id = ?", [issue.id])

      assert [_create, promote, raw] = rows(issue)

      assert {promote.transition, promote.from_state, promote.to_state} ==
               {"promote", :backlog, :queued}

      # queued → verifying is not in the lifecycle table.
      assert {raw.transition, raw.from_state, raw.to_state} == {"unnamed", :queued, :verifying}
      assert DateTime.compare(raw.at, promote.at) in [:gt, :eq]

      TicketTransitionsInvariant.assert_holds!(ws.id)
    end

    test "a raw write stamping an old updated_at still sorts after the earlier rows",
         %{ws: ws} do
      {:ok, queued} = ws |> ticket() |> Ash.update(%{}, action: :promote)

      Repo.query!("UPDATE issues SET state = 'active', updated_at = ? WHERE id = ?", [
        ~U[2020-01-01 00:00:00.000000Z],
        queued.id
      ])

      assert [_create, promote, start] = rows(queued)
      assert start.transition == "start"
      assert start.at == promote.at

      TicketTransitionsInvariant.assert_holds!(ws.id)
    end

    test "a raw write that leaves state alone is not recorded", %{ws: ws} do
      issue = ticket(ws)
      Repo.query!("UPDATE issues SET state = state, title = 'x' WHERE id = ?", [issue.id])
      assert [%{transition: "create"}] = rows(issue)
    end
  end

  test "the trigger names exactly the lifecycle table's moves", %{ws: ws} do
    # The writer is SQL, so the table is spelled out there too; this keeps the
    # two in step. Each (from, to) the table allows must get its transition's
    # name — the pairs are unambiguous, which is what lets SQL name them.
    for transition <- Lifecycle.transitions(),
        {sources, to} = Lifecycle.rule(transition),
        from <- sources do
      issue = ticket(ws)

      Repo.query!("UPDATE issues SET state = ? WHERE id = ?", [Atom.to_string(from), issue.id])
      Repo.query!("UPDATE issues SET state = ? WHERE id = ?", [Atom.to_string(to), issue.id])

      assert List.last(rows(issue)).transition == Atom.to_string(transition),
             "#{from} → #{to} should be named #{transition}"
    end
  end

  # SQLite drops a table's triggers with the table, so a later migration that
  # rebuilds `issues` (create-copy-drop-rename) would silently stop the
  # history. This fails it instead.
  test "both writer triggers are installed on issues" do
    %{rows: rows} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'issues' ORDER BY name"
      )

    assert ["ticket_transitions_on_issue_insert", "ticket_transitions_on_issue_state_update"] --
             List.flatten(rows) == []
  end

  test "deleting a ticket keeps its history", %{ws: ws} do
    issue = ticket(ws)
    Repo.query!("DELETE FROM issues_versions WHERE version_source_id = ?", [issue.id])
    Repo.query!("DELETE FROM issues WHERE id = ?", [issue.id])

    assert [%{transition: "create"}] = TicketTransition.for_ticket!(issue.id)
  end
end
