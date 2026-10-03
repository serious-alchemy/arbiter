defmodule ArbiterWeb.Api.IssueEffectivePriorityTest do
  @moduledoc """
  ES4 (bd-4sw689, `docs/design/epic-aware-scheduling.md` §6.3): `GET
  /api/issues/:id` adds `effective_priority`, `priority_via` and
  `priority_lift`; `GET /api/issues/ready` and `/lifecycle` list in the §4 order.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Dependencies, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ep-api-#{System.unique_integer([:positive])}", prefix: "epa"})

    {:ok, epic} = Ash.create(Issue, %{title: "Epic", workspace_id: ws.id, issue_type: :epic})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws, epic: epic}
  end

  defp floor!(epic, floor) do
    {:ok, epic} = Ash.update(epic, %{floor_priority: floor}, action: :set_floor)
    epic
  end

  defp ready(ws, priority, parent \\ nil) do
    {:ok, created} =
      Ash.create(Issue, %{
        title: "t-#{System.unique_integer([:positive])}",
        workspace_id: ws.id,
        priority: priority,
        acceptance: "- ok"
      })

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    if parent, do: {:ok, _} = Dependencies.add(parent.id, issue.id, :parent_of)
    issue
  end

  defp ids(conn), do: for(%{"id" => id} <- json_response(conn, 200)["data"], do: id)

  describe "GET /api/issues/:id" do
    test "no floor: the three fields read own priority, null, null", ctx do
      child = ready(ctx.ws, 3, ctx.epic)
      body = ctx.conn |> get(~p"/api/issues/#{child.id}") |> json_response(200)

      assert %{
               "priority" => 3,
               "effective_priority" => 3,
               "priority_via" => nil,
               "priority_lift" => nil
             } = body
    end

    test "a floored epic lifts the child; priority stays own", ctx do
      epic = floor!(ctx.epic, 1)
      child = ready(ctx.ws, 3, epic)
      body = ctx.conn |> get(~p"/api/issues/#{child.id}") |> json_response(200)

      assert %{
               "priority" => 3,
               "effective_priority" => 1,
               "priority_via" => via,
               "priority_lift" => "applied"
             } = body

      assert via == epic.id
    end
  end

  describe "GET /api/issues/ready" do
    test "no floor: priority, rank, age", ctx do
      low = ready(ctx.ws, 3, ctx.epic)
      high = ready(ctx.ws, 1)
      mid = ready(ctx.ws, 2)

      conn = get(ctx.conn, ~p"/api/issues/ready", workspace_id: ctx.ws.id)
      assert ids(conn) == [high.id, mid.id, low.id]
    end

    test "a floor lifts the epic's child over a better-own-priority ticket", ctx do
      epic = floor!(ctx.epic, 1)
      plain = ready(ctx.ws, 2)
      child = ready(ctx.ws, 4, epic)

      conn = get(ctx.conn, ~p"/api/issues/ready", workspace_id: ctx.ws.id)
      assert ids(conn) == [child.id, plain.id]
    end
  end

  describe "GET /api/issues/lifecycle" do
    test "a floor lifts the epic's child over a better-own-priority ticket", ctx do
      epic = floor!(ctx.epic, 1)
      plain = ready(ctx.ws, 2)
      child = ready(ctx.ws, 4, epic)

      conn = get(ctx.conn, ~p"/api/issues/lifecycle", workspace_id: ctx.ws.id)
      assert ids(conn) == [child.id, plain.id]
    end
  end
end
