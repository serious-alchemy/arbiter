defmodule Arbiter.Guardrails.Event do
  @moduledoc """
  One guardrail event of a worker run (G17,
  `docs/design/guardrail-profiles.md` §6.1): something the earned-trust Loop
  (G18) counts against the `(provider, model)` subject that ran it.

    * `kind` — `kinds/0`; `severity` — `critical | major | minor`, assigned by
      the capture site per the §6.1 table.
    * `source` — `sources/0`: which capture path saw it.
    * `provider`/`model` — the subject, as the run reported it (either may be
      `nil` when the run had not reported a model yet).
    * `tool` — the tool the worker called, when there was one; `detail` — a
      short, redacted description (the matched command word, host, category).
    * `egress_event_id` — the `egress_events` row this event was derived from.
    * `fingerprint` — dedupes a repeat within a run (`run_id` + `fingerprint`
      is unique), so a worker looping on one denied command is one event.

  `run_id`/`task_id` are plain strings, like `egress_events`: the trail must
  outlive the run. Append-only: only `:create` and `:read` exist.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Workers,
    data_layer: AshSqlite.DataLayer

  @kinds [
    :public_upload_attempt,
    :fabricated_evidence,
    :hidden_channel_attempt,
    :credential_read,
    :self_grant_attempt,
    :unrequested_egress,
    :permission_denial
  ]
  @severities [:critical, :major, :minor]
  @sources [
    :egress,
    :evidence_integrity,
    :transcript_scan,
    :claude_permission_denials,
    :agy_permission_check,
    :bridge_audit
  ]

  @doc "Every event kind."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Every capture source."
  @spec sources() :: [atom()]
  def sources, do: @sources

  sqlite do
    table "guardrail_events"
    repo Arbiter.Repo

    custom_indexes do
      index [:run_id, :inserted_at]
      index [:task_id, :inserted_at]
      index [:provider, :model, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    create :record do
      primary? true

      accept [
        :run_id,
        :task_id,
        :provider,
        :model,
        :kind,
        :severity,
        :source,
        :tool,
        :detail,
        :egress_event_id,
        :fingerprint
      ]

      upsert? true
      upsert_identity :unique_run_fingerprint
      upsert_fields []
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :run_id, :string, allow_nil?: false, public?: true
    attribute :task_id, :string, public?: true
    attribute :provider, :string, public?: true
    attribute :model, :string, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @kinds]

    attribute :severity, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @severities]

    attribute :source, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @sources]

    attribute :tool, :string, public?: true
    attribute :detail, :string, public?: true
    attribute :egress_event_id, :string, public?: true
    attribute :fingerprint, :string, allow_nil?: false, public?: true

    create_timestamp :inserted_at, public?: true
  end

  identities do
    identity :unique_run_fingerprint, [:run_id, :fingerprint]
  end
end
