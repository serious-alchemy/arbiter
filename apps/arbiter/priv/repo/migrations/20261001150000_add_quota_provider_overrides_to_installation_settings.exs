defmodule Arbiter.Repo.Migrations.AddQuotaProviderOverridesToInstallationSettings do
  @moduledoc """
  bd-i2gwwn: the install-wide override on which providers' quota the status
  bar and `/usage` show (`Arbiter.Quota.Visibility`). Two lists of quota
  provider codes, forced on and forced off; NULL means "auto-detect", so an
  install that never sets them gets the detected providers only.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :quota_providers_shown, {:array, :text}
      add :quota_providers_hidden, {:array, :text}
    end
  end
end
