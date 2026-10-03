defmodule Arbiter.Repo.Migrations.AddCgroupScopesToWorkerRuns do
  @moduledoc """
  Adds `worker_runs.cgroup_scopes` (bd-6zuoo6, GitHub #265).

  Every agent spawn runs in its own transient systemd scope
  (`Arbiter.Worker.MemoryScope`), and the scope's unit name is what a kernel
  OOM line (`task_memcg=…/arb-run-<task>-<hex>.scope`) carries — so recording it
  on the run is what lets an OOM-killed process be mapped back to a task after
  the fact. One entry per spawn (a resumed / nudged run spawns again).

  Nullable and never backfilled: NULL means "this run was not spawned in a
  scope (cap disabled, host without systemd, or predates the column)".
  Additive and safe to hot-run; rollback drops the column.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add :cgroup_scopes, {:array, :text}
    end
  end

  def down do
    alter table(:worker_runs) do
      remove :cgroup_scopes
    end
  end
end
