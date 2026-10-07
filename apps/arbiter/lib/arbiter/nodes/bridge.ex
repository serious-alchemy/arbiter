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

  The protocol and its limits are `Arbiter.Nodes.Bridge.Core`; each stream's
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

  alias Arbiter.Nodes.Bridge.{Core, Limits, Stream}
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

    {:ok,
     %{
       channel: channel,
       channel_ref: Process.monitor(channel),
       node_id: Keyword.get(opts, :node_id),
       authorize: authorize,
       core: Core.new(Keyword.get_lazy(opts, :limits, &Limits.current/0)),
       pids: %{}
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, %{streams: Core.stream_ids(state.core), inflight: Core.inflight(state.core)}, state}
  end

  @impl true
  def handle_cast({:node, "bridge.open", payload}, state), do: open(state, payload)

  def handle_cast({:node, event, payload}, state) do
    {core, effects} = Core.remote(state.core, event, payload)
    perform(%{state | core: core}, effects)
  end

  def handle_cast({:run_over, run}, state) do
    Enum.reduce(Core.run_streams(state.core, run), {:noreply, state}, fn id, {:noreply, st} ->
      {core, effects} = Core.reset(st.core, id, :run_over)
      perform(%{st | core: core}, effects)
    end)
  end

  @impl true
  def handle_info({:bridge_stream, id, event}, state), do: stream_event(state, id, event)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_ref: ref} = state),
    do: {:stop, :normal, state}

  # A stream process ended. Its last words came first; one still in the table died
  # without saying so.
  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.pids, fn {_id, p} -> p == pid end) do
      {id, _} ->
        state = %{state | pids: Map.delete(state.pids, id)}
        {core, effects} = Core.reset(state.core, id, exit_reason(reason))
        perform(%{state | core: core}, effects)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pids, fn {_id, pid} -> Stream.stop(pid) end)
    :ok
  end

  # ---- opening --------------------------------------------------------------

  defp open(state, %{"run" => run, "name" => name, "stream" => id}) do
    with {:ok, path} <- authorize(state, run, name),
         {:ok, core, effects} <- Core.open_remote(state.core, id, run, name) do
      case Stream.start_link(owner: self(), id: id, dial: path) do
        {:ok, pid} ->
          perform(%{state | core: core, pids: Map.put(state.pids, id, pid)}, effects)

        {:error, reason} ->
          {core, effects} = Core.reset(core, id, :stream_start_failed)
          Logger.warning("bridge: stream #{id} did not start: #{inspect(reason)}")
          perform(%{state | core: core}, effects)
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
    push(state, "bridge.reset", %{"stream" => id, "reason" => Atom.to_string(reason)})
    {:noreply, state}
  end

  defp refuse(state, _id, _reason), do: {:noreply, state}

  # ---- stream process events -----------------------------------------------

  defp stream_event(state, id, {:data, bytes}) do
    {core, effects} = Core.local_data(state.core, id, bytes)
    perform(%{state | core: core}, effects)
  end

  defp stream_event(state, id, :eof) do
    {core, effects} = Core.local_eof(state.core, id)
    perform(%{state | core: core}, effects)
  end

  defp stream_event(state, id, {:wrote, n}) do
    {core, effects} = Core.local_wrote(state.core, id, n)
    perform(%{state | core: core}, effects)
  end

  defp stream_event(state, id, {:failed, reason}) do
    Logger.debug("bridge: stream #{id} failed: #{inspect(reason)}")
    {core, effects} = Core.reset(state.core, id, :stream_failed)
    perform(%{state | core: core}, effects)
  end

  # ---- effects --------------------------------------------------------------

  defp perform(state, effects) do
    Enum.reduce_while(effects, {:noreply, state}, fn effect, {:noreply, state} ->
      case effect(state, effect) do
        {:ok, state} -> {:cont, {:noreply, state}}
        {:stop, reason, state} -> {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp effect(state, {:push, event, payload}) do
    push(state, event, payload)
    {:ok, state}
  end

  defp effect(state, {:stream, id, :write, bytes}) do
    with_stream(state, id, &Stream.write(&1, bytes))
    {:ok, state}
  end

  defp effect(state, {:stream, id, :rearm}) do
    with_stream(state, id, &Stream.rearm/1)
    {:ok, state}
  end

  defp effect(state, {:stream, id, :shutdown_write}) do
    with_stream(state, id, &Stream.shutdown_write/1)
    {:ok, state}
  end

  defp effect(state, {:stream, id, :stop}) do
    with_stream(state, id, &Stream.stop/1)
    {:ok, %{state | pids: Map.delete(state.pids, id)}}
  end

  defp effect(state, {:violation, reason}) do
    Logger.warning("bridge: node #{state.node_id} broke the protocol: #{inspect(reason)}")
    {:stop, {:shutdown, {:violation, reason}}, state}
  end

  defp with_stream(state, id, fun) do
    case state.pids do
      %{^id => pid} -> fun.(pid)
      _ -> :ok
    end
  end

  defp push(state, event, payload), do: send(state.channel, {:node_bridge, {:push, event, payload}})

  defp exit_reason(:normal), do: :stream_closed
  defp exit_reason(_), do: :stream_crashed
end
