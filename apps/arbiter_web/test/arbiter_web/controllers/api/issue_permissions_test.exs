defmodule ArbiterWeb.Api.IssuePermissionsTest do
  @moduledoc """
  bd-54m4vv (G12): `permissions` over REST. The authority comes from the bearer
  token (`Arbiter.Guardrails.Authority.from_scope/1`), never from the body: a
  coordinator without operator proof only `request`s an operator-grant
  permission, a worker token is refused outright.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "perm-api-ws",
        prefix: "pap",
        config: %{
          "guardrails" => %{"defaults" => %{"permissions" => ["network:repo.hex.pm"]}}
        }
      })

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp operator(conn), do: bearer(conn, Scope.mint_coordinator(nil, operator: true))

  describe "POST /api/issues" do
    test "a coordinator's permissions are canonical, defaults are merged, prod_ssh is requested",
         %{conn: conn, ws: ws} do
      conn =
        post(conn, ~p"/api/issues", %{
          title: "needs reach",
          workspace_id: ws.id,
          permissions: ["tracker_write", "prod_ssh", "network:API.example.com"]
        })

      assert %{"id" => id, "permissions" => permissions} = json_response(conn, 201)

      assert permissions ==
               [
                 "network:api.example.com:443",
                 "network:repo.hex.pm:443",
                 "prod_ssh",
                 "tracker_write"
               ]

      issue = Ash.get!(Issue, id)
      assert Permissions.pending(issue) == ["prod_ssh"]
    end

    test "operator proof makes the same declaration in force", %{conn: conn, ws: ws} do
      conn =
        conn
        |> operator()
        |> post(~p"/api/issues", %{title: "ssh", workspace_id: ws.id, permissions: ["prod_ssh"]})

      assert %{"id" => id} = json_response(conn, 201)
      assert Permissions.pending(Ash.get!(Issue, id)) == []
    end

    test "a bad permission is a 422", %{conn: conn, ws: ws} do
      conn =
        post(conn, ~p"/api/issues", %{title: "x", workspace_id: ws.id, permissions: ["root"]})

      assert json_response(conn, 422)
    end

    test "a worker filing a follow-up may not declare permissions", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "own task", workspace_id: ws.id})
      token = Scope.mint_worker(parent)

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> bearer(token)
        |> post(~p"/api/issues", %{
          title: "follow-up",
          workspace_id: ws.id,
          parent_id: parent.id,
          permissions: ["tracker_write"]
        })

      assert json_response(conn, 403)
    end
  end

  describe "PATCH /api/issues/:id" do
    setup %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      %{issue: issue}
    end

    test "permissions replaces the list; add/remove edit it", %{conn: conn, issue: issue} do
      conn1 = patch(conn, ~p"/api/issues/#{issue.id}", %{permissions: ["tracker_write"]})
      assert %{"permissions" => ["tracker_write"]} = json_response(conn1, 200)

      conn2 =
        patch(conn, ~p"/api/issues/#{issue.id}", %{
          add_permissions: ["prod_read", "network:b.example.com"],
          remove_permissions: ["tracker_write"]
        })

      assert %{"permissions" => ["network:b.example.com:443", "prod_read"]} =
               json_response(conn2, 200)
    end

    test "removing phi_data needs operator proof", %{conn: conn, issue: issue} do
      patch(conn, ~p"/api/issues/#{issue.id}", %{permissions: ["phi_data"]})

      refused = patch(conn, ~p"/api/issues/#{issue.id}", %{remove_permissions: ["phi_data"]})
      assert json_response(refused, 422)
      assert Ash.get!(Issue, issue.id).permissions == ["phi_data"]

      ok =
        conn
        |> operator()
        |> patch(~p"/api/issues/#{issue.id}", %{remove_permissions: ["phi_data"]})

      assert %{"permissions" => []} = json_response(ok, 200)
    end

    test "a worker token cannot patch permissions even on its own task", %{issue: issue} do
      token = Scope.mint_worker(issue)

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> bearer(token)
        |> patch(~p"/api/issues/#{issue.id}", %{permissions: ["tracker_write"]})

      assert json_response(conn, 403)
      refute "tracker_write" in Ash.get!(Issue, issue.id).permissions
    end
  end

  describe "GET /api/issues/:id" do
    test "reports pending permissions", %{conn: conn, ws: ws} do
      created =
        post(conn, ~p"/api/issues", %{title: "p", workspace_id: ws.id, permissions: ["prod_ssh"]})

      %{"id" => id} = json_response(created, 201)

      shown = get(conn, ~p"/api/issues/#{id}")

      assert %{"permissions" => perms, "pending_permissions" => ["prod_ssh"]} =
               json_response(shown, 200)

      assert "prod_ssh" in perms
    end
  end
end
