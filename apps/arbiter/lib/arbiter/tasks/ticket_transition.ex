defmodule Arbiter.Tasks.TicketTransition do
  @moduledoc """
  One change of a ticket's lifecycle `state` (bd-5gkqdr; reports design v2,
  `docs/design/reports-design-v2.md` §4.2). Append-only: a row is never
  updated, and it outlives a hard-deleted ticket (no foreign key).

  Every report that needs state history — cumulative flow, stage dwell, lead
  time, epic burn-up — reads it from here, so the invariant is that a
  ticket's last row (by `at`, then insertion order) ends in its stored
  `state`.

  ## Who writes it

  Live rows (`source: "live"`) are written by two SQLite triggers on `issues`
  (migration `20261001052317_create_ticket_transitions`), not by Ash: AshSqlite
  opens no transaction around an action, so a row inserted from an Ash hook
  would be a write of its own and a failing insert could not roll the
  transition back. A trigger runs inside the state write's own statement, so
  the two commit together or not at all — a failing insert fails the
  transition (`{:error, _}` from the action, the ticket left where it was).
  It covers every writer:

    * `:create` — a `nil → backlog` row named `create`, at the ticket's
      `created_at`;
    * every named transition through `Arbiter.Tasks.Issue.Changes.Transition`
      — named by its `(from, to)` pair, which the lifecycle table maps to
      exactly one transition (so the legacy door `:promote_to_ready` records
      `promote`, `:pr_closed` records `return_to_work`), at the write's
      `updated_at`. An idempotent no-op leaves `state` alone and writes
      nothing;
    * rows written around Ash — the Dolt importer
      (`Arbiter.Tasks.DoltImport.Mapper`) and any raw `UPDATE`. A pair the
      table does not have is named `unnamed`.

  `:record` is for the writers that are not a state write: the backfill
  (`source: "backfill"` / `"backfill_reconcile"`, design §3).
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer

  @states Arbiter.Tasks.Lifecycle.states()
  @close_reasons Arbiter.Tasks.Lifecycle.close_reasons()
  @sources ~w(live backfill backfill_reconcile)

  sqlite do
    table "ticket_transitions"
    repo Arbiter.Repo

    custom_indexes do
      index [:ticket_id, :at]
      index [:to_state, :at]
      index [:workspace_id, :at]
      index [:ticket_id, :at, :to_state], unique: true
    end
  end

  code_interface do
    define :for_ticket, args: [:ticket_id]
  end

  actions do
    defaults [:read]

    # A ticket's history, oldest first.
    read :for_ticket do
      argument :ticket_id, :string, allow_nil?: false
      filter expr(ticket_id == ^arg(:ticket_id))
      prepare build(sort: [at: :asc, seq: :asc])
    end

    create :record do
      accept [
        :ticket_id,
        :workspace_id,
        :repo,
        :from_state,
        :to_state,
        :transition,
        :close_reason,
        :at,
        :source,
        :origin
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :ticket_id, :string do
      allow_nil? false
      public? true
    end

    attribute :workspace_id, :string, public?: true
    attribute :repo, :string, public?: true

    attribute :from_state, :atom do
      public? true
      constraints one_of: @states
      description "The state the ticket left; nil for the creation row."
    end

    attribute :to_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: @states
    end

    attribute :transition, :string do
      allow_nil? false
      public? true

      description """
      `create`, a `Arbiter.Tasks.Lifecycle.transitions/0` name, `unnamed` for a
      raw write outside the lifecycle table, `legacy:<action>` for a
      backfilled pre-lifecycle row, or `reconcile` for the backfill's row that
      closes a replay ending off the stored state.
      """
    end

    attribute :close_reason, :atom do
      public? true
      constraints one_of: @close_reasons
      description "Set when `to_state` is closed."
    end

    attribute :at, :utc_datetime_usec do
      allow_nil? false
      public? true
      description "The clock reading of the state write."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      default "live"
      constraints match: ~r/\A(#{Enum.join(@sources, "|")})\z/
    end

    attribute :origin, :string do
      public? true
      description "The paper trail's `change_origin`, when a backfilled row has one."
    end
  end

  calculations do
    # Insertion order: the tiebreak for two rows with the same `at` (only a
    # raw write, stamped by the millisecond database clock, can make one).
    calculate :seq, :integer, expr(fragment("rowid"))
  end
end
