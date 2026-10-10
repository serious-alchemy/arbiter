defmodule Arbiter.Quota.QuotaSnapshot do
  @moduledoc """
  Append-only history of quota polls (bd-5kt9sk; design
  `docs/design/reports-design-v2.md` §9 row 12).

  `AnthropicQuota` / `CodexQuota` keep only the latest reading per account;
  this table gets one row per window per poll — `window` is the label
  `Arbiter.Quota.Gate.Snapshot` gives it (`"5h"`, `"7d"`, Codex's `"weekly"`
  ...), `utilization` a fraction, `ceiling` the pace ceiling in force at that
  moment (`Arbiter.Quota.policy_fields/2`'s `effective` value) — so
  `/reports` can chart utilization against the ceiling. `bucket` names what the
  window meters: the provider, or an Antigravity model group (bd-3qfc81, R2).

  This is the single append-only quota history: every capture path (Anthropic
  header and OAuth poll, Codex, Antigravity/CloudCode) writes it through
  `Arbiter.Quota.History.record/2`, and it serves reports, burn rate and
  calibration alike. Rows are never updated; `Arbiter.Quota.History.prune/1`
  deletes those past `config :arbiter, :quota_history, retention_days:`.
  `seats` and `budget` (bd-c1dief, DC2) record the account's seat count and the
  pool's published budget at the capture, for the seat-hour calibration
  (`Arbiter.Quota.BudgetCalibration`).

  (`codex_quota_snapshots` is a separate, Codex-only raw-column log kept for
  the plan-window pacing work, bd-afvsnc.)
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
    defaults [:read, :destroy]

    create :record do
      primary? true

      accept [
        :provider_account_id,
        :provider,
        :bucket,
        :window,
        :utilization,
        :ceiling,
        :resets_at,
        :captured_at,
        :seats,
        :budget
      ]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :provider_account_id, :uuid, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :bucket, :string, public?: true
    attribute :window, :string, allow_nil?: false, public?: true
    attribute :utilization, :float, allow_nil?: false, public?: true
    attribute :ceiling, :float, public?: true
    attribute :resets_at, :utc_datetime, public?: true
    attribute :captured_at, :utc_datetime, allow_nil?: false, public?: true

    # bd-c1dief (DC2): the seats the account held at the capture, and the
    # pool's published budget (`nil` until DC3 publishes one). Both `nil` on a
    # row captured before the columns existed.
    attribute :seats, :integer, public?: true, constraints: [min: 0]
    attribute :budget, :integer, public?: true, constraints: [min: 0]
    create_timestamp :inserted_at
  end
end
