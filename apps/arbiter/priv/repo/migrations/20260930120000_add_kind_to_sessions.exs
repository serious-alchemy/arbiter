defmodule Arbiter.Repo.Migrations.AddKindToSessions do
  @moduledoc """
  bd-98oj3s (login relay 1/6): `kind` and `login_account` on `sessions`.

  `kind` is `:coordinator` (every pre-existing row and today's behaviour) or
  `:login`. The column is added `NOT NULL DEFAULT 'coordinator'`, which SQLite
  applies to existing rows; the explicit UPDATE is the backfill belt-and-braces
  for any row a driver left NULL.

  Hand-written, like every other `sessions` migration.
  """

  use Ecto.Migration

  def up do
    alter table(:sessions) do
      add :kind, :text, null: false, default: "coordinator"
      add :login_account, :text
    end

    execute("UPDATE sessions SET kind = 'coordinator' WHERE kind IS NULL OR kind = ''")
    flush()
    create index(:sessions, [:kind])
  end

  def down do
    drop index(:sessions, [:kind])

    alter table(:sessions) do
      remove :login_account
      remove :kind
    end
  end
end
