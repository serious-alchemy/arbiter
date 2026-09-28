defmodule Arbiter.Repo.Migrations.AdoptRunVocabularyOnWorkerRuns do
  @moduledoc """
  Ticket lifecycle 5/13 (bd-1uu19b): `worker_runs` moves onto the one run
  vocabulary (`Arbiter.Workers.RunState`), shared with the worker GenServer.

    * `kind` — `implement | review | fix_pass | conflict`, from `worker_type`
      (`main` and `impl` are both `implement`; `role` keeps the distinction,
      so it is backfilled where an older row left it NULL).
    * `state` — `starting | working | waiting | finished`.
    * `outcome` — `succeeded | failed | interrupted | handed_off`, NULL until
      the run finishes.

  | old status | state / outcome |
  |---|---|
  | running | working |
  | completed | finished / succeeded |
  | failed, review_parked, review_not_started | finished / failed |
  | interrupted | finished / interrupted |

  `status` and `worker_type` are dropped with their index; the dashboard's
  `(workspace_id, status, started_at)` index becomes
  `(workspace_id, state, started_at)`. `down/0` restores both old columns from
  the new ones (a review park comes back as `failed`).

  Hand-written, like the other lifecycle migrations (the resource snapshots
  are stale; see `20260824170000_add_refined_to_issues.exs`).
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add :kind, :text, null: false, default: "implement"
      add :state, :text, null: false, default: "starting"
      add :outcome, :text
    end

    # `execute/1` is deferred until the flush, so the backfill has to be
    # flushed before the columns it reads are dropped.
    flush()

    execute("""
    UPDATE worker_runs SET kind = CASE worker_type
      WHEN 'review' THEN 'review'
      WHEN 'fix_pass' THEN 'fix_pass'
      WHEN 'conflict' THEN 'conflict'
      ELSE 'implement'
    END
    """)

    execute("""
    UPDATE worker_runs SET role = CASE worker_type
      WHEN 'main' THEN 'base'
      ELSE worker_type
    END
    WHERE role IS NULL
    """)

    execute("""
    UPDATE worker_runs SET
      state = CASE status WHEN 'running' THEN 'working' ELSE 'finished' END,
      outcome = CASE status
        WHEN 'running' THEN NULL
        WHEN 'completed' THEN 'succeeded'
        WHEN 'interrupted' THEN 'interrupted'
        ELSE 'failed'
      END
    """)

    flush()

    execute("DROP INDEX IF EXISTS polecat_runs_workspace_id_status_started_at_index")
    execute("DROP INDEX IF EXISTS worker_runs_workspace_id_status_started_at_index")

    alter table(:worker_runs) do
      remove :status
      remove :worker_type
    end

    create index(:worker_runs, [:workspace_id, :state, :started_at])
  end

  def down do
    drop_if_exists index(:worker_runs, [:workspace_id, :state, :started_at])

    alter table(:worker_runs) do
      add :status, :text, null: false, default: "running"
      add :worker_type, :text, null: false, default: "main"
    end

    flush()

    execute("""
    UPDATE worker_runs SET status = CASE
      WHEN state != 'finished' THEN 'running'
      WHEN outcome = 'succeeded' THEN 'completed'
      WHEN outcome = 'interrupted' THEN 'interrupted'
      ELSE 'failed'
    END
    """)

    execute("""
    UPDATE worker_runs SET worker_type = CASE
      WHEN kind = 'implement' AND role = 'impl' THEN 'impl'
      WHEN kind = 'implement' THEN 'main'
      ELSE kind
    END
    """)

    flush()

    alter table(:worker_runs) do
      remove :kind
      remove :state
      remove :outcome
    end

    execute(
      "CREATE INDEX polecat_runs_workspace_id_status_started_at_index " <>
        "ON worker_runs (workspace_id, status, started_at)"
    )
  end
end
