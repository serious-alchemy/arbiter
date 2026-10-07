defmodule Arbiter.Nodes.Bridge do
  @moduledoc """
  The primary's end of the bridge multiplexer (`docs/design/remote-workers.md`
  §8): the node's per-run egress, MCP and `arb` sockets, tunnelled over the node
  channel as credit-controlled streams. One process per channel connection;
  streams die with the channel and are not resumed (the in-container client
  reconnects).

  For each `bridge.open{run, name, stream}` the node sends, this process asks the
  node's `Arbiter.Nodes.Session` whether the run is placed on this node, live, and
  declared that bridge, and then **dials the primary's own existing unix
  listener** for it (`Arbiter.Worker.Egress.socket_path/2` /
  `bridge_path/3`, recorded in the run's spec). From there nothing is new: the
  proxy decides, `Arbiter.Worker.Egress.Audit` records `egress_events`, and
  `Arbiter.Worker.Egress.Forward` registers the connection with
  `Arbiter.Worker.Egress.BridgeIdentity`. **The egress code, policy, audit and
  identity are untouched**; a stream looks to them like a local client.

  The protocol and its limits are `Arbiter.Nodes.Bridge.Core`, driven through
  `Arbiter.Nodes.Bridge.Relay` (shared with the agent's end); each stream's
  socket is a `Arbiter.Nodes.Bridge.Stream` process, so a listener that stops
  reading stalls that stream's window and nothing else. This process only moves
  messages: it never blocks on a socket, and it is not the channel process, so a
  heartbeat never queues behind bridge work. It pushes to the node through the
  channel (`{:node_bridge, {:push, event, payload}}`).

  A `bridge.open` that is refused is answered with `bridge.reset{stream, reason}`;
  a peer that breaks the protocol (a frame that is not a frame) ends this process
  with `{:shutdown, {:violation, reason}}`, which the channel turns into a close.
  """

  use GenServer, restart: :temporary

  alias Arbiter.Nodes.Bridge.{Limits, Relay, Stream}
  alias Arbiter.Nodes.Session

  require Logger

  @doc """
  Start the bridge for `channel`. Options: `:node_id`, `:session` (pid, for
  authorization), `:limits` (default `Limits.current/0`), `:authorize`
  (`fun(run, name) -> {:ok, path} | {:error, reason}`, a test seam).
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "An event from the node, as the channel received it."
  @spec from_node(pid(), String.t(), term()) :: :ok
  def from_node(bridge, event, payload), do: GenServer.cast(bridge, {:node, event, payload})

  @doc "The run is over: its streams end."
  @spec run_over(pid(), String.t()) :: :ok
  def run_over(bridge, run), do: GenServer.cast(bridge, {:run_over, run})

  @doc "How many streams are open (diagnostics, tests)."
  @spec info(pid()) :: map()
  def info(bridge), do: GenServer.call(bridge, :info)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    channel = Keyword.fetch!(opts, :channel)
    session = Keyword.get(opts, :session)

    authorize =
      Keyword.get_lazy(opts, :authorize, fn ->
        fn run, name -> Session.bridge_target(session, run, name) end
      end)

    limits = Keyword.get_lazy(opts, :limits, &Limits.current/0)
    push = fn event, payload -> send(channel, {:node_bridge, {:push, event, payload}}) end

    {:ok,
     %{
       channel_ref: Process.monitor(channel),
       node_id: Keyword.get(opts, :node_id),
       authorize: authorize,
       relay: Relay.new(limits, push, {:node, Keyword.get(opts, :node_id)})
     }}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, Relay.info(state.relay), state}

  @impl true
  def handle_cast({:node, "bridge.open", payload}, state), do: open(state, payload)

  def handle_cast({:node, event, payload}, state),
    do: reply(state, Relay.remote(state.relay, event, payload))

  def handle_cast({:run_over, run}, state),
    do: reply(state, Relay.reset_run(state.relay, run, :run_over))

  @impl true
  def handle_info({:bridge_stream, id, event}, state),
    do: reply(state, Relay.stream_event(state.relay, id, event))

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, reason}, state) do
    case Relay.stream_down(state.relay, pid, reason) do
      :error -> {:noreply, state}
      result -> reply(state, result)
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Relay.stop_all(state.relay)

  defp reply(state, {:cont, relay}), do: {:noreply, %{state | relay: relay}}
  defp reply(state, {:stop, reason, relay}), do: {:stop, reason, %{state | relay: relay}}

  # ---- opening --------------------------------------------------------------

  defp open(state, %{"run" => run, "name" => name, "stream" => id}) do
    with {:ok, path} <- authorize(state, run, name),
         {:ok, relay} <- Relay.open_remote(state.relay, id, run, name) do
      case Stream.start_link(owner: self(), id: id, dial: path) do
        {:ok, pid} ->
          {:noreply, %{state | relay: Relay.attach_stream(relay, id, pid)}}

        {:error, reason} ->
          Logger.warning("bridge: stream #{id} did not start: #{inspect(reason)}")
          reply(state, Relay.reset(relay, id, :stream_start_failed))
      end
    else
      {:error, reason} -> refuse(state, id, reason)
    end
  end

  defp open(state, _payload), do: {:noreply, state}

  defp authorize(%{authorize: fun}, run, name) when is_binary(run) and is_binary(name) do
    fun.(run, name)
  catch
    :exit, _ -> {:error, :no_session}
  end

  defp authorize(_state, _run, _name), do: {:error, :bad_target}

  # Not a stream we hold: say so, so the node closes its end. A bad id has no
  # stream to name.
  defp refuse(state, id, reason) when is_integer(id) do
    state.relay.push.("bridge.reset", %{"stream" => id, "reason" => Atom.to_string(reason)})
    {:noreply, state}
  end

  defp refuse(state, _id, _reason), do: {:noreply, state}
end
