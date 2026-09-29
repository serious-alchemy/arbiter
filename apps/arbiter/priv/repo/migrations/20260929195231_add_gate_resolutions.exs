defmodule Arbiter.Repo.Migrations.AddGateResolutions do
  @moduledoc """
  Creates `gate_resolutions` (bd-4qjl0q): the coordinator's recorded answer to
  a gate escalation — decision, reasoning, actor, timestamp — persisted against
  the task and, for a ReviewGate escalation, the round it answers.

  Before this table an escalation was terminal in the data model: the mail was
  read, the task moved on out of band, and a coordinator amendment that
  overrode a reviewer's standing finding survived only in a commit message.

  Hand-written, like the other recent migrations.
  """

  use Ecto.Migration

  def change do
    create table(:gate_resolutions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :task_id, :text, null: false
      add :workspace_id, :text
      add :gate, :text, null: false
      add :decision, :text, null: false
      add :reasoning, :text, null: false
      add :actor, :text, null: false
      add :round, :integer
      add :fix_round_attempt, :integer
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:gate_resolutions, [:task_id, :inserted_at])
    create index(:gate_resolutions, [:workspace_id, :inserted_at])
  end
end
