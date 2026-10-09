defmodule Arbiter.Repo.Migrations.AddIssuePermissionsAndPermissionEvents do
  @moduledoc """
  Ticket-declared permissions (`docs/design/guardrail-profiles.md` §5.2, G12).

    * `issues.permissions` — the canonical, sorted, de-duplicated list of
      permissions the ticket declares. Not null, default `[]`: every existing
      ticket declares nothing, which is exactly today's behaviour.
    * `permission_events` — the append-only audit trail of how each permission
      got on (or off, or was proposed for) a ticket: `declared`, `defaulted`,
      `suggested`, `requested`, `granted`, `denied`, `revoked`. `issue_id` is a
      plain string, not a foreign key, like `node_events.node_id`: a removed
      ticket's history stays.

  Additive, no backfill. Safe to hot-run. Hand-written, like the other
  column additions here.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :permissions, {:array, :text}, null: false, default: []
    end

    create table(:permission_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :issue_id, :text, null: false
      add :permission, :text, null: false
      add :event, :text, null: false
      add :source, :text, null: false
      add :actor, :text
      add :reason, :text
      add :run_id, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:permission_events, [:issue_id, :inserted_at])
  end

  def down do
    drop table(:permission_events)

    alter table(:issues) do
      remove :permissions
    end
  end
end
