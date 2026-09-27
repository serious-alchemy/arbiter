defmodule Arbiter.Repo.Migrations.AddIssuesVersionsVersionInsertedAtIndex do
  @moduledoc """
  Adds an index on issues_versions(version_inserted_at) to improve the
  performance of the /audit page, which sorts versions by this column.
  """

  use Ecto.Migration

  def up do
    create index(:issues_versions, [:version_inserted_at],
             name: "issues_versions_version_inserted_at_index"
           )
  end

  def down do
    drop_if_exists index(:issues_versions, [:version_inserted_at],
                     name: "issues_versions_version_inserted_at_index"
                   )
  end
end
