defmodule ArbiterCli.Cmd.NodeTest do
  @moduledoc "RW4: `arb node add|list|show|set|events` (`docs/design/remote-workers.md` §5.6)."
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

  describe "list" do
    test "shows name, status, workers, labels and last seen" do
      stub_get("/api/nodes", %{"nodes" => [@node]})
      {out, _err, 0} = capture(fn -> Node.run(["list"]) end)

      assert out =~ "box-1"
      assert out =~ "active"
      assert out =~ "zone=a"
      assert out =~ "never"
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

    test "with nothing to change it says so and sends nothing" do
      {_out, err, code} = capture(fn -> Node.run(["set", "box-1"]) end)
      assert code != 0
      assert err =~ "nothing to set"
      refute_received {:request, _, _, _}
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
