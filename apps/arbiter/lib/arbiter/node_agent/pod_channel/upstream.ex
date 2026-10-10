defmodule Arbiter.NodeAgent.PodChannel.Upstream do
  @moduledoc """
  The controller's leg to the primary for the checkout and transcript traffic
  (`docs/design/remote-workers.md` §16 K§10.1, K§10.3): the same routes and node
  credential the machine agent uses (`GET /nodes/runs/:run/seed.bundle`,
  `PUT /nodes/runs/:run/checkout`, `PUT /nodes/runs/:run/transcripts`).

  The controller **never parses a bundle or a tar**: it moves bytes. The seed is
  streamed primary → pod and an upload pod → primary, chunk by chunk, so neither
  is held in memory or written to a file and backpressure is TCP's end to end.
  Quarantine, `fsck`, the ref allowlist and the primary-side path filter all stay
  on the primary (`Arbiter.Nodes.Checkout`), exactly as for a machine node.
  """

  alias Arbiter.NodeAgent.Config

  @pull_timeout_ms 120_000
  @receive_timeout_ms 600_000
  @read_length 262_144

  @doc """
  Stream the seed bundle of `run` into `conn` (a chunked `200`). A non-`200` from
  the primary (a veto, an unknown run) is relayed as its status and small body.
  Returns the `conn`; raises if the primary breaks the stream after bytes were
  sent, so the pod sees a connection error, not a short bundle that looks whole.
  """
  @spec stream_seed(Config.t(), String.t(), String.t(), Plug.Conn.t()) :: Plug.Conn.t()
  def stream_seed(%Config{} = config, run, have, conn) do
    sink = fn {:data, data}, {req, resp} ->
      current = resp.private[:pod_conn] || conn

      if resp.status == 200 do
        current = if resp.private[:pod_started], do: current, else: start_chunked(current)

        case Plug.Conn.chunk(current, data) do
          {:ok, current} ->
            {:cont, {req, resp |> put(:pod_conn, current) |> put(:pod_started, true)}}

          {:error, _closed} ->
            {:halt, {req, resp |> put(:pod_conn, current) |> put(:pod_gone, true)}}
        end
      else
        {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
      end
    end

    request =
      Req.new(
        [
          url: Config.http_url(config, "/nodes/runs/#{run}/seed.bundle"),
          params: [have: have],
          headers: [{"authorization", "Bearer " <> config.credential}],
          decode_body: false,
          into: sink,
          retry: false,
          receive_timeout: @receive_timeout_ms
        ] ++ (config.req_options || [])
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: 200} = resp} ->
        finish_seed(resp, conn)

      {:ok, %Req.Response{status: status, body: body}} ->
        relay(conn, status, body)

      {:error, reason} ->
        if conn.state == :chunked or conn.state == :sent do
          raise "pod channel: seed stream for #{run} broke: #{inspect(reason)}"
        else
          relay(conn, 502, ~s({"error":"primary_unreachable"}))
        end
    end
  end

  defp finish_seed(resp, conn) do
    case resp.private do
      %{pod_started: true, pod_conn: current} ->
        current

      # a 200 with an empty body: an empty bundle is still a response
      _ ->
        conn |> start_chunked() |> Plug.Conn.halt()
    end
  end

  defp start_chunked(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/octet-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_chunked(200)
  end

  defp relay(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body_binary(body))
  end

  defp body_binary(body) when is_binary(body), do: body
  defp body_binary(nil), do: ""
  defp body_binary(other), do: Jason.encode!(other)

  defp put(resp, key, value), do: Req.Response.put_private(resp, key, value)

  @doc """
  Forward the request body of `conn` (`length` bytes, already checked against the
  limit) to the primary as `PUT /nodes/runs/<run>/<route>`. Returns
  `{result, conn}`: `{:ok, status, body}` for a `200`, `{:rejected, status, body}`
  for any other status, `{:error, reason}` when the primary was unreachable or the
  pod's body broke off.

  The body is pumped through a request task a chunk at a time, so the plug
  process keeps the `conn` (and its adapter state) and no byte is buffered beyond
  one chunk.
  """
  @spec put_stream(
          Config.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          Plug.Conn.t()
        ) ::
          {term(), Plug.Conn.t()}
  def put_stream(%Config{} = config, run, route, content_type, length, conn) do
    parent = self()
    ref = make_ref()

    body =
      Stream.resource(
        fn -> :ok end,
        fn state ->
          send(parent, {ref, :pull, self()})

          receive do
            {^ref, :chunk, data} -> {[data], state}
            {^ref, :eof} -> {:halt, state}
            {^ref, :abort} -> raise "request body from the pod broke off"
          after
            @pull_timeout_ms -> raise "request body from the pod stalled"
          end
        end,
        fn _ -> :ok end
      )

    request =
      Req.new(
        [
          url: Config.http_url(config, "/nodes/runs/#{run}/#{route}"),
          method: :put,
          headers: [
            {"authorization", "Bearer " <> config.credential},
            {"content-type", content_type},
            {"content-length", Integer.to_string(length)}
          ],
          body: body,
          decode_body: false,
          retry: false,
          receive_timeout: @receive_timeout_ms
        ] ++ (config.req_options || [])
      )

    task = Task.async(fn -> send_request(request) end)
    pump(conn, ref, task, false)
  end

  defp send_request(request) do
    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, 200, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:rejected, status, body}
      {:error, reason} -> {:error, {:upload_failed, reason}}
    end
  rescue
    e -> {:error, {:upload_failed, Exception.message(e)}}
  end

  defp pump(conn, ref, %Task{ref: task_ref} = task, done?) do
    receive do
      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])
        {result, conn}

      {^ref, :pull, from} ->
        pump_chunk(conn, ref, task, from, done?)
    end
  end

  defp pump_chunk(conn, ref, task, from, true) do
    send(from, {ref, :eof})
    pump(conn, ref, task, true)
  end

  defp pump_chunk(conn, ref, task, from, false) do
    case Plug.Conn.read_body(conn, length: @read_length, read_length: @read_length) do
      {:ok, "", conn} ->
        send(from, {ref, :eof})
        pump(conn, ref, task, true)

      {:ok, data, conn} ->
        send(from, {ref, :chunk, data})
        pump(conn, ref, task, true)

      {:more, data, conn} ->
        send(from, {ref, :chunk, data})
        pump(conn, ref, task, false)

      {:error, _reason} ->
        send(from, {ref, :abort})
        pump(conn, ref, task, true)
    end
  end
end
