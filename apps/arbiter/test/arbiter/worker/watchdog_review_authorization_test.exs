defmodule Arbiter.Worker.WatchdogReviewAuthorizationTest do
  @moduledoc """
  bd-651ine / #529 — the Watchdog's merge honours the ReviewGate's own record.

  A ticket whose latest reviewer round is REQUEST_CHANGES has no approved head,
  so the reviewed-SHA guard has no baseline and used to merge unguarded. A
  `send_back` resolution ("another review round follows") does not change that;
  only `accept_as_is` / `amend` — or a later APPROVE — does.

  And the refusal is not the end of it: "another review round follows" is only
  true if something dispatches the round. The Watchdog routes the refused head
  to a review round (an auto-resume of the Merging ticket, whose completion
  re-enters the ReviewGate) exactly as it does a stale reviewed SHA, and pages
  once — never a per-poll retry — when there is no path back.

  The incident shape: the PR sits on the production lane (`via_review_gate`,
  which pins the outcome to `:approved`; the forge itself reports
  `approved=false`), the gate's latest round is REQUEST_CHANGES, and the
  coordinator has recorded `send_back`.
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

  defp start_watchdog(task, ref, ws, extra \\ []) do
    :ok = Watchdog.subscribe(task.id)

    {:ok, pid} =
      Watchdog.start(
        [
          task_id: task.id,
          mr_ref: ref,
          adapter: StubMerger,
          workspace: ws,
          auto_merge: true,
          interval_ms: 15,
          initial_delay_ms: 0,
          auto_resume_dispatcher: StubAutoResumeDispatcher
        ] ++ extra
      )

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp approved_get(ref),
    do:
      StubMerger.queue_get(ref, [
        %{status: :open, approved: true, head_sha: "sha-fix", base_ref: "main"}
      ])

  test "a send_back resolution does not let a REQUEST_CHANGES PR merge: a review round is dispatched" do
    {task, ws} = rejected_task()

    {:ok, _} =
      Resolutions.record(%{task_id: task.id, decision: "send_back", reasoning: "fix, re-review"})

    # The incident lane: the gate "approved" in-process (`via_review_gate`), the
    # forge says approved=false. On main this merged.
    StubMerger.queue_get("!ra1", [
      %{status: :open, approved: false, head_sha: "sha-fix", base_ref: "main"}
    ])

    pid = start_watchdog(task, "!ra1", ws, via_review_gate: true)
    ref = Process.monitor(pid)

    # The refusal buys a reviewer round (a new run on the ticket) and the
    # Watchdog's episode ends there; the merge is never attempted.
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    assert [%{task_id: task_id, attempt: 1, briefing: briefing}] =
             StubAutoResumeDispatcher.resumes()

    assert task_id == task.id
    assert briefing =~ "REVIEW ROUND ONLY"
    assert StubAutoResumeDispatcher.escalations() == []
    assert StubMerger.merge_count("!ra1") == 0
    assert Ash.get!(Issue, task.id).state != :closed
  end

  test "with no auto-resume budget the refusal pages once and stops (no per-poll retry)" do
    {task, ws} = rejected_task()

    {:ok, _} =
      Resolutions.record(%{task_id: task.id, decision: "send_back", reasoning: "fix, re-review"})

    approved_get("!ra3")
    pid = start_watchdog(task, "!ra3", ws, via_review_gate: true, max_auto_resumes: 0)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    assert [{task_id, _ws, "!ra3", 0, {:review_not_approved, "sha-fix", _refusal}}] =
             StubAutoResumeDispatcher.escalations()

    assert task_id == task.id
    assert StubAutoResumeDispatcher.resume_count() == 0
    assert StubMerger.merge_count("!ra3") == 0
  end

  test "after the review round approves the new head the merge goes through" do
    {task, ws} = rejected_task()

    {:ok, _} =
      Resolutions.record(%{task_id: task.id, decision: "send_back", reasoning: "fix, re-review"})

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: :approve,
        findings: "",
        finding_count: 0
      })

    approved_get("!ra4")
    start_watchdog(task, "!ra4", ws, via_review_gate: true)

    assert_receive {:watchdog, _, {:merged, _}}, 2_000
    assert StubMerger.merge_count("!ra4") == 1
    assert StubAutoResumeDispatcher.resume_count() == 0
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
