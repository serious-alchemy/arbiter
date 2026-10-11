defmodule Arbiter.Repo.Migrations.CreateReplayRuns do
  @moduledoc """
  R15 (bd-c7lx65, `docs/design/paced-quota-routing-signals.md` §7.2-§7.3): one
  row per offline replay of a closed task, `Arbiter.Loop.ReplayRun`. Replay
  evidence is its own source: nothing here is written to `worker_runs`,
  `review_gate_rounds` or `usage_events`, so the live competence measures never
  see it. Additive and self-contained, so rollback is `drop table`.
  """

  use Ecto.Migration

  def change do
    create table(:replay_runs, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :task_id, :text, null: false
      add :workspace_id, :text
      add :repo, :text
      add :difficulty, :bigint
      add :issue_type, :text
      add :provider, :text, null: false
      add :account_id, :text
      add :model, :text, null: false
      add :pool, :text
      add :thinking, :text
      add :reviewer_provider, :text
      add :reviewer_account_id, :text
      add :reviewer_model, :text
      add :reviewer_pool, :text
      add :reviewer_thinking, :text
      add :live_provider, :text
      add :live_model, :text
      add :base_sha, :text
      add :known_good_sha, :text
      add :provenance, :text
      add :state, :text, null: false
      add :reason, :text
      add :verdict, :text
      add :converged, :boolean
      add :criteria_total, :bigint
      add :criteria_unmet, :bigint
      add :tests, :text
      add :file_overlap, :float
      add :line_overlap, :float
      add :files, {:array, :text}, null: false, default: []
      add :admission, {:array, :map}, null: false, default: []
      add :runs, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:replay_runs, [:state])
    create index(:replay_runs, [:task_id])
    create index(:replay_runs, [:provider, :model, :difficulty, :issue_type])
  end
end
