defmodule Arbiter.Repo.Migrations.AddDashboardDismissedDeployToInstallationSettings do
  @moduledoc """
  The operator's dismissal of the dashboard's deploy-outcome banner: the key of the
  deploy record it was dismissed at (tag + finish time). Nullable; NULL means
  nothing dismissed.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :dashboard_dismissed_deploy, :text
    end
  end
end
