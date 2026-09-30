defmodule Arbiter.Repo.Migrations.AddProviderPausesToInstallationSettings do
  @moduledoc """
  bd-5ef587: persisted provider / account pauses. One JSON map on the
  installation singleton, `%{target => %{"reason", "by", "at"}}`; NULL means
  nothing is paused, so an install that never pauses behaves as before.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :provider_pauses, :map
    end
  end
end
