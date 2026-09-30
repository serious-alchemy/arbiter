defmodule Arbiter.MCP.OperatorSocketTest do
  @moduledoc """
  `Arbiter.MCP.OperatorSocket` over a real Unix domain socket (bd-8381tk).

  The clients are real OS processes (`python3`), so the peer credentials the
  listener checks are the kernel's, not a stub's. With the default policy the
  "server" is this VM, and every client this test starts is its child, just
  as a worker is the child of the real server. That is the refused case. The
  accepted case points the policy's `:server_pid` at an unrelated process,
  which makes the same client look like the operator's shell (outside
  Arbiter's tree).
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Arbiter.MCP.OperatorSocket
  alias Arbiter.MCP.Scope

  @python System.find_executable("python3")

  # Short and private: sun_path is 108 bytes, and /tmp is shared between workers.
  setup do
    dir = Path.join(System.tmp_dir!(), "ops-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, path: Path.join([dir, "arbiter", "op.sock"])}
  end

  defp start!(path, authorize) do
    start_supervised!({OperatorSocket, path: path, authorize: authorize, name: nil})
  end

  # An unrelated OS process: the client below is not its descendant.
  defp unrelated_pid do
    port = Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["60"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [Integer.to_string(pid)]) end)
    pid
  end

  @client """
  import socket, sys
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.connect(sys.argv[1])
  s.sendall(sys.argv[2].encode() + b"\\n")
  print(s.makefile().readline(), end="")
  """

  defp os_client(path, request) do
    {out, 0} = System.cmd(@python, ["-c", @client, path, Jason.encode!(request)])
    Jason.decode!(out)
  end

  @moduletag skip: if(@python, do: false, else: "python3 not on PATH")

  describe "a client that is a child of the server (a worker's position)" do
    test "is refused and gets no token", %{path: path} do
      start!(path, server_cgroup: nil)

      resp = os_client(path, %{"op" => "mint", "tier" => "coordinator"})

      refute Map.has_key?(resp, "token")
      assert resp["error"]["reason"] == "spawned_by_arbiter"
      assert resp["error"]["message"] =~ "started by the Arbiter server"
    end

    test "the server connecting to itself is refused", %{path: path} do
      start!(path, server_cgroup: nil)

      {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
      :ok = :gen_tcp.send(sock, ~s({"op":"mint"}\n))
      {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)

      assert %{"error" => %{"reason" => "spawned_by_arbiter"}} = Jason.decode!(line)
    end
  end

  describe "a client outside the server's tree (the operator's position)" do
    setup %{path: path} do
      start!(path, server_pid: unrelated_pid(), server_cgroup: nil)
      :ok
    end

    test "mints a workspace-agnostic coordinator token", %{path: path} do
      resp = os_client(path, %{"op" => "mint", "tier" => "coordinator", "ttl" => 120})

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.tier == :coordinator
      assert scope.workspace_id == nil
      assert scope.session_id == nil
      assert scope.can_dispatch == true
      assert resp["tier"] == "coordinator"
      assert resp["expires_in"] == 120
      assert is_binary(resp["server_url"])
    end

    test "may narrow via workspace_id / can_dispatch", %{path: path} do
      resp =
        os_client(path, %{"op" => "mint", "workspace_id" => "ws-9", "can_dispatch" => "false"})

      assert {:ok, scope} = Scope.from_token(resp["token"])
      assert scope.workspace_id == "ws-9"
      assert scope.can_dispatch == false
      assert resp["workspace_id"] == "ws-9"
    end

    test "rejects other tiers and unknown ops", %{path: path} do
      assert %{"error" => %{"message" => msg}} = os_client(path, %{"op" => "mint", "tier" => "worker"})
      assert msg =~ "coordinator"

      assert %{"error" => %{"message" => "unknown op" <> _}} = os_client(path, %{"op" => "nope"})
    end
  end

  describe "socket file" do
    test "is 0600 in a 0700 directory it created, and is removed on stop", %{path: path} do
      start!(path, server_cgroup: nil)

      assert {:ok, %{mode: mode, type: :other}} = File.lstat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert {:ok, %{mode: dmode}} = File.stat(Path.dirname(path))
      assert Bitwise.band(dmode, 0o777) == 0o700

      :ok = stop_supervised(OperatorSocket)
      assert {:error, :enoent} = File.lstat(path)
    end

    test "a stale socket from a previous run is replaced", %{path: path} do
      File.mkdir_p!(Path.dirname(path))

      {:ok, stale} =
        :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])

      :gen_tcp.close(stale)
      assert {:ok, %{type: :other}} = File.lstat(path)

      start!(path, server_cgroup: nil)
      assert {:ok, _} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false])
    end

    test "refuses to clobber a path that is not a socket", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not a socket")

      assert :ignore = OperatorSocket.init(path: path, authorize: [])
      assert File.read!(path) == "not a socket"
    end
  end
end
