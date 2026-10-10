defmodule ArbiterWeb.TaskDetailAdmissionShadowTest do
  @moduledoc """
  The run roster under `scheduler_admission: shadow` (DC6): a run's
  `routing_decision` may carry only the admission shadow's record (routing
  never ran for it), which must not render as an empty routing box. The
  record shows on its own line; a routed run shows both.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ArbiterWeb.TaskDetailLiveHelpers

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.Run

  @shadow %{
    "policy" => "shadow",
    "dispatched" => "bd-x",
    "pick" => "bd-y",
    "pool_label" => "antigravity:default claude-gpt",
    "node" => "local",
    "agrees" => false,
    "comparable" => true,
    "cause" => "capacity:provider",
    "reason" => "waiting for claude:default: 3 of 3 seats",
    "placements" => 1
  }

  setup do
    ws =
      Ash.create!(Workspace, %{
        name: "shadow-ws-#{System.unique_integer([:positive])}",
        prefix: "shw"
      })

    task = Ash.create!(Issue, %{title: "shadowed", workspace_id: ws.id})

    run = fn started_at, decision ->
      Ash.create!(Run, %{
        task_id: task.id,
        repo: "test/repo",
        kind: :implement,
        state: :finished,
        outcome: :succeeded,
        started_at: started_at,
        completed_at: DateTime.add(started_at, 300, :second),
        routing_decision: decision
      })
    end

    unrouted = run.(~U[2026-10-10 09:00:00.000000Z], %{"admission_shadow" => @shadow})

    routed =
      run.(~U[2026-10-10 10:00:00.000000Z], %{
        "outcome" => "selected",
        "role" => "main",
        "account_slug" => "main",
        "provider" => "claude",
        "admission_shadow" =>
          Map.merge(@shadow, %{"agrees" => true, "pick" => "bd-x", "cause" => nil})
      })

    %{task: task, unrouted: unrouted, routed: routed}
  end

  test "a shadow record alone is its own line, with no empty routing box",
       %{conn: conn, task: task, unrouted: unrouted} do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")
    view |> element(~s([phx-value-run="#{unrouted.id}"])) |> render_click()

    refute has_element?(view, "#run-routing-#{unrouted.id}")
    assert has_element?(view, "#run-admission-#{unrouted.id}", "bd-y")
    assert has_element?(view, "#run-admission-#{unrouted.id}", "antigravity:default claude-gpt")
    assert has_element?(view, "#run-admission-#{unrouted.id}", "capacity:provider")
  end

  test "a routed run shows its routing decision and the shadow beside it",
       %{conn: conn, task: task, routed: routed} do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")
    view |> element(~s([phx-value-run="#{routed.id}"])) |> render_click()

    assert has_element?(view, "#run-routing-#{routed.id}", "selected")
    assert has_element?(view, "#run-admission-#{routed.id}", "agrees")
  end
end
