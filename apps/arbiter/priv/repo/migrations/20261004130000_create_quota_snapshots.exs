defmodule Arbiter.Repo.Migrations.CreateQuotaSnapshots do
  @moduledoc """
  bd-5kt9sk: append-only history of quota polls, one row per window, so the
  Reports page can chart utilization against the pace ceiling. Additive;
  rollback drops the table.
  """

  use Ecto.Migration

  def up do
    create table(:quota_snapshots, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_account_id, :text, null: false
      add :provider, :text, null: false
      add :window, :text, null: false
      add :utilization, :float, null: false
      add :ceiling, :float
      add :resets_at, :utc_datetime
      add :captured_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:quota_snapshots, [:provider_account_id, :window, :captured_at])
  end

  def down do
    drop table(:quota_snapshots)
  end
end
