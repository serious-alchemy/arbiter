defmodule Arbiter.Repo.Migrations.AddNodesRegistryPublishTimeoutMsToInstallationSettings do
  @moduledoc """
  `nodes.registry.publish_timeout_ms`: how long a caller waits on an image
  publish before it stops waiting. Nullable; NULL means the 30 minute default.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_registry_publish_timeout_ms, :integer
    end
  end
end
