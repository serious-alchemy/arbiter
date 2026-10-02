defmodule Arbiter.Repo.Migrations.AddFloorPriorityToIssues do
  @moduledoc """
  bd-3e7inj (ES2, `docs/design/epic-aware-scheduling.md` §6.2): the epic
  priority floor.

  Adds a nullable `issues.floor_priority` with a `CHECK` that it is `NULL` or
  1..3 (P0 is never a floor: an incident must always beat one). Every existing
  row stays `NULL`, which means "no floor", so scheduling order is unchanged.
  "Only epics carry it" is enforced by the `:set_floor` action, not here: a
  `CHECK` on `issue_type` would turn retyping a floored epic into a constraint
  error instead of a cleared floor.

  `ADD COLUMN ... CHECK` is raw SQL because Ecto's `add/3` has no `check:`
  option and SQLite cannot add a constraint to an existing column afterwards.

  Rollback (`down`) drops the column. SQLite allows that for a column-level
  `CHECK` that references only that column, which this is, so it is a clean
  inverse that loses only the floors already set. Rolling back while the new
  code is running breaks every `Issue` read (the attribute is selected), so
  roll the release back first. The paper-trail `issues_versions` rows keep the
  old `changes` JSON either way.
  Hand-picked version: it sorts after every migration already shipped.
  """

  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE issues
      ADD COLUMN floor_priority INTEGER
      CHECK (floor_priority IS NULL OR (floor_priority >= 1 AND floor_priority <= 3))
    """
  end

  def down do
    execute "ALTER TABLE issues DROP COLUMN floor_priority"
  end
end
