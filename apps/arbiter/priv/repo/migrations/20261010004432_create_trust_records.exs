defmodule Arbiter.Repo.Migrations.CreateTrustRecords do
  @moduledoc """
  G18 (bd-7i9pxn, `docs/design/guardrail-profiles.md` §6.2–6.5): earned trust.

    * `trust_records` — one row per `(provider, model)` subject, written by
      `Arbiter.Loop.Trust` on the canary ticker: the window counts, recent
      guardrail events, round-1 quality, promotion eligibility, the last harness
      and model version, and any automatic suspension. `history` is the
      append-only list of what was done to the subject (suspended, demoted,
      version changed, promoted, confirmed, dismissed).
    * `worker_runs.harness_version` — the agent CLI's version for the run, so a
      version change can reset the subject's promotion clock.

  When this migration ran is the trust cutover (`Arbiter.Loop.Trust.cutover/0`):
  guardrail events recorded before it count against a subject but never trigger
  an automatic suspension or demotion, so the deploy does not act on history.

  Additive and self-contained: rollback drops the table and the column.
  """

  use Ecto.Migration

  def up do
    create table(:trust_records, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :provider, :text, null: false
      add :model, :text, null: false
      add :family, :text
      add :tier, :text
      add :pinned, :boolean, null: false, default: false
      add :window_days, :integer, null: false, default: 30
      add :runs, :integer, null: false, default: 0
      add :clean_runs, :integer, null: false, default: 0
      add :clean_tickets, :integer, null: false, default: 0
      add :clean_repos, :integer, null: false, default: 0
      add :critical_events, :integer, null: false, default: 0
      add :major_events, :integer, null: false, default: 0
      add :minor_events, :integer, null: false, default: 0
      add :reviewed, :integer, null: false, default: 0
      add :round1_approve_rate, :float
      add :quality, :map
      add :eligible_for, :text
      add :eligibility, :map
      add :harness_version, :text
      add :model_version, :text
      add :last_run_at, :utc_datetime_usec
      add :clock_started_at, :utc_datetime_usec
      add :tier_since, :utc_datetime_usec
      add :suspended_at, :utc_datetime_usec
      add :suspension, :map
      add :last_demoted_at, :utc_datetime_usec
      add :events_watermark, :utc_datetime_usec
      add :recent_events, {:array, :map}, null: false, default: []
      add :history, {:array, :map}, null: false, default: []
      add :computed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:trust_records, [:provider, :model])

    alter table(:worker_runs) do
      add :harness_version, :text
    end
  end

  def down do
    alter table(:worker_runs) do
      remove :harness_version
    end

    drop table(:trust_records)
  end
end
