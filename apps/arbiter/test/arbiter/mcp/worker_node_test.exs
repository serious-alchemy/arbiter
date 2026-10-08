defmodule Arbiter.MCP.WorkerNodeTest do
  @moduledoc """
  bd-1b4k9r: `worker_list`, `worker_show` and `worker_runs` carry `node_id` and
  `node_name` (nil for a run on the primary) — the same fields REST serves.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup do
    ws =
      Ash.create!(Workspace, %{
        name: "wn-ws-#{System.unique_integer([:positive])}",
        prefix: "wn#{System.unique_integer([:positive])}"
      })

    ticket = Ash.create!(Issue, %{title: "where it runs", workspace_id: ws.id})

    node =
      Ash.create!(
        Arbiter.Nodes.Node,
        %{
          name: "gpu-box",
          credential_hash: "h-#{System.unique_integer([:positive])}",
          credential_prefix: "p",
          enrolled_at: DateTime.utc_now()
        },
        action: :enroll
      )

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    %{ws: ws, ticket: ticket, node: node, coordinator: coordinator}
  end

  test "worker_list and worker_show name the node of a live remote run", ctx do
    {:ok, pid} =
      Worker.start(task_id: ctx.ticket.id, repo: "test/repo", workspace_id: ctx.ws.id)

    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(ctx.ticket.id, :normal) end)
    :ok = Worker.advance(pid, :implement)

    assert {:ok, %{workers: [local]}} = Tools.worker_list(ctx.coordinator, %{})
    assert %{node_id: nil, node_name: nil} = Map.take(local, [:node_id, :node_name])

    :ok = Worker.report(pid, :node_id, ctx.node.id)

    assert {:ok, %{workers: [remote]}} = Tools.worker_list(ctx.coordinator, %{})
    assert remote.node_id == ctx.node.id
    assert remote.node_name == "gpu-box"

    assert {:ok, shown} = Tools.worker_show(ctx.coordinator, %{"task_id" => ctx.ticket.id})
    assert shown.node_name == "gpu-box"
    assert Enum.all?(shown.runs, &Map.has_key?(&1, :node_name))
  end

  test "worker_runs carries each historical run's node", ctx do
    base = %{
      task_id: ctx.ticket.id,
      repo: "arbiter",
      workspace_id: ctx.ws.id,
      kind: :implement,
      state: :finished,
      outcome: :succeeded,
      role: "base",
      started_at: DateTime.utc_now()
    }

    remote = Ash.create!(Run, Map.put(base, :node_id, ctx.node.id))
    local = Ash.create!(Run, base)

    assert {:ok, %{runs: runs}} =
             Tools.worker_runs(ctx.coordinator, %{"task_id" => ctx.ticket.id})

    by_id = Map.new(runs, &{&1.id, &1})
    assert by_id[remote.id].node_name == "gpu-box"
    assert by_id[remote.id].node_id == ctx.node.id
    assert %{node_id: nil, node_name: nil} = Map.take(by_id[local.id], [:node_id, :node_name])
  end
end
