defmodule Arbiter.Quota.QuotaSnapshot do
  @moduledoc """
  Append-only history of quota polls (bd-5kt9sk; design
  `docs/design/reports-design-v2.md` §9 row 12).

  `AnthropicQuota` / `CodexQuota` keep only the latest reading per account;
  this table gets one row per window per poll — `window` is the label
  `Arbiter.Quota.Gate.Snapshot` gives it (`"5h"`, `"7d"`, Codex's `"weekly"`
  ...), `utilization` a fraction, `ceiling` the pace ceiling in force at that
  moment (`Arbiter.Quota.policy_fields/2`'s `effective` value) — so
  `/reports` can chart utilization against the ceiling. Written by
  `Arbiter.Quota.History.record/2`; rows are never updated or pruned.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Quota,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "quota_snapshots"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :provider_account_id,
        :provider,
        :window,
        :utilization,
        :ceiling,
        :resets_at,
        :captured_at
      ]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :provider_account_id, :uuid, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :window, :string, allow_nil?: false, public?: true
    attribute :utilization, :float, allow_nil?: false, public?: true
    attribute :ceiling, :float, public?: true
    attribute :resets_at, :utc_datetime, public?: true
    attribute :captured_at, :utc_datetime, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end
