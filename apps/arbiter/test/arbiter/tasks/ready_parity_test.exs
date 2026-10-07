defmodule Arbiter.Tasks.ReadyParityTest do
  @moduledoc """
  P-13 (D-T-16): there is one "Ready". A `:queued` ticket whose run registered
  before dispatch's `start` transition landed is `in_progress` to the board, so
  it is not Ready on `Issue.ready/1`, the MCP `ticket_ready` tool or
  `Projection.ready/2` — none of them, not just one.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle.Projection
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rdyp-#{System.unique_integer([:positive])}", prefix: "rp"})

    {:ok, a} =
      Ash.create(Issue, %{title: "a", workspace_id: ws.id, acceptance: "- ok", priority: 2})

    {:ok, b} =
      Ash.create(Issue, %{title: "b", workspace_id: ws.id, acceptance: "- ok", priority: 1})

    a = promote!(a)
    b = promote!(b)

    %{ws: ws, a: a, b: b, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id}}
  end

  defp promote!(issue) do
    {:ok, issue} = Ash.update(issue, %{}, action: :promote)
    issue
  end

  defp ready_ids(ws), do: [workspace_id: ws.id] |> Issue.ready() |> Enum.map(& &1.id)

  test "without a registered run both tickets are Ready, in dispatch order", ctx do
    assert ready_ids(ctx.ws) == [ctx.b.id, ctx.a.id]
  end

  test "Issue.ready/1 is the Projection.ready/2 set, in the same order", ctx do
    assert ready_ids(ctx.ws) ==
             ctx.ws.id |> Projection.ready() |> Enum.map(fn {issue, _view} -> issue.id end)
  end

  test "a queued ticket with an early-registered run is Ready on no surface", ctx do
    {:ok, pid} = Worker.start(task_id: ctx.a.id, repo: "arbiter", workspace_id: ctx.ws.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    # The stored state is still `queued`: the run beat the `start` transition.
    assert {:ok, %{state: :queued}} = Ash.get(Issue, ctx.a.id)

    assert ready_ids(ctx.ws) == [ctx.b.id]

    assert [ctx.b.id] ==
             ctx.ws.id |> Projection.ready() |> Enum.map(fn {issue, _view} -> issue.id end)

    assert {:ok, %{tasks: tasks, count: 1}} = Tools.task_ready(ctx.coordinator, %{})
    assert Enum.map(tasks, & &1.id) == [ctx.b.id]
  end

  test "an explicit :workers list overrides the live read", ctx do
    workers = [%{task_id: ctx.b.id, state: :running, agent_live: true}]

    assert [ctx.a.id] ==
             [workspace_id: ctx.ws.id, workers: workers] |> Issue.ready() |> Enum.map(& &1.id)
  end
end
