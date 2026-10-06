defmodule Arbiter.MCP.AlertToolsTest do
  @moduledoc """
  bd-7gt8rm (ticket lifecycle 8/13) AC4: the MCP `alert_list` tool lists the
  active system alerts.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Alerts
  alias Arbiter.MCP.{Catalog, Scope}

  @coordinator %Scope{tier: :coordinator, workspace_id: nil}

  defp raise_one(kind, key, ws) do
    {:ok, alert} =
      Alerts.raise_alert(%{
        kind: kind,
        key: key,
        workspace_id: ws,
        subject: "s #{key}",
        detail: "d"
      })

    alert
  end

  test "lists every active alert, oldest first, across workspaces" do
    a = raise_one(:credential_expired, "Arbiter.Agents.Claude:usage_poll", "ws-a")
    b = raise_one(:budget_exceeded, "bd-over", "ws-b")
    _ = raise_one(:quota_poll_failing, "anthropic_oauth_usage", "ws-a")
    {:ok, _} = Alerts.clear(:quota_poll_failing, "anthropic_oauth_usage")

    assert {:ok, %{alerts: alerts, count: 2}} = Catalog.call(@coordinator, "alert_list", %{})
    assert Enum.map(alerts, & &1.id) == [a.id, b.id]
    assert [%{kind: "credential_expired", owner: "operator", cleared_at: nil} | _] = alerts
    assert b.id in Enum.map(alerts, & &1.id)
  end

  test "filters by kind; an unknown kind is an error" do
    raise_one(:credential_expired, "k", "ws-a")
    b = raise_one(:overage_alert, "ws-b", "ws-b")

    assert {:ok, %{alerts: [%{id: id}]}} =
             Catalog.call(@coordinator, "alert_list", %{"kind" => "overage_alert"})

    assert id == b.id
    assert {:tool_error, _, _type} = Catalog.call(@coordinator, "alert_list", %{"kind" => "nope"})
  end

  test "is coordinator-only" do
    worker = %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
    assert {:rpc_error, _, _} = Catalog.call(worker, "alert_list", %{})
  end
end
