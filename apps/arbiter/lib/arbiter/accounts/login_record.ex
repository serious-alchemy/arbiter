defmodule Arbiter.Accounts.LoginRecord do
  @moduledoc """
  One finished dashboard login (login relay 4/6, bd-djh1yr) — the Login history
  child 6 displays.

    * `provider` / `account` — the slug the login ran for; `provider_account_id`
      is set when the account row existed or was created by the login.
    * `started_by`, `started_at`, `ended_at`, `outcome` (`:succeeded`,
      `:failed`, `:timed_out`, `:cancelled`) and a short `reason` for a miss.
    * `fingerprint` — 12 hex characters of a hash of the credential file's
      mtime and size. Never the token, never any file content.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Accounts,
    data_layer: AshSqlite.DataLayer

  @outcomes [:succeeded, :failed, :timed_out, :cancelled]

  sqlite do
    table "account_logins"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :login_id,
        :provider,
        :account,
        :provider_account_id,
        :started_by,
        :started_at,
        :ended_at,
        :outcome,
        :reason,
        :fingerprint
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :login_id, :string, public?: true

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:claude, :codex, :grok, :antigravity]
    end

    attribute :account, :string, allow_nil?: false, public?: true
    attribute :provider_account_id, :string, public?: true
    attribute :started_by, :string, public?: true
    attribute :started_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ended_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: @outcomes
    end

    attribute :reason, :string, public?: true
    attribute :fingerprint, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
