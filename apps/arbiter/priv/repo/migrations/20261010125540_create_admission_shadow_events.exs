defmodule Arbiter.Repo.Migrations.CreateAdmissionShadowEvents do
  @moduledoc """
  DC6 (bd-9ycsk4, `docs/design/provider-dynamic-concurrency.md` §10.2): one
  append-only row each time either side's admission outcome changes under
  `scheduler_admission: shadow` or `enforce` — today's plan and the scheduler
  walk, side by side, with every pool's budget. DC7's report reads it.
  Additive and self-contained, so rollback is `drop table`.
  """

  use Ecto.Migration

  def change do
    create table(:admission_shadow_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :at, :utc_datetime_usec, null: false
      add :policy, :text, null: false
      add :legacy_pick, :text
      add :walk_pick, :text
      add :agrees, :boolean, null: false
      add :comparable, :boolean, null: false
      add :cause, :text
      add :legacy, :map, null: false
      add :walk, :map, null: false
      add :budgets, {:array, :map}, null: false, default: []
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:admission_shadow_events, [:at])
  end
end
