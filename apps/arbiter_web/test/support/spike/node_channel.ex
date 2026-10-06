defmodule ArbiterWeb.Spike.NodeChannel do
  @moduledoc """
  RW2 spike (bd-6tx1xv): the primary half of the bridge mux, plus the
  heartbeat and echo events the transport checks use. **Prototype, not
  product code.** `bridge.open` dials the unix listener registered in
  `:spike_upstreams` (`{run, name} => path`), standing in for
  `Egress.socket_path/1`; everything else is the design's §4.2 protocol.
  """
  use Phoenix.Channel

  alias ArbiterWeb.Spike.Mux

  @impl true
  def join("node:" <> _, _params, socket) do
    {:ok,
     assign(socket,
       mux: Mux.new(node_cap: Application.get_env(:arbiter_web, :spike_node_cap, 1_048_576)),
       socks: %{},
       by_sock: %{}
     )}
  end

  @impl true
  def handle_in("hb", %{"seq" => seq} = payload, socket) do
    push(socket, "hb_ack", %{"seq" => seq, "t" => payload["t"]})
    {:noreply, socket}
  end

  def handle_in("echo", payload, socket), do: {:reply, {:ok, payload}, socket}

  def handle_in("echo_bin", {:binary, bin}, socket) do
    push(socket, "echo_bin", {:binary, bin})
    {:noreply, socket}
  end

  def handle_in("bridge.open", %{"run" => run, "name" => name, "stream" => id}, socket) do
    path = Application.fetch_env!(:arbiter_web, :spike_upstreams) |> Map.fetch!({run, name})

    case :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, active: :once, packet: :raw]) do
      {:ok, sock} ->
        {:noreply,
         assign(socket,
           mux: Mux.open_stream(socket.assigns.mux, id),
           socks: Map.put(socket.assigns.socks, id, sock),
           by_sock: Map.put(socket.assigns.by_sock, sock, id)
         )}

      {:error, _} ->
        push(socket, "bridge.close", %{"stream" => id})
        {:noreply, socket}
    end
  end

  def handle_in("bridge.data", {:binary, <<"ARB1", _seq::64, id::32, bytes::binary>>}, socket) do
    case socket.assigns.socks do
      %{^id => sock} ->
        _ = :gen_tcp.send(sock, bytes)
        push(socket, "bridge.credit", %{"stream" => id, "n" => byte_size(bytes)})

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_in("bridge.credit", %{"stream" => id, "n" => n}, socket) do
    {mux, actions} = Mux.credit(socket.assigns.mux, id, n)
    {:noreply, perform(actions, assign(socket, :mux, mux))}
  end

  def handle_in("bridge.close", %{"stream" => id}, socket) do
    case socket.assigns.socks do
      %{^id => sock} -> _ = :gen_tcp.shutdown(sock, :write)
      _ -> :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:tcp, sock, data}, socket) do
    case socket.assigns.by_sock do
      %{^sock => id} ->
        {mux, actions} = Mux.local_data(socket.assigns.mux, id, data)
        {:noreply, perform(actions, assign(socket, :mux, mux))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:tcp_closed, sock}, socket) do
    case socket.assigns.by_sock do
      %{^sock => id} ->
        {mux, actions} = Mux.local_closed(socket.assigns.mux, id)
        {:noreply, perform(actions, assign(socket, :mux, mux))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:tcp_error, _sock, _reason}, socket), do: {:noreply, socket}

  defp perform(actions, socket) do
    Enum.each(actions, fn
      {:frame, _id, frame} -> push(socket, "bridge.data", {:binary, frame})
      {:close, id} -> push(socket, "bridge.close", %{"stream" => id})
      {:rearm, id} -> if sock = socket.assigns.socks[id], do: :inet.setopts(sock, active: :once)
    end)

    socket
  end
end
