defmodule ArbiterWeb.Api.AlertController do
  @moduledoc """
  REST endpoint for system alerts (bd-7gt8rm, ticket lifecycle 8/13) —
  problems with the installation that are not tied to a ticket (credentials,
  the quota poll, overage and budget), each clearing when its condition does.

  Routes:

    * `GET /api/alerts` — the active alerts, oldest first (`?workspace=`,
      `?kind=`)
  """

  use ArbiterWeb, :controller

  alias Arbiter.Alerts

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc "The active system alerts."
  def index(conn, params) do
    case Alerts.parse_kind(params["kind"]) do
      {:ok, kind} ->
        alerts = Alerts.active(workspace_id: blank_to_nil(params["workspace"]), kind: kind)
        json(conn, %{alerts: Enum.map(alerts, &Alerts.serialize/1), count: length(alerts)})

      :error ->
        {:error,
         {:invalid_request,
          "unknown alert kind #{inspect(params["kind"])} — one of " <>
            Enum.map_join(Arbiter.Alerts.SystemAlert.kinds(), ", ", &Atom.to_string/1)}}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_), do: nil
end
