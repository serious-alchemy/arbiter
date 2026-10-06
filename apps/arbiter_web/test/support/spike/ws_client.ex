defmodule ArbiterWeb.Spike.WsClient do
  @moduledoc """
  RW2 spike (bd-6tx1xv, docs/design/remote-workers.md U2): a Phoenix **V2
  serializer** client on `mint_web_socket`. **Prototype, not product code.**

  Speaks exactly what `Phoenix.Socket.V2.JSONSerializer` decodes/encodes:
  JSON text frames `[join_ref, ref, topic, event, payload]` and the three
  binary kinds (push 0, reply 1, broadcast 2). Ping/pong, close, and the
  `phoenix` heartbeat are handled here. The owner process receives:

    * `{:ws, :push, topic, event, payload}` — `payload` is a map or `{:binary, bin}`
    * `{:ws, :reply, ref, status, payload}`
    * `{:ws, :closed, reason}`

  With `tag: t` every message carries `t` after `:ws` (`{:ws, t, :push, ...}`).
  """
  use GenServer

  @push 0
  @reply 1
  @broadcast 2

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Joins `topic` and blocks for the reply; `{:ok, response}` or `{:error, response}`."
  def join(client, topic, params \\ %{}, timeout \\ 10_000),
    do: GenServer.call(client, {:join, topic, params}, timeout)

  @doc "Pushes on a joined topic; returns the ref so a reply can be matched."
  def push(client, topic, event, payload),
    do: GenServer.call(client, {:push, topic, event, payload})

  def heartbeat(client), do: GenServer.call(client, :heartbeat)

  def close(client), do: GenServer.stop(client, :normal)

  @impl true
  def init(opts) do
    uri = URI.parse(Keyword.fetch!(opts, :url))

    {scheme, http_scheme} =
      if uri.scheme in ["wss", "https"], do: {:wss, :https}, else: {:ws, :http}

    port = uri.port || if(scheme == :wss, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    headers = Keyword.get(opts, :headers, [])

    with {:ok, conn} <-
           Mint.HTTP.connect(
             http_scheme,
             uri.host,
             port,
             [
               protocols: [:http1],
               transport_opts: Keyword.get(opts, :transport_opts, nodelay: true)
             ] ++ proxy_opt(opts)
           ),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(scheme, conn, path, headers) do
      {:ok,
       %{
         owner: Keyword.fetch!(opts, :owner),
         tag: Keyword.get(opts, :tag),
         conn: conn,
         ref: ref,
         ws: nil,
         status: nil,
         resp_headers: [],
         upgraded?: false,
         waiting_upgrade: [],
         next_ref: 1,
         joins: %{},
         pending_joins: %{}
       }}
    else
      {:error, reason} -> {:stop, {:connect_failed, reason}}
      {:error, _conn, reason} -> {:stop, {:upgrade_failed, reason}}
    end
  end

  # K11 spike (bd-6zl538): an HTTP CONNECT proxy, e.g. tailscaled's userspace
  # `--outbound-http-proxy-listen`: `proxy: {:http, "127.0.0.1", 1055, []}`.
  defp proxy_opt(opts) do
    case Keyword.get(opts, :proxy) do
      nil -> []
      proxy -> [proxy: proxy]
    end
  end

  @impl true
  def handle_call(request, from, %{upgraded?: false} = state) do
    {:noreply, %{state | waiting_upgrade: [{request, from} | state.waiting_upgrade]}}
  end

  def handle_call({:join, topic, params}, from, state) do
    {ref, state} = bump(state)
    join_ref = to_string(ref)
    state = %{state | joins: Map.put(state.joins, topic, join_ref)}
    state = put_in(state.pending_joins[to_string(ref)], from)

    {:noreply,
     send_frame(
       state,
       {:text, Jason.encode!([join_ref, to_string(ref), topic, "phx_join", params])}
     )}
  end

  def handle_call({:push, topic, event, payload}, _from, state) do
    {ref, state} = bump(state)
    join_ref = Map.get(state.joins, topic)
    {:reply, ref, send_frame(state, encode_push(join_ref, to_string(ref), topic, event, payload))}
  end

  def handle_call(:heartbeat, _from, state) do
    {ref, state} = bump(state)
    frame = {:text, Jason.encode!([nil, to_string(ref), "phoenix", "heartbeat", %{}])}
    {:reply, ref, send_frame(state, frame)}
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} -> handle_responses(%{state | conn: conn}, responses)
      {:error, conn, reason, _responses} -> closed(%{state | conn: conn}, reason)
      :unknown -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{ws: ws, conn: conn} = state) when not is_nil(ws) do
    _ = send_frame(state, {:close, 1000, ""})
    _ = Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- upgrade + frames ------------------------------------------------------

  defp handle_responses(state, responses) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {:noreply, state} ->
      case handle_response(response, state) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        other -> {:halt, other}
      end
    end)
  end

  defp handle_response({:status, ref, status}, %{ref: ref} = state),
    do: {:noreply, %{state | status: status}}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state),
    do: {:noreply, %{state | resp_headers: headers}}

  defp handle_response({:done, ref}, %{ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, ws} ->
        state = %{state | conn: conn, ws: ws, upgraded?: true}
        # Replay calls that raced the upgrade, oldest first.
        Enum.reduce(Enum.reverse(state.waiting_upgrade), %{state | waiting_upgrade: []}, fn {req,
                                                                                             from},
                                                                                            st ->
          case handle_call(req, from, st) do
            {:reply, reply, st} ->
              GenServer.reply(from, reply)
              st

            {:noreply, st} ->
              st
          end
        end)
        |> then(&{:noreply, &1})

      {:error, conn, reason} ->
        closed(%{state | conn: conn}, {:upgrade_rejected, state.status, reason})
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, ws: ws} = state) when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> handle_frames(%{state | ws: ws}, frames)
      {:error, ws, reason} -> closed(%{state | ws: ws}, reason)
    end
  end

  defp handle_response({:data, ref, _data}, %{ref: ref} = state), do: {:noreply, state}
  defp handle_response(_other, state), do: {:noreply, state}

  defp handle_frames(state, frames) do
    Enum.reduce_while(frames, {:noreply, state}, fn frame, {:noreply, state} ->
      case handle_frame(frame, state) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        other -> {:halt, other}
      end
    end)
  end

  defp handle_frame({:text, text}, state), do: dispatch(state, decode_text(text))
  defp handle_frame({:binary, bin}, state), do: dispatch(state, decode_binary(bin))
  defp handle_frame({:ping, data}, state), do: {:noreply, send_frame(state, {:pong, data})}
  defp handle_frame({:pong, _}, state), do: {:noreply, state}

  defp handle_frame({:close, code, reason}, state) do
    _ = send_frame(state, {:close, code, ""})
    closed(state, {:server_close, code, reason})
  end

  defp handle_frame(_other, state), do: {:noreply, state}

  # -- Phoenix V2 ------------------------------------------------------------

  defp decode_text(text) do
    [join_ref, ref, topic, event, payload | _] = Jason.decode!(text)
    {join_ref, ref, topic, event, payload}
  end

  # server push (no ref)
  defp decode_binary(
         <<@push, jrs, ts, es, join_ref::binary-size(jrs), topic::binary-size(ts),
           event::binary-size(es), data::binary>>
       ),
       do: {join_ref, nil, topic, event, {:binary, data}}

  defp decode_binary(
         <<@reply, jrs, rs, ts, ss, join_ref::binary-size(jrs), ref::binary-size(rs),
           topic::binary-size(ts), status::binary-size(ss), data::binary>>
       ),
       do:
         {join_ref, ref, topic, "phx_reply", %{"status" => status, "response" => {:binary, data}}}

  defp decode_binary(
         <<@broadcast, ts, es, topic::binary-size(ts), event::binary-size(es), data::binary>>
       ),
       do: {nil, nil, topic, event, {:binary, data}}

  defp dispatch(
         state,
         {_join_ref, ref, _topic, "phx_reply", %{"status" => status, "response" => response}}
       ) do
    case Map.pop(state.pending_joins, ref) do
      {nil, _} ->
        notify(state, {:reply, ref, status, response})
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, if(status == "ok", do: {:ok, response}, else: {:error, response}))
        {:noreply, %{state | pending_joins: pending}}
    end
  end

  defp dispatch(state, {_jr, _ref, topic, event, payload}) do
    notify(state, {:push, topic, event, payload})
    {:noreply, state}
  end

  defp encode_push(join_ref, ref, topic, event, {:binary, data}) do
    jr = join_ref || ""

    {:binary,
     <<@push, byte_size(jr), byte_size(ref), byte_size(topic), byte_size(event), jr::binary,
       ref::binary, topic::binary, event::binary, data::binary>>}
  end

  defp encode_push(join_ref, ref, topic, event, payload) when is_map(payload),
    do: {:text, Jason.encode!([join_ref, ref, topic, event, payload])}

  defp send_frame(state, frame) do
    {:ok, ws, data} = Mint.WebSocket.encode(state.ws, frame)

    case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} ->
        %{state | ws: ws, conn: conn}

      {:error, conn, _reason} ->
        %{state | ws: ws, conn: conn}
    end
  end

  # `tag:` (optional) lets one owner multiplex several clients: `{:ws, tag, kind, ...}`.
  defp notify(state, msg) do
    case state.tag do
      nil -> send(state.owner, Tuple.insert_at(msg, 0, :ws))
      tag -> send(state.owner, msg |> Tuple.insert_at(0, tag) |> Tuple.insert_at(0, :ws))
    end
  end

  defp bump(state), do: {state.next_ref, %{state | next_ref: state.next_ref + 1}}

  defp closed(state, reason) do
    notify(state, {:closed, reason})
    {:stop, :normal, state}
  end
end
