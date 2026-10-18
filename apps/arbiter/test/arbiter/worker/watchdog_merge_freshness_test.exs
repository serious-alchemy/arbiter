defmodule Arbiter.Worker.WatchdogMergeFreshnessTest do
  @moduledoc """
  bd-5z9yvb — the Watchdog syncs an approved branch that lacks the target tip
  once, waits for CI on the synced head, and only then merges. Forge-independent:
  GitLab `merge_method=merge` never reports `:behind_base`.
  """
  # async: false — shared sandbox with the Watchdog process, singleton stubs and
  # the app-env freshness probe.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

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

  @authored_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,8 @@ defmodule A do
     def run do
       :ok
  +    :extra
  +    :authored_after_review
     end
   end
  """

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    on_exit(fn -> Application.delete_env(:arbiter, :merge_freshness_probe) end)
    :ok
  end

  # `behind` maps head sha -> commits of the target that head lacks.
  defp probe(behind) do
    test_pid = self()

    Application.put_env(:arbiter, :merge_freshness_probe, fn _repo, base, head ->
      send(test_pid, {:probed, base, head})
      {:ok, Map.fetch!(behind, head)}
    end)
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp reviewed_task(attrs, config \\ %{}) do
    ws =
      Ash.create!(Arbiter.Tasks.Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "mf#{System.unique_integer([:positive])}",
        config: config
      })

    task =
      Ash.create!(
        Issue,
        Map.merge(%{title: "freshness", description: "body", workspace_id: ws.id}, attrs)
      )

    {task, ws}
  end

  defp start_watchdog(task, mr_ref, ws, opts \\ []) do
    base = [
      task_id: task.id,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      auto_resume_dispatcher: StubAutoResumeDispatcher,
      last_reviewed_sha: "sha-reviewed"
    ]

    :ok = Watchdog.subscribe(task.id)
    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
  end

  defp open(head, extra \\ %{}),
    do: Map.merge(%{status: :open, approved: true, head_sha: head, base_ref: "main"}, extra)

  test "a stale approved branch is synced once, CI runs on the synced head, then it merges" do
    {task, ws} = reviewed_task(%{last_reviewed_sha: "sha-reviewed"})
    probe(%{"sha-reviewed" => 4, "sha-synced" => 0})

    StubMerger.set_diff("!mf1", "sha-reviewed", @reviewed_diff)
    StubMerger.set_diff("!mf1", "sha-synced", @merge_from_main_diff)

    StubMerger.queue_get("!mf1", [
      # Green CI on the OLD head — the exact stale-merge shape.
      open("sha-reviewed", %{pipeline: :success, ci_clean: true}),
      # Forge has not shown the sync commit yet: must not sync a second time.
      open("sha-reviewed", %{pipeline: :success, ci_clean: true}),
      # The synced head's pipeline is still running: must not merge.
      open("sha-synced", %{pipeline: :running}),
      open("sha-synced", %{pipeline: :success, ci_clean: true})
    ])

    start_watchdog(task, "!mf1", ws)

    assert_receive {:watchdog, _, {:merged, _}}, 3_000
    assert StubMerger.update_branch_count("!mf1") == 1
    assert StubMerger.last_merge() == {"!mf1", "sha-synced"}
    assert StubMerger.merge_count("!mf1") == 1
    assert StubAutoResumeDispatcher.resume_count() == 0
  end

  test "a sync commit that is not only the target merge still goes back to review" do
    {task, ws} = reviewed_task(%{last_reviewed_sha: "sha-reviewed"})
    probe(%{"sha-reviewed" => 2, "sha-authored" => 0})

    StubMerger.set_diff("!mf2", "sha-reviewed", @reviewed_diff)
    StubMerger.set_diff("!mf2", "sha-authored", @authored_diff)

    StubMerger.queue_get("!mf2", [
      open("sha-reviewed", %{pipeline: :success, ci_clean: true}),
      open("sha-authored", %{pipeline: :success, ci_clean: true})
    ])

    start_watchdog(task, "!mf2", ws)

    assert_receive {:watchdog, _, {:unreviewed_head, "sha-authored"}}, 3_000
    assert StubMerger.merge_count("!mf2") == 0
  end

  test "a sync that fails to apply takes the :conflict path: parked, paged, not merged, not retried" do
    {task, ws} = reviewed_task(%{last_reviewed_sha: "sha-reviewed"})
    probe(%{"sha-reviewed" => 3})
    StubMerger.set_update_branch_result({:error, :conflict})

    StubMerger.queue_get("!mf3", [open("sha-reviewed", %{pipeline: :success, ci_clean: true})])

    wpid = start_watchdog(task, "!mf3", ws)

    wait_until(fn -> :sys.get_state(wpid).last_block_reason == :conflict end)

    assert StubMerger.merge_count("!mf3") == 0
    assert StubMerger.update_branch_count("!mf3") == 1
    assert :sys.get_state(wpid).freshness_failed_head == "sha-reviewed"
  end

  test "a sync the forge never applies is capped and fails closed: parked, never merged" do
    {task, ws} = reviewed_task(%{last_reviewed_sha: "sha-reviewed"})
    probe(%{"sha-reviewed" => 3})

    StubMerger.queue_get("!mf7", [open("sha-reviewed", %{pipeline: :success, ci_clean: true})])

    wpid = start_watchdog(task, "!mf7", ws)

    wait_until(fn -> :sys.get_state(wpid).last_block_reason == :behind_base end, 10_000)

    assert StubMerger.merge_count("!mf7") == 0
    assert StubMerger.update_branch_count("!mf7") == 3
  end

  test "when the check cannot tell, the branch is synced rather than merged unchecked" do
    {task, ws} = reviewed_task(%{last_reviewed_sha: "sha-reviewed"})

    Application.put_env(:arbiter, :merge_freshness_probe, fn _repo, _base, _head ->
      {:error, :no_repo_path}
    end)

    StubMerger.queue_get("!mf8", [open("sha-reviewed", %{pipeline: :success, ci_clean: true})])

    start_watchdog(task, "!mf8", ws)

    wait_until(fn -> StubMerger.update_branch_count("!mf8") >= 1 end)
    assert StubMerger.merge_count("!mf8") == 0
  end

  test "a forge-reported :behind_base keeps the existing path: one update, no extra probe" do
    {task, ws} = reviewed_task(%{last_reviewed_sha: "sha-reviewed"})
    probe(%{"sha-reviewed" => 5})

    StubMerger.queue_get("!mf4", [
      open("sha-reviewed", %{block_reason: :behind_base, ci_clean: false}),
      open("sha-reviewed", %{pipeline: :success, ci_clean: true})
    ])

    start_watchdog(task, "!mf4", ws)

    wait_until(fn -> StubMerger.update_branch_count("!mf4") >= 1 end)
    refute_received {:probed, _, _}
    assert StubMerger.update_branch_count("!mf4") == 1
  end

  test "a branch that already contains the target tip merges without a sync" do
    {task, ws} = reviewed_task(%{last_reviewed_sha: "sha-reviewed"})
    probe(%{"sha-reviewed" => 0})

    StubMerger.queue_get("!mf5", [open("sha-reviewed", %{pipeline: :success, ci_clean: true})])
    start_watchdog(task, "!mf5", ws)

    assert_receive {:watchdog, _, {:merged, _}}, 3_000
    assert StubMerger.update_branch_count("!mf5") == 0
    assert_received {:probed, "main", "sha-reviewed"}
  end

  test "merge.require_up_to_date=false skips the check" do
    {task, ws} =
      reviewed_task(%{last_reviewed_sha: "sha-reviewed"}, %{
        "merge" => %{"require_up_to_date" => false}
      })

    probe(%{"sha-reviewed" => 9})

    StubMerger.queue_get("!mf6", [open("sha-reviewed", %{pipeline: :success, ci_clean: true})])
    start_watchdog(task, "!mf6", ws)

    assert_receive {:watchdog, _, {:merged, _}}, 3_000
    assert StubMerger.update_branch_count("!mf6") == 0
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :ok
        System.monotonic_time(:millisecond) > deadline -> flunk("condition not met")
        true -> Process.sleep(10) && :retry
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end
end
