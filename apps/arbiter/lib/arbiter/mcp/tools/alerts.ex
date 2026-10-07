defmodule Arbiter.MCP.Tools.Alerts do
  @moduledoc """
  `Arbiter.MCP.Tools` handler for system alerts (bd-7gt8rm, ticket lifecycle
  8/13): `alert_list`.

  A system alert is a problem with the installation rather than a ticket — an
  expired credential, the quota poll failing, overage spend or a task's worker
  spend past its threshold — and clears by itself when its condition does
  (`Arbiter.Alerts`). Read-only and coordinator-only, like `breaker_list`.
  """

  alias Arbiter.Alerts
  alias Arbiter.Alerts.SystemAlert
  alias Arbiter.MCP.Scope

  @doc """
  The active system alerts, oldest first. Optional `workspace` and `kind`.
  Coordinator only.
  """
  @spec alert_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def alert_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Arbiter.MCP.Tools.authorized_workspace(scope, args),
         {:ok, kind} <- kind_arg(args) do
      alerts = Alerts.active(workspace_id: ws_id, kind: kind)

      {:ok,
       %{
         alerts: Enum.map(alerts, &Alerts.serialize/1),
         count: length(alerts),
         workspace_id: ws_id
       }}
    end
  end

  defp kind_arg(args) do
    case Alerts.parse_kind(Map.get(args, "kind")) do
      {:ok, kind} ->
        {:ok, kind}

      :error ->
        {:error,
         {:invalid,
          "unknown alert kind #{inspect(Map.get(args, "kind"))} — one of " <>
            Enum.map_join(SystemAlert.kinds(), ", ", &Atom.to_string/1)}}
    end
  end
end
