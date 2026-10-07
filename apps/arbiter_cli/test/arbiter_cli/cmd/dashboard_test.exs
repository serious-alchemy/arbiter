defmodule ArbiterCli.Cmd.DashboardTest do
  # async: false — sets ARB_TOKEN in the process env.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Dashboard
  alias ArbiterCli.Cmd.Doctor.Checks
  alias ArbiterCli.FakeOperatorSocket

  describe "arb dashboard login" do
    @minted %{"token" => "PROOF-TOKEN", "tier" => "coordinator", "expires_in" => 300}
    @login {%{"token" => "tok", "path" => "/login?token=tok", "expires_in" => 120}, 200}

    setup do
      saved = System.get_env("ARB_TOKEN")
      System.put_env("ARB_TOKEN", "coordinator-session-token")

      on_exit(fn ->
        if saved, do: System.put_env("ARB_TOKEN", saved), else: System.delete_env("ARB_TOKEN")
      end)

      FakeOperatorSocket.start!(@minted)
      :ok
    end

    test "prints the one-time login URL" do
      stub_routes([{{"post", "/api/dashboard/login_tokens"}, @login}])

      {out, _err, _code} = capture(fn -> Dashboard.run(["login"]) end)
      assert out =~ ~r{^http\S+/login\?token=tok$}m
    end

    test "--json carries the url" do
      stub_routes([{{"post", "/api/dashboard/login_tokens"}, @login}])

      {out, _err, _code} = capture(fn -> Dashboard.run(["login", "--json"]) end)
      assert %{"token" => "tok", "url" => "http" <> _} = Jason.decode!(out)
    end

    test "mints operator proof over the socket and sends that, never ARB_TOKEN" do
      test_pid = self()

      stub_routes([
        {{"post", "/api/dashboard/login_tokens"},
         fn conn ->
           send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
           Req.Test.json(conn, elem(@login, 0))
         end}
      ])

      {_out, _err, 0} = capture(fn -> Dashboard.run(["login"]) end)

      assert_received {:operator_request, %{"op" => "mint", "ttl" => 300}}
      assert_received {:auth, ["Bearer PROOF-TOKEN"]}
    end

    test "an unreachable operator socket fails and never falls back to ARB_TOKEN" do
      Process.put(:bd2_operator_socket, "/nonexistent-#{System.pid()}/op.sock")
      test_pid = self()

      stub_routes([
        {{"post", "/api/dashboard/login_tokens"},
         fn conn ->
           send(test_pid, :hit_server)
           Req.Test.json(conn, elem(@login, 0))
         end}
      ])

      {_out, err, code} = capture(fn -> Dashboard.run(["login"]) end)
      assert code != 0
      assert err =~ "operator socket"
      refute_received :hit_server
    end
  end

  describe "doctor: dashboard requires login" do
    defp redirect_route do
      {{"get", "/"},
       fn conn ->
         conn |> Plug.Conn.put_resp_header("location", "/login") |> Plug.Conn.send_resp(302, "")
       end}
    end

    test "ok when an anonymous browser request is redirected, and reports the mode" do
      stub_routes([
        redirect_route(),
        {{"get", "/api/server/dashboard_auth"}, {%{"impl" => "default", "mode" => "token"}, 200}}
      ])

      result = Checks.check_dashboard_auth()
      assert result.status == :ok
      assert result.detail =~ "mode token"
    end

    test "fails, fatally, when the dashboard is served anonymously" do
      stub_routes([{{"get", "/"}, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end}])

      result = Checks.check_dashboard_auth()
      assert result.status == :fail
      assert result.fatal
    end

    test "with loopback trust on, the direct probe is not a failure but a forwarded one must redirect" do
      stub_routes([
        {{"get", "/"},
         fn conn ->
           if Plug.Conn.get_req_header(conn, "x-forwarded-for") == [] do
             Plug.Conn.send_resp(conn, 200, "<html>")
           else
             conn
             |> Plug.Conn.put_resp_header("location", "/login")
             |> Plug.Conn.send_resp(302, "")
           end
         end},
        {{"get", "/api/server/dashboard_auth"},
         {%{"impl" => "default", "mode" => "token+loopback", "trust_loopback" => true}, 200}}
      ])

      result = Checks.check_dashboard_auth()
      assert result.status == :ok
      assert result.detail =~ "loopback trusted (opt-in)"
      assert result.detail =~ "token+loopback"
    end

    test "with loopback trust on, a forwarded request that is served fails" do
      stub_routes([
        {{"get", "/"}, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>") end},
        {{"get", "/api/server/dashboard_auth"},
         {%{"impl" => "default", "mode" => "token+loopback", "trust_loopback" => true}, 200}}
      ])

      result = Checks.check_dashboard_auth()
      assert result.status == :fail
      assert result.fatal
    end

    test "an unknown answer is left alone" do
      stub_routes([])
      assert Checks.check_dashboard_auth().status == :ok
    end
  end
end
