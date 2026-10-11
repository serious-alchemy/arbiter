defmodule Arbiter.Repo.Migrations.AddFairShareToProviderAccounts do
  @moduledoc """
  DC10 (bd-ag5nlo, `docs/design/provider-dynamic-concurrency.md` §5.3):
  workspace fair share on a shared account.

    * `provider_accounts.budget_split` — `queue` (the ES3 order alone decides,
      as today) or `fair`. Every existing account reads `queue`, so nothing
      changes until an operator opts in.
    * `workspace_provider_accounts.weight` — the workspace's fair-share weight,
      a positive integer. Every existing link reads 1, and it has no effect
      until its account is `fair`.

  Additive, so rollback drops the columns.
  """

  use Ecto.Migration

  def up do
    alter table(:provider_accounts) do
      add :budget_split, :text, null: false, default: "queue"
    end

    alter table(:workspace_provider_accounts) do
      add :weight, :bigint, null: false, default: 1
    end
  end

  def down do
    alter table(:workspace_provider_accounts) do
      remove :weight
    end

    alter table(:provider_accounts) do
      remove :budget_split
    end
  end
end
