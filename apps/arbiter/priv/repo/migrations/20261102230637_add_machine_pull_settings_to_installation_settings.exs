defmodule Arbiter.Repo.Migrations.AddMachinePullSettingsToInstallationSettings do
  @moduledoc """
  SI4 (`docs/design/remote-workers.md` §21.4, §21.6): the install-wide read credential
  a machine node may be handed for one pull of a published image
  (`nodes.registry_pull_username`, and `nodes.registry_pull_password` as a Cloak
  ciphertext), and `nodes.machine_image_source` (`auto` | `build`). All nullable:
  NULL is no pull credential, and `build` (machines keep building from a plan).
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_registry_pull_username, :string
      add :nodes_registry_pull_password, :binary
      add :nodes_machine_image_source, :string
    end
  end
end
