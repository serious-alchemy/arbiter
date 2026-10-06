defmodule Arbiter.Nodes.RunNodeIdTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Workers.Run

  test "worker_runs.node_id exists: NULL is the primary, a node id is stored" do
    attrs = %{
      task_id: "bd-nodeid",
      base_task_id: "bd-nodeid",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      started_at: DateTime.utc_now()
    }

    local = Ash.create!(Run, attrs)
    assert Ash.get!(Run, local.id).node_id == nil

    node_id = Ecto.UUID.generate()
    remote = Ash.create!(Run, Map.put(attrs, :node_id, node_id))
    assert Ash.get!(Run, remote.id).node_id == node_id
  end
end
