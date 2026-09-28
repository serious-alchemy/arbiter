defmodule Arbiter.Workers.RunVocabularyMigrationTest do
  @moduledoc """
  bd-1uu19b (ticket lifecycle 5/13, AC2 + AC3): the hand-written migration
  moves `worker_runs` onto the one run vocabulary — `status` becomes `state`
  plus `outcome`, and `worker_type` becomes `kind` — and backfills every row.

  Run against a throwaway database, like the other migration tests: the
  suite's own `Arbiter.Repo` has already been migrated, so only a
  `worker_runs` table still in the old shape can exercise the migration's SQL.
  """
  use ExUnit.Case, async: false

  alias Arbiter.RekeyMigrationRepo, as: Repo
  alias Arbiter.Workers.RunState

  @migration_id 20_260_928_131_352
  @migration_file "priv/repo/migrations/20260928131352_adopt_run_vocabulary_on_worker_runs.exs"

  # One row per old status in the ticket's table: {id, status, state, outcome}.
  @status_rows [
    {"r-running", "running", "working", nil},
    {"r-completed", "completed", "finished", "succeeded"},
    {"r-failed", "failed", "finished", "failed"},
    {"r-review-parked", "review_parked", "finished", "failed"},
    {"r-review-not-started", "review_not_started", "finished", "failed"},
    {"r-interrupted", "interrupted", "finished", "interrupted"}
  ]

  # The old statuses no code mints any more — so no `String.to_existing_atom/1`.
  @legacy_statuses %{
    "running" => :running,
    "completed" => :completed,
    "failed" => :failed,
    "review_parked" => :review_parked,
    "review_not_started" => :review_not_started,
    "interrupted" => :interrupted
  }

  # One row per old worker_type: {id, task_id, worker_type, role, kind, role_after}.
  @type_rows [
    {"k-main", "bd-1", "main", nil, "implement", "base"},
    {"k-main-role", "bd-1", "main", "base", "implement", "base"},
    {"k-impl", "bd-1#impl", "impl", nil, "implement", "impl"},
    {"k-review", "bd-1#review", "review", nil, "review", "review"},
    {"k-fix", "bd-1", "fix_pass", nil, "fix_pass", "fix_pass"},
    {"k-conflict", "bd-1", "conflict", "conflict", "conflict", "conflict"}
  ]

  @legacy_types %{
    "main" => :main,
    "impl" => :impl,
    "review" => :review,
    "fix_pass" => :fix_pass,
    "conflict" => :conflict
  }

  setup_all do
    [{module, _}] = Code.require_file(@migration_file, File.cwd!())
    {:ok, migration: module}
  end

  setup %{migration: migration} do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_rv_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    # The live table's shape for every column this migration reads or writes.
    Repo.query!("""
    CREATE TABLE worker_runs (
      "updated_at" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "failure_reason" TEXT,
      "started_at" TEXT NOT NULL,
      "status" TEXT NOT NULL,
      "workspace_id" TEXT,
      "task_id" TEXT NOT NULL,
      "id" TEXT NOT NULL PRIMARY KEY,
      worker_type TEXT NOT NULL DEFAULT 'main',
      "role" TEXT
    )
    """)

    Repo.query!(
      ~s[CREATE INDEX "polecat_runs_workspace_id_status_started_at_index" ON "worker_runs" (workspace_id, status, started_at)]
    )

    {:ok, migration: migration}
  end

  describe "status becomes state and outcome" do
    test "every old status lands where the ticket's table says", %{migration: migration} do
      for {id, status, _state, _outcome} <- @status_rows, do: insert(id, "bd-1", status, "main")

      migrate!(migration)

      for {id, status, state, outcome} <- @status_rows do
        assert query("SELECT state, outcome FROM worker_runs WHERE id = ?1", [id]) ==
                 [[state, outcome]],
               "#{status}: expected #{state}/#{inspect(outcome)}"
      end
    end

    test "agrees with RunState.from_legacy_status/1, the same rule in code", %{
      migration: migration
    } do
      for {id, status, _state, _outcome} <- @status_rows, do: insert(id, "bd-1", status, "main")

      migrate!(migration)

      for {id, status, _state, _outcome} <- @status_rows do
        {state, outcome} = RunState.from_legacy_status(Map.fetch!(@legacy_statuses, status))

        assert query("SELECT state, outcome FROM worker_runs WHERE id = ?1", [id]) ==
                 [[Atom.to_string(state), outcome && Atom.to_string(outcome)]]
      end
    end

    test "the status column and its index are gone", %{migration: migration} do
      migrate!(migration)

      columns = columns()
      refute "status" in columns
      assert "state" in columns
      assert "outcome" in columns

      indexes = query("SELECT name FROM sqlite_master WHERE type = 'index'", []) |> List.flatten()
      refute "polecat_runs_workspace_id_status_started_at_index" in indexes
      assert "worker_runs_workspace_id_state_started_at_index" in indexes
    end
  end

  describe "worker_type becomes kind" do
    test "every worker_type maps to its kind, and role is kept or backfilled", %{
      migration: migration
    } do
      for {id, task_id, type, role, _kind, _role_after} <- @type_rows do
        insert(id, task_id, "completed", type, role)
      end

      migrate!(migration)

      for {id, _task_id, type, _role, kind, role_after} <- @type_rows do
        assert query("SELECT kind, role FROM worker_runs WHERE id = ?1", [id]) ==
                 [[kind, role_after]],
               "#{type}: expected kind #{kind}, role #{role_after}"
      end

      refute "worker_type" in columns()
    end

    test "agrees with RunState.kind_for_worker_type/1", %{migration: migration} do
      for {id, task_id, type, role, _kind, _role_after} <- @type_rows do
        insert(id, task_id, "completed", type, role)
      end

      migrate!(migration)

      for {id, _task_id, type, _role, _kind, _role_after} <- @type_rows do
        kind = RunState.kind_for_worker_type(Map.fetch!(@legacy_types, type))
        assert query("SELECT kind FROM worker_runs WHERE id = ?1", [id]) == [[to_string(kind)]]
      end
    end
  end

  describe "rows written after the migration" do
    test "default to an implement run that is starting", %{migration: migration} do
      migrate!(migration)

      Repo.query!("""
      INSERT INTO worker_runs (id, task_id, started_at, inserted_at, updated_at)
      VALUES ('late', 'bd-2', '2026-09-28T00:00:00Z', '2026-09-28T00:00:00Z', '2026-09-28T00:00:00Z')
      """)

      assert query("SELECT kind, state, outcome FROM worker_runs WHERE id = 'late'", []) ==
               [["implement", "starting", nil]]
    end
  end

  describe "down/0" do
    test "restores status and worker_type from the new columns", %{migration: migration} do
      for {id, status, _state, _outcome} <- @status_rows, do: insert(id, "bd-1", status, "main")
      insert("k-review", "bd-1#review", "completed", "review", "review")
      insert("k-impl", "bd-1#impl", "completed", "impl", "impl")
      migrate!(migration)

      Ecto.Migrator.down(Repo, @migration_id, migration, log: false)

      columns = columns()
      refute "state" in columns
      refute "outcome" in columns
      refute "kind" in columns

      # review_parked / review_not_started folded into failed and do not
      # come back; every other status round-trips.
      assert query("SELECT id, status FROM worker_runs WHERE id LIKE 'r-%' ORDER BY id", []) ==
               [
                 ["r-completed", "completed"],
                 ["r-failed", "failed"],
                 ["r-interrupted", "interrupted"],
                 ["r-review-not-started", "failed"],
                 ["r-review-parked", "failed"],
                 ["r-running", "running"]
               ]

      assert query("SELECT id, worker_type FROM worker_runs WHERE id LIKE 'k-%' ORDER BY id", []) ==
               [["k-impl", "impl"], ["k-review", "review"]]
    end
  end

  describe "its place in the migration order" do
    # The newest migration main had shipped, and the live install had run,
    # when this one was written (the install's `schema_migrations` topped out
    # at 20260928000034 on 2026-09-28).
    @already_run_in_production [20_260_927_184_052, 20_260_928_000_034]

    test "sorts after every migration production had already run", %{migration: migration} do
      _ = Ecto.Migrator.migrated_versions(Repo, log: false)

      for version <- @already_run_in_production do
        Repo.query!("INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
          version,
          "2026-09-28T00:00:00"
        ])
      end

      assert :ok =
               Ecto.Migrator.up(Repo, @migration_id, migration,
                 log: false,
                 strict_version_order: true
               )
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp migrate!(migration), do: Ecto.Migrator.up(Repo, @migration_id, migration, log: false)

  defp query(sql, params), do: Repo.query!(sql, params).rows

  defp columns,
    do: query("SELECT name FROM pragma_table_info('worker_runs')", []) |> List.flatten()

  defp insert(id, task_id, status, worker_type, role \\ nil) do
    Repo.query!(
      """
      INSERT INTO worker_runs (id, task_id, status, worker_type, role, started_at,
                               inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z',
              '2026-09-01T00:00:00Z')
      """,
      [id, task_id, status, worker_type, role]
    )
  end
end
