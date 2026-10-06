defmodule ArbiterWeb.NodeController do
  @moduledoc """
  The node join flow's HTTP surface (`docs/design/remote-workers.md` §5.2,
  §5.4–§5.5, §6), under `/nodes/*`, outside `/api` and `/mcp`.

  Anonymous (no node credential exists yet, or none is needed):

    * `GET /nodes/join` — the join script, rendered from `nodes.public_url`.
    * `GET /nodes/ping` — `pong`, so the script can check reachability before
      it spends a token.
    * `POST /nodes/enroll` — a join token **in the JSON body** (never a header
      or the query string) for a node credential. Rate limited
      (`Arbiter.Nodes.RateLimit`); every token failure is the same generic
      `401`.

  Behind `ArbiterWeb.Plugs.NodeAuth` (a node credential, nothing else):

    * `GET /nodes/agent/<version>.tar.gz` — the agent build the primary runs
      (`Arbiter.Nodes.Agent`), only for the version the enroll response named.
    * `GET /nodes/files/<sha256>` — the same bytes addressed by content hash.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Agent, JoinScript, RateLimit}
  alias Arbiter.Settings
  alias ArbiterWeb.Loopback

  @unauthorized "Invalid or expired join token"

  # ---- anonymous -----------------------------------------------------------

  def join(conn, _params) do
    case Settings.nodes_public_url() do
      nil ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "nodes.public_url is not set on the primary; set it first\n")

      url ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, JoinScript.render(public_url: url))
    end
  end

  def ping(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "pong")
  end

  def enroll(conn, _params) do
    key = source_key(conn)
    # `params` merges the query string and path; the token is read from the
    # request body only (a `?token=` would end up in access logs).
    body = body_params(conn)

    with :ok <- rate_limit(key),
         {:ok, url} <- public_url(),
         {:ok, artifact} <- agent_artifact() do
      redeem(conn, body, key, url, artifact)
    else
      {:error, {:rate_limited, seconds}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> error(429, "Too many enrolment attempts")

      {:error, :unconfigured} ->
        error(conn, 503, "nodes.public_url is not set on the primary")

      {:error, :unavailable} ->
        error(conn, 503, "The primary has no agent build to serve")
    end
  end

  defp body_params(%Plug.Conn{body_params: %{} = body}) when not is_struct(body), do: body
  defp body_params(_conn), do: %{}

  defp rate_limit(key), do: RateLimit.check(:enroll, key)

  defp public_url do
    case Settings.nodes_public_url() do
      nil -> {:error, :unconfigured}
      url -> {:ok, url}
    end
  end

  defp agent_artifact do
    # Checked before the token is spent: a primary that cannot serve the agent
    # must not burn the operator's token.
    Agent.artifact()
  end

  defp redeem(conn, body, key, url, artifact) do
    params = body

    case Nodes.redeem_join_token(params["token"], attrs(params), remote_addr_hint: key) do
      {:ok, %{node: node, credential: credential}} ->
        respond_enrolled(conn, node, credential, url, artifact)

      {:error, :invalid_token} ->
        RateLimit.record_failure(:enroll, key)
        error(conn, 401, @unauthorized)

      {:error, :name_taken} ->
        error(conn, 409, "A node with that name already exists")

      {:error, _other} ->
        error(conn, 500, "Enrolment failed")
    end
  end

  # Only well-typed optional fields reach the domain.
  defp attrs(params) do
    %{}
    |> put_if(:name, params["name"], &(is_binary(&1) and &1 != ""))
    |> put_if(
      :labels,
      params["labels"],
      &(is_list(&1) and Enum.all?(&1, fn l -> is_binary(l) end))
    )
    |> put_if(:max_workers, params["max_workers"], &(is_integer(&1) and &1 >= 1))
  end

  defp put_if(map, key, value, valid?),
    do: if(valid?.(value), do: Map.put(map, key, value), else: map)

  defp respond_enrolled(conn, node, credential, url, artifact) do
    body = %{
      node_id: node.id,
      name: node.name,
      credential: credential,
      ws_url: ws_url(url),
      agent_version: artifact.version,
      tarball_sha256: artifact.sha256,
      labels: node.labels,
      max_workers: node.max_workers,
      proto: JoinScript.proto()
    }

    conn = put_resp_header(conn, "cache-control", "no-store")

    if wants_text?(conn) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, kv(body))
    else
      json(conn, body)
    end
  end

  # `KEY=value` lines for the join script, which has no JSON parser. Only the
  # scalar fields it reads, each from a restricted character set.
  defp kv(body) do
    [:node_id, :name, :credential, :ws_url, :agent_version, :tarball_sha256]
    |> Enum.map_join("", fn key -> "#{key}=#{Map.fetch!(body, key)}\n" end)
  end

  defp wants_text?(conn), do: get_req_header(conn, "accept") |> Enum.any?(&(&1 =~ "text/plain"))

  defp ws_url("https://" <> rest), do: "wss://" <> rest <> "/node/socket"
  defp ws_url("http://" <> rest), do: "ws://" <> rest <> "/node/socket"

  # ---- node credential -----------------------------------------------------

  def agent(conn, %{"file" => file}) do
    with {:ok, version} <- version_of(file),
         {:ok, %{version: ^version} = artifact} <- Agent.artifact() do
      send_artifact(conn, artifact)
    else
      _ -> error(conn, 404, "Not found")
    end
  end

  def file(conn, %{"sha" => sha}) do
    case Agent.find_by_sha(sha) do
      {:ok, artifact} -> send_artifact(conn, artifact)
      :error -> error(conn, 404, "Not found")
    end
  end

  defp version_of(file) do
    case String.split_at(file, -7) do
      {version, ".tar.gz"} when version != "" -> {:ok, version}
      _ -> :error
    end
  end

  # `artifact.path` is never request input: `Arbiter.Nodes.Agent` derives it
  # from the deploy data home and the running release's tag (validated against
  # a character set), and `file/2` matches the request's hash against that
  # artifact's own hash. The request chooses nothing about the path.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_artifact(conn, artifact) do
    conn
    |> put_resp_content_type("application/gzip")
    |> put_resp_header("x-content-sha256", artifact.sha256)
    |> put_resp_header("cache-control", "no-store")
    |> send_file(200, artifact.path)
  end

  # ---- shared ---------------------------------------------------------------

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{message: message}})
  end

  # The rate-limit key (design §5.4). Behind `tailscale serve` every peer is
  # loopback, so the caller is the address the proxy appended to
  # `X-Forwarded-For`; from any other peer the header is attacker-chosen and
  # ignored. The same string is the audit `remote_addr_hint`.
  defp source_key(%Plug.Conn{remote_ip: peer} = conn) do
    if Loopback.loopback?(peer) do
      forwarded(conn) || format_ip(peer)
    else
      format_ip(peer)
    end
  end

  defp forwarded(conn) do
    with [header | _] <- get_req_header(conn, "x-forwarded-for"),
         last = header |> String.split(",") |> List.last() |> String.trim(),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(last)) do
      format_ip(ip)
    else
      _ -> nil
    end
  end

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
