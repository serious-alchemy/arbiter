defmodule Arbiter.Worker.ResumeMergingTicketTest do
  @moduledoc """
  bd-741sid, review round 1 (finding 1): a resume of a Merging ticket — a
  revise round on its open PR — takes the PR off the merge path before the
  ticket goes back to work.

  The ticket's Watchdog belongs to the ticket, not to any run, so a resume no
  longer stops it by stopping a parked worker. Left running, it merged the
  very head the round was resumed to revise, and the ticket's close then
  killed the round. Driven end to end with a real `Dispatch.resume/2` on a
  real repo (`Arbiter.Test.ResumeSlotFixture`), a real Watchdog, and the
  stub forge.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Mergers.PendingMerge
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.{ResumeSlotFixture, StubMerger}
  alias Arbiter.Worker
  alias Arbiter.Worker.{Dispatch, Watchdog}
  alias Arbiter.Workflows.PendingMergeSweeper

  setup do
    StubMerger.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-merging-#{System.unique_integer([:positive])}",
        prefix: "rmt#{System.unique_integer([:positive])}",
        config: %{"merge" => %{"auto_merge" => true}}
      })

    ResumeSlotFixture.setup_repo!()
    {:ok, task} = Ash.create(Issue, %{title: "revise its PR", workspace_id: ws.id})

    # Dispatched, then its PR opened: Merging, with the PR on the row.
    ResumeSlotFixture.park!(task)
    merging = ticket(task.id)
    assert merging.state == :merging
    on_exit(fn -> stop_quietly(Watchdog.whereis(task.id)) end)

    %{ws: ws, task: merging, mr_ref: merging.pr_ref}
  end

  defp ticket(id), do: Ash.get!(Issue, id)

  defp stop_quietly(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp stop_quietly(_), do: :ok

  # The lane the PR open records: the ReviewGate approved it, and the
  # workspace merges on approval.
  defp record_lane!(task, overrides \\ []) do
    lane =
      PullRequest.lane(
        Keyword.merge(
          [
            adapter: StubMerger,
            via_review_gate: true,
            auto_merge: true,
            interval_ms: 15,
            initial_delay_ms: 0
          ],
          overrides
        )
      )

    Ash.update!(ticket(task.id), %{merge_watch: lane}, action: :record_merge_watch)
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

  test "a resume stops the ticket's Watchdog, so the PR is not merged under the revise round",
       %{task: task, mr_ref: mr_ref} do
    record_lane!(task)

    # Approved, CI still running: the Watchdog waits to merge and stamps the
    # pending merge.
    StubMerger.queue_get(mr_ref, [
      %{status: :open, approved: true, pipeline: :running, head_sha: "h1"}
    ])

    assert :ok = Watchdog.restart(task.id)
    wait_until(fn -> PendingMerge.get(ticket(task.id)) != nil end)

    assert {:ok, result} =
             Dispatch.resume(task.id,
               revise_feedback: "address the review",
               start_driver: false,
               claude_command: ["sleep", "5"]
             )

    # The PR is off the merge path before the ticket is back at work: no
    # Watchdog, no pending merge for the sweeper to re-arm.
    assert Watchdog.whereis(task.id) == nil
    assert ticket(task.id).state == :active
    assert PendingMerge.get(ticket(task.id)) == nil
    assert Worker.state(result.worker_pid).status not in [:failed, :completed]

    # CI goes green on the head the round is revising. Nothing merges it.
    StubMerger.queue_get(mr_ref, [
      %{status: :open, approved: true, pipeline: :success, head_sha: "h1"}
    ])

    assert %{retried: [], rewatched: []} =
             PendingMergeSweeper.sweep(
               adapter: StubMerger,
               primary?: fn -> true end,
               retry_opts: [interval_ms: 15, initial_delay_ms: 0]
             )

    assert Watchdog.whereis(task.id) == nil
    assert Watchdog.retry_whereis(task.id) == nil
    assert StubMerger.merge_count(mr_ref) == 0
    assert ticket(task.id).state == :active
    assert Worker.whereis(task.id) == result.worker_pid
  end

  # The Watchdog's own auto-resume runs `Dispatch.resume/2` inside the
  # Watchdog, so the stop above is asked of the process making the call. It
  # stands down by itself once the resume has started the round.
  test "a Watchdog's own auto-resume takes the ticket back to work, then the Watchdog stops",
       %{task: task, mr_ref: mr_ref} do
    record_lane!(task, max_polls: 2)

    StubMerger.queue_get(mr_ref, [
      %{status: :open, approved: true, pipeline: :running, head_sha: "h1"}
    ])

    task_id = task.id
    :ok = Watchdog.subscribe(task_id)
    assert :ok = Watchdog.restart(task_id)
    wd = Watchdog.whereis(task_id)
    ref = Process.monitor(wd)

    assert_receive {:watchdog, ^task_id, {:timed_out, 2}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^wd, :normal}, 10_000

    resumed = Worker.whereis(task_id)
    assert is_pid(resumed)
    assert Worker.state(resumed).meta[:resume] == true
    assert Worker.state(resumed).meta[:awaiting_review_resume_attempts] == 1
    assert ticket(task_id).state == :active
    assert Watchdog.whereis(task_id) == nil
    assert StubMerger.merge_count(mr_ref) == 0
  end
end
