defmodule ArbiterCli.Cmd.TrustTest do
  # async: false — sets ARB_TOKEN in the process env.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Trust
  alias ArbiterCli.FakeOperatorSocket

  @subject "antigravity/gemini-3.8-flash-low"

  @summary %{
    "subject" => @subject,
    "tier" => "probation",
    "effective_tier" => "quarantine",
    "pinned" => false,
    "suspended" => %{
      "kind" => "public_upload_attempt",
      "run_id" => "run-9",
      "at" => "2026-10-10T11:00:00Z"
    },
    "record" => %{
      "window_days" => 30,
      "runs" => 14,
      "clean_runs" => 11,
      "clean_tickets" => 8,
      "clean_repos" => 1,
      "critical_events" => 1,
      "major_events" => 0,
      "minor_events" => 2,
      "reviewed" => 9,
      "round1_approve_rate" => 0.8888
    },
    "versions" => %{"harness" => "1.2.16", "model" => "gemini-3.8-flash-low"},
    "eligibility" => %{
      "eligible_for" => nil,
      "from" => "probation",
      "to" => "trusted",
      "blocked_by" => "suspended",
      "criteria" => [
        %{"name" => "clean_runs", "need" => 20, "have" => 11, "met" => false},
        %{"name" => "days_at_tier", "need" => 21, "have" => 30, "met" => true}
      ]
    },
    "pending" => [
      %{
        "id" => "pw-1",
        "state" => "proposed",
        "from" => "quarantine",
        "to" => "probation",
        "gist" => "promote it"
      }
    ]
  }

  setup do
    saved = System.get_env("ARB_TOKEN")
    System.put_env("ARB_TOKEN", "coordinator-session-token")

    on_exit(fn ->
      if saved, do: System.put_env("ARB_TOKEN", saved), else: System.delete_env("ARB_TOKEN")
    end)

    :ok
  end

  describe "arb trust show" do
    test "lists every subject: tier, effective tier, record and eligibility" do
      stub_get("/api/trust", %{"subjects" => [@summary]})

      {out, _err, 0} = capture(fn -> Trust.run(["show"]) end)

      assert out =~ @subject
      assert out =~ "probation"
      assert out =~ "SUSPENDED"
      assert out =~ "11/14 clean"
    end

    test "with no subcommand it is show" do
      stub_get("/api/trust", %{"subjects" => [@summary]})
      {out, _err, 0} = capture(fn -> Trust.run([]) end)
      assert out =~ @subject
    end

    test "one subject: the record, recent events and the pending proposal" do
      detail =
        Map.merge(@summary, %{
          "recent_events" => [
            %{
              "kind" => "public_upload_attempt",
              "severity" => "critical",
              "at" => "2026-10-10T11:00:00Z",
              "run_id" => "run-9",
              "task_id" => "bd-1"
            }
          ],
          "history" => [
            %{"at" => "2026-10-10T11:05:00Z", "action" => "suspended", "actor" => "loop:trust"}
          ]
        })

      stub_routes([
        {{"get", "/api/trust"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           assert conn.query_params["subject"] == @subject
           Req.Test.json(conn, %{"subject" => detail})
         end}
      ])

      {out, _err, 0} = capture(fn -> Trust.run(["show", @subject]) end)

      assert out =~ "tier: probation"
      assert out =~ "suspended"
      assert out =~ "public_upload_attempt"
      assert out =~ "pw-1"
      assert out =~ "arb trust promote #{@subject} --to probation"
      assert out =~ "clean_runs"
    end

    test "--json prints the server's envelope" do
      stub_get("/api/trust", %{"subjects" => [@summary]})
      {out, _err, 0} = capture(fn -> Trust.run(["show", "--json"]) end)
      assert %{"subjects" => [%{"subject" => @subject}]} = Jason.decode!(out)
    end
  end

  describe "arb trust promote" do
    @minted %{"token" => "PROOF-TOKEN", "tier" => "coordinator", "expires_in" => 300}

    test "mints operator proof over the socket and sends that, never ARB_TOKEN" do
      FakeOperatorSocket.start!(@minted)
      test_pid = self()

      stub_routes([
        {{"post", "/api/trust/promote"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:promote, Plug.Conn.get_req_header(conn, "authorization"), body})

           Req.Test.json(conn, %{
             "promoted" => true,
             "subject" => Map.put(@summary, "tier", "trusted"),
             "proposal" => nil
           })
         end}
      ])

      {out, _err, 0} =
        capture(fn ->
          Trust.run(["promote", @subject, "--to", "trusted", "--reason", "twenty clean runs"])
        end)

      assert out =~ "promoted #{@subject}"
      assert_received {:operator_request, %{"op" => "mint"}}
      assert_received {:promote, ["Bearer PROOF-TOKEN"], body}

      assert %{"subject" => @subject, "to" => "trusted", "reason" => "twenty clean runs"} =
               Jason.decode!(body)
    end

    test "an unreachable operator socket fails and never sends the request" do
      Process.put(:bd2_operator_socket, "/nonexistent-#{System.pid()}/op.sock")
      test_pid = self()

      stub_routes([
        {{"post", "/api/trust/promote"},
         fn conn ->
           send(test_pid, :hit_server)
           Req.Test.json(conn, %{})
         end}
      ])

      {_out, err, code} =
        capture(fn -> Trust.run(["promote", @subject, "--to", "trusted", "--reason", "x"]) end)

      assert code != 0
      assert err =~ "operator socket"
      refute_received :hit_server
    end

    test "--to and --reason are required before anything is asked" do
      for argv <- [
            ["promote", @subject, "--reason", "x"],
            ["promote", @subject, "--to", "trusted"],
            ["promote", "--to", "trusted", "--reason", "x"]
          ] do
        {_out, err, code} = capture(fn -> Trust.run(argv) end)
        assert code != 0
        assert err =~ "usage: arb trust promote"
      end
    end
  end

  describe "arb trust confirm / dismiss" do
    test "confirm posts the subject with the caller's own token" do
      test_pid = self()

      stub_routes([
        {{"post", "/api/trust/confirm"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:confirm, Plug.Conn.get_req_header(conn, "authorization"), body})
           Req.Test.json(conn, %{"confirmed" => true, "subject" => @summary})
         end}
      ])

      {out, _err, 0} = capture(fn -> Trust.run(["confirm", @subject]) end)

      assert out =~ "confirmed"
      assert_received {:confirm, ["Bearer coordinator-session-token"], body}
      assert %{"subject" => @subject} = Jason.decode!(body)
    end

    test "dismiss needs a reason and passes it through" do
      {_out, err, code} = capture(fn -> Trust.run(["dismiss", @subject]) end)
      assert code != 0
      assert err =~ "usage: arb trust dismiss"

      test_pid = self()

      stub_routes([
        {{"post", "/api/trust/dismiss"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:dismiss, body})
           Req.Test.json(conn, %{"dismissed" => true, "subject" => @summary})
         end}
      ])

      {out, _err, 0} =
        capture(fn -> Trust.run(["dismiss", @subject, "--reason", "authorised probe"]) end)

      assert out =~ "dismissed"
      assert_received {:dismiss, body}
      assert %{"subject" => @subject, "reason" => "authorised probe"} = Jason.decode!(body)
    end
  end

  test "an unknown subcommand is an error" do
    {_out, err, code} = capture(fn -> Trust.run(["frobnicate"]) end)
    assert code != 0
    assert err =~ "unknown `arb trust` subcommand"
  end

  test "--help prints usage without hitting the API" do
    {out, _err, 0} = capture(fn -> Trust.run(["--help"]) end)
    assert out =~ "arb trust promote"
    assert out =~ "operator"
  end
end
