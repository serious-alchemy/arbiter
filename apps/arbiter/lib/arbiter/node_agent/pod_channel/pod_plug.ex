defmodule Arbiter.NodeAgent.PodChannel.PodPlug do
  @moduledoc """
  The routes of the pod channel's HTTPS listener, `:9444`
  (`docs/design/remote-workers.md` §16 K§9.3, K§10).

  | route | auth | does |
  |---|---|---|
  | `POST /boot` | server-authenticated only; the nonce is the body | redeem the single-use boot nonce: the run's certificates, secrets and seed files as a tar (`Arbiter.NodeAgent.PodChannel.BootBundle`) |
  | `GET /seed.bundle[?have=]` | `control` client certificate | stream the primary's seed bundle for the certificate's run |
  | `PUT /checkpoint` | `control` client certificate | forward a checkpoint bundle to `PUT /nodes/runs/:run/checkout` |
  | `PUT /transcripts` | `control` client certificate | forward the transcripts tar to `PUT /nodes/runs/:run/transcripts` |
  | `GET /commands[?wait=s]` | `control` client certificate | long-poll the run's command mailbox |

  **The run is the certificate's `CN`, never the URL or the body**, and the
  certificate must be the very leaf `Arbiter.NodeAgent.PodChannel.Runs` minted
  for it, presented from the run's pod IP (`Runs.authorize/4`). A pod can reach
  nothing but its own run. A bridge leaf is not a `control` leaf.

  Uploads need a `Content-Length` (`411` without) within `:max_upload_bytes`
  (`413` before a byte is read), and are moved, never parsed
  (`Arbiter.NodeAgent.PodChannel.Upstream`). After an upload the plug sends
  `{:pod_channel_upload, run, :checkpoint | :transcripts, result}` to `:notify`,
  which is how the controller learns the final snapshot has been forwarded and
  may hold `exit` until then (K§10.3).

  Plug options: `:runs`, `:config` (`Arbiter.NodeAgent.Config`, the primary and
  its credential), `:notify`, `:max_upload_bytes` (default 1 GiB).
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.NodeAgent.PodChannel.{Runs, Upstream}

  require Logger

  @max_nonce_bytes 512
  @default_max_upload 1_073_741_824
  @max_wait_s 30
  @default_wait_s 25

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case {conn.method, conn.path_info} do
      {"POST", ["boot"]} ->
        boot(conn, opts)

      {_, ["boot"]} ->
        json(conn, 405, %{error: "method_not_allowed"})

      {"GET", ["seed.bundle"]} ->
        control(conn, opts, &seed/3)

      {"PUT", ["checkpoint"]} ->
        control(conn, opts, &upload(&1, &2, &3, :checkpoint))

      {"PUT", ["transcripts"]} ->
        control(conn, opts, &upload(&1, &2, &3, :transcripts))

      {"GET", ["commands"]} ->
        control(conn, opts, &commands/3)

      {_, [route]} when route in ["seed.bundle", "checkpoint", "transcripts", "commands"] ->
        json(conn, 405, %{error: "method_not_allowed"})

      _ ->
        json(conn, 404, %{error: "not_found"})
    end
  end

  # ---- /boot -------------------------------------------------------------------------

  defp boot(conn, opts) do
    case read_body(conn, length: @max_nonce_bytes) do
      {:ok, body, conn} ->
        redeem(conn, opts, String.trim(body))

      {:more, _body, conn} ->
        json(conn, 413, %{error: "too_large"})

      {:error, _} ->
        json(conn, 400, %{error: "bad_request"})
    end
  end

  defp redeem(conn, opts, nonce) do
    ip = peer_ip(conn)

    case Runs.redeem(runs(opts), nonce, ip) do
      {:ok, run, tar} ->
        Logger.info("pod channel: run #{run} redeemed its boot nonce")

        conn
        |> put_resp_content_type("application/x-tar")
        |> send_resp(200, tar)

      {:error, :unbound} ->
        conn |> put_resp_header("retry-after", "1") |> json(409, %{error: "not_ready"})

      {:error, reason} ->
        Logger.warning("pod channel: boot refused (#{reason}) from #{inspect(ip)}")
        json(conn, 403, %{error: "forbidden"})
    end
  end

  # ---- the control routes ------------------------------------------------------------

  defp control(conn, opts, fun) do
    case peer_cert(conn) do
      nil ->
        json(conn, 401, %{error: "client_certificate_required"})

      der ->
        case Runs.authorize(runs(opts), :control, der, peer_ip(conn)) do
          {:ok, %{run: run}} ->
            fun.(conn, opts, run)

          {:error, reason} ->
            Logger.warning("pod channel: control request refused: #{inspect(reason)}")
            json(conn, 403, %{error: "forbidden"})
        end
    end
  end

  defp seed(conn, opts, run) do
    conn = fetch_query_params(conn)
    have = conn.query_params["have"] || ""
    Upstream.stream_seed(Keyword.fetch!(opts, :config), run, String.slice(have, 0, 4_096), conn)
  end

  defp upload(conn, opts, run, kind) do
    max = Keyword.get(opts, :max_upload_bytes, @default_max_upload)

    case content_length(conn) do
      :none ->
        json(conn, 411, %{error: "length_required"})

      :bad ->
        json(conn, 400, %{error: "bad_content_length"})

      {:ok, length} when length > max ->
        json(conn, 413, %{error: "too_large"})

      {:ok, length} ->
        forward(conn, opts, run, kind, length)
    end
  end

  defp forward(conn, opts, run, kind, length) do
    {route, default_type} = route_of(kind)
    type = List.first(get_req_header(conn, "content-type")) || default_type

    {result, conn} =
      Upstream.put_stream(Keyword.fetch!(opts, :config), run, route, type, length, conn)

    notify(opts, {:pod_channel_upload, run, kind, summary(result)})

    case result do
      {:ok, 200, body} -> raw(conn, 200, body)
      {:rejected, status, body} -> raw(conn, status, body)
      {:error, _reason} -> json(conn, 502, %{error: "primary_unreachable"})
    end
  end

  defp route_of(:checkpoint), do: {"checkout", "application/x-git-bundle"}
  defp route_of(:transcripts), do: {"transcripts", "application/gzip"}

  defp summary({:ok, status, _body}), do: {:ok, status}
  defp summary({:rejected, status, _body}), do: {:error, {:rejected, status}}
  defp summary({:error, reason}), do: {:error, reason}

  defp commands(conn, opts, run) do
    conn = fetch_query_params(conn)

    wait_s =
      case Integer.parse(conn.query_params["wait"] || "") do
        {n, ""} -> n |> max(0) |> min(@max_wait_s)
        _ -> @default_wait_s
      end

    case Runs.await_commands(runs(opts), run, wait_s * 1_000) do
      {:ok, commands} -> json(conn, 200, %{commands: commands})
      {:error, _} -> json(conn, 403, %{error: "forbidden"})
    end
  end

  # ---- helpers -----------------------------------------------------------------------

  defp runs(opts), do: Keyword.get(opts, :runs, Runs)

  defp peer_cert(conn), do: conn |> get_peer_data() |> Map.get(:ssl_cert)
  defp peer_ip(conn), do: conn |> get_peer_data() |> Map.get(:address)

  defp content_length(conn) do
    chunked? = get_req_header(conn, "transfer-encoding") != []

    case get_req_header(conn, "content-length") do
      [value] when not chunked? ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> :bad
        end

      [] ->
        :none

      _ ->
        if chunked?, do: :none, else: :bad
    end
  end

  defp notify(opts, message) do
    case Keyword.get(opts, :notify) do
      pid when is_pid(pid) -> send(pid, message)
      fun when is_function(fun, 1) -> fun.(message)
      _ -> :ok
    end
  end

  defp raw(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
