defmodule Arbiter.Test.PendingMigrations do
  @moduledoc false
  # Stands in for `Arbiter.Migrations` (`:migrations_module`) with 3 pending.
  def count_pending, do: {:ok, 3}
end
