defmodule ArbiterWeb.Plugs.ApiAuth do
  @moduledoc """
  Token authentication and per-route authorization for the `/api` pipeline.

  Every `/api` request needs an `Authorization: Bearer <token>` (the signed
  MCP scope token the `/mcp` endpoint uses), unless `ArbiterWeb.ApiPolicy`
  classifies its route `:anonymous` (bd-asawcq). Loopback is not an
  identity: every worker runs on this host as the operator's own Unix user,
  so before this a plain `curl` from any of them was coordinator-equivalent
  on every route. Now:

    * no `Authorization` header, from loopback → only `:anonymous` routes
      (`GET /api/version`, `GET /api/server/migrations`); anything else 401.
      `ArbiterWeb.Loopback` owns which addresses count, shared with
      `ArbiterWeb.SessionSocket`;
    * no header, from anywhere else → 401, whatever the route;
    * a header that is present but expired, revoked or malformed → 401, on
      loopback exactly like off it. It is never downgraded to anonymous: a
      session's own `arb` authenticates with its own token (bd-5b5hq7), and a
      revoked one must not quietly turn into a different identity;
    * a valid token whose tier or scope the route's policy refuses → 403
      (`ArbiterWeb.ApiPolicy.authorize/3`).

  Errors use the API error shape: `%{"error" => %{"message" => "..."}}`.

  A request that arrived through a jailed worker's Arbiter bridge
  (`ArbiterWeb.Plugs.WorkerBridge`, bd-c1qq7l) is authenticated as that
  worker's own `:worker` scope, derived from the connection and the run. Any
  `Authorization` header it carries is ignored, and a run with no usable scope
  gets 401: it is never anonymous loopback.

  The decoded `%Scope{}` is assigned to `conn.assigns[:mcp_scope]` (`nil`
  only on an `:anonymous` route reached without a token), so controllers
  can narrow further — `ArbiterWeb.Api.McpController.mint_token/2` caps what
  it mints at the caller's own authority.

  Do NOT trust `X-Forwarded-For` — arbiter binds directly (no reverse proxy)
  so `conn.remote_ip` is always the real peer.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.MCP.Scope
  alias ArbiterWeb.ApiPolicy
  alias ArbiterWeb.Loopback
  alias ArbiterWeb.Plugs.WorkerBridge

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    with {:ok, scope} <- authenticate(conn),
         conn = assign(conn, :mcp_scope, scope),
         :ok <- ApiPolicy.authorize(route_policy(conn), scope, conn.params) do
      conn
    else
      {:error, :unauthenticated, message} -> halt_with(conn, 401, message)
      {:error, :forbidden, message} -> halt_with(conn, 403, message)
    end
  end

  defp authenticate(%Plug.Conn{remote_ip: remote_ip} = conn) do
    case WorkerBridge.identity(conn) do
      {_run_id, {:ok, %Scope{} = scope}} ->
        {:ok, scope}

      {_run_id, {:error, _reason}} ->
        {:error, :unauthenticated, "Worker bridge identity unavailable or expired"}

      nil ->
        authenticate_presented(conn, remote_ip)
    end
  end

  defp authenticate_presented(conn, remote_ip) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Scope.from_token(String.trim(token)) do
          {:ok, scope} -> {:ok, scope}
          {:error, :expired} -> {:error, :unauthenticated, "Bearer token expired"}
          {:error, :revoked} -> {:error, :unauthenticated, "Bearer token revoked (session ended)"}
          {:error, _} -> {:error, :unauthenticated, "Invalid Bearer token"}
        end

      _ ->
        if Loopback.loopback?(remote_ip),
          do: {:ok, nil},
          else: {:error, :unauthenticated, "Authorization: Bearer <token> required"}
    end
  end

  # The pipeline runs after routing, so the matched route's pattern
  # ("/api/issues/:id") is what the policy table is keyed by.
  defp route_policy(%Plug.Conn{} = conn) do
    case Phoenix.Router.route_info(ArbiterWeb.Router, conn.method, conn.path_info, conn.host) do
      %{route: route} -> ApiPolicy.policy(verb(conn.method), route)
      :error -> :unclassified
    end
  end

  @verbs %{"GET" => :get, "POST" => :post, "PUT" => :put, "PATCH" => :patch, "DELETE" => :delete}
  defp verb(method), do: Map.get(@verbs, method, :unknown)

  defp halt_with(conn, status, message) do
    body = Jason.encode!(%{"error" => %{"message" => message}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
