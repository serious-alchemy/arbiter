defmodule Arbiter.Repo.Migrations.AddAdmissionToProviderAccounts do
  @moduledoc """
  O11 (bd-di40xs): a per-account `scheduler_admission` override.

    * `provider_accounts.admission` — `legacy`, `shadow` or `enforce`, or NULL
      to follow the installation-wide `scheduler_admission` key. Every existing
      account reads NULL, so nothing changes until an operator opts one in.

  Additive, so rollback drops the column.
  """

  use Ecto.Migration

  def up do
    alter table(:provider_accounts) do
      add :admission, :text, null: true
    end
  end

  def down do
    alter table(:provider_accounts) do
      remove :admission
    end
  end
end
