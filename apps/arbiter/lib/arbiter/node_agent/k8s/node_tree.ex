defmodule Arbiter.NodeAgent.K8s.NodeTree do
  @moduledoc """
  A cluster controller once it knows who it is (ticket K14): what
  `Arbiter.NodeAgent.K8s.Boot` starts under the node supervisor when the credential, the
  primary's facts and the controller's identity are in hand. `:rest_for_one`, in this
  order:

      PodChannel             the CA (Secret `arbiter-controller-ca`), leaves, :9443/:9444
      ConfigLoader           /etc/arb/config/controller.yaml, re-read every 30 s
      Informer               the pods labelled with this install and node
      Lease                  `arbiter-controller`: one active controller (K§3.5)
      ControllerSupervisor   ReadinessMonitor (the canary), then Controller (the run table)
      Upgrader               the image self-upgrade (K§2.4)
      Connection             the WebSocket to the primary, last: it reports the others

  Everything runs under its production name, which is how `Arbiter.NodeAgent.Backend.K8s`
  and the controller find each other: a restarted process is found again by name, and
  `:rest_for_one` restarts whatever subscribed to it. The pod channel is first because its
  run table is in memory (K5's known limit): only its own crash restarts it, and then the
  controller after it re-adopts the pods. The controller's pushes go to the connection by
  name (`sink`), since the connection starts after it.

  Options: `:config` (the agent's `Arbiter.NodeAgent.Config`, with the credential),
  `:client`, `:identity` (`Arbiter.NodeAgent.K8s.Identity.resolve/4`), `:canary_image`
  (a `fn -> {:ok, image} | {:error, reason}`), `:tree` (per-child extra options for tests:
  `:pod_channel`, `:config_loader`, `:informer`, `:lease`, `:controller_supervisor`).
  """

  use Supervisor

  alias Arbiter.NodeAgent.Connection
  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.ControllerSupervisor
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.NodeAgent.K8s.Lease
  alias Arbiter.NodeAgent.K8s.Upgrader
  alias Arbiter.NodeAgent.PodChannel
  alias Arbiter.NodeAgent.PodChannel.CAStore

  @loader Arbiter.NodeAgent.K8s.ConfigLoader
  @informer Arbiter.NodeAgent.K8s.Informer
  @lease Arbiter.NodeAgent.K8s.Lease
  @upgrader Arbiter.NodeAgent.K8s.Upgrader
  @service "arbiter-controller"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    client = Keyword.fetch!(opts, :client)
    identity = Keyword.fetch!(opts, :identity)
    tree = Keyword.get(opts, :tree, [])

    Supervisor.init(
      [
        {PodChannel, pod_channel(config, client, identity, tree)},
        {ConfigLoader, Keyword.merge([name: @loader], tree[:config_loader] || [])},
        {Informer,
         Keyword.merge(
           [client: client, label_selector: selector(identity), name: @informer],
           tree[:informer] || []
         )},
        {Lease,
         Keyword.merge(
           [client: client, identity: identity.own_pod || "arbiter-controller", name: @lease],
           tree[:lease] || []
         )},
        {ControllerSupervisor,
         Keyword.merge(
           [
             client: client,
             informer: @informer,
             config_loader: @loader,
             identity: identity,
             image: Keyword.fetch!(opts, :canary_image),
             name: ControllerSupervisor,
             controller: [lease: @lease, sink: Connection]
           ],
           tree[:controller_supervisor] || []
         )},
        {Upgrader, client: client, version: config.version, name: @upgrader},
        {Connection, config: config, upgrader: @upgrader}
      ],
      strategy: :rest_for_one
    )
  end

  # The label selector of K§3.3: this install's pods on this node, nothing else.
  defp selector(identity) do
    Client.label_selector(%{
      "arbiter.dev/install" => identity.install_id,
      "arbiter.dev/node" => identity.node_id
    })
  end

  # The server certificate names the Service the pods dial (its DNS names and clusterIP).
  defp pod_channel(config, client, identity, tree) do
    ns = client.namespace

    Keyword.merge(
      [
        ca_store: {CAStore.Secret, client},
        config: config,
        server_names: [@service, "#{@service}.#{ns}", "#{@service}.#{ns}.svc"],
        server_ips: server_ips(identity.bridge_addr)
      ],
      tree[:pod_channel] || []
    )
  end

  defp server_ips(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} -> [ip]
      {:error, _} -> []
    end
  end
end
