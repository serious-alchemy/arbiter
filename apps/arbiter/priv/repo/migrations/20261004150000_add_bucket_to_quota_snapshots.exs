defmodule Arbiter.Repo.Migrations.AddBucketToQuotaSnapshots do
  @moduledoc """
  bd-3qfc81 (R2): `quota_snapshots` becomes the one append-only quota history.
  Adds the `bucket` a window belongs to (Antigravity's model groups; the
  provider name elsewhere) and the per-account time-range index. Additive;
  rollback drops the column and index.
  """

  use Ecto.Migration

  def up do
    alter table(:quota_snapshots) do
      add :bucket, :text
    end

    create index(:quota_snapshots, [:provider_account_id, :captured_at])
    create index(:quota_snapshots, [:provider_account_id, :bucket, :window, :captured_at])
  end

  def down do
    drop index(:quota_snapshots, [:provider_account_id, :bucket, :window, :captured_at])
    drop index(:quota_snapshots, [:provider_account_id, :captured_at])

    alter table(:quota_snapshots) do
      remove :bucket
    end
  end
end
