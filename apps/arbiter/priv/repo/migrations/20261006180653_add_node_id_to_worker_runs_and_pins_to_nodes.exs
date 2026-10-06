defmodule Arbiter.Repo.Migrations.AddNodeIdToWorkerRunsAndPinsToNodes do
  @moduledoc """
  RW8 (bd-3igo6h, `docs/design/remote-workers.md` §13):

    * `worker_runs.node_id` — the node a run was placed on. NULL is the primary
      (every run until RW9 makes remote placement real). Not a foreign key: a
      removed node's runs keep their history, as `node_events` does.
    * `nodes.workspace_ids` — the node↔workspace pin (an allowlist). Empty means
      "any workspace"; a non-empty list means only those workspaces' runs may be
      placed on the node.

  Hand-written, like the other nodes migrations.
  """

  use Ecto.Migration

  def change do
    alter table(:worker_runs) do
      add :node_id, :uuid
    end

    create index(:worker_runs, [:node_id])

    alter table(:nodes) do
      add :workspace_ids, {:array, :text}, null: false, default: []
    end
  end
end
