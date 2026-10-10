defmodule ArbiterWeb.NodeController do
  @moduledoc """
  The node join flow's HTTP surface (`docs/design/remote-workers.md` §5.2,
  §5.4–§5.5, §6), under `/nodes/*`, outside `/api` and `/mcp`.

  Anonymous (no node credential exists yet, or none is needed):

    * `GET /nodes/join` — the join script, rendered from `nodes.public_url`.
    * `GET /nodes/ping` — `pong`, so the script can check reachability before
      it spends a token.
    * `GET /nodes/join/k8s.yaml` — the cluster install manifests (K9,
      `Arbiter.NodeAgent.K8s.InstallManifest`), rendered from the query string. They
      contain no secret, so the route is anonymous like the script.
    * `POST /nodes/enroll` — a join token **in the JSON body** (never a header
      or the query string) for a node credential. Rate limited
      (`Arbiter.Nodes.RateLimit`); every token failure is the same generic
      `401`.
    * `GET /join` — the same script on a short, stable path.
    * `POST /nodes/pair` and `POST /nodes/pair/poll` — device-code pairing
      (`Arbiter.Nodes.Pairing`, design §5.7): the node asks for a short code to
      show the operator, then polls with its poll secret **in the JSON body**
      until the operator has approved it on the primary. Rate limited per
      source. An unapproved, denied, expired or redeemed request never yields a
      credential.

  Behind `ArbiterWeb.Plugs.NodeAuth` (a node credential, nothing else):

    * `GET /nodes/agent/<version>.tar.gz` — the agent build the primary runs
      (`Arbiter.Nodes.Agent`), only for the version the enroll response named.
    * `GET /nodes/files/<sha256>` — the same bytes addressed by content hash.
  """

  use ArbiterWeb, :controller

  alias Arbiter.NodeAgent.K8s.InstallManifest
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Agent, ClusterInstall, Credentials, JoinScript, Pairing, RateLimit}
  alias Arbiter.Settings
  alias ArbiterWeb.Loopback

  @unauthorized "Invalid or expired join token"
  @bad_name "The node name may only contain A-Za-z0-9._=:/@- (1-128 characters)"
  @poll_interval 3
  @pair_retry_after 60

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

  # K9: `kubectl apply -f <(curl -fsSL "<public_url>/nodes/join/k8s.yaml?name=...")`. There
  # is no token, credential or key anywhere in the render, and no parameter that would put
  # one there: an offered `?token=` is ignored, not echoed.
  def k8s(conn, params) do
    with {:ok, spec} <- parse_manifest(params),
         {:ok, server} <- ClusterInstall.server_opts(),
         {:ok, yaml} <- InstallManifest.yaml(spec, server) do
      conn
      |> put_resp_content_type("application/yaml")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, yaml)
    else
      {:error, {:invalid, errors}} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(422, Enum.map_join(errors, "", &(&1 <> "\n")))

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, manifest_unavailable(reason))
    end
  end

  defp parse_manifest(params) do
    case InstallManifest.parse(params) do
      {:ok, spec} -> {:ok, spec}
      {:error, errors} -> {:error, {:invalid, errors}}
    end
  end

  defp manifest_unavailable(:no_public_url),
    do: "nodes.public_url is not set on the primary; set it first\n"

  defp manifest_unavailable(:no_registry),
    do: "nodes.registry is not set on the primary; a cluster node needs an image it can pull\n"

  defp manifest_unavailable(_reason),
    do: "The primary has no deployed release to name a controller image for\n"

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
         {:ok, artifact} <- agent_artifact(body["kind"]) do
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

  # A cluster controller is an image, not a tarball: it upgrades by image (K§2.4) and
  # never downloads the agent, so the primary need not be able to serve one.
  defp agent_artifact("cluster"), do: {:ok, nil}

  defp agent_artifact(_kind) do
    # Checked before the token is spent: a primary that cannot serve the agent
    # must not burn the operator's token.
    Agent.artifact()
  end

  defp agent_artifact, do: agent_artifact(nil)

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

      {:error, :invalid_name} ->
        error(conn, 422, @bad_name)

      {:error, :kind_mismatch} ->
        error(conn, 422, "This join token is for a different kind of node than the kind sent")
    end
  end

  # ---- pairing ---------------------------------------------------------------

  def pair(conn, _params) do
    key = source_key(conn)
    body = body_params(conn)

    with :ok <- RateLimit.check(:pair, key),
         {:ok, _url} <- public_url(),
         {:ok, _artifact} <- agent_artifact(),
         {:ok, %{request: req, secret: secret}} <- Pairing.request(pair_attrs(body), peer: key) do
      respond_paired(conn, req, secret)
    else
      {:error, {:rate_limited, seconds}} -> too_many(conn, seconds)
      {:error, :too_many_pending} -> too_many(conn, @pair_retry_after)
      {:error, :unconfigured} -> error(conn, 503, "nodes.public_url is not set on the primary")
      {:error, :unavailable} -> error(conn, 503, "The primary cannot take a pairing request now")
      {:error, :invalid_name} -> error(conn, 422, @bad_name)
    end
  end

  defp too_many(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> error(429, "Too many pairing requests")
  end

  defp pair_attrs(params), do: put_if(attrs(params), :hostname, params["hostname"], &is_binary/1)

  defp respond_paired(conn, req, secret) do
    body = %{
      id: req.id,
      code: Credentials.format_pairing_code(req.code),
      secret: secret,
      expires_in: Pairing.ttl_seconds(),
      interval: @poll_interval
    }

    conn = put_resp_header(conn, "cache-control", "no-store")

    if wants_text?(conn) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(201, kv(body, [:id, :code, :secret, :expires_in, :interval]))
    else
      conn |> put_status(201) |> json(body)
    end
  end

  def poll(conn, _params) do
    key = source_key(conn)
    body = body_params(conn)

    with :ok <- RateLimit.check(:pair_poll, key),
         {:ok, url} <- public_url(),
         {:ok, artifact} <- agent_artifact() do
      case Pairing.redeem(body["id"], body["secret"], remote_addr_hint: key) do
        {:ok, %{node: node, credential: credential}} ->
          respond_enrolled(conn, node, credential, url, artifact)

        {:pending, _req} ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_status(202)
          |> json(%{state: "pending"})

        {:error, :denied} ->
          error(conn, 403, "The operator denied this pairing request")

        {:error, :expired} ->
          error(conn, 410, "This pairing request expired; start again")

        {:error, :name_taken} ->
          error(conn, 409, "A node with that name already exists; the operator must rename it")

        {:error, :invalid} ->
          RateLimit.record_failure(:pair_poll, key)
          error(conn, 401, "Invalid pairing request")
      end
    else
      {:error, {:rate_limited, seconds}} -> too_many(conn, seconds)
      {:error, :unconfigured} -> error(conn, 503, "nodes.public_url is not set on the primary")
      {:error, :unavailable} -> error(conn, 503, "The primary has no agent build to serve")
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
    |> put_if(:kind, params["kind"], &is_binary/1)
    |> put_if(:k8s_version, params["k8s_version"], &is_binary/1)
    |> put_if(:agent_version, params["agent_version"], &is_binary/1)
  end

  defp put_if(map, key, value, valid?),
    do: if(valid?.(value), do: Map.put(map, key, value), else: map)

  defp respond_enrolled(conn, node, credential, url, artifact) do
    body =
      put_artifact(
        %{
          node_id: node.id,
          name: node.name,
          kind: node.kind,
          credential: credential,
          ws_url: ws_url(url),
          labels: node.labels,
          max_workers: node.max_workers,
          proto: JoinScript.proto()
        },
        artifact
      )

    conn = put_resp_header(conn, "cache-control", "no-store")

    if wants_text?(conn) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, kv(body))
    else
      json(conn, body)
    end
  end

  # A cluster node has no tarball (it upgrades by image); say which release the primary is.
  defp put_artifact(body, nil), do: Map.put(body, :agent_version, Agent.release_tag())

  defp put_artifact(body, artifact),
    do: Map.merge(body, %{agent_version: artifact.version, tarball_sha256: artifact.sha256})

  # `KEY=value` lines for the join script, which has no JSON parser. Only the
  # scalar fields it reads, each from a restricted character set.
  @enrolled_keys [:node_id, :name, :credential, :ws_url, :agent_version, :tarball_sha256]

  defp kv(body, keys \\ @enrolled_keys),
    do: Enum.map_join(keys, "", fn key -> "#{key}=#{Map.fetch!(body, key)}\n" end)

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
      :error -> send_shelved(conn, sha)
    end
  end

  # A file the primary published for a run (`Arbiter.Nodes.Files`: the provider
  # CLI and `arb`). The path comes from the primary's own shelf; the request
  # contributes only a hash that must already be on it.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_shelved(conn, sha) do
    case Arbiter.Nodes.Files.lookup(sha) do
      {:ok, path} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("x-content-sha256", sha)
        |> put_resp_header("cache-control", "no-store")
        |> send_file(200, path)

      :error ->
        error(conn, 404, "Not found")
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
