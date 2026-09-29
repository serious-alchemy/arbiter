defmodule Arbiter.Tasks.DropLegacyStateColumnsMigrationTest do
  @moduledoc """
  bd-36ytcl (ticket lifecycle 12/13, AC1): the hand-written migration drops
  the legacy `refined`, `status`, `review_park_reason` and `review_parked_at`
  columns from `issues`, and leaves the stored `state` (and the attention cause
  the park moved into) exactly as it was.

  Run against a throwaway database, like the other migration tests: the
  suite's own `Arbiter.Repo` has already been migrated, so only a table still
  in the old shape can exercise the migration's SQL.
  """
  use ExUnit.Case, async: false

  alias Arbiter.RekeyMigrationRepo, as: Repo

  @migration_id 20_260_929_193_617
  @migration_file "priv/repo/migrations/20260929193617_drop_legacy_state_columns_from_issues.exs"

  @dropped ~w(refined status review_park_reason review_parked_at)

  setup_all do
    [{module, _}] = Code.require_file(@migration_file, File.cwd!())
    {:ok, migration: module}
  end

  setup %{migration: migration} do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_dls_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    # The columns involved, in the shape production has them.
    Repo.query!("""
    CREATE TABLE issues (
      id TEXT NOT NULL PRIMARY KEY,
      title TEXT NOT NULL,
      status TEXT NOT NULL,
      refined INTEGER DEFAULT false,
      review_park_reason TEXT,
      review_parked_at TEXT,
      state TEXT DEFAULT 'backlog' NOT NULL,
      close_reason TEXT,
      attention_cause TEXT,
      attention_since TEXT,
      updated_at TEXT NOT NULL
    )
    """)

    {:ok, migration: migration}
  end

  @updated "2026-09-20T08:00:00.000000Z"
  @parked "2026-09-21T09:30:00.000000Z"

  # {id, status, refined, state, close_reason, park reason, attention cause}
  @rows [
    {"t-backlog", "open", 0, "backlog", nil, nil, nil},
    {"t-queued", "open", 1, "queued", nil, nil, nil},
    {"t-active", "in_progress", 1, "active", nil, nil, nil},
    {"t-merging", "in_progress", 1, "merging", nil, "inconclusive", "inconclusive"},
    {"t-verifying", "awaiting_verification", 1, "verifying", nil, nil, "awaiting_verification"},
    {"t-closed", "closed", 0, "closed", "wont_do", nil, nil}
  ]

  defp seed! do
    for {id, status, refined, state, close_reason, park, cause} <- @rows do
      Repo.query!(
        "INSERT INTO issues (id, title, status, refined, state, close_reason, " <>
          "review_park_reason, review_parked_at, attention_cause, attention_since, updated_at) " <>
          "VALUES (?1, 't', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?7, ?9)",
        [id, status, refined, state, close_reason, park, park && @parked, cause, @updated]
      )
    end
  end

  defp migrate!(m), do: Ecto.Migrator.up(Repo, @migration_id, m, log: false)

  defp columns,
    do: Repo.query!("SELECT name FROM pragma_table_info('issues')").rows |> List.flatten()

  defp states,
    do:
      Repo.query!("SELECT id, state, close_reason, attention_cause FROM issues ORDER BY id").rows

  test "drops the four legacy columns", %{migration: m} do
    seed!()
    migrate!(m)

    for column <- @dropped, do: refute(column in columns(), "#{column} is still on issues")
  end

  test "leaves every ticket's state, close_reason and attention cause intact", %{migration: m} do
    seed!()
    before = states()
    migrate!(m)

    assert states() == before
    assert length(before) == length(@rows)
    assert ["t-merging", "merging", nil, "inconclusive"] in states()
  end

  test "down/0 restores the columns from the state", %{migration: m} do
    seed!()
    migrate!(m)
    Ecto.Migrator.down(Repo, @migration_id, m, log: false)

    rows =
      Repo.query!(
        "SELECT id, status, refined, review_park_reason, review_parked_at FROM issues ORDER BY id"
      ).rows

    assert rows == [
             ["t-active", "in_progress", 1, nil, nil],
             ["t-backlog", "open", 0, nil, nil],
             ["t-closed", "closed", 1, nil, nil],
             ["t-merging", "in_progress", 1, "inconclusive", @parked],
             ["t-queued", "open", 1, nil, nil],
             ["t-verifying", "awaiting_verification", 1, nil, nil]
           ]
  end

  describe "its place in the migration order" do
    # The newest migration the live install had run when this was written
    # (`SELECT max(version) FROM schema_migrations`, 2026-09-29).
    @already_shipped [20_260_928_184_002, 20_260_929_070_714]

    test "sorts after every migration already shipped", %{migration: m} do
      _ = Ecto.Migrator.migrated_versions(Repo, log: false)

      for version <- @already_shipped do
        Repo.query!("INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
          version,
          "2026-09-29T13:00:00"
        ])
      end

      assert :ok =
               Ecto.Migrator.up(Repo, @migration_id, m, log: false, strict_version_order: true)
    end
  end
end
