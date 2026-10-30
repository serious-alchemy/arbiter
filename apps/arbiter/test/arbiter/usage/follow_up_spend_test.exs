defmodule Arbiter.Usage.FollowUpSpendTest do
  @moduledoc "Spend rolls up from follow-up tickets over `fixes` / `discovered_from` edges."
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.FollowUpSpend

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "fu-#{System.unique_integer([:positive])}", prefix: "fu"})

    {:ok, ws: ws}
  end

  defp issue!(ws, title), do: Ash.create!(Issue, %{title: title, workspace_id: ws.id})

  defp spend!(ws, issue, cost) do
    Ash.create!(Arbiter.Usage.Event, %{
      task_id: issue.id,
      base_task_id: issue.id,
      source: :task,
      step: :work,
      role: "base",
      workspace_id: ws.id,
      occurred_at: ~U[2026-01-01 00:00:00Z],
      cost_usd: cost
    })
  end

  defp edge!(from, to, type), do: {:ok, _} = Dependencies.add(from.id, to.id, type)

  test "no follow-ups: total is own spend", %{ws: ws} do
    a = issue!(ws, "a")
    spend!(ws, a, 2.0)

    assert %{own_usd: 2.0, follow_ups_usd: +0.0, total_usd: 2.0, follow_ups: []} =
             FollowUpSpend.for_task(a.id, workers: [])
  end

  test "sums a 3-level chain over fixes and discovered_from, each ticket once", %{ws: ws} do
    a = issue!(ws, "a")
    b = issue!(ws, "b")
    c = issue!(ws, "c")
    d = issue!(ws, "d")
    for {i, cost} <- [{a, 1.0}, {b, 2.0}, {c, 4.0}, {d, 8.0}], do: spend!(ws, i, cost)

    edge!(b, a, :fixes)
    edge!(c, b, :discovered_from)
    edge!(d, c, :fixes)
    # a second path to d must not double count it
    edge!(d, a, :discovered_from)

    r = FollowUpSpend.for_task(a.id, workers: [])
    assert r.own_usd == 1.0
    assert r.follow_ups_usd == 14.0
    assert r.total_usd == 15.0

    by_id = Map.new(r.follow_ups, &{&1.id, &1})
    assert Map.keys(by_id) |> Enum.sort() == Enum.sort([b.id, c.id, d.id])
    assert by_id[b.id].usd == 2.0
    assert by_id[c.id].usd == 4.0
    assert by_id[d.id].usd == 8.0
    assert by_id[b.id].title == "b"

    # the middle ticket rolls up only its own subtree
    assert FollowUpSpend.for_task(b.id, workers: []).follow_ups_usd == 12.0
  end

  test "a cycle terminates and never counts the origin as its own follow-up", %{ws: ws} do
    a = issue!(ws, "a")
    b = issue!(ws, "b")
    spend!(ws, a, 1.0)
    spend!(ws, b, 2.0)
    edge!(b, a, :fixes)
    edge!(a, b, :discovered_from)

    r = FollowUpSpend.for_task(a.id, workers: [])
    assert r.own_usd == 1.0
    assert r.follow_ups_usd == 2.0
    assert r.total_usd == 3.0
    assert [%{id: id}] = r.follow_ups
    assert id == b.id
  end

  test "other edge types do not roll up", %{ws: ws} do
    a = issue!(ws, "a")
    b = issue!(ws, "b")
    spend!(ws, b, 5.0)
    edge!(b, a, :relates_to)

    assert %{follow_ups: [], follow_ups_usd: +0.0} = FollowUpSpend.for_task(a.id, workers: [])
  end
end
