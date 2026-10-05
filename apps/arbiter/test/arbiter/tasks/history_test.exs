defmodule Arbiter.Tasks.HistoryTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{History, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "hist-#{System.unique_integer([:positive])}", prefix: "hi"})

    {:ok, issue} =
      Actor.with_actor(Actor.operator("ryan"), fn ->
        Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- ok"})
      end)

    {:ok, issue: issue}
  end

  test "lists a ticket's versions newest first, each with its actor", %{issue: issue} do
    {:ok, _} = Ash.update(issue, %{notes: "n"}, actor: %Scope{tier: :coordinator})

    assert [newest, oldest] = History.recent(issue.id)
    assert %{action: "update", actor: "coordinator"} = newest
    assert %{action: "create", actor: "operator:ryan"} = oldest
    assert %DateTime{} = newest.at
    assert newest.changes["notes"] == "n"
  end

  test "a version with no actor on record reports nil", %{issue: issue} do
    {:ok, _} = Ash.update(issue, %{notes: "n"})
    assert [%{action: "update", actor: nil} | _] = History.recent(issue.id)
  end

  test "is bounded by limit", %{issue: issue} do
    {:ok, issue} = Ash.update(issue, %{notes: "a"})
    {:ok, _} = Ash.update(issue, %{notes: "b"})
    assert [_] = History.recent(issue.id, 1)
  end
end
