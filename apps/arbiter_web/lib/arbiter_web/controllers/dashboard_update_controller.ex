defmodule ArbiterWeb.DashboardUpdateController do
  @moduledoc """
  The dashboard's "Update to vX.Y.Z" button (bd-6umf7z). It is a plain form POST
  rather than a LiveView event because the update notice lives in the shared
  layout, which renders on dead controller pages (`/about`) as well as every
  LiveView — a form works on all of them.

  Sits behind `ArbiterWeb.Plugs.DashboardAuth`, i.e. a dashboard login — the
  operator's own browser session. A bearer token (coordinator, worker, MCP) is
  not one and is redirected to the login page without reaching this action.

  The tag is never taken from the form: the button deploys the release the update
  check offered, so a forged field cannot choose what runs as the operator.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Release.{SelfDeploy, UpdateCheck}
  alias ArbiterWeb.Api.ReleaseDeployController

  def create(conn, _params) do
    with {:ok, tag} <- SelfDeploy.resolve_tag(nil, UpdateCheck.state()),
         {:ok, _} <- SelfDeploy.start(tag) do
      conn
      |> put_flash(
        :info,
        "Updating to #{tag}: the server will restart when the deploy swaps in. " <>
          "This page shows the outcome once it is back."
      )
      |> redirect(to: ~p"/about")
    else
      {:error, reason} ->
        {_kind, message} = ReleaseDeployController.error(reason)
        conn |> put_flash(:error, message) |> redirect(to: ~p"/about")
    end
  end
end
