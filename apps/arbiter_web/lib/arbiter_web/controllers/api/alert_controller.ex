defmodule ArbiterWeb.Api.AlertController do
  @moduledoc """
  REST endpoint for system alerts (bd-7gt8rm, ticket lifecycle 8/13) —
  problems with the installation that are not tied to a ticket (credentials,
  the quota poll, overage and budget), each clearing when its condition does.

  Routes:

    * `GET /api/alerts` — the active alerts, oldest first (`?workspace=` — id or name,
      `workspace_id` accepted as an alias — `?kind=`)
  """

  use ArbiterWeb, :controller

  alias Arbiter.Alerts
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc "The active system alerts."
  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      case Alerts.parse_kind(params["kind"]) do
        {:ok, kind} ->
          alerts = Alerts.active(workspace_id: ws_id, kind: kind)

          json(conn, %{
            alerts: Enum.map(alerts, &Alerts.serialize/1),
            count: length(alerts),
            workspace_id: ws_id
          })

        :error ->
          {:error,
           {:invalid_request,
            "unknown alert kind #{inspect(params["kind"])} — one of " <>
              Enum.map_join(Arbiter.Alerts.SystemAlert.kinds(), ", ", &Atom.to_string/1)}}
      end
    end
  end
end
