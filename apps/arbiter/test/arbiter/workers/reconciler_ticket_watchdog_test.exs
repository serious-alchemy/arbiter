defmodule Arbiter.Workers.ReconcilerTicketWatchdogTest do
  @moduledoc """
  bd-741sid (ticket lifecycle 4/13), acceptance 8: after a reboot the open-PR
  sweep (`Reconciler.reconcile_open_pr_tasks/1`) starts a ticket Watchdog for
  every `:merging` ticket that has none, from the row alone — instead of
  handing it to the patrols or escalating it.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workers.Reconciler

  setup do
    StubMerger.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rtw-#{System.unique_integer([:positive])}",
        prefix: "rt"
      })

    %{ws: ws}
  end

  # A Merging ticket whose PR is on its row and which nothing is watching —
  # what a reboot leaves behind.
  defp merging_ticket(ws, mr_ref) do
    {:ok, issue} = Ash.create(Issue, %{title: "open PR", workspace_id: ws.id})
    put_state!(issue, :active)

    lane = PullRequest.lane(adapter: StubMerger, interval_ms: 60_000, initial_delay_ms: 60_000)
    {:ok, merging} = Issue.pr_opened(issue.id, mr_ref, merge_watch: lane)
    assert merging.state == :merging

    on_exit(fn -> stop(Watchdog.whereis(issue.id)) end)
    merging
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  test "starts a Watchdog for every Merging ticket that has none, without escalating", %{ws: ws} do
    a = merging_ticket(ws, "!ra")
    b = merging_ticket(ws, "!rb")
    refute Watchdog.alive?(a.id)
    refute Watchdog.alive?(b.id)

    patrol = fn issue -> flunk("#{issue.id} was handed to the patrols") end

    assert {:ok, %{watched: 2, rewatched: 0, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(rewatch_fun: patrol)

    assert Watchdog.alive?(a.id)
    assert Watchdog.alive?(b.id)
    assert Message.inbox(Message.coordinator_ref(), workspace_id: ws.id) == []
  end

  test "leaves a Merging ticket whose Watchdog is running alone", %{ws: ws} do
    ticket = merging_ticket(ws, "!rc")
    :ok = Watchdog.restart(ticket.id)
    running = Watchdog.whereis(ticket.id)

    assert {:ok, %{watched: 0, rewatched: 0, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks()

    assert Watchdog.whereis(ticket.id) == running
  end

  test "a ticket whose fix pass the restart cut off goes back to Merging and is watched",
       %{ws: ws} do
    ticket = merging_ticket(ws, "!re")
    {:ok, active} = Ash.update(ticket, %{}, action: :return_to_work)
    assert active.state == :active

    {:ok, _run} =
      Ash.create(Arbiter.Workers.Run, %{
        task_id: ticket.id,
        repo: "rt/repo",
        workspace_id: ws.id,
        kind: :fix_pass,
        state: :finished,
        outcome: :interrupted,
        failure_reason: "server shutdown",
        started_at: DateTime.utc_now()
      })

    patrol = fn issue -> flunk("#{issue.id} was handed to the patrols") end

    assert {:ok, %{watched: 1, rewatched: 0, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(rewatch_fun: patrol)

    assert Ash.get!(Issue, ticket.id).state == :merging
    assert Watchdog.alive?(ticket.id)
  end

  # bd-741sid, review round 1 (finding 4): a reboot does not undo an
  # operator's pull out of the merge queue.
  test "leaves a Merging ticket pulled out of the merge queue unwatched, paging no one",
       %{ws: ws} do
    ticket = merging_ticket(ws, "!rp")
    :ok = PullRequest.pull(ticket.id)

    patrol = fn issue -> flunk("#{issue.id} was handed to the patrols") end

    assert {:ok, %{watched: 0, rewatched: 0, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(rewatch_fun: patrol)

    refute Watchdog.alive?(ticket.id)
    assert Ash.get!(Issue, ticket.id).state == :merging
    assert Message.inbox(Message.coordinator_ref(), workspace_id: ws.id) == []
  end

  test "falls back to the patrols when the Watchdog cannot start", %{ws: ws} do
    ticket = merging_ticket(ws, "!rd")
    test_pid = self()

    assert {:ok, %{watched: 0, rewatched: 1, escalated: 0}} =
             Reconciler.reconcile_open_pr_tasks(
               watch_fun: fn _issue -> {:error, :no_adapter} end,
               rewatch_fun: fn issue ->
                 send(test_pid, {:patrol, issue.id})
                 :ok
               end
             )

    assert_received {:patrol, id}
    assert id == ticket.id
  end
end
