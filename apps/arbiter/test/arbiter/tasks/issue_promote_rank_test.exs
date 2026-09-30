defmodule Arbiter.Tasks.IssuePromoteRankTest do
  @moduledoc """
  Promoting a ticket Backlog → Ready ranks it last in its workspace, on both
  the `:promote_to_ready` door and the `:promote` transition. An idempotent
  re-promote leaves the rank alone, and `:set_rank` still reorders it.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "pr-#{System.unique_integer([:positive])}", prefix: "pr"})

    {:ok, ws: ws}
  end

  defp ticket(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- it works"})

    issue
  end

  defp max_rank(ws) do
    Issue |> Ash.Query.filter(workspace_id == ^ws.id) |> Ash.max!(:rank)
  end

  for action <- [:promote_to_ready, :promote] do
    test "#{action} ranks a promoted ticket after every ticket in the workspace", %{ws: ws} do
      old = ticket(ws)
      newer = ticket(ws)
      {:ok, newer} = Ash.update(newer, %{}, action: :promote_to_ready)
      assert old.rank < newer.rank

      assert {:ok, promoted} = Ash.update(old, %{}, action: unquote(action))
      assert promoted.state == :queued
      assert promoted.rank > newer.rank
      assert promoted.rank == max_rank(ws)
    end
  end

  test "an idempotent re-promote does not move the ticket", %{ws: ws} do
    a = ticket(ws)
    {:ok, a} = Ash.update(a, %{}, action: :promote_to_ready)
    _later = ticket(ws)

    assert {:ok, again} = Ash.update(a, %{}, action: :promote_to_ready)
    assert again.rank == a.rank
  end

  test "set_rank still reorders a promoted ticket", %{ws: ws} do
    a = ticket(ws)
    b = ticket(ws)
    {:ok, a} = Ash.update(a, %{}, action: :promote_to_ready)
    {:ok, b} = Ash.update(b, %{}, action: :promote_to_ready)
    assert a.rank < b.rank

    {:ok, b} = Ash.update(b, %{position: :top}, action: :set_rank)
    assert b.rank < Ash.get!(Issue, a.id).rank
  end
end
