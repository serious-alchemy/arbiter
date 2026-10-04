defmodule Arbiter.Repo.Migrations.CreateQuotaSamples do
  @moduledoc """
  bd-3qfc81 (R2): append-only history of every quota capture across providers
  (provider_account_id, bucket, window, used, reset, captured_at).
  """

  use Ecto.Migration

  def up do
    create table(:quota_samples, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_account_id, :text, null: false
      add :account_id, :text
      add :account, :text
      add :bucket, :text, null: false
      add :window, :text, null: false
      add :used, :float, null: false
      add :reset_at, :utc_datetime
      add :reset, :utc_datetime
      add :captured_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:quota_samples, [:provider_account_id, :captured_at])
    create index(:quota_samples, [:account, :captured_at])
    create index(:quota_samples, [:provider_account_id, :bucket, :window, :captured_at])
  end

  def down do
    drop table(:quota_samples)
  end
end
