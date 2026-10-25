defmodule Arbiter.Repo.Migrations.AddNodesRegistryPublicOkToInstallationSettings do
  @moduledoc """
  SI12 (`docs/design/remote-workers.md` §21.9): `nodes.registry_public_ok`, the
  opt-in that lets the install-wide `nodes.registry` answer anonymous reads.
  Nullable; NULL means a registry that answers anonymously is refused.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_registry_public_ok, :boolean
    end
  end
end
