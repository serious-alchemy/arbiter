defmodule Arbiter.MCP.BulkLifecycleTest do
  @moduledoc "bd-3cyf8j: `ticket_promote` / `ticket_demote` / `ticket_rank` accept `ids`."
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Tasks.{BulkResult, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "bulk-#{System.unique_integer([:positive])}", prefix: "bk"})

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    %{ws: ws, coordinator: coordinator}
  end

  defp issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp call(scope, tool, args), do: Catalog.call(scope, tool, args)

  defp by_id(%{results: results}), do: Map.new(results, &{&1.id, &1})

  test "mixed promote batch: ok + refused + not_found, refusal does not block the rest", ctx do
    good = issue!(ctx.ws, %{})
    gated = issue!(ctx.ws, %{issue_type: :feature, acceptance: nil})
    ids = [good.id, gated.id, "bk-nope"]

    assert {:ok, res} = call(ctx.coordinator, "ticket_promote", %{"ids" => ids})
    r = by_id(res)

    assert r[good.id].status == "ok"
    assert r[good.id].ticket.state == "queued"
    assert r[gated.id].status == "refused"
    assert r[gated.id].reason =~ "acceptance"
    assert r["bk-nope"].status == "not_found"
    assert res.counts == %{total: 3, ok: 1, refused: 1, not_found: 1}
    assert Ash.get!(Issue, gated.id).state == :backlog
  end

  test "shared acceptance_waived applies to every id", ctx do
    gated = issue!(ctx.ws, %{issue_type: :feature, acceptance: nil})

    assert {:ok, %{counts: %{ok: 1}}} =
             call(ctx.coordinator, "ticket_promote", %{
               "ids" => [gated.id],
               "acceptance_waived" => "spike"
             })
  end

  test "single id keeps its response shape", ctx do
    t = issue!(ctx.ws, %{})
    assert {:ok, res} = call(ctx.coordinator, "ticket_promote", %{"id" => t.id})
    assert res.id == t.id
    refute Map.has_key?(res, :results)
  end

  test "refine scope: ids outside the subtree are refused per id" do
    {:ok, ws} = Ash.create(Workspace, %{name: "bulk-refine", prefix: "brf"})
    root = issue!(ws, %{})
    other = issue!(ws, %{})

    scope = %Scope{
      tier: :refine,
      workspace_id: ws.id,
      issue_id: root.id,
      can_dispatch: false
    }

    assert {:ok, res} = call(scope, "ticket_promote", %{"ids" => [root.id, other.id]})
    r = by_id(res)
    assert r[root.id].status == "ok"
    assert r[other.id].status == "refused"
    assert r[other.id].reason =~ "subtree"
  end

  test "demote batch with a missing id", ctx do
    a = issue!(ctx.ws, %{})
    {:ok, _} = call(ctx.coordinator, "ticket_promote", %{"id" => a.id})

    assert {:ok, res} = call(ctx.coordinator, "ticket_demote", %{"ids" => [a.id, "bk-nope"]})
    r = by_id(res)
    assert r[a.id].status == "ok"
    assert r["bk-nope"].status == "not_found"
    assert Ash.get!(Issue, a.id).state == :backlog
  end

  test "rank batch places ids in list order at the top", ctx do
    [a, b, c] = for _ <- 1..3, do: issue!(ctx.ws, %{})

    assert {:ok, res} =
             call(ctx.coordinator, "ticket_rank", %{
               "ids" => [c.id, a.id, "bk-nope"],
               "top" => true
             })

    r = by_id(res)
    assert r[c.id].status == "ok"
    assert r["bk-nope"].status == "not_found"
    assert Ash.get!(Issue, c.id).rank < Ash.get!(Issue, a.id).rank
    assert Ash.get!(Issue, a.id).rank < Ash.get!(Issue, b.id).rank
  end

  test "rank batch with an invalid move refuses every id", ctx do
    a = issue!(ctx.ws, %{})
    assert {:ok, res} = call(ctx.coordinator, "ticket_rank", %{"ids" => [a.id]})
    assert [%{status: "refused", reason: reason}] = res.results
    assert reason =~ "exactly one"
  end

  test "batch cap and empty ids are clear errors", ctx do
    ids = Enum.map(1..(BulkResult.max_batch() + 1), &"bk-#{&1}")
    assert {:tool_error, msg, _} = call(ctx.coordinator, "ticket_promote", %{"ids" => ids})
    assert msg =~ "at most #{BulkResult.max_batch()}"
    assert {:tool_error, _, _} = call(ctx.coordinator, "ticket_demote", %{"ids" => []})
  end

  test "schema documents ids on all three tools and no longer requires id" do
    for name <- ~w(ticket_promote ticket_demote ticket_rank) do
      {:ok, tool} = Catalog.fetch(name)
      assert tool.input_schema["properties"]["ids"]["type"] == "array"
      assert tool.input_schema["properties"]["ids"]["maxItems"] == BulkResult.max_batch()
      assert tool.description =~ "not_found"
    end
  end
end
