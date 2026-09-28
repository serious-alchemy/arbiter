defmodule Arbiter.Repo.Migrations.AddEscalationKindAndAttentionFromReviewPark do
  @moduledoc """
  Ticket lifecycle 6/13 (bd-8if9zt): typed escalation kinds, and the ReviewGate
  park moves into the ticket's attention cause. See
  `docs/design/ticket-lifecycle.md` ("Child 6").

  `messages`:

    * `escalation_kind` — `Arbiter.Messages.EscalationKind`, required on every
      new `:escalation` row. Existing escalations are backfilled `legacy`:
      they were told apart only by subject text, and guessing a kind from
      that text is exactly what this child retires.
    * `resolved_at` — when the system resolved the escalation because its
      ticket moved on (`Arbiter.Tasks.Attention.clear/2`), as opposed to a
      reader clearing it.
    * an index on `(task_ref, escalation_kind)` for the `(kind, ticket)`
      dedupe and the per-ticket resolve.

  `issues`: a ticket parked by the ReviewGate (`review_park_reason` /
  `review_parked_at`) gets that park as its `attention_cause` /
  `attention_since`, unless it already carries a cause. Only the park reasons
  `Arbiter.Tasks.ReviewPark` knows are copied: `attention_cause` is an atom
  column, and an unknown string would not load. The park columns stay (the
  legacy dual-write) until bd-36ytcl deletes them.

  Hand-written, like the other lifecycle migrations (the resource snapshots
  are stale; see `20260824170000_add_refined_to_issues.exs`).
  """

  use Ecto.Migration

  @park_reasons ~w(inconclusive reviewer_failed reviewer_timeout verdict_guard_exhausted
                   commit_gate_no_changes commit_gate_no_changes_after_non_file_fix
                   commit_gate_uncommitted empty_diff empty_net_diff head_not_pushed
                   resume_blocked review_rerun)

  def up do
    alter table(:messages) do
      add :escalation_kind, :text
      add :resolved_at, :utc_datetime_usec
    end

    create index(:messages, [:task_ref, :escalation_kind])

    # `execute/1` is deferred until the flush, so the columns must exist first.
    flush()

    execute("UPDATE messages SET escalation_kind = 'legacy' WHERE kind = 'escalation'")

    execute("""
    UPDATE issues
    SET attention_cause = review_park_reason,
        attention_since = COALESCE(review_parked_at, updated_at)
    WHERE attention_cause IS NULL
      AND review_park_reason IN (#{Enum.map_join(@park_reasons, ", ", &"'#{&1}'")})
    """)
  end

  def down do
    execute("""
    UPDATE issues
    SET attention_cause = NULL, attention_since = NULL, attention_detail = NULL
    WHERE attention_cause IN (#{Enum.map_join(@park_reasons, ", ", &"'#{&1}'")})
    """)

    flush()

    drop index(:messages, [:task_ref, :escalation_kind])

    alter table(:messages) do
      remove :escalation_kind
      remove :resolved_at
    end
  end
end
