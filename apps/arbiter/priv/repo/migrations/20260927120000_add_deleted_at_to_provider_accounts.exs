defmodule Arbiter.Repo.Migrations.AddDeletedAtToProviderAccounts do
  @moduledoc """
  `arb account delete` (bd-agb7ai): a nullable `deleted_at` marks an account
  soft-deleted, distinct from `merged_into_id` (which always names a
  surviving account — a delete has no survivor). No default and no backfill —
  every existing row starts outside it, so nothing already-listed changes.
  """

  use Ecto.Migration

  def up do
    alter table(:provider_accounts) do
      add :deleted_at, :utc_datetime
    end
  end

  def down do
    alter table(:provider_accounts) do
      remove :deleted_at
    end
  end
end
