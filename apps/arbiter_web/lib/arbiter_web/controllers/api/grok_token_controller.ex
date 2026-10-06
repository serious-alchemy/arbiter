defmodule ArbiterWeb.Api.GrokTokenController do
  @moduledoc """
  The server half of a grok worker's `GROK_AUTH_PROVIDER_COMMAND` (bd-9p4lx9).

    * `POST /api/grok/token` — `{"force"?: true}` →
      `{"access_token", "expires_in"}`

  `arb grok-token` (run by grok itself through the wrapper
  `Arbiter.Grok.AuthProvider` installs) calls this with the worker's own bearer
  token. Each request is logged by the broker with the task (and, for a jailed
  worker, the run) that asked. The answer comes from `Arbiter.Grok.CredentialBroker`, the single
  refresher: the rotating refresh token stays on the server, and the worker only
  ever holds an access token that expires in hours. `force` is grok's
  `GROK_AUTH_EXPIRED=1`.

  Failures are `503`, `Cache-Control: no-store`, and carry the remedy and no
  token: `grok_reauth_required` / `grok_not_logged_in` (the operator has to run
  a grok login; an auth hold is already open) or `grok_unavailable` (the issuer
  is unreachable; retry).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Errors
  alias Arbiter.Grok.CredentialBroker

  action_fallback(ArbiterWeb.Api.FallbackController)

  @relogin "Log in to grok again from the dashboard (the grok provider account's login); " <>
             "with no grok account, run `grok login --device-code` on the Arbiter host."

  def create(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case CredentialBroker.fetch_token(
           force: params["force"] == true,
           task_id: requester_task(conn),
           run_id: requester_run(conn)
         ) do
      {:ok, %{access_token: token, expires_in: expires_in}} ->
        json(conn, %{access_token: token, expires_in: expires_in})

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  # Who asked, for the broker's per-request log line (bd-8rvkqd). A worker
  # token is bound to its task; a jailed worker's bridge also names its run.
  defp requester_task(%{assigns: %{mcp_scope: %{task_id: task_id}}}), do: task_id
  defp requester_task(_conn), do: nil

  defp requester_run(%{assigns: %{worker_bridge: {run_id, _resolution}}}), do: run_id
  defp requester_run(_conn), do: nil

  defp failure(conn, :reauth_required) do
    fail(
      conn,
      "grok_reauth_required",
      "The grok login was refused by x.ai. #{@relogin}"
    )
  end

  defp failure(conn, :not_logged_in) do
    fail(
      conn,
      "grok_not_logged_in",
      "There is no usable grok login. #{@relogin}"
    )
  end

  defp failure(conn, :unavailable) do
    fail(conn, "grok_unavailable", "x.ai could not be reached to refresh the grok token; retry.")
  end

  defp fail(conn, type, message) do
    conn
    |> put_status(Errors.http_status(:busy))
    |> json(Errors.body(:busy, message, %{}, type: type))
  end
end
