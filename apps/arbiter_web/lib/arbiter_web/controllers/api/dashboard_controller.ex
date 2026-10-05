defmodule ArbiterWeb.Api.DashboardController do
  @moduledoc """
  `POST /api/dashboard/login_tokens` (bd-3gycsz) — mint a one-time dashboard
  login token for `arb dashboard login`. Coordinator tier (`ArbiterWeb.ApiPolicy`):
  holding one is what proves operator identity.
  """
  use ArbiterWeb, :controller

  alias ArbiterWeb.DashboardAuth.LoginTokens

  def login_token(conn, _params) do
    token = LoginTokens.mint()

    json(conn, %{
      token: token,
      path: "/login?token=" <> token,
      expires_in: LoginTokens.ttl_seconds()
    })
  end
end
