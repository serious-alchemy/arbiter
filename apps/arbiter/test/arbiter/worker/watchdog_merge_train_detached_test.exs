defmodule Arbiter.Worker.WatchdogMergeTrainDetachedTest do
  @moduledoc """
  bd-7jluyk — the worker-less merge retry (`Watchdog.start_retry/1`) takes the
  target's merge slot in the freshness gate like a live poll, so it must give it
  back at the end of every poll: a retry waiting on a transient failure or red CI
  must not freeze every other MR on the target.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.PendingMerge
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.MergeTrain
  alias Arbiter.Worker.Watchdog

  @diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -10,6 +10,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  @transient %Github.Error{kind: :server_error, status: 502, message: "bad gateway"}

  setup do
    StubMerger.reset()

    on_exit(fn ->
      Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h -> {:ok, 0} end)
    end)

    Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h -> {:ok, 0} end)

    ws =
      Ash.create!(Arbiter.Tasks.Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "mt#{System.unique_integer([:positive])}",
        config: %{"merge" => %{"auto_merge" => true}}
      })

    {:ok, ws: ws, key: {ws.id, nil, "main"}}
  end

  defp sha(seed), do: :crypto.hash(:sha, seed) |> Base.encode16(case: :lower)

  defp green(head),
    do: %{status: :open, head_sha: head, base_ref: "main", pipeline: :success, approved: true}

  defp red(head),
    do: %{
      status: :open,
      head_sha: head,
      base_ref: "main",
      pipeline: :failed,
      block_reason: :ci_failed,
      approved: true
    }

  # A task with a pending merge on `mr_ref`, reviewed at `reviewed`.
  defp pending_task(ws, mr_ref, reviewed) do
    task =
      Issue
      |> Ash.create!(%{title: "orphaned merge", description: "body", workspace_id: ws.id})
      |> put_state!(:merging, pr_ref: mr_ref)

    StubMerger.set_diff(mr_ref, reviewed, @diff)

    :ok =
      PendingMerge.stamp(task.id, %{
        mr_ref: mr_ref,
        reviewed_sha: reviewed,
        via_review_gate: true,
        reason: :ci_pending
      })

    task
  end

  defp start_retry(task, mr_ref, ws, reviewed) do
    {:ok, pid} =
      Watchdog.start_retry(
        task_id: task.id,
        mr_ref: mr_ref,
        adapter: StubMerger,
        workspace: ws,
        reviewed_sha: reviewed,
        via_review_gate: true,
        interval_ms: 15,
        initial_delay_ms: 0
      )

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp stop_quietly(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_quietly(_), do: :ok

  defp polls(pid), do: :sys.get_state(pid).poll_count

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
        true -> Process.sleep(10) && :retry
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end

  test "a transient merge failure does not leave the merge slot held", %{ws: ws, key: key} do
    reviewed = sha("transient")
    task = pending_task(ws, "!d1", reviewed)
    StubMerger.queue_get("!d1", [green(reviewed)])
    StubMerger.set_merge_result({:error, @transient})

    pid = start_retry(task, "!d1", ws, reviewed)
    wait_until(fn -> StubMerger.merge_count("!d1") >= 1 and polls(pid) >= 1 end)

    assert :ok = MergeTrain.acquire_merge(key, "another-mr")
    :ok = MergeTrain.release_merge(key, "another-mr")
  end

  test "a retry that took the slot, then sees red CI, frees it for another MR", %{
    ws: ws,
    key: key
  } do
    reviewed = sha("red")
    task = pending_task(ws, "!d2", reviewed)
    # Poll 1: green, so the retry takes the slot and its merge fails; every
    # later poll is red and never reaches the gate again.
    StubMerger.queue_get("!d2", [green(reviewed), red(reviewed)])
    StubMerger.set_merge_result({:error, @transient})

    pid = start_retry(task, "!d2", ws, reviewed)
    wait_until(fn -> StubMerger.merge_count("!d2") >= 1 and polls(pid) >= 3 end)

    assert :ok = MergeTrain.acquire_merge(key, "another-mr")
    :ok = MergeTrain.release_merge(key, "another-mr")
  end

  test "a retry that merges frees the slot and the waiting MR then proceeds", %{ws: ws, key: key} do
    ra = sha("merge-a")
    rb = sha("merge-b")
    a = pending_task(ws, "!da", ra)
    b = pending_task(ws, "!db", rb)
    StubMerger.queue_get("!da", [green(ra)])
    StubMerger.queue_get("!db", [green(rb)])

    # Another MR is mid-merge, so both retries wait on the slot.
    assert :ok = MergeTrain.acquire_merge(key, "someone-else")
    pa = start_retry(a, "!da", ws, ra)
    pb = start_retry(b, "!db", ws, rb)
    wait_until(fn -> polls(pa) >= 3 and polls(pb) >= 3 end)
    assert StubMerger.merge_count("!da") == 0
    assert StubMerger.merge_count("!db") == 0

    :ok = MergeTrain.release_merge(key, "someone-else")

    wait_until(fn ->
      Ash.get!(Issue, a.id).state == :closed and Ash.get!(Issue, b.id).state == :closed
    end)

    # Closed is written before the retry's poll ends; wait for both to exit.
    for p <- [pa, pb] do
      ref = Process.monitor(p)
      assert_receive {:DOWN, ^ref, :process, ^p, _}, 3_000
    end

    assert StubMerger.merge_count("!da") == 1
    assert StubMerger.merge_count("!db") == 1
    assert :ok = MergeTrain.acquire_merge(key, "another-mr")
    :ok = MergeTrain.release_merge(key, "another-mr")
  end
end
