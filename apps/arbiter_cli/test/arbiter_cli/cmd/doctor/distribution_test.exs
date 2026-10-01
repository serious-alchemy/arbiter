defmodule ArbiterCli.Cmd.Doctor.DistributionTest do
  @moduledoc """
  bd-51m9ba: the doctor check that Erlang distribution (epmd + the release
  node's listener) is loopback-only and the release cookie is owner-only.
  Every input — the `/proc/net/tcp*` tables, epmd, the cookie files — is a
  fixture, so the verdict never depends on the host this runs on.
  """
  use ExUnit.Case, async: true

  alias ArbiterCli.Cmd.Doctor.Checks.Result
  alias ArbiterCli.Cmd.Doctor.Distribution

  @header "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"

  @moduletag :tmp_dir

  # Real /proc/net/tcp rows (x86, little-endian words), taken from a host.
  defp row(local, state \\ "0A", remote \\ "00000000:0000") do
    "  21: #{local} #{remote} #{state} 00000000:00000000 00:00000000 00000000  1000        0 71165863 1 000000000fbb109e 100 0 0 10 0\n"
  end

  defp proc_net!(dir, name, rows) do
    path = Path.join(dir, name)
    File.write!(path, [@header | rows])
    path
  end

  defp cookie!(dir, name, mode) do
    path = Path.join(dir, name)
    File.write!(path, "secret")
    File.chmod!(path, mode)
    path
  end

  # A one-shot fake epmd answering NAMES_REQ (<<1::16, 110>>) the way the real
  # one does: a 4-byte epmd port, then one "name X at port N" line per node.
  defp fake_epmd!(names) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    body = Enum.map(names, fn {name, p} -> "name #{name} at port #{p}\n" end)

    serve =
      Task.async(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 5_000)
        {:ok, <<1::16, 110>>} = :gen_tcp.recv(sock, 3, 5_000)
        :ok = :gen_tcp.send(sock, [<<port::32>> | body])
        :gen_tcp.close(sock)
      end)

    on_exit(fn -> :gen_tcp.close(listen) end)
    {port, serve}
  end

  defp check(opts), do: Distribution.check(Keyword.put_new(opts, :cookie_paths, []))

  test "all loopback and an owner-only cookie is green, and says what it saw", %{tmp_dir: dir} do
    {epmd_port, serve} = fake_epmd!([{"arbiter", 39_783}])

    tcp = proc_net!(dir, "tcp", [row("0100007F:1111"), row("0100007F:9B67")])
    tcp6 = proc_net!(dir, "tcp6", [])
    cookie = cookie!(dir, "release.cookie", 0o600)

    result =
      check(
        proc_net: [tcp, tcp6],
        epmd_port: epmd_port,
        epmd_listen_port: 4369,
        cookie_paths: [cookie]
      )

    Task.await(serve)
    assert %Result{status: :ok, fatal: true, blocks_readiness: false} = result
    assert result.detail =~ "epmd 127.0.0.1:4369"
    assert result.detail =~ "arbiter 127.0.0.1:39783"
    assert result.detail =~ "#{cookie} 0600"
  end

  test "epmd bound to every IPv4 interface fails", %{tmp_dir: dir} do
    tcp = proc_net!(dir, "tcp", [row("00000000:1111")])

    result = check(proc_net: [tcp], epmd_port: nil, epmd_listen_port: 4369)

    assert %Result{status: :fail, fatal: true} = result
    assert result.detail =~ "epmd listens on 0.0.0.0:4369"
    assert result.hint =~ "ERL_EPMD_ADDRESS"
  end

  test "epmd bound to the IPv6 wildcard fails", %{tmp_dir: dir} do
    tcp = proc_net!(dir, "tcp", [row("0100007F:1111")])
    tcp6 = proc_net!(dir, "tcp6", [row("00000000000000000000000000000000:1111")])

    result = check(proc_net: [tcp, tcp6], epmd_port: nil, epmd_listen_port: 4369)

    assert result.status == :fail
    assert result.detail =~ "epmd listens on [::]:4369"
  end

  test "IPv6 loopback and v4-mapped loopback count as loopback", %{tmp_dir: dir} do
    tcp6 =
      proc_net!(dir, "tcp6", [
        row("00000000000000000000000001000000:1111"),
        row("0000000000000000FFFF00000100007F:1111")
      ])

    result = check(proc_net: [tcp6], epmd_port: nil, epmd_listen_port: 4369)

    assert result.status == :ok
    assert result.detail =~ "[::1]:4369"
  end

  test "the release node's distribution port on 0.0.0.0 fails", %{tmp_dir: dir} do
    {epmd_port, serve} = fake_epmd!([{"rpc-1a2b-arbiter", 41_000}, {"arbiter", 39_783}])

    # An established connection's local side is not a listener — ignored.
    tcp =
      proc_net!(dir, "tcp", [
        row("0100007F:1111"),
        row("00000000:9B67"),
        row("2601A8C0:1111", "01", "0100007F:D1AC")
      ])

    result = check(proc_net: [tcp], epmd_port: epmd_port, epmd_listen_port: 4369)

    Task.await(serve)
    assert result.status == :fail
    assert result.detail =~ "arbiter listens on 0.0.0.0:39783"
    refute result.detail =~ "192.168.1.38"
    assert result.hint =~ "inet_dist_use_interface"
  end

  test "a group- or world-readable cookie fails, naming the file and its mode", %{tmp_dir: dir} do
    tcp = proc_net!(dir, "tcp", [])
    world = cookie!(dir, "COOKIE", 0o644)
    group = cookie!(dir, "release.cookie", 0o640)

    result = check(proc_net: [tcp], epmd_port: nil, cookie_paths: [world, group])

    assert result.status == :fail
    assert result.detail =~ "#{world} is 0644"
    assert result.detail =~ "#{group} is 0640"
    assert result.hint =~ "chmod 600"
  end

  test "a missing cookie file is not a failure", %{tmp_dir: dir} do
    tcp = proc_net!(dir, "tcp", [])

    result =
      check(proc_net: [tcp], epmd_port: nil, cookie_paths: [Path.join(dir, "absent.cookie")])

    assert result.status == :ok
  end

  test "nothing listening and no epmd reads as distribution not running", %{tmp_dir: dir} do
    tcp = proc_net!(dir, "tcp", [])

    result = check(proc_net: [tcp], epmd_port: nil)

    assert result.status == :ok
    assert result.detail =~ "not running"
  end

  test "unreadable socket tables skip the bind half but still judge the cookie", %{tmp_dir: dir} do
    cookie = cookie!(dir, "release.cookie", 0o604)

    result =
      check(proc_net: [Path.join(dir, "missing")], epmd_port: nil, cookie_paths: [cookie])

    assert result.status == :fail
    assert result.detail =~ "listeners unknown"
    assert result.detail =~ "0604"
  end

  test "default cookie paths are the per-install cookie and the current release's COOKIE" do
    assert Distribution.cookie_paths("/data") == [
             "/data/release.cookie",
             "/data/current/releases/COOKIE"
           ]
  end
end
