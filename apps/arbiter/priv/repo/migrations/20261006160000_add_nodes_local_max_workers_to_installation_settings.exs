defmodule Arbiter.Repo.Migrations.AddNodesLocalMaxWorkersToInstallationSettings do
  @moduledoc """
  RW7 (bd-aedh64, operator amendment): the operator's override of the primary's
  own worker cap, the `local` row of the nodes page. Nullable; NULL means "no
  override" (the install's local concurrency as it was), and 0 is a real value
  (the primary runs nothing, the nodes do).
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_local_max_workers, :integer
    end
  end
end
