defmodule Arbiter.Tasks.DoltImport.RecordsTest do
  @moduledoc """
  The importer writes `issues` and `dependencies` rows with `Repo.insert_all/3`,
  around Ash. On SQLite every id column is plain `:text`: the adapter stores
  the bytes it is handed and hands the same bytes back, and Ash's non-strict
  load keeps a value its type rejects rather than failing the read. A 16-byte
  binary id therefore "reads" but can never be fetched by id, and a 16-byte
  `workspace_id` never matches the hyphenated string Ash wrote for every
  other row. These tests pin the only shape that round-trips: the string.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Repo
  alias Arbiter.Tasks.{Dependency, Issue, TicketTransition, Workspace}
  alias Arbiter.Tasks.DoltImport.Mapper
  alias Arbiter.TicketTransitionsInvariant

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "dolt-ws", prefix: "dlt"})
    {:ok, ws: ws, now: DateTime.utc_now() |> DateTime.truncate(:microsecond)}
  end

  test "issue_record/3 rows bulk-inserted around Ash belong to the workspace Ash sees",
       %{ws: ws, now: now} do
    row = %{"id" => "dlt-a1b2c", "title" => "imported", "status" => "open"}

    {1, _} = Repo.insert_all("issues", [Mapper.issue_record(row, ws.id, now)])

    issue = Ash.get!(Issue, "dlt-a1b2c")
    assert issue.workspace_id == ws.id

    assert [%Issue{id: "dlt-a1b2c"}] =
             Issue
             |> Ash.Query.filter(workspace_id == ^ws.id)
             |> Ash.read!()
  end

  # bd-842qio: rows written around Ash still carry the lifecycle state their
  # status implies — the column's default would put every one in the backlog.
  test "issue_record/3 rows land in the lifecycle state their status implies",
       %{ws: ws, now: now} do
    rows = [
      %{"id" => "dlt-open1", "title" => "o", "status" => "open"},
      %{"id" => "dlt-work1", "title" => "w", "status" => "in_progress"},
      %{"id" => "dlt-done1", "title" => "d", "status" => "closed"}
    ]

    {3, _} = Repo.insert_all("issues", Enum.map(rows, &Mapper.issue_record(&1, ws.id, now)))

    assert %Issue{state: :backlog, close_reason: nil} = Ash.get!(Issue, "dlt-open1")
    assert %Issue{state: :active, close_reason: nil} = Ash.get!(Issue, "dlt-work1")
    assert %Issue{state: :closed, close_reason: :completed} = Ash.get!(Issue, "dlt-done1")
  end

  test "status_sync/2 moves the lifecycle state to the one the refreshed Dolt status implies",
       %{ws: ws, now: now} do
    {1, _} =
      Repo.insert_all("issues", [
        Mapper.issue_record(
          %{"id" => "dlt-sync1", "title" => "s", "status" => "open"},
          ws.id,
          now
        )
      ])

    sync = fn status ->
      {sql, params} = Mapper.status_sync(%{"id" => "dlt-sync1", "status" => status}, now)
      Repo.query!(sql, params)
      Ash.get!(Issue, "dlt-sync1")
    end

    assert %Issue{state: :closed, close_reason: :completed} = sync.("closed")
    assert %Issue{state: :active, close_reason: nil} = sync.("in_progress")
    assert %Issue{state: :backlog, close_reason: nil} = sync.("open")
  end

  test "status_sync/2 leaves a queued ticket queued and a ticket already in step untouched",
       %{ws: ws, now: now} do
    {:ok, queued} =
      Issue
      |> Ash.create!(%{title: "q", workspace_id: ws.id, acceptance: "- works"})
      |> Ash.update(%{}, action: :promote)

    {sql, params} = Mapper.status_sync(%{"id" => queued.id, "status" => "open"}, now)
    assert %{num_rows: 0} = Repo.query!(sql, params)
    assert Ash.get!(Issue, queued.id).state == :queued
  end

  # bd-5gkqdr: the importer writes `issues` around Ash, and its rows still get
  # their transition history — the creation row at the Dolt `created_at`, and a
  # row for every state a `--sync-status` refresh moves.
  test "issue_record/3 rows get a creation row in the state they land in",
       %{ws: ws, now: now} do
    rows = [
      %{
        "id" => "dlt-hist1",
        "title" => "o",
        "status" => "open",
        "created_at" => "2026-05-19 19:21:46.123456"
      },
      %{"id" => "dlt-hist2", "title" => "d", "status" => "closed"}
    ]

    {2, _} = Repo.insert_all("issues", Enum.map(rows, &Mapper.issue_record(&1, ws.id, now)))

    assert [open] = TicketTransition.for_ticket!("dlt-hist1")
    assert {open.from_state, open.to_state, open.transition} == {nil, :backlog, "create"}
    assert open.at == ~U[2026-05-19 19:21:46.123456Z]
    assert open.workspace_id == ws.id

    assert [closed] = TicketTransition.for_ticket!("dlt-hist2")
    assert {closed.to_state, closed.close_reason, closed.at} == {:closed, :completed, now}

    TicketTransitionsInvariant.assert_holds!(ws.id)
  end

  test "status_sync/2 writes a row per state it moves, and none when in step",
       %{ws: ws, now: now} do
    row = %{"id" => "dlt-hist3", "title" => "s", "status" => "open"}
    {1, _} = Repo.insert_all("issues", [Mapper.issue_record(row, ws.id, now)])

    sync = fn status ->
      {sql, params} = Mapper.status_sync(%{"id" => "dlt-hist3", "status" => status}, now)
      Repo.query!(sql, params)
    end

    sync.("in_progress")
    sync.("in_progress")
    sync.("closed")

    assert Enum.map(TicketTransition.for_ticket!("dlt-hist3"), &{&1.from_state, &1.to_state}) ==
             [{nil, :backlog}, {:backlog, :active}, {:active, :closed}]

    TicketTransitionsInvariant.assert_holds!(ws.id)
  end

  test "dependency_record/3 rows bulk-inserted around Ash are fetchable by id",
       %{ws: ws, now: now} do
    {:ok, a} = Ash.create(Issue, %{title: "A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "B", workspace_id: ws.id})
    row = %{"issue_id" => a.id, "depends_on_id" => b.id, "type" => "blocks"}

    rec = Mapper.dependency_record(row, :blocks, now)
    {1, _} = Repo.insert_all("dependencies", [rec])

    a_id = a.id
    b_id = b.id
    id = rec.id

    assert %Dependency{id: ^id, from_issue_id: ^a_id, to_issue_id: ^b_id} =
             Ash.get!(Dependency, id)
  end
end
