defmodule Arbiter.Worker.ReviewNotStartedStatusTest do
  # bd-8tjcms / #1511 (acceptance 3) — a run that reached `arb done` and exited
  # successfully must not be recorded `failed` just because the *review* stage
  # never started.
  #
  # vs-ehjarz run 39c6b497 printed `arb done`, reported `session success`, pushed
  # its branch and opened MR !183 — and was then written to `worker_runs` as
  # a plain failure because no reviewer picked it up inside the Watchdog's
  # poll ceiling. "The implementation run failed" is the wrong description of
  # that.
  #
  # Since the one run vocabulary (bd-1uu19b) a review that never started is a
  # run finished with outcome `:failed` whose cause is its `failure_reason`
  # (`{:awaiting_review_timeout, N}`) — there is no separate
  # `:review_not_started` run status any more. The worker finishes `:failed`
  # on purpose: it is the terminal state `Dispatch.resume/2` requires before it
  # will re-attach, and the Watchdog's bounded auto-resume (bd-8eheb6) depends
  # on that.
  #
  # async: false — the Worker registry and DynamicSupervisor are global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.{Run, RunState}

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "review-not-started-ws", prefix: "rns"})
    {:ok, task} = Ash.create(Issue, %{title: "ship the thing", workspace_id: ws.id})
    {:ok, ws: ws, task: task}
  end

  defp start_worker!(ws, task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp run_for(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
    |> List.first()
  end

  test "an awaiting_review_timeout finishes the run :failed with the timeout as its cause",
       %{ws: ws, task: task} do
    pid = start_worker!(ws, task)

    :ok = Worker.fail(pid, {:awaiting_review_timeout, 30})

    run = run_for(task.id)
    assert run.state == :finished
    assert run.outcome == :failed
    assert run.failure_reason == "{:awaiting_review_timeout, 30}"

    # The worker is terminal — Dispatch.resume/2 and the Watchdog's
    # auto-resume both require a finished worker.
    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
  end

  test "any other failure is still recorded as :failed", %{ws: ws, task: task} do
    pid = start_worker!(ws, task)

    :ok = Worker.fail(pid, {:claude_exit, 1})

    run = run_for(task.id)
    assert run.state == :finished
    assert run.outcome == :failed
    assert run.failure_reason == "{:claude_exit, 1}"
  end

  test "a review that never started is not its own run outcome", %{ws: _ws, task: _task} do
    refute :review_not_started in RunState.outcomes()
    assert :failed in RunState.outcomes()
  end
end
