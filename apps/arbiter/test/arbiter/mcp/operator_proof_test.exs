defmodule Arbiter.MCP.OperatorProofTest do
  @moduledoc """
  `Arbiter.MCP.OperatorProof.authorize/2`, the peer policy behind the
  operator socket (bd-8381tk). The pure cases run against a fake `/proc` tree
  so they don't depend on the process layout of whichever host runs the suite.
  The real-process cases at the bottom use this VM as the "server".
  """
  use ExUnit.Case, async: true

  alias Arbiter.MCP.OperatorProof

  @uid 1000
  @server 500
  @service "/user.slice/user-1000.slice/user@1000.service/app.slice/arbiter.service"
  @terminal "/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.gnome.Terminal.slice/vte-spawn-1.scope"

  # pid => {ppid, cgroup}
  @tree %{
    1 => {0, "/init.scope"},
    400 => {1, "/user.slice/user-1000.slice/user@1000.service/init.scope"},
    # the Arbiter server and what it spawned
    @server => {400, @service},
    501 => {@server, @service},
    502 => {501, @service},
    # a worker's double-forked orphan: reparented to systemd --user, but still
    # inside the service's cgroup
    503 => {400, @service},
    # the operator's terminal
    600 => {400, @terminal},
    601 => {600, @terminal}
  }

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "opproof-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    for {pid, {ppid, cgroup}} <- @tree do
      dir = Path.join(root, Integer.to_string(pid))
      File.mkdir_p!(dir)
      # comm with a space and a ")" to exercise the parser
      File.write!(Path.join(dir, "stat"), "#{pid} (we)ird name) S #{ppid} #{pid} #{pid} 0 -1\n")
      File.write!(Path.join(dir, "cgroup"), "0::#{cgroup}\n")
    end

    {:ok, opts: [proc_root: root, server_uid: @uid, server_pid: @server, server_cgroup: @service]}
  end

  defp peer(pid, uid \\ @uid), do: %{pid: pid, uid: uid, gid: uid}

  test "the operator's terminal passes", %{opts: opts} do
    assert :ok = OperatorProof.authorize(peer(601), opts)
  end

  test "a process the server spawned (a worker, its shell) is refused", %{opts: opts} do
    assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(501), opts)
    assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(502), opts)
  end

  test "the server process itself is refused", %{opts: opts} do
    assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(@server), opts)
  end

  test "an orphan that escaped the ancestry but not the service cgroup is refused", %{opts: opts} do
    assert {:error, :in_arbiter_cgroup} = OperatorProof.authorize(peer(503), opts)
  end

  test "without a dedicated service cgroup only ancestry is checked", %{opts: opts} do
    opts = Keyword.put(opts, :server_cgroup, nil)

    assert :ok = OperatorProof.authorize(peer(503), opts)
    assert {:error, :spawned_by_arbiter} = OperatorProof.authorize(peer(502), opts)
  end

  test "a different Unix user is refused", %{opts: opts} do
    assert {:error, :foreign_uid} = OperatorProof.authorize(peer(601, 1001), opts)
  end

  test "an unreadable peer fails closed", %{opts: opts} do
    assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(9999), opts)
    assert {:error, :unknown_peer} = OperatorProof.authorize(peer(0), opts)
  end

  test "an unreadable ancestor fails closed", %{opts: opts} do
    File.rm!(Path.join([opts[:proc_root], "600", "stat"]))
    assert {:error, :peer_unreadable} = OperatorProof.authorize(peer(601), opts)
  end

  describe "dedicated_cgroup/1" do
    test "a systemd service's cgroup counts, a terminal scope does not" do
      assert OperatorProof.dedicated_cgroup("0::#{@service}\n") == @service
      assert OperatorProof.dedicated_cgroup("0::#{@terminal}\n") == nil
      assert OperatorProof.dedicated_cgroup("0::/\n") == nil
    end

    test "cgroup v1 falls back to the name=systemd hierarchy" do
      v1 = "12:pids:/user.slice\n1:name=systemd:/system.slice/arbiter.service\n0::/\n"
      assert OperatorProof.dedicated_cgroup(v1) == "/system.slice/arbiter.service"
    end
  end

  describe "parse_peercred/1" do
    test "decodes struct ucred" do
      bin = <<42::native-signed-32, 1000::native-signed-32, 1001::native-signed-32>>
      assert OperatorProof.parse_peercred(bin) == {:ok, %{pid: 42, uid: 1000, gid: 1001}}
      assert OperatorProof.parse_peercred(<<1, 2>>) == :error
    end
  end

  describe "socket paths" do
    test "the socket is keyed by port under the socket dir" do
      assert OperatorProof.socket_path(4848) ==
               Path.join(OperatorProof.socket_dir(), "operator-4848.sock")
    end

    test "the default dir is the per-user runtime dir when the host has one" do
      {:ok, %{uid: uid}} = File.stat("/proc/self")
      runtime = "/run/user/#{uid}"

      if File.dir?(runtime) do
        assert OperatorProof.socket_dir() == Path.join(runtime, "arbiter")
      end
    end
  end

  describe "real processes (this VM plays the server)" do
    test "a child process of this VM is refused" do
      port =
        Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["30"]])

      {:os_pid, child} = Port.info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", [Integer.to_string(child)]) end)

      assert {:error, :spawned_by_arbiter} =
               OperatorProof.authorize(%{pid: child, uid: own_uid(), gid: 0}, server_cgroup: nil)
    end

    test "a process outside this VM's tree passes the ancestry check" do
      # This test process's own OS parent is outside the VM, so it stands in
      # for the operator's shell when the "server" is this VM.
      outside = ppid_of(String.to_integer(System.pid()))

      assert :ok =
               OperatorProof.authorize(%{pid: outside, uid: own_uid(), gid: 0},
                 server_cgroup: nil
               )
    end
  end

  defp own_uid do
    {:ok, %{uid: uid}} = File.stat("/proc/self")
    uid
  end

  defp ppid_of(pid) do
    [_, rest] = "/proc/#{pid}/stat" |> File.read!() |> String.split(")", parts: 2)
    [_state, ppid | _] = String.split(rest)
    String.to_integer(ppid)
  end
end
