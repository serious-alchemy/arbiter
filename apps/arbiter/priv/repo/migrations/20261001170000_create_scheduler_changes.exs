defmodule Arbiter.Repo.Migrations.CreateSchedulerChanges do
  @moduledoc """
  bd-cl6zjn: an append-only audit trail of every board scheduler pause and
  resume — who (`actor`), through which surface, and when. Hand-picked
  version: it sorts after every migration already shipped.
  """

  use Ecto.Migration

  def change do
    create table(:scheduler_changes, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :paused, :boolean, null: false
      add :actor, :text
      add :surface, :text
      add :at, :utc_datetime_usec, null: false
    end

    create index(:scheduler_changes, [:at])
  end
end
