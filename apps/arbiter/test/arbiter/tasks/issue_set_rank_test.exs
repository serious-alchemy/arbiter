defmodule Arbiter.Tasks.IssueSetRankTest do
  @moduledoc """
  bd-djapyj: the `:set_rank` action — top/bottom/before/after reordering
  inside a workspace's rank order, the gap-exhaustion renumber path, the
  cross-workspace rejection, and the paper_trail audit row.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rank-#{System.unique_integer([:positive])}", prefix: "rk"})

    {:ok, ws: ws}
  end

  defp ticket(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- it works"}, attrs)
      )

    issue
  end

  defp ranks(ws) do
    Issue
    |> Ash.Query.filter(workspace_id == ^ws.id)
    |> Ash.Query.sort(rank: :asc)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  describe ":top / :bottom" do
    test "top moves a ticket ahead of every other ticket in the workspace", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)
      c = ticket(ws)

      assert {:ok, moved} = Ash.update(c, %{position: :top}, action: :set_rank)

      assert ranks(ws) == [moved.id, a.id, b.id]
    end

    test "bottom moves a ticket behind every other ticket in the workspace", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)
      c = ticket(ws)

      assert {:ok, moved} = Ash.update(a, %{position: :bottom}, action: :set_rank)

      assert ranks(ws) == [b.id, c.id, moved.id]
    end

    test "top on the only ticket in the workspace is a no-op success", %{ws: ws} do
      a = ticket(ws)

      assert {:ok, _moved} = Ash.update(a, %{position: :top}, action: :set_rank)
      assert ranks(ws) == [a.id]
    end

    test "never changes priority", %{ws: ws} do
      a = ticket(ws, %{priority: 3})
      _b = ticket(ws)

      assert {:ok, moved} = Ash.update(a, %{position: :bottom}, action: :set_rank)
      assert moved.priority == 3
    end
  end

  describe ":before / :after" do
    test "before places a ticket immediately ahead of the target", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)
      c = ticket(ws)

      assert {:ok, moved} = Ash.update(c, %{before_id: b.id}, action: :set_rank)

      assert ranks(ws) == [a.id, moved.id, b.id]
    end

    test "after places a ticket immediately behind the target", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)
      c = ticket(ws)

      assert {:ok, moved} = Ash.update(a, %{after_id: b.id}, action: :set_rank)

      assert ranks(ws) == [b.id, moved.id, c.id]
    end

    test "before the first ticket puts it at the very top", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)

      assert {:ok, moved} = Ash.update(b, %{before_id: a.id}, action: :set_rank)

      assert ranks(ws) == [moved.id, a.id]
    end

    test "after the last ticket puts it at the very bottom", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)

      assert {:ok, moved} = Ash.update(a, %{after_id: b.id}, action: :set_rank)

      assert ranks(ws) == [b.id, moved.id]
    end
  end

  describe "renumbering when there's no integer gap" do
    test "adjacent ranks renumber the whole workspace and preserve order", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)
      c = ticket(ws)
      d = ticket(ws)

      # Force `a` and `b` to be adjacent integers so there is no room to fit
      # a ticket strictly between them.
      Arbiter.Repo.query!("UPDATE issues SET rank = 100 WHERE id = ?1", [a.id])
      Arbiter.Repo.query!("UPDATE issues SET rank = 101 WHERE id = ?1", [b.id])

      assert {:ok, moved} = Ash.update(d, %{before_id: b.id}, action: :set_rank)

      # `d` lands between `a` and `b`; `c`'s relative position (after `b`) is
      # preserved.
      assert ranks(ws) == [a.id, moved.id, b.id, c.id]

      reloaded = Enum.map(ranks(ws), &Ash.get!(Issue, &1))
      rank_values = Enum.map(reloaded, & &1.rank)
      assert rank_values == Enum.sort(rank_values)
      assert Enum.uniq(rank_values) == rank_values
    end
  end

  describe "cross-workspace rejection" do
    test "before a ticket in another workspace is rejected", %{ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "rank-other-#{System.unique_integer([:positive])}",
          prefix: "rko"
        })

      a = ticket(ws)
      other = ticket(other_ws)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(a, %{before_id: other.id}, action: :set_rank)

      # Unmoved.
      assert Ash.get!(Issue, a.id).rank == a.rank
    end

    test "after a ticket in another workspace is rejected", %{ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "rank-other-#{System.unique_integer([:positive])}",
          prefix: "rko"
        })

      a = ticket(ws)
      other = ticket(other_ws)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(a, %{after_id: other.id}, action: :set_rank)
    end
  end

  describe "self-target rejection" do
    test "before_id pointing at the ticket itself is rejected", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(a, %{before_id: a.id}, action: :set_rank)

      # Neither ticket moved.
      assert ranks(ws) == [a.id, b.id]
    end

    test "after_id pointing at the ticket itself is rejected", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(a, %{after_id: a.id}, action: :set_rank)

      # Neither ticket moved.
      assert ranks(ws) == [a.id, b.id]
      assert Ash.get!(Issue, a.id).rank == a.rank
      assert Ash.get!(Issue, b.id).rank == b.rank
    end
  end

  describe "argument validation" do
    test "no arguments is rejected", %{ws: ws} do
      a = ticket(ws)

      assert {:error, %Ash.Error.Invalid{}} = Ash.update(a, %{}, action: :set_rank)
    end

    test "more than one of top/bottom/before/after is rejected", %{ws: ws} do
      a = ticket(ws)
      b = ticket(ws)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(a, %{position: :top, before_id: b.id}, action: :set_rank)
    end

    test "rank is not in :update's accept list", %{ws: ws} do
      a = ticket(ws)

      assert {:error, %Ash.Error.Invalid{}} = Ash.update(a, %{rank: 999_999})
    end
  end

  describe "paper_trail audit" do
    test "set_rank writes a version row with the action name", %{ws: ws} do
      a = ticket(ws)
      _b = ticket(ws)

      {:ok, _moved} = Ash.update(a, %{position: :bottom}, action: :set_rank)

      versions =
        Arbiter.Tasks.Issue.Version
        |> Ash.Query.filter(version_source_id == ^a.id)
        |> Ash.read!()

      assert Enum.any?(versions, &(&1.version_action_name == :set_rank))
    end
  end
end
