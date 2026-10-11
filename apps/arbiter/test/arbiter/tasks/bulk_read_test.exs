defmodule Arbiter.Tasks.BulkReadTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.BulkRead
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "br-#{System.unique_integer([:positive])}", prefix: "br"})

    %{ws: ws}
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
      fn _e, _m, _meta, _ -> send(me, {:q, ref}) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
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

  defp build(ws, n) do
    epic = ticket(ws, %{issue_type: :epic, title: "epic"})

    for _ <- 1..n do
      child = ticket(ws)
      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      other = ticket(ws)
      {:ok, _} = Dependencies.add(child.id, other.id, :depends_on)
      child
    end
    |> then(&{epic, &1})
  end

  test "decorate/2 returns parent_id, depends_on and blocks per ticket", %{ws: ws} do
    {epic, [child | _]} = build(ws, 2)
    {:ok, issues} = Ash.read(Issue)
    extras = BulkRead.edges(issues)

    assert extras[child.id].parent_id == epic.id
    assert [_] = extras[child.id].depends_on
    assert extras[epic.id].parent_id == nil
    assert [_ | _] = Enum.flat_map(extras, fn {_, e} -> e.blocks end)
  end

  test "query count does not grow with the number of tickets", %{ws: ws} do
    build(ws, 2)
    {:ok, small} = Ash.read(Issue)
    {_, q_small} = count_queries(fn -> BulkRead.load(small) end)

    build(ws, 8)
    {:ok, large} = Ash.read(Issue)
    assert length(large) > length(small)
    {_, q_large} = count_queries(fn -> BulkRead.load(large) end)

    assert q_small == q_large
  end

  test "load/1 gives epics child_total/child_closed", %{ws: ws} do
    {epic, _} = build(ws, 2)
    {:ok, issues} = Ash.read(Issue)
    loaded = BulkRead.load(issues)
    e = Enum.find(loaded, &(&1.id == epic.id))
    assert e.child_total == 2
    assert e.child_closed == 0
  end
end
