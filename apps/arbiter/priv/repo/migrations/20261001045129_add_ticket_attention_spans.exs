defmodule Arbiter.Repo.Migrations.AddTicketAttentionSpans do
  @moduledoc """
  Creates `ticket_attention_spans` (bd-cq1wsp, reports design v2 §4.3): one
  row per stretch of a ticket's attention — the cause, who owned it when it
  opened and when it closed, and what cleared it — so the attention / wait
  time report has a history to read. The ticket row only ever holds the
  attention it has now, and a derived cause (`merge_blocked` from a dead
  Watchdog, `run_crashed`, …) is recorded nowhere else.

  `ticket_id` is not a foreign key: a span outlives a hard-deleted ticket.
  The unique `(ticket_id, cause, opened_at)` is what makes the one-off
  backfill (`Arbiter.Tasks.AttentionSpanBackfill`) idempotent — a stored
  cause's span opens at its `attention_since`, which the paper trail records
  too, so a span live capture already wrote is not written again.

  Hand-written, like the other recent migrations.
  """

  use Ecto.Migration

  def change do
    create table(:ticket_attention_spans, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :ticket_id, :text, null: false
      add :workspace_id, :text
      add :repo, :text
      add :cause, :text, null: false
      add :owner, :text, null: false
      add :owner_changed_at, :utc_datetime_usec
      add :owner_at_close, :text
      add :opened_at, :utc_datetime_usec, null: false
      add :cleared_at, :utc_datetime_usec
      add :cleared_by, :text
      add :derived, :boolean, null: false, default: false
      add :source, :text, null: false, default: "live"
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:ticket_attention_spans, [:ticket_id, :cause, :opened_at])
    create index(:ticket_attention_spans, [:workspace_id, :opened_at])
    create index(:ticket_attention_spans, [:cause, :opened_at])
    create index(:ticket_attention_spans, [:ticket_id, :cleared_at])
  end
end
