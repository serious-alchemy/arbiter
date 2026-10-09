defmodule Arbiter.Repo.Migrations.CreateGuardrailEvents do
  @moduledoc """
  G17 (`docs/design/guardrail-profiles.md` §6.1): an append-only row per
  guardrail event a worker run produced. `run_id`/`task_id` are plain text, not
  foreign keys, like `egress_events`: the trail outlives the run.
  `(run_id, fingerprint)` is unique so a repeat within a run is one event.
  Additive and self-contained, so rollback is `drop table`.
  """

  use Ecto.Migration

  def change do
    create table(:guardrail_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :run_id, :text, null: false
      add :task_id, :text
      add :provider, :text
      add :model, :text
      add :kind, :text, null: false
      add :severity, :text, null: false
      add :source, :text, null: false
      add :tool, :text
      add :detail, :text
      add :egress_event_id, :text
      add :fingerprint, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:guardrail_events, [:run_id, :fingerprint])
    create index(:guardrail_events, [:run_id, :inserted_at])
    create index(:guardrail_events, [:task_id, :inserted_at])
    create index(:guardrail_events, [:provider, :model, :inserted_at])
  end
end
