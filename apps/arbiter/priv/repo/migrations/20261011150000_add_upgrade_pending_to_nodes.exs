defmodule Arbiter.Repo.Migrations.AddUpgradePendingToNodes do
  @moduledoc """
  bd-5v5od0: `nodes.upgrade_pending_to` — the version an operator asked the node to move to
  (`arb node upgrade`) that the node has not yet reported running. NULL when nothing is pending.
  Additive, so rollback drops the column.
  """

  use Ecto.Migration

  def up do
    alter table(:nodes) do
      add :upgrade_pending_to, :text, null: true
    end
  end

  def down do
    alter table(:nodes) do
      remove :upgrade_pending_to
    end
  end
end
