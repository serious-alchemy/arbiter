defmodule ArbiterWeb.Spike.AgentMux do
  @moduledoc """
  RW2 spike (bd-6tx1xv, remote-workers design §4.2/§8): the **node agent** half
  of the bridge mux — per-run unix listeners whose accepted connections become
  `bridge.open` streams over one `WsClient` socket, plus the 10 s-style
  heartbeat (interval configurable) whose `hb_ack` round trips U4 measures.
  **Prototype, not product code.**
  """
  use GenServer

  alias ArbiterWeb.Spike.Mux
  alias ArbiterWeb.Spike.WsClient

  @topic "node:spike"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Heartbeat samples so far: `[{sent_at_ms, rtt_ms}]` oldest first, and the ack arrival times."
  def heartbeats(pid), do: GenServer.call(pid, :heartbeats)

  def stop_heartbeats(pid), do: GenServer.call(pid, :stop_heartbeats)

  def stats(pid), do: GenServer.call(pid, :stats)

  @impl true
  def init(opts) do
    {:ok, client} =
      WsClient.start_link(
        url: Keyword.fetch!(opts, :url),
        owner: self(),
        transport_opts: opts[:transport_opts] || []
      )

    {:ok, _} = WsClient.join(client, @topic, %{})

    listeners =
      for {run, path} <- Keyword.fetch!(opts, :listeners), into: %{} do
        File.rm(path)

        {:ok, lsock} =
          :gen_tcp.listen(0, [
            :binary,
            ifaddr: {:local, to_charlist(path)},
            active: false,
            backlog: 128
          ])

        parent = self()
        {:ok, acceptor} = Task.start_link(fn -> accept_loop(lsock, run, parent) end)
        {run, {lsock, acceptor}}
      end

    state = %{
      client: client,
      mux: Mux.new(Keyword.get(opts, :mux, [])),
      socks: %{},
      by_sock: %{},
      names: %{},
      next_stream: 1,
      listeners: listeners,
      hb_ms: Keyword.get(opts, :hb_ms),
      hb_seq: 0,
      hb_sent: %{},
      hb_samples: [],
      rx_frames: 0,
      rx_bytes: 0,
      tx_frames: 0
    }

    if state.hb_ms, do: Process.send_after(self(), :hb, state.hb_ms)
    {:ok, state}
  end

  defp accept_loop(lsock, run, parent) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        :ok = :gen_tcp.controlling_process(sock, parent)
        send(parent, {:accepted, run, sock})
        accept_loop(lsock, run, parent)

      {:error, _} ->
        :ok
    end
  end

  @impl true
  def handle_call(:heartbeats, _from, state), do: {:reply, Enum.reverse(state.hb_samples), state}
  def handle_call(:stop_heartbeats, _from, state), do: {:reply, :ok, %{state | hb_ms: nil}}

  def handle_call(:stats, _from, state),
    do:
      {:reply,
       %{
         rx_frames: state.rx_frames,
         rx_bytes: state.rx_bytes,
         tx_frames: state.tx_frames,
         streams: map_size(state.socks)
       }, state}

  @impl true
  def handle_info(:hb, %{hb_ms: nil} = state), do: {:noreply, state}

  def handle_info(:hb, state) do
    seq = state.hb_seq + 1
    now = now_ms()
    WsClient.push(state.client, @topic, "hb", %{"seq" => seq, "t" => now})
    Process.send_after(self(), :hb, state.hb_ms)
    {:noreply, %{state | hb_seq: seq, hb_sent: Map.put(state.hb_sent, seq, now)}}
  end

  def handle_info({:accepted, run, sock}, state) do
    id = state.next_stream

    WsClient.push(state.client, @topic, "bridge.open", %{
      "run" => run,
      "name" => "proxy",
      "stream" => id
    })

    :inet.setopts(sock, active: :once)

    {:noreply,
     %{
       state
       | next_stream: id + 1,
         mux: Mux.open_stream(state.mux, id),
         socks: Map.put(state.socks, id, sock),
         by_sock: Map.put(state.by_sock, sock, id)
     }}
  end

  def handle_info({:tcp, sock, data}, state) do
    case state.by_sock do
      %{^sock => id} ->
        {mux, actions} = Mux.local_data(state.mux, id, data)
        {:noreply, perform(actions, %{state | mux: mux})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, sock}, state) do
    case state.by_sock do
      %{^sock => id} ->
        {mux, actions} = Mux.local_closed(state.mux, id)
        {:noreply, perform(actions, %{state | mux: mux})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_error, _, _}, state), do: {:noreply, state}

  def handle_info({:ws, :push, @topic, "hb_ack", %{"seq" => seq}}, state) do
    now = now_ms()

    case Map.pop(state.hb_sent, seq) do
      {nil, _} ->
        {:noreply, state}

      {sent, rest} ->
        {:noreply,
         %{state | hb_sent: rest, hb_samples: [{sent, now - sent, now} | state.hb_samples]}}
    end
  end

  def handle_info(
        {:ws, :push, @topic, "bridge.data",
         {:binary, <<"ARB1", _seq::64, id::32, bytes::binary>>}},
        state
      ) do
    case state.socks do
      %{^id => sock} ->
        _ = :gen_tcp.send(sock, bytes)

        WsClient.push(state.client, @topic, "bridge.credit", %{
          "stream" => id,
          "n" => byte_size(bytes)
        })

        {:noreply,
         %{state | rx_frames: state.rx_frames + 1, rx_bytes: state.rx_bytes + byte_size(bytes)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:ws, :push, @topic, "bridge.credit", %{"stream" => id, "n" => n}}, state) do
    {mux, actions} = Mux.credit(state.mux, id, n)
    {:noreply, perform(actions, %{state | mux: mux})}
  end

  def handle_info({:ws, :push, @topic, "bridge.close", %{"stream" => id}}, state) do
    case state.socks do
      %{^id => sock} -> _ = :gen_tcp.shutdown(sock, :write)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:ws, :closed, reason}, state) do
    IO.puts(:stderr, "AgentMux: websocket closed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:ws, _, _, _, _}, state), do: {:noreply, state}
  def handle_info({:ws, _, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_run, {lsock, _}} <- state.listeners, do: :gen_tcp.close(lsock)
    :ok
  end

  defp perform(actions, state) do
    Enum.reduce(actions, state, fn
      {:frame, _id, frame}, st ->
        WsClient.push(st.client, @topic, "bridge.data", {:binary, frame})
        %{st | tx_frames: st.tx_frames + 1}

      {:close, id}, st ->
        WsClient.push(st.client, @topic, "bridge.close", %{"stream" => id})
        st

      {:rearm, id}, st ->
        if sock = st.socks[id], do: :inet.setopts(sock, active: :once)
        st
    end)
  end

  defp now_ms, do: System.monotonic_time(:microsecond) / 1000
end
