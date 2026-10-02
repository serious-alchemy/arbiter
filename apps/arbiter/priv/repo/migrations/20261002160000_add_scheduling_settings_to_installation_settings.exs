defmodule Arbiter.Repo.Migrations.AddSchedulingSettingsToInstallationSettings do
  @moduledoc """
  bd-73uipb (ES3, `docs/design/epic-aware-scheduling.md` §6.6): the install-wide
  knobs that shape the Ready order. Every column is nullable and NULL means
  "no override", so the order is exactly today's until an operator sets one.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :scheduling_epic_floors_enabled, :boolean
      add :scheduling_max_lifted_in_flight, :integer
      add :scheduling_finish_first, :boolean
      add :scheduling_finish_first_max_wait_hours, :integer
    end
  end
end
