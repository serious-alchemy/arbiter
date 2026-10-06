defmodule Arbiter.Repo.Migrations.AddNodesSettingsToInstallationSettings do
  @moduledoc """
  RW3 (bd-9x9os5, `docs/design/remote-workers.md` §4.3, §5.1): the install-wide
  `nodes.*` settings. Every column is nullable and NULL means "no override", so
  an install that never sets one behaves as before (no public URL, public
  exposure refused, 15 minute join-token TTL).
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_public_url, :text
      add :nodes_allow_public_endpoint, :boolean
      add :nodes_join_token_ttl_minutes, :integer
    end
  end
end
