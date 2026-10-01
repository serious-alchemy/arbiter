defmodule Arbiter.Repo.Migrations.IndexUsageEventsCastTextExpressions do
  @moduledoc """
  Expression indexes that match what AshSqlite actually emits (bd-bdjgwc).

  `Ash.Query.filter(Event, occurred_at >= ^t)` compiles to
  `CAST(occurred_at AS TEXT) >= CAST(? AS TEXT)`: ash_sql wraps both operands
  of a comparison in `type/2`, and ecto_sqlite3 renders text-stored types
  (`utc_datetime_usec`, `uuid`, `atom`) as `CAST(.. AS TEXT)`. SQLite will only
  use an index whose expression is textually the same, so the plain
  `[:occurred_at]`-style indexes never served those reads and they SCANned the
  whole ledger. (Reads through `Arbiter.Usage.LedgerRow` are plain Ecto, emit
  bare columns, and keep using the existing indexes.)

  These mirror the existing `[:provider_account_id, :occurred_at]` and
  `[:source, :occurred_at]` indexes, plus a lone `occurred_at` for the window
  scans. The CAST text of a stored value is identical to the value (they are
  already TEXT), so results are unchanged.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS usage_events_cast_occurred_at_index
    ON usage_events (CAST(occurred_at AS TEXT))
    """

    execute """
    CREATE INDEX IF NOT EXISTS usage_events_cast_provider_account_id_occurred_at_index
    ON usage_events (CAST(provider_account_id AS TEXT), CAST(occurred_at AS TEXT))
    """

    execute """
    CREATE INDEX IF NOT EXISTS usage_events_cast_source_occurred_at_index
    ON usage_events (CAST(source AS TEXT), CAST(occurred_at AS TEXT))
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS usage_events_cast_source_occurred_at_index"
    execute "DROP INDEX IF EXISTS usage_events_cast_provider_account_id_occurred_at_index"
    execute "DROP INDEX IF EXISTS usage_events_cast_occurred_at_index"
  end
end
