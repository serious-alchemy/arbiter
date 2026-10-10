defmodule Arbiter.NodeAgent.BridgeTest do
  @moduledoc """
  The agent's end of the bridge mux (`Arbiter.NodeAgent.Bridge`, RW10): the
  per-run listeners, what an accepted connection becomes on the channel, a
  channel that comes and goes, and the end of a run. The channel is a stand-in
  that records what the bridge pushes; the primary's half is played by an
  `Arbiter.Nodes.Bridge.Core`.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.NodeAgent.Bridge
  alias Arbiter.Nodes.Bridge.Frame

  defmodule FakeClient do
    @moduledoc false
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:push, _topic, event, payload}, _from, test) do
      send(test, {:pushed, event, payload})
      {:reply, "ref", test}
    end
  end

  setup do
    home =
      Path.join(Arbiter.Config.Paths.socket_root(), "nab-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    bridge = start_supervised!({Bridge, node_home: home, name: nil, hold_ms: 1_500, hold_max: 2})
    %{bridge: bridge, home: home}
  end

  defp client(bridge) do
    {:ok, pid} = FakeClient.start_link(self())
    :ok = Bridge.attach(bridge, pid, "node:n1")
    pid
  end

  defp dial(path) do
    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 2_000)

    sock
  end

  defp listen!(bridge, run, names \\ ["arb"]) do
    {:ok, paths} =
      Bridge.listen(bridge, run, Enum.map(names, &%{name: &1, path: "/x/#{&1}.sock"}))

    paths
  end

  test "listens on a 0700 per-run directory, one socket per declared bridge", %{
    bridge: bridge,
    home: home
  } do
    [arb, proxy] = listen!(bridge, "r1", ["arb", "proxy"])
    assert Path.dirname(arb) == Path.join([home, "runs", "r1", "bridge"])
    assert Path.basename(proxy) == "proxy.sock"
    assert File.stat!(Path.dirname(arb)).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(arb).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a path too long for a unix socket is refused", %{bridge: bridge} do
    assert {:error, {:path_too_long, _}} =
             Bridge.listen(bridge, String.duplicate("r", 90), [%{name: "arb", path: "/x"}])
  end

  test "an accepted connection opens a stream and its bytes become frames", %{bridge: bridge} do
    [path] = listen!(bridge, "r1")
    client(bridge)

    sock = dial(path)

    assert_receive {:pushed, "bridge.open", %{"run" => "r1", "name" => "arb", "stream" => id}},
                   2_000

    :ok = :gen_tcp.send(sock, "hello")
    assert_receive {:pushed, "bridge.data", {:binary, frame}}, 2_000
    assert %{stream: ^id, seq: 0, bytes: "hello"} = Frame.decode!(frame)
  end

  test "bytes from the primary are written to the connection and credited", %{bridge: bridge} do
    [path] = listen!(bridge, "r1")
    client(bridge)
    sock = dial(path)
    assert_receive {:pushed, "bridge.open", %{"stream" => id}}, 2_000

    Bridge.from_primary(bridge, "bridge.data", {:binary, Frame.encode(0, id, "from the primary")})
    assert {:ok, "from the primary"} = :gen_tcp.recv(sock, 16, 2_000)
    assert_receive {:pushed, "bridge.recv", %{"n" => 16}}, 2_000
    assert_receive {:pushed, "bridge.credit", %{"stream" => ^id, "n" => 16}}, 2_000
  end

  test "a reset from the primary closes the connection", %{bridge: bridge} do
    [path] = listen!(bridge, "r1")
    client(bridge)
    sock = dial(path)
    assert_receive {:pushed, "bridge.open", %{"stream" => id}}, 2_000

    Bridge.from_primary(bridge, "bridge.reset", %{"stream" => id, "reason" => "unknown_run"})
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    assert %{streams: []} = Bridge.info(bridge)
  end

  test "a closed connection announces a half close and, once both ends are done, goes", %{
    bridge: bridge
  } do
    [path] = listen!(bridge, "r1")
    client(bridge)
    sock = dial(path)
    assert_receive {:pushed, "bridge.open", %{"stream" => id}}, 2_000

    :ok = :gen_tcp.shutdown(sock, :write)
    assert_receive {:pushed, "bridge.close", %{"stream" => ^id}}, 2_000
    Bridge.from_primary(bridge, "bridge.close", %{"stream" => id})
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
  end

  test "losing the channel ends every stream; a connection made meanwhile is held, then opened",
       %{bridge: bridge} do
    [path] = listen!(bridge, "r1")
    client(bridge)
    first = dial(path)
    assert_receive {:pushed, "bridge.open", %{"stream" => id1}}, 2_000

    :ok = Bridge.detach(bridge)
    assert {:error, :closed} = :gen_tcp.recv(first, 0, 2_000)

    held = dial(path)
    # Accepted by the agent, not yet opened on any channel.
    assert_eventually(fn -> Bridge.info(bridge).held == 1 end)
    refute_received {:pushed, "bridge.open", _}

    client(bridge)
    assert_receive {:pushed, "bridge.open", %{"stream" => id2, "name" => "arb"}}, 2_000
    assert id2 > id1
    :gen_tcp.close(held)
  end

  test "a held connection that outlives the hold is closed", %{bridge: bridge} do
    [path] = listen!(bridge, "r1")
    held = dial(path)
    assert_eventually(fn -> Bridge.info(bridge).held == 1 end)
    assert {:error, :closed} = :gen_tcp.recv(held, 0, 5_000)
    assert Bridge.info(bridge).held == 0
  end

  test "more held connections than the cap close the oldest", %{bridge: bridge} do
    [path] = listen!(bridge, "r1")
    socks = for _ <- 1..3, do: dial(path)
    assert_eventually(fn -> Bridge.info(bridge).held == 2 end)
    assert {:error, :closed} = :gen_tcp.recv(hd(socks), 0, 2_000)
  end

  test "the stream cap refuses the connection rather than queueing it" do
    home =
      Path.join(Arbiter.Config.Paths.socket_root(), "nab-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    capped =
      start_supervised!(
        {Bridge, node_home: home, name: nil, limits: %{max_streams_per_run: 1}},
        id: :capped
      )

    [path] = listen!(capped, "r1")
    client(capped)
    _one = dial(path)
    assert_receive {:pushed, "bridge.open", _}, 2_000

    two = dial(path)
    assert {:error, :closed} = :gen_tcp.recv(two, 0, 2_000)
    assert %{streams: [_]} = Bridge.info(capped)
  end

  test "release closes the run's listeners, streams and held connections", %{
    bridge: bridge,
    home: home
  } do
    [path] = listen!(bridge, "r1")
    client(bridge)
    sock = dial(path)
    assert_receive {:pushed, "bridge.open", %{"stream" => id}}, 2_000

    assert :ok = Bridge.release(bridge, "r1")
    assert_receive {:pushed, "bridge.reset", %{"stream" => ^id, "reason" => "run_over"}}, 2_000
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    refute File.exists?(path)
    assert File.exists?(Path.join(home, "runs"))
    assert {:error, _} = :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [])
  end

  test "a frame that is not a frame drops the channel, not the agent", %{bridge: bridge} do
    [path] = listen!(bridge, "r1")
    client(bridge)
    sock = dial(path)
    assert_receive {:pushed, "bridge.open", _}, 2_000

    Bridge.from_primary(bridge, "bridge.data", {:binary, "garbage"})
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 2_000)
    assert Process.alive?(bridge)
  end

  test "events with no channel attached are ignored", %{bridge: bridge} do
    Bridge.from_primary(bridge, "bridge.data", {:binary, Frame.encode(0, 1, "x")})
    assert %{streams: []} = Bridge.info(bridge)
  end

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          20 -> assert_eventually(fun, tries - 1)
        end
    end
  end
end
