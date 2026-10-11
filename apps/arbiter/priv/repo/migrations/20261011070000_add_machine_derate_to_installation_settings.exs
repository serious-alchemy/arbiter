defmodule Arbiter.Repo.Migrations.AddMachineDerateToInstallationSettings do
  @moduledoc """
  bd-6w7usy (`docs/machine-derate.md`): the primary's own self-derate thresholds
  (thermal soft/hard, memory PSI, MemAvailable floor, hysteresis), one JSON object.
  Nullable; NULL means every default, so an install that never sets it derates
  by the defaults. Additive, so rollback drops the column. Written by hand, like
  the other column additions here.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :machine_derate, :map
    end
  end
end
