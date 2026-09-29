defmodule ArbiterWeb.MCP.ReviewGateResolvePlugTest do
  @moduledoc """
  bd-4qjl0q over the wire: a coordinator records a gate-escalation resolution
  with `review_gate_resolve` through the real `/mcp` transport (catalog, input
  schema, handler, JSON encoding), and `review_gate_rounds_list` returns it.
  A worker token cannot record one.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rgr-plug-#{System.unique_integer([:positive])}"})

    {:ok, task} = Ash.create(Issue, %{title: "escalated", workspace_id: ws.id})

    for r <- 1..3 do
      {:ok, _} =
        Ash.create(Round, %{
          task_id: task.id,
          round: r,
          role: :review,
          verdict: :request_changes,
          findings: "VERDICT: REQUEST_CHANGES\n1. [High] r#{r}",
          finding_count: 1
        })
    end

    {:ok,
     conn: conn,
     task: task,
     coordinator_token: Scope.mint_coordinator(ws.id),
     worker_token: Scope.mint_worker(task, "shipyard")}
  end

  defp call(conn, token, name, arguments) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> post(
      "/mcp",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })
    )
    |> json_response(200)
  end

  test "a coordinator records an amendment and reads it back with the rounds", ctx do
    body =
      call(ctx.conn, ctx.coordinator_token, "review_gate_resolve", %{
        "task_id" => ctx.task.id,
        "decision" => "amend",
        "reasoning" => "heuristic need not be airtight"
      })

    assert %{"result" => result} = body
    refute result["isError"]
    assert result["structuredContent"]["resolution"]["decision"] == "amend"
    assert result["structuredContent"]["resolution"]["round"] == 3

    listed =
      build_conn()
      |> call(ctx.coordinator_token, "review_gate_rounds_list", %{"task_id" => ctx.task.id})

    assert %{"result" => %{"structuredContent" => content}} = listed
    assert content["outcome"] == "resolved"
    assert content["resolution"]["reasoning"] == "heuristic need not be airtight"
    assert length(content["rounds"]) == 3
  end

  test "a worker token cannot record a resolution", ctx do
    body =
      call(ctx.conn, ctx.worker_token, "review_gate_resolve", %{
        "task_id" => ctx.task.id,
        "decision" => "accept_as_is",
        "reasoning" => "self-approval"
      })

    assert body["error"] || get_in(body, ["result", "isError"])
    assert Resolutions.list(ctx.task.id) == []
  end
end
