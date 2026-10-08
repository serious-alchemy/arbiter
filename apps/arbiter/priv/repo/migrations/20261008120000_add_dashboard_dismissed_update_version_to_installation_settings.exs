defmodule Arbiter.Repo.Migrations.AddDashboardDismissedUpdateVersionToInstallationSettings do
  @moduledoc """
  The operator's dismissal of the dashboard's "Update to vX.Y.Z" banner: the
  release tag it was dismissed at. Nullable; NULL means nothing dismissed.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :dashboard_dismissed_update_version, :text
    end
  end
end
