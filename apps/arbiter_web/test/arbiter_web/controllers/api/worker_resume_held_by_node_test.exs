defmodule ArbiterWeb.Api.WorkerResumeHeldByNodeTest do
  @moduledoc """
  bd-4ic681 AC3 on `POST /api/workers/:task_id/resume`, the endpoint behind
  `arb worker resume`: while a node still holds the ticket's run (a primary restart
  left its row live, and `Nodes.Recovery` has not adopted or collected it yet), the
  resume is a 409 naming the run and the node, and nothing is stopped. `"force":
  true` (`--force`, which goes over the primary's cap) does not go over it: the run's
  work is not in the home clone the resume would start from.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "api-resume-held-#{System.unique_integer([:positive])}",
        prefix: "arh#{System.unique_integer([:positive])}"
      })

    incident = ResumeSlotFixture.setup_incident(ws)

    # The endpoint is a *session* resume: it needs a captured session id.
    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: incident.a.id,
        workspace_id: ws.id,
        repo: ResumeSlotFixture.repo(),
        step: :work,
        provider: "claude",
        session_id: "sess-#{System.unique_integer([:positive])}",
        occurred_at: DateTime.utc_now()
      })

    {:ok, %{token: token}} = Nodes.mint_join_token([name: "held-node"], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)

    on_exit(fn ->
      for {pid, _} <- Nodes.Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    # What a primary restart leaves: A's run row still live on the node, and the node,
    # reconnected, told to hold it.
    {:ok, run} =
      Ash.create(Run, %{
        task_id: incident.a.id,
        task_title: "cut off on a node",
        repo: ResumeSlotFixture.repo(),
        state: :working,
        started_at: DateTime.utc_now(),
        node_id: node.id
      })

    hello = %{
      "agent_version" => "1.0.0",
      "proto" => 1,
      "caps" => %{"run_hold" => true},
      "runs" => [%{"id" => run.id, "state" => "running"}]
    }

    {:ok, _} = Nodes.Registry.attach(Nodes.get_node(node.id), self(), hello)

    Map.merge(
      %{conn: put_req_header(conn, "accept", "application/json"), ws: ws, run: run},
      incident
    )
  end

  test "a resume while a node holds the ticket's run is a 409 naming the run and the node",
       ctx do
    conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{})

    body = json_response(conn, 409)

    assert body["error"]["message"] =~
             "held — run #{ctx.run.id} of #{ctx.a.id} is still on node held-node (held); " <>
               "it is adopted or collected first"

    assert body["error"]["details"]["node"] == "held-node"
    assert Worker.whereis(ctx.a.id) == ctx.first.worker_pid
  end

  test "force: true does not go over it, and records no override", ctx do
    conn = post(ctx.conn, ~p"/api/workers/#{ctx.a.id}/resume", %{"force" => true})

    assert json_response(conn, 409)["error"]["message"] =~ "still on node held-node"
    assert Worker.whereis(ctx.a.id) == ctx.first.worker_pid
    assert ResumeSlotFixture.overrides(ctx.ws) == []
  end
end
