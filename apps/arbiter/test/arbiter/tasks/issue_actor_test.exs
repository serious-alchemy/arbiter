defmodule Arbiter.Tasks.IssueActorTest do
  @moduledoc """
  bd-6i7yzq: every `Issue` version row records who acted — the explicit Ash
  `actor:`, else the process's ambient `Arbiter.Actor`, else nothing. Attribution
  only: the actor never changes whether an action succeeds.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Tasks.Issue.Version

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "act-#{System.unique_integer([:positive])}", prefix: "ac"})

    {:ok, issue} =
      Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- works"})

    {:ok, ws: ws, issue: issue}
  end

  defp versions(issue, action) do
    Version
    |> Ash.Query.filter(version_source_id == ^issue.id and version_action_name == ^action)
    |> Ash.read!()
  end

  test "a write with no actor and no ambient actor records none", %{issue: issue} do
    assert [%{actor: nil}] = versions(issue, :create)
  end

  test "an explicit scope actor is recorded", %{issue: issue} do
    scope = %Scope{tier: :worker, task_id: issue.id, workspace_id: issue.workspace_id}
    {:ok, _} = Ash.update(issue, %{notes: "n"}, actor: scope)

    assert [%{actor: actor}] = versions(issue, :update)
    assert actor == "worker:#{issue.id}"
  end

  test "an Arbiter.Actor passed as the Ash actor is recorded", %{issue: issue} do
    {:ok, _} = Ash.update(issue, %{notes: "n"}, actor: Actor.autopilot())
    assert [%{actor: "autopilot"}] = versions(issue, :update)
  end

  test "the ambient actor is the fallback, on a named transition", %{issue: issue} do
    Actor.with_actor(Actor.operator("ryan"), fn ->
      {:ok, _} = Ash.update(issue, %{}, action: :promote)
    end)

    assert [%{actor: "operator:ryan"}] = versions(issue, :promote)
  end

  test "an explicit actor beats the ambient one", %{issue: issue} do
    Actor.with_actor(Actor.autopilot(), fn ->
      {:ok, _} = Ash.update(issue, %{notes: "n"}, actor: %Scope{tier: :coordinator})
    end)

    assert [%{actor: "coordinator"}] = versions(issue, :update)
  end

  test "creates are attributed too", %{ws: ws} do
    {:ok, created} =
      Actor.with_actor(Actor.coordinator(), fn ->
        Ash.create(Issue, %{title: "c", workspace_id: ws.id, acceptance: "- ok"})
      end)

    assert [%{actor: "coordinator"}] = versions(created, :create)
  end
end
