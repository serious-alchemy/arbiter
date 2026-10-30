defmodule ArbiterWeb.Api.IssueAcceptanceLintTest do
  @moduledoc "#1146: REST create/update return acceptance-lint warnings; `no_lint` suppresses."
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}

  @bad "- After deploy, the dashboard shows it"

  setup %{conn: conn} do
    {:ok, ws} = Ash.create(Workspace, %{name: "lint-api-ws", prefix: "lia"})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  test "create warns, and no_lint suppresses", %{conn: conn, ws: ws} do
    body = %{"title" => "a", "workspace_id" => ws.id, "acceptance" => @bad}

    resp = conn |> post("/api/issues", body) |> json_response(201)
    assert [w] = resp["warnings"]
    assert w =~ "deployment_notes"

    resp =
      conn
      |> post("/api/issues", Map.merge(body, %{"title" => "b", "no_lint" => true}))
      |> json_response(201)

    refute Map.has_key?(resp, "warnings")
  end

  test "update warns, and no_lint suppresses", %{conn: conn, ws: ws} do
    {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})

    resp = conn |> patch("/api/issues/#{issue.id}", %{"acceptance" => @bad}) |> json_response(200)
    assert [w] = resp["warnings"]
    assert w =~ "deployment_notes"

    resp =
      conn
      |> patch("/api/issues/#{issue.id}", %{"acceptance" => @bad, "no_lint" => true})
      |> json_response(200)

    refute Map.has_key?(resp, "warnings")
  end
end
