defmodule Arbiter.Tasks.LifecycleMigrationTest do
  @moduledoc """
  bd-842qio (ticket lifecycle 1/13, AC8): the hand-written migration adds
  `state`, `close_reason` and `rank` to `issues` and backfills every existing
  row by the ticket's backfill table.

  Run against a throwaway database, like the other migration tests: the
  suite's own `Arbiter.Repo` has already been migrated, so only an `issues`
  table still in the old shape can exercise the migration's SQL.
  """
  use ExUnit.Case, async: false

  alias Arbiter.RekeyMigrationRepo, as: Repo

  @migration_id 20_260_927_184_052
  @migration_file "priv/repo/migrations/20260927184052_add_lifecycle_state_to_issues.exs"

  @ws_a "0199aaaa-0000-7000-8000-00000000000a"
  @ws_b "0199bbbb-0000-7000-8000-00000000000b"

  # One row per case in the ticket's backfill table, then the edges around
  # them: {id, status, refined, pr_ref, pending_merge, expected_state}.
  @rows [
    {"t-open-unrefined", "open", 0, nil, nil, "backlog"},
    {"t-open-refined", "open", 1, nil, nil, "queued"},
    {"t-wip-pr", "in_progress", 1, "#123", nil, "merging"},
    {"t-wip-pending", "in_progress", 1, nil, ~s({"pr_ref":"#9","reason":"ci_pending"}),
     "merging"},
    {"t-wip-bare", "in_progress", 1, nil, nil, "active"},
    {"t-verifying", "awaiting_verification", 1, "#77", nil, "verifying"},
    {"t-closed", "closed", 1, "#5", nil, "closed"},
    # Edges: an empty ref or stamp is no PR; a NULL refined is unrefined; an
    # unrefined row a manual dispatch took is still in progress; a close
    # leaves `refined` as it found it.
    {"t-wip-empty", "in_progress", 1, "", "{}", "active"},
    {"t-open-null-refined", "open", nil, nil, nil, "backlog"},
    {"t-wip-unrefined", "in_progress", 0, nil, nil, "active"},
    {"t-closed-unrefined", "closed", 0, nil, nil, "closed"}
  ]

  setup_all do
    [{module, _}] = Code.require_file(@migration_file, File.cwd!())
    {:ok, migration: module}
  end

  setup %{migration: migration} do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_lc_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    Repo.query!("""
    CREATE TABLE issues (
      id TEXT NOT NULL PRIMARY KEY,
      workspace_id TEXT NOT NULL,
      title TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'open',
      priority INTEGER NOT NULL DEFAULT 2,
      refined BOOLEAN DEFAULT 0,
      pr_ref TEXT,
      pending_merge TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    {:ok, migration: migration}
  end

  describe "the state backfill" do
    test "puts every row where the backfill table says", %{migration: migration} do
      seed_rows()

      migrate!(migration)

      for {id, _status, _refined, _pr_ref, _pending, expected} <- @rows do
        assert state_of(id) == expected, "#{id}: expected #{expected}, got #{state_of(id)}"
      end
    end

    test "leaves no row without a state", %{migration: migration} do
      seed_rows()

      migrate!(migration)

      assert query("SELECT COUNT(*) FROM issues WHERE state IS NULL") == [[0]]
    end
  end

  describe "close_reason" do
    test "every closed row is recorded as completed; no other row has one", %{
      migration: migration
    } do
      seed_rows()

      migrate!(migration)

      assert query("SELECT id, close_reason FROM issues WHERE status = 'closed' ORDER BY id") ==
               [["t-closed", "completed"], ["t-closed-unrefined", "completed"]]

      assert query(
               "SELECT COUNT(*) FROM issues WHERE status != 'closed' AND close_reason IS NOT NULL"
             ) ==
               [[0]]
    end
  end

  describe "rank" do
    test "runs in creation order per workspace, spaced 1024 apart", %{migration: migration} do
      insert("a-2", @ws_a, "open", 1, nil, nil, "2026-09-02T00:00:00.000000Z", 1)
      insert("a-1", @ws_a, "open", 1, nil, nil, "2026-09-01T00:00:00.000000Z", 3)
      insert("b-1", @ws_b, "open", 1, nil, nil, "2026-09-03T00:00:00.000000Z", 2)
      insert("a-3", @ws_a, "closed", 1, nil, nil, "2026-09-04T00:00:00.000000Z", 2)

      migrate!(migration)

      assert query("SELECT id, rank FROM issues ORDER BY id") ==
               [["a-1", 1024], ["a-2", 2048], ["a-3", 3072], ["b-1", 1024]]
    end
  end

  describe "its place in the migration order" do
    # The newest migrations main had shipped, and the live install had run,
    # when this one was written (the install's `schema_migrations` topped out
    # at 20260927180000 on 2026-09-27). Landing before them is out of order:
    # Ecto warns when it runs, and a rollback would then revert the newest of
    # them instead of this one.
    @already_run_in_production [20_260_927_170_000, 20_260_927_180_000]

    test "sorts after every migration production had already run", %{migration: migration} do
      _ = Ecto.Migrator.migrated_versions(Repo, log: false)

      for version <- @already_run_in_production do
        Repo.query!("INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
          version,
          "2026-09-27T18:00:00"
        ])
      end

      assert :ok =
               Ecto.Migrator.up(Repo, @migration_id, migration,
                 log: false,
                 strict_version_order: true
               )
    end
  end

  describe "the new columns" do
    test "a row written after the migration defaults to backlog, no reason, rank 0", %{
      migration: migration
    } do
      migrate!(migration)

      insert("late", @ws_a, "open", 0, nil, nil, "2026-09-27T00:00:00.000000Z", 2)

      assert query("SELECT state, close_reason, rank FROM issues WHERE id = 'late'") ==
               [["backlog", nil, 0]]
    end

    test "down/0 removes them again", %{migration: migration} do
      seed_rows()
      migrate!(migration)

      Ecto.Migrator.down(Repo, @migration_id, migration, log: false)

      columns = query("SELECT name FROM pragma_table_info('issues')") |> List.flatten()
      refute "state" in columns
      refute "close_reason" in columns
      refute "rank" in columns
      assert query("SELECT COUNT(*) FROM issues") == [[length(@rows)]]
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp migrate!(migration), do: Ecto.Migrator.up(Repo, @migration_id, migration, log: false)

  defp query(sql), do: Repo.query!(sql).rows

  defp state_of(id) do
    [[state]] = Repo.query!("SELECT state FROM issues WHERE id = ?1", [id]).rows
    state
  end

  defp seed_rows do
    @rows
    |> Enum.with_index()
    |> Enum.each(fn {{id, status, refined, pr_ref, pending, _expected}, i} ->
      created_at = "2026-09-01T00:00:#{String.pad_leading("#{i}", 2, "0")}.000000Z"
      insert(id, @ws_a, status, refined, pr_ref, pending, created_at, 2)
    end)
  end

  defp insert(id, ws, status, refined, pr_ref, pending, created_at, priority) do
    Repo.query!(
      """
      INSERT INTO issues (id, workspace_id, title, status, priority, refined, pr_ref,
                          pending_merge, created_at, updated_at)
      VALUES (?1, ?2, ?1, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
      """,
      [id, ws, status, priority, refined, pr_ref, pending, created_at]
    )
  end
end
