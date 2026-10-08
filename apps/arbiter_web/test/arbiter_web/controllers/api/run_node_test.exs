defmodule ArbiterWeb.Api.RunNodeTest do
  @moduledoc """
  bd-1b4k9r: the run payloads — `/api/workers`, `/api/workers/:id`,
  `/api/workers/history[/:id]` and the issue's `current_run` — carry `node_id`
  and `node_name`, null for a run on the primary.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    for snap <- Worker.list_children(), do: Worker.stop(snap.registry_key)

    ws = Ash.create!(Workspace, %{name: "rn-ws-#{System.unique_integer([:positive])}"})
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

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"), ws: ws, ticket: ticket, node: node}
  end

  defp history_run(ticket, ws, attrs) do
    Ash.create!(
      Run,
      Map.merge(
        %{
          task_id: ticket.id,
          repo: "arbiter",
          workspace_id: ws.id,
          kind: :implement,
          state: :finished,
          outcome: :succeeded,
          role: "base",
          started_at: DateTime.add(DateTime.utc_now(), -600, :second),
          completed_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  test "history and run detail carry node_id/node_name; null for a local run", ctx do
    remote = history_run(ctx.ticket, ctx.ws, %{node_id: ctx.node.id})
    local = history_run(ctx.ticket, ctx.ws, %{})

    data =
      ctx.conn
      |> get(~p"/api/workers/history?#{[workspace_id: ctx.ws.id]}")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Map.new(&{&1["id"], &1})

    assert %{"node_id" => nid, "node_name" => "gpu-box"} = data[remote.id]
    assert nid == ctx.node.id

    assert %{"node_id" => nil, "node_name" => nil} =
             Map.take(data[local.id], ["node_id", "node_name"])

    one = ctx.conn |> get(~p"/api/workers/history/#{remote.id}") |> json_response(200)
    assert one["data"]["node_name"] == "gpu-box"
  end

  test "a live remote worker's list and show rows name its node; a local one is null", ctx do
    {:ok, pid} = Worker.start(task_id: ctx.ticket.id, repo: "arbiter", workspace_id: ctx.ws.id)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(pid) end)
    :ok = Worker.advance(pid, :claude)

    row = fn ->
      ctx.conn
      |> get(~p"/api/workers?#{[workspace_id: ctx.ws.id]}")
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.find(&(&1["task_id"] == ctx.ticket.id))
    end

    assert %{"node_id" => nil, "node_name" => nil} = Map.take(row.(), ["node_id", "node_name"])

    :ok = Worker.report(pid, :node_id, ctx.node.id)

    assert %{"node_id" => nid, "node_name" => "gpu-box"} = row.()
    assert nid == ctx.node.id

    shown = ctx.conn |> get(~p"/api/workers/#{ctx.ticket.id}") |> json_response(200)
    assert shown["node_name"] == "gpu-box"
    assert shown["node_id"] == ctx.node.id
  end
end
