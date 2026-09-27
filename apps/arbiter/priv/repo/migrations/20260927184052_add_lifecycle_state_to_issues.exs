defmodule Arbiter.Repo.Migrations.AddLifecycleStateToIssues do
  @moduledoc """
  Ticket lifecycle 1/13 (bd-842qio): adds the stored lifecycle columns to
  `issues` and backfills every existing row. The model is in
  `docs/design/ticket-lifecycle.md`.

    * `state` — `backlog | queued | active | merging | verifying | closed`,
      non-null. New rows default to `backlog`.
    * `close_reason` — `completed | wont_do | duplicate`; null unless closed.
    * `rank` — the manual order inside a priority band, in creation order per
      workspace, spaced 1024 apart so a later drag-to-rank can drop a ticket
      between two neighbours by writing one row.

  The backfill reads the legacy columns, which stay authoritative for every
  consumer until the later children switch them over (see
  `Arbiter.Tasks.Lifecycle.legacy_state/1`, the same rule in code):

  | existing row | state | other |
  |---|---|---|
  | open, refined false | backlog | |
  | open, refined true | queued | |
  | in_progress with `pr_ref` or a non-empty `pending_merge` | merging | |
  | other in_progress | active | |
  | awaiting_verification | verifying | |
  | closed | closed | `close_reason: completed` |

  Every row that already closed is recorded as `completed`: nothing on the row
  says otherwise, and no earlier close could have said "won't do".

  Hand-written: this repo's `priv/resource_snapshots/` are stale enough that
  `mix ash_sqlite.generate_migrations` emits a large destructive diff (see
  `20260824170000_add_refined_to_issues.exs`).
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :state, :text, null: false, default: "backlog"
      add :close_reason, :text
      add :rank, :integer, null: false, default: 0
    end

    execute("""
    UPDATE issues SET state = CASE
      WHEN status = 'closed' THEN 'closed'
      WHEN status = 'awaiting_verification' THEN 'verifying'
      WHEN status = 'in_progress'
           AND ((pr_ref IS NOT NULL AND TRIM(pr_ref) != '')
                OR (pending_merge IS NOT NULL
                    AND TRIM(pending_merge) NOT IN ('', '{}', 'null')))
        THEN 'merging'
      WHEN status = 'in_progress' THEN 'active'
      WHEN status = 'open' AND refined = 1 THEN 'queued'
      ELSE 'backlog'
    END
    """)

    execute("UPDATE issues SET close_reason = 'completed' WHERE status = 'closed'")

    # Creation order within each workspace — the order the Ready column already
    # uses inside a priority band (priority, then age).
    execute("""
    UPDATE issues SET rank = (
      SELECT ranked.position * 1024
      FROM (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY workspace_id ORDER BY created_at, id) AS position
        FROM issues
      ) AS ranked
      WHERE ranked.id = issues.id
    )
    """)
  end

  def down do
    alter table(:issues) do
      remove :rank
      remove :close_reason
      remove :state
    end
  end
end
