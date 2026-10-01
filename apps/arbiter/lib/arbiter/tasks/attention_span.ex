defmodule Arbiter.Tasks.AttentionSpan do
  @moduledoc """
  One stretch of a ticket's attention (bd-cq1wsp, reports design v2 §4.3):
  from the moment a cause was raised — or, for a derived cause, first seen by
  `Arbiter.Tasks.AttentionSweep` — until it cleared. The history the attention
  / wait time report reads; the ticket row only holds the attention it has now.

  Written by `Arbiter.Tasks.AttentionSpans` (live capture) and
  `Arbiter.Tasks.AttentionSpanBackfill` (the one-off backfill), never by hand.

  ## Fields

    * `ticket_id`, `workspace_id`, `repo` — denormalised so a report filters
      without a join. `ticket_id` is not a foreign key: the span outlives a
      hard-deleted ticket.
    * `cause` — the attention cause, as text (a legacy ReviewGate park reason
      the backfill reads may no longer be an atom the code knows).
    * `owner` — who owned it when it opened (`Lifecycle.Attention`'s table,
      or a move already on the ticket).
    * `owner_at_close` / `owner_changed_at` — who owns it now (once closed:
      who owned it when it closed) and when that last changed by a hand-off,
      a hand-back or a sweep promotion; `owner_changed_at` is nil while it
      never moved. A report splits the span at `owner_changed_at` to separate
      coordinator time from operator time.
    * `opened_at` — a stored cause's `attention_since`; a derived cause's
      first sighting.
    * `cleared_at` / `cleared_by` — nil while open. `cleared_by`:
      `:transition` (the ticket's state moved), `:clear` (a ReviewGate park
      cleared), `:resume` (its run restarted), `:replaced` (another cause
      took its place), `:sweep_gone` (a derived cause the sweep no longer
      sees). A span the backfill rebuilt from an escalation alone has no
      `cleared_by` — the escalation only says when it was resolved.
    * `derived` — the cause was computed by `Lifecycle.View`, not stored.
    * `source` — `:live` or `:backfill`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer

  @owners [:coordinator, :operator]
  @cleared_by [:transition, :clear, :resume, :replaced, :sweep_gone]
  @sources [:live, :backfill]

  sqlite do
    table "ticket_attention_spans"
    repo Arbiter.Repo

    custom_indexes do
      index [:ticket_id, :cause, :opened_at], unique: true
      index [:workspace_id, :opened_at]
      index [:cause, :opened_at]
      index [:ticket_id, :cleared_at]
    end
  end

  actions do
    defaults [:read]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :ticket_id, :string, allow_nil?: false, public?: true
    attribute :workspace_id, :string, public?: true
    attribute :repo, :string, public?: true
    attribute :cause, :string, allow_nil?: false, public?: true

    attribute :owner, :atom do
      allow_nil? false
      public? true
      constraints one_of: @owners
    end

    attribute :owner_changed_at, :utc_datetime_usec, public?: true

    attribute :owner_at_close, :atom do
      public? true
      constraints one_of: @owners
    end

    attribute :opened_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :cleared_at, :utc_datetime_usec, public?: true

    attribute :cleared_by, :atom do
      public? true
      constraints one_of: @cleared_by
    end

    attribute :derived, :boolean, allow_nil?: false, default: false, public?: true

    attribute :source, :atom do
      allow_nil? false
      default :live
      public? true
      constraints one_of: @sources
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
