defmodule Arbiter.Worker.WatchdogCiTriageTest do
  @moduledoc """
  GitHub #1144 - the Watchdog classifies a red head (`CiTriage`) before it spawns
  a fix pass:

    * infra / unrelated tests -> re-run the failed jobs, up to a per-head budget
      (default 2, `merge.ci.triage_rerun_budget`), then fall back to a fix pass;
    * target branch red -> hold, as before;
    * needs_agent (touches the diff, unclassifiable) -> fix pass, briefed with the
      triage evidence;
    * every decision is appended to the ticket's notes with the class and evidence.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  @docs_diff "diff --git a/docs/guide.md b/docs/guide.md\n--- a/docs/guide.md\n+++ b/docs/guide.md\n@@ -1 +1 @@\n-a\n+b\n"
  @lib_diff "diff --git a/apps/arbiter/lib/arbiter/board/drain.ex b/apps/arbiter/lib/arbiter/board/drain.ex\n--- a/apps/arbiter/lib/arbiter/board/drain.ex\n+++ b/apps/arbiter/lib/arbiter/board/drain.ex\n@@ -1 +1 @@\n-a\n+b\n"
  @drain "apps/arbiter/test/arbiter/board/drain_test.exs"

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    :ok
  end

  defp workspace(ci \\ %{}) do
    config = if ci == %{}, do: %{}, else: %{"merge" => %{"ci" => ci}}

    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "tr#{System.unique_integer([:positive])}",
      config: config
    })
  end

  defp task(ws),
    do: Ash.create!(Issue, %{title: "triage", description: "body", workspace_id: ws.id})

  defp notes(task), do: Ash.get!(Issue, task.id).notes || ""

  defp runner_failure(name \\ "rspec"),
    do: [%{name: name, summary: "", failure_reason: "runner_system_failure", url: nil}]

  defp untouched_test(name \\ "mix test"),
    do: [%{name: name, summary: "", conclusion: "failure", files: [@drain]}]

  defp red(head),
    do: %{
      status: :open,
      approved: true,
      block_reason: :ci_failed,
      pipeline: :failed,
      head_sha: head
    }

  defp pending(head),
    do: %{status: :open, approved: true, block_reason: nil, pipeline: :running, head_sha: head}

  defp reruns(ref), do: for({^ref, opts} <- StubMerger.ci_reruns(), do: opts)

  defp start(task, ws, ref, opts \\ []) do
    {diff, opts} = Keyword.pop(opts, :diff, @docs_diff)

    if diff == :error,
      do: StubMerger.set_diff_error(ref, :boom),
      else: StubMerger.set_diff(ref, nil, diff)

    {:ok, pid} =
      Watchdog.start(
        Keyword.merge(
          [
            task_id: task.id,
            mr_ref: ref,
            adapter: StubMerger,
            workspace: ws,
            auto_merge: true,
            interval_ms: 15,
            initial_delay_ms: 0,
            fix_pass_history: fn _task_id, _mr_ref -> 0 end,
            fix_pass_dispatcher: StubFixPassDispatcher
          ],
          opts
        )
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    pid
  end

  describe "infra" do
    test "re-runs the failed jobs without spawning an agent, and records the decision" do
      ws = workspace()
      t = task(ws)
      StubMerger.set_failing_checks("!ti1", runner_failure())
      StubMerger.queue_get("!ti1", [red("h1"), pending("h1")])

      start(t, ws, "!ti1")

      wait_until(fn -> length(reruns("!ti1")) == 1 end)
      wait_until(fn -> notes(t) =~ "CI triage" end)
      assert StubFixPassDispatcher.call_count() == 0

      note = notes(t)
      assert note =~ "infra"
      assert note =~ "runner_system_failure"
      assert note =~ "rspec"
      assert note =~ "re-ran CI (1/2)"
      assert note =~ "h1"
    end

    test "a head still red after the budget falls back to a fix pass briefed with the evidence" do
      ws = workspace()
      t = task(ws)
      StubMerger.set_failing_checks("!ti2", runner_failure())

      StubMerger.queue_get("!ti2", [
        red("h1"),
        pending("h1"),
        red("h1"),
        pending("h1"),
        red("h1")
      ])

      start(t, ws, "!ti2")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert length(reruns("!ti2")) == 2

      args = StubFixPassDispatcher.last_args()
      assert args.triage =~ "CI triage: infra"
      assert args.triage =~ "runner_system_failure"
      assert notes(t) =~ "re-ran CI (2/2)"
      assert notes(t) =~ "re-run budget (2) spent"
    end

    test "the budget is configurable through merge.ci.triage_rerun_budget" do
      ws = workspace(%{"triage_rerun_budget" => 1})
      t = task(ws)
      StubMerger.set_failing_checks("!ti3", runner_failure())
      StubMerger.queue_get("!ti3", [red("h1"), pending("h1"), red("h1")])

      start(t, ws, "!ti3")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert length(reruns("!ti3")) == 1
    end
  end

  describe "unrelated tests" do
    test "re-runs up to the budget, then dispatches a fix pass" do
      ws = workspace()
      t = task(ws)
      StubMerger.set_failing_checks("!tu1", untouched_test())

      StubMerger.queue_get("!tu1", [
        red("h1"),
        pending("h1"),
        red("h1"),
        pending("h1"),
        red("h1")
      ])

      start(t, ws, "!tu1")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert length(reruns("!tu1")) == 2
      assert StubFixPassDispatcher.last_args().triage =~ "unrelated_tests"
      assert StubFixPassDispatcher.last_args().outside_diff_files == [@drain]
      assert notes(t) =~ "unrelated_tests"
      assert notes(t) =~ "drain_test.exs"
    end

    test "a new head gets a fresh budget" do
      ws = workspace()
      t = task(ws)
      StubMerger.set_failing_checks("!tu2", untouched_test())

      StubMerger.queue_get("!tu2", [
        red("h1"),
        pending("h1"),
        red("h1"),
        pending("h1"),
        red("h2"),
        pending("h2")
      ])

      start(t, ws, "!tu2")

      wait_until(fn -> length(reruns("!tu2")) == 3 end)
      assert StubFixPassDispatcher.call_count() == 0
    end

    test "merge.ci.no_rerun_jobs is respected: straight to the fix pass" do
      ws = workspace(%{"no_rerun_jobs" => ["visual"]})
      t = task(ws)
      StubMerger.set_failing_checks("!tu3", untouched_test("visual-chromium"))
      StubMerger.queue_get("!tu3", [red("h1")])

      start(t, ws, "!tu3")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert reruns("!tu3") == []
      assert notes(t) =~ "no_rerun_jobs"
    end
  end

  describe "needs_agent" do
    test "a failure touching the diff dispatches a fix pass at once, briefed with the evidence" do
      ws = workspace()
      t = task(ws)
      StubMerger.set_failing_checks("!tn1", untouched_test())
      StubMerger.queue_get("!tn1", [red("h1")])

      # drain_test.exs fails and the PR changes its subject, drain.ex.
      start(t, ws, "!tn1", diff: @lib_diff)

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert reruns("!tn1") == []

      args = StubFixPassDispatcher.last_args()
      assert args.triage =~ "CI triage: needs_agent"
      assert args.triage =~ "touches_diff"
      assert args.triage =~ "drain.ex"

      assert notes(t) =~ "needs_agent"
      assert notes(t) =~ "dispatching a fix pass"
    end

    test "a mixed pipeline (one infra job, one touching the diff) dispatches a fix pass" do
      ws = workspace()
      t = task(ws)
      checks = runner_failure("build") ++ untouched_test()
      StubMerger.set_failing_checks("!tn2", checks)
      StubMerger.queue_get("!tn2", [red("h1")])

      start(t, ws, "!tn2", diff: @lib_diff)

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert reruns("!tn2") == []
    end

    test "an unclassifiable failure (no check data) fails safe to a fix pass" do
      ws = workspace()
      t = task(ws)
      StubMerger.queue_get("!tn3", [red("h1")])

      start(t, ws, "!tn3")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert reruns("!tn3") == []
      assert StubFixPassDispatcher.last_args().triage =~ "needs_agent"
      assert notes(t) =~ "no failing-check data"
    end

    test "a failure naming no test file (lint/build) fails safe to a fix pass" do
      ws = workspace()
      t = task(ws)

      StubMerger.set_failing_checks("!tn4", [
        %{name: "credo", summary: "lib/x.ex:3 nesting too deep", conclusion: "failure"}
      ])

      StubMerger.queue_get("!tn4", [red("h1")])

      start(t, ws, "!tn4")

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert reruns("!tn4") == []
    end

    test "an unreadable diff fails safe: untouched-looking tests are not waved through" do
      ws = workspace()
      t = task(ws)
      StubMerger.set_failing_checks("!tn5", untouched_test())
      StubMerger.queue_get("!tn5", [red("h1")])

      start(t, ws, "!tn5", diff: :error)

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      assert reruns("!tn5") == []
    end
  end

  describe "target_red" do
    test "holds the MR as before and records the triage on the ticket" do
      ws = workspace()
      t = task(ws)
      StubMerger.set_failing_checks("!tt1", untouched_test())

      StubMerger.set_branch_pipeline(
        {:ok, %{id: 777, sha: "abc", status: "failed", url: "https://ci/777"}}
      )

      StubMerger.queue_get("!tt1", [red("h1")])

      pid = start(t, ws, "!tt1")

      wait_until(fn -> :sys.get_state(pid).ci_hold != nil end)
      wait_until(fn -> notes(t) =~ "target_red" end)
      assert reruns("!tt1") == []
      assert StubFixPassDispatcher.call_count() == 0
      assert notes(t) =~ "holding"
      assert notes(t) =~ "777"
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
