defmodule ArbiterWeb.NodeChannelTest do
  @moduledoc """
  RW6 (bd-uixe28, `docs/design/remote-workers.md` §4.1, §4.2, §10.1, §10.2):
  the primary's node socket and channel — authentication, hello/hello_ok,
  heartbeat, suspect/fence/lost, drain and revoke.

  `Phoenix.ChannelTest` has no transport, so the revoke test also runs against
  a real Bandit listener (`ArbiterWeb.NodeTestEndpoint`) and watches the
  WebSocket close.
  """
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry, Session}
  alias ArbiterWeb.NodeSocket
  alias ArbiterWeb.Spike.WsClient

  @version "1.2.3"

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    # An outdated hello looks up the release to upgrade to: keep it on a fixture
    # tree, never the operator's real `~/.arbiter`.
    ArbiterWeb.NodeFixtures.use_data_home!(home)
    # The skew verdict compares against the primary's version, which `git
    # describe` makes ambient (a tagless CI clone is 0.0.0): pin it.
    previous_version = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)

    on_exit(fn ->
      case previous_version do
        {:ok, v} -> Application.put_env(:arbiter, :node_primary_version, v)
        :error -> Application.delete_env(:arbiter, :node_primary_version)
      end
    end)

    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)

    previous = Application.fetch_env(:arbiter_web, :node_session_opts)

    Application.put_env(:arbiter_web, :node_session_opts,
      clock: fn -> Agent.get(clock, & &1) end,
      tick_ms: :infinity
    )

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter_web, :node_session_opts, v)
        :error -> Application.delete_env(:arbiter_web, :node_session_opts)
      end

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    {node, credential} = enroll!("chan-node")
    %{clock: clock, node: node, credential: credential}
  end

  defp enroll!(name, opts \\ []) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name] ++ opts, "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(token)
    {node, credential}
  end

  defp advance(clock, seconds), do: Agent.update(clock, &(&1 + seconds * 1000))

  defp hello(overrides \\ %{}) do
    Map.merge(
      %{
        "agent_version" => @version,
        "proto" => 1,
        "caps" => %{"backend" => "podman"},
        "capacity" => %{"suggestion" => 2},
        "runs" => []
      },
      overrides
    )
  end

  defp connect_node(credential, params \\ %{}) do
    connect(NodeSocket, Map.put(params, "token", credential), connect_info: connect_info())
  end

  defp connect_info, do: %{peer_data: %{address: {100, 64, 0, 7}, port: 4000}, x_headers: []}

  # Connect, join the node's own topic and say hello; returns the joined socket.
  defp join_and_hello(node, credential, hello \\ hello()) do
    {:ok, socket} = connect_node(credential)
    {:ok, _, socket} = subscribe_and_join(socket, "node:" <> node.id, %{})
    ref = push(socket, "hello", hello)
    assert_push "hello_ok", ok
    _ = ref
    # The channel is linked to the test; a close with a non-normal reason must
    # not take the test down with it.
    Process.unlink(socket.channel_pid)
    {socket, ok}
  end

  describe "connect (NodeSocket)" do
    test "a valid credential connects, and the socket id is the node's", %{
      node: node,
      credential: credential
    } do
      assert {:ok, socket} = connect_node(credential)
      assert socket.assigns.node_id == node.id
      assert NodeSocket.id(socket) == "node_socket:" <> node.id
      assert NodeSocket.id(socket) == Nodes.socket_id(node.id)
    end

    test "the credential may also ride in the x-arbiter-node-credential header", %{
      node: node,
      credential: credential
    } do
      info = %{connect_info() | x_headers: [{"x-arbiter-node-credential", credential}]}
      assert {:ok, socket} = connect(NodeSocket, %{}, connect_info: info)
      assert socket.assigns.node_id == node.id
    end

    test "an invalid, malformed, absent or foreign-tier credential is refused", %{node: node} do
      {:ok, %{token: join_token}} = Nodes.mint_join_token([], "operator:test")
      secret = String.duplicate("a", 52)

      for bad <- [
            "arbn_#{node.id}.#{secret}",
            "arbn_garbage",
            "nonsense",
            "",
            join_token,
            Arbiter.MCP.Scope.mint_coordinator()
          ] do
        assert :error = connect(NodeSocket, %{"token" => bad}, connect_info: connect_info()),
               "expected #{inspect(bad)} to be refused"
      end

      assert :error = connect(NodeSocket, %{}, connect_info: connect_info())
    end

    test "a revoked node's credential is refused", %{node: node, credential: credential} do
      assert {:ok, _} = connect_node(credential)
      {:ok, _} = Nodes.revoke(node, "operator:test")
      assert :error = connect_node(credential)
    end

    test "repeated failures trip the socket-connect limiter, which then refuses even a good credential",
         %{credential: credential} do
      for _ <- 1..30,
          do:
            assert(:error = connect(NodeSocket, %{"token" => "x"}, connect_info: connect_info()))

      assert :error = connect_node(credential)
    end
  end

  describe "join" do
    test "a node can only join its own topic", %{credential: credential} do
      {other, _} = enroll!("other-node")
      {:ok, socket} = connect_node(credential)

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, "node:" <> other.id, %{})
    end
  end

  describe "hello" do
    test "hello_ok carries the boot_epoch and the per-run verdicts (no live Worker, so unknown: §10.4)",
         %{
           node: node,
           credential: credential
         } do
      live = run!(:working)
      gone = Ash.UUID.generate()

      {_socket, ok} =
        join_and_hello(
          node,
          credential,
          hello(%{"runs" => [%{"id" => live.id}, %{"id" => gone}]})
        )

      assert ok["boot_epoch"] == Nodes.boot_epoch()
      # a live row alone is not "known": only a run this session holds is (RW12)
      assert ok["runs"] == %{live.id => "unknown", gone => "unknown"}
      assert ok["fence_after"] == 60
      assert ok["lost_after"] == 90
      assert ok["hb_interval"] == 10
      assert ok["health"] == "ready"
      assert ok["max_workers"] == 2
    end

    test "records a connected event and registers a session", %{
      node: node,
      credential: credential
    } do
      {_socket, _ok} = join_and_hello(node, credential)
      assert :connected in Enum.map(Nodes.events(node_id: node.id), & &1.kind)
      assert %{connected?: true, state: :online} = Session.snapshot(node.id)
    end

    test "an outdated agent is told so, and takes no new work", %{
      node: node,
      credential: credential
    } do
      {_socket, ok} = join_and_hello(node, credential, hello(%{"agent_version" => "0.0.1"}))
      assert ok["health"] == "outdated"
      assert ok["max_workers"] == 0
      refute Registry.assignable?(node.id)
    end

    test "an outdated agent is told which release to move to", %{
      node: node,
      credential: credential,
      tmp_dir: home
    } do
      %{tag: tag, sha256: sha} = ArbiterWeb.NodeFixtures.install_release!(home)
      {_socket, ok} = join_and_hello(node, credential, hello(%{"agent_version" => "0.0.1"}))
      assert ok["upgrade"] == %{"version" => tag, "sha256" => sha}
    end

    test "an up-to-date agent is not sent an upgrade", %{
      node: node,
      credential: credential,
      tmp_dir: home
    } do
      ArbiterWeb.NodeFixtures.install_release!(home)
      {_socket, ok} = join_and_hello(node, credential)
      refute Map.has_key?(ok, "upgrade")
    end

    test "a heartbeat before hello is refused, not silently accepted", %{
      node: node,
      credential: credential
    } do
      {:ok, socket} = connect_node(credential)
      {:ok, _, socket} = subscribe_and_join(socket, "node:" <> node.id, %{})
      ref = push(socket, "hb", %{"seq" => 1})
      assert_reply ref, :error, %{reason: "hello_required"}
    end
  end

  describe "heartbeat" do
    test "is acked with its seq and the boot_epoch", %{node: node, credential: credential} do
      {socket, _} = join_and_hello(node, credential)

      push(socket, "hb", %{
        "seq" => 7,
        "runs" => %{"r1" => %{"state" => "running", "stdout_seq" => 3}}
      })

      assert_push "hb_ack", %{"seq" => 7, "boot_epoch" => epoch}
      assert epoch == Nodes.boot_epoch()
      assert %{runs: %{"r1" => %{"stdout_seq" => 3}}} = Session.snapshot(node.id)
    end
  end

  describe "cluster node events (K12, A3, A7)" do
    test "a capacity event reaches the session; hello carries kind and degraded", %{
      node: node,
      credential: credential
    } do
      {socket, ok} =
        join_and_hello(
          node,
          credential,
          hello(%{
            "kind" => "cluster",
            "degraded" => "netpol_unenforced",
            "capacity" => %{"ceiling" => 4}
          })
        )

      # a cluster is told the prepare budget; its hello_ok is otherwise a machine's
      assert %{"limits" => %{"prepare_timeout_s" => 1500}} = ok

      assert %{kind: "cluster", degraded: ["netpol_unenforced"], node_capacity: nil} =
               Session.snapshot(node.id)

      push(socket, "capacity", %{"ceiling" => 4, "pending" => 1, "constrained" => true})
      assert_receive {:node_capacity, _id, %{"constrained" => true}}
      assert %{node_capacity: %{"pending" => 1}} = Session.snapshot(node.id)
    end

    test "a machine hello_ok has no limits", %{node: node, credential: credential} do
      {_socket, ok} = join_and_hello(node, credential)
      refute Map.has_key?(ok, "limits")
    end
  end

  # bd-4p1vui (docs/design/remote-workers.md §10.4.3): the adoption handshake crosses the
  # channel both ways.
  describe "adoption" do
    test "adopt reaches the node, and the node's adopt.refused reaches the session", %{
      node: node,
      credential: credential
    } do
      row =
        Ash.create!(Arbiter.Workers.Run, %{
          task_id: "bd-node-chan",
          base_task_id: "bd-node-chan",
          repo: "trib/repo",
          kind: :implement,
          provider: "claude",
          state: :working,
          node_id: node.id,
          started_at: DateTime.utc_now()
        })

      {socket, ok} =
        join_and_hello(
          node,
          credential,
          hello(%{
            "caps" => %{"backend" => "podman", "run_hold" => "quiesce", "run_adopt" => "attach"},
            "runs" => [%{"id" => row.id, "state" => "running", "exited" => false, "acked" => 0}]
          })
        )

      assert ok["runs"] == %{row.id => "hold"}
      session = Registry.lookup(node.id)
      owner = self()

      task =
        Task.async(fn -> Session.adopt(session, row.id, %{"run" => row.id}, owner, []) end)

      run_id = row.id
      assert_push "adopt", %{"run" => ^run_id}
      push(socket, "adopt.refused", %{"run" => run_id, "reason" => "exited"})

      assert {:error, {:adopt_refused, "exited"}} = Task.await(task)
      assert :ok = Session.adoptable(session, run_id)
    end
  end

  describe "missed heartbeats" do
    test "suspect at 30 s, fenced at 60 s, lost at 90 s: the channel closes and the runs are named",
         %{node: node, credential: credential, clock: clock} do
      live = run!(:working)
      id = node.id
      {socket, _} = join_and_hello(node, credential, hello(%{"runs" => [%{"id" => live.id}]}))
      session = Registry.lookup(id)
      Process.unlink(socket.channel_pid)
      channel_ref = Process.monitor(socket.channel_pid)

      advance(clock, 30)
      Session.tick(session)
      assert_receive {:node_state, ^id, :suspect}
      refute_received {:DOWN, ^channel_ref, _, _, _}

      push(socket, "hb", %{"seq" => 1})
      assert_push "hb_ack", _
      assert %{state: :online} = Session.snapshot(id)

      advance(clock, 60)
      Session.tick(session)
      assert :fenced in Enum.map(Nodes.events(node_id: id), & &1.kind)

      advance(clock, 30)
      Session.tick(session)
      assert_receive {:node_lost, ^id, [run_id]}
      assert run_id == live.id
      assert_receive {:DOWN, ^channel_ref, :process, _, {:shutdown, :lost}}
      assert Registry.lookup(id) == nil
      assert :node_lost in Enum.map(Nodes.events(node_id: id), & &1.kind)
    end

    test "the lost node can reconnect and gets a fresh verdict on what it still runs", %{
      node: node,
      credential: credential,
      clock: clock
    } do
      live = run!(:working)
      {_socket, _} = join_and_hello(node, credential, hello(%{"runs" => [%{"id" => live.id}]}))
      session = Registry.lookup(node.id)
      advance(clock, 90)
      Session.tick(session)
      assert Registry.lookup(node.id) == nil

      # The primary interrupted the run while the node was away.
      Ash.update!(live, %{state: :finished, outcome: :interrupted}, action: :update)

      {_socket, ok} = join_and_hello(node, credential, hello(%{"runs" => [%{"id" => live.id}]}))
      assert ok["runs"] == %{live.id => "unknown"}
    end
  end

  describe "drain" do
    test "pushes drain to the node, withholds new work, and leaves live runs alone", %{
      node: node,
      credential: credential
    } do
      live = run!(:working)
      {socket, _} = join_and_hello(node, credential, hello(%{"runs" => [%{"id" => live.id}]}))
      assert Registry.assignable?(node.id)

      {:ok, _} = Nodes.drain(node, "operator:test")
      assert_push "drain", %{"on" => true}
      refute_push "cancel", _
      refute Registry.assignable?(node.id)

      # Heartbeats go on, the run table is untouched, the channel stays open.
      push(socket, "hb", %{"seq" => 2, "runs" => %{live.id => %{"state" => "running"}}})
      assert_push "hb_ack", %{"seq" => 2}
      assert %{draining?: true, runs: %{} = runs} = Session.snapshot(node.id)
      assert Map.has_key?(runs, live.id)
      assert Ash.get!(Arbiter.Workers.Run, live.id).state == :working
      assert Process.alive?(socket.channel_pid)

      {:ok, _} = Nodes.undrain(node, "operator:test")
      assert_push "drain", %{"on" => false}
      assert Registry.assignable?(node.id)
    end

    test "a node that reconnects is told it is still draining", %{
      node: node,
      credential: credential
    } do
      {:ok, _} = Nodes.drain(node, "operator:test")
      {_socket, ok} = join_and_hello(node, credential)
      assert ok["draining"] == true
      assert ok["max_workers"] == 0
    end
  end

  describe "revoke" do
    test "broadcasts disconnect on the socket id and closes the channel", %{
      node: node,
      credential: credential
    } do
      {socket, _} = join_and_hello(node, credential)
      Process.unlink(socket.channel_pid)
      channel_ref = Process.monitor(socket.channel_pid)
      ArbiterWeb.Endpoint.subscribe(NodeSocket.id(socket))

      {:ok, _} = Nodes.revoke(node, "operator:test")

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      assert_receive {:DOWN, ^channel_ref, :process, _, {:shutdown, :revoked}}
      assert Registry.lookup(node.id) == nil
      assert :error = connect_node(credential)
    end

    test "falls back to closing on the next heartbeat when the broadcast never came", %{
      node: node,
      credential: credential
    } do
      {socket, _} = join_and_hello(node, credential)
      Process.unlink(socket.channel_pid)
      channel_ref = Process.monitor(socket.channel_pid)

      # Revoked behind the session's back: no notification, no broadcast.
      {:ok, _} = Ash.update(node, %{}, action: :revoke)
      push(socket, "hb", %{"seq" => 9})

      assert_receive {:DOWN, ^channel_ref, :process, _, {:shutdown, :revoked}}
      assert Registry.lookup(node.id) == nil
    end

    test "a revoked node cannot say hello on a channel it joined earlier", %{
      node: node,
      credential: credential
    } do
      {:ok, socket} = connect_node(credential)
      {:ok, _, socket} = subscribe_and_join(socket, "node:" <> node.id, %{})
      {:ok, _} = Nodes.revoke(node, "operator:test")
      Process.unlink(socket.channel_pid)
      channel_ref = Process.monitor(socket.channel_pid)
      push(socket, "hello", hello())
      assert_receive {:DOWN, ^channel_ref, :process, _, {:shutdown, :revoked}}
    end
  end

  describe "over a real WebSocket" do
    setup do
      ArbiterWeb.NodeTestEndpoint.configure()
      start_supervised!(ArbiterWeb.NodeTestEndpoint)
      %{port: ArbiterWeb.NodeTestEndpoint.port()}
    end

    defp url(port, token),
      do: "ws://127.0.0.1:#{port}/node/socket/websocket?vsn=2.0.0&token=#{token}"

    test "a valid credential joins, says hello and gets hello_ok; revoking closes the socket promptly",
         %{port: port, node: node, credential: credential} do
      {:ok, client} = WsClient.start_link(url: url(port, credential), owner: self())
      topic = "node:" <> node.id
      assert {:ok, %{}} = WsClient.join(client, topic)

      WsClient.push(client, topic, "hello", hello())
      assert_receive {:ws, :push, ^topic, "hello_ok", %{"boot_epoch" => _}}, 5_000

      WsClient.push(client, topic, "hb", %{"seq" => 1})
      assert_receive {:ws, :push, ^topic, "hb_ack", %{"seq" => 1}}, 5_000

      {:ok, _} = Nodes.revoke(node, "operator:test")
      assert_receive {:ws, :closed, _reason}, 5_000
      assert Registry.lookup(node.id) == nil
    end

    test "an invalid credential is refused at the upgrade", %{port: port} do
      Process.flag(:trap_exit, true)
      {:ok, client} = WsClient.start_link(url: url(port, "arbn_nope"), owner: self())
      ref = Process.monitor(client)
      assert_receive {:ws, :closed, {:upgrade_rejected, 403, _}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^client, _}, 5_000
    end

    test "a revoked credential is refused at the upgrade", %{
      port: port,
      node: node,
      credential: credential
    } do
      Process.flag(:trap_exit, true)
      {:ok, _} = Nodes.revoke(node, "operator:test")
      {:ok, client} = WsClient.start_link(url: url(port, credential), owner: self())
      ref = Process.monitor(client)
      assert_receive {:ws, :closed, {:upgrade_rejected, 403, _}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^client, _}, 5_000
    end
  end

  defp run!(state) do
    Ash.create!(Arbiter.Workers.Run, %{
      task_id: "bd-node-chan",
      base_task_id: "bd-node-chan",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: state,
      started_at: DateTime.utc_now()
    })
  end
end
