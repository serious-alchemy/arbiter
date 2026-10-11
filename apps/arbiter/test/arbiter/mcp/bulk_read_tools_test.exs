defmodule Arbiter.MCP.BulkReadToolsTest do
  @moduledoc "bd-7sxpln: `ticket_list` `include` and `ticket_show` `ids`."
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "mb-#{System.unique_integer([:positive])}", prefix: "mb"})

    %{ws: ws, scope: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  defp ticket(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp count_queries(fun) do
    ref = make_ref()
    me = self()
    id = {__MODULE__, ref}

    :telemetry.attach(
      id,
      [:arbiter, :repo, :query],
      fn _, _, _, _ -> send(me, {:q, ref}) end,
      nil
    )

    try do
      fun.()
      drain(ref, 0)
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, n) do
    receive do
      {:q, ^ref} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  defp grow(ws, n) do
    epic = ticket(ws, %{issue_type: :epic})

    for _ <- 1..n do
      child = ticket(ws)
      other = ticket(ws)
      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      {:ok, _} = Dependencies.add(child.id, other.id, :depends_on)
    end

    epic
  end

  test "ticket_list default rows are unchanged; epics carry progress", ctx do
    epic = grow(ctx.ws, 2)
    assert {:ok, %{tasks: rows}} = Catalog.call(ctx.scope, "ticket_list", %{})
    refute Enum.any?(rows, &Map.has_key?(&1, :parent_id))
    row = Enum.find(rows, &(&1.id == epic.id))
    assert %{child_total: 2, child_closed: 0} = row
  end

  test "ticket_list include=parent,deps (string or list) adds edges", ctx do
    epic = grow(ctx.ws, 1)

    for include <- ["parent,deps", ["parent", "deps"]] do
      assert {:ok, %{tasks: rows}} =
               Catalog.call(ctx.scope, "ticket_list", %{"include" => include})

      assert [child] = Enum.filter(rows, &(&1[:parent_id] == epic.id))
      assert [dep] = child.depends_on
      assert Enum.find(rows, &(&1.id == dep)).blocks == [child.id]
    end
  end

  test "ticket_list rejects an unknown include", ctx do
    assert {:tool_error, _, "validation_error"} =
             Catalog.call(ctx.scope, "ticket_list", %{"include" => "x"})
  end

  test "ticket_list include query count is constant in ticket count", ctx do
    grow(ctx.ws, 2)
    args = %{"include" => "parent,deps"}
    Catalog.call(ctx.scope, "ticket_list", args)
    small = count_queries(fn -> Catalog.call(ctx.scope, "ticket_list", args) end)
    grow(ctx.ws, 10)
    large = count_queries(fn -> Catalog.call(ctx.scope, "ticket_list", args) end)
    assert small == large
  end

  test "ticket_show ids returns all, unknown ids per id", ctx do
    a = ticket(ctx.ws)
    b = ticket(ctx.ws)

    assert {:ok, %{tasks: tasks, not_found: ["nope"], count: 2}} =
             Catalog.call(ctx.scope, "ticket_show", %{"ids" => [a.id, "nope", b.id]})

    assert Enum.map(tasks, & &1.id) == [a.id, b.id]
    assert Enum.all?(tasks, &Map.has_key?(&1, :column))
    assert Enum.all?(tasks, &Map.has_key?(&1, :parent_id))
  end

  test "ticket_show ids hides another workspace's ticket as not found", ctx do
    {:ok, other_ws} =
      Ash.create(Workspace, %{name: "mb2-#{System.unique_integer([:positive])}", prefix: "mc"})

    foreign = ticket(other_ws)

    assert {:ok, %{tasks: [], not_found: [id]}} =
             Catalog.call(ctx.scope, "ticket_show", %{"ids" => [foreign.id]})

    assert id == foreign.id
  end

  test "ticket_show ids is coordinator-only; a worker scope is refused", ctx do
    a = ticket(ctx.ws)
    worker = %Scope{tier: :worker, workspace_id: ctx.ws.id, task_id: a.id}
    assert {:rpc_error, _, _} = Catalog.call(worker, "ticket_show", %{"ids" => [a.id]})
  end

  test "ticket_show ids query count is constant", ctx do
    few = for _ <- 1..2, do: ticket(ctx.ws).id
    Catalog.call(ctx.scope, "ticket_show", %{"ids" => few})
    small = count_queries(fn -> Catalog.call(ctx.scope, "ticket_show", %{"ids" => few}) end)
    many = for _ <- 1..12, do: ticket(ctx.ws).id
    large = count_queries(fn -> Catalog.call(ctx.scope, "ticket_show", %{"ids" => many}) end)
    assert small == large
  end
end
