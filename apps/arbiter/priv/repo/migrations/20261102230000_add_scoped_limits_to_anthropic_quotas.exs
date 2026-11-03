defmodule Arbiter.Repo.Migrations.AddScopedLimitsToAnthropicQuotas do
  @moduledoc """
  The per-model `weekly_scoped` limits of `/api/oauth/usage` `limits[]`
  (bd-e0b7so, 5H C6), stored as a list of maps:
  `{scope, utilization, status, reset_at, is_active}`. They are nested windows
  of the weekly one, read by `Arbiter.Quota.Gate.Snapshot` per predicted model.
  Legacy rows hold an empty list (no scoped limit reported).
  """

  use Ecto.Migration

  def up do
    alter table(:anthropic_quotas) do
      add :scoped_limits, {:array, :map}, default: []
    end
  end

  def down do
    alter table(:anthropic_quotas) do
      remove :scoped_limits
    end
  end
end
