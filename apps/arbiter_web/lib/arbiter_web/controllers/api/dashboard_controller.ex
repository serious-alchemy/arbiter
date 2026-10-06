defmodule ArbiterWeb.Api.DashboardController do
  @moduledoc """
  `POST /api/dashboard/login_tokens` (bd-3gycsz) — mint a one-time dashboard
  login token for `arb dashboard login`. Operator-proof tier (`ArbiterWeb.ApiPolicy`
  `:operator`, P-28): a dashboard login is an operator grant, so a coordinator
  session's own token is refused; `arb dashboard login` mints its proof over the
  operator socket. See `docs/design/tier-proof-boundaries.md`.
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
