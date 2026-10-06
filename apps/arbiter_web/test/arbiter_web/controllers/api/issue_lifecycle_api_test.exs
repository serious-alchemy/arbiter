defmodule ArbiterWeb.Api.IssueLifecycleApiTest do
  @moduledoc """
  bd-6fkgvo (ticket lifecycle 10/13): the REST reads `arb prime` and
  `arb ticket show` render — `GET /api/issues/lifecycle` (every open ticket in
  a workspace, projected, in dispatch order) and the projection plus the
  current run on `GET /api/issues/:id`.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Dependencies, Issue, Workspace}
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "lc-api-#{System.unique_integer([:positive])}", prefix: "lca"})

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp in_state(ws, state, attrs \\ %{})

  defp in_state(ws, :backlog, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp in_state(ws, :queued, attrs), do: ws |> in_state(:backlog, attrs) |> transition!(:promote)
  defp in_state(ws, :active, attrs), do: ws |> in_state(:queued, attrs) |> transition!(:start)
  defp in_state(ws, :merging, attrs), do: ws |> in_state(:active, attrs) |> transition!(:open_pr)

  defp in_state(ws, :verifying, attrs),
    do: ws |> in_state(:active, attrs) |> transition!(:await_verification)

  defp in_state(ws, :closed, attrs),
    do: ws |> in_state(:backlog, attrs) |> transition!(:close, %{close_reason: :wont_do})

  defp transition!(issue, transition, args \\ %{}) do
    {:ok, next} = Ash.update(issue, args, action: transition)
    next
  end

  describe "GET /api/issues/lifecycle" do
    test "every open, non-epic ticket in the workspace, projected, in dispatch order", ctx do
      %{conn: conn, ws: ws} = ctx
      blocker = in_state(ws, :active, %{priority: 1})
      blocked = in_state(ws, :queued, %{priority: 1})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)
      ready = in_state(ws, :queued, %{priority: 0})
      verifying = in_state(ws, :verifying, %{priority: 2})
      backlog = in_state(ws, :backlog, %{priority: 3})
      _closed = in_state(ws, :closed)
      _epic = in_state(ws, :queued, %{issue_type: :epic})

      conn = get(conn, ~p"/api/issues/lifecycle", workspace_id: ws.id)
      assert %{"data" => rows} = json_response(conn, 200)

      assert Enum.map(rows, & &1["id"]) ==
               [ready.id, blocker.id, blocked.id, verifying.id, backlog.id]

      by_id = Map.new(rows, &{&1["id"], &1})
      assert by_id[ready.id]["column"] == "ready"
      assert by_id[blocked.id]["column"] == "blocked"
      assert by_id[blocked.id]["blocked_by"] == [blocker.id]
      assert by_id[blocker.id]["column"] == "in_progress"
      assert by_id[blocker.id]["step"] == "implementing"
      assert by_id[backlog.id]["column"] == "backlog"

      assert %{"owner" => "coordinator", "cause" => "awaiting_verification"} =
               by_id[verifying.id]["attention"]
    end

    # bd-dtdeff: a Ready card the scheduler is not dispatching says why, in the
    # same words the board card uses, so `arb prime` can print it. Cards in other
    # columns carry none.
    test "a Ready card carries the board's hold reason; other columns carry none", ctx do
      %{conn: conn, ws: ws} = ctx
      ready = in_state(ws, :queued, %{priority: 0})
      active = in_state(ws, :active, %{priority: 1})

      conn = get(conn, ~p"/api/issues/lifecycle", workspace_id: ws.id)
      assert %{"data" => rows} = json_response(conn, 200)
      by_id = Map.new(rows, &{&1["id"], &1})

      # No scheduler runs under test, so the board reads the queue as held.
      assert by_id[ready.id]["hold_reason"] == "scheduler paused"
      refute Map.has_key?(by_id[active.id], "hold_reason")
    end

    test "requires a workspace_id", %{conn: conn} do
      conn = get(conn, ~p"/api/issues/lifecycle")
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/issues/:id" do
    test "carries the projection: column, step, blocked_by and attention", ctx do
      %{conn: conn, ws: ws} = ctx
      issue = in_state(ws, :merging)

      conn = get(conn, ~p"/api/issues/#{issue.id}")
      body = json_response(conn, 200)

      assert body["state"] == "merging"
      assert body["column"] == "merging"
      assert body["step"] in ~w(waiting_ci in_merge_queue behind_base merge_blocked)
      assert body["blocked_by"] == []
      assert Map.has_key?(body, "attention")
    end

    test "carries the current run, in the run vocabulary", ctx do
      %{conn: conn, ws: ws} = ctx
      issue = in_state(ws, :active)

      {:ok, _run} =
        Ash.create(Run, %{
          task_id: issue.id,
          workspace_id: ws.id,
          repo: "acme/app",
          kind: :implement,
          state: :finished,
          outcome: :failed,
          started_at: DateTime.utc_now()
        })

      conn = get(conn, ~p"/api/issues/#{issue.id}")

      assert %{"kind" => "implement", "state" => "finished", "outcome" => "failed"} =
               json_response(conn, 200)["current_run"]
    end

    test "current_run is null for a ticket that never ran", ctx do
      issue = in_state(ctx.ws, :queued)
      conn = get(ctx.conn, ~p"/api/issues/#{issue.id}")
      assert %{"current_run" => nil, "column" => "ready"} = json_response(conn, 200)
    end
  end
end
