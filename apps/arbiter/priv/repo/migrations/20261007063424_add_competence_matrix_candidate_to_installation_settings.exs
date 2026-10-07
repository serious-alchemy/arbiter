defmodule Arbiter.Repo.Migrations.AddCompetenceMatrixCandidateToInstallationSettings do
  @moduledoc """
  The candidate competence matrix (bd-dde4l7), kept beside the live one
  (`competence_matrix`, bd-biycyw). `competence_matrix_candidate` is what the
  scorer ranks with in shadow only; `competence_matrix_previous` is the live
  matrix a promotion replaced, kept for rollback. NULL on both means "none",
  so an install that never writes them behaves as before.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :competence_matrix_candidate, {:array, :map}
      add :competence_matrix_previous, {:array, :map}
    end
  end
end
