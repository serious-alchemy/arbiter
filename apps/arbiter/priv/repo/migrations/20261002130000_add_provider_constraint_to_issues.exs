defmodule Arbiter.Repo.Migrations.AddProviderConstraintToIssues do
  @moduledoc """
  bd-13pqcp: a per-ticket provider constraint — `%{"require" => [...]}` or
  `%{"exclude" => [...]}` — that every path picking an implementer account
  honours (`Arbiter.Agents.ProviderConstraint`).

  One nullable column, no backfill: `NULL` is "no constraint", which is every
  ticket today, so nothing routes differently until an operator sets one.
  Additive and safe to hot-run; rollback drops the column and loses only the
  constraints set since. Written by hand, like the other column additions
  here, with a version that sorts after every migration already shipped.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :provider_constraint, :map
    end
  end

  def down do
    alter table(:issues) do
      remove :provider_constraint
    end
  end
end
