defmodule Arbiter.NodeAgent.PodChannelTest do
  @moduledoc """
  The pod channel as the controller starts it (`docs/design/remote-workers.md` §16
  K§9.2, K§9.3): the CA from a store, the run table, the two listeners, and the
  server certificate's rotation.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Arbiter.NodeAgent.{Bridge, Config, PodChannel}
  alias Arbiter.NodeAgent.PodChannel.{CA, CAStore, Runs}
  alias Arbiter.NodeAgent.PodChannelKit, as: Kit

  @loopback {127, 0, 0, 1}

  defmodule FakeClient do
    @moduledoc false
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    @impl true
    def init(test), do: {:ok, test}
    @impl true
    def handle_call({:push, _t, event, payload}, _from, test) do
      send(test, {:pushed, event, payload})
      {:reply, "ref", test}
    end
  end

  setup %{tmp_dir: tmp} do
    bridge = start_supervised!({Bridge, node_home: tmp, name: nil})
    {:ok, client} = FakeClient.start_link(self())
    :ok = Bridge.attach(bridge, client, "node:n1")

    start = fn extra ->
      start_supervised!(
        {PodChannel,
         extra ++
           [
             name: nil,
             ca_store: {CAStore.Dir, Path.join(tmp, "ca")},
             config: %Config{primary_url: "http://127.0.0.1:1", credential: "x"},
             bridge: bridge,
             ip: @loopback,
             bridge_port: 0,
             boot_port: 0,
             server_names: ["arbiter-controller", "localhost"],
             server_ips: [@loopback]
           ]}
      )
    end

    %{start: start, tmp: tmp, bridge: bridge}
  end

  defp ca_of do
    {:ok, ca} = CA.load_or_create(PodChannel.ca_store())
    ca
  end

  test "first boot creates the CA in the store; the channel serves bridges to a booted pod",
       ctx do
    _channel = ctx.start.([])
    ca = ca_of()
    assert File.exists?(Path.join([ctx.tmp, "ca", "ca.key"]))

    {:ok, nonce} = PodChannel.register(Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))
    :ok = PodChannel.bind_pod_ip("run-1", @loopback)

    boot =
      Req.post!(
        url: "https://localhost:#{PodChannel.ports().boot}/boot",
        body: nonce,
        decode_body: false,
        retry: false,
        connect_options: [transport_opts: Kit.client_opts_no_cert(ca)]
      )

    assert boot.status == 200
    files = Kit.unpack(boot.body)

    opts = [:binary, active: false] ++ Kit.client_opts(files, "proxy", ca)
    assert {:ok, _sock} = :ssl.connect(@loopback, PodChannel.ports().bridge, opts, 5_000)
    assert_receive {:pushed, "bridge.open", %{"run" => "run-1", "name" => "proxy"}}, 5_000
  end

  test "a restarted controller reads the same CA, so existing pods' trust anchor still holds",
       ctx do
    _first = ctx.start.([])
    der = ca_of().der
    :ok = stop_supervised(PodChannel)

    _second = ctx.start.([])
    assert ca_of().der == der
  end

  test "rotating the server certificate keeps the CA and serves a new certificate", ctx do
    _channel = ctx.start.([])
    ca = ca_of()
    before = server_cert(ca)

    :ok = PodChannel.rotate()
    after_rotation = server_cert(ca)

    assert before != after_rotation
    assert {:ok, _} = :public_key.pkix_path_validation(ca.der, [after_rotation], [])
  end

  test "a run released from the channel can no longer bridge", ctx do
    _channel = ctx.start.([])
    ca = ca_of()
    {:ok, nonce} = PodChannel.register(Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))
    :ok = PodChannel.bind_pod_ip("run-1", @loopback)
    {:ok, "run-1", tar} = Runs.redeem(nonce, @loopback)
    files = Kit.unpack(tar)

    :ok = PodChannel.release("run-1")

    opts = [:binary, active: false] ++ Kit.client_opts(files, "proxy", ca)
    {:ok, sock} = :ssl.connect(@loopback, PodChannel.ports().bridge, opts, 5_000)
    assert {:error, _} = :ssl.recv(sock, 0, 5_000)
    refute_received {:pushed, "bridge.open", _}
  end

  test "the channel only hands the CA to its store, never a leaf or a secret", ctx do
    test = self()

    defmodule SpyStore do
      @moduledoc false
      @behaviour Arbiter.NodeAgent.PodChannel.CAStore
      def load({test, _}),
        do:
          (
            send(test, :load)
            :none
          )

      def save({test, _}, material),
        do:
          (
            send(test, {:save, material})
            :ok
          )

      def publish({test, _}, pem),
        do:
          (
            send(test, {:publish, pem})
            :ok
          )
    end

    _channel = ctx.start.(ca_store: {SpyStore, {test, nil}})
    {:ok, _} = PodChannel.register(Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))

    assert_received {:save, %{cert: cert, key: key}}
    assert_received {:publish, ^cert}
    refute_received {:save, _}
    refute_received {:publish, _}
    refute cert =~ "PRIVATE"
    assert key =~ "PRIVATE"
    refute_received {:save, %{cert: _, key: "s3cret"}}
  end

  defp server_cert(ca) do
    opts = [
      :binary,
      active: false,
      cacerts: [ca.der],
      verify: :verify_peer,
      server_name_indication: ~c"localhost"
    ]

    {:ok, sock} = :ssl.connect(@loopback, PodChannel.ports().boot, opts, 5_000)
    {:ok, der} = :ssl.peercert(sock)
    :ssl.close(sock)
    der
  end
end
