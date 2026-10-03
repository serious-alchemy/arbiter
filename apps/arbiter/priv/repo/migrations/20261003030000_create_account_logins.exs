defmodule Arbiter.Repo.Migrations.CreateAccountLogins do
  @moduledoc """
  Login relay 4/6 (bd-djh1yr, epic bd-dqvv90): the Login history. One row per
  finished dashboard login — who started it, when, how it ended, and a short
  non-secret credential fingerprint (a hash of the credential file's mtime and
  size, never the token) so child 6 can show whether a login actually changed
  the credential.
  """

  use Ecto.Migration

  def change do
    create table(:account_logins, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :login_id, :text
      add :provider, :text, null: false
      add :account, :text, null: false
      add :provider_account_id, :text
      add :started_by, :text
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec, null: false
      add :outcome, :text, null: false
      add :reason, :text
      add :fingerprint, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:account_logins, [:provider, :account, :ended_at])
  end
end
