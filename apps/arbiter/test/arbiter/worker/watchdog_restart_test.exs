defmodule Arbiter.Worker.WatchdogRestartTest do
  @moduledoc """
  bd-8jixav: a Watchdog GenServer can die outright — crash, or fail to start
  after the MR was already opened — leaving a genuinely-open MR that nothing is
  polling.

  `retry_auto_resolve/1` (bd-bspakl) cannot recover this: it messages an
  *already-running* Watchdog. These cases pin `Watchdog.restart/1`, which mints
  a **fresh** Watchdog against the ticket's existing MR ref without going
  through a full `worker_resume` (which would restart the review gate from
  round 1 at real cost).

  bd-741sid: the ticket owns the PR and its Watchdog's lane, and no worker
  stays resident once the PR is open — so a restart works from the ticket row
  alone. `watchdog_start_error: true` on `open_mr/5` reproduces the incident
  state exactly: MR open on the forge and on the ticket, the run ended, no
  Watchdog registered.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Test.StubMerger

  setup do
    StubMerger.reset()
    :ok
  end

  defp new_workspace(config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wd-restart-ws-#{System.unique_integer([:positive])}",
        prefix: "wr",
        config: config
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "watchdog restart task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    task = put_state!(task, :active)
    on_exit(fn -> stop_watchdog(task.id) end)
    task
  end

  defp stop_watchdog(task_id) do
    case Watchdog.whereis(task_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  # Open an MR whose Watchdog fails to start — the dead-watchdog state this
  # ticket is about. The run ends with the PR open; nothing watches it.
  defp opened_without_watchdog(task, ws, mr_ref, opts \\ %{}) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "wr/repo", workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    ref = Process.monitor(pid)
    StubMerger.next_open_ref(mr_ref)

    {:ok, ^mr_ref} =
      Worker.open_mr(
        pid,
        "feature/#{mr_ref}",
        "MR #{mr_ref}",
        "desc",
        Map.merge(
          %{
            adapter: StubMerger,
            workspace: ws,
            interval_ms: 20,
            initial_delay_ms: 0,
            watchdog_start_error: true
          },
          opts
        )
      )

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert Ash.get!(Issue, task.id).state == :merging
    assert Watchdog.whereis(task.id) == nil
    :ok
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  describe "restart/1" do
    test "a Watchdog that fails to start at PR open pages the coordinator with the remedy" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr0", [%{status: :open, approved: false}])
      opened_without_watchdog(task, ws, "!wr0")

      assert [page] =
               ws.id
               |> then(&Message.inbox(Message.coordinator_ref(), workspace_id: &1))
               |> Enum.filter(&(&1.task_ref == task.id))

      assert page.subject =~ "Watchdog startup failed"
      assert page.body =~ "arb queue restart-watchdog #{task.id}"
    end

    test "mints a fresh Watchdog against the ticket's existing MR ref" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr1", [%{status: :open, approved: false}])
      opened_without_watchdog(task, ws, "!wr1")

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)

      # It is genuinely polling the *existing* MR, not a new one.
      wait_until(fn -> StubMerger.get_count("!wr1") >= 1 end)
    end

    test "the restarted Watchdog carries the ticket through to completion" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr2", [%{status: :merged}])
      opened_without_watchdog(task, ws, "!wr2")

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> Ash.get!(Issue, task.id).state == :closed end)
    end

    test "refuses when a Watchdog is already running (never two live watchdogs)" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr3", [%{status: :open, approved: false}])
      opened_without_watchdog(task, ws, "!wr3")

      assert :ok = Watchdog.restart(task.id)
      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)
      wpid = Watchdog.whereis(task.id)

      assert {:error, :already_running} = Watchdog.restart(task.id)
      # ...and the original is untouched.
      assert Watchdog.whereis(task.id) == wpid
    end

    test "returns :not_found for a ticket that does not exist" do
      assert Watchdog.restart("no-such-task-#{System.unique_integer([:positive])}") ==
               {:error, :not_found}
    end

    test "refuses a ticket with no PR on its row" do
      ws = new_workspace()
      task = new_task(ws)

      assert Watchdog.restart(task.id) == {:error, :no_mr_ref}
    end

    test "replays the via_review_gate lane recorded when the MR was opened" do
      # auto_merge on, gate-approved: the Watchdog must treat an unapproved
      # forge poll as approved and merge. A restart that lost via_review_gate
      # would park forever waiting on a forge approval the gate never posts —
      # the exact vs-3vlaqi failure mode.
      ws = new_workspace(%{"merge" => %{"auto_merge" => true}})
      task = new_task(ws)
      StubMerger.queue_get("!wr4", [%{status: :open, approved: false}])
      opened_without_watchdog(task, ws, "!wr4", %{via_review_gate: true})

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> StubMerger.merge_count("!wr4") >= 1 end)
    end

    test "recovers a Watchdog that crashed after polling had already started" do
      ws = new_workspace()
      task = new_task(ws)
      StubMerger.queue_get("!wr5", [%{status: :open, approved: false}])
      opened_without_watchdog(task, ws, "!wr5")

      assert :ok = Watchdog.restart(task.id)
      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)
      first = Watchdog.whereis(task.id)

      # Simulate the incident: the Watchdog dies outright, silently.
      Process.exit(first, :kill)
      wait_until(fn -> Watchdog.whereis(task.id) == nil end)

      assert :ok = Watchdog.restart(task.id)
      wait_until(fn -> is_pid(Watchdog.whereis(task.id)) end)
      second = Watchdog.whereis(task.id)

      refute second == first
    end
  end
end
