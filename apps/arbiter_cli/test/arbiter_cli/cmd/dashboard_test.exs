defmodule ArbiterCli.Cmd.DashboardTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Dashboard
  alias ArbiterCli.Cmd.Doctor.Checks

  describe "arb dashboard login" do
    test "prints the one-time login URL" do
      stub_routes([
        {{"post", "/api/dashboard/login_tokens"},
         {%{"token" => "tok", "path" => "/login?token=tok", "expires_in" => 120}, 200}}
      ])

      {out, _err, _code} = capture(fn -> Dashboard.run(["login"]) end)
      assert out =~ ~r{^http\S+/login\?token=tok$}m
    end

    test "--json carries the url" do
      stub_routes([
        {{"post", "/api/dashboard/login_tokens"},
         {%{"token" => "tok", "path" => "/login?token=tok", "expires_in" => 120}, 200}}
      ])

      {out, _err, _code} = capture(fn -> Dashboard.run(["login", "--json"]) end)
      assert %{"token" => "tok", "url" => "http" <> _} = Jason.decode!(out)
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

    test "an unknown answer is left alone" do
      stub_routes([])
      assert Checks.check_dashboard_auth().status == :ok
    end
  end
end
