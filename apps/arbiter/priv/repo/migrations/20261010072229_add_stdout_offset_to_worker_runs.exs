defmodule Arbiter.Repo.Migrations.AddStdoutOffsetToWorkerRuns do
  @moduledoc """
  Worker adoption across a primary restart (bd-4p1vui;
  `docs/design/remote-workers.md` §10.4.5).

  `worker_runs` gains `stdout_offset`: how many of a remote run's stdout bytes its
  Worker had processed when it left the run to the node at a graceful stop. A new
  Worker that adopts the run starts its stream there, so nothing is delivered twice.

  Nullable, no backfill: only a Worker leaving a live remote run writes it. Safe to
  hot-run. Written by hand, like the other column additions here.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add :stdout_offset, :bigint
    end
  end

  def down do
    alter table(:worker_runs) do
      remove :stdout_offset
    end
  end
end
