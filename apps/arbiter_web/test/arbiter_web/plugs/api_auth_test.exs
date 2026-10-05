defmodule ArbiterWeb.Plugs.ApiAuthTest do
  use ArbiterWeb.ConnCase, async: true

  alias Arbiter.MCP.Scope

  # A stable API route we can hit to test auth without caring about business logic.
  # It is one of the two `:anonymous` routes (`ArbiterWeb.ApiPolicy`).
  @test_path "/api/version"

  # These tests are about who the caller is, so start from no Authorization
  # header at all rather than ConnCase's default coordinator token.
  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp loopback_conn(conn) do
    %{conn | remote_ip: {127, 0, 0, 1}}
  end

  defp loopback_ipv6_conn(conn) do
    %{conn | remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
  end

  defp loopback_ipv4_mapped_ipv6_conn(conn) do
    # IPv4-mapped IPv6 loopback: ::ffff:127.0.0.1 = {0, 0, 0, 0, 0, 0xffff, 0x7f00, 0x0001}
    %{conn | remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}}
  end

  defp non_loopback_conn(conn) do
    %{conn | remote_ip: {10, 0, 0, 1}}
  end

  defp with_bearer(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "loopback requests" do
    test "IPv4 loopback passes without a token", %{conn: conn} do
      conn = conn |> loopback_conn() |> get(@test_path)
      assert conn.status == 200
    end

    test "IPv6 loopback passes without a token", %{conn: conn} do
      conn = conn |> loopback_ipv6_conn() |> get(@test_path)
      assert conn.status == 200
    end

    test "IPv4-mapped IPv6 loopback (::ffff:127.0.0.1) passes without a token", %{conn: conn} do
      conn = conn |> loopback_ipv4_mapped_ipv6_conn() |> get(@test_path)
      assert conn.status == 200
    end

    test "IPv4 loopback still passes with a valid token", %{conn: conn} do
      token = Scope.mint_coordinator(nil)
      conn = conn |> loopback_conn() |> with_bearer(token) |> get(@test_path)
      assert conn.status == 200
    end
  end

  describe "non-loopback without token" do
    test "returns 401 with no Authorization header", %{conn: conn} do
      conn = conn |> non_loopback_conn() |> get(@test_path)
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["error"]["message"])
    end

    test "returns 401 with a non-Bearer Authorization header", %{conn: conn} do
      conn =
        conn
        |> non_loopback_conn()
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> get(@test_path)

      assert conn.status == 401
    end
  end

  describe "non-loopback with invalid token" do
    test "returns 401 for a garbage token", %{conn: conn} do
      conn = conn |> non_loopback_conn() |> with_bearer("not-a-real-token") |> get(@test_path)
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["error"]["message"])
    end

    test "returns 401 for an expired token", %{conn: conn} do
      expired_token = Scope.mint_coordinator(nil, max_age: -1)
      conn = conn |> non_loopback_conn() |> with_bearer(expired_token) |> get(@test_path)
      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "expired"
    end
  end

  describe "non-loopback with valid token" do
    test "coordinator token allows through", %{conn: conn} do
      token = Scope.mint_coordinator(nil)
      conn = conn |> non_loopback_conn() |> with_bearer(token) |> get(@test_path)
      assert conn.status == 200
    end
  end

  describe "assigns[:mcp_scope]" do
    test "nil on anonymous loopback", %{conn: conn} do
      conn = conn |> loopback_conn() |> get(@test_path)
      assert conn.status == 200
      assert conn.assigns[:mcp_scope] == nil
    end

    test "set on loopback with a valid bearer token", %{conn: conn} do
      token = Scope.mint_coordinator(nil)
      conn = conn |> loopback_conn() |> with_bearer(token) |> get(@test_path)
      assert conn.status == 200
      assert %Scope{tier: :coordinator} = conn.assigns[:mcp_scope]
    end

    test "an invalid bearer token on loopback is rejected, not downgraded to anonymous", %{
      conn: conn
    } do
      conn = conn |> loopback_conn() |> with_bearer("garbage") |> get(@test_path)
      assert conn.status == 401
    end

    test "set on non-loopback with a valid bearer token", %{conn: conn} do
      token = Scope.mint_coordinator(nil)
      conn = conn |> non_loopback_conn() |> with_bearer(token) |> get(@test_path)
      assert conn.status == 200
      assert %Scope{tier: :coordinator} = conn.assigns[:mcp_scope]
    end
  end

  # bd-asawcq: the exact requests the coordinator confirmed on live v0.2.6
  # went through with no token at all.
  describe "anonymous loopback outside the :anonymous routes" do
    test "a ticket read is 401", %{conn: conn} do
      conn = conn |> loopback_conn() |> get("/api/issues/bd-9ck2a7")
      assert json_response(conn, 401)["error"]["message"] =~ "Bearer"
    end

    test "a workspace config PATCH is 401, not a validation error", %{conn: conn} do
      conn = conn |> loopback_conn() |> patch("/api/workspaces/default/config", %{})
      assert json_response(conn, 401)["error"]["message"] =~ "Bearer"
    end

    test "an IPv6 loopback dispatch is 401", %{conn: conn} do
      conn = conn |> loopback_ipv6_conn() |> post("/api/workers/dispatch", %{task_id: "bd-x"})
      assert conn.status == 401
    end
  end

  describe "a valid token the route's policy refuses" do
    test "is 403 with the API error shape", %{conn: conn} do
      token = Scope.mint_worker(%{id: "bd-w", workspace_id: "ws-w"})

      conn =
        conn
        |> loopback_conn()
        |> with_bearer(token)
        |> post("/api/scheduler/pause", %{})

      assert json_response(conn, 403)["error"]["message"] =~ "worker-tier"
    end
  end

  # The browser dashboard is not behind `:api`: it is served by the
  # `:browser` pipeline (session + CSRF), and needs no bearer token — but since
  # bd-3gycsz it needs a dashboard login, and loopback is not one.
  describe "the browser dashboard" do
    test "renders without any token, over loopback, once logged in", %{conn: conn} do
      conn = conn |> dashboard_login() |> loopback_conn() |> get("/")
      assert html_response(conn, 200)
    end

    test "redirects to login from loopback with no login", _ do
      conn = Phoenix.ConnTest.build_conn() |> loopback_conn() |> get("/")
      assert redirected_to(conn) == "/login"
    end
  end
end
