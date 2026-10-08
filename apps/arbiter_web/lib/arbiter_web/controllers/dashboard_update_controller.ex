defmodule ArbiterWeb.DashboardUpdateController do
  @moduledoc """
  The dashboard's "Update to vX.Y.Z" button (bd-6umf7z). It is a plain form POST
  rather than a LiveView event because the update notice lives in the shared
  layout, which renders on dead controller pages (`/about`) as well as every
  LiveView — a form works on all of them.

  Sits behind `ArbiterWeb.Plugs.DashboardAuth`, i.e. a dashboard login — the
  operator's own browser session. A bearer token (coordinator, worker, MCP) is
  not one and is redirected to the login page without reaching this action.

  It redirects to the board, a LiveView: the deploy restarts the server, and only a
  LiveView page reconnects and re-reads the deploy record when the server is back.
  A dead page would keep showing the banner as it was when it rendered.

  The tag is never taken from the form: the button deploys the release the update
  check offered, so a forged field cannot choose what runs as the operator.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Release.{SelfDeploy, UpdateCheck}
  alias Arbiter.Settings
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
      |> redirect(to: ~p"/")
    else
      {:error, reason} ->
        {_kind, message} = ReleaseDeployController.error(reason)
        conn |> put_flash(:error, message) |> redirect(to: ~p"/")
    end
  end

  @doc """
  The banner's × control: remember the version the update check currently
  offers, so the banner stays hidden until a newer one appears. Cosmetic only;
  the update check, `/api/version` and the deploy action are untouched. The
  version comes from the update check, never the form.
  """
  def dismiss(conn, _params) do
    case UpdateCheck.state() do
      %{update_available?: true, latest: latest} when is_binary(latest) ->
        Settings.set_dismissed_update_version(latest)

      _ ->
        :ok
    end

    redirect(conn, to: ~p"/")
  end
end
