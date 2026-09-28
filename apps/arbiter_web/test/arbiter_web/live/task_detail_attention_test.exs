defmodule ArbiterWeb.TaskDetailAttentionTest do
  @moduledoc """
  bd-8nlez1 (ticket lifecycle 7/13): the task page's attention strip — who
  owns the ticket's attention and the note a hand-off left — and the
  operator's hand-back button.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ArbiterWeb.TaskDetailLiveHelpers

  alias Arbiter.Tasks.{Attention, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ta-#{System.unique_integer([:positive])}", prefix: "tat"})

    {:ok, task} = Ash.create(Issue, %{title: "attention page", workspace_id: ws.id})
    {:ok, task} = Ash.update(task, %{status: :in_progress})
    {:ok, _} = Attention.raise_cause(task.id, :run_crashed, "the run died")

    {:ok, ws: ws, task: task}
  end

  test "a coordinator-owned item shows without a hand-back", %{conn: conn, task: task} do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, ~s(#task-attention[data-owner="coordinator"]))
    assert has_element?(view, "#task-attention-reason", "the run died")
    refute has_element?(view, "#task-attention-handback")
  end

  test "the operator hands a handed-off item back to the coordinator", %{conn: conn, task: task} do
    {:ok, _} = Attention.hand_off(task.id, :operator, "rotate the deploy key")

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, ~s(#task-attention[data-owner="operator"]))
    assert has_element?(view, "#task-attention-note", "rotate the deploy key")

    view |> element("#task-attention-handback") |> render_click()

    issue = Ash.get!(Issue, task.id)
    assert issue.attention_owner == :coordinator
    assert has_element?(view, ~s(#task-attention[data-owner="coordinator"]))
    refute has_element?(view, "#task-attention-handback")
  end

  test "a ticket with no attention has no strip", %{conn: conn, ws: ws} do
    {:ok, quiet} = Ash.create(Issue, %{title: "quiet", workspace_id: ws.id})
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{quiet.id}")

    refute has_element?(view, "#task-attention")
  end
end
