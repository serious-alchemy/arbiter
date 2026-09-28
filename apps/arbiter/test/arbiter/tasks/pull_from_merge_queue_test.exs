defmodule Arbiter.Tasks.PullFromMergeQueueTest do
  @moduledoc """
  bd-741sid, review round 1 (finding 4): pulling a Merging ticket out of the
  merge queue (`PullRequest.pull/1`, the board's gesture) sticks.

  The pull is recorded on the ticket, and nothing automatic restarts the
  Watchdog that would merge the PR: not `Watchdog.restart/1`, not a finished
  pass (`PullRequest.back_to_merging/1`), not the pending-merge sweeper. (The
  boot reconciler's half is in `Arbiter.Workers.ReconcilerTicketWatchdogTest`.)
  An operator's explicit restart puts it back, and so does a run that re-opens
  the PR.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Mergers.PendingMerge
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workflows.PendingMergeSweeper

  setup do
    StubMerger.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pull-#{System.unique_integer([:positive])}",
        prefix: "pl",
        config: %{"merge" => %{"auto_merge" => true}}
      })

    %{ws: ws}
  end

  # A Merging ticket on the stub forge, on the ReviewGate's lane with
  # auto-merge on: a Watchdog that polled it would merge it.
  defp merging_ticket(ws, mr_ref) do
    {:ok, issue} = Ash.create(Issue, %{title: "pull me", workspace_id: ws.id})
    {:ok, _} = Ash.update(issue, %{status: :in_progress})

    lane =
      PullRequest.lane(
        adapter: StubMerger,
        via_review_gate: true,
        auto_merge: true,
        interval_ms: 15,
        initial_delay_ms: 0
      )

    {:ok, merging} = Issue.pr_opened(issue.id, mr_ref, merge_watch: lane)
    assert merging.state == :merging

    StubMerger.queue_get(mr_ref, [
      %{status: :open, approved: true, pipeline: :running, head_sha: "h1", base_ref: "main"}
    ])

    on_exit(fn ->
      stop(Watchdog.whereis(issue.id))
      stop(Watchdog.retry_whereis(issue.id))
    end)

    merging
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp ticket(id), do: Ash.get!(Issue, id)

  defp green(mr_ref) do
    StubMerger.queue_get(mr_ref, [
      %{status: :open, approved: true, pipeline: :success, head_sha: "h1", base_ref: "main"}
    ])
  end

  defp wait_until(fun, timeout \\ 3_000) do
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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  test "stops the Watchdog, drops the pending merge and records the pull; the PR is untouched",
       %{ws: ws} do
    task = merging_ticket(ws, "!pl1")
    assert :ok = Watchdog.restart(task.id)
    wait_until(fn -> PendingMerge.get(ticket(task.id)) != nil end)

    assert :ok = PullRequest.pull(task.id)

    refute Watchdog.alive?(task.id)
    pulled = ticket(task.id)
    assert PullRequest.pulled?(pulled)
    assert PendingMerge.get(pulled) == nil
    assert {pulled.state, pulled.pr_ref} == {:merging, "!pl1"}
    assert StubMerger.merge_count("!pl1") == 0
  end

  test "no automatic restart undoes it, and nothing merges the PR", %{ws: ws} do
    task = merging_ticket(ws, "!pl2")
    :ok = PullRequest.pull(task.id)
    green("!pl2")

    # The restart every automatic path goes through.
    assert {:error, :pulled} = Watchdog.restart(task.id)
    assert {:conflict, message} = Watchdog.restart_refusal(task.id, :pulled)
    assert message =~ "pulled out of the merge queue"

    # A pass that ends takes the ticket back to Merging, without a Watchdog.
    :ok = Issue.back_to_work(task.id)
    assert ticket(task.id).state == :active
    assert :ok = PullRequest.back_to_merging(task.id)
    assert ticket(task.id).state == :merging
    refute Watchdog.alive?(task.id)

    # A pending merge stamped before the pull landed is not re-armed.
    :ok =
      PendingMerge.stamp(task.id, %{
        mr_ref: "!pl2",
        reviewed_sha: "h1",
        via_review_gate: true,
        reason: :ci_pending
      })

    capture_log(fn ->
      assert %{retried: [], rewatched: [], skipped: skipped} =
               PendingMergeSweeper.sweep(
                 adapter: StubMerger,
                 primary?: fn -> true end,
                 retry_opts: [interval_ms: 15, initial_delay_ms: 0]
               )

      assert {task.id, :pulled} in skipped
    end)

    refute Watchdog.alive?(task.id)
    assert Watchdog.retry_whereis(task.id) == nil
    assert StubMerger.merge_count("!pl2") == 0
    refute task.id in Enum.map(PullRequest.merging_tickets(), & &1.id)
  end

  test "an operator's restart puts it back in the queue", %{ws: ws} do
    task = merging_ticket(ws, "!pl3")
    :ok = PullRequest.pull(task.id)

    assert :ok = Watchdog.restart(task.id, clear_pull: true)

    assert Watchdog.alive?(task.id)
    refute PullRequest.pulled?(ticket(task.id))
    assert task.id in Enum.map(PullRequest.merging_tickets(), & &1.id)
  end

  test "a run that re-opens the PR records a fresh lane, back in the queue", %{ws: ws} do
    task = merging_ticket(ws, "!pl4")
    :ok = PullRequest.pull(task.id)

    {:ok, reopened} =
      Issue.pr_opened(task.id, "!pl4", merge_watch: PullRequest.lane(adapter: StubMerger))

    refute PullRequest.pulled?(reopened)
  end
end
