defmodule ArbiterWeb.Plugs.DashboardAuth do
  @moduledoc """
  Gate for the `:browser` pipeline (bd-3gycsz). Delegates the decision to the
  configured `ArbiterWeb.DashboardAuth` implementation and redirects the
  browser to its login page when it says no. Must run after `fetch_session`.

  The login routes themselves sit in a pipeline without this plug.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case ArbiterWeb.DashboardAuth.authenticate(conn) do
      {:ok, conn, identity} ->
        assign(conn, :dashboard_identity, identity)

      :error ->
        conn
        |> Phoenix.Controller.redirect(to: ArbiterWeb.DashboardAuth.login_path())
        |> halt()
    end
  end
end
