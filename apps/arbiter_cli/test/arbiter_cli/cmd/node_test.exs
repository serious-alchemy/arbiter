defmodule ArbiterCli.Cmd.NodeTest do
  @moduledoc """
  `arb node add|list|show|set|events` (RW4) and `drain|undrain|revoke|remove|upgrade`
  plus the per-node caps, `local` included (RW7), `docs/design/remote-workers.md` §5.6, §14.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Node

  @token "arbj_" <> String.duplicate("a", 52)
  @one_liner "curl --proto '=https' --tlsv1.2 -fsSL https://primary.ts.net/nodes/join | bash"

  @minted %{
    "token" => @token,
    "one_liner" => @one_liner,
    "public_url" => "https://primary.ts.net",
    "join_token" => %{
      "id" => "jt-1",
      "name" => "box-1",
      "expires_at" => "2026-10-06T12:15:00Z"
    }
  }

  @node %{
    "id" => "01a0-node",
    "name" => "box-1",
    "status" => "active",
    "labels" => ["zone=a"],
    "max_workers" => 2,
    "credential_prefix" => "abcd1234",
    "enrolled_at" => "2026-10-06T12:00:00Z",
    "last_seen_at" => nil
  }

  # Capture the request the command sent, then answer.
  defp capture_request(method, path, status, body) do
    test = self()
    method = method |> to_string() |> String.upcase()

    Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.method, conn.request_path, raw})
      assert conn.method == method
      assert conn.request_path == path
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp tty(value), do: Process.put(:bd2_stdout_tty, value)

  describe "add" do
    test "prints the one-liner and, separately, the token (to a terminal)" do
      tty(true)
      capture_request(:post, "/api/nodes/join-tokens", 201, @minted)

      {out, _err, 0} = capture(fn -> Node.run(["add", "--name", "box-1"]) end)

      lines = String.split(out, "\n")
      liner = Enum.find_index(lines, &(&1 == "  " <> @one_liner))
      token = Enum.find_index(lines, &(&1 == "  " <> @token))
      assert liner && token && liner < token, "one-liner then token, on separate lines"
      refute @one_liner =~ @token
      assert out =~ "expires 2026-10-06T12:15:00Z"
      assert out =~ "shown once"

      assert_receive {:request, "POST", "/api/nodes/join-tokens", raw}
      assert Jason.decode!(raw) == %{"name" => "box-1"}
    end

    test "sends labels, max-workers and the ttl in seconds" do
      tty(true)
      capture_request(:post, "/api/nodes/join-tokens", 201, @minted)

      {_out, _err, 0} =
        capture(fn ->
          Node.run([
            "add",
            "--label",
            "zone=a",
            "--label",
            "gpu=no",
            "--max-workers",
            "3",
            "--ttl",
            "2h"
          ])
        end)

      assert_receive {:request, "POST", _, raw}

      assert Jason.decode!(raw) == %{
               "labels" => ["zone=a", "gpu=no"],
               "max_workers" => 3,
               "ttl_seconds" => 7200
             }
    end

    test "ttl accepts s, m, h and refuses nonsense before minting anything" do
      tty(true)

      for bad <- ["abc", "0m", "-5m", "15x"] do
        {_out, err, code} = capture(fn -> Node.run(["add", "--ttl", bad]) end)
        assert code != 0
        assert err =~ "ttl"
      end

      refute_received {:request, _, _, _}
    end

    test "off a terminal it refuses to print the token, before minting one" do
      tty(false)
      capture_request(:post, "/api/nodes/join-tokens", 201, @minted)

      {out, err, code} = capture(fn -> Node.run(["add"]) end)

      assert code != 0
      assert err =~ "--token-file"
      refute out =~ @token
      refute err =~ @token
      refute_received {:request, _, _, _}
    end

    test "--token-file writes the token (0600) and prints only the file's path" do
      tty(false)
      capture_request(:post, "/api/nodes/join-tokens", 201, @minted)
      path = Path.join(System.tmp_dir!(), "arb-node-token-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)

      {out, _err, 0} = capture(fn -> Node.run(["add", "--token-file", path]) end)

      assert File.read!(path) |> String.trim() == @token
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      refute out =~ @token
      assert out =~ path
      assert out =~ @one_liner
      assert out =~ "ARB_JOIN_TOKEN_FILE"
    end

    test "--token-file refuses to overwrite a file" do
      tty(false)
      path = Path.join(System.tmp_dir!(), "arb-node-token-#{System.unique_integer([:positive])}")
      File.write!(path, "keep me")
      on_exit(fn -> File.rm(path) end)

      {_out, err, code} = capture(fn -> Node.run(["add", "--token-file", path]) end)
      assert code != 0
      assert err =~ "already exists"
      assert File.read!(path) == "keep me"
      refute_received {:request, _, _, _}
    end

    test "--json carries the one-liner and expiry, and the token only to a terminal" do
      tty(true)
      capture_request(:post, "/api/nodes/join-tokens", 201, @minted)
      {out, _err, 0} = capture(fn -> Node.run(["add", "--json"]) end)
      body = Jason.decode!(out)
      assert body["one_liner"] == @one_liner
      assert body["token"] == @token

      tty(false)
      {out, _err, code} = capture(fn -> Node.run(["add", "--json"]) end)
      assert code != 0
      refute out =~ @token
    end

    test "an API error is reported" do
      tty(true)

      capture_request(:post, "/api/nodes/join-tokens", 422, %{
        "error" => %{"type" => "validation_error", "message" => "nodes.public_url is not set"}
      })

      {_out, err, code} = capture(fn -> Node.run(["add"]) end)
      assert code != 0
      assert err =~ "nodes.public_url"
    end
  end

  @local %{
    "id" => "local",
    "name" => "local",
    "kind" => "local",
    "state" => "online",
    "live" => 1,
    "max" => 3,
    "suggested" => 3,
    "override" => nil,
    "ceiling" => nil
  }

  @live_node Map.merge(@node, %{
               "state" => "online",
               "health" => "ready",
               "agent_version" => "1.2.3",
               "live" => 1,
               "max" => 2,
               "suggested" => 4,
               "override" => 2,
               "ceiling" => 3,
               "last_heartbeat_at" => nil
             })

  describe "list" do
    test "shows the local row first, then name, state, caps, labels and last seen" do
      stub_get("/api/nodes", %{
        "nodes" => [Map.put(@live_node, "contributes", 2)],
        "local" => @local,
        "total" => 5,
        "effective" => 5,
        "ceiling" => nil,
        "warnings" => []
      })

      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)

      [header, first, second | _] = String.split(out, "\n")
      assert header =~ "NAME" and header =~ "SUGGESTED" and header =~ "OVERRIDE"
      assert first =~ "local" and first =~ "1/3"
      assert second =~ "box-1" and second =~ "online" and second =~ "1/2"
      assert out =~ "zone=a"
      assert out =~ "never"
      assert out =~ "capacity 5 = local 3 + box-1 2"
      assert out =~ "conductor.max_concurrent: not set"
      refute out =~ "idle"
    end

    test "names a ceiling that cuts the sum, and the idle-capacity warning with it" do
      stub_get("/api/nodes", %{
        "nodes" => [Map.put(@live_node, "contributes", 2)],
        "local" => @local,
        "total" => 5,
        "effective" => 4,
        "ceiling" => 4,
        "warnings" => ["ceiling_below_total"]
      })

      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)
      assert out =~ "conductor.max_concurrent = 4"
      assert out =~ "plans 4"
      assert out =~ "arb settings unset conductor_system_max_concurrent"
      assert out =~ "will sit idle"
    end

    test "lists a node that adds nothing as not counted" do
      stub_get("/api/nodes", %{
        "nodes" => [Map.merge(@live_node, %{"contributes" => 0, "state" => "draining"})],
        "local" => @local,
        "total" => 3,
        "effective" => 3,
        "ceiling" => nil,
        "warnings" => []
      })

      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)
      assert out =~ "capacity 3 = local 3 (not counted: box-1 draining)"
    end

    test "prints the warnings" do
      stub_get("/api/nodes", %{
        "nodes" => [],
        "local" => %{@local | "max" => 0, "override" => 0},
        "total" => 0,
        "ceiling" => 3,
        "warnings" => ["local_cap_zero"]
      })

      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)
      assert out =~ "local cap is 0"
      assert out =~ "wait"
    end

    test "with only the primary it says there are no remote nodes" do
      stub_get("/api/nodes", %{"nodes" => [], "local" => @local, "total" => 3, "ceiling" => 3})
      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)
      assert out =~ "local"
      assert out =~ "No remote nodes"
      assert out =~ "arb node add"
    end

    test "an older server's list (no local row) still renders" do
      stub_get("/api/nodes", %{"nodes" => [@node]})
      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)

      assert out =~ "box-1"
      assert out =~ "active"
    end

    test "says so when there are none" do
      stub_get("/api/nodes", %{"nodes" => []})
      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)
      assert out =~ "No nodes"
      assert out =~ "arb node add"
    end

    test "--json" do
      stub_get("/api/nodes", %{"nodes" => [@node]})
      {out, _err, 0} = capture(fn -> Node.run(["list", "--json"]) end)
      assert [%{"name" => "box-1"}] = Jason.decode!(out)["nodes"]
    end
  end

  describe "show" do
    test "prints the node's details" do
      stub_get("/api/nodes/box-1", %{"node" => @node})
      {out, _err, 0} = capture(fn -> Node.run(["show", "box-1"]) end)

      assert out =~ "box-1"
      assert out =~ "01a0-node"
      assert out =~ "abcd1234"
      assert out =~ "max workers: 2"
    end

    test "shows the cap's sources, the ceiling that wins, and the workspace pin" do
      node =
        Map.merge(@node, %{
          "max" => 2,
          "suggested" => 4,
          "override" => 8,
          "ceiling" => 2,
          "cap_source" => "ceiling",
          "workspace_ids" => ["ws-a"]
        })

      stub_get("/api/nodes/box-1", %{"node" => node})
      {out, _err, 0} = capture(fn -> Node.run(["show", "box-1"]) end)

      assert out =~ "max workers: 2 (suggested 4, override 8, ceiling 2 — the ceiling wins)"
      assert out =~ "pinned to:     ws-a"
    end

    test "needs a name or id" do
      {_out, err, code} = capture(fn -> Node.run(["show"]) end)
      assert code != 0
      assert err =~ "node name or id"
    end

    test "an unknown node is an error" do
      stub_get(
        "/api/nodes/ghost",
        %{"error" => %{"type" => "not_found", "message" => "nope"}},
        404
      )

      {_out, err, code} = capture(fn -> Node.run(["show", "ghost"]) end)
      assert code != 0
      assert err =~ "nope"
    end
  end

  describe "set" do
    test "patches labels and max-workers" do
      capture_request(:patch, "/api/nodes/box-1", 200, %{"node" => %{@node | "max_workers" => 5}})

      {out, _err, 0} =
        capture(fn ->
          Node.run(["set", "box-1", "--label", "zone=b", "--max-workers", "5"])
        end)

      assert_receive {:request, "PATCH", "/api/nodes/box-1", raw}
      assert Jason.decode!(raw) == %{"labels" => ["zone=b"], "max_workers" => 5}
      assert out =~ "Updated box-1"
    end

    test "--max-workers none clears the cap; --name renames" do
      capture_request(:patch, "/api/nodes/box-1", 200, %{"node" => @node})

      {_out, _err, 0} =
        capture(fn -> Node.run(["set", "box-1", "--max-workers", "none", "--name", "box-2"]) end)

      assert_receive {:request, "PATCH", _, raw}
      assert Jason.decode!(raw) == %{"max_workers" => nil, "name" => "box-2"}
    end

    test "--workspace pins the node to workspaces; `--workspace none` clears the pin" do
      capture_request(:patch, "/api/nodes/box-1", 200, %{"node" => @node})

      {_out, _err, 0} =
        capture(fn ->
          Node.run(["set", "box-1", "--workspace", "ws-a", "--workspace", "ws-b"])
        end)

      assert_receive {:request, "PATCH", _, raw}
      assert Jason.decode!(raw) == %{"workspace_ids" => ["ws-a", "ws-b"]}

      {_out, _err, 0} = capture(fn -> Node.run(["set", "box-1", "--workspace", "none"]) end)
      assert_receive {:request, "PATCH", _, raw}
      assert Jason.decode!(raw) == %{"workspace_ids" => []}
    end

    test "--json prints the raw response instead of the text summary" do
      capture_request(:patch, "/api/nodes/box-1", 200, %{"node" => @node})

      {out, _err, 0} =
        capture(fn -> Node.run(["set", "box-1", "--max-workers", "3", "--json"]) end)

      assert %{"node" => _} = Jason.decode!(String.trim(out))
      refute out =~ "Updated"
    end

    test "with nothing to change it says so and sends nothing" do
      {_out, err, code} = capture(fn -> Node.run(["set", "box-1"]) end)
      assert code != 0
      assert err =~ "nothing to set"
      refute_received {:request, _, _, _}
    end
  end

  describe "set local" do
    test "sets the primary's cap, 0 included" do
      capture_request(:patch, "/api/nodes/local", 200, %{"node" => @local})

      {out, _err, 0} = capture(fn -> Node.run(["set", "local", "--max-workers", "0"]) end)

      assert_receive {:request, "PATCH", "/api/nodes/local", raw}
      assert Jason.decode!(raw) == %{"max_workers" => 0}
      assert out =~ "Updated local"
    end

    test "none clears the override" do
      capture_request(:patch, "/api/nodes/local", 200, %{"node" => @local})
      {_out, _err, 0} = capture(fn -> Node.run(["set", "local", "--max-workers", "none"]) end)
      assert_receive {:request, "PATCH", _, raw}
      assert Jason.decode!(raw) == %{"max_workers" => nil}
    end

    test "local takes no other field, and a node's cap cannot be 0" do
      {_out, err, code} = capture(fn -> Node.run(["set", "local", "--name", "x"]) end)
      assert code != 0
      assert err =~ "local"

      {_out, err, code} = capture(fn -> Node.run(["set", "box-1", "--max-workers", "0"]) end)
      assert code != 0
      assert err =~ "positive"
      refute_received {:request, _, _, _}
    end
  end

  describe "lifecycle verbs" do
    for {verb, past} <- [
          {"drain", "Draining"},
          {"undrain", "Undrained"},
          {"revoke", "Revoked"},
          {"upgrade", "Upgrade requested for"}
        ] do
      test "#{verb} posts to the node and says so" do
        capture_request(:post, "/api/nodes/box-1/#{unquote(verb)}", 200, %{
          "node" => @node,
          "upgrading_to" => "v9"
        })

        {out, _err, 0} = capture(fn -> Node.run([unquote(verb), "box-1"]) end)

        assert_receive {:request, "POST", "/api/nodes/box-1/" <> unquote(verb), _}
        assert out =~ unquote(past)
        assert out =~ "box-1"
      end
    end

    test "remove deletes the node" do
      capture_request(:delete, "/api/nodes/box-1", 200, %{"removed" => "box-1"})

      {out, _err, 0} = capture(fn -> Node.run(["remove", "box-1"]) end)

      assert_receive {:request, "DELETE", "/api/nodes/box-1", _}
      assert out =~ "Removed box-1"
    end

    test "a refusal is reported with the server's message and a non-zero exit" do
      Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{
          "error" => %{"type" => "conflict", "message" => "revoke the node before removing it"}
        })
      end)

      {_out, err, code} = capture(fn -> Node.run(["remove", "box-1"]) end)
      assert code != 0
      assert err =~ "revoke the node before removing it"
    end

    test "each needs a node" do
      for verb <- ["drain", "undrain", "revoke", "remove", "upgrade"] do
        {_out, err, code} = capture(fn -> Node.run([verb]) end)
        assert code != 0
        assert err =~ "node name or id"
      end
    end

    test "a node named by an id with odd characters is path-escaped" do
      capture_request(:post, "/api/nodes/a%2Fb/drain", 200, %{"node" => @node})
      {_out, _err, 0} = capture(fn -> Node.run(["drain", "a/b"]) end)
      assert_receive {:request, "POST", _, _}
    end
  end

  describe "events" do
    test "lists the audit trail" do
      stub_get("/api/nodes/box-1/events", %{
        "events" => [
          %{
            "kind" => "enrolled",
            "actor" => "node:box-1",
            "at" => "2026-10-06T12:00:00Z",
            "detail" => %{},
            "remote_addr_hint" => "100.64.0.9"
          },
          %{
            "kind" => "updated",
            "actor" => "operator:cli",
            "at" => "2026-10-06T12:05:00Z",
            "detail" => %{"changes" => %{"max_workers" => 2}},
            "remote_addr_hint" => nil
          }
        ]
      })

      {out, _err, 0} = capture(fn -> Node.run(["events", "box-1"]) end)
      assert out =~ "enrolled"
      assert out =~ "node:box-1"
      assert out =~ "100.64.0.9"
      assert out =~ "updated"
      assert out =~ "max_workers"
    end
  end

  describe "pairing (device code)" do
    @pairing %{
      "id" => "019a-req",
      "code" => "K7QM-2X9D",
      "state" => "pending",
      "hostname" => "laptop",
      "peer" => "100.64.0.7",
      "name" => nil,
      "labels" => [],
      "max_workers" => nil,
      "expires_at" => "2026-10-08T12:10:00Z"
    }

    # Route by "METHOD path"; every request is also sent to the test process.
    defp stub_pairing_routes(routes) do
      test = self()

      Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn.method, conn.request_path, raw})
        {status, body} = Map.fetch!(routes, conn.method <> " " <> conn.request_path)
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)
    end

    @list {200, %{"pairings" => [@pairing]}}
    @approved {200, %{"pairing" => %{@pairing | "state" => "approved"}}}

    test "pending lists each request with its code, hostname and source address" do
      stub_pairing_routes(%{"GET /api/nodes/pairings" => @list})

      {out, _err, 0} = capture(fn -> Node.run(["pending"]) end)
      assert out =~ "K7QM-2X9D"
      assert out =~ "laptop"
      assert out =~ "100.64.0.7"
    end

    test "pending with none says so" do
      stub_pairing_routes(%{"GET /api/nodes/pairings" => {200, %{"pairings" => []}}})
      {out, _err, 0} = capture(fn -> Node.run(["pending"]) end)
      assert out =~ "No pending pairing requests"
    end

    test "approve shows the requesting host and address, asks, then approves" do
      stub_pairing_routes(%{
        "GET /api/nodes/pairings" => @list,
        "POST /api/nodes/pairings/019a-req/approve" => @approved
      })

      {out, _err, 0} =
        capture(
          fn -> Node.run(["approve", "k7qm2x9d", "--name", "gpu-1", "--max-workers", "2"]) end,
          input: "y\n"
        )

      assert out =~ "laptop"
      assert out =~ "100.64.0.7"
      assert out =~ "Approve"
      assert out =~ "Approved"

      assert_received {:request, "POST", "/api/nodes/pairings/019a-req/approve", raw}
      assert Jason.decode!(raw) == %{"name" => "gpu-1", "max_workers" => 2}
    end

    test "approve aborts, sending nothing, unless the operator says yes" do
      stub_pairing_routes(%{"GET /api/nodes/pairings" => @list})

      {out, _err, 0} = capture(fn -> Node.run(["approve", "K7QM-2X9D"]) end, input: "n\n")
      assert out =~ "aborted"
      refute_received {:request, "POST", _, _}
    end

    test "approve --yes skips the question" do
      stub_pairing_routes(%{
        "GET /api/nodes/pairings" => @list,
        "POST /api/nodes/pairings/019a-req/approve" => @approved
      })

      {out, _err, 0} = capture(fn -> Node.run(["approve", "K7QM-2X9D", "--yes"]) end)
      assert out =~ "Approved"
      assert_received {:request, "POST", "/api/nodes/pairings/019a-req/approve", _}
    end

    test "approve --json needs --yes and prints the pairing" do
      stub_pairing_routes(%{
        "GET /api/nodes/pairings" => @list,
        "POST /api/nodes/pairings/019a-req/approve" => @approved
      })

      {_out, err, code} = capture(fn -> Node.run(["approve", "K7QM-2X9D", "--json"]) end)
      assert code != 0
      assert err =~ "--yes"

      {out, _err, 0} = capture(fn -> Node.run(["approve", "K7QM-2X9D", "--yes", "--json"]) end)
      assert %{"pairing" => %{"state" => "approved"}} = Jason.decode!(out)
    end

    test "approve of an unknown or malformed code is an error and approves nothing" do
      stub_pairing_routes(%{"GET /api/nodes/pairings" => @list})

      for code <- ["ZZZZ-ZZZZ", "nope"] do
        {_out, err, status} = capture(fn -> Node.run(["approve", code, "--yes"]) end)
        assert status != 0
        assert err =~ "arb node pending"
      end

      refute_received {:request, "POST", _, _}
    end

    test "approve needs a code" do
      {_out, err, code} = capture(fn -> Node.run(["approve"]) end)
      assert code != 0
      assert err =~ "code"
    end

    test "deny posts to the request and says so" do
      stub_pairing_routes(%{
        "GET /api/nodes/pairings" => @list,
        "POST /api/nodes/pairings/019a-req/deny" =>
          {200, %{"pairing" => %{@pairing | "state" => "denied"}}}
      })

      {out, _err, 0} = capture(fn -> Node.run(["deny", "K7QM-2X9D"]) end)
      assert out =~ "Denied"
      assert_received {:request, "POST", "/api/nodes/pairings/019a-req/deny", _}
    end

    test "the help documents pairing" do
      {out, _err, 0} = capture(fn -> Node.run(["--help"]) end)
      assert out =~ "arb node approve"
      assert out =~ "arb node pending"
      assert out =~ "arb node deny"
    end
  end

  test "an unknown subcommand is a usage error" do
    {_out, err, code} = capture(fn -> Node.run(["frobnicate"]) end)
    assert code == 2
    assert err =~ "unknown node subcommand"
  end

  test "--help prints usage" do
    {out, _err, 0} = capture(fn -> Node.run(["--help"]) end)
    assert out =~ "arb node add"
  end
end
