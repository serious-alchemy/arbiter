defmodule Arbiter.Repo.Migrations.CreateEgressEvents do
  @moduledoc """
  bd-aspkyr: an append-only audit row per egress decision the worker CONNECT
  proxy (`Arbiter.Worker.Egress`) makes. `run_id` and `task_id` are plain
  text rather than foreign keys: the proxy decides before a run row is
  guaranteed to exist, and the trail must outlive the run. Additive and
  self-contained, so rollback is `drop table`, which loses only the audit
  rows. Hand-picked version: it sorts after every migration already shipped.
  """

  use Ecto.Migration

  def change do
    create table(:egress_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :run_id, :text, null: false
      add :task_id, :text
      add :host, :text, null: false
      add :port, :integer, null: false
      add :decision, :text, null: false
      add :policy_verdict, :text, null: false
      add :mode, :text, null: false
      add :reason, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:egress_events, [:run_id, :inserted_at])
    create index(:egress_events, [:task_id, :inserted_at])
  end
end
