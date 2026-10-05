defmodule ArbiterWeb.Api.GrokTokenController do
  @moduledoc """
  The server half of a grok worker's `GROK_AUTH_PROVIDER_COMMAND` (bd-9p4lx9).

    * `POST /api/grok/token` — `{"force"?: true}` →
      `{"access_token", "expires_in"}`

  `arb grok-token` (run by grok itself through the wrapper
  `Arbiter.Grok.AuthProvider` installs) calls this with the worker's own bearer
  token. The answer comes from `Arbiter.Grok.CredentialBroker`, the single
  refresher: the rotating refresh token stays on the server, and the worker only
  ever holds an access token that expires in hours. `force` is grok's
  `GROK_AUTH_EXPIRED=1`.

  Failures are `503`, `Cache-Control: no-store`, and carry the remedy and no
  token: `grok_reauth_required` / `grok_not_logged_in` (the operator has to run
  `grok login`; an auth hold is already open) or `grok_unavailable` (the issuer
  is unreachable; retry).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Grok.CredentialBroker

  def create(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case CredentialBroker.fetch_token(force: params["force"] == true) do
      {:ok, %{access_token: token, expires_in: expires_in}} ->
        json(conn, %{access_token: token, expires_in: expires_in})

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  defp failure(conn, :reauth_required) do
    fail(
      conn,
      "grok_reauth_required",
      "The grok login was refused by x.ai. Run `grok login --device-code` on the Arbiter host."
    )
  end

  defp failure(conn, :not_logged_in) do
    fail(
      conn,
      "grok_not_logged_in",
      "There is no usable grok login. Run `grok login --device-code` on the Arbiter host."
    )
  end

  defp failure(conn, :unavailable) do
    fail(conn, "grok_unavailable", "x.ai could not be reached to refresh the grok token; retry.")
  end

  defp fail(conn, type, message) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: %{type: type, message: message, details: %{}}})
  end
end
