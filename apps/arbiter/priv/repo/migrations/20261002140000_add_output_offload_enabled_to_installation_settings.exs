defmodule Arbiter.Repo.Migrations.AddOutputOffloadEnabledToInstallationSettings do
  @moduledoc """
  bd-16ljft: the operator switch for `Arbiter.Workers.OutputOffload`. NULL (and
  false) mean the sweeper stays off; only an explicit true turns it on.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :output_offload_enabled, :boolean
    end
  end
end
