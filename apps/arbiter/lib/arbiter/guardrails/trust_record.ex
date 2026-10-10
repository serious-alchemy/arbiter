defmodule Arbiter.Guardrails.TrustRecord do
  @moduledoc """
  One subject's earned-trust record (G18, `docs/design/guardrail-profiles.md`
  §6.2–6.5): what `Arbiter.Loop.Trust` folded from `guardrail_events` and
  `Arbiter.Loop.SubjectStats` for the `(provider, model)` pair.

    * `tier` / `pinned` — the subject rule's tier and pin at the last fold
      (`nil` tier when no rule is configured: guardrails are off).
    * window counts — `runs` (main implementer runs in the promotion window),
      `clean_runs` / `clean_tickets` / `clean_repos` (§6.2), and the
      `critical_events` / `major_events` / `minor_events` of the 30-day window;
    * round-1 quality — `reviewed`, `round1_approve_rate`, and `quality` per
      difficulty band with the incumbent it is measured against (§6.3);
    * `eligible_for` / `eligibility` — the next tier when every §6.3 threshold
      holds, and each criterion with what it needs and has;
    * `harness_version` / `model_version` — the last run's agent CLI version and
      the model id it reported; a change resets `clock_started_at`, never the tier;
    * `suspended_at` / `suspension` — an automatic suspension after a critical
      event, until the coordinator confirms or dismisses it;
    * `history` — what was done to the subject, oldest first, each entry with
      its `actor`.

  Written only by `Arbiter.Loop.Trust`; there is no destroy action.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Guardrails.Subjects,
    data_layer: AshSqlite.DataLayer

  @fields [
    :provider,
    :model,
    :family,
    :tier,
    :pinned,
    :window_days,
    :runs,
    :clean_runs,
    :clean_tickets,
    :clean_repos,
    :critical_events,
    :major_events,
    :minor_events,
    :reviewed,
    :round1_approve_rate,
    :quality,
    :eligible_for,
    :eligibility,
    :harness_version,
    :model_version,
    :last_run_at,
    :clock_started_at,
    :tier_since,
    :suspended_at,
    :suspension,
    :last_demoted_at,
    :events_watermark,
    :recent_events,
    :history,
    :computed_at
  ]

  sqlite do
    table "trust_records"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @fields
    end

    update :update do
      primary? true
      require_atomic? false
      accept @fields -- [:provider, :model]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :model, :string, allow_nil?: false, public?: true
    attribute :family, :string, public?: true

    attribute :tier, :atom,
      public?: true,
      constraints: [one_of: [:quarantine, :probation, :trusted, :privileged]]

    attribute :pinned, :boolean, allow_nil?: false, default: false, public?: true
    attribute :window_days, :integer, allow_nil?: false, default: 30, public?: true
    attribute :runs, :integer, allow_nil?: false, default: 0, public?: true
    attribute :clean_runs, :integer, allow_nil?: false, default: 0, public?: true
    attribute :clean_tickets, :integer, allow_nil?: false, default: 0, public?: true
    attribute :clean_repos, :integer, allow_nil?: false, default: 0, public?: true
    attribute :critical_events, :integer, allow_nil?: false, default: 0, public?: true
    attribute :major_events, :integer, allow_nil?: false, default: 0, public?: true
    attribute :minor_events, :integer, allow_nil?: false, default: 0, public?: true
    attribute :reviewed, :integer, allow_nil?: false, default: 0, public?: true
    attribute :round1_approve_rate, :float, public?: true
    attribute :quality, :map, public?: true

    attribute :eligible_for, :atom,
      public?: true,
      constraints: [one_of: [:probation, :trusted, :privileged]]

    attribute :eligibility, :map, public?: true
    attribute :harness_version, :string, public?: true
    attribute :model_version, :string, public?: true
    attribute :last_run_at, :utc_datetime_usec, public?: true
    attribute :clock_started_at, :utc_datetime_usec, public?: true
    attribute :tier_since, :utc_datetime_usec, public?: true
    attribute :suspended_at, :utc_datetime_usec, public?: true
    attribute :suspension, :map, public?: true
    attribute :last_demoted_at, :utc_datetime_usec, public?: true
    attribute :events_watermark, :utc_datetime_usec, public?: true
    attribute :recent_events, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :history, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :computed_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  identities do
    identity :unique_subject, [:provider, :model]
  end
end
