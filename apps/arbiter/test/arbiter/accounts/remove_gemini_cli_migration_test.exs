defmodule Arbiter.Accounts.RemoveGeminiCliMigrationTest do
  @moduledoc """
  bd-ac53wz: the upstream Gemini CLI provider (`gemini_cli`) is dropped. The
  migration removes every `gemini_cli` provider account together with its
  workspace joins, credentials and Cloud Code quota rows, and leaves
  `usage_events` alone so the spend history stays readable.

  Run against a throwaway database, like the other account migration tests:
  the suite's own `Arbiter.Repo` has already been migrated and cannot
  exercise the migration's own SQL.
  """
  use ExUnit.Case, async: false

  alias Arbiter.RekeyMigrationRepo, as: Repo

  @migration_id 20_260_927_170_000
  @migration_file "priv/repo/migrations/20260927170000_remove_gemini_cli_provider.exs"

  setup_all do
    [{module, _}] = Code.require_file(@migration_file, File.cwd!())
    {:ok, migration: module}
  end

  setup %{migration: migration} do
    path =
      Path.join(
        System.tmp_dir!(),
        "arbiter_rmgem_#{Arbiter.TestDbPartition.suffix()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Repo, database: path, pool_size: 1, log: false})
    on_exit(fn -> for f <- [path, path <> "-wal", path <> "-shm"], do: File.rm(f) end)

    create_schema()

    {:ok, migration: migration}
  end

  test "removes the gemini_cli account with its joins, credentials and quota rows", %{
    migration: migration
  } do
    gemini = uuid()
    antigravity = uuid()
    claude = uuid()
    insert_account(gemini, "gemini_cli")
    insert_account(antigravity, "antigravity")
    insert_account(claude, "claude")

    ws = uuid()
    link(ws, "gemini_cli", gemini)
    link(ws, "antigravity", antigravity)
    link(ws, "claude", claude)

    insert_credential(gemini, "GEMINI_API_KEY")
    insert_credential(claude, "CLAUDE_CODE_OAUTH_TOKEN")

    insert_cloud_code_quota(gemini, "gemini_cli")
    insert_cloud_code_quota(antigravity, "antigravity")

    migrate!(migration)

    assert query("SELECT provider FROM provider_accounts ORDER BY provider") ==
             [["antigravity"], ["claude"]]

    assert query("SELECT provider FROM workspace_provider_accounts ORDER BY provider") ==
             [["antigravity"], ["claude"]]

    assert query("SELECT provider_account_id FROM provider_credentials") == [[claude]]
    assert query("SELECT provider FROM cloud_code_quotas") == [["antigravity"]]
  end

  test "removes every gemini_cli account, not only the default one", %{migration: migration} do
    default = uuid()
    merged = uuid()
    insert_account(default, "gemini_cli", "default")
    insert_account(merged, "gemini_cli", "work", default)

    migrate!(migration)

    assert query("SELECT count(*) FROM provider_accounts") == [[0]]
  end

  test "leaves historical usage_events rows readable, verbatim", %{migration: migration} do
    gemini = uuid()
    insert_account(gemini, "gemini_cli")
    ev = uuid()
    insert_usage_event(ev, "gemini_cli", gemini, 0.42)

    migrate!(migration)

    assert query("SELECT id, provider, provider_account_id, cost_usd FROM usage_events") ==
             [[ev, "gemini_cli", gemini, 0.42]]
  end

  test "down/0 is a no-op (the removed rows are not restorable)", %{migration: migration} do
    insert_account(uuid(), "gemini_cli")

    migrate!(migration)
    Ecto.Migrator.down(Repo, @migration_id, migration, log: false)

    assert query("SELECT count(*) FROM provider_accounts") == [[0]]
  end

  # ---- helpers ------------------------------------------------------------

  defp migrate!(migration), do: Ecto.Migrator.up(Repo, @migration_id, migration, log: false)

  defp query(sql), do: Repo.query!(sql).rows

  defp uuid, do: Ecto.UUID.generate()

  defp insert_account(id, provider, slug \\ "default", merged_into_id \\ nil) do
    Repo.query!(
      """
      INSERT INTO provider_accounts (id, provider, slug, identity_source, quota_config, enabled,
                                     merged_into_id, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, 'operator', '{}', 1, ?4, '2026-09-01 00:00:00', '2026-09-01 00:00:00')
      """,
      [id, provider, slug, merged_into_id]
    )
  end

  defp link(workspace_id, provider, account_id) do
    Repo.query!(
      "INSERT INTO workspace_provider_accounts (id, workspace_id, provider, provider_account_id) VALUES (?1, ?2, ?3, ?4)",
      [uuid(), workspace_id, provider, account_id]
    )
  end

  defp insert_credential(account_id, env_var) do
    Repo.query!(
      """
      INSERT INTO provider_credentials (id, provider_account_id, kind, env_var, encrypted_secret,
                                        fingerprint, active, created_at)
      VALUES (?1, ?2, 'api_key', ?3, x'00', 'fp', 1, '2026-09-01 00:00:00')
      """,
      [uuid(), account_id, env_var]
    )
  end

  defp insert_cloud_code_quota(account_id, provider) do
    Repo.query!(
      """
      INSERT INTO cloud_code_quotas (id, provider_account_id, provider, captured_at, inserted_at,
                                     updated_at)
      VALUES (?1, ?2, ?3, '2026-09-01 00:00:00', '2026-09-01 00:00:00', '2026-09-01 00:00:00')
      """,
      [uuid(), account_id, provider]
    )
  end

  defp insert_usage_event(id, provider, account_id, cost) do
    Repo.query!(
      """
      INSERT INTO usage_events (id, step, provider, provider_account_id, cost_usd, occurred_at,
                                inserted_at, updated_at)
      VALUES (?1, 'work', ?2, ?3, ?4, '2026-09-01 00:00:00', '2026-09-01 00:00:00',
              '2026-09-01 00:00:00')
      """,
      [id, provider, account_id, cost]
    )
  end

  defp create_schema do
    [
      """
      CREATE TABLE provider_accounts (
        id TEXT NOT NULL PRIMARY KEY, provider TEXT NOT NULL, slug TEXT NOT NULL, label TEXT,
        plan TEXT, provider_account_ref TEXT, provider_org_ref TEXT, identity_source TEXT NOT NULL,
        identity_verified_at TEXT, max_concurrent INTEGER, quota_config TEXT, enabled BOOLEAN NOT NULL,
        merged_into_id TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT)
      """,
      """
      CREATE TABLE workspace_provider_accounts (
        id TEXT NOT NULL PRIMARY KEY, workspace_id TEXT NOT NULL, provider TEXT NOT NULL,
        provider_account_id TEXT NOT NULL, share INTEGER)
      """,
      """
      CREATE TABLE provider_credentials (
        id TEXT NOT NULL PRIMARY KEY, provider_account_id TEXT NOT NULL, kind TEXT NOT NULL,
        env_var TEXT NOT NULL, encrypted_secret BLOB NOT NULL, fingerprint TEXT NOT NULL,
        active INTEGER NOT NULL, scopes TEXT, created_at TEXT NOT NULL, retired_at TEXT)
      """,
      """
      CREATE TABLE cloud_code_quotas (
        id TEXT NOT NULL PRIMARY KEY, provider_account_id TEXT NOT NULL, provider TEXT NOT NULL,
        plan TEXT, message TEXT, used_percent REAL, reset_at TEXT, snapshot TEXT,
        captured_at TEXT NOT NULL, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)
      """,
      """
      CREATE TABLE usage_events (
        id TEXT NOT NULL PRIMARY KEY, step TEXT NOT NULL, provider TEXT, provider_account_id TEXT,
        cost_usd NUMERIC, occurred_at TEXT NOT NULL, inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL)
      """
    ]
    |> Enum.each(&Repo.query!/1)
  end
end
