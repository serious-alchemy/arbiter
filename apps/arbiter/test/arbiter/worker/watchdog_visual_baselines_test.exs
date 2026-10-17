defmodule Arbiter.Worker.WatchdogVisualBaselinesTest do
  @moduledoc """
  bd-9obzu9 / GitHub #936 — the Watchdog's `:ci_failed` path tries the
  deterministic visual-baseline refresh (`Arbiter.Worker.VisualBaselines`)
  before it dispatches an agent fix pass.

    * refreshed: no fix pass is dispatched, and the pushed head is an authored
      push — it goes back to a review round, never straight to the merge (AC1, AC4);
    * not refreshable (the refresher skips, or the repo has no config): the
      normal fix pass runs (AC3).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  @approved_diff """
  diff --git a/app/page.html b/app/page.html
  index 1111111..2222222 100644
  --- a/app/page.html
  +++ b/app/page.html
  @@ -1,3 +1,3 @@
   <p>one</p>
  -<p>two</p>
  +<p>2</p>
   <p>three</p>
  """

  @refreshed_diff @approved_diff <>
                    """
                    diff --git a/e2e/page-chromium-linux.png b/e2e/page-chromium-linux.png
                    index 3333333..4444444 100644
                    Binary files a/e2e/page-chromium-linux.png and b/e2e/page-chromium-linux.png differ
                    """

  defmodule Refresher do
    @moduledoc false
    # Records the context it was called with and answers what the test set.
    def refresh(ctx) do
      send(Application.get_env(:arbiter, :visual_refresher_pid), {:refresh, ctx})
      Application.get_env(:arbiter, :visual_refresher_reply)
    end
  end

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    StubFixPassDispatcher.reset()
    Application.put_env(:arbiter, :visual_refresher_pid, self())

    on_exit(fn ->
      Application.delete_env(:arbiter, :visual_refresher_pid)
      Application.delete_env(:arbiter, :visual_refresher_reply)
    end)

    :ok
  end

  defp sha(seed), do: Base.encode16(:crypto.hash(:sha, seed), case: :lower)

  defp workspace(configured?) do
    worker =
      if configured? do
        %{
          "repos" => %{
            "tonic" => %{
              "visual_baselines" => %{"job" => "visual", "baseline_dir" => "e2e"}
            }
          }
        }
      else
        %{}
      end

    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "vb#{System.unique_integer([:positive])}",
      config: %{"worker" => worker}
    })
  end

  defp approved_task(ws, approved) do
    Ash.create!(Issue, %{
      title: "visual drift",
      description: "body",
      workspace_id: ws.id,
      last_reviewed_sha: approved
    })
  end

  defp start_watchdog(task, mr_ref, ws, opts \\ []) do
    base = [
      task_id: task.id,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      repo: "tonic",
      auto_merge: true,
      via_review_gate: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      max_auto_resolve_attempts: 1,
      fix_pass_dispatcher: StubFixPassDispatcher,
      auto_resume_dispatcher: StubAutoResumeDispatcher,
      visual_refresher: &Refresher.refresh/1
    ]

    :ok = Watchdog.subscribe(task.id)
    {:ok, pid} = Watchdog.start(Keyword.merge(base, opts))

    on_exit(fn -> stop_quietly(pid) end)

    pid
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp red(head),
    do: %{
      status: :open,
      approved: true,
      head_sha: head,
      head_ref: "feature/x",
      base_ref: "main",
      block_reason: :ci_failed
    }

  test "a refreshed head is an authored push: no fix pass, and it goes back to review, not the merge" do
    ws = workspace(true)
    mr_ref = "!vb1"
    approved = sha("approved")
    pushed = sha("refreshed")
    task = approved_task(ws, approved)

    Application.put_env(
      :arbiter,
      :visual_refresher_reply,
      {:refreshed, %{sha: pushed, files: ["e2e/page-chromium-linux.png"]}}
    )

    StubMerger.set_diff(mr_ref, approved, @approved_diff)
    StubMerger.set_diff(mr_ref, pushed, @refreshed_diff)

    StubMerger.queue_get(mr_ref, [
      red(approved),
      red(approved),
      %{status: :open, approved: true, head_sha: pushed, head_ref: "feature/x", base_ref: "main"}
    ])

    pid = start_watchdog(task, mr_ref, ws)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000

    assert_received {:refresh, ctx}
    assert ctx.repo == "tonic"
    assert ctx.mr_ref == mr_ref
    assert ctx.result.head_sha == approved
    assert ctx.result.head_ref == "feature/x"

    assert StubFixPassDispatcher.call_count() == 0
    assert StubMerger.merge_count(mr_ref) == 0, "the refreshed head merged unreviewed"
    assert [%{task_id: task_id}] = StubAutoResumeDispatcher.resumes()
    assert task_id == task.id
  end

  test "the refresher skipping leaves the normal fix pass to run" do
    ws = workspace(true)
    mr_ref = "!vb2"
    head = sha("head2")
    task = approved_task(ws, head)

    Application.put_env(
      :arbiter,
      :visual_refresher_reply,
      {:skip, {:own_changes, ["app/own.html"]}}
    )

    StubMerger.queue_get(mr_ref, [red(head)])
    start_watchdog(task, mr_ref, ws)

    assert_receive {:refresh, _}, 3_000
    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    assert StubFixPassDispatcher.call_count() >= 1
  end

  test "a repo with no visual_baselines config never calls the refresher" do
    ws = workspace(false)
    mr_ref = "!vb3"
    head = sha("head3")
    task = approved_task(ws, head)
    Application.put_env(:arbiter, :visual_refresher_reply, {:skip, :unused})

    StubMerger.queue_get(mr_ref, [red(head)])
    start_watchdog(task, mr_ref, ws)

    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    refute_received {:refresh, _}
  end

  test "a refresher error also falls through to the fix pass" do
    ws = workspace(true)
    mr_ref = "!vb4"
    head = sha("head4")
    task = approved_task(ws, head)
    Application.put_env(:arbiter, :visual_refresher_reply, {:error, {:push_failed, "rejected"}})

    StubMerger.queue_get(mr_ref, [red(head)])
    start_watchdog(task, mr_ref, ws)

    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    assert_received {:refresh, _}
  end

  test "it refreshes once per head: a second red on the same head goes to the fix pass" do
    ws = workspace(true)
    mr_ref = "!vb5"
    head = sha("head5")
    task = approved_task(ws, head)

    Application.put_env(
      :arbiter,
      :visual_refresher_reply,
      {:refreshed, %{sha: sha("never-seen"), files: ["e2e/a.png"]}}
    )

    # the forge keeps reporting the old head red (the refresh push has not shown up)
    StubMerger.queue_get(mr_ref, [red(head)])
    start_watchdog(task, mr_ref, ws)

    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    assert_received {:refresh, _}
    refute_received {:refresh, _}
  end

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() ->
          :done

        System.monotonic_time(:millisecond) > deadline ->
          flunk("condition not met within timeout")

        true ->
          Process.sleep(10) && :wait
      end
    end)
    |> Enum.find(&(&1 == :done))
  end
end
