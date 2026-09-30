defmodule ArbiterWeb.BoardConcurrencyLiveTest do
  @moduledoc """
  The board toolbar's control for the install-wide scheduler concurrency cap
  (`Arbiter.Settings.conductor_system_max_concurrent/0`).
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @async_timeout 5_000

  alias Arbiter.Board.Autopilot
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Autopilot.resume(Autopilot)

    {:ok, _} = Settings.set_conductor_system_max_concurrent(nil)

    on_exit(fn ->
      Settings.set_conductor_system_max_concurrent(nil)
      Autopilot.pause(Autopilot)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cc-#{System.unique_integer([:positive])}",
        prefix: "cc#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp mount_board(conn) do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    view
  end

  defp submit(view, value) do
    view |> form("#board-concurrency-form", %{"max" => value}) |> render_submit()
    render_async(view, @async_timeout)
  end

  defp slots(view), do: view |> element("#board-slots") |> render()

  test "shows the fallback marked as default when no override is set", %{conn: conn} do
    view = mount_board(conn)

    assert has_element?(view, "#board-concurrency")
    assert has_element?(view, "#board-concurrency[data-override='false']")
    assert render(element(view, "#board-concurrency")) =~ "default"
  end

  test "saving a positive integer persists it and updates the slot total", %{conn: conn} do
    view = mount_board(conn)
    submit(view, "3")

    assert Settings.conductor_system_max_concurrent() == 3
    assert slots(view) =~ "of 3"
    assert has_element?(view, "#board-concurrency[data-override='true']")
  end

  test "a blank value clears the override", %{conn: conn} do
    {:ok, _} = Settings.set_conductor_system_max_concurrent(3)
    view = mount_board(conn)
    assert has_element?(view, "#board-concurrency[data-override='true']")

    submit(view, "")

    assert Settings.conductor_system_max_concurrent() == nil
    assert has_element?(view, "#board-concurrency[data-override='false']")
  end

  for bad <- ["0", "-2", "abc", "2.5"] do
    test "rejects #{inspect(bad)} and writes nothing", %{conn: conn} do
      {:ok, _} = Settings.set_conductor_system_max_concurrent(5)
      view = mount_board(conn)

      html = view |> form("#board-concurrency-form", %{"max" => unquote(bad)}) |> render_submit()

      assert Settings.conductor_system_max_concurrent() == 5
      assert html =~ "whole number"
    end
  end

  test "hints when a workspace cap is the binding limit", %{conn: conn, ws: ws} do
    {:ok, _} =
      Ash.update(ws, %{config: Map.put(ws.config || %{}, "conductor", %{"max_concurrent" => 2})})

    {:ok, _} = Settings.set_conductor_system_max_concurrent(6)
    view = mount_board(conn)

    assert slots(view) =~ "of 2"
    assert has_element?(view, "#board-concurrency-limited")
    assert render(element(view, "#board-concurrency-limited")) =~ "limited to 2"
  end

  test "no hint when the system cap is the binding limit", %{conn: conn} do
    {:ok, _} = Settings.set_conductor_system_max_concurrent(3)
    view = mount_board(conn)
    refute has_element?(view, "#board-concurrency-limited")
  end

  test "the control's text never says conductor", %{conn: conn, ws: ws} do
    {:ok, _} =
      Ash.update(ws, %{config: Map.put(ws.config || %{}, "conductor", %{"max_concurrent" => 2})})

    {:ok, _} = Settings.set_conductor_system_max_concurrent(6)
    view = mount_board(conn)
    html = view |> element("#board-concurrency") |> render()
    refute String.downcase(html) =~ "conductor"
  end
end
