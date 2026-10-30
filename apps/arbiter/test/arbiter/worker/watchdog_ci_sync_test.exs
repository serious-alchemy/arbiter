defmodule Arbiter.Worker.WatchdogCiSyncTest do
  @moduledoc """
  bd-5owt7w — a CI-failure remediation (fix pass, flake re-run, `ci_rerun`)
  first brings a stale MR branch up to its target, holds while the target's own
  pipeline is red, and an exhausted lane stays re-wakeable.
  """
  # async: false — shared sandbox with the Watchdog process, singleton stubs and
  # the app-env freshness probe.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.CiSync
  alias Arbiter.Worker.Watchdog

  # The reviewed net diff, and the same content after the target was merged in:
  # the synced head is "the reviewed content plus the target", so the merge-time
  # reviewed-SHA guard lets it through without a new review.
  @reviewed_diff """
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

  @merge_from_main_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  defp reviewed_then_synced(ref) do
    StubMerger.set_diff(ref, "old", @reviewed_diff)
    StubMerger.set_diff(ref, "synced", @merge_from_main_diff)
  end

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    StubAutoResumeDispatcher.reset()

    on_exit(fn ->
      Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h -> {:ok, 0} end)
    end)

    :ok
  end

  # `behind` maps head sha -> commits of the target that head lacks.
  defp probe(behind) do
    Application.put_env(:arbiter, :merge_freshness_probe, fn _repo, _base, head ->
      {:ok, Map.fetch!(behind, head)}
    end)
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp new_task_id, do: "ci-sync-test-#{System.unique_integer([:positive])}"

  defp test_workspace do
    %Arbiter.Tasks.Workspace{id: "ws-#{System.unique_integer([:positive])}", config: %{}}
  end

  defp start_watchdog(task_id, mr_ref, opts \\ []) do
    base = [
      task_id: task_id,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: test_workspace(),
      auto_merge: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      fix_pass_dispatcher: StubFixPassDispatcher,
      auto_resume_dispatcher: StubAutoResumeDispatcher
    ]

    :ok = Watchdog.subscribe(task_id)
    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
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

  defp red(head),
    do: %{
      status: :open,
      approved: true,
      block_reason: :ci_failed,
      pipeline: :failed,
      head_sha: head,
      base_ref: "main"
    }

  defp green(head),
    do: %{
      status: :open,
      approved: true,
      ci_clean: true,
      pipeline: :success,
      head_sha: head,
      base_ref: "main"
    }

  defp running(head),
    do: %{status: :open, approved: true, pipeline: :running, head_sha: head, base_ref: "main"}

  describe "a CI-failure fix pass on a branch the target has outrun" do
    test "syncs first and, when the synced head passes, never dispatches the agent" do
      task_id = new_task_id()
      probe(%{"old" => 4, "synced" => 0})

      StubMerger.queue_get("!cs1", [
        red("old"),
        # the forge has not shown the sync commit yet: must not sync again
        red("old"),
        running("synced"),
        green("synced")
      ])

      reviewed_then_synced("!cs1")
      start_watchdog(task_id, "!cs1", last_reviewed_sha: "old")

      assert_receive {:watchdog, ^task_id, {:merged, _}}, 3_000
      assert StubMerger.update_branch_count("!cs1") == 1
      assert StubFixPassDispatcher.call_count() == 0
      assert StubMerger.merge_count("!cs1") == 1
    end

    test "the sync spends no auto-resolve attempt: the budget is intact for the synced head" do
      task_id = new_task_id()
      probe(%{"old" => 2, "synced" => 0})

      # A budget of ONE attempt. If the sync had consumed it, the synced head's
      # failure would park instead of dispatching.
      StubMerger.queue_get("!cs2", [red("old"), running("synced"), red("synced")])

      wpid = start_watchdog(task_id, "!cs2", max_auto_resolve_attempts: 1)

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert StubMerger.update_branch_count("!cs2") == 1
      assert StubFixPassDispatcher.call_count() == 1
      # The one fix pass is the first and only attempt; the sync was not counted.
      assert :sys.get_state(wpid).auto_resolve_attempts == 1
    end

    test "a head that is current with the target goes straight to the fix pass" do
      task_id = new_task_id()
      probe(%{"cur" => 0})
      StubMerger.queue_get("!cs3", [red("cur")])

      start_watchdog(task_id, "!cs3")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert StubMerger.update_branch_count("!cs3") == 0
    end

    test "a sync that does not apply holds the dispatch and pages as a conflict, once" do
      task_id = new_task_id()
      probe(%{"old" => 3})
      StubMerger.set_update_branch_result({:error, :conflict})
      StubMerger.queue_get("!cs4", [red("old")])

      wpid = start_watchdog(task_id, "!cs4")

      wait_until(fn -> :sys.get_state(wpid).last_block_reason == :conflict end)
      Process.sleep(80)
      assert StubFixPassDispatcher.call_count() == 0
      assert StubMerger.update_branch_count("!cs4") == 1
      assert :sys.get_state(wpid).auto_resolve_attempts == 0
    end

    test "a probe that cannot tell fails open: the fix pass is not held" do
      task_id = new_task_id()

      Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h ->
        {:error, :no_repo}
      end)

      StubMerger.queue_get("!cs5", [red("old")])

      start_watchdog(task_id, "!cs5")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert StubMerger.update_branch_count("!cs5") == 0
    end
  end

  describe "a :no_pipeline block on a branch the target has outrun" do
    defp no_pipeline(head),
      do: %{
        status: :open,
        approved: true,
        block_reason: :no_pipeline,
        pipeline: nil,
        head_sha: head,
        base_ref: "main"
      }

    test "syncs once, polls the new head, and merges when the synced head has a pipeline" do
      task_id = new_task_id()
      probe(%{"old" => 4, "synced" => 0})

      StubMerger.queue_get("!np1", [
        no_pipeline("old"),
        # the forge has not shown the sync commit yet: must not sync again
        no_pipeline("old"),
        running("synced"),
        green("synced")
      ])

      reviewed_then_synced("!np1")
      start_watchdog(task_id, "!np1", last_reviewed_sha: "old")

      assert_receive {:watchdog, ^task_id, {:merged, _}}, 3_000
      assert StubMerger.update_branch_count("!np1") == 1
    end

    test "a synced head that still has no pipeline escalates and parks, no sync loop" do
      task_id = new_task_id()
      probe(%{"old" => 4, "synced" => 0})
      StubMerger.queue_get("!np2", [no_pipeline("old"), no_pipeline("synced")])

      wpid = start_watchdog(task_id, "!np2")

      wait_until(fn -> :sys.get_state(wpid).park_reason == :no_pipeline end)
      wait_until(fn -> StubMerger.get_count("!np2") >= 6 end)
      assert StubMerger.update_branch_count("!np2") == 1
      assert StubMerger.merge_count("!np2") == 0
    end

    test "a head already current with the target escalates without syncing" do
      task_id = new_task_id()
      probe(%{"cur" => 0})
      StubMerger.queue_get("!np3", [no_pipeline("cur")])

      wpid = start_watchdog(task_id, "!np3")

      wait_until(fn -> :sys.get_state(wpid).park_reason == :no_pipeline end)
      assert StubMerger.update_branch_count("!np3") == 0
    end
  end

  describe "ci_rerun on a stale branch" do
    test "syncs instead of re-running the old head" do
      task_id = new_task_id()
      probe(%{"old" => 5})
      StubMerger.queue_get("!cr1", [running("old")])

      start_watchdog(task_id, "!cr1")
      wait_until(fn -> StubMerger.get_count("!cr1") >= 1 end)

      assert {:ok, result} = Watchdog.rerun_ci(task_id, %{})
      assert result.action == :synced
      assert result.behind == 5
      assert StubMerger.update_branch_count("!cr1") == 1
      assert StubMerger.ci_reruns() == []
    end

    test "re-runs normally when the head is current" do
      task_id = new_task_id()
      probe(%{"cur" => 0})
      StubMerger.queue_get("!cr2", [running("cur")])

      start_watchdog(task_id, "!cr2")
      wait_until(fn -> StubMerger.get_count("!cr2") >= 1 end)

      assert {:ok, _} = Watchdog.rerun_ci(task_id, %{})
      assert StubMerger.update_branch_count("!cr2") == 0
      assert [{"!cr2", _}] = StubMerger.ci_reruns()
    end

    test "CiSync.rerun/4 (the no-Watchdog path) syncs a stale head too" do
      probe(%{"old" => 2})
      StubMerger.queue_get("!cr3", [running("old")])

      assert {:ok, %{action: :synced}} =
               CiSync.rerun(StubMerger, "!cr3", %{}, %{
                 workspace: test_workspace(),
                 repo: nil
               })

      assert StubMerger.update_branch_count("!cr3") == 1
      assert StubMerger.ci_reruns() == []
    end
  end

  describe "the target branch's own pipeline is red" do
    test "holds the MR: no sync, no attempt, no fix pass; names the target pipeline" do
      task_id = new_task_id()
      probe(%{"old" => 4, "synced" => 0})

      StubMerger.set_branch_pipeline(
        {:ok, %{id: 777, sha: "abc", status: "failed", url: "https://ci/777"}}
      )

      StubMerger.queue_get("!th1", [red("old")])

      wpid = start_watchdog(task_id, "!th1")

      wait_until(fn -> :sys.get_state(wpid).ci_hold != nil end)
      Process.sleep(80)

      state = :sys.get_state(wpid)
      assert state.ci_hold =~ "target branch red"
      assert state.ci_hold =~ "777"
      assert state.auto_resolve_attempts == 0
      assert StubFixPassDispatcher.call_count() == 0
      assert StubMerger.update_branch_count("!th1") == 0
      assert {"!th1", "main"} in StubMerger.branch_pipeline_calls()
      assert Watchdog.ci_hold(task_id) =~ "target branch red"
    end

    test "resumes when the target is green: syncs, then lets CI run on the synced head" do
      task_id = new_task_id()
      probe(%{"old" => 4, "synced" => 0})

      StubMerger.set_branch_pipeline({:ok, %{id: 777, sha: "abc", status: "failed", url: nil}})
      StubMerger.queue_get("!th2", [red("old"), red("old"), running("synced"), green("synced")])

      reviewed_then_synced("!th2")
      wpid = start_watchdog(task_id, "!th2", last_reviewed_sha: "old")
      wait_until(fn -> :sys.get_state(wpid).ci_hold != nil end)

      StubMerger.set_branch_pipeline({:ok, %{id: 778, sha: "def", status: "success", url: nil}})

      assert_receive {:watchdog, ^task_id, {:merged, _}}, 3_000
      assert StubMerger.update_branch_count("!th2") == 1
      assert StubFixPassDispatcher.call_count() == 0
    end

    test "a held MR does not trip the poll ceiling" do
      task_id = new_task_id()
      probe(%{"old" => 0})
      StubMerger.set_branch_pipeline({:ok, %{id: 1, sha: "a", status: "failed", url: nil}})
      StubMerger.queue_get("!th3", [red("old")])

      wpid = start_watchdog(task_id, "!th3", max_polls: 5)

      wait_until(fn -> StubMerger.get_count("!th3") >= 12 end)
      assert Process.alive?(wpid)
      refute_received {:watchdog, ^task_id, {:timed_out, _}}
    end

    test "an unreadable target pipeline fails open" do
      task_id = new_task_id()
      probe(%{"old" => 0})
      StubMerger.set_branch_pipeline({:error, :boom})
      StubMerger.queue_get("!th4", [red("old")])

      start_watchdog(task_id, "!th4")
      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    end
  end

  describe "an exhausted lane stays re-wakeable (the vs-9pdgfr gap)" do
    test "exhausting auto-resolve stamps the durable pending merge, so the sweeper can re-wake it" do
      ws =
        Ash.create!(Arbiter.Tasks.Workspace, %{
          name: "ws-#{System.unique_integer([:positive])}",
          prefix: "cs#{System.unique_integer([:positive])}",
          config: %{}
        })

      task =
        Ash.create!(Issue, %{title: "exhausted", description: "body", workspace_id: ws.id})

      probe(%{"h" => 0})
      StubMerger.queue_get("!ex1", [red("h")])

      wpid =
        start_watchdog(task.id, "!ex1", workspace: ws, max_auto_resolve_attempts: 1)

      wait_until(fn -> :sys.get_state(wpid).park_reason == :ci_failed end)

      wait_until(fn ->
        match?(%{reason: "ci_failed"}, Arbiter.Mergers.PendingMerge.get(Ash.get!(Issue, task.id)))
      end)

      assert %{mr_ref: "!ex1", escalated_at: nil} =
               Arbiter.Mergers.PendingMerge.get(Ash.get!(Issue, task.id))
    end
  end
end
