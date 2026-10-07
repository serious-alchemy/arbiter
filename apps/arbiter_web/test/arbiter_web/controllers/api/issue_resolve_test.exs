defmodule ArbiterWeb.Api.IssueResolveTest do
  @moduledoc """
  bd-4qjl0q: `POST /api/issues/:id/resolve` — the REST side of recording the
  coordinator's answer to a gate escalation (`arb review resolve`).
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.ReviewGate.Resolutions
  alias Arbiter.Tasks.{Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rs-#{System.unique_integer([:positive])}", prefix: "rst"})

    {:ok, task} = Ash.create(Issue, %{title: "resolve me", workspace_id: ws.id})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), task: task}
  end

  test "records the resolution and returns it", %{conn: conn, task: task} do
    conn =
      post(conn, ~p"/api/issues/#{task.id}/resolve", %{
        decision: "amend",
        reasoning: "heuristic need not be airtight"
      })

    body = json_response(conn, 201)
    assert body["task_id"] == task.id
    assert body["decision"] == "amend"
    assert body["gate"] == "review_gate"
    assert body["reasoning"] == "heuristic need not be airtight"
    assert body["actor"] == "coordinator"
    assert is_binary(body["inserted_at"])

    assert [%{decision: :amend}] = Resolutions.list(task.id)
  end

  test "an unknown decision is refused with 422", %{conn: conn, task: task} do
    conn = post(conn, ~p"/api/issues/#{task.id}/resolve", %{decision: "overrule", reasoning: "x"})
    assert json_response(conn, 422)["error"]["message"] =~ "decision"
    assert Resolutions.list(task.id) == []
  end

  test "a missing reasoning is refused with 422", %{conn: conn, task: task} do
    conn = post(conn, ~p"/api/issues/#{task.id}/resolve", %{decision: "reject"})
    assert json_response(conn, 422)["error"]["message"] =~ "reasoning"
  end

  test "an unknown ticket is a 404", %{conn: conn} do
    conn = post(conn, ~p"/api/issues/bd-nope00/resolve", %{decision: "reject", reasoning: "x"})
    assert json_response(conn, 404)
  end
end
