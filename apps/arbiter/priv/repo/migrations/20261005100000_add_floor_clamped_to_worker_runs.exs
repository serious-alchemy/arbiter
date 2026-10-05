defmodule Arbiter.Repo.Migrations.AddFloorClampedToWorkerRuns do
  @moduledoc """
  Adds `worker_runs.floor_clamped` (bd-c675ny, R8 of
  `docs/design/paced-quota-routing-signals.md` §6.4): whether the routing
  floor raised the tier this run was dispatched at. A clamped dispatch did not
  get the rule the policy (or a Stage 3 canary) assigned it, so
  `Arbiter.Loop.Canary.Metrics` leaves it out of both arms.

  Nullable with no default: a row written before this column reads as `NULL`,
  which every reader treats as "not clamped".
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add(:floor_clamped, :boolean)
    end
  end

  def down do
    alter table(:worker_runs) do
      remove(:floor_clamped)
    end
  end
end
