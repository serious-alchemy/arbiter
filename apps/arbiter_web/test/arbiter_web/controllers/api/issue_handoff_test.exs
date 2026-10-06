defmodule ArbiterWeb.Api.IssueHandoffTest do
  @moduledoc """
  bd-8nlez1: `POST /api/issues/:id/handoff` and `/handback` — the REST side
  of the coordinator's hand-off and the operator's hand-back
  (`arb ticket handoff` / `arb ticket handback`).
  """
  use ArbiterWeb.ConnCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Tasks.{Attention, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ho-#{System.unique_integer([:positive])}", prefix: "hot"})

    {:ok, task} = Ash.create(Issue, %{title: "hand me off", workspace_id: ws.id})
    task = put_state!(task, :active)
    {:ok, _} = Attention.raise_cause(task.id, :run_crashed, "boom")

    {:ok, conn: put_req_header(conn, "accept", "application/json"), task: task}
  end

  test "handoff moves the attention to the operator with the note", %{conn: conn, task: task} do
    conn = post(conn, ~p"/api/issues/#{task.id}/handoff", %{note: "needs the prod key"})

    body = json_response(conn, 200)
    assert body["attention_owner"] == "operator"
    assert body["attention_note"] == "needs the prod key"
  end

  test "handoff without a note is refused", %{conn: conn, task: task} do
    conn = post(conn, ~p"/api/issues/#{task.id}/handoff", %{})
    assert json_response(conn, 422)["error"]["message"] =~ "needs a note"
  end

  test "handback moves it back to the coordinator", %{conn: conn, task: task} do
    {:ok, _} = Attention.hand_off(task.id, :operator, "yours")

    conn = post(conn, ~p"/api/issues/#{task.id}/handback", %{note: "done, retry"})

    body = json_response(conn, 200)
    assert body["attention_owner"] == "coordinator"
    assert body["attention_note"] == "done, retry"
    assert Ash.get!(Issue, task.id).attention_owner == :coordinator
  end

  test "a hand-off to the owner it already has is a 409 conflict", %{conn: conn, task: task} do
    {:ok, _} = Attention.hand_off(task.id, :operator, "yours")

    conn = post(conn, ~p"/api/issues/#{task.id}/handoff", %{note: "again"})

    assert %{"error" => %{"type" => "conflict"}} = json_response(conn, 409)
  end

  test "a hand-off on an unknown ticket is a 404", %{conn: conn} do
    conn = post(conn, ~p"/api/issues/no-such-ticket/handoff", %{note: "x"})

    assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
  end
end
