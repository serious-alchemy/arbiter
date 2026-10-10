defmodule Arbiter.Repo.Migrations.CreateWorkerPrepushSteps do
  @moduledoc """
  bd-8wdrql: `worker_prepush_steps` — one row per step of the pre-push check
  recipe (`Arbiter.Worker.PrepushCheck`) per attempt, so a run records what the
  commit gate ran before the push and `arb worker show` can list it.

  Additive: rollback drops the table.
  """

  use Ecto.Migration

  def up do
    create table(:worker_prepush_steps, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :run_id, :uuid
      add :task_id, :text
      add :attempt, :integer, null: false, default: 1
      add :position, :integer, null: false, default: 0
      add :name, :text, null: false
      add :cmd, :text
      add :scope, :text
      add :status, :text, null: false
      add :exit_status, :integer
      add :duration_ms, :bigint
      add :output, :text
      add :occurred_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:worker_prepush_steps, [:run_id, :occurred_at])
    create index(:worker_prepush_steps, [:task_id])
  end

  def down do
    drop_if_exists index(:worker_prepush_steps, [:task_id])
    drop_if_exists index(:worker_prepush_steps, [:run_id, :occurred_at])
    drop table(:worker_prepush_steps)
  end
end
