defmodule ArbiterWeb.Api.McpController do
  @moduledoc """
  API endpoints for minting and verifying MCP scope tokens.

  Routes:

    * `POST /api/mcp/tokens`        — :mint_token   Mint a coordinator scope token (bearer callers only)
    * `POST /api/mcp/tokens/verify` — :verify_token Decode + verify a scope token

  `arb mcp token verify` uses the verify route. `arb mcp token mint` uses the
  mint route only when it already holds a token (`ARB_TOKEN`, or a session's
  own). Otherwise it goes through `Arbiter.MCP.OperatorSocket`.
  """

  use ArbiterWeb, :controller

  alias Arbiter.MCP
  alias Arbiter.MCP.{OperatorSocket, Scope}

  action_fallback ArbiterWeb.Api.FallbackController

  @doc """
  Mint a coordinator-tier scope token.

  Coordinator tokens are **workspace-agnostic** by default: a single token is
  valid for any workspace on the installation, and coordinator API endpoints /
  MCP tools resolve the target workspace per call (explicit `workspace` param
  → referenced entity → installation default).

  Body parameters:
    - `ttl` (optional) — token lifetime in seconds, default 30 days
    - `workspace_id` (optional) — bind the minted token to one workspace
    - `can_dispatch` (optional, default `true`) — whether the minted token may
      dispatch. Ignored (forced to `false`) when it would exceed the caller.

  ## No anonymous minting (bd-8381tk)

  An anonymous call (no `Authorization` header) is refused, whatever it asks
  for: `ArbiterWeb.Plugs.ApiAuth` answers 401 before it gets here
  (bd-asawcq), and the 403 below stays as a second line.
  Loopback only proves "same host", and every worker runs on this host as
  the operator's Unix user, so it cannot tell the operator from a worker.
  An unauthenticated caller gets no tier at all. The operator mints
  over `Arbiter.MCP.OperatorSocket` (`arb mcp token mint`, `arb init`), which
  checks the peer's credentials and refuses any process Arbiter spawned. See
  docs/worker-security.md, "Operator proof for token minting".

  ## Caller-inheritance guardrail (bd-5b5hq7)

  A call that presents a bearer token (`conn.assigns[:mcp_scope]`, set by
  `ApiAuth` whenever one was given, loopback or not) can only mint a token
  **no more powerful than itself**:

    * the minted token inherits the caller's `session_id`, if any — so ending
      that session revokes the new token too, closing the escalation path
      where a browser session's limited, revocable token is traded for an
      unrestricted one via this same endpoint;
    * the minted token's `workspace_id` is the caller's if the caller is
      workspace-bound (a bound caller cannot mint an unbound or
      differently-bound token); an unbound caller may still narrow via the
      `workspace_id` param;
    * `can_dispatch` is `requested and caller.can_dispatch` — never more
      permissive than the caller.

  A `:worker`-tier caller is refused outright (403): workers have no business
  minting new tokens at all. So is a `:refine`-tier caller (bd-3uy2hn) — this
  endpoint only mints coordinator tokens, so for a refine caller every possible
  result is a widening.
  """
  def mint_token(conn, params) do
    ttl = OperatorSocket.parse_ttl(Map.get(params, "ttl"))

    case conn.assigns[:mcp_scope] do
      # bd-8381tk: loopback is not an identity. Every worker shares this host
      # and Unix user, so an anonymous loopback caller could be any of them.
      # No tier is safe to hand out here (the only tier this endpoint mints is
      # coordinator); the operator proves who they are over the peer-checked
      # operator socket instead (`Arbiter.MCP.OperatorSocket`).
      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          "error" => %{
            "message" =>
              "anonymous token minting is disabled: run `arb mcp token mint` on the " <>
                "server host (it proves operator identity over the local operator " <>
                "socket), or present an existing coordinator token as Authorization: Bearer"
          }
        })

      %Scope{tier: :worker} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          "error" => %{"message" => "a worker-tier token cannot mint new tokens"}
        })

      # bd-3uy2hn: the same rule, for the same reason. This endpoint caps what it
      # mints at the caller's own authority, but it can only mint `:coordinator`
      # tokens — so for a refine caller "capped" would still mean *wider*: a
      # coordinator token can close tasks and write config anywhere in the
      # workspace, none of which a refine session may do. There is nothing safe to
      # hand back, so it hands back nothing.
      %Scope{tier: :refine} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          "error" => %{
            "message" =>
              "a refine-tier token cannot mint new tokens — it would widen, not narrow, its scope"
          }
        })

      %Scope{} = caller ->
        workspace_id =
          narrow_workspace(caller.workspace_id, nilable_param(params, "workspace_id"))

        can_dispatch = narrow_can_dispatch(caller.can_dispatch, Map.get(params, "can_dispatch"))

        token =
          if caller.session_id do
            Scope.mint_session(caller.session_id,
              workspace_id: workspace_id,
              can_dispatch: can_dispatch,
              max_age: ttl
            )
          else
            Scope.mint_coordinator(workspace_id, can_dispatch: can_dispatch, max_age: ttl)
          end

        respond_token(conn, token, ttl)
    end
  end

  defp respond_token(conn, token, ttl) do
    {:ok, scope} = Scope.from_token(token)

    json(conn, %{
      "token" => token,
      "tier" => "coordinator",
      "workspace_id" => scope.workspace_id,
      "expires_in" => ttl,
      "server_url" => MCP.server_url()
    })
  end

  # A bound caller cannot mint an unbound (or differently-bound) token — the
  # caller's binding is the ceiling. An unbound caller may still narrow.
  defp narrow_workspace(nil, requested), do: requested
  defp narrow_workspace(caller_ws, _requested), do: caller_ws

  defp narrow_can_dispatch(caller_can_dispatch, requested) do
    requested_bool =
      case requested do
        b when b in [false, "false"] -> false
        b when b in [true, "true"] -> true
        nil -> true
        _ -> true
      end

    caller_can_dispatch and requested_bool
  end

  defp nilable_param(params, key) do
    case Map.get(params, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  @doc """
  Verify a scope token and return its decoded claims.

  Body parameters:
    - `token` (required) — the signed scope token to verify

  Returns `{"valid": true, ...claims}` or `{"valid": false, "reason": "..."}`.
  """
  def verify_token(conn, %{"token" => token}) when is_binary(token) and token != "" do
    case Scope.from_token(token) do
      {:ok, scope} ->
        json(conn, %{
          "valid" => true,
          "tier" => to_string(scope.tier),
          "workspace_id" => scope.workspace_id,
          "task_id" => scope.task_id,
          "repo" => scope.repo,
          "session_id" => scope.session_id,
          "can_dispatch" => scope.can_dispatch,
          "depth" => scope.depth
        })

      {:error, reason} when reason in [:expired, :revoked] ->
        conn
        |> put_status(:ok)
        |> json(%{"valid" => false, "reason" => to_string(reason)})

      {:error, _} ->
        conn
        |> put_status(:ok)
        |> json(%{"valid" => false, "reason" => "invalid"})
    end
  end

  def verify_token(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => %{"message" => "token is required"}})
  end
end
