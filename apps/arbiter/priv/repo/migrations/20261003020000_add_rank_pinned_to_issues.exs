defmodule Arbiter.Repo.Migrations.AddRankPinnedToIssues do
  @moduledoc """
  ES6 (`docs/design/epic-aware-scheduling.md` §4, §6.3): `issues.rank_pinned`,
  set when an operator drags a card inside its band and cleared by promote,
  demote, close and reopen. A pinned card sorts first within its band.

  `NOT NULL DEFAULT 0` backfills every existing row as unpinned, so the order
  of a board nobody has dragged on since is exactly today's. Rollback drops the
  column; only the pins already set are lost.
  Hand-picked version: it sorts after every migration already shipped.
  """

  use Ecto.Migration

  def up do
    execute "ALTER TABLE issues ADD COLUMN rank_pinned INTEGER NOT NULL DEFAULT 0"
  end

  def down do
    execute "ALTER TABLE issues DROP COLUMN rank_pinned"
  end
end
