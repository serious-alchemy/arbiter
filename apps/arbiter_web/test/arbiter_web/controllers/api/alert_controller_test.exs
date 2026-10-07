defmodule ArbiterWeb.Api.AlertControllerTest do
  @moduledoc """
  `GET /api/alerts` (bd-7gt8rm, ticket lifecycle 8/13): the active system
  alerts — problems with the installation that are not tied to a ticket.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Alerts

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

  test "lists active alerts, oldest first, without cleared ones", %{conn: conn} do
    a = raise_one(:credential_expired, "Arbiter.Agents.Claude:periodic_probe", "ws-a")
    b = raise_one(:overage_alert, "ws-b", "ws-b")
    _ = raise_one(:quota_poll_failing, "anthropic_oauth_usage", "ws-a")
    {:ok, _} = Alerts.clear(:quota_poll_failing, "anthropic_oauth_usage")

    resp = conn |> get("/api/alerts") |> json_response(200)

    assert resp["count"] == 2
    assert Enum.map(resp["alerts"], & &1["id"]) == [a.id, b.id]

    [first | _] = resp["alerts"]
    assert first["kind"] == "credential_expired"
    assert first["owner"] == "operator"
    assert first["detail"] == "d"
    assert first["cleared_at"] == nil
    assert is_binary(first["raised_at"])
  end

  test "filters by workspace (id or name) and kind, echoing the scope", %{conn: conn} do
    ws_a = Ash.create!(Arbiter.Tasks.Workspace, %{name: "alert-ws-a"})
    ws_b = Ash.create!(Arbiter.Tasks.Workspace, %{name: "alert-ws-b"})
    a = raise_one(:credential_expired, "k1", ws_a.id)
    b = raise_one(:overage_alert, "ws-b", ws_b.id)

    for ref <- [ws_b.name, ws_b.id] do
      assert %{"alerts" => [%{"id" => id_b}], "workspace_id" => ws_id} =
               conn |> get("/api/alerts", %{"workspace" => ref}) |> json_response(200)

      assert id_b == b.id
      assert ws_id == ws_b.id
    end

    assert %{"alerts" => [%{"id" => alias_id}]} =
             conn |> get("/api/alerts", %{"workspace_id" => ws_b.id}) |> json_response(200)

    assert alias_id == b.id

    assert %{"error" => %{"type" => "not_found"}} =
             conn |> get("/api/alerts", %{"workspace" => "nope"}) |> json_response(404)

    assert %{"alerts" => [%{"id" => id_a}]} =
             conn |> get("/api/alerts", %{"kind" => "credential_expired"}) |> json_response(200)

    assert id_a == a.id
  end

  test "an unknown kind is a 400, not an empty list", %{conn: conn} do
    assert conn |> get("/api/alerts", %{"kind" => "not_a_kind"}) |> json_response(400)
  end
end
