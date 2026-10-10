defmodule Arbiter.NodeAgent.PodChannel.BridgeListener do
  @moduledoc """
  The pod channel's bridge listener, `:9443` (`docs/design/remote-workers.md` §16
  K§9.3): raw TLS with `verify_peer` and `fail_if_no_peer_cert`. In a pod the
  in-container `socat` dials it once per bridged connection with the run's leaf
  for that bridge; the leaf's `CN` is the run, its `OU` the bridge name.

  A connection that completes the handshake has a certificate the install's CA
  signed, unexpired and for client authentication. That is **not yet** a run
  this controller assigned: `Arbiter.NodeAgent.PodChannel.Runs.authorize/4` is
  asked next, and only a leaf this controller minted for a live, registered
  run, whose name is one of that run's spec bridges, presented from the run's
  pod IP, gets through. Everything else is closed without a byte read.

  An authorized socket is handed to `Arbiter.NodeAgent.Bridge.adopt/5`, the
  process the machine agent's per-run unix listeners feed. From there it is the
  same code: `bridge.open{run, name, stream}` to the primary, whose
  `Arbiter.Nodes.Bridge` dials its own `Egress` listener. Egress policy,
  `egress_events` and `BridgeIdentity` are untouched.

  Unauthenticated connections cost a process each until their handshake ends:
  at most `:max_handshakes` run at once (default 128) and each is dropped after
  `:handshake_timeout_ms` (default 5 s).

  Options: `:identity` (server certificate), `:ca`, `:runs` (the run table),
  `:bridge` (`Arbiter.NodeAgent.Bridge` server, default the module name), `:ip`,
  `:port` (`0` picks one), `:notify` (a pid sent `{:pod_channel_verdict,
  :bridge, {:ok, %{run:, name:}} | {:error, reason}}` per connection, the
  assertion point for tests: with TLS 1.3 a rejected client sees its handshake
  succeed), `:backlog`, `:send_timeout_ms`.
  """

  use GenServer

  alias Arbiter.NodeAgent.PodChannel.{Runs, Tls}

  require Logger

  @handshake_timeout_ms 5_000
  @max_handshakes 128

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The port the listener is bound to."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    listen_opts =
      Tls.socket_options(opts) ++
        Tls.server_options(Keyword.fetch!(opts, :identity), Keyword.fetch!(opts, :ca)) ++
        [ip: Keyword.get(opts, :ip, {0, 0, 0, 0})]

    case :ssl.listen(Keyword.get(opts, :port, 9443), listen_opts) do
      {:ok, lsock} ->
        {:ok, {_ip, port}} = :ssl.sockname(lsock)
        config = Map.new(opts) |> Map.put(:active, :counters.new(1, []))
        acceptor = spawn_link(fn -> accept_loop(lsock, config) end)
        {:ok, %{lsock: lsock, port: port, acceptor: acceptor}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state),
    do: {:stop, {:acceptor_down, reason}, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{lsock: lsock}), do: :ssl.close(lsock)

  # ---- accepting ---------------------------------------------------------------------

  defp accept_loop(lsock, config) do
    case :ssl.transport_accept(lsock) do
      {:ok, sock} ->
        dispatch(sock, config)
        accept_loop(lsock, config)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.debug("pod channel: bridge accept failed: #{inspect(reason)}")
        accept_loop(lsock, config)
    end
  end

  # The handshake (a network round trip a stranger controls) runs in its own
  # process, never the acceptor.
  defp dispatch(sock, %{active: active} = config) do
    if :counters.get(active, 1) >= Map.get(config, :max_handshakes, @max_handshakes) do
      :ssl.close(sock)
    else
      :counters.add(active, 1, 1)
      pid = spawn(fn -> receive do: (:go -> serve(sock, config)) end)

      case :ssl.controlling_process(sock, pid) do
        :ok ->
          send(pid, :go)

        {:error, _} ->
          :counters.sub(active, 1, 1)
          :ssl.close(sock)
      end
    end
  end

  defp serve(sock, config) do
    timeout = Map.get(config, :handshake_timeout_ms, @handshake_timeout_ms)

    verdict =
      case :ssl.handshake(sock, timeout) do
        {:ok, tls} -> decide(tls, config)
        {:ok, tls, _ext} -> decide(tls, config)
        {:error, reason} -> {:refuse, {:handshake, reason}, nil}
      end

    :counters.sub(config.active, 1, 1)
    finish(verdict, config)
  end

  defp decide(tls, config) do
    with {:ok, der} <- :ssl.peercert(tls),
         {:ok, {ip, _port}} <- :ssl.peername(tls),
         {:ok, who} <- Runs.authorize(Map.get(config, :runs, Runs), :bridge, der, ip) do
      {:ok, who, tls}
    else
      {:error, reason} -> {:refuse, reason, tls}
    end
  end

  defp finish({:ok, %{run: run, name: name} = who, tls}, config) do
    bridge = Map.get(config, :bridge, Arbiter.NodeAgent.Bridge)

    with pid when is_pid(pid) <- GenServer.whereis(bridge),
         :ok <- :ssl.controlling_process(tls, pid) do
      Arbiter.NodeAgent.Bridge.adopt(bridge, run, name, tls, :ssl)
      notify(config, {:ok, who})
    else
      _ ->
        :ssl.close(tls)
        notify(config, {:error, :no_bridge})
    end
  end

  defp finish({:refuse, reason, tls}, config) do
    if tls, do: :ssl.close(tls)
    Logger.info("pod channel: bridge connection refused: #{inspect(reason)}")
    notify(config, {:error, reason})
  end

  defp notify(%{notify: pid}, verdict) when is_pid(pid),
    do: send(pid, {:pod_channel_verdict, :bridge, verdict})

  defp notify(_config, _verdict), do: :ok
end
