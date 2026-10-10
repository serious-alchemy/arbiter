defmodule Arbiter.Nodes.Bridge.Stream do
  @moduledoc """
  One bridged connection's local socket (`docs/design/remote-workers.md` §8): a
  process that owns a unix-socket connection and does its blocking IO, so a peer
  that stops reading stalls **this stream's process** and nothing else. The
  owner (`Arbiter.Nodes.Bridge` on the primary, `Arbiter.NodeAgent.Bridge` on the
  agent) holds the protocol state (`Arbiter.Nodes.Bridge.Core`) and never touches
  a socket.

  A stream is made one of two ways:

    * `dial: path`: connect to a listening unix socket (the primary dials its own
      `Egress` listener), then read it;
    * `socket: sock`: an accepted connection (the agent's per-run listener). The
      owner makes this process the socket's controller and sends `:go`. With
      `transport: :ssl` the socket is a TLS one (the k8s pod channel's `:9443`
      listener, `Arbiter.NodeAgent.PodChannel`); its send timeout is then the
      listener's option, not this process's.

  To the owner it sends `{:bridge_stream, id, event}`:

    * `{:data, bytes}`: read from the socket; reading then stops until `:rearm`
    * `:eof`: the peer closed its writing side
    * `{:wrote, n}`: `n` bytes the owner asked to `{:write, bytes}` are on the socket
    * `{:failed, reason}`: the socket broke or the write timed out; the process exits

  and it takes `{:write, bytes}`, `:rearm`, `:shutdown_write` and `:stop`. It
  exits normally once both directions are closed. A write that cannot finish in
  `:send_timeout_ms` (default 30 s) fails the stream: a consumer that never reads
  does not hold its window forever.
  """

  use GenServer, restart: :temporary

  @send_timeout_ms 30_000
  @dial_timeout_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Accepted-socket mode: the owner has made this process the controller; start reading."
  @spec go(pid()) :: :ok
  def go(pid), do: GenServer.cast(pid, :go)

  @spec write(pid(), binary()) :: :ok
  def write(pid, bytes), do: GenServer.cast(pid, {:write, bytes})

  @spec rearm(pid()) :: :ok
  def rearm(pid), do: GenServer.cast(pid, :rearm)

  @spec shutdown_write(pid()) :: :ok
  def shutdown_write(pid), do: GenServer.cast(pid, :shutdown_write)

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.cast(pid, :stop)

  @doc "Hand an accepted socket (of `transport`) to `pid`."
  @spec controlling_process(:tcp | :ssl, term(), pid()) :: :ok | {:error, term()}
  def controlling_process(:tcp, sock, pid), do: :gen_tcp.controlling_process(sock, pid)
  def controlling_process(:ssl, sock, pid), do: :ssl.controlling_process(sock, pid)

  @doc "Close an accepted socket of `transport`."
  @spec close(:tcp | :ssl, term()) :: :ok
  def close(:tcp, sock), do: :gen_tcp.close(sock)
  def close(:ssl, sock), do: :ssl.close(sock)

  @doc "The socket options a bridged connection uses."
  @spec socket_opts(keyword()) :: keyword()
  def socket_opts(opts \\ []) do
    [
      mode: :binary,
      packet: :raw,
      active: false,
      exit_on_close: false,
      send_timeout: Keyword.get(opts, :send_timeout_ms, @send_timeout_ms),
      send_timeout_close: true
    ]
  end

  @impl true
  def init(opts) do
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      id: Keyword.fetch!(opts, :id),
      sock: nil,
      transport: Keyword.get(opts, :transport, :tcp),
      send_timeout_ms: Keyword.get(opts, :send_timeout_ms, @send_timeout_ms),
      eof_in?: false,
      eof_out?: false
    }

    start(state, opts)
  end

  defp start(state, opts) do
    case Keyword.fetch(opts, :socket) do
      {:ok, sock} ->
        if state.transport == :tcp, do: :ok = :inet.setopts(sock, socket_opts(opts))
        {:ok, %{state | sock: sock}}

      :error ->
        {:ok, state, {:continue, {:dial, Keyword.fetch!(opts, :dial)}}}
    end
  end

  @impl true
  def handle_continue({:dial, path}, state) do
    opts = socket_opts(send_timeout_ms: state.send_timeout_ms)

    case :gen_tcp.connect({:local, to_charlist(path)}, 0, opts, @dial_timeout_ms) do
      {:ok, sock} ->
        :inet.setopts(sock, active: :once)
        {:noreply, %{state | sock: sock}}

      {:error, reason} ->
        fail(state, {:dial, reason})
    end
  end

  @impl true
  def handle_cast(:go, state) do
    activate(state)
    {:noreply, state}
  end

  def handle_cast(:rearm, %{sock: sock, eof_in?: false} = state) when not is_nil(sock) do
    _ = activate(state)
    {:noreply, state}
  end

  def handle_cast(:rearm, state), do: {:noreply, state}

  def handle_cast({:write, bytes}, %{sock: sock} = state) when not is_nil(sock) do
    case send_bytes(state, bytes) do
      :ok ->
        notify(state, {:wrote, byte_size(bytes)})
        {:noreply, state}

      {:error, reason} ->
        fail(state, {:write, reason})
    end
  end

  def handle_cast(:shutdown_write, %{sock: sock} = state) when not is_nil(sock) do
    _ = half_close(state)
    state = %{state | eof_out?: true}
    if state.eof_in?, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_cast(:stop, state), do: {:stop, :normal, state}
  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_info({tag, sock, bytes}, %{sock: sock} = state) when tag in [:tcp, :ssl] do
    notify(state, {:data, bytes})
    {:noreply, state}
  end

  def handle_info({tag, sock}, %{sock: sock} = state) when tag in [:tcp_closed, :ssl_closed] do
    notify(state, :eof)
    state = %{state | eof_in?: true}
    if state.eof_out?, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({tag, sock, reason}, %{sock: sock} = state)
      when tag in [:tcp_error, :ssl_error],
      do: fail(state, {:read, reason})

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{sock: sock, transport: transport}) when not is_nil(sock),
    do: close(transport, sock)

  def terminate(_reason, _state), do: :ok

  defp activate(%{transport: :tcp, sock: sock}), do: :inet.setopts(sock, active: :once)
  defp activate(%{transport: :ssl, sock: sock}), do: :ssl.setopts(sock, active: :once)

  defp send_bytes(%{transport: :tcp, sock: sock}, bytes), do: :gen_tcp.send(sock, bytes)
  defp send_bytes(%{transport: :ssl, sock: sock}, bytes), do: :ssl.send(sock, bytes)

  defp half_close(%{transport: :tcp, sock: sock}), do: :gen_tcp.shutdown(sock, :write)
  defp half_close(%{transport: :ssl, sock: sock}), do: :ssl.shutdown(sock, :write)

  defp notify(%{owner: owner, id: id}, event), do: send(owner, {:bridge_stream, id, event})

  defp fail(state, reason) do
    notify(state, {:failed, reason})
    {:stop, :normal, state}
  end
end
