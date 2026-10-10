defmodule Arbiter.Repo.Migrations.AddNodesRegistryToInstallationSettings do
  @moduledoc """
  K8 (bd-9vrbx7, `docs/design/remote-workers.md` §16 K8, §11): the `nodes.registry`
  settings the primary publishes images to. All nullable; NULL registry means
  "no registry" and nothing changes. `nodes_registry_password` is a Cloak
  (`Arbiter.Vault`) ciphertext, never plaintext.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_registry, :string
      add :nodes_registry_username, :string
      add :nodes_registry_password, :binary
      add :nodes_registry_insecure, :boolean
    end
  end
end
