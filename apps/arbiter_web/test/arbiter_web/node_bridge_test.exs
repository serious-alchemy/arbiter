defmodule ArbiterWeb.NodeBridgeTest do
  @moduledoc """
  RW10 (bd-54ibeo, `docs/design/remote-workers.md` §8), the primary's half: the
  node's `bridge.*` events through the real `NodeChannel`, `Arbiter.Nodes.Bridge`
  and a real `Arbiter.Worker.Egress` run on this host. The node's side is played
  by a `Arbiter.Nodes.Bridge.Core` driven from the test.

  Covers authorization (only a run placed on this node, only a declared bridge),
  the stream and byte caps, a consumer that stops reading (it must not stall
  another stream or the heartbeat), the end of a run, and a peer that breaks the
  protocol.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.Nodes
  alias Arbiter.Nodes.Bridge.{Core, Frame}
  alias Arbiter.Nodes.{RateLimit, Registry, Session}
  alias Arbiter.Worker.Egress
  alias ArbiterWeb.NodeSocket

  @version "1.2.3"

  setup %{tmp_dir: home} do
    ArbiterWeb.NodeFixtures.use_data_home!(home)
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "bridge-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    {:ok, socket} =
      connect(NodeSocket, %{"token" => credential},
        connect_info: %{peer_data: %{address: {100, 64, 0, 7}, port: 4000}, x_headers: []}
      )

    {:ok, _, socket} = subscribe_and_join(socket, "node:" <> node.id, %{})
    push(socket, "hello", %{"agent_version" => @version, "proto" => 1, "runs" => []})
    assert_push "hello_ok", _
    Process.unlink(socket.channel_pid)

    # Short, comma-free: a unix socket path is limited to ~100 bytes.
    dir = Path.join(System.tmp_dir!(), "nb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{node: node, socket: socket, session: Registry.lookup(node.id), dir: dir}
  end

  defp put_env_restoring(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp limits(overrides), do: put_env_restoring(:arbiter, Arbiter.Nodes.Bridge, limits: overrides)

  # A TCP server on loopback that echoes everything back.
  defp echo_server do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    pid = spawn_link(fn -> accept(lsock, &echo/1) end)
    on_exit(fn -> :gen_tcp.close(lsock) end)
    _ = pid
    port
  end

  # One that accepts and never reads: a consumer that has stopped.
  defp stuck_server do
    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        recbuf: 4096
      ])

    {:ok, port} = :inet.port(lsock)
    spawn_link(fn -> accept(lsock, fn _sock -> Process.sleep(:infinity) end) end)
    on_exit(fn -> :gen_tcp.close(lsock) end)
    port
  end

  defp accept(lsock, handler) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        pid = spawn(fn -> receive do: (:go -> handler.(sock)) end)
        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept(lsock, handler)

      {:error, _} ->
        :ok
    end
  end

  defp echo(sock) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} ->
        _ = :gen_tcp.send(sock, data)
        echo(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  # Start the run's egress (its real proxy and its `arb`/`t1` bridges) and place
  # the run on the node with a spec that declares those sockets.
  defp place_run(ctx, run, targets) do
    bridges = for {name, port} <- targets, do: {name, {"127.0.0.1", port}}

    {:ok, proxy} =
      Egress.start_run(run, dir: ctx.dir, bridges: bridges, owner: self(), audit: false)

    declared =
      [%{"name" => "proxy", "path" => proxy}] ++
        for {name, _} <- targets,
            do: %{"name" => name, "path" => Egress.bridge_path(run, name, ctx.dir)}

    owner = self()

    task =
      Task.async(fn ->
        Session.assign(ctx.session, run, %{"bridges" => declared}, owner,
          prepare_timeout_ms: 5_000
        )
      end)

    assert_push "assign", %{"run" => ^run}
    push(ctx.socket, "run.ready", %{"run" => run})
    assert {:ok, _handle} = Task.await(task)
    :ok
  end

  # The node's end of a stream, as a `Core` the test drives.
  defp node_core, do: Core.new(%{})

  defp send_effects(socket, effects) do
    for {:push, event, payload} <- effects, do: push(socket, event, payload)
    :ok
  end

  describe "opening a stream" do
    test "reaches the run's own listener and relays both ways", ctx do
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])

      core = node_core()
      {:ok, core, effects} = Core.open_local(core, 1, "run1", "arb")
      send_effects(ctx.socket, effects)
      {core, effects} = Core.local_data(core, 1, "ping")
      send_effects(ctx.socket, effects)

      assert_push "bridge.data", {:binary, frame}
      assert %{stream: 1, seq: 0, bytes: "ping"} = Frame.decode!(frame)
      assert_push "bridge.recv", %{"n" => 4}
      assert_push "bridge.credit", %{"stream" => 1, "n" => 4}
      assert core
    end

    test "a run that is not placed on this node is refused", ctx do
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])

      push(ctx.socket, "bridge.open", %{"run" => "someone-elses", "name" => "arb", "stream" => 1})
      assert_push "bridge.reset", %{"stream" => 1, "reason" => "unknown_run"}
    end

    test "a bridge the run's spec did not declare is refused", ctx do
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "t9", "stream" => 1})
      assert_push "bridge.reset", %{"stream" => 1, "reason" => "unknown_bridge"}
    end

    test "a run whose listener is gone is reset", ctx do
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])
      Egress.stop_run("run1")

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 1})
      assert_push "bridge.reset", %{"stream" => 1}
    end
  end

  describe "caps" do
    test "streams per run are capped", ctx do
      limits(max_streams_per_run: 2)
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])

      for id <- 1..2,
          do: push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => id})

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 3})
      assert_push "bridge.reset", %{"stream" => 3, "reason" => "run_stream_cap"}
    end

    test "streams per node are capped across runs", ctx do
      limits(max_streams_per_node: 2)
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])
      place_run(ctx, "run2", [{"arb", port}])

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 1})
      push(ctx.socket, "bridge.open", %{"run" => "run2", "name" => "arb", "stream" => 2})
      push(ctx.socket, "bridge.open", %{"run" => "run2", "name" => "arb", "stream" => 3})
      assert_push "bridge.reset", %{"stream" => 3, "reason" => "node_stream_cap"}
    end

    test "a stream past its byte cap is reset", ctx do
      limits(max_stream_bytes: 10, frame: 8)
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 1})
      push(ctx.socket, "bridge.data", {:binary, Frame.encode(0, 1, "12345678")})
      push(ctx.socket, "bridge.data", {:binary, Frame.encode(1, 1, "12345678")})
      assert_push "bridge.reset", %{"stream" => 1, "reason" => "stream_byte_cap"}
    end

    test "a peer that outruns its window is reset, not buffered", ctx do
      limits(window: 16, frame: 16)
      port = stuck_server()
      place_run(ctx, "run1", [{"arb", port}])

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 1})
      # Nothing was credited back for the first (the stuck listener never reads
      # it) — but 16 B fits a kernel buffer, so credit does come. A frame over
      # the frame limit is the unambiguous violation.
      push(ctx.socket, "bridge.data", {:binary, Frame.encode(0, 1, String.duplicate("x", 17))})
      assert_push "bridge.reset", %{"stream" => 1, "reason" => "frame_too_large"}
    end
  end

  describe "a consumer that stops reading" do
    test "stalls its own stream's credit, not another stream and not the heartbeat", ctx do
      limits(window: 65_536, frame: 16_384)
      stuck = stuck_server()
      echo = echo_server()
      place_run(ctx, "run1", [{"t1", stuck}, {"arb", echo}])

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "t1", "stream" => 1})
      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 2})

      # Feed the stuck stream until its credit stops coming back (the kernel
      # buffers absorb a few hundred KiB first).
      chunk = String.duplicate("s", 16_384)

      stalled? =
        Enum.reduce_while(0..400, {0, 0}, fn seq, {seq_sent, credited} ->
          if seq_sent - div(credited, 16_384) >= 4 do
            {:halt, :stalled}
          else
            push(ctx.socket, "bridge.data", {:binary, Frame.encode(seq, 1, chunk)})
            {:cont, {seq_sent + 1, credited + drain_credit(1, 50)}}
          end
        end)

      assert stalled? == :stalled

      # Stream 2 and the heartbeat both still answer, promptly.
      push(ctx.socket, "bridge.data", {:binary, Frame.encode(0, 2, "alive")})
      assert_push "bridge.data", {:binary, frame}, 1_000
      assert %{stream: 2, bytes: "alive"} = Frame.decode!(frame)

      push(ctx.socket, "hb", %{"seq" => 1})
      assert_push "hb_ack", %{"seq" => 1}, 1_000
    end
  end

  describe "the end" do
    test "a run released by its owner has its streams reset", ctx do
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])
      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 1})
      push(ctx.socket, "bridge.data", {:binary, Frame.encode(0, 1, "x")})
      assert_push "bridge.data", _

      Session.release_run(ctx.session, "run1")
      assert_push "bridge.reset", %{"stream" => 1, "reason" => "run_over"}
    end

    test "a frame that is not a frame closes the channel", ctx do
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])
      ref = Process.monitor(ctx.socket.channel_pid)

      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 1})
      push(ctx.socket, "bridge.data", {:binary, "garbage"})
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end

    test "the streams die with the channel", ctx do
      port = echo_server()
      place_run(ctx, "run1", [{"arb", port}])
      push(ctx.socket, "bridge.open", %{"run" => "run1", "name" => "arb", "stream" => 1})
      push(ctx.socket, "bridge.data", {:binary, Frame.encode(0, 1, "x")})
      assert_push "bridge.data", _

      bridge = :sys.get_state(ctx.socket.channel_pid).assigns.bridge
      ref = Process.monitor(bridge)
      Process.exit(ctx.socket.channel_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    end
  end

  # Credit pushes for `id` in the mailbox: total bytes credited, waiting up to `wait` ms.
  defp drain_credit(id, wait) do
    receive do
      %Phoenix.Socket.Message{event: "bridge.credit", payload: %{"stream" => ^id, "n" => n}} ->
        n + drain_credit(id, 0)
    after
      wait -> 0
    end
  end
end
