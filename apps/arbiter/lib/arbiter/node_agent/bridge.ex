defmodule Arbiter.NodeAgent.Bridge do
  @moduledoc """
  The agent's end of the bridge multiplexer (`docs/design/remote-workers.md` §8):
  for each run it creates the **same-named** per-run unix listeners the primary
  would have (`<name>.sock` under the run's own `0700` directory), which `Run`
  bind-mounts at the primary's socket paths in the container, so the in-container
  `socat`/`arb`/MCP client is unchanged. Every connection a listener accepts
  becomes a stream: `bridge.open{run, name, stream}` to the primary, whose
  `Arbiter.Nodes.Bridge` dials its own `Egress` listener for it.

  The protocol is `Arbiter.Nodes.Bridge.Core`, driven through
  `Arbiter.Nodes.Bridge.Relay` (the primary's end is the same code); each stream's
  socket is an `Arbiter.Nodes.Bridge.Stream` process, so a container that stops
  reading stalls its own stream's window and nothing else. This process is not
  `Arbiter.NodeAgent.Connection`, so a heartbeat never queues behind bridge work.

  * **Channel down.** Streams are not resumed: when `detach/1` is called every
    stream's socket is closed (the in-container client reconnects). A connection
    accepted while the channel is down is **held**, up to `:hold_max` of them and
    for `:hold_ms` each, and opened on `attach/3`; one that outlives the hold, or
    its run, is closed.
  * **Run over.** `release/2` closes the run's listeners, resets its streams and
    drops what it held.
  """

  use GenServer

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.WsClient
  alias Arbiter.Nodes.Bridge.{Limits, Relay, Stream}

  require Logger

  @hold_ms 60_000
  @hold_max 32
  # sun_path is 108 bytes on Linux, 104 on macOS/BSD; stay under both.
  @max_socket_path 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Listen for `bridges` (`[%{name:, path:}]` from the run spec) of `run`: returns
  the host path of each listener, in order, for `Run` to mount.
  """
  @spec listen(GenServer.server(), String.t(), [map()]) :: {:ok, [Path.t()]} | {:error, term()}
  def listen(server \\ __MODULE__, run, bridges),
    do: safe(server, {:listen, run, bridges}, {:error, :bridge_down})

  @doc "The run is over: close its listeners and streams."
  @spec release(GenServer.server(), String.t()) :: :ok
  def release(server \\ __MODULE__, run), do: safe(server, {:release, run}, :ok)

  @doc "The channel is up: `client` is its `WsClient`, `topic` the node's topic."
  @spec attach(GenServer.server(), pid(), String.t()) :: :ok
  def attach(server \\ __MODULE__, client, topic), do: safe(server, {:attach, client, topic}, :ok)

  @doc "The channel is gone."
  @spec detach(GenServer.server()) :: :ok
  def detach(server \\ __MODULE__), do: safe(server, :detach, :ok)

  @doc "A `bridge.*` event from the primary."
  @spec from_primary(GenServer.server(), String.t(), term()) :: :ok
  def from_primary(server \\ __MODULE__, event, payload),
    do: GenServer.cast(server, {:primary, event, payload})

  @doc "Streams and in-flight bytes (diagnostics, tests)."
  @spec info(GenServer.server()) :: map()
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  # The connection and the runs outlive a bridge that is not running (a test, a
  # restart): they carry on without it.
  defp safe(server, request, fallback) do
    GenServer.call(server, request)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    limits = Keyword.get_lazy(opts, :limits, &Limits.current/0)

    {:ok,
     %{
       node_home: opts |> Keyword.get_lazy(:node_home, fn -> Config.node_home() end),
       limits: limits,
       hold_ms: Keyword.get(opts, :hold_ms, @hold_ms),
       hold_max: Keyword.get(opts, :hold_max, @hold_max),
       channel: nil,
       relay: Relay.new(limits, fn _event, _payload -> :ok end, :agent),
       listeners: %{},
       held: [],
       next_id: 1
     }}
  end

  @impl true
  def handle_call({:listen, run, bridges}, _from, state) do
    case listen_all(state, run, bridges) do
      {:ok, state, paths} -> {:reply, {:ok, paths}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, run}, _from, state), do: {:reply, :ok, release_run(state, run)}

  def handle_call({:attach, client, topic}, _from, state) do
    channel = %{client: client, ref: Process.monitor(client)}
    push = fn event, payload -> WsClient.push(client, topic, event, payload) end
    state = %{state | channel: channel, relay: Relay.put_push(state.relay, push)}
    {:reply, :ok, open_held(state)}
  end

  def handle_call(:detach, _from, state), do: {:reply, :ok, detach_channel(state)}

  def handle_call(:info, _from, state),
    do: {:reply, Map.put(Relay.info(state.relay), :held, length(state.held)), state}

  @impl true
  def handle_cast({:primary, event, payload}, %{channel: %{}} = state),
    do: relay(state, Relay.remote(state.relay, event, payload))

  def handle_cast({:primary, _event, _payload}, state), do: {:noreply, state}

  @impl true
  def handle_info({:accepted, run, name, sock}, state),
    do: {:noreply, accepted(state, run, name, sock)}

  def handle_info({:bridge_stream, id, event}, state),
    do: relay(state, Relay.stream_event(state.relay, id, event))

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel: %{ref: ref}} = state),
    do: {:noreply, detach_channel(state)}

  def handle_info({:expire_held, sock}, state) do
    {expired, held} = Enum.split_with(state.held, &(&1.sock == sock))
    Enum.each(expired, &:gen_tcp.close(&1.sock))
    {:noreply, %{state | held: held}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Relay.stream_down(state.relay, pid, reason) do
      :error -> {:noreply, state}
      result -> relay(state, result)
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Relay.stop_all(state.relay)
    Enum.each(state.listeners, fn {_run, ls} -> Enum.each(ls, &close_listener/1) end)
    Enum.each(state.held, &:gen_tcp.close(&1.sock))
  end

  # A protocol violation by the primary drops the channel: the streams go, the
  # connection is closed so the agent reconnects with a clean slate.
  defp relay(state, {:cont, relay}), do: {:noreply, %{state | relay: relay}}

  defp relay(state, {:stop, reason, relay}) do
    Logger.warning("node agent bridge: primary broke the protocol: #{inspect(reason)}")
    state = %{state | relay: relay}
    if state.channel, do: WsClient.close(state.channel.client)
    {:noreply, detach_channel(state)}
  end

  # ---- listeners ------------------------------------------------------------

  defp listen_all(state, run, bridges) do
    dir = Path.join([state.node_home, "runs", run, "bridge"])

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      Enum.reduce_while(bridges, {:ok, [], []}, fn %{name: name}, {:ok, made, paths} ->
        case listen_one(run, name, Path.join(dir, name <> ".sock")) do
          {:ok, listener} -> {:cont, {:ok, [listener | made], paths ++ [listener.path]}}
          {:error, reason} -> {:halt, {:error, made, reason}}
        end
      end)
      |> case do
        {:ok, made, paths} ->
          {:ok, %{state | listeners: Map.update(state.listeners, run, made, &(made ++ &1))},
           paths}

        {:error, made, reason} ->
          Enum.each(made, &close_listener/1)
          {:error, reason}
      end
    end
  end

  defp listen_one(run, name, path) do
    opts = [
      :binary,
      packet: :raw,
      active: false,
      exit_on_close: false,
      backlog: 128,
      ifaddr: {:local, String.to_charlist(path)}
    ]

    with :ok <- check_path(path),
         _ <- File.rm(path),
         {:ok, lsock} <- :gen_tcp.listen(0, opts),
         :ok <- File.chmod(path, 0o600) do
      me = self()
      acceptor = spawn_link(fn -> accept_loop(lsock, me, run, name) end)
      {:ok, %{run: run, name: name, path: path, lsock: lsock, acceptor: acceptor}}
    end
  end

  defp check_path(path) do
    if byte_size(path) <= @max_socket_path, do: :ok, else: {:error, {:path_too_long, path}}
  end

  # Accepts on the run's listener and hands each socket to the bridge process
  # (which owns the streams) until the listener closes.
  defp accept_loop(lsock, bridge, run, name) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        case :gen_tcp.controlling_process(sock, bridge) do
          :ok -> send(bridge, {:accepted, run, name, sock})
          {:error, _} -> :gen_tcp.close(sock)
        end

        accept_loop(lsock, bridge, run, name)

      {:error, _closed} ->
        :ok
    end
  end

  defp close_listener(%{lsock: lsock, path: path, acceptor: acceptor}) do
    Process.unlink(acceptor)
    :gen_tcp.close(lsock)
    File.rm(path)
  end

  defp release_run(state, run) do
    {listeners, rest} = Map.pop(state.listeners, run, [])
    Enum.each(listeners, &close_listener/1)

    {mine, held} = Enum.split_with(state.held, &(&1.run == run))
    Enum.each(mine, &:gen_tcp.close(&1.sock))

    state = %{state | listeners: rest, held: held}

    case Relay.reset_run(state.relay, run, :run_over) do
      {:cont, relay} -> %{state | relay: relay}
      {:stop, _reason, relay} -> %{state | relay: relay}
    end
  end

  # ---- connections ----------------------------------------------------------

  defp accepted(%{channel: nil} = state, run, name, sock), do: hold(state, run, name, sock)
  defp accepted(state, run, name, sock), do: open_stream(state, run, name, sock)

  defp hold(state, run, name, sock) do
    Process.send_after(self(), {:expire_held, sock}, state.hold_ms)
    held = state.held ++ [%{run: run, name: name, sock: sock}]

    {overflow, kept} = Enum.split(held, max(length(held) - state.hold_max, 0))
    Enum.each(overflow, &:gen_tcp.close(&1.sock))
    %{state | held: kept}
  end

  defp open_held(state) do
    held = state.held
    Enum.reduce(held, %{state | held: []}, &open_stream(&2, &1.run, &1.name, &1.sock))
  end

  defp open_stream(state, run, name, sock) do
    id = state.next_id

    with {:ok, pid} <- Stream.start_link(owner: self(), id: id, socket: sock),
         :ok <- :gen_tcp.controlling_process(sock, pid) do
      case Relay.open_local(state.relay, id, run, name, pid) do
        {:ok, relay} ->
          Stream.go(pid)
          %{state | relay: relay, next_id: id + 1}

        {:error, reason} ->
          Logger.debug("node agent bridge: dropped a connection to #{name}: #{inspect(reason)}")
          Stream.stop(pid)
          state
      end
    else
      _ ->
        :gen_tcp.close(sock)
        state
    end
  end

  defp detach_channel(state) do
    if state.channel, do: Process.demonitor(state.channel.ref, [:flush])
    relay = Relay.clear(state.relay, state.limits)
    %{state | channel: nil, relay: Relay.put_push(relay, fn _event, _payload -> :ok end)}
  end
end
