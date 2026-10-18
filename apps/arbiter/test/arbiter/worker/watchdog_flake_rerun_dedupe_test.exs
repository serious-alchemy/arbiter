defmodule Arbiter.Worker.WatchdogFlakeRerunDedupeTest do
  @moduledoc """
  bd-51ji79 / GitHub #949 — the Watchdog's suspected-flake re-run honours the
  same skips as the ReviewGate's (`ReviewCi.skip_rerun/4`):

    * every failed job matches `merge.ci.no_rerun_jobs` -> no re-run, fix path;
    * the head already failed this job set (either site's re-run) -> no re-run;
    * a job outside the list keeps its single re-run, which is recorded for the
      ReviewGate to dedupe against.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.ReviewCi
  alias Arbiter.Worker.Watchdog

  @docs_diff "diff --git a/docs/guide.md b/docs/guide.md\n--- a/docs/guide.md\n+++ b/docs/guide.md\n@@ -1 +1 @@\n-a\n+b\n"
  @drain "apps/arbiter/test/arbiter/board/drain_test.exs"

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    :ok
  end

  defp workspace(no_rerun_jobs) do
    ci = if no_rerun_jobs == [], do: %{}, else: %{"ci" => %{"no_rerun_jobs" => no_rerun_jobs}}

    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "fr#{System.unique_integer([:positive])}",
      config: %{"merge" => ci}
    })
  end

  defp task(ws),
    do: Ash.create!(Issue, %{title: "flake", description: "body", workspace_id: ws.id})

  defp failing(job), do: [%{name: job, summary: "", files: [@drain]}]

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

  test "every failed job matching merge.ci.no_rerun_jobs skips the re-run for the fix path" do
    ws = workspace(["visual"])
    StubMerger.set_failing_checks("!nr1", failing("visual-chromium"))
    StubMerger.queue_get("!nr1", [red("h1")])

    start(task(ws), ws, "!nr1")

    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    assert reruns("!nr1") == []
  end

  test "a job outside no_rerun_jobs keeps its single re-run and records the set" do
    ws = workspace(["visual"])
    t = task(ws)
    StubMerger.set_failing_checks("!nr2", failing("mix test"))
    StubMerger.queue_get("!nr2", [red("h1"), pending("h1")])

    start(t, ws, "!nr2")

    wait_until(fn -> length(reruns("!nr2")) == 1 end)
    assert StubFixPassDispatcher.call_count() == 0
    assert ReviewCi.load_failed_sets(t.id) == %{"h1" => ["mix test"]}
  end

  test "a head the ReviewGate already re-ran with the same job set is not re-run again" do
    ws = workspace([])
    t = task(ws)
    ReviewCi.note_failed_set(t.id, %{}, "h1", [%{name: "mix test"}])
    StubMerger.set_failing_checks("!nr3", failing("mix test"))
    StubMerger.queue_get("!nr3", [red("h1")])

    start(t, ws, "!nr3")

    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    assert reruns("!nr3") == []
  end

  test "a different job set on the same head still gets its re-run" do
    ws = workspace([])
    t = task(ws)
    ReviewCi.note_failed_set(t.id, %{}, "h1", [%{name: "lint"}])
    StubMerger.set_failing_checks("!nr4", failing("mix test"))
    StubMerger.queue_get("!nr4", [red("h1"), pending("h1")])

    start(t, ws, "!nr4")

    wait_until(fn -> length(reruns("!nr4")) == 1 end)
    assert StubFixPassDispatcher.call_count() == 0
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
