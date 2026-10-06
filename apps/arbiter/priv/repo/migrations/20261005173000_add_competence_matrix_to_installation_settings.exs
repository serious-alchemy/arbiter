defmodule Arbiter.Repo.Migrations.AddCompetenceMatrixToInstallationSettings do
  @moduledoc """
  bd-biycyw (R6): the operator's competence-matrix override. One JSON array of rows
  on the installation singleton; NULL means "code defaults only", so an install
  that never writes it behaves as before.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :competence_matrix, {:array, :map}
    end
  end
end
