defmodule Arbiter.Tasks.LifecycleProjectionTest do
  @moduledoc """
  bd-6fkgvo (ticket lifecycle 10/13): the read every non-board surface
  projects tickets through — gating blockers, live runs and the Watchdog read
  once, `Lifecycle.view/2` applied, and the JSON shape the CLI, MCP and the
  event stream share.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Attention, Dependencies, Issue, Workspace}
  alias Arbiter.Tasks.Lifecycle.Projection

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "projection-#{System.unique_integer([:positive])}",
        prefix: "pj"
      })

    %{ws: ws}
  end

  defp ticket(ws, attrs) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- it works"}, attrs)
      )

    issue
  end

  defp in_state(ws, state, attrs \\ %{})
  defp in_state(ws, :backlog, attrs), do: ticket(ws, attrs)
  defp in_state(ws, :queued, attrs), do: ws |> in_state(:backlog, attrs) |> transition!(:promote)
  defp in_state(ws, :active, attrs), do: ws |> in_state(:queued, attrs) |> transition!(:start)
  defp in_state(ws, :merging, attrs), do: ws |> in_state(:active, attrs) |> transition!(:open_pr)

  defp in_state(ws, :verifying, attrs),
    do: ws |> in_state(:active, attrs) |> transition!(:await_verification)

  defp in_state(ws, :closed, attrs), do: ws |> in_state(:backlog, attrs) |> transition!(:close)

  defp transition!(issue, transition, args \\ %{}) do
    {:ok, next} = Ash.update(issue, args, action: transition)
    next
  end

  describe "views/2" do
    test "splits :queued into Ready and Blocked from the gating edges", %{ws: ws} do
      blocker = in_state(ws, :queued, %{title: "blocker"})
      blocked = in_state(ws, :queued, %{title: "blocked"})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      views = Projection.views([blocker, blocked], workers: [])

      assert views[blocker.id].column == :ready
      assert views[blocked.id].column == :blocked
      assert views[blocked.id].blocked_by == [blocker.id]
    end

    test "a blocker outside the projected set still gates", %{ws: ws} do
      blocker = in_state(ws, :active, %{title: "blocker"})
      blocked = in_state(ws, :queued, %{title: "blocked"})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      assert %{column: :blocked, blocked_by: [id]} =
               Projection.views([blocked], workers: [])[blocked.id]

      assert id == blocker.id
    end

    test "carries each state's column, the step and the attention", %{ws: ws} do
      tickets = for s <- [:backlog, :active, :merging, :verifying, :closed], do: in_state(ws, s)
      views = Projection.views(tickets, workers: [])

      assert Enum.map(tickets, &views[&1.id].column) ==
               [:backlog, :in_progress, :merging, :verifying, :closed]

      [_, active, merging, verifying, _] = tickets
      assert views[active.id].step == :implementing
      assert views[merging.id].step in [:waiting_ci, :in_merge_queue, :merge_blocked]
      assert %{owner: :coordinator, cause: :awaiting_verification} = views[verifying.id].attention
    end
  end

  describe "view/2" do
    test "one ticket, read with its own blockers", %{ws: ws} do
      blocker = in_state(ws, :backlog)
      blocked = in_state(ws, :queued)
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      assert %{state: :queued, column: :blocked, blocked_by: [_]} =
               Projection.view(blocked, workers: [])
    end
  end

  describe "open/2" do
    test "every non-closed, non-epic ticket in the workspace, in dispatch order", %{ws: ws} do
      low = in_state(ws, :queued, %{priority: 3, title: "low"})
      high = in_state(ws, :queued, %{priority: 0, title: "high"})
      _closed = in_state(ws, :closed)
      _epic = in_state(ws, :queued, %{issue_type: :epic})
      backlog = in_state(ws, :backlog, %{priority: 2})

      {:ok, other_ws} =
        Ash.create(Workspace, %{name: "other-#{System.unique_integer()}", prefix: "ot"})

      _elsewhere = in_state(other_ws, :queued)

      ids = ws.id |> Projection.open(workers: []) |> Enum.map(fn {issue, _view} -> issue.id end)

      assert ids == [high.id, backlog.id, low.id]
    end
  end

  describe "payload/1" do
    test "the JSON-friendly lifecycle fields", %{ws: ws} do
      issue = in_state(ws, :active)
      {:ok, _} = Attention.raise_cause(issue.id, :run_crashed, "boom")
      issue = Ash.get!(Issue, issue.id)

      payload = issue |> Projection.view(workers: []) |> Projection.payload()

      assert payload.state == "active"
      assert payload.column == "in_progress"
      assert payload.step == "implementing"
      assert payload.blocked_by == []
      assert payload.attention.owner == "coordinator"
      assert payload.attention.cause == "run_crashed"
      assert is_binary(payload.attention.reason)
    end

    test "nil attention and nil step stay nil", %{ws: ws} do
      payload = ws |> in_state(:queued) |> Projection.view(workers: []) |> Projection.payload()

      assert payload.column == "ready"
      assert payload.step == nil
      assert payload.attention == nil
    end
  end
end
