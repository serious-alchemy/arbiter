defmodule Arbiter.Tasks.TicketTransitionBackfillTest do
  @moduledoc """
  bd-d8fi92 (reports design v2 §3.4–3.5): the one-off backfill of
  `ticket_transitions` from the paper trail, against a fixture DB holding a
  ticket of every era — dry run by default, a reconciling row on a mismatch,
  idempotent, and never touching a ticket the live triggers already cover.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, TicketTransition, TicketTransitionBackfill, Workspace}
  alias Arbiter.TicketTransitionsInvariant

  @refined_cutover ~U[2026-08-24 17:16:09.000000Z]
  @state_cutover ~U[2026-09-27 19:41:30.000000Z]
  @cutovers [refined_cutover: @refined_cutover, state_cutover: @state_cutover]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ttb-#{System.unique_integer([:positive])}", prefix: "ttb"})

    {:ok, ws: ws}
  end

  # ---- fixtures ---------------------------------------------------------------

  defp at(iso), do: DateTime.from_iso8601(iso) |> elem(1) |> usec()
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  # A ticket as an install from before bd-5gkqdr holds it: its stored row,
  # its paper trail and no ticket_transitions rows.
  defp historic(ws, state, created_at, versions, extra \\ %{}) do
    issue = Ash.create!(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- ok"})

    Repo.query!(
      "UPDATE issues SET state = ?1, close_reason = ?2, created_at = ?3, repo = ?4 WHERE id = ?5",
      [state, extra[:close_reason], DateTime.to_iso8601(created_at), extra[:repo], issue.id]
    )

    Repo.query!("DELETE FROM issues_versions WHERE version_source_id = ?", [issue.id])
    Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [issue.id])

    for {action, at, changes} <- versions, do: insert_version(issue.id, action, at, changes)

    issue.id
  end

  defp insert_version(ticket_id, action, at, changes) do
    Repo.query!(
      """
      INSERT INTO issues_versions
        (id, version_source_id, version_action_name, version_action_type, changes,
         version_action_inputs, version_inserted_at, version_updated_at)
      VALUES (?1, ?2, ?3, 'update', ?4, '{}', ?5, ?5)
      """,
      [Ecto.UUID.generate(), ticket_id, action, Jason.encode!(changes), DateTime.to_iso8601(at)]
    )
  end

  defp rows(ticket_id) do
    ticket_id
    |> TicketTransition.for_ticket!()
    |> Enum.map(&{&1.from_state, &1.to_state, &1.transition, &1.source})
  end

  # One ticket per era, plus a reopen. Returns their ids.
  defp fixture_db(ws) do
    # Era A, created before the refined cutover: open (seeded ready) →
    # in_progress → PR → closed.
    a =
      historic(
        ws,
        "closed",
        at("2026-07-01T10:00:00Z"),
        [
          {"create", at("2026-07-01T10:00:00.5Z"), %{"status" => "open", "title" => "a"}},
          {"update", at("2026-07-01T11:00:00Z"), %{"status" => "in_progress"}},
          {"record_pr", at("2026-07-01T12:00:00Z"), %{"pr_ref" => "#1"}},
          {"close", at("2026-07-02T09:00:00Z"), %{"status" => "closed"}}
        ],
        %{close_reason: "completed", repo: "org/app"}
      )

    # Era A after the cutover: backlog → promoted → started → closed →
    # reopened (refined kept) → still queued.
    reopen =
      historic(ws, "queued", at("2026-09-01T08:00:00Z"), [
        {"create", at("2026-09-01T08:00:00Z"), %{"status" => "open", "refined" => false}},
        {"promote_to_ready", at("2026-09-02T08:00:00Z"), %{"refined" => true}},
        {"update", at("2026-09-03T08:00:00Z"), %{"status" => "in_progress"}},
        {"close", at("2026-09-04T08:00:00Z"), %{"status" => "closed"}},
        {"reopen", at("2026-09-05T08:00:00Z"), %{"status" => "open"}}
      ])

    # Era A creation, era B dual-write start, era C open_pr and await.
    b =
      historic(ws, "verifying", at("2026-09-20T08:00:00Z"), [
        {"create", at("2026-09-20T08:00:00Z"), %{"status" => "open", "refined" => true}},
        {"start", at("2026-09-28T08:00:00Z"), %{"status" => "in_progress", "state" => "active"}},
        {"record_pr", at("2026-09-28T09:00:00Z"), %{"pr_ref" => "#2"}},
        {"open_pr", at("2026-09-28T09:00:01Z"), %{"state" => "merging"}},
        {"await_verification", at("2026-09-29T08:00:00Z"), %{"state" => "verifying"}}
      ])

    # Era C from creation: backlog → promote → start → close (wont_do).
    c =
      historic(
        ws,
        "closed",
        at("2026-09-30T08:00:00Z"),
        [
          {"create", at("2026-09-30T08:00:00Z"), %{"state" => "backlog"}},
          {"promote_to_ready", at("2026-09-30T09:00:00Z"), %{"state" => "queued"}},
          {"start", at("2026-09-30T10:00:00Z"), %{"state" => "active"}},
          {"close", at("2026-09-30T11:00:00Z"),
           %{"state" => "closed", "close_reason" => "wont_do"}}
        ],
        %{close_reason: "wont_do"}
      )

    %{a: a, reopen: reopen, b: b, c: c}
  end

  # The §5.1 CFD query over the table: on `day`, every ticket sits in exactly
  # one band, so Σ bands must equal the tickets created by then.
  defp cfd(ws, day) do
    day_end = DateTime.new!(day, ~T[23:59:59.999999]) |> DateTime.to_iso8601()

    %{rows: [[banded, created]]} =
      Repo.query!(
        """
        WITH intervals AS (
          SELECT t.ticket_id, t.to_state, t.at,
                 LEAD(t.at) OVER (PARTITION BY t.ticket_id ORDER BY t.at, t.rowid) AS next_at
          FROM ticket_transitions t JOIN issues i ON i.id = t.ticket_id
          WHERE i.workspace_id = ?1
        )
        SELECT
          (SELECT COUNT(*) FROM intervals WHERE at <= ?2 AND (next_at IS NULL OR next_at > ?2)),
          (SELECT COUNT(*) FROM issues WHERE workspace_id = ?1 AND created_at <= ?2)
        """,
        [ws.id, day_end]
      )

    {banded, created}
  end

  defp run(opts \\ []), do: TicketTransitionBackfill.backfill(Keyword.merge(@cutovers, opts))

  # ---- the fixture DB ---------------------------------------------------------

  describe "a dry run (the default)" do
    test "plans every era's history, writes nothing, and finds nothing wrong", %{ws: ws} do
      ids = fixture_db(ws)
      result = run()

      assert result.pending == 4
      assert result.planned == 4 + 5 + 4 + 4
      assert result.inserted == 0
      assert result.mismatches == []
      assert result.unmapped == []
      assert result.illegal == []

      for id <- Map.values(ids), do: assert(rows(id) == [])
    end

    test "reports the CFD invariant over the plan on sample days", %{ws: ws} do
      fixture_db(ws)

      days = [~D[2026-07-01], ~D[2026-09-02], ~D[2026-09-30]]
      result = run(cfd_days: days)

      assert result.cfd == [
               %{day: ~D[2026-07-01], banded: 1, created: 1},
               %{day: ~D[2026-09-02], banded: 2, created: 2},
               %{day: ~D[2026-09-30], banded: 4, created: 4}
             ]
    end
  end

  describe "apply" do
    test "writes each era's transitions as backfill rows", %{ws: ws} do
      ids = fixture_db(ws)
      result = run(apply?: true)

      assert result.inserted == result.planned
      assert result.planned == 17

      assert rows(ids.a) == [
               {nil, :queued, "create", "backfill"},
               {:queued, :active, "legacy:update", "backfill"},
               {:active, :merging, "legacy:record_pr", "backfill"},
               {:merging, :closed, "legacy:close", "backfill"}
             ]

      assert rows(ids.reopen) == [
               {nil, :backlog, "create", "backfill"},
               {:backlog, :queued, "legacy:promote_to_ready", "backfill"},
               {:queued, :active, "legacy:update", "backfill"},
               {:active, :closed, "legacy:close", "backfill"},
               {:closed, :queued, "legacy:reopen", "backfill"}
             ]

      assert rows(ids.b) == [
               {nil, :queued, "create", "backfill"},
               {:queued, :active, "start", "backfill"},
               {:active, :merging, "open_pr", "backfill"},
               {:merging, :verifying, "await_verification", "backfill"}
             ]

      assert rows(ids.c) == [
               {nil, :backlog, "create", "backfill"},
               {:backlog, :queued, "promote", "backfill"},
               {:queued, :active, "start", "backfill"},
               {:active, :closed, "close", "backfill"}
             ]

      [a_create | _] = TicketTransition.for_ticket!(ids.a)
      assert a_create.at == at("2026-07-01T10:00:00Z")
      assert a_create.workspace_id == ws.id
      assert a_create.repo == "org/app"
      assert List.last(TicketTransition.for_ticket!(ids.a)).close_reason == :completed
      assert List.last(TicketTransition.for_ticket!(ids.c)).close_reason == :wont_do

      TicketTransitionsInvariant.assert_holds!(ws.id)
    end

    test "the CFD invariant holds over the written table on sample days", %{ws: ws} do
      fixture_db(ws)
      run(apply?: true)

      for day <- [~D[2026-06-30], ~D[2026-07-01], ~D[2026-09-03], ~D[2026-09-29], ~D[2026-10-01]] do
        {banded, created} = cfd(ws, day)
        assert banded == created, "CFD on #{day}: #{banded} banded vs #{created} created"
      end

      assert cfd(ws, ~D[2026-10-01]) == {4, 4}
    end

    test "a ticket whose insert fails is rolled back whole, logged and counted", %{ws: ws} do
      ids = fixture_db(ws)

      Repo.query!("""
      CREATE TRIGGER test_backfill_fails BEFORE INSERT ON ticket_transitions
      WHEN NEW.ticket_id = '#{ids.b}' AND NEW.to_state = 'verifying'
      BEGIN SELECT RAISE(ABORT, 'backfill insert failed'); END
      """)

      {result, log} = with_log(fn -> run(apply?: true) end)

      assert result.failed == 1
      assert result.inserted == result.planned - 4
      assert rows(ids.b) == []
      assert log =~ ids.b

      Repo.query!("DROP TRIGGER test_backfill_fails")
      assert %{pending: 1, inserted: 4} = run(apply?: true)
    end

    test "a second run inserts nothing", %{ws: ws} do
      fixture_db(ws)
      first = run(apply?: true)
      assert first.inserted > 0

      second = run(apply?: true)
      assert second.pending == 0
      assert second.planned == 0
      assert second.inserted == 0
    end
  end

  describe "the reconcile check" do
    test "a replay that ends off the stored state is logged and closed by a reconcile row", %{
      ws: ws
    } do
      id =
        historic(ws, "active", at("2026-07-01T10:00:00Z"), [
          {"create", at("2026-07-01T10:00:00Z"), %{"status" => "open"}}
        ])

      {result, log} = with_log(fn -> run(apply?: true) end)

      assert [mismatch] = result.mismatches
      assert %{ticket_id: ^id, replayed: :queued, stored: :active} = mismatch
      assert log =~ id

      assert rows(id) == [
               {nil, :queued, "create", "backfill"},
               {:queued, :active, "reconcile", "backfill_reconcile"}
             ]

      TicketTransitionsInvariant.assert_holds!(ws.id)
    end

    test "a dry run reports the mismatch and writes nothing", %{ws: ws} do
      id =
        historic(ws, "active", at("2026-07-01T10:00:00Z"), [
          {"create", at("2026-07-01T10:00:00Z"), %{"status" => "open"}}
        ])

      capture_log(fn -> assert %{mismatches: [%{ticket_id: ^id}]} = run() end)
      assert rows(id) == []
    end

    test "a ticket with no paper trail gets one row into its stored state at created_at", %{
      ws: ws
    } do
      id = historic(ws, "backlog", at("2026-07-01T10:00:00Z"), [])

      capture_log(fn -> run(apply?: true) end)

      assert [%{from_state: nil, to_state: :backlog, source: "backfill_reconcile", at: at}] =
               TicketTransition.for_ticket!(id)

      assert at == at("2026-07-01T10:00:00Z")
    end

    test "unmapped values and illegal pairs are reported with their ticket", %{ws: ws} do
      id =
        historic(ws, "merging", at("2026-09-30T08:00:00Z"), [
          {"create", at("2026-09-30T08:00:00Z"), %{"state" => "backlog"}},
          {"update", at("2026-09-30T09:00:00Z"), %{"state" => "limbo"}},
          {"update", at("2026-09-30T10:00:00Z"), %{"state" => "merging"}}
        ])

      {result, _log} = with_log(fn -> run() end)

      assert [%{ticket_id: ^id, key: "state", value: "limbo"}] = result.unmapped
      assert [%{ticket_id: ^id, from_state: :backlog, to_state: :merging}] = result.illegal
    end
  end

  describe "tickets the live triggers already cover" do
    test "a ticket created since bd-5gkqdr (it has a live create row) is left alone", %{ws: ws} do
      issue = Ash.create!(Issue, %{title: "live", workspace_id: ws.id, acceptance: "- ok"})
      {:ok, _} = Ash.update(issue, %{}, action: :promote)
      before = rows(issue.id)

      result = run(apply?: true)

      assert result.pending == 0
      assert rows(issue.id) == before
    end

    test "the real paper trail stamps a transition's version after its live row, so the cut is exact",
         %{ws: ws} do
      # A ticket from before the triggers (its paper trail, no rows), then a
      # real promote through Ash once they are live.
      issue = Ash.create!(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- ok"})
      Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [issue.id])
      {:ok, _} = Ash.update(issue, %{}, action: :promote_to_ready)

      result = run(apply?: true)

      assert result.pending == 1
      assert result.mismatches == []

      assert rows(issue.id) == [
               {nil, :backlog, "create", "backfill"},
               {:backlog, :queued, "promote", "live"}
             ]
    end

    test "a ticket that transitioned live before the backfill ran gets only the history before its first live row",
         %{ws: ws} do
      id =
        historic(ws, "queued", at("2026-07-01T10:00:00Z"), [
          {"create", at("2026-07-01T10:00:00Z"), %{"status" => "open"}},
          {"update", at("2026-07-01T11:00:00Z"), %{"status" => "in_progress", "pr_ref" => "#5"}},
          {"close", at("2026-07-02T10:00:00Z"), %{"status" => "closed"}}
        ])

      # Deployed triggers, no backfill yet: a reopen lands as a live row.
      Repo.query!("UPDATE issues SET state = 'closed' WHERE id = ?", [id])
      Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [id])

      Repo.query!("UPDATE issues SET state = 'queued', updated_at = ?2 WHERE id = ?1", [
        id,
        "2026-10-01T09:00:00.000000Z"
      ])

      # ...and its paper trail version lands a moment after the live row.
      insert_version(id, "reopen", at("2026-10-01T09:00:00.000100Z"), %{"state" => "queued"})

      result = run(apply?: true)

      assert result.pending == 1
      assert result.mismatches == []

      assert rows(id) == [
               {nil, :queued, "create", "backfill"},
               {:queued, :merging, "legacy:update", "backfill"},
               {:merging, :closed, "legacy:close", "backfill"},
               {:closed, :queued, "reopen", "live"}
             ]

      TicketTransitionsInvariant.assert_holds!(ws.id)
      assert run(apply?: true).inserted == 0
    end
  end

  describe "the per-install cutovers" do
    test "are read from schema_migrations by default" do
      %{rows: [[refined]]} =
        Repo.query!("SELECT inserted_at FROM schema_migrations WHERE version = 20260824170000")

      %{rows: [[state]]} =
        Repo.query!("SELECT inserted_at FROM schema_migrations WHERE version = 20260927184052")

      assert TicketTransitionBackfill.cutovers() == %{
               refined_cutover: to_utc(refined),
               state_cutover: to_utc(state)
             }
    end

    test "a migration missing from schema_migrations is no cutover" do
      Repo.query!("DELETE FROM schema_migrations WHERE version = 20260824170000")
      assert %{refined_cutover: nil} = TicketTransitionBackfill.cutovers()
    end

    test "an install whose refined migration ran after the ticket was created seeds it ready",
         %{ws: ws} do
      id =
        historic(ws, "queued", at("2026-07-01T10:00:00Z"), [
          {"create", at("2026-07-01T10:00:00Z"), %{"status" => "open"}}
        ])

      run(apply?: true, refined_cutover: ~U[2026-07-02 00:00:00Z])
      assert rows(id) == [{nil, :queued, "create", "backfill"}]
    end
  end

  defp to_utc(%NaiveDateTime{} = naive), do: naive |> DateTime.from_naive!("Etc/UTC") |> usec()

  defp to_utc(text) when is_binary(text),
    do: text |> NaiveDateTime.from_iso8601!() |> to_utc()
end
