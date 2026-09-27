defmodule Arbiter.Worker.DispatchLifecycleTest do
  @moduledoc """
  bd-842qio (ticket lifecycle 1/13, AC7): a dispatch moves the ticket to
  `:active` through the `start` transition.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "dl-#{System.unique_integer([:positive])}", prefix: "dl"})

    {:ok, ws: ws}
  end

  defp ticket(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "dispatch me", workspace_id: ws.id, acceptance: "- works"})

    issue
  end

  defp dispatch!(issue) do
    {:ok, result} = Dispatch.dispatch(issue.id, repo: "test/repo", start_driver: false)
    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(Worker.Supervisor, result.worker_pid) end)
    result
  end

  defp actions(issue_id) do
    Issue.Version
    |> Ash.Query.filter(version_source_id == ^issue_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!()
    |> Enum.map(& &1.version_action_name)
  end

  test "dispatching a queued ticket starts it: queued → :active", %{ws: ws} do
    {:ok, queued} = Ash.update(ticket(ws), %{}, action: :promote)

    result = dispatch!(queued)

    assert result.task.state == :active
    assert result.task.status == :in_progress
    assert Ash.get!(Issue, queued.id).state == :active
    assert :start in actions(queued.id)
  end

  test "a review dispatch stamps review_only in the same start", %{ws: ws} do
    {:ok, queued} = Ash.update(ticket(ws), %{}, action: :promote)

    {:ok, result} =
      Dispatch.dispatch(queued.id, repo: "test/repo", start_driver: false, review: true)

    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(Worker.Supervisor, result.worker_pid) end)

    reloaded = Ash.get!(Issue, queued.id)
    assert {reloaded.state, reloaded.review_only} == {:active, true}
  end

  test "a manual dispatch of a Backlog ticket lands on :active too", %{ws: ws} do
    backlog = ticket(ws)
    assert backlog.state == :backlog

    result = dispatch!(backlog)

    assert result.task.state == :active
    assert Ash.get!(Issue, backlog.id).state == :active
  end

  test "re-dispatching an active ticket leaves it :active", %{ws: ws} do
    {:ok, queued} = Ash.update(ticket(ws), %{}, action: :promote)
    first = dispatch!(queued)

    assert {:ok, second} = Dispatch.dispatch(queued.id, repo: "test/repo", start_driver: false)
    assert second.worker_pid == first.worker_pid
    assert second.task.state == :active
  end

  test "a ticket that raced to closed mid-dispatch is reopened and started again", %{ws: ws} do
    {:ok, closed} = Ash.update(ticket(ws), %{}, action: :close)
    live_worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(live_worker, :kill) end)

    assert {:ok, realigned} = Dispatch.realign_task_if_orphaned(closed.id, live_worker)

    assert {realigned.state, realigned.close_reason} == {:active, nil}
    assert Enum.take(actions(closed.id), -2) == [:reopen, :start]
  end
end
