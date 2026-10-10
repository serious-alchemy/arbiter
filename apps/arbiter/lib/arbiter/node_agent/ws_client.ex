defmodule Arbiter.NodeAgent.WsClient do
  @moduledoc """
  A Phoenix **V2 serializer** WebSocket client on `mint_web_socket`
  (`docs/design/remote-workers.md` §4.1, RW2 U2). One process per connection;
  `Arbiter.NodeAgent.Connection` owns it, reconnects by starting a new one, and
  owns the backoff (this module has none).

  Speaks what `Phoenix.Socket.V2.JSONSerializer` decodes and encodes: JSON text
  frames `[join_ref, ref, topic, event, payload]` and the three binary kinds
  (push 0, reply 1, broadcast 2). Ping/pong and close are answered here, and so
  is the `phoenix` heartbeat that keeps Phoenix's 60 s idle timeout at bay: a
  heartbeat still unanswered when the next is due closes the connection, which
  is how a half-dead TCP connection is noticed. Those heartbeats are never shown
  to the owner.

  `start/1` connects (TCP + TLS) and returns `{:error, reason}` when it cannot.
  The WebSocket upgrade finishes asynchronously: `join/3` and `push/4` made
  before it are queued and replayed in order. The owner receives:

    * `{:ws, pid, :open}` — the upgrade completed
    * `{:ws, pid, :reply, ref, status, response}` — `status` is `"ok"` / `"error"`
    * `{:ws, pid, :push, topic, event, payload}` — `payload` is a map or `{:binary, bin}`
    * `{:ws, pid, :closed, reason}` — then the process exits normally

  It connects with `nodelay: true`: Mint leaves Nagle on, and the
  request/response pattern then stalls on delayed ACKs (RW2: median ≈46 ms
  instead of ≈5 ms on loopback).
  """
  use GenServer

  @push 0
  @reply 1
  @broadcast 2

  @default_heartbeat_ms 30_000
  @default_connect_timeout_ms 10_000

  @type t :: pid()

  @doc """
  Connect. Options: `:url` (`ws://` / `wss://`), `:owner` (default: the
  caller), `:headers`, `:connect_timeout_ms`, `:phoenix_heartbeat_ms`,
  `:transport_opts` (merged into the *target's* transport options, e.g. a CA
  bundle), and `:proxy` — an HTTP proxy to CONNECT through, `{:http, host, port, []}`
  or a `http://host:port` URL (tailscale's userspace proxy is `127.0.0.1:1055`,
  §2.3). Plain `ws://` is accepted only to a loopback host; anything else is
  `{:error, {:insecure_url, url}}`, with or without a proxy.
  """
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts) do
    opts = Keyword.put_new(opts, :owner, self())

    case GenServer.start(__MODULE__, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:connect_failed, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Join `topic`; returns the ref the `:reply` will carry, or `{:error, :closed}`
  when the connection is already gone (the owner gets, or already has, `:closed`).
  """
  @spec join(t(), String.t(), map()) :: String.t() | {:error, :closed}
  def join(client, topic, params \\ %{}), do: call(client, {:join, topic, params})

  @doc "Push on a joined topic; returns the ref a reply will carry, or `{:error, :closed}`."
  @spec push(t(), String.t(), String.t(), map() | {:binary, binary()}) ::
          String.t() | {:error, :closed}
  def push(client, topic, event, payload), do: call(client, {:push, topic, event, payload})

  defp call(client, request) do
    GenServer.call(client, request)
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc "Close the connection with a normal WebSocket close."
  @spec close(t()) :: :ok
  def close(client) do
    GenServer.stop(client, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    uri = URI.parse(url)

    with :ok <- secure(uri, url),
         {:ok, proxy} <- parse_proxy(Keyword.get(opts, :proxy)) do
      connect(uri, Keyword.put(opts, :proxy, proxy))
    else
      {:error, reason} -> {:stop, {:connect_failed, reason}}
    end
  end

  defp secure(%URI{scheme: "wss"}, _url), do: :ok

  defp secure(%URI{scheme: "ws", host: host}, url) when is_binary(host) do
    if Arbiter.NodeAgent.Config.loopback_host?(host),
      do: :ok,
      else: {:error, {:insecure_url, url}}
  end

  defp secure(_uri, url), do: {:error, {:insecure_url, url}}

  defp parse_proxy(nil), do: {:ok, nil}

  defp parse_proxy({:http, host, port, _opts} = proxy) when is_binary(host) and is_integer(port),
    do: {:ok, proxy}

  defp parse_proxy(url) when is_binary(url) do
    # `HTTPS_PROXY=host:port` without a scheme is common; treat it as http.
    full = if String.contains?(url, "://"), do: url, else: "http://" <> url

    case URI.parse(full) do
      %URI{scheme: "http", host: host, port: port} when is_binary(host) and host != "" ->
        {:ok, {:http, host, port || 80, []}}

      _ ->
        {:error, {:bad_proxy, url}}
    end
  end

  defp parse_proxy(other), do: {:error, {:bad_proxy, other}}

  defp proxy_opt(nil), do: []
  defp proxy_opt(proxy), do: [proxy: proxy]

  defp connect(uri, opts) do
    {scheme, http_scheme} = if uri.scheme == "wss", do: {:wss, :https}, else: {:ws, :http}
    port = uri.port || if(scheme == :wss, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")
    timeout = Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)
    owner = Keyword.fetch!(opts, :owner)

    with {:ok, conn} <-
           Mint.HTTP.connect(
             http_scheme,
             uri.host,
             port,
             [
               protocols: [:http1],
               transport_opts:
                 Keyword.merge(
                   [nodelay: true, timeout: timeout],
                   Keyword.get(opts, :transport_opts, [])
                 )
             ] ++ proxy_opt(Keyword.get(opts, :proxy))
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(scheme, conn, path, Keyword.get(opts, :headers, [])) do
      heartbeat_ms = Keyword.get(opts, :phoenix_heartbeat_ms, @default_heartbeat_ms)

      {:ok,
       %{
         owner: owner,
         owner_ref: Process.monitor(owner),
         conn: conn,
         ref: ref,
         ws: nil,
         status: nil,
         resp_headers: [],
         queued: [],
         next_ref: 1,
         joins: %{},
         heartbeat_ms: heartbeat_ms,
         pending_heartbeat: nil
       }}
    else
      {:error, reason} ->
        {:stop, {:connect_failed, reason}}

      {:error, conn, reason} ->
        _ = Mint.HTTP.close(conn)
        {:stop, {:connect_failed, reason}}
    end
  end

  @impl true
  def handle_call(request, from, %{ws: nil} = state),
    do: {:noreply, %{state | queued: [{request, from} | state.queued]}}

  def handle_call({:join, topic, params}, _from, state) do
    {ref, state} = bump(state)
    state = %{state | joins: Map.put(state.joins, topic, ref)}
    frame = {:text, Jason.encode!([ref, ref, topic, "phx_join", params])}
    {:reply, ref, send_frame(state, frame)}
  end

  def handle_call({:push, topic, event, payload}, _from, state) do
    {ref, state} = bump(state)
    {:reply, ref, send_frame(state, encode_push(state.joins[topic], ref, topic, event, payload))}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:phoenix_heartbeat, %{pending_heartbeat: pending} = state)
      when not is_nil(pending),
      do: closed(state, :heartbeat_timeout)

  def handle_info(:phoenix_heartbeat, state) do
    {ref, state} = bump(state)
    state = send_frame(state, {:text, Jason.encode!([nil, ref, "phoenix", "heartbeat", %{}])})
    Process.send_after(self(), :phoenix_heartbeat, state.heartbeat_ms)
    {:noreply, %{state | pending_heartbeat: ref}}
  end

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

  def terminate(_reason, %{conn: conn}) do
    _ = Mint.HTTP.close(conn)
    :ok
  end

  # -- upgrade + frames ---------------------------------------------------------

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
        state = %{state | conn: conn, ws: ws}
        notify(state, :open)

        if state.heartbeat_ms > 0,
          do: Process.send_after(self(), :phoenix_heartbeat, state.heartbeat_ms)

        {:noreply, replay_queued(state)}

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

  defp handle_response(_other, state), do: {:noreply, state}

  # Calls that raced the upgrade, oldest first.
  defp replay_queued(state) do
    queued = Enum.reverse(state.queued)

    Enum.reduce(queued, %{state | queued: []}, fn {request, from}, state ->
      {:reply, reply, state} = handle_call(request, from, state)
      GenServer.reply(from, reply)
      state
    end)
  end

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

  # -- Phoenix V2 -----------------------------------------------------------------

  defp decode_text(text) do
    case Jason.decode(text) do
      {:ok, [join_ref, ref, topic, event, payload | _]} -> {join_ref, ref, topic, event, payload}
      _ -> :ignore
    end
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

  defp decode_binary(_), do: :ignore

  defp dispatch(state, :ignore), do: {:noreply, state}

  # Our own phoenix heartbeat answered.
  defp dispatch(%{pending_heartbeat: ref} = state, {_, ref, "phoenix", "phx_reply", _})
       when not is_nil(ref),
       do: {:noreply, %{state | pending_heartbeat: nil}}

  defp dispatch(state, {_jr, ref, _topic, "phx_reply", %{"status" => status} = payload}) do
    notify(state, :reply, [ref, status, Map.get(payload, "response")])
    {:noreply, state}
  end

  defp dispatch(state, {_jr, _ref, topic, event, payload}) do
    notify(state, :push, [topic, event, payload])
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
    # A write that fails means the socket is gone; the read side reports the
    # close, so a failure here changes nothing.
    case Mint.WebSocket.encode(state.ws, frame) do
      {:ok, ws, data} -> stream_frame(%{state | ws: ws}, data)
      {:error, ws, _reason} -> %{state | ws: ws}
    end
  end

  defp stream_frame(state, data) do
    case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} -> %{state | conn: conn}
      {:error, conn, _reason} -> %{state | conn: conn}
    end
  end

  defp notify(state, kind, args \\ []),
    do: send(state.owner, List.to_tuple([:ws, self(), kind | args]))

  defp bump(state),
    do: {Integer.to_string(state.next_ref), %{state | next_ref: state.next_ref + 1}}

  defp closed(state, reason) do
    # Callers still waiting on an upgrade that will never finish.
    Enum.each(state.queued, fn {_request, from} -> GenServer.reply(from, {:error, :closed}) end)
    notify(state, :closed, [reason])
    {:stop, :normal, state}
  end
end
