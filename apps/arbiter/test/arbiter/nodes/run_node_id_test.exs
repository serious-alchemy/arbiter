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

  # bd-4p1vui (docs/design/remote-workers.md §10.4.5): how many of a remote run's stdout
  # bytes its Worker had processed when it left the run to the node at a graceful stop.
  test "worker_runs.stdout_offset is NULL until stored, then the byte count" do
    run =
      Ash.create!(Run, %{
        task_id: "bd-stdout-offset",
        base_task_id: "bd-stdout-offset",
        repo: "trib/repo",
        kind: :implement,
        provider: "claude",
        node_id: Ecto.UUID.generate(),
        started_at: DateTime.utc_now()
      })

    assert Ash.get!(Run, run.id).stdout_offset == nil
    assert {:ok, _} = Ash.update(run, %{stdout_offset: 12_345}, action: :update)
    assert Ash.get!(Run, run.id).stdout_offset == 12_345
  end
end
