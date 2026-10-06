defmodule ArbiterWeb.Test.UnreachableMigrations do
  @moduledoc false
  # Stands in for `Arbiter.Migrations` (`:migrations_module`) with the DB down.
  def count_pending, do: {:error, :unreachable}
end
