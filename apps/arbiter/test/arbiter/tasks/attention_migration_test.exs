defmodule Arbiter.Tasks.AttentionMigrationTest do
  @moduledoc """
  bd-8if9zt (ticket lifecycle 6/13, AC3): the hand-written migration moves a
  ReviewGate park (`review_park_reason` / `review_parked_at`) into the
  ticket's attention cause, and types every existing escalation.

  Run against a throwaway database, like the other migration tests: the
  suite's own `Arbiter.Repo` has already been migrated, so only tables still
  in the old shape can exercise the migration's SQL.
  """
  use ExUnit.Case, async: false

  alias Arbiter.RekeyMigrationRepo, as: Repo

  @migration_id 20_260_928_170_000
  @migration_file "priv/repo/migrations/20260928170000_add_escalation_kind_and_attention_from_review_park.exs"

  setup_all do
    [{module, _}] = Code.require_file(@migration_file, File.cwd!())
    {:ok, migration: module}
  end

  setup %{migration: migration} do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_att_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    Repo.query!("""
    CREATE TABLE issues (
      id TEXT NOT NULL PRIMARY KEY,
      review_park_reason TEXT,
      review_parked_at TEXT,
      attention_cause TEXT,
      attention_detail TEXT,
      attention_since TEXT,
      updated_at TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE messages (
      id TEXT NOT NULL PRIMARY KEY,
      kind TEXT NOT NULL,
      task_ref TEXT,
      workspace_id TEXT NOT NULL,
      subject TEXT,
      body TEXT NOT NULL DEFAULT '',
      cleared_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    {:ok, migration: migration}
  end

  @updated "2026-09-20T08:00:00.000000Z"
  @parked "2026-09-21T09:30:00.000000Z"

  defp seed_issue(id, reason, parked_at, cause \\ nil) do
    Repo.query!(
      "INSERT INTO issues (id, review_park_reason, review_parked_at, attention_cause, updated_at) " <>
        "VALUES (?1, ?2, ?3, ?4, ?5)",
      [id, reason, parked_at, cause, @updated]
    )
  end

  defp seed_message(id, kind) do
    Repo.query!(
      "INSERT INTO messages (id, kind, task_ref, workspace_id, inserted_at, updated_at) " <>
        "VALUES (?1, ?2, 'bd-x', 'ws', ?3, ?3)",
      [id, kind, @updated]
    )
  end

  defp migrate!(migration), do: Ecto.Migrator.up(Repo, @migration_id, migration, log: false)

  defp attention(id) do
    [row] =
      Repo.query!(
        "SELECT attention_cause, attention_since, review_park_reason FROM issues WHERE id = ?1",
        [id]
      ).rows

    row
  end

  describe "the review park moves into the attention cause" do
    test "a parked ticket's reason and stamp become its cause and since", %{migration: m} do
      seed_issue("t-parked", "inconclusive", @parked)
      migrate!(m)

      # The park columns stay: the legacy dual-write until bd-36ytcl.
      assert attention("t-parked") == ["inconclusive", @parked, "inconclusive"]
    end

    test "every reason ReviewPark knows is carried over", %{migration: m} do
      reasons = Enum.map(Arbiter.Tasks.ReviewPark.park_reasons(), &Atom.to_string/1)
      for r <- reasons, do: seed_issue("t-#{r}", r, @parked)
      migrate!(m)

      for r <- reasons, do: assert([^r, _, _] = attention("t-#{r}"))
    end

    test "a park with no stamp falls back to updated_at", %{migration: m} do
      seed_issue("t-unstamped", "empty_diff", nil)
      migrate!(m)

      assert attention("t-unstamped") == ["empty_diff", @updated, "empty_diff"]
    end

    test "a ticket that already carries a cause keeps it", %{migration: m} do
      seed_issue("t-closed-pr", "inconclusive", @parked, "pr_closed")
      migrate!(m)

      assert ["pr_closed", nil, "inconclusive"] = attention("t-closed-pr")
    end

    test "an unparked ticket, and a reason nothing knows, get no cause", %{migration: m} do
      seed_issue("t-plain", nil, nil)
      seed_issue("t-empty", "", nil)
      seed_issue("t-unknown", "some_future_guard", @parked)
      migrate!(m)

      assert [nil, nil, nil] = attention("t-plain")
      assert [nil, nil, ""] = attention("t-empty")
      assert [nil, nil, "some_future_guard"] = attention("t-unknown")
    end

    test "down/0 takes the moved causes back out", %{migration: m} do
      seed_issue("t-parked", "inconclusive", @parked)
      seed_issue("t-closed-pr", nil, nil, "pr_closed")
      migrate!(m)

      Ecto.Migrator.down(Repo, @migration_id, m, log: false)

      assert [nil, nil, "inconclusive"] = attention("t-parked")
      assert ["pr_closed", nil, nil] = attention("t-closed-pr")
    end
  end

  describe "escalations get a kind" do
    test "every existing escalation is typed legacy; other kinds stay untyped", %{migration: m} do
      seed_message("m-esc", "escalation")
      seed_message("m-info", "info")
      migrate!(m)

      rows =
        Repo.query!("SELECT id, escalation_kind, resolved_at FROM messages ORDER BY id").rows

      assert rows == [["m-esc", "legacy", nil], ["m-info", nil, nil]]
    end

    test "down/0 drops the new columns", %{migration: m} do
      migrate!(m)
      Ecto.Migrator.down(Repo, @migration_id, m, log: false)

      columns = Repo.query!("SELECT name FROM pragma_table_info('messages')").rows |> List.flatten()
      refute "escalation_kind" in columns
      refute "resolved_at" in columns
    end
  end

  describe "its place in the migration order" do
    # The newest migrations main had shipped when this one was written: the
    # live install's `schema_migrations` topped out at 20260928000034 on
    # 2026-09-28, and bd-1uu19b's 20260928131352 was merged behind it.
    @already_shipped [20_260_928_000_034, 20_260_928_131_352]

    test "sorts after every migration already shipped", %{migration: m} do
      _ = Ecto.Migrator.migrated_versions(Repo, log: false)

      for version <- @already_shipped do
        Repo.query!("INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
          version,
          "2026-09-28T13:00:00"
        ])
      end

      assert :ok = Ecto.Migrator.up(Repo, @migration_id, m, log: false, strict_version_order: true)
    end
  end
end
