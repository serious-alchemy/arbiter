defmodule ArbiterWeb.DashboardWithoutApiTokenTest do
  @moduledoc """
  bd-asawcq: `/api` now refuses a caller with no bearer token, on loopback
  too. The browser dashboard is not behind `:api` — it is the `:browser`
  pipeline plus the LiveView socket, and it calls the domain in-process — so
  it must keep working with no `Authorization` header anywhere: it renders,
  its LiveView connects, and an operator action on it (a drag that promotes a
  ticket) still writes.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    Autopilot.resume(Autopilot)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "dash-#{System.unique_integer([:positive])}", prefix: "bd"})

    {:ok, task} =
      Ash.create(Issue, %{title: "promote me", workspace_id: ws.id, acceptance: "- fixture"})

    # No ConnCase default bearer token: a browser never sends one. It does
    # carry the dashboard login (bd-3gycsz), which is not a bearer token.
    conn = dashboard_login(%{Phoenix.ConnTest.build_conn() | remote_ip: {127, 0, 0, 1}})
    {:ok, conn: conn, task: task}
  end

  test "the board renders, connects and acts with no bearer token", %{conn: conn, task: task} do
    assert Plug.Conn.get_req_header(conn, "authorization") == []

    assert conn |> get("/") |> html_response(200)

    {:ok, view, _html} = live(conn, "/")
    render_async_settled(view)
    assert has_element?(view, ~s(#board-column-backlog [id="card-#{task.id}"]))

    render_hook(view, "drag", %{"id" => task.id, "from" => "backlog", "to" => "ready"})
    render_async_settled(view)

    assert Ash.get!(Issue, task.id).state == :queued
    assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
  end

  test "the same ticket over /api, with no token, is refused", %{conn: conn, task: task} do
    assert conn |> get("/api/issues/#{task.id}") |> json_response(401)
  end
end
