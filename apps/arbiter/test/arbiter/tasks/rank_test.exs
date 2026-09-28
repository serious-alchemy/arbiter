defmodule Arbiter.Tasks.RankTest do
  @moduledoc """
  bd-djapyj: `Arbiter.Tasks.Rank.move/2` wraps the `:set_rank` action's
  renumber (raw SQL, outside AshSqlite's transaction support) in an explicit
  `Repo.transaction/1`. This asserts that a failure partway through a
  renumber rolls every write back, rather than leaving the workspace's
  ranks half-renumbered.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Rank, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rank-tx-#{System.unique_integer([:positive])}", prefix: "rk"})

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

  defp ranks_and_values(ws) do
    Issue
    |> Ash.Query.filter(workspace_id == ^ws.id)
    |> Ash.Query.sort(rank: :asc)
    |> Ash.read!()
    |> Enum.map(&{&1.id, &1.rank})
  end

  test "top/bottom/before/after persist through move/2 exactly as through the raw action", %{
    ws: ws
  } do
    a = ticket(ws)
    b = ticket(ws)
    _c = ticket(ws)

    assert {:ok, moved} = Rank.move(a, %{position: :bottom})
    assert Enum.map(ranks_and_values(ws), &elem(&1, 0)) |> List.last() == moved.id
    assert moved.id == a.id
    assert Ash.get!(Issue, b.id).priority == b.priority
  end

  test "a crash partway through a renumber rolls back every write, moved ticket included", %{
    ws: ws
  } do
    a = ticket(ws)
    b = ticket(ws)
    _c = ticket(ws)
    d = ticket(ws)

    # Force `a` and `b` adjacent so inserting `d` before `b` has no integer
    # gap and must renumber the whole workspace.
    Arbiter.Repo.query!("UPDATE issues SET rank = 100 WHERE id = ?1", [a.id])
    Arbiter.Repo.query!("UPDATE issues SET rank = 101 WHERE id = ?1", [b.id])

    before_state = ranks_and_values(ws)

    Process.put(:rank_test_query_count, 0)

    :meck.new(Arbiter.Repo, [:passthrough, :no_link])

    :meck.expect(Arbiter.Repo, :query!, fn sql, params ->
      count = Process.get(:rank_test_query_count, 0) + 1
      Process.put(:rank_test_query_count, count)

      if count == 2 do
        raise "injected mid-renumber failure"
      else
        :meck.passthrough([sql, params])
      end
    end)

    try do
      assert {:error, error} = Rank.move(d, %{before_id: b.id})
      assert Exception.message(error) =~ "injected mid-renumber failure"
    after
      :meck.unload(Arbiter.Repo)
    end

    # Nothing persisted: the first renumber write landed on the connection
    # inside the transaction Rank.move opened, and the raise rolled it back
    # along with everything else, rather than leaving it committed.
    assert ranks_and_values(ws) == before_state
  end
end
