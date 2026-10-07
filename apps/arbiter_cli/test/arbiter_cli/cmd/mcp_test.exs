defmodule ArbiterCli.Cmd.McpTest do
  @moduledoc """
  `arb mcp token mint` (bd-8381tk). With no token of its own, the CLI proves
  operator identity over the server's local operator socket instead of the
  anonymous HTTP route, which the server now refuses. A caller that already
  holds a token (`ARB_TOKEN`, a session's own) keeps using the HTTP route,
  where the server caps what it mints at the caller's authority.
  """
  # async: false — the ARB_TOKEN / ARB_HOST cases set process env.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Mcp
  alias ArbiterCli.FakeOperatorSocket
  alias ArbiterCli.OperatorSocket

  @minted %{
    "token" => "TOKEN-FROM-SOCKET",
    "tier" => "coordinator",
    "workspace_id" => nil,
    "expires_in" => 2_592_000,
    "server_url" => "http://127.0.0.1:4848/mcp"
  }

  setup do
    saved =
      for k <- ~w(ARB_TOKEN ARB_HOST ARB_SESSION_ID ARB_OPERATOR_SOCKET),
          do: {k, System.get_env(k)}

    Enum.each(saved, fn {k, _} -> System.delete_env(k) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  describe "without a token of its own" do
    test "mints over the operator socket and prints the token" do
      FakeOperatorSocket.start!(@minted)

      {out, err, code} = capture(fn -> Mcp.run(~w(token mint --tier coordinator --ttl 600)) end)

      assert code == 0
      assert out =~ "TOKEN-FROM-SOCKET"
      assert err =~ "tier:         coordinator"

      assert_received {:operator_request,
                       %{"op" => "mint", "tier" => "coordinator", "ttl" => 600}}
    end

    test "--json prints the server's response" do
      FakeOperatorSocket.start!(@minted)

      {out, _err, 0} = capture(fn -> Mcp.run(~w(token mint --json)) end)
      assert Jason.decode!(String.trim(out))["token"] == "TOKEN-FROM-SOCKET"
    end

    test "a refusal is reported with the server's reason" do
      FakeOperatorSocket.start!(%{
        "error" => %{
          "message" =>
            "operator proof refused: the connecting process was started by the Arbiter server",
          "reason" => "spawned_by_arbiter"
        }
      })

      {out, err, code} = capture(fn -> Mcp.run(~w(token mint)) end)

      assert code == 1
      assert out == ""
      assert err =~ "operator proof refused"
      assert err =~ "hint:"
    end

    test "a missing socket says where it looked and what to do instead" do
      Process.put(:bd2_operator_socket, "/nonexistent-#{System.pid()}/op.sock")

      {_out, err, code} = capture(fn -> Mcp.run(~w(token mint)) end)

      # the same exit code as "the server isn't running" over HTTP
      assert code == 3
      assert err =~ "/nonexistent-#{System.pid()}/op.sock"
      assert err =~ "ARB_TOKEN"
    end

    test "a remote ARB_HOST is refused up front: its socket is on the other host" do
      System.put_env("ARB_HOST", "http://arbiter.example.test:4848")
      FakeOperatorSocket.start!(@minted)

      {_out, err, code} = capture(fn -> Mcp.run(~w(token mint)) end)

      assert code == 1
      assert err =~ "ssh"
      refute_received {:operator_request, _}
    end
  end

  describe "with a token of its own" do
    test "ARB_TOKEN uses the bearer-authenticated HTTP route, not the socket" do
      System.put_env("ARB_TOKEN", "caller-token")
      FakeOperatorSocket.start!(@minted)
      stub_post("/api/mcp/tokens", Map.put(@minted, "token", "TOKEN-FROM-HTTP"), 200)

      {out, _err, 0} = capture(fn -> Mcp.run(~w(token mint)) end)

      assert out =~ "TOKEN-FROM-HTTP"
      refute_received {:operator_request, _}
    end
  end

  describe "OperatorSocket.path/0" do
    test "is keyed by the ARB_HOST port" do
      Process.delete(:bd2_operator_socket)
      System.put_env("ARB_HOST", "http://127.0.0.1:4002")
      assert Path.basename(OperatorSocket.path()) == "operator-4002.sock"

      System.delete_env("ARB_HOST")
      assert Path.basename(OperatorSocket.path()) == "operator-4848.sock"
    end

    test "ARB_OPERATOR_SOCKET overrides it" do
      Process.delete(:bd2_operator_socket)
      System.put_env("ARB_OPERATOR_SOCKET", "/somewhere/op.sock")
      assert OperatorSocket.path() == "/somewhere/op.sock"
    end

    test "defaults to the per-user runtime dir the server uses" do
      Process.delete(:bd2_operator_socket)
      {:ok, %{uid: uid}} = File.stat("/proc/self")

      if File.dir?("/run/user/#{uid}") do
        assert OperatorSocket.path() == "/run/user/#{uid}/arbiter/operator-4848.sock"
      end
    end
  end

  describe "verify secret input (P-28)" do
    setup do
      stub_post("/api/mcp/tokens/verify", %{"valid" => true, "tier" => "worker"}, 200)
      :ok
    end

    test "a token on argv still verifies but warns, never echoing it" do
      {_out, err, 0} = capture(fn -> Mcp.run(~w(token verify argv-token)) end)
      assert err =~ "warning: a secret on the command line"
      refute err =~ "argv-token"
    end

    test "`-` reads the token from stdin without a warning" do
      {out, err, 0} = capture(fn -> Mcp.run(~w(token verify -)) end, input: "stdin-token\n")
      assert out =~ "worker"
      refute err =~ "`arb mcp token verify -` (stdin)"
    end

    test "--file reads the token from a file without a warning" do
      path = Path.join(System.tmp_dir!(), "tok-#{System.unique_integer([:positive])}")
      File.write!(path, "file-token\n")
      on_exit(fn -> File.rm(path) end)

      {_out, err, 0} = capture(fn -> Mcp.run(["token", "verify", "--file", path]) end)
      refute err =~ "`arb mcp token verify -` (stdin)"
    end

    test "no token at all is an error" do
      {_out, err, code} = capture(fn -> Mcp.run(~w(token verify)) end)
      assert code == 1
      assert err =~ "requires a token"
    end
  end

  describe "flag strictness (bd-cqw11s)" do
    test "mint rejects an unknown flag" do
      {_out, err, code} = capture(fn -> Mcp.run(["token", "mint", "--tir", "coordinator"]) end)

      assert code == 1
      assert err =~ "unknown option --tir for arb mcp token mint"
    end

    test "verify rejects an unknown flag rather than skipping dash-words" do
      {_out, err, code} = capture(fn -> Mcp.run(["token", "verify", "--bogus", "tok"]) end)

      assert code == 1
      assert err =~ "unknown option --bogus for arb mcp token verify"
    end
  end
end
