defmodule Arbiter.Worker.DispatchEligibilityTest do
  @moduledoc """
  bd-asxw4e (ticket lifecycle 3/13): `Dispatch.dispatch/2` asks the one
  dispatch-eligibility predicate (`Arbiter.Tasks.Lifecycle.dispatchable/2`).
  A manual dispatch of a Backlog or Blocked ticket is refused with the named
  reason unless forced, and a forced one is recorded as a `dispatch_forced`
  event naming the bypass.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Events.Record
  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  require Ash.Query

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "dispatch-eligibility-#{System.unique_integer([:positive])}",
        prefix: "de#{System.unique_integer([:positive])}"
      })

    on_exit(fn ->
      for w <- Worker.list_children(), w.workspace_id == ws.id do
        _ = Worker.stop(w.task_id, :normal)
      end
    end)

    %{ws: ws}
  end

  defp ticket(ws, title, state) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ok"})

    case state do
      :backlog -> issue
      :queued -> Ash.update!(issue, %{}, action: :promote_to_ready)
    end
  end

  defp depends_on!(from, to) do
    {:ok, _} =
      Ash.create(Dependency, %{from_issue_id: from.id, to_issue_id: to.id, type: :depends_on})
  end

  defp forced_events(ws) do
    Record
    |> Ash.Query.filter(workspace_id == ^ws.id and topic == "dispatch_forced")
    |> Ash.read!()
  end

  defp dispatch(ticket, opts \\ []),
    do: Dispatch.dispatch(ticket.id, Keyword.merge([repo: "r", start_driver: false], opts))

  describe "a manual dispatch" do
    test "of a Backlog ticket is refused, in Backlog, and nothing moves", %{ws: ws} do
      task = ticket(ws, "not refined", :backlog)

      assert {:error, {:not_dispatchable, id, {:column, :backlog} = hold}} = dispatch(task)
      assert id == task.id
      assert Dispatch.refusal_message(id, hold) =~ "#{task.id} is in Backlog"
      assert Dispatch.refusal_message(id, hold) =~ "force"

      assert Ash.get!(Issue, task.id).state == :backlog
      assert Worker.whereis(task.id) == nil
      assert forced_events(ws) == []
    end

    test "of a Blocked ticket is refused, naming its blockers", %{ws: ws} do
      blocker = ticket(ws, "the blocker", :queued)
      task = ticket(ws, "waits on it", :queued)
      depends_on!(task, blocker)

      assert {:error, {:not_dispatchable, _, {:blocked_by, [blocker_id]} = hold}} =
               dispatch(task)

      assert blocker_id == blocker.id
      assert Dispatch.refusal_message(task.id, hold) =~ "blocked by #{blocker.id}"
      assert Ash.get!(Issue, task.id).state == :queued
    end

    test "of a Ready ticket goes ahead, and records no bypass", %{ws: ws} do
      task = ticket(ws, "ready", :queued)

      assert {:ok, result} = dispatch(task)
      assert result.task.state == :active
      assert forced_events(ws) == []
    end

    test "with force bypasses Backlog and records the bypass", %{ws: ws} do
      task = ticket(ws, "forced from backlog", :backlog)

      assert {:ok, result} = dispatch(task, force: true, dispatched_by: "cli")
      assert result.task.state == :active

      assert [event] = forced_events(ws)
      assert event.payload["task_id"] == task.id
      assert event.payload["bypassed"] == "in Backlog"
      assert event.payload["column"] == "backlog"
      assert event.payload["dispatched_by"] == "cli"
    end

    test "with force bypasses open blockers and names them", %{ws: ws} do
      blocker = ticket(ws, "the blocker", :queued)
      task = ticket(ws, "forced past it", :queued)
      depends_on!(task, blocker)

      assert {:ok, _} = dispatch(task, force: true)

      assert [event] = forced_events(ws)
      assert event.payload["bypassed"] == "blocked by #{blocker.id}"
      assert event.payload["blocked_by"] == [blocker.id]
    end

    test "with force on a Ready ticket is a plain dispatch, not a bypass", %{ws: ws} do
      task = ticket(ws, "ready anyway", :queued)

      assert {:ok, _} = dispatch(task, force: true)
      assert forced_events(ws) == []
    end

    test "of a closed ticket is refused, force or not", %{ws: ws} do
      task = ticket(ws, "done", :queued)
      {:ok, _} = Ash.update(task, %{}, action: :close)

      assert {:error, {:task_closed, _}} = dispatch(task)
      assert {:error, {:task_closed, _}} = dispatch(task, force: true)
    end
  end

  describe "an Autopilot dispatch" do
    test "re-checks the column and is never forced", %{ws: ws} do
      blocker = ticket(ws, "the blocker", :queued)
      task = ticket(ws, "blocked since the plan", :queued)
      depends_on!(task, blocker)

      assert {:error, {:task_not_ready, _}} =
               dispatch(task, dispatched_by: "autopilot", force: true)

      assert forced_events(ws) == []
    end
  end
end
