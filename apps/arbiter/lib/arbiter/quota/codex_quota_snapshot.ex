defmodule Arbiter.Quota.CodexQuotaSnapshot do
  @moduledoc """
  Append-only history of Codex quota captures (bd-afvsnc).

  `Arbiter.Quota.CodexQuota` keeps only the latest reading per account; this
  table records every capture (`captured_at`, `plan`, used percents, reset
  times, reported window lengths) so the real burn rate can be inspected and a
  plan's window length inferred from the `reset_at` jump across an actual
  reset. Written by `Arbiter.Quota.Codex.fetch/2`; read via
  `Arbiter.Quota.Codex.history/2`. Old rows are pruned on write.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Quota,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "codex_quota_snapshots"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      primary? true

      accept [
        :provider_account_id,
        :plan,
        :session_used_percent,
        :session_reset_at,
        :weekly_used_percent,
        :weekly_reset_at,
        :session_window_minutes,
        :weekly_window_minutes,
        :limit_reached,
        :captured_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :provider_account_id, :uuid, allow_nil?: false, public?: true
    attribute :plan, :string, public?: true
    attribute :session_used_percent, :float, public?: true
    attribute :session_reset_at, :utc_datetime, public?: true
    attribute :weekly_used_percent, :float, public?: true
    attribute :weekly_reset_at, :utc_datetime, public?: true
    attribute :session_window_minutes, :integer, public?: true
    attribute :weekly_window_minutes, :integer, public?: true
    attribute :limit_reached, :boolean, public?: true
    attribute :captured_at, :utc_datetime, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end
