defmodule Arbiter.NodeAgent.PodChannel.Listeners do
  @moduledoc """
  Owns the two pod-channel listeners and the controller's server certificate
  (`Arbiter.NodeAgent.PodChannel`): mints the certificate (SANs the Service name
  and ClusterIP), starts `Arbiter.NodeAgent.PodChannel.BridgeListener` and
  `Arbiter.NodeAgent.PodChannel.PodServer` on it under their own supervisor, and
  replaces both on a new certificate every `:rotate_after_ms`.
  """

  use GenServer

  alias Arbiter.NodeAgent.PodChannel.{BridgeListener, Cert, PodServer, Runs}

  @ttl_s 30 * 86_400
  @skew_s 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec ports() :: %{bridge: :inet.port_number(), boot: :inet.port_number()}
  def ports, do: GenServer.call(__MODULE__, :ports)

  @spec ca_store() :: Arbiter.NodeAgent.PodChannel.CAStore.t()
  def ca_store, do: GenServer.call(__MODULE__, :ca_store)

  @spec rotate() :: :ok
  def rotate, do: GenServer.call(__MODULE__, :rotate)

  @impl true
  def init(opts) do
    ttl_s = Keyword.get(opts, :server_ttl_s, @ttl_s)

    state = %{
      opts: opts,
      ttl_s: ttl_s,
      rotate_after_ms: Keyword.get(opts, :rotate_after_ms, div(ttl_s * 1000, 4)),
      sup: nil,
      timer: nil
    }

    {:ok, start_listeners(state)}
  end

  @impl true
  def handle_call(:ports, _from, state), do: {:reply, ports_of(state.sup), state}

  def handle_call(:ca_store, _from, state),
    do: {:reply, Keyword.fetch!(state.opts, :ca_store), state}

  def handle_call(:rotate, _from, state),
    do: {:reply, :ok, state |> stop_listeners() |> start_listeners()}

  @impl true
  def handle_info(:rotate, state), do: {:noreply, state |> stop_listeners() |> start_listeners()}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_listeners(state) && :ok

  defp start_listeners(%{opts: opts} = state) do
    ca = Keyword.fetch!(opts, :ca)
    now = DateTime.utc_now()

    identity =
      Cert.server(
        ca,
        Keyword.get(opts, :server_names, ["arbiter-controller"]),
        Keyword.get(opts, :server_ips, []),
        DateTime.add(now, -@skew_s),
        DateTime.add(now, state.ttl_s)
      )

    shared = [identity: identity, ca: ca, runs: Runs, ip: Keyword.get(opts, :ip, {0, 0, 0, 0})]

    bridge =
      shared ++
        [port: Keyword.get(opts, :bridge_port, 9443)] ++
        Keyword.take(opts, [:bridge, :notify]) ++ [id: :bridge_listener]

    boot =
      shared ++
        [port: Keyword.get(opts, :boot_port, 9444), config: Keyword.fetch!(opts, :config)] ++
        Keyword.take(opts, [:notify, :max_upload_bytes])

    {:ok, sup} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({BridgeListener, bridge}, id: :bridge_listener),
          {PodServer, boot}
        ],
        strategy: :one_for_all
      )

    timer = Process.send_after(self(), :rotate, min(state.rotate_after_ms, 2_000_000_000))
    %{state | sup: sup, timer: timer}
  end

  defp stop_listeners(%{sup: nil} = state), do: state

  defp stop_listeners(%{sup: sup, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    Supervisor.stop(sup)
    %{state | sup: nil, timer: nil}
  end

  defp ports_of(sup) do
    children = Supervisor.which_children(sup)
    {_, bridge, _, _} = List.keyfind(children, :bridge_listener, 0)
    {_, boot, _, _} = List.keyfind(children, PodServer, 0)
    %{bridge: BridgeListener.port(bridge), boot: PodServer.port(boot)}
  end
end
