defmodule Arbiter.MCP.BulkPatchTest do
  @moduledoc "bd-cvyx6j: `ticket_update` / `ticket_close` / `ticket_verify` accept `ids`."
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Tasks.{BulkResult, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "bp-#{System.unique_integer([:positive])}", prefix: "bpt"})

    %{ws: ws, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  defp issue!(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp verifying!(ws) do
    issue = issue!(ws)

    Enum.reduce([:promote, :start, :await_verification], issue, fn tr, acc ->
      {:ok, next} = Ash.update(acc, %{}, action: tr)
      next
    end)
  end

  defp call(scope, tool, args), do: Catalog.call(scope, tool, args)
  defp by_id(%{results: results}), do: Map.new(results, &{&1.id, &1})

  test "bulk update applies one patch; mixed result", ctx do
    a = issue!(ctx.ws)
    b = issue!(ctx.ws)

    assert {:ok, res} =
             call(ctx.coordinator, "ticket_update", %{
               "ids" => [a.id, b.id, "bpt-nope"],
               "priority" => 1
             })

    r = by_id(res)
    assert r[a.id].status == "ok"
    assert r["bpt-nope"].status == "not_found"
    assert res.counts == %{total: 3, ok: 2, refused: 0, not_found: 1}
    assert Ash.get!(Issue, a.id).priority == 1
    assert Ash.get!(Issue, b.id).priority == 1
  end

  test "bulk update with invalid field value refuses per id", ctx do
    a = issue!(ctx.ws)
    assert {:ok, res} = call(ctx.coordinator, "ticket_update", %{"ids" => [a.id]})
    assert [%{status: "refused", reason: reason}] = res.results
    assert reason =~ "at least one field"
  end

  test "bulk notes replace needs confirm; append_notes works", ctx do
    a = issue!(ctx.ws, %{notes: "old"})

    assert {:tool_error, msg, _} =
             call(ctx.coordinator, "ticket_update", %{"ids" => [a.id], "notes" => "new"})

    assert msg =~ "confirm_replace_notes"
    assert Ash.get!(Issue, a.id).notes == "old"

    assert {:ok, %{counts: %{ok: 1}}} =
             call(ctx.coordinator, "ticket_update", %{
               "ids" => [a.id],
               "notes" => "new",
               "confirm_replace_notes" => true
             })

    assert Ash.get!(Issue, a.id).notes == "new"

    assert {:ok, %{counts: %{ok: 1}}} =
             call(ctx.coordinator, "ticket_update", %{"ids" => [a.id], "append_notes" => "more"})

    assert Ash.get!(Issue, a.id).notes =~ "more"
  end

  test "bulk close: ok + not_found, single shape unchanged", ctx do
    a = issue!(ctx.ws)
    b = issue!(ctx.ws)

    assert {:ok, res} =
             call(ctx.coordinator, "ticket_close", %{
               "ids" => [a.id, "bpt-nope"],
               "reason" => "swept"
             })

    r = by_id(res)
    assert r[a.id].status == "ok"
    assert r["bpt-nope"].status == "not_found"
    assert Ash.get!(Issue, a.id).state == :closed

    assert {:ok, single} = call(ctx.coordinator, "ticket_close", %{"id" => b.id})
    assert single.id == b.id
    refute Map.has_key?(single, :results)
  end

  test "bulk verify observed closes; failed reopens each id like single verify", ctx do
    a = verifying!(ctx.ws)
    b = verifying!(ctx.ws)
    c = verifying!(ctx.ws)
    not_parked = issue!(ctx.ws)

    assert {:ok, res} =
             call(ctx.coordinator, "ticket_verify", %{
               "ids" => [a.id, not_parked.id],
               "observed" => "restarted; works"
             })

    r = by_id(res)
    assert r[a.id].status == "ok"
    assert r[not_parked.id].status == "refused"
    assert r[not_parked.id].reason =~ "not awaiting verification"
    assert Ash.get!(Issue, a.id).state == :closed

    assert {:ok, %{counts: %{ok: 2}}} =
             call(ctx.coordinator, "ticket_verify", %{
               "ids" => [b.id, c.id],
               "failed" => "still broken"
             })

    # exactly what a single failed verify does
    single = verifying!(ctx.ws)
    {:ok, _} = call(ctx.coordinator, "ticket_verify", %{"id" => single.id, "failed" => "x"})
    expected = Ash.get!(Issue, single.id).state
    assert expected != :verifying
    assert Ash.get!(Issue, b.id).state == expected
    assert Ash.get!(Issue, c.id).state == expected
  end

  test "batch cap enforced and schema documents ids" do
    for name <- ~w(ticket_update ticket_close ticket_verify) do
      {:ok, tool} = Catalog.fetch(name)
      assert tool.input_schema["properties"]["ids"]["maxItems"] == BulkResult.max_batch()
    end

    scope = %Scope{tier: :coordinator, workspace_id: "x", can_dispatch: true}
    ids = Enum.map(1..(BulkResult.max_batch() + 1), &"bpt-#{&1}")
    assert {:tool_error, msg, _} = call(scope, "ticket_close", %{"ids" => ids})
    assert msg =~ "at most"
  end
end
