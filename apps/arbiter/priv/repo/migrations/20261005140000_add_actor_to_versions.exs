defmodule Arbiter.Repo.Migrations.AddActorToVersions do
  @moduledoc """
  Adds `issues_versions.actor` and `dependencies_versions.actor` (bd-6i7yzq): the `Arbiter.Actor` label of whoever
  made the write, stamped by `Arbiter.PaperTrail.StampActor`. Attribution only.

  Nullable with no default: a version written before this column, or by a
  caller with no actor in scope, reads as `NULL` — "unattributed".
  """

  use Ecto.Migration

  def up do
    alter table(:issues_versions) do
      add(:actor, :text)
    end

    alter table(:dependencies_versions) do
      add(:actor, :text)
    end
  end

  def down do
    alter table(:issues_versions) do
      remove(:actor)
    end

    alter table(:dependencies_versions) do
      remove(:actor)
    end
  end
end
