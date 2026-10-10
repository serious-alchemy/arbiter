defmodule Arbiter.NodeAgent.PodChannel.BridgeListenerTest do
  @moduledoc """
  The pod channel's bridge listener, `:9443` (`docs/design/remote-workers.md` §16
  K§9.3): mTLS, a leaf per run per bridge, and a relay into the same
  `Arbiter.NodeAgent.Bridge` the machine agent uses.

  Acceptance: a bridge connection needs a valid leaf certificate for a live run
  this controller assigned, with a bridge name from that run's spec; anything
  else is refused. With TLS 1.3 a client's handshake completes before the server
  has checked its certificate, so a rejected client shows up as an immediate
  close and these tests assert on the **listener's verdict**
  (`{:pod_channel_verdict, ...}`), never on the client's connect result.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Arbiter.NodeAgent.Bridge
  alias Arbiter.NodeAgent.PodChannel.{BridgeListener, Cert, Runs}
  alias Arbiter.NodeAgent.PodChannelKit, as: Kit
  alias Arbiter.Nodes.Bridge.Frame

  @loopback {127, 0, 0, 1}

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

  setup %{tmp_dir: tmp} do
    ca = Kit.ca()
    runs = start_supervised!({Runs, ca: ca, name: nil})
    bridge = start_supervised!({Bridge, node_home: tmp, name: nil})
    {:ok, client} = FakeClient.start_link(self())
    :ok = Bridge.attach(bridge, client, "node:n1")

    listener =
      start_supervised!(
        {BridgeListener,
         identity: Kit.server_identity(ca),
         ca: ca,
         runs: runs,
         bridge: bridge,
         ip: @loopback,
         port: 0,
         notify: self(),
         handshake_timeout_ms: 1_000}
      )

    %{ca: ca, runs: runs, bridge: bridge, port: BridgeListener.port(listener), listener: listener}
  end

  defp boot(ctx, run \\ "run-1", bridges \\ ["proxy", "arb"], ip \\ @loopback),
    do: Kit.boot!(ctx.runs, Kit.spec!(run, bridges), ip)

  defp connect(ctx, opts),
    do: :ssl.connect(@loopback, ctx.port, [:binary, active: false] ++ opts, 5_000)

  defp assert_refused(reason) do
    assert_receive {:pod_channel_verdict, :bridge, {:error, ^reason}}, 5_000
    refute_received {:pushed, "bridge.open", _}
  end

  describe "a valid leaf" do
    test "opens a stream as the named bridge of its run", ctx do
      %{files: files} = boot(ctx)
      assert {:ok, sock} = connect(ctx, Kit.client_opts(files, "proxy", ctx.ca))

      assert_receive {:pod_channel_verdict, :bridge, {:ok, %{run: "run-1", name: "proxy"}}}, 5_000

      assert_receive {:pushed, "bridge.open",
                      %{"run" => "run-1", "name" => "proxy", "stream" => id}},
                     5_000

      :ok = :ssl.send(sock, "hello")
      assert_receive {:pushed, "bridge.data", {:binary, frame}}, 5_000
      assert %{stream: ^id, bytes: "hello"} = Frame.decode!(frame)
    end

    test "bytes from the primary come back over TLS", ctx do
      %{files: files} = boot(ctx)
      {:ok, sock} = connect(ctx, Kit.client_opts(files, "arb", ctx.ca))
      assert_receive {:pushed, "bridge.open", %{"name" => "arb", "stream" => id}}, 5_000

      Bridge.from_primary(
        ctx.bridge,
        "bridge.data",
        {:binary, Frame.encode(0, id, "from the primary")}
      )

      assert {:ok, "from the primary"} = :ssl.recv(sock, 16, 5_000)
    end

    test "each bridge name is its own identity", ctx do
      %{files: files} = boot(ctx)
      {:ok, _a} = connect(ctx, Kit.client_opts(files, "proxy", ctx.ca))
      {:ok, _b} = connect(ctx, Kit.client_opts(files, "arb", ctx.ca))

      assert_receive {:pushed, "bridge.open", %{"name" => "proxy"}}, 5_000
      assert_receive {:pushed, "bridge.open", %{"name" => "arb"}}, 5_000
    end
  end

  describe "a connection is refused" do
    test "without a client certificate", ctx do
      connect(ctx, Kit.client_opts_no_cert(ctx.ca))

      assert_receive {:pod_channel_verdict, :bridge, {:error, {:handshake, _}}}, 5_000
      refute_received {:pushed, "bridge.open", _}
    end

    test "with a certificate from another CA", ctx do
      boot(ctx)
      other = Kit.ca()
      now = DateTime.utc_now()
      leaf = Cert.leaf(other, "run-1", "proxy", DateTime.add(now, -60), DateTime.add(now, 600))
      connect(ctx, Kit.client_opts_leaf(leaf, ctx.ca))

      assert_receive {:pod_channel_verdict, :bridge, {:error, {:handshake, _}}}, 5_000
      refute_received {:pushed, "bridge.open", _}
    end

    test "with an expired certificate", ctx do
      boot(ctx)
      now = DateTime.utc_now()

      leaf =
        Cert.leaf(ctx.ca, "run-1", "proxy", DateTime.add(now, -7200), DateTime.add(now, -3600))

      connect(ctx, Kit.client_opts_leaf(leaf, ctx.ca))

      assert_receive {:pod_channel_verdict, :bridge, {:error, {:handshake, _}}}, 5_000
    end

    test "with a certificate that is not for client authentication", ctx do
      boot(ctx)
      now = DateTime.utc_now()

      leaf =
        Cert.leaf(ctx.ca, "run-1", "proxy", DateTime.add(now, -60), DateTime.add(now, 600),
          eku: :server
        )

      connect(ctx, Kit.client_opts_leaf(leaf, ctx.ca))

      assert_receive {:pod_channel_verdict, :bridge, {:error, {:handshake, _}}}, 5_000
    end

    test "with the controller's own server certificate", ctx do
      identity = Kit.server_identity(ctx.ca)
      connect(ctx, Kit.client_opts_leaf(identity, ctx.ca))

      assert_receive {:pod_channel_verdict, :bridge, {:error, {:handshake, _}}}, 5_000
    end

    test "for a run this controller never assigned", ctx do
      boot(ctx)
      now = DateTime.utc_now()
      stray = Cert.leaf(ctx.ca, "run-9", "proxy", DateTime.add(now, -60), DateTime.add(now, 600))
      {:ok, sock} = connect(ctx, Kit.client_opts_leaf(stray, ctx.ca))

      assert_refused(:unknown_run)
      assert {:error, _} = recv_closed(sock)
    end

    test "for a bridge the run's spec does not name", ctx do
      boot(ctx)
      now = DateTime.utc_now()
      stray = Cert.leaf(ctx.ca, "run-1", "git", DateTime.add(now, -60), DateTime.add(now, 600))
      connect(ctx, Kit.client_opts_leaf(stray, ctx.ca))

      assert_refused(:unknown_bridge)
    end

    test "with the run's control leaf", ctx do
      %{files: files} = boot(ctx)
      connect(ctx, Kit.client_opts(files, "control", ctx.ca))

      assert_refused(:wrong_purpose)
    end

    test "once the run has been released", ctx do
      %{files: files} = boot(ctx)
      :ok = Runs.release(ctx.runs, "run-1")
      connect(ctx, Kit.client_opts(files, "proxy", ctx.ca))

      assert_refused(:unknown_run)
    end

    test "from an address other than the pod's", ctx do
      %{files: files} = boot(ctx, "run-1", ["proxy"], {10, 42, 0, 61})
      connect(ctx, Kit.client_opts(files, "proxy", ctx.ca))

      assert_refused(:wrong_ip)
    end
  end

  test "a client that does not trust the controller's certificate does not connect", ctx do
    %{files: files} = boot(ctx)
    other = Kit.ca()

    assert {:error, _} = connect(ctx, Kit.client_opts(files, "proxy", other))
  end

  test "a client that stalls in the handshake is dropped", ctx do
    {:ok, sock} = :gen_tcp.connect(@loopback, ctx.port, [:binary, active: false])

    assert_receive {:pod_channel_verdict, :bridge, {:error, {:handshake, :timeout}}}, 10_000
    assert {:error, :closed} = :gen_tcp.recv(sock, 0, 5_000)
  end

  defp recv_closed(sock), do: :ssl.recv(sock, 0, 5_000)
end
