defmodule Arbiter.Repo.Migrations.CreateCodexQuotaSnapshots do
  @moduledoc """
  bd-afvsnc: append-only history of Codex quota captures, so the burn rate can
  be inspected and each plan's window length inferred. Additive; rollback drops
  the table.
  """

  use Ecto.Migration

  def up do
    create table(:codex_quota_snapshots, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_account_id, :text, null: false
      add :plan, :text
      add :session_used_percent, :float
      add :session_reset_at, :utc_datetime
      add :weekly_used_percent, :float
      add :weekly_reset_at, :utc_datetime
      add :session_window_minutes, :integer
      add :weekly_window_minutes, :integer
      add :limit_reached, :boolean
      add :captured_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:codex_quota_snapshots, [:provider_account_id, :captured_at])
  end

  def down do
    drop table(:codex_quota_snapshots)
  end
end
