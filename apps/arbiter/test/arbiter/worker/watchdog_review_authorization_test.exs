defmodule Arbiter.Worker.WatchdogReviewAuthorizationTest do
  @moduledoc """
  bd-651ine / #529 — the Watchdog's merge honours the ReviewGate's own record.

  A ticket whose latest reviewer round is REQUEST_CHANGES has no approved head,
  so the reviewed-SHA guard has no baseline and used to merge unguarded. A
  `send_back` resolution ("another review round follows") does not change that;
  only `accept_as_is` / `amend` — or a later APPROVE — does.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    :ok
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp rejected_task do
    ws =
      Ash.create!(Arbiter.Tasks.Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "wa#{System.unique_integer([:positive])}"
      })

    task = Ash.create!(Issue, %{title: "rc", description: "body", workspace_id: ws.id})

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: :request_changes,
        findings: "[high] a.ex:1 needs a guard",
        finding_count: 1
      })

    {task, ws}
  end

  defp start_watchdog(task, ref, ws) do
    :ok = Watchdog.subscribe(task.id)

    {:ok, pid} =
      Watchdog.start(
        task_id: task.id,
        mr_ref: ref,
        adapter: StubMerger,
        workspace: ws,
        auto_merge: true,
        interval_ms: 15,
        initial_delay_ms: 0,
        auto_resume_dispatcher: StubAutoResumeDispatcher
      )

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp approved_get(ref),
    do:
      StubMerger.queue_get(ref, [
        %{status: :open, approved: true, head_sha: "sha-fix", base_ref: "main"}
      ])

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(10) && do_wait(fun, deadline)
    end
  end

  test "a send_back resolution does not let a REQUEST_CHANGES PR merge" do
    {task, ws} = rejected_task()

    {:ok, _} =
      Resolutions.record(%{task_id: task.id, decision: "send_back", reasoning: "fix, re-review"})

    approved_get("!ra1")
    start_watchdog(task, "!ra1", ws)

    # The refusal is retried (it is not terminal), and never reaches the forge.
    wait_until(fn -> StubMerger.get_count("!ra1") >= 3 end)
    assert StubMerger.merge_count("!ra1") == 0
    assert Ash.get!(Issue, task.id).state != :closed
  end

  test "an accept_as_is resolution authorises the merge" do
    {task, ws} = rejected_task()

    {:ok, _} =
      Resolutions.record(%{task_id: task.id, decision: "accept_as_is", reasoning: "reviewed"})

    approved_get("!ra2")
    start_watchdog(task, "!ra2", ws)

    assert_receive {:watchdog, _, {:merged, _}}, 2_000
    assert StubMerger.merge_count("!ra2") == 1
  end
end
