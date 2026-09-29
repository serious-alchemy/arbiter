defmodule Arbiter.Repo.Migrations.AddSystemAlerts do
  @moduledoc """
  Ticket lifecycle 8/13 (bd-7gt8rm): system alerts. See
  `docs/design/ticket-lifecycle.md` ("Child 8").

  `system_alerts` holds one row per alert episode — a credential, quota-poll,
  overage or budget problem that is about the installation rather than a
  ticket. `key` narrows the kind (an adapter and source, a workspace, a task);
  the partial unique index keeps at most one active (uncleared) row per
  `(kind, key)`, so a repeated raise refreshes it instead of adding a second.

  Hand-written, like the other lifecycle migrations.
  """

  use Ecto.Migration

  def change do
    create table(:system_alerts, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :kind, :text, null: false
      add :key, :text, null: false
      add :workspace_id, :text
      add :subject, :text
      add :detail, :text, null: false, default: ""
      add :owner, :text, null: false, default: "operator"
      add :raised_at, :utc_datetime_usec, null: false
      add :last_raised_at, :utc_datetime_usec, null: false
      add :raise_count, :bigint, null: false, default: 1
      add :cleared_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:system_alerts, [:kind, :key],
             where: "cleared_at IS NULL",
             name: :system_alerts_one_active_per_kind_key
           )

    create index(:system_alerts, [:cleared_at, :raised_at])
  end
end
