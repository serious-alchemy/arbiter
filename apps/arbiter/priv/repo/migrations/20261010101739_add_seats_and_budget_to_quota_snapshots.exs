defmodule Arbiter.Repo.Migrations.AddSeatsAndBudgetToQuotaSnapshots do
  @moduledoc """
  bd-c1dief (DC2 of `docs/design/provider-dynamic-concurrency.md`): two columns
  on the append-only `quota_snapshots` history.

    * `seats` — how many seats the account held when the capture was taken
      (`Arbiter.Quota.History.record/2`). The seat-hour calibration
      (`Arbiter.Quota.BudgetCalibration`) integrates it between captures.
    * `budget` — the published budget for the pool at the capture. Nothing
      publishes one until DC3 (`Arbiter.Quota.Budget`), so it stays `NULL` until then.

  Both are nullable and additive: a row captured before this migration has
  neither, and the calibration reconstructs its seats from `worker_runs`.
  Rollback drops the columns.
  """

  use Ecto.Migration

  def up do
    alter table(:quota_snapshots) do
      add :seats, :bigint
      add :budget, :bigint
    end
  end

  def down do
    alter table(:quota_snapshots) do
      remove :budget
      remove :seats
    end
  end
end
