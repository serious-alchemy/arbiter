defmodule ArbiterWeb.Api.IssuePermissionDecisionTest do
  @moduledoc """
  bd-lozakf (G15b): `POST /api/issues/:id/permission`, what `arb ticket permit`
  wraps. The authority is the bearer token's: an operator-only binding needs an
  operator-proof token.
  """
  use ArbiterWeb.ConnCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Mailbox
  alias Arbiter.Tasks.{Issue, PermissionRequest, Permissions, Workspace}

  @guardrails %{
    "bindings" => %{
      "prod_read" => %{"grant_by" => "coordinator", "enforced_read_only" => true},
      "prod_ssh" => %{"grant_by" => "operator", "hosts" => ["prod.internal:22"]}
    }
  }

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ipd-#{System.unique_integer([:positive])}",
        prefix: "ipd",
        config: %{"guardrails" => @guardrails}
      })

    {:ok, task} = Ash.create(Issue, %{title: "needs reach", workspace_id: ws.id})
    task = put_state!(task, :active)

    for permission <- ["prod_read", "prod_ssh"],
        do: {:ok, _} = PermissionRequest.submit(task, permission, "need it", actor: "worker")

    {:ok, conn: put_req_header(conn, "accept", "application/json"), task: task}
  end

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp coordinator(conn), do: as(conn, Scope.mint_coordinator(nil))
  defp operator(conn), do: as(conn, Scope.mint_coordinator(nil, operator: true))

  test "a coordinator grants a coordinator-grant permission", %{conn: conn, task: task} do
    body =
      conn
      |> coordinator()
      |> post(~p"/api/issues/#{task.id}/permission", %{permission: "prod_read"})
      |> json_response(200)

    assert %{"decision" => "granted", "permission" => "prod_read"} = body
    assert "prod_read" in body["permissions"]
    assert body["pending_permissions"] == ["prod_ssh"]
    assert %{event: :granted} = task.id |> Permissions.events() |> List.last()
  end

  test "an operator-only binding is refused to a coordinator token", %{conn: conn, task: task} do
    body =
      conn
      |> coordinator()
      |> post(~p"/api/issues/#{task.id}/permission", %{permission: "prod_ssh"})
      |> json_response(403)

    assert body["error"]["message"] =~ "operator"
    assert "prod_ssh" in Permissions.pending(task)
  end

  test "an operator-proof token grants it", %{conn: conn, task: task} do
    body =
      conn
      |> operator()
      |> post(~p"/api/issues/#{task.id}/permission", %{permission: "prod_ssh"})
      |> json_response(200)

    assert body["decision"] == "granted"
    assert "prod_ssh" in Ash.get!(Issue, task.id).permissions
  end

  test "a denial carries its reason to the worker's inbox", %{conn: conn, task: task} do
    conn = coordinator(conn)

    assert conn
           |> post(~p"/api/issues/#{task.id}/permission", %{permission: "prod_read", deny: true})
           |> json_response(422)

    body =
      conn
      |> post(~p"/api/issues/#{task.id}/permission", %{
        permission: "prod_read",
        deny: true,
        reason: "use the dump"
      })
      |> json_response(200)

    assert body["decision"] == "denied"
    assert [%{body: text}] = Mailbox.list(to_ref: task.id, state: :any)
    assert text =~ "use the dump"
  end

  test "a worker token is refused", %{conn: conn, task: task} do
    conn
    |> as(Scope.mint_worker(task))
    |> post(~p"/api/issues/#{task.id}/permission", %{permission: "prod_read"})
    |> json_response(403)

    assert "prod_read" in Permissions.pending(task)
  end

  test "an unknown ticket is a 404", %{conn: conn} do
    conn
    |> coordinator()
    |> post(~p"/api/issues/no-such/permission", %{permission: "prod_read"})
    |> json_response(404)
  end
end
