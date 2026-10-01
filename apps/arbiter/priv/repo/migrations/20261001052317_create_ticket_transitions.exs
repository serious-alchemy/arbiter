defmodule Arbiter.Repo.Migrations.CreateTicketTransitions do
  @moduledoc """
  Creates `ticket_transitions` (bd-5gkqdr; reports design v2, §4.2): one
  append-only row per change of a ticket's lifecycle `state`, the source every
  report reads state history from.

  The rows are written by two triggers on `issues`, not by Ash:

    * AshSqlite runs no action in a transaction (`can?(_, :transact)` is
      false), so a row inserted from an `after_action` hook would land in a
      write of its own: a failing insert could not roll the transition back
      (design §8 risk 5), and a crash between the two would leave the history
      short. A trigger runs inside the `UPDATE` / `INSERT` statement itself —
      the state and its row commit together or not at all.
    * It also covers every writer around Ash (the Dolt importer, a future raw
      `UPDATE`), so the invariant "a ticket's last row ends in its `state`"
      cannot be broken by a path that forgot to write one.

  The trigger names the transition from its `(from, to)` pair: the lifecycle
  table (`Arbiter.Tasks.Lifecycle`) maps each pair to exactly one transition.
  A pair outside the table (only a raw write can make one) is `unnamed`. If
  the table changes, a new migration must recreate the update trigger —
  `Arbiter.Tasks.TicketTransitionTest` fails until it does.

  `at` is the write's own clock reading: `created_at` for the creation row and
  `updated_at` for a transition (Ash stamps both in the same write), else the
  database clock for a raw write that leaves `updated_at` alone. A transition's
  `at` is never earlier than the ticket's previous row — the database clock
  only reads milliseconds, and a raw writer may hand in an old `updated_at` —
  so a ticket's rows sort by `at` in the order they were written (equal `at`s
  break by `rowid`).

  Hand-written, like the other recent migrations. Hand-picked version: it must
  sort after every migration already shipped.
  """

  use Ecto.Migration

  @now "strftime('%Y-%m-%dT%H:%M:%f', 'now') || '000Z'"

  # A UUIDv7 string: 48 bits of Unix milliseconds, version 7, the RFC variant,
  # random bits elsewhere. 'now' is fixed for the whole statement.
  @uuid_v7 """
  substr(printf('%012x', CAST(unixepoch('subsec') * 1000 AS INTEGER)), 1, 8) || '-' ||
  substr(printf('%012x', CAST(unixepoch('subsec') * 1000 AS INTEGER)), 9, 4) || '-7' ||
  substr(lower(hex(randomblob(2))), 2, 3) || '-' ||
  substr('89ab', 1 + (random() & 3), 1) || substr(lower(hex(randomblob(2))), 2, 3) || '-' ||
  lower(hex(randomblob(6)))
  """

  @transition_name """
  CASE
    WHEN NEW.state = 'queued' AND OLD.state = 'backlog' THEN 'promote'
    WHEN NEW.state = 'queued' AND OLD.state IN ('active', 'merging') THEN 'requeue'
    WHEN NEW.state = 'queued' AND OLD.state IN ('closed', 'verifying') THEN 'reopen'
    WHEN NEW.state = 'backlog' AND OLD.state IN ('queued', 'active', 'merging') THEN 'demote'
    WHEN NEW.state = 'active' AND OLD.state IN ('backlog', 'queued') THEN 'start'
    WHEN NEW.state = 'active' AND OLD.state = 'merging' THEN 'return_to_work'
    WHEN NEW.state = 'merging' AND OLD.state = 'active' THEN 'open_pr'
    WHEN NEW.state = 'verifying' AND OLD.state IN ('active', 'merging') THEN 'await_verification'
    WHEN NEW.state = 'closed' THEN 'close'
    ELSE 'unnamed'
  END
  """

  @columns "id, ticket_id, workspace_id, repo, from_state, to_state, transition, close_reason, at, source"

  def up do
    create table(:ticket_transitions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      # No foreign key: the history outlives a hard-deleted ticket.
      add :ticket_id, :text, null: false
      add :workspace_id, :text
      add :repo, :text
      add :from_state, :text
      add :to_state, :text, null: false
      add :transition, :text, null: false
      add :close_reason, :text
      add :at, :utc_datetime_usec, null: false
      add :source, :text, null: false, default: "live"
      add :origin, :text
    end

    create index(:ticket_transitions, [:ticket_id, :at])
    create index(:ticket_transitions, [:to_state, :at])
    create index(:ticket_transitions, [:workspace_id, :at])
    create unique_index(:ticket_transitions, [:ticket_id, :at, :to_state])

    execute("""
    CREATE TRIGGER ticket_transitions_on_issue_insert
    AFTER INSERT ON issues
    BEGIN
      INSERT INTO ticket_transitions (#{@columns})
      VALUES (
        #{@uuid_v7},
        NEW.id, NEW.workspace_id, NEW.repo,
        NULL, NEW.state, 'create',
        CASE WHEN NEW.state = 'closed' THEN NEW.close_reason END,
        COALESCE(NEW.created_at, #{@now}),
        'live'
      );
    END
    """)

    execute("""
    CREATE TRIGGER ticket_transitions_on_issue_state_update
    AFTER UPDATE OF state ON issues
    WHEN OLD.state IS NOT NEW.state
    BEGIN
      INSERT INTO ticket_transitions (#{@columns})
      VALUES (
        #{@uuid_v7},
        NEW.id, NEW.workspace_id, NEW.repo,
        OLD.state, NEW.state, #{@transition_name},
        CASE WHEN NEW.state = 'closed' THEN NEW.close_reason END,
        max(
          CASE
            WHEN NEW.updated_at IS NOT NULL AND NEW.updated_at IS NOT OLD.updated_at
              THEN NEW.updated_at
            ELSE #{@now}
          END,
          COALESCE((SELECT max(at) FROM ticket_transitions WHERE ticket_id = NEW.id), '')
        ),
        'live'
      );
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS ticket_transitions_on_issue_state_update")
    execute("DROP TRIGGER IF EXISTS ticket_transitions_on_issue_insert")
    drop table(:ticket_transitions)
  end
end
