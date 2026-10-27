defmodule Arbiter.Worker.WatchdogBaselineCarryTest do
  @moduledoc """
  bd-2oo8kf / #1062 — the vs-6myyiu shape: a coordinator's `accept_as_is` ruling
  on H, then a sync (update-branch) moves the PR to H'. With H' provably H plus
  the target's own delta (a real checkout, `Arbiter.Mergers.SyncProof`) the
  ruling is carried and the merge proceeds pinned to H'; with any extra content
  the ruling is voided and the coordinator is told, exactly as before.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.GitFixture

  alias Arbiter.ReviewGate.{Resolutions, Round, RoundsReport}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.{StubAutoResumeDispatcher, StubFixPassDispatcher, StubMerger}
  alias Arbiter.Worker.Watchdog

  @ref "!carry1"

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    StubFixPassDispatcher.reset()
    :ok
  end

  defp fixture do
    fx = origin_and_clone(%{"lib/widget.ex" => "w1\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])
    reviewed = commit!(fx.origin, %{"lib/widget.ex" => "w1\nw2\n"}, "feature work")
    git!(fx.origin, ["checkout", "-q", "main"])
    commit!(fx.origin, %{"lib/other.ex" => "o1\n"}, "unrelated main work")
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.clone, ["fetch", "-q", "origin"])
    Map.put(fx, :reviewed, reviewed)
  end

  defp ruled_task(fx) do
    ws =
      Ash.create!(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "wbc#{System.unique_integer([:positive])}",
        config: %{"repo_paths" => %{"widget" => fx.clone}}
      })

    task =
      Ash.create!(Issue, %{
        title: "ruled",
        description: "body",
        workspace_id: ws.id,
        repo: "widget",
        last_reviewed_sha: fx.reviewed
      })

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: :request_changes,
        findings: "[high] a.ex:1 needs a guard",
        finding_count: 1
      })

    {:ok, _} =
      Resolutions.record(
        %{
          task_id: task.id,
          decision: :accept_as_is,
          reasoning: "ship it",
          head_sha: fx.reviewed,
          actor: "coordinator"
        },
        resume: false
      )

    {ws, task}
  end

  # Ruled head → behind the base (the Watchdog issues update-branch) → synced head.
  defp sync_timeline(fx, synced) do
    StubMerger.queue_get(@ref, [
      %{
        status: :open,
        approved: true,
        head_sha: fx.reviewed,
        base_ref: "main",
        block_reason: :behind_base
      },
      %{status: :open, approved: true, head_sha: synced, base_ref: "main"}
    ])

    # The forge's own diffs disagree, so neither net-diff equality nor anything
    # but the sync proof can be what carries the ruling.
    StubMerger.set_diff(@ref, fx.reviewed, "diff --git a/x b/x\n+ruled\n")
    StubMerger.set_diff(@ref, synced, "diff --git a/x b/x\n+something else\n")
  end

  defp start_watchdog(ws, task) do
    :ok = Watchdog.subscribe(task.id)

    {:ok, pid} =
      Watchdog.start(
        task_id: task.id,
        mr_ref: @ref,
        adapter: StubMerger,
        workspace: ws,
        repo: "widget",
        auto_merge: true,
        via_review_gate: true,
        interval_ms: 15,
        initial_delay_ms: 0,
        max_auto_resolve_attempts: 2,
        fix_pass_dispatcher: StubFixPassDispatcher,
        auto_resume_dispatcher: StubAutoResumeDispatcher
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    pid
  end

  test "an accept_as_is ruling survives an update-branch rebase with identical patch-ids" do
    fx = fixture()
    git!(fx.origin, ["rebase", "-q", "main"])
    synced = git!(fx.origin, ["rev-parse", "HEAD"])
    {ws, task} = ruled_task(fx)
    sync_timeline(fx, synced)

    start_watchdog(ws, task)

    task_id = task.id
    assert_receive {:watchdog, ^task_id, {:merged, _}}, 5_000
    assert StubMerger.update_branch_count(@ref) >= 1
    assert StubMerger.last_merge() == {@ref, synced}
    assert Ash.get!(Issue, task.id).state == :closed

    report = RoundsReport.build(task.id)
    assert List.last(report.resolutions).head_sha == synced
    assert [%{baseline: "ruling", from_sha: from, head_sha: ^synced}] = report.carries
    assert from == fx.reviewed
  end

  test "an accept_as_is ruling survives an update-branch merge whose tree equals merge-tree" do
    fx = fixture()
    git!(fx.origin, ["merge", "-q", "--no-ff", "--no-edit", "main"])
    synced = git!(fx.origin, ["rev-parse", "HEAD"])
    {ws, task} = ruled_task(fx)
    sync_timeline(fx, synced)

    start_watchdog(ws, task)

    task_id = task.id
    assert_receive {:watchdog, ^task_id, {:merged, _}}, 5_000
    assert StubMerger.last_merge() == {@ref, synced}
    assert [%{baseline: "ruling"}] = RoundsReport.build(task.id).carries
  end

  test "an extra commit on the synced head voids the ruling exactly as today" do
    fx = fixture()
    git!(fx.origin, ["rebase", "-q", "main"])
    synced = commit!(fx.origin, %{"lib/evil.ex" => "x\n"}, "extra")
    {ws, task} = ruled_task(fx)
    sync_timeline(fx, synced)

    start_watchdog(ws, task)

    task_id = task.id
    assert_receive {:watchdog, ^task_id, {:unreviewed_head, ^synced}}, 5_000
    assert StubMerger.merge_count(@ref) == 0
    assert RoundsReport.build(task.id).carries == []
    assert length(Resolutions.list(task.id)) == 1
  end
end
