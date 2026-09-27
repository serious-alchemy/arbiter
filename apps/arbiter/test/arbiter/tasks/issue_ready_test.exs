defmodule Arbiter.Tasks.IssueReadyTest do
  @moduledoc """
  bd-6zapbl: `Issue.ready/1` — and so `task_ready`, `GET /api/issues/ready`,
  `arb ready` and `arb prime`'s "Ready issues" — returns exactly the tickets
  whose `Lifecycle.view/2` column is `:ready`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Dependency, EdgeGate, Issue, Lifecycle, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rdy-#{System.unique_integer([:positive])}", prefix: "rdy"})

    {:ok, ws: ws}
  end

  defp backlog(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- it works"})

    issue
  end

  defp transition!(issue, action) do
    {:ok, issue} = Ash.update(issue, %{}, action: action)
    issue
  end

  defp queued(ws), do: ws |> backlog() |> transition!(:promote)

  defp verifying(ws),
    do: ws |> queued() |> transition!(:start) |> transition!(:await_verification)

  defp depends_on!(from, to) do
    {:ok, _} =
      Ash.create(Dependency, %{from_issue_id: from.id, to_issue_id: to.id, type: :depends_on})
  end

  defp ready_ids(ws), do: [workspace_id: ws.id] |> Issue.ready() |> MapSet.new(& &1.id)

  test "a backlog ticket with no dependencies is excluded", %{ws: ws} do
    ticket = backlog(ws)
    refute ticket.id in ready_ids(ws)
  end

  test "a queued ticket with no dependencies is included", %{ws: ws} do
    ticket = queued(ws)
    assert ticket.id in ready_ids(ws)
  end

  test "a queued ticket blocked by an open dependency is excluded", %{ws: ws} do
    ticket = queued(ws)
    depends_on!(ticket, queued(ws))

    refute ticket.id in ready_ids(ws)
  end

  test "a queued ticket whose only blocker is verifying is included", %{ws: ws} do
    ticket = queued(ws)
    depends_on!(ticket, verifying(ws))

    assert ticket.id in ready_ids(ws)
  end

  test "a ticket already at work is excluded", %{ws: ws} do
    active = ws |> queued() |> transition!(:start)
    merging = ws |> queued() |> transition!(:start) |> transition!(:open_pr)

    ids = ready_ids(ws)
    refute active.id in ids
    refute merging.id in ids
  end

  test "is exactly the set whose Lifecycle.view column is :ready", %{ws: ws} do
    blocker = queued(ws)
    blocked = queued(ws)
    depends_on!(blocked, blocker)
    _others = [backlog(ws), verifying(ws), ws |> queued() |> transition!(:start)]

    issues = Ash.read!(Issue) |> Enum.filter(&(&1.workspace_id == ws.id))
    blockers = EdgeGate.blockers(Ash.read!(Dependency), issues)

    expected =
      for issue <- issues,
          Lifecycle.view(issue, %{blocked_by: Map.get(blockers, issue.id, [])}).column == :ready,
          into: MapSet.new(),
          do: issue.id

    assert ready_ids(ws) == expected
    assert blocker.id in expected
    refute blocked.id in expected
  end
end
