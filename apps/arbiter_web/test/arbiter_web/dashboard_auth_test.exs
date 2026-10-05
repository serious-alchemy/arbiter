defmodule ArbiterWeb.DashboardAuthTest do
  # Not async: flips app env (the allowlist) and shares the token table.
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArbiterWeb.DashboardAuth.LoginTokens

  # What a request through `tailscale serve` looks like to us: from 127.0.0.1,
  # carrying the identity and forwarding headers serve injects.
  defp via_serve(conn, login) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("tailscale-user-login", login)
    |> put_req_header("x-forwarded-for", "100.101.102.103")
    |> put_req_header("x-forwarded-proto", "https")
  end

  defp anonymous, do: build_conn()

  setup do
    previous = Application.get_env(:arbiter_web, :dashboard_tailscale_logins)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:arbiter_web, :dashboard_tailscale_logins)
  defp restore(v), do: Application.put_env(:arbiter_web, :dashboard_tailscale_logins, v)

  describe "unauthenticated browser access" do
    test "every :browser route redirects to the login page" do
      for path <- ["/", "/tasks", "/providers", "/settings", "/about", "/sessions/x/transcript"] do
        conn = get(anonymous(), path)
        assert redirected_to(conn) == "/login", "#{path} was served without a login"
      end
    end

    test "a proxied request from 127.0.0.1 is not trusted for being loopback" do
      conn = anonymous() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> get("/")
      assert redirected_to(conn) == "/login"

      conn =
        anonymous()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "100.101.102.103")
        |> get("/")

      assert redirected_to(conn) == "/login"
    end

    test "the login page itself is reachable" do
      assert anonymous() |> get("/login") |> html_response(200) =~ "arb dashboard login"
    end

    test "the LiveView mount hook refuses a session with no grant" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, %{redirected: {:redirect, %{to: "/login"}}}} =
               ArbiterWeb.LiveHooks.on_mount(:dashboard_auth, %{}, %{}, socket)
    end

    test "the router's live_session redirects an anonymous LiveView request" do
      assert {:error, {:redirect, %{to: "/login"}}} = live(anonymous(), "/")
    end

    test "the router's live_session redirects an expired grant" do
      session = ArbiterWeb.DashboardAuth.Default.grant_session("token", "operator", 1)
      conn = Plug.Test.init_test_session(anonymous(), session)
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/")
    end

    test "the LiveView mount hook accepts a granted session" do
      session = ArbiterWeb.DashboardAuth.Default.grant_session("token", "operator")

      assert {:cont, _} =
               ArbiterWeb.LiveHooks.on_mount(
                 :dashboard_auth,
                 %{},
                 session,
                 %Phoenix.LiveView.Socket{}
               )
    end

    test "an expired grant is refused" do
      session = ArbiterWeb.DashboardAuth.Default.grant_session("token", "operator", 1)
      assert :error = ArbiterWeb.DashboardAuth.Default.authenticate_session(session)
    end
  end

  describe "token login" do
    test "a minted one-time token logs the browser in, once" do
      token = LoginTokens.mint()

      conn = post(anonymous(), "/login", %{"token" => token})
      assert redirected_to(conn) == "/"
      assert conn |> recycle() |> get("/about") |> html_response(200)

      # Replay fails, and stays on the login page.
      conn = post(anonymous(), "/login", %{"token" => token})
      assert redirected_to(conn) == "/login"
    end

    test "GET /login?token= only renders a confirmation, it does not consume" do
      token = LoginTokens.mint()
      html = anonymous() |> get("/login", %{"token" => token}) |> html_response(200)
      assert html =~ "login-confirm-form"
      assert {:ok, _} = LoginTokens.consume(token)
    end

    test "a bad token is refused" do
      conn = post(anonymous(), "/login", %{"token" => "nope"})
      assert redirected_to(conn) == "/login"
      assert anonymous() |> get("/") |> redirected_to() == "/login"
    end

    test "tokens expire" do
      token = LoginTokens.mint(-1)
      assert :error = LoginTokens.consume(token)
    end

    test "logout drops the grant" do
      token = LoginTokens.mint()
      conn = post(anonymous(), "/login", %{"token" => token})
      conn = conn |> recycle() |> delete("/logout")
      assert redirected_to(conn) == "/login"
      assert conn |> recycle() |> get("/") |> redirected_to() == "/login"
    end

    test "POST /api/dashboard/login_tokens mints a URL for a coordinator token only" do
      body = conn() |> post("/api/dashboard/login_tokens") |> json_response(200)
      assert %{"token" => token, "path" => "/login?token=" <> _} = body
      assert {:ok, _} = LoginTokens.consume(token)

      assert build_conn() |> post("/api/dashboard/login_tokens") |> json_response(401)
    end

    defp conn, do: coordinator_conn()
  end

  describe "tailscale identity" do
    test "an allowlisted login arriving via serve is let in" do
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, ["ryan@example.com"])
      conn = anonymous() |> via_serve("Ryan@Example.com") |> get("/about")
      assert html_response(conn, 200)
      # …and the grant sticks for the websocket / later requests.
      assert conn |> recycle() |> get("/about") |> html_response(200)
    end

    test "a login not on the allowlist is refused" do
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, ["ryan@example.com"])
      conn = anonymous() |> via_serve("mallory@example.com") |> get("/about")
      assert redirected_to(conn) == "/login"
    end

    test "with no allowlist configured the header is ignored" do
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, [])
      conn = anonymous() |> via_serve("ryan@example.com") |> get("/about")
      assert redirected_to(conn) == "/login"
    end

    test "spoofed identity headers on a direct, non-loopback request are rejected" do
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, ["ryan@example.com"])

      conn =
        anonymous()
        |> via_serve("ryan@example.com")
        |> Map.put(:remote_ip, {100, 64, 0, 9})
        |> get("/about")

      assert redirected_to(conn) == "/login"
    end

    test "loopback without serve's forwarding header is rejected" do
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, ["ryan@example.com"])

      conn =
        anonymous()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("tailscale-user-login", "ryan@example.com")
        |> get("/about")

      assert redirected_to(conn) == "/login"
    end

    test "removing a login from the allowlist revokes its existing session" do
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, ["ryan@example.com"])
      conn = anonymous() |> via_serve("ryan@example.com") |> get("/about")
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, [])
      assert conn |> recycle() |> get("/about") |> redirected_to() == "/login"
    end
  end

  describe "mode and slot" do
    test "the default implementation reports its mode" do
      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, [])
      assert %{impl: "default", mode: "token"} = ArbiterWeb.DashboardAuth.mode()

      Application.put_env(:arbiter_web, :dashboard_tailscale_logins, ["a@b.c"])
      assert %{mode: "token+tailscale"} = ArbiterWeb.DashboardAuth.mode()
    end

    test "the implementation is replaceable by config" do
      defmodule AllowAll do
        @behaviour ArbiterWeb.DashboardAuth
        def authenticate(conn), do: {:ok, conn, "sso"}
        def authenticate_session(_), do: {:ok, "sso"}
        def mode, do: %{impl: "allow_all", mode: "sso"}
      end

      previous = Application.get_env(:arbiter_web, :dashboard_auth)
      Application.put_env(:arbiter_web, :dashboard_auth, AllowAll)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter_web, :dashboard_auth, previous),
          else: Application.delete_env(:arbiter_web, :dashboard_auth)
      end)

      assert anonymous() |> get("/about") |> html_response(200)
      assert %{impl: "allow_all"} = ArbiterWeb.DashboardAuth.mode()
    end
  end
end
