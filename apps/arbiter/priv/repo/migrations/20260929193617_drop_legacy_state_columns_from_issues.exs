defmodule Arbiter.Repo.Migrations.DropLegacyStateColumnsFromIssues do
  @moduledoc """
  Ticket lifecycle 12/13 (bd-36ytcl): drop the columns the lifecycle
  redesign replaced. See `docs/design/ticket-lifecycle.md` ("Child 12").

    * `status` and `refined` — superseded by the stored `state` (bd-842qio),
      which every reader has used since the later children switched them;
    * `review_park_reason` / `review_parked_at` — the ReviewGate park lives
      in the ticket's `attention_cause` / `attention_since` since bd-8if9zt,
      whose migration copied every known park across.

  Nothing indexes these columns, so SQLite's `ALTER TABLE … DROP COLUMN`
  drops each in place. `state`, `close_reason` and the attention columns are
  not touched.

  `down/0` puts the columns back and refills them from `state` by the
  dual-write rule they carried until now (`closed` rows come back refined:
  whether one was refined before it closed is not recoverable, and nothing
  reads it). A park comes back from an attention cause that is a park reason.

  Hand-written, like the other lifecycle migrations (the resource snapshots
  are stale; see `20260824170000_add_refined_to_issues.exs`).
  """

  use Ecto.Migration

  @park_reasons ~w(inconclusive reviewer_failed reviewer_timeout verdict_guard_exhausted
                   commit_gate_no_changes commit_gate_no_changes_after_non_file_fix
                   commit_gate_uncommitted empty_diff empty_net_diff head_not_pushed
                   resume_blocked review_rerun)

  def up do
    alter table(:issues) do
      remove :status
      remove :refined
      remove :review_park_reason
      remove :review_parked_at
    end
  end

  def down do
    alter table(:issues) do
      add :status, :text, null: false, default: "open"
      add :refined, :boolean, default: false
      add :review_park_reason, :text
      add :review_parked_at, :utc_datetime_usec
    end

    # `execute/1` is deferred until the flush, so the columns must exist first.
    flush()

    execute("""
    UPDATE issues
    SET status = CASE state
          WHEN 'backlog' THEN 'open'
          WHEN 'queued' THEN 'open'
          WHEN 'active' THEN 'in_progress'
          WHEN 'merging' THEN 'in_progress'
          WHEN 'verifying' THEN 'awaiting_verification'
          ELSE 'closed'
        END,
        refined = CASE state WHEN 'backlog' THEN false ELSE true END
    """)

    execute("""
    UPDATE issues
    SET review_park_reason = attention_cause, review_parked_at = attention_since
    WHERE attention_cause IN (#{Enum.map_join(@park_reasons, ", ", &"'#{&1}'")})
    """)
  end
end
