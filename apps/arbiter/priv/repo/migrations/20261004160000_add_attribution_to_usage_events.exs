defmodule Arbiter.Repo.Migrations.AddAttributionToUsageEvents do
  @moduledoc """
  Seams #4 (bd-6yi7j6): nullable `attribution` map on `usage_events`, stamped
  by `Arbiter.Usage.Attributor` at write time. Additive; existing rows stay
  NULL and no report reads the column.
  """

  use Ecto.Migration

  def up do
    alter table(:usage_events) do
      add :attribution, :map
    end
  end

  def down do
    alter table(:usage_events) do
      remove :attribution
    end
  end
end
