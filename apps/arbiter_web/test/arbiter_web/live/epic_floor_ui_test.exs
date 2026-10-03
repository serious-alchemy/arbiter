defmodule ArbiterWeb.EpicFloorUiTest do
  @moduledoc """
  ES5 (bd-5xxkpv, `docs/design/epic-aware-scheduling.md` §6.3): the board card's
  `P1↑` badge, the parent chip's `· floor P1` suffix, the capped wording, the
  task page's "scheduled as" line and the epic mini-board header.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Dependencies, Issue, Workspace}

  @async_timeout 5_000

  setup do
    on_exit(fn -> Arbiter.Settings.set_scheduling_max_lifted_in_flight(nil) end)
    {:ok, 1} = Arbiter.Settings.set_scheduling_max_lifted_in_flight(1)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "es5-#{System.unique_integer([:positive])}", prefix: "es5"})

    {:ok, epic} =
      Ash.create(Issue, %{title: "Add reports", workspace_id: ws.id, issue_type: :epic})

    {:ok, ws: ws, epic: epic}
  end

  defp floor!(epic, floor) do
    {:ok, epic} = Ash.update(epic, %{floor_priority: floor}, action: :set_floor)
    epic
  end

  defp ready(ws, epic, priority) do
    {:ok, created} =
      Ash.create(Issue, %{
        title: "child-#{System.unique_integer([:positive])}",
        workspace_id: ws.id,
        priority: priority,
        acceptance: "- ok"
      })

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    {:ok, _} = Dependencies.add(epic.id, issue.id, :parent_of)
    issue
  end

  defp start!(issue) do
    {:ok, issue} = Ash.update(issue, %{}, action: :start)
    issue
  end

  defp live_board(conn) do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    view
  end

  defp live_task(conn, id) do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{id}")
    render_async(view, @async_timeout)
    view
  end

  defp attr(view, selector, name) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  test "no floor: the card badge, chip and task page are the plain ones", %{
    conn: conn,
    ws: ws,
    epic: epic
  } do
    child = ready(ws, epic, 3)
    view = live_board(conn)

    assert has_element?(view, "##{child.id}-priority", "P3")
    refute has_element?(view, "##{child.id}-priority[data-lift]")
    refute has_element?(view, "##{child.id}-priority[title]")
    refute has_element?(view, "[data-role=parent-floor]")

    task = live_task(conn, child.id)
    refute has_element?(task, "#task-scheduled-as")
    refute has_element?(task, "#task-priority[data-lift]")

    refute has_element?(live_task(conn, epic.id), "#children-floor-header")
  end

  test "a lifted card shows P1↑ with title and aria-label, and the chip says the floor", %{
    conn: conn,
    ws: ws,
    epic: epic
  } do
    floor!(epic, 1)
    child = ready(ws, epic, 3)
    view = live_board(conn)
    badge = "##{child.id}-priority"

    assert has_element?(view, badge <> "[data-lift=applied]", "P1↑")
    expected = "P1 via #{epic.id} — own priority P3"
    assert attr(view, badge, "title") == expected
    assert attr(view, badge, "aria-label") == expected
    assert has_element?(view, "[data-role=parent-chip] [data-role=parent-floor]", "floor P1")
  end

  test "a capped lift keeps the own priority and says what is waiting", %{
    conn: conn,
    ws: ws,
    epic: epic
  } do
    floor!(epic, 1)
    _running = epic |> ready_child(ws, 3) |> start!()
    waiting = ready(ws, epic, 3)
    view = live_board(conn)
    badge = "##{waiting.id}-priority"

    assert has_element?(view, badge <> "[data-lift=capped]", "P3")
    refute has_element?(view, badge, "↑")

    assert attr(view, badge, "title") ==
             "floor P1 via #{epic.id} waiting — 1 of 1 lifted slots in progress"

    refute has_element?(view, "[data-card=#{waiting.id}] [data-role=parent-floor]")
  end

  test "the task page reads scheduled as, and the epic mini-board header shows the floor", %{
    conn: conn,
    ws: ws,
    epic: epic
  } do
    floor!(epic, 1)
    child = ready(ws, epic, 3)

    task = live_task(conn, child.id)
    assert has_element?(task, "#task-priority[data-lift=applied]", "P1")
    assert has_element?(task, "#task-scheduled-as", "P1 via #{epic.id}")
    assert has_element?(task, "#task-scheduled-as", "Add reports")

    header = live_task(conn, epic.id)
    assert has_element?(header, "#children-floor-header", "floor P1 · 1 lifted, 0 in progress")
  end

  defp ready_child(epic, ws, priority), do: ready(ws, epic, priority)
end
