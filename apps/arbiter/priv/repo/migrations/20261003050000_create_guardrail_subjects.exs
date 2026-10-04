defmodule Arbiter.Repo.Migrations.CreateGuardrailSubjects do
  @moduledoc """
  G11 (bd-anwb0u, `docs/design/guardrail-profiles.md` §3.1, §7.1): the
  installation's ordered subject rules. One row assigns a trust tier to every
  (provider, model) subject that `provider` / `family` / `model` (a `*` glob)
  matches; `scope` (`{workspace => [repo]}`) and `overrides` (tighten-only cap
  fields) narrow it. No rows means guardrails are off and nothing changes.
  """

  use Ecto.Migration

  def change do
    create table(:guardrail_subjects, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :position, :integer, null: false, default: 0
      add :provider, :text
      add :family, :text
      add :model, :text
      add :tier, :text, null: false
      add :scope, :map
      add :overrides, :map
      add :pinned, :boolean, null: false, default: false
      add :reason, :text
      add :updated_by, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:guardrail_subjects, [:position])
  end
end
