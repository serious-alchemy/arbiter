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

  defp cut_off_run!(ws, ticket, kind) do
    {:ok, run} =
      Ash.create(Arbiter.Workers.Run, %{
        task_id: ticket.id,
        repo: "rt/repo",
        workspace_id: ws.id,
        kind: kind,
        state: :finished,
        outcome: :interrupted,
        failure_reason: "server shutdown",
        started_at: DateTime.utc_now()
      })

    run
  end

  defp recording_pass_fun(result \\ :ok) do
    test = self()

    fn task_id, kind, opts ->
      send(test, {:queued, task_id, kind, opts})
      result
    end
  end

  # bd-7s6y2j: a conflict pass live at shutdown is handed to the scheduler's
  # queue, held for local capacity, rather than waiting on the Watchdog to
  # re-observe an approved, conflicting PR.
  test "a Merging ticket's cut-off conflict pass is queued held for local capacity", %{ws: ws} do
    ticket = merging_ticket(ws, "!rp")
    cut_off_run!(ws, ticket, :conflict)

    Logger.put_module_level(Reconciler, :info)
    on_exit(fn -> Logger.delete_module_level(Reconciler) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert {:ok, %{watched: 1, escalated: 0, passes: [pass]}} =
                 Reconciler.reconcile_open_pr_tasks(pass_fun: recording_pass_fun())

        assert pass == %{task_id: ticket.id, kind: :conflict, outcome: :queued}
      end)

    ticket_id = ticket.id
    pr_ref = ticket.pr_ref
    ws_id = ws.id

    assert_received {:queued, ^ticket_id, :conflict, opts}
    assert opts[:held_for] == :local_capacity
    assert opts[:resume_origin] == :automatic
    assert %{task_id: ^ticket_id, workspace_id: ^ws_id, pr_ref: ^pr_ref} = opts[:args]

    assert log =~ "cut-off pass"
    assert log =~ ticket.id
    assert Watchdog.alive?(ticket.id)
  end

  test "a cut-off conflict pass that cannot be queued is escalated, not dropped", %{ws: ws} do
    ticket = merging_ticket(ws, "!rs")
    cut_off_run!(ws, ticket, :conflict)

    assert {:ok, %{escalated: 1, passes: [pass]}} =
             Reconciler.reconcile_open_pr_tasks(
               pass_fun: recording_pass_fun({:error, :not_running})
             )

    assert pass == %{task_id: ticket.id, kind: :conflict, outcome: :escalated}
    assert Message.inbox(Message.coordinator_ref(), workspace_id: ws.id) != []
  end

  test "a cut-off conflict pass is listed on a ticket whose Watchdog already runs", %{ws: ws} do
    ticket = merging_ticket(ws, "!rt")
    cut_off_run!(ws, ticket, :conflict)
    assert :ok = Watchdog.restart(ticket.id)

    assert {:ok, %{watched: 0, passes: [pass]}} =
             Reconciler.reconcile_open_pr_tasks(pass_fun: recording_pass_fun())

    assert pass == %{task_id: ticket.id, kind: :conflict, outcome: :queued}
  end

  # A fix pass needs the failing checks only the Watchdog's poll has, so its
  # restarted Watchdog asks for it again; the sweep lists it.
  test "a Merging ticket's cut-off fix_pass is listed as watched, not queued directly",
       %{ws: ws} do
    ticket = merging_ticket(ws, "!rf")
    cut_off_run!(ws, ticket, :fix_pass)

    assert {:ok, %{watched: 1, passes: [pass]}} =
             Reconciler.reconcile_open_pr_tasks(pass_fun: recording_pass_fun())

    assert pass == %{task_id: ticket.id, kind: :fix_pass, outcome: :watched}
    refute_received {:queued, _, _, _}
  end

  test "the resume sweep's line counts the cut-off passes it is handed", %{ws: ws} do
    ticket = merging_ticket(ws, "!ru")
    passes = [%{task_id: ticket.id, kind: :conflict, outcome: :queued}]

    Logger.put_module_level(Reconciler, :info)
    on_exit(fn -> Logger.delete_module_level(Reconciler) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        assert {:ok, %{resumed: 0}} =
                 Reconciler.reconcile_resumable_tasks(
                   cut_off_passes: passes,
                   resume_fun: fn _ -> {:ok, %{}} end
                 )
      end)

    assert log =~ "resume sweep"
    assert log =~ "#{ticket.id} (conflict: queued)"
  end

  test "a Merging ticket whose last run finished normally lists no cut-off pass", %{ws: ws} do
    _ = merging_ticket(ws, "!rq")
    assert {:ok, %{watched: 1, passes: []}} = Reconciler.reconcile_open_pr_tasks()
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
