defmodule ArbiterWeb.Api.IssueSpendTest do
  @moduledoc "GET /api/issues/:id carries the actual-spend breakdown (bd-aundwd)."
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.LiveSpend

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "sp-#{System.unique_integer([:positive])}", prefix: "sp"})

    {:ok, issue} = Ash.create(Issue, %{title: "spend", workspace_id: ws.id})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws, issue: issue}
  end

  defp row!(ws, issue, suffix, role, cost, secs) do
    Ash.create!(Arbiter.Usage.Event, %{
      task_id: issue.id <> suffix,
      base_task_id: issue.id,
      source: :task,
      step: :work,
      role: role,
      workspace_id: ws.id,
      occurred_at: DateTime.add(~U[2026-01-01 00:00:00Z], secs),
      cost_usd: cost
    })
  end

  defp pass(body, kind), do: Enum.find(body["spend"]["passes"], &(&1["kind"] == kind))

  test "no usage: zero runs", %{conn: conn, issue: issue} do
    body = conn |> get(~p"/api/issues/#{issue.id}") |> json_response(200)
    assert body["spend"]["run_count"] == 0
    assert body["spend"]["passes"] == []
  end

  test "breaks spend down per pass kind and matches the dashboard total", %{
    conn: conn,
    ws: ws,
    issue: issue
  } do
    row!(ws, issue, "", "base", 4.0, 0)
    row!(ws, issue, "", "base", 1.0, 10)
    row!(ws, issue, "#review", "review", 0.5, 20)
    row!(ws, issue, "#review#impl1", "impl", 2.0, 30)
    row!(ws, issue, ":fixpass", "fix_pass", 1.5, 40)
    row!(ws, issue, ":fixpass", "fix_pass", 1.0, 50)
    row!(ws, issue, ":conflict", "conflict", 0.25, 60)
    row!(ws, issue, "#review", "review", nil, 70)

    body = conn |> get(~p"/api/issues/#{issue.id}") |> json_response(200)
    spend = body["spend"]

    assert spend["total_usd"] == LiveSpend.for_task(issue.id, workers: []).total_usd
    assert spend["total_usd"] == 10.25
    assert spend["unpriced_runs"] == 1
    assert %{"count" => 1, "usd" => 4.0} = pass(body, "implement")
    assert %{"count" => 1, "usd" => 1.0} = pass(body, "resume")
    assert %{"count" => 1, "usd" => 2.0} = pass(body, "review_round")
    assert %{"count" => 2, "usd" => 2.5} = pass(body, "fix_pass")
    assert %{"count" => 1, "usd" => 0.25} = pass(body, "conflict")
    assert %{"count" => 2, "usd" => 0.5, "unpriced_runs" => 1} = pass(body, "review")
  end

  test "an all-unpriced ticket shows a count, not $0", %{conn: conn, ws: ws, issue: issue} do
    row!(ws, issue, "", "base", nil, 0)

    body = conn |> get(~p"/api/issues/#{issue.id}") |> json_response(200)
    assert body["spend"]["total_usd"] == nil
    assert body["spend"]["unpriced_runs"] == 1
    assert %{"count" => 1, "unpriced_runs" => 1} = pass(body, "implement")
  end
end
