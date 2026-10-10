defmodule Arbiter.Worker.EgressTest do
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Egress.Event

  setup do
    dir =
      Path.join(
        Arbiter.Config.Paths.socket_root(),
        "egt#{Base.encode16(:crypto.strong_rand_bytes(4))}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, upstream, port} = start_echo_server()
    run_id = "run#{System.unique_integer([:positive])}"
    on_exit(fn -> Egress.stop_run(run_id) end)

    %{dir: dir, upstream: upstream, port: port, run_id: run_id}
  end

  # A TCP server on 127.0.0.1 that echoes whatever it receives.
  defp start_echo_server do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> echo_accept(listen) end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    {:ok, pid, port}
  end

  defp echo_accept(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        pid =
          spawn(fn ->
            receive do
              :go -> echo(sock)
            end
          end)

        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        echo_accept(listen)

      _ ->
        :ok
    end
  end

  defp echo(sock) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} ->
        :gen_tcp.send(sock, data)
        echo(sock)

      _ ->
        :gen_tcp.close(sock)
    end
  end

  defp client(path) do
    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 2_000)

    sock
  end

  # CONNECT through `path`; returns {status_code, headers_text, socket, extra}.
  defp connect(path, authority, pipelined \\ "") do
    sock = client(path)

    :ok =
      :gen_tcp.send(
        sock,
        "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n\r\n" <> pipelined
      )

    {head, rest} = read_head(sock, "")
    "HTTP/1.1 " <> <<code::binary-size(3), _::binary>> = head
    {String.to_integer(code), head, sock, rest}
  end

  defp read_head(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 2_000)
        read_head(sock, acc <> data)
    end
  end

  defp events(run_id) do
    Event |> Ash.Query.filter(run_id == ^run_id) |> Ash.Query.sort(:inserted_at) |> Ash.read!()
  end

  defp start!(run_id, dir, opts) do
    {:ok, path} =
      Egress.start_run(run_id, Keyword.merge([dir: dir, allow_local_dial: true], opts))

    path
  end

  describe "socket and run identity" do
    test "listens on <run>.proxy.sock and removes it on stop", %{dir: dir, run_id: run_id} do
      path = start!(run_id, dir, [])
      assert Path.basename(path) == "#{run_id}.proxy.sock"
      assert File.exists?(path)
      assert Egress.running?(run_id)

      Egress.stop_run(run_id)
      refute File.exists?(path)
      refute Egress.running?(run_id)
    end

    test "the socket a request arrives on selects the run's policy", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      other = run_id <> "b"
      on_exit(fn -> Egress.stop_run(other) end)
      a = start!(run_id, dir, task_id: "bd-a", baseline: ["127.0.0.1:#{port}"])
      b = start!(other, dir, task_id: "bd-b", baseline: [])

      assert {200, _, sock_a, _} = connect(a, "127.0.0.1:#{port}")
      :gen_tcp.close(sock_a)
      assert {403, _, sock_b, _} = connect(b, "127.0.0.1:#{port}")
      :gen_tcp.close(sock_b)

      assert [%{run_id: ^run_id, task_id: "bd-a", decision: :allow}] = events(run_id)
      assert [%{run_id: ^other, task_id: "bd-b", decision: :deny}] = events(other)
    end

    test "a second start for the same run is refused", %{dir: dir, run_id: run_id} do
      start!(run_id, dir, [])
      assert {:error, :already_running} = Egress.start_run(run_id, dir: dir)
    end

    test "an invalid baseline or run id fails the start", %{dir: dir, run_id: run_id} do
      assert {:error, {:invalid_baseline, "*.com:443"}} =
               Egress.start_run(run_id, dir: dir, baseline: ["*.com:443"])

      assert {:error, :invalid_run_id} = Egress.start_run("../evil", dir: dir)
      refute Egress.running?(run_id)
    end
  end

  describe "fail closed" do
    test "after the proxy stops there is nothing to connect to", %{dir: dir, run_id: run_id} do
      path = start!(run_id, dir, [])
      Egress.stop_run(run_id)

      assert {:error, reason} =
               :gen_tcp.connect(
                 {:local, String.to_charlist(path)},
                 0,
                 [:binary, active: false],
                 1_000
               )

      assert reason in [:enoent, :econnrefused]
    end

    test "a proxy that dies abruptly leaves a socket that refuses", %{dir: dir, run_id: run_id} do
      path = start!(run_id, dir, [])
      [{listener, _}] = Registry.lookup(Arbiter.Worker.Egress.Registry, {run_id, :listener})
      [{sup, _}] = Registry.lookup(Arbiter.Worker.Egress.Registry, {run_id, :sup})
      ref = Process.monitor(sup)
      Process.exit(listener, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sup, _}

      assert {:error, _} =
               :gen_tcp.connect(
                 {:local, String.to_charlist(path)},
                 0,
                 [:binary, active: false],
                 1_000
               )
    end
  end

  describe "enforce mode" do
    test "an allowed CONNECT tunnels bytes both ways, including pipelined data", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      path = start!(run_id, dir, baseline: ["127.0.0.1:#{port}"])

      assert {200, _, sock, rest} = connect(path, "127.0.0.1:#{port}", "early")
      {:ok, echoed} = recv_n(sock, 5 - byte_size(rest), rest)
      assert echoed == "early"

      :ok = :gen_tcp.send(sock, "hello")
      assert {:ok, "hello"} = :gen_tcp.recv(sock, 5, 2_000)
      :gen_tcp.close(sock)

      assert [
               %{
                 host: "127.0.0.1",
                 decision: :allow,
                 policy_verdict: :allow,
                 mode: :enforce,
                 reason: :baseline
               }
             ] =
               events(run_id)
    end

    test "a denied CONNECT is answered 403 and recorded", %{dir: dir, port: port, run_id: run_id} do
      path = start!(run_id, dir, task_id: "bd-x")

      assert {403, head, sock, _} = connect(path, "127.0.0.1:#{port}")
      assert head =~ "X-Arbiter-Egress: not_granted"
      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)

      assert [
               %{
                 decision: :deny,
                 policy_verdict: :deny,
                 mode: :enforce,
                 reason: :not_granted,
                 port: ^port
               }
             ] =
               events(run_id)
    end

    test "a non-CONNECT request is 405 and a malformed authority is 400", %{
      dir: dir,
      run_id: run_id
    } do
      path = start!(run_id, dir, [])

      sock = client(path)
      :ok = :gen_tcp.send(sock, "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n")
      {head, _} = read_head(sock, "")
      assert head =~ "405"
      :gen_tcp.close(sock)

      assert {400, _, sock, _} = connect(path, "no-port")
      :gen_tcp.close(sock)
      assert [%{reason: :invalid_target, decision: :deny}] = events(run_id)
    end
  end

  describe "learn mode" do
    test "a would-be deny is allowed through and recorded as such", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      path = start!(run_id, dir, enforce: false)

      assert {200, _, sock, _} = connect(path, "127.0.0.1:#{port}")
      :ok = :gen_tcp.send(sock, "ping")
      assert {:ok, "ping"} = :gen_tcp.recv(sock, 4, 2_000)
      :gen_tcp.close(sock)

      assert [%{decision: :allow, policy_verdict: :deny, mode: :learn, reason: :not_granted}] =
               events(run_id)
    end

    test "public upload hosts are still denied", %{dir: dir, run_id: run_id} do
      path = start!(run_id, dir, enforce: false, grants: fn _ -> ["catbox.moe:443"] end)

      assert {403, _, sock, _} = connect(path, "catbox.moe:443")
      :gen_tcp.close(sock)
      assert [%{decision: :deny, mode: :learn, reason: :public_upload}] = events(run_id)
    end
  end

  describe ":no_public_upload" do
    test "denied at the proxy even when granted", %{dir: dir, run_id: run_id} do
      hosts = ["catbox.moe", "0x0.st", "gist.github.com"]
      path = start!(run_id, dir, grants: fn _ -> Enum.map(hosts, &"#{&1}:443") end)

      for host <- hosts do
        assert {403, head, sock, _} = connect(path, "#{host}:443")
        assert head =~ "public_upload"
        :gen_tcp.close(sock)
      end

      assert Enum.all?(events(run_id), &(&1.reason == :public_upload and &1.decision == :deny))
      assert length(events(run_id)) == 3
    end
  end

  describe "live grants" do
    test "a grant takes effect mid-run once the cache is invalidated", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      {:ok, store} = Agent.start_link(fn -> [] end)
      authority = "127.0.0.1:#{port}"
      path = start!(run_id, dir, task_id: "bd-live", grants: fn _ -> Agent.get(store, & &1) end)
      on_exit(fn -> Egress.invalidate_grants("bd-live") end)

      assert {403, _, s1, _} = connect(path, authority)
      :gen_tcp.close(s1)

      # The ticket gains a grant. Without invalidation the cached empty list
      # still answers: the cache is what the proxy reads.
      Agent.update(store, fn _ -> ["network:" <> authority] end)
      assert {403, _, s2, _} = connect(path, authority)
      :gen_tcp.close(s2)

      Egress.invalidate_grants("bd-live")
      assert {200, _, s3, _} = connect(path, authority)
      :gen_tcp.close(s3)

      # And a revocation behaves the same way.
      Agent.update(store, fn _ -> [] end)
      Egress.invalidate_grants("bd-live")
      assert {403, _, s4, _} = connect(path, authority)
      :gen_tcp.close(s4)

      assert [:not_granted, :not_granted, :grant, :not_granted] =
               Enum.map(events(run_id), & &1.reason)
    end

    test "a loader that raises denies instead of crashing the proxy", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      path = start!(run_id, dir, task_id: "bd-boom", grants: fn _ -> raise "db down" end)

      assert {403, _, sock, _} = connect(path, "127.0.0.1:#{port}")
      :gen_tcp.close(sock)
      assert Egress.running?(run_id)
    end
  end

  describe "host-side dial" do
    test "the client sends a name and the proxy resolves it", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      path = start!(run_id, dir, baseline: ["localhost:#{port}"])

      assert {200, _, sock, _} = connect(path, "localhost:#{port}")
      :ok = :gen_tcp.send(sock, "dns")
      assert {:ok, "dns"} = :gen_tcp.recv(sock, 3, 2_000)
      :gen_tcp.close(sock)
    end

    test "an unresolvable host is 502", %{dir: dir, run_id: run_id} do
      path = start!(run_id, dir, baseline: ["no-such-host.invalid:443"])

      assert {502, _, sock, _} = connect(path, "no-such-host.invalid:443")
      :gen_tcp.close(sock)
    end

    test "a granted name that resolves to the host's loopback is refused by default", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      {:ok, path} =
        Egress.start_run(run_id, dir: dir, baseline: ["localhost:#{port}", "127.0.0.1:#{port}"])

      for authority <- ["localhost:#{port}", "127.0.0.1:#{port}"] do
        assert {403, head, sock, _} = connect(path, authority)
        assert head =~ "dial_blocked"
        :gen_tcp.close(sock)
      end

      # The policy allow is recorded first, then the refused dial.
      blocked = Enum.filter(events(run_id), &(&1.reason == :dial_blocked))
      assert length(blocked) == 2
      assert Enum.all?(blocked, &(&1.decision == :deny and &1.policy_verdict == :allow))
    end

    test "local?/1 covers loopback, link-local and mapped forms" do
      local = Arbiter.Worker.Egress.Connection

      for ip <- [
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
          ] do
        assert local.local?(ip), inspect(ip)
      end

      for ip <- [{10, 0, 0, 1}, {93, 184, 216, 34}, {0x2606, 0x2800, 0, 0, 0, 0, 0, 1}] do
        refute local.local?(ip), inspect(ip)
      end
    end
  end

  describe "bridges and owner (bd-cfktou)" do
    test "a bridge splices its socket to a fixed host:port, with no policy in between", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      start!(run_id, dir, bridges: [arb: {"127.0.0.1", port}])
      path = Egress.bridge_path(run_id, :arb, dir)
      assert Path.basename(path) == "#{run_id}.arb.sock"
      assert File.exists?(path)

      sock = client(path)
      :ok = :gen_tcp.send(sock, "hello")
      assert {:ok, "hello"} = recv_n(sock, 5, "")
      :gen_tcp.close(sock)

      assert events(run_id) == []
      Egress.stop_run(run_id)
      refute File.exists?(path)
    end

    test "an unreachable bridge target closes the client instead of hanging", %{
      dir: dir,
      run_id: run_id
    } do
      {:ok, l} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, dead} = :inet.port(l)
      :gen_tcp.close(l)

      start!(run_id, dir, bridges: [t1: {"127.0.0.1", dead}])
      sock = client(Egress.bridge_path(run_id, :t1, dir))
      assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    end

    test "a bridge name that is not a plain token fails the start", %{dir: dir, run_id: run_id} do
      assert {:error, {:invalid_bridge, "../x"}} =
               Egress.start_run(run_id, dir: dir, bridges: [{"../x", {"127.0.0.1", 1}}])

      refute Egress.running?(run_id)
    end

    test "the run stops when its owner exits and removes every socket", %{
      dir: dir,
      port: port,
      run_id: run_id
    } do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      proxy = start!(run_id, dir, owner: owner, bridges: [arb: {"127.0.0.1", port}])
      bridge = Egress.bridge_path(run_id, :arb, dir)
      assert File.exists?(proxy) and File.exists?(bridge)

      [{sup, _}] = Registry.lookup(Arbiter.Worker.Egress.Registry, {run_id, :sup})
      ref = Process.monitor(sup)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sup, _}, 2_000

      refute Egress.running?(run_id)
      refute File.exists?(proxy)
      refute File.exists?(bridge)
    end
  end

  defp recv_n(_sock, n, acc) when n <= 0, do: {:ok, acc}

  defp recv_n(sock, n, acc) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 2_000)
    recv_n(sock, n - byte_size(data), acc <> data)
  end
end
