defmodule ArbiterCli.Cmd.AlertTest do
  @moduledoc """
  `arb alert list` (P-17): the active system alerts, `GET /api/alerts`.
  """
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Alert

  @alert %{
    "id" => "a-1",
    "kind" => "credential_expired",
    "key" => "Arbiter.Agents.Claude:usage_poll",
    "workspace_id" => "ws-1",
    "subject" => "Claude credential expired",
    "detail" => "401 from the usage endpoint",
    "owner" => "operator",
    "raised_at" => "2026-09-13T01:00:00Z",
    "last_raised_at" => "2026-09-13T02:00:00Z",
    "raise_count" => 3,
    "cleared_at" => nil
  }

  describe "arb alert list" do
    test "prints each active alert" do
      stub_get("/api/alerts", %{"alerts" => [@alert], "count" => 1, "workspace_id" => nil})

      {out, _err, code} = capture(fn -> Alert.run(["list"]) end)

      assert code == 0
      assert out =~ "credential_expired"
      assert out =~ "Claude credential expired"
      assert out =~ "401 from the usage endpoint"
    end

    test "says so when nothing is wrong" do
      stub_get("/api/alerts", %{"alerts" => [], "count" => 0, "workspace_id" => nil})

      {out, _err, code} = capture(fn -> Alert.run(["list"]) end)

      assert code == 0
      assert out =~ "No active system alerts"
    end

    test "--json prints the REST body untouched" do
      body = %{"alerts" => [@alert], "count" => 1, "workspace_id" => nil}
      stub_get("/api/alerts", body)

      {out, _err, code} = capture(fn -> Alert.run(["list", "--json"]) end)

      assert code == 0
      assert Jason.decode!(out) == body
    end

    test "sends --kind and the resolved --workspace" do
      test_pid = self()

      Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.request_path do
          "/api/workspaces" ->
            Req.Test.json(conn, %{"data" => [%{"id" => "ws-acme", "name" => "acme"}]})

          "/api/alerts" ->
            send(test_pid, {:query, conn.query_params})
            Req.Test.json(conn, %{"alerts" => [], "count" => 0})
        end
      end)

      {_out, err, code} =
        capture(fn -> Alert.run(["list", "--kind", "overage_alert", "--workspace", "acme"]) end)

      assert code == 0, err
      assert_received {:query, %{"kind" => "overage_alert", "workspace" => "ws-acme"}}
    end

    test "a REST error exits non-zero" do
      stub_get(
        "/api/alerts",
        %{"error" => %{"type" => "invalid_request", "message" => "bad"}},
        400
      )

      {_out, _err, code} = capture(fn -> Alert.run(["list", "--kind", "nope"]) end)

      assert code != 0
    end

    test "an unknown flag is refused" do
      {_out, err, code} = capture(fn -> Alert.run(["list", "--bogus"]) end)

      assert code == 1
      assert err =~ "unknown option --bogus for arb alert"
    end

    test "an unknown subcommand exits 2" do
      {_out, err, code} = capture(fn -> Alert.run(["nope"]) end)

      assert code == 2
      assert err =~ "unknown alert subcommand"
    end
  end
end
