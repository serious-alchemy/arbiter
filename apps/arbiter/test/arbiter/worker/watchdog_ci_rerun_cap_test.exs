defmodule Arbiter.Worker.WatchdogCiRerunCapTest do
  @moduledoc """
  GitHub #1284 — automatic CI re-runs on one commit are capped across every
  Watchdog site (`CiRerunBudget`, `merge.ci.max_reruns_per_sha`, default 2):

    * at the cap no further pipeline is started on that SHA;
    * reaching it yields one fix pass (and one ticket note) naming the failing jobs;
    * a first failure followed by a passing re-run proceeds as before;
    * a push (a new head SHA) starts the count again;
    * a zero-job pipeline (bd-7eve8a) is no re-run and does not count.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.CiRerunBudget
  alias Arbiter.Worker.Watchdog

  @docs_diff "diff --git a/docs/guide.md b/docs/guide.md\n--- a/docs/guide.md\n+++ b/docs/guide.md\n@@ -1 +1 @@\n-a\n+b\n"

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    :ok
  end

  defp workspace(ci \\ %{}) do
    config = if ci == %{}, do: %{}, else: %{"merge" => %{"ci" => ci}}

    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "rc#{System.unique_integer([:positive])}",
      config: config
    })
  end

  defp task(ws),
    do: Ash.create!(Issue, %{title: "cap", description: "body", workspace_id: ws.id})

  defp notes(task), do: Ash.get!(Issue, task.id).notes || ""

  # A runner failure: triaged `:infra`, so the Watchdog re-runs it (budget 2)
  # on its own, with no agent.
  defp runner_failure,
    do: [%{name: "rspec", summary: "", failure_reason: "runner_system_failure", url: nil}]

  defp red(head),
    do: %{
      status: :open,
      approved: true,
      block_reason: :ci_failed,
      pipeline: :failed,
      head_sha: head,
      base_ref: "main"
    }

  defp pending(head),
    do: %{status: :open, approved: true, block_reason: nil, pipeline: :running, head_sha: head}

  defp green(head),
    do: %{status: :open, approved: true, block_reason: nil, pipeline: :success, head_sha: head}

  defp reruns(ref), do: for({^ref, opts} <- StubMerger.ci_reruns(), do: opts)

  defp start(task, ws, ref) do
    StubMerger.set_diff(ref, nil, @docs_diff)

    {:ok, pid} =
      Watchdog.start(
        task_id: task.id,
        mr_ref: ref,
        adapter: StubMerger,
        workspace: ws,
        auto_merge: true,
        interval_ms: 15,
        initial_delay_ms: 0,
        fix_pass_history: fn _task_id, _mr_ref -> 0 end,
        fix_pass_dispatcher: StubFixPassDispatcher
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    pid
  end

  test "at the cap no further pipeline is started on the SHA: one fix pass names the failing jobs" do
    # triage_rerun_budget (3) alone would allow 3 re-runs; the shared cap stops at 1.
    ws = workspace(%{"triage_rerun_budget" => 3, "max_reruns_per_sha" => 1})
    t = task(ws)
    StubMerger.set_failing_checks("!rc1", runner_failure())

    StubMerger.queue_get("!rc1", [
      red("h1"),
      pending("h1"),
      red("h1"),
      red("h1"),
      red("h1"),
      red("h1")
    ])

    start(t, ws, "!rc1")

    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    wait_until(fn -> StubMerger.get_count("!rc1") >= 6 end)

    assert length(reruns("!rc1")) == 1
    wait_until(fn -> CiRerunBudget.count(t.id, "h1") == 1 end)
    assert StubFixPassDispatcher.call_count() >= 1

    args = StubFixPassDispatcher.last_args()
    assert Enum.any?(args.checks, &(&1.name == "rspec"))

    note = notes(t)
    assert note =~ "re-run cap reached on head h1"
    assert note =~ "rspec"
    assert note =~ "merge.ci.max_reruns_per_sha"
    assert length(String.split(note, "## CI re-run cap reached")) == 2
  end

  test "a first failure followed by a passing re-run proceeds as today" do
    ws = workspace()
    t = task(ws)
    StubMerger.set_failing_checks("!rc2", runner_failure())
    StubMerger.queue_get("!rc2", [red("h1"), pending("h1"), green("h1")])

    start(t, ws, "!rc2")

    wait_until(fn -> length(reruns("!rc2")) == 1 end)

    wait_until(fn -> CiRerunBudget.count(t.id, "h1") == 1 end)
    wait_until(fn -> StubMerger.get_count("!rc2") >= 3 end)
    assert StubFixPassDispatcher.call_count() == 0
    refute notes(t) =~ "re-run cap reached"
  end

  test "a push of a new commit resets the count" do
    ws = workspace(%{"max_reruns_per_sha" => 1})
    t = task(ws)
    StubMerger.set_failing_checks("!rc3", runner_failure())

    StubMerger.queue_get("!rc3", [
      red("h1"),
      pending("h1"),
      red("h1"),
      red("h2"),
      pending("h2"),
      red("h2"),
      red("h2")
    ])

    start(t, ws, "!rc3")

    # h1: one re-run, then the cap -> fix pass. h2: a fresh re-run is allowed.
    wait_until(fn -> length(reruns("!rc3")) == 2 end)
    wait_until(fn -> StubFixPassDispatcher.call_count() >= 2 end)

    assert length(reruns("!rc3")) == 2
    wait_until(fn -> CiRerunBudget.count(t.id, "h2") == 1 end)
    assert CiRerunBudget.count(t.id, "h1") == 0
  end

  test "a zero-job pipeline is no code failure: it starts no re-run and does not count" do
    ws = workspace(%{"max_reruns_per_sha" => 1})
    t = task(ws)
    StubMerger.queue_get("!rc4", List.duplicate(red("h1"), 8))

    StubMerger.set_unrun_pipeline("!rc4", %{
      pipeline_id: 7,
      sha: "h1",
      user: "bot",
      failure_reason: "no jobs",
      error_messages: nil,
      verification?: false
    })

    start(t, ws, "!rc4")
    wait_until(fn -> StubMerger.get_count("!rc4") >= 5 end)

    assert reruns("!rc4") == []
    assert StubFixPassDispatcher.call_count() == 0
    assert CiRerunBudget.count(t.id, "h1") == 0
    refute notes(t) =~ "re-run cap reached"
  end

  test "the cancelled-run re-runs share the cap and escalate at it" do
    ws = workspace(%{"max_reruns_per_sha" => 1})
    t = task(ws)

    cancelled = fn head ->
      %{
        status: :open,
        approved: true,
        block_reason: :ci_cancelled,
        pipeline: :canceled,
        head_sha: head,
        base_ref: "main"
      }
    end

    StubMerger.queue_get("!rc5", [cancelled.("h1")])
    pid = start(t, ws, "!rc5")

    wait_until(fn -> :sys.get_state(pid).park_reason == :ci_cancelled end)

    # The per-site cap alone (2) would have re-run twice.
    assert length(reruns("!rc5")) == 1
    assert StubFixPassDispatcher.call_count() == 0
    assert :sys.get_state(pid).ci_cancelled_escalated_head == "h1"
  end

  describe "manual ci_rerun" do
    test "a worker's re-run is booked and refused at the cap; the coordinator's is counted, never refused" do
      ws = workspace(%{"max_reruns_per_sha" => 2})
      t = task(ws)
      StubMerger.queue_get("!rc6", [pending("h1")])
      pid = start(t, ws, "!rc6")
      wait_until(fn -> :sys.get_state(pid).polled_head_sha == "h1" end)

      assert {:ok, _} = Watchdog.rerun_ci(t.id, %{actor: :worker})
      assert {:ok, _} = Watchdog.rerun_ci(t.id, %{})
      assert CiRerunBudget.count(t.id, "h1") == 2

      assert {:error, {:rerun_cap, 2, 2}} = Watchdog.rerun_ci(t.id, %{actor: :worker})
      assert length(reruns("!rc6")) == 2
      # the coordinator can still re-run by hand
      assert {:ok, _} = Watchdog.rerun_ci(t.id, %{})
      assert length(reruns("!rc6")) == 3
      assert notes(t) =~ "re-run cap reached on head h1"
    end

    test "the :actor marker never reaches the forge adapter" do
      ws = workspace()
      t = task(ws)
      StubMerger.queue_get("!rc7", [pending("h1")])
      pid = start(t, ws, "!rc7")
      wait_until(fn -> :sys.get_state(pid).polled_head_sha == "h1" end)

      assert {:ok, _} = Watchdog.rerun_ci(t.id, %{actor: :worker, mode: :auto})
      assert [opts] = reruns("!rc7")
      refute Map.has_key?(opts, :actor)
    end
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
          Process.sleep(10)
          :wait
      end
    end)
    |> Enum.find(&(&1 == :done))
  end
end
