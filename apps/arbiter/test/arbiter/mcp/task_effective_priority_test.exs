defmodule Arbiter.MCP.TaskEffectivePriorityTest do
  @moduledoc """
  ES4 (bd-4sw689, `docs/design/epic-aware-scheduling.md` §6.3): `ticket_show`
  adds `effective_priority`, `priority_via` and `priority_lift` while `priority`
  stays the own priority, and `ticket_ready` lists in the §4 order.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Dependencies, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "mcp-ep-#{System.unique_integer([:positive])}", prefix: "me"})

    {:ok, epic} = Ash.create(Issue, %{title: "Epic", workspace_id: ws.id, issue_type: :epic})

    %{
      ws: ws,
      epic: epic,
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    }
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

  describe "ticket_show" do
    test "no floor: the three fields read own priority, null, null", ctx do
      child = ready(ctx.ws, 3, ctx.epic)

      for args <- [%{"id" => child.id}, %{"id" => child.id, "full" => true}] do
        assert {:ok, shown} = Catalog.call(ctx.coordinator, "ticket_show", args)

        assert %{priority: 3, effective_priority: 3, priority_via: nil, priority_lift: nil} =
                 shown
      end
    end

    test "a floored epic: effective_priority and via, priority stays own", ctx do
      epic = floor!(ctx.epic, 1)
      child = ready(ctx.ws, 3, epic)

      for args <- [%{"id" => child.id}, %{"id" => child.id, "full" => true}] do
        assert {:ok, shown} = Catalog.call(ctx.coordinator, "ticket_show", args)
        epic_id = epic.id

        assert %{
                 priority: 3,
                 effective_priority: 1,
                 priority_via: ^epic_id,
                 priority_lift: "applied"
               } = shown
      end
    end
  end

  describe "ticket_ready" do
    test "no floor: priority, rank, age as today", ctx do
      low = ready(ctx.ws, 3, ctx.epic)
      high = ready(ctx.ws, 1)

      assert {:ok, %{tasks: tasks}} = Catalog.call(ctx.coordinator, "ticket_ready", %{})
      assert Enum.map(tasks, & &1.id) == [high.id, low.id]
    end

    test "a floor lifts the epic's child over a better-own-priority ticket", ctx do
      epic = floor!(ctx.epic, 1)
      plain = ready(ctx.ws, 2)
      child = ready(ctx.ws, 4, epic)

      assert {:ok, %{tasks: tasks}} = Catalog.call(ctx.coordinator, "ticket_ready", %{})
      assert Enum.map(tasks, & &1.id) == [child.id, plain.id]
    end
  end
end
