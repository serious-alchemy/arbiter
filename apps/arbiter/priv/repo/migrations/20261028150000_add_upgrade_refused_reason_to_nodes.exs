defmodule Arbiter.Repo.Migrations.AddUpgradeRefusedReasonToNodes do
  @moduledoc """
  bd-4kvxun: `nodes.upgrade_refused_reason` — why a controller refused the upgrade an operator
  asked for ("needs operator (helm)"). NULL when nothing was refused. Additive, so rollback
  drops the column.
  """

  use Ecto.Migration

  def up do
    alter table(:nodes) do
      add :upgrade_refused_reason, :text, null: true
    end
  end

  def down do
    alter table(:nodes) do
      remove :upgrade_refused_reason
    end
  end
end
