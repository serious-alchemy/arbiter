defmodule Arbiter.Repo.Migrations.AddCapabilityMatrixToInstallationSettings do
  @moduledoc """
  bd-57uzkl: the operator's capability-matrix override. One JSON array of rows
  on the installation singleton; NULL means "code defaults only", so an install
  that never writes it behaves as before.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :capability_matrix, {:array, :map}
    end
  end
end
