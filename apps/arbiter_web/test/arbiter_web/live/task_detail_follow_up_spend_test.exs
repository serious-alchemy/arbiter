defmodule ArbiterWeb.TaskDetailFollowUpSpendTest do
  @moduledoc "The task page rolls follow-up spend up into the ticket it fixes."

  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ArbiterWeb.TaskDetailLiveHelpers

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "fus-#{System.unique_integer([:positive])}", prefix: "fus"})

    {:ok, ws: ws}
  end

  defp task!(ws, title), do: Ash.create!(Issue, %{title: title, workspace_id: ws.id})

  defp spend!(task, ws, cost) do
    Ash.create!(Event, %{
      task_id: task.id,
      base_task_id: task.id,
      source: :task,
      step: :work,
      role: "base",
      workspace_id: ws.id,
      occurred_at: ~U[2026-09-15 12:00:00.000000Z],
      cost_usd: cost
    })
  end

  test "shows own + follow-ups = total and lists each follow-up with its spend",
       %{conn: conn, ws: ws} do
    orig = task!(ws, "original")
    fix = task!(ws, "the fix")
    ci = task!(ws, "ci fix")
    spend!(orig, ws, 3.0)
    spend!(fix, ws, 2.0)
    spend!(ci, ws, 0.5)
    {:ok, _} = Dependencies.add(fix.id, orig.id, :fixes)
    {:ok, _} = Dependencies.add(ci.id, fix.id, :discovered_from)

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{orig.id}")

    rollup = view |> element("#task-spend-rollup") |> render()
    assert rollup =~ "$3.00 own"
    assert rollup =~ "$2.50 follow-ups"
    assert rollup =~ "$5.50"

    assert view |> element("#task-follow-up-#{fix.id}") |> render() =~ "$2.00"
    assert view |> element("#task-follow-up-#{ci.id}") |> render() =~ "$0.50"
  end

  test "no follow-ups: no rollup block", %{conn: conn, ws: ws} do
    orig = task!(ws, "alone")
    spend!(orig, ws, 1.0)

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{orig.id}")
    refute has_element?(view, "#task-spend-rollup")
  end
end
