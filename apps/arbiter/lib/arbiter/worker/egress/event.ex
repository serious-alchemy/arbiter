defmodule Arbiter.Worker.Egress.Event do
  @moduledoc """
  One audit row per egress decision (bd-aspkyr): which run and task asked for
  which `host:port`, what the proxy did (`decision`), what the policy said
  (`policy_verdict`), the `mode` the run was in, and why (`reason`).

  `decision` and `policy_verdict` differ only in learn mode, where a
  `policy_verdict` of `:deny` is allowed through and logged as the rows the
  operator should look at before turning enforcement on. Append-only.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Workers,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "egress_events"
    repo Arbiter.Repo

    custom_indexes do
      index [:run_id, :inserted_at]
      index [:task_id, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:run_id, :task_id, :host, :port, :decision, :policy_verdict, :mode, :reason]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :run_id, :string, allow_nil?: false, public?: true
    attribute :task_id, :string, public?: true
    attribute :host, :string, allow_nil?: false, public?: true
    attribute :port, :integer, allow_nil?: false, public?: true

    attribute :decision, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:allow, :deny]]

    attribute :policy_verdict, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:allow, :deny]]

    attribute :mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:learn, :enforce]]

    attribute :reason, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [
        one_of: [
          :baseline,
          :grant,
          :public_upload,
          :not_granted,
          :invalid_target,
          :dial_blocked
        ]
      ]

    create_timestamp :inserted_at
  end
end
