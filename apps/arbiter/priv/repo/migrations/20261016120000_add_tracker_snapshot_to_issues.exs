defmodule Arbiter.Repo.Migrations.AddTrackerSnapshotToIssues do
  @moduledoc """
  Adds `issues.tracker_snapshot` (bd-evxsrx): what the tracker story said when
  Arbiter last reconciled the ticket with it — the common ancestor the claimed-
  ticket re-sync compares both sides against to tell a tracker edit from a local
  override.

  Nullable with no backfill, deliberately: `NULL` means "claimed before this was
  recorded", and the first re-sync adopts the tracker's current values without
  rewriting the ticket (we cannot know who last changed which field).
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add(:tracker_snapshot, :map)
    end
  end

  def down do
    alter table(:issues) do
      remove(:tracker_snapshot)
    end
  end
end
