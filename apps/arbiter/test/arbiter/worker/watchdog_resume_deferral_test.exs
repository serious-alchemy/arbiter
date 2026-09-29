defmodule Arbiter.Worker.WatchdogResumeDeferralTest do
  @moduledoc """
  bd-985tkl / #1729 — the deferred auto-resume that nothing ever re-fired.

  bd-di4t6d gave the Watchdog a deferral: a resume refused because the task's
  own `<task>:fixpass` pass still holds the registry family is retried on the
  poll interval instead of paging. bd-3qkbch / #1724 and bd-bsdeb2 / #1732 both
  logged `deferral=1/30` and then *nothing* — no second deferral, no resume, no
  escalation — for 70+ minutes on an approved, CI-green, MERGEABLE PR.

  The reason the retry never came is the deferral's own first attempt:
  `Dispatch.resume/2` calls `stop_prior_worker/1` **before** `Worker.start/1`'s
  family check refuses, so the primary worker the Watchdog monitors exits as a
  direct consequence of the attempt that was just deferred. The Watchdog's
  `:DOWN` clause then stopped it — taking the `:retry_review_resume` timer with
  it. One deferral, then silence.

  These cases pin the whole episode: the deferral survives that `:DOWN`, it
  re-fires the moment the blocking pass finishes, a transient `:network` poll
  error in the middle neither clears nor duplicates it, and both terminal arms
  (budget spent, blocker vanished) park the task (its `attention_cause`)
  and page the coordinator exactly once — guard class E of
  `docs/review-coverage-and-guard-policy.md` §5.3 (fail open, one escalation,
  parked terminal), registry row `:resume_deferral_budget` (W14).

  bd-741sid: a Watchdog is keyed by its ticket and monitors no worker, so that
  `:DOWN` cannot recur; the first case now pins that a run on the ticket exiting
  mid-deferral leaves the deferral alone. The auto-resume count rides the
  ticket's lane (`auto_resumes`), which is what a Watchdog is started with,
  rather than a worker's meta.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wd-defer-#{System.unique_integer([:positive])}",
        prefix: "wdd"
      })

    {:ok, task} = Ash.create(Issue, %{title: "deferral", workspace_id: ws.id})
    task = put_state!(task, :active)

    %{ws: ws, task_id: task.id}
  end

  # ---- helpers -------------------------------------------------------------

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  # `max_polls: 1` puts the very first poll on the ceiling, so every case starts
  # at the exact moment the incident starts: the timeout is registered and the
  # auto-resume is attempted. bd-741sid: keyed by the ticket, with no worker.
  defp start_watchdog(task_id, mr_ref, ws, opts) do
    base = [
      task_id: task_id,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      interval_ms: 50,
      initial_delay_ms: 0,
      max_polls: 1,
      auto_resume_dispatcher: StubAutoResumeDispatcher
    ]

    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
  end

  # A stand-in for the `<task>:fixpass` worker process. It stays alive until the
  # test says the pass finished, exactly like a real fix pass.
  defp fixpass_worker do
    spawn(fn ->
      receive do
        :finish -> :ok
      after
        30_000 -> :ok
      end
    end)
  end

  # The exact refusal shape `Worker.start/1`'s single-active-worker guard
  # produces when a subordinate pass holds the family. Since bd-741sid a pass
  # registers under the ticket id and a live one refuses the resume as
  # `{:worker_active, _}` ("recovery already happened"); this `<task>:fixpass`
  # shape is the pre-bd-741sid registration, still handled as a transient block.
  defp fixpass_live(task_id, pid) do
    {:worker_start_failed,
     {:task_worker_live,
      %{
        pid: pid,
        status: :running,
        task_id: task_id,
        registry_key: task_id <> ":fixpass",
        requested_key: task_id
      }}}
  end

  defp wait_until(fun, timeout) do
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

  # ---- acceptance 1: the deferral survives, and re-fires on completion ------

  describe "a deferred auto-resume outlives the attempt that deferred it" do
    # bd-741sid: the Watchdog no longer monitors the primary worker, so this is
    # now a run on the ticket, unpaired, exiting mid-deferral.
    test "a run on the ticket exiting — which the resume attempt itself can cause — does not kill the deferral",
         %{task_id: task_id, ws: ws} do
      {:ok, run} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: ws.id)
      :ok = Worker.advance(run, :implement)
      on_exit(fn -> stop_quietly(run) end)

      blocker = fixpass_worker()
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker))

      wpid = start_watchdog(task_id, "!strand1", ws, max_resume_deferrals: 10)
      wref = Process.monitor(wpid)

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 1 end, 5_000)

      # `Dispatch.resume/2` frees the registry slot before the family check
      # refuses, so a run lingering under the ticket id is gone by the time
      # the Watchdog processes the deferral.
      stop_quietly(run)

      # The fix pass then finishes and a resume would take.
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker), 0)
      send(blocker, :finish)

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 2 end, 5_000)
      assert StubAutoResumeDispatcher.escalations() == []
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 5_000
    end

    test "the resume re-fires when the blocking fix pass completes, not on a retry tick that may never come",
         %{task_id: task_id, ws: ws} do
      blocker = fixpass_worker()
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker))

      # A retry interval far beyond the test's own timeout: only the fix pass
      # finishing can produce the second attempt.
      wpid =
        start_watchdog(task_id, "!strand2", ws,
          interval_ms: 60_000,
          max_resume_deferrals: 10
        )

      wref = Process.monitor(wpid)
      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 1 end, 5_000)

      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker), 0)
      send(blocker, :finish)

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 2 end, 5_000)
      assert StubAutoResumeDispatcher.escalations() == []
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 5_000
    end
  end

  # ---- the budget the retry inherits --------------------------------------

  describe "the auto-resume budget across a deferred retry" do
    test "a retry keeps the attempt count it inherited instead of restarting the budget at 1",
         %{task_id: task_id, ws: ws} do
      # Two auto-resumes already spent on this task. bd-741sid: the count rides
      # the ticket's lane (`auto_resumes`) — each round mints a fresh Watchdog,
      # which is started with it — rather than a worker's meta.
      blocker = fixpass_worker()
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker))

      wpid =
        start_watchdog(task_id, "!strand6", ws,
          interval_ms: 60_000,
          auto_resumes: 2,
          max_auto_resumes: 3,
          max_resume_deferrals: 10
        )

      wref = Process.monitor(wpid)
      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 1 end, 5_000)
      assert [%{attempt: 3}] = StubAutoResumeDispatcher.resumes()

      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker), 0)
      send(blocker, :finish)

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 2 end, 5_000)
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 5_000

      # Still attempt 3 — the deferral never spent one, and it never gave one
      # back either. Resuming as attempt 1 here would record 1 on the ticket's
      # lane and make the cap unbindable on exactly this path.
      assert [%{attempt: 3}, %{attempt: 3}] = StubAutoResumeDispatcher.resumes()
      assert Ash.get!(Issue, task_id).merge_watch["auto_resumes"] == 3
      assert StubAutoResumeDispatcher.escalations() == []
    end

    test "the escalation from a deferral that ran out reports the inherited attempt count, not 0",
         %{task_id: task_id, ws: ws} do
      blocker = fixpass_worker()
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker))

      wpid =
        start_watchdog(task_id, "!strand7", ws,
          interval_ms: 20,
          auto_resumes: 2,
          max_auto_resumes: 3,
          max_resume_deferrals: 2
        )

      wref = Process.monitor(wpid)
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 5_000

      assert [{^task_id, _ws_id, "!strand7", 2, {:resume_blocked, _blocked_by, 2}}] =
               StubAutoResumeDispatcher.escalations()
    end
  end

  # ---- acceptance 2: both terminal arms park + page exactly once ------------

  describe "the terminal arms park the task and page once (class E)" do
    test "the deferral budget running out parks with an attention cause and pages once",
         %{task_id: task_id, ws: ws} do
      blocker = fixpass_worker()
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker))

      wpid =
        start_watchdog(task_id, "!strand3", ws, interval_ms: 20, max_resume_deferrals: 2)

      wref = Process.monitor(wpid)
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 5_000

      # One initial attempt + exactly two deferred retries, then stop.
      assert StubAutoResumeDispatcher.resume_count() == 3

      assert [{^task_id, _ws_id, "!strand3", 0, {:resume_blocked, blocked_by, 2}}] =
               StubAutoResumeDispatcher.escalations()

      assert inspect(blocked_by) =~ "fixpass"

      {:ok, reloaded} = Ash.get(Issue, task_id)
      assert reloaded.attention_cause == :resume_blocked
      assert %DateTime{} = reloaded.attention_since
      # An attention cause, not a state — the work is still live.
      assert reloaded.state == :active
    end

    test "a blocker that disappears without a completion signal parks and pages once, well inside the budget",
         %{task_id: task_id, ws: ws} do
      dead = spawn(fn -> :ok end)
      wait_until(fn -> not Process.alive?(dead) end, 2_000)

      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, dead))

      wpid =
        start_watchdog(task_id, "!strand4", ws, interval_ms: 20, max_resume_deferrals: 30)

      wref = Process.monitor(wpid)
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 5_000

      # Nothing can ever signal completion for a blocker that is already gone,
      # so this must NOT sit out all 30 deferrals.
      assert StubAutoResumeDispatcher.resume_count() == 2

      assert [{^task_id, _ws_id, "!strand4", 0, {:resume_blocker_vanished, blocked_by, 2}}] =
               StubAutoResumeDispatcher.escalations()

      assert inspect(blocked_by) =~ "fixpass"

      {:ok, reloaded} = Ash.get(Issue, task_id)
      assert reloaded.attention_cause == :resume_blocked
    end
  end

  # ---- acceptance 3: a transient forge poll error is inert -----------------

  describe "a transient GitHub poll error during a deferral" do
    test "neither clears nor duplicates the deferral state",
         %{task_id: task_id, ws: ws} do
      blocker = fixpass_worker()
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker))

      # The `socket closed` the incident logged 22 times in three hours.
      StubMerger.queue_get("!strand5", [
        {:error, %Arbiter.Mergers.Github.Error{kind: :network, message: "socket closed"}}
      ])

      wpid =
        start_watchdog(task_id, "!strand5", ws,
          interval_ms: 60_000,
          max_resume_deferrals: 1
        )

      wref = Process.monitor(wpid)
      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 1 end, 5_000)

      for _ <- 1..3, do: send(wpid, :poll)
      # Synchronise: the Watchdog has handled all three by the time this returns.
      _ = :sys.get_state(wpid)

      # The deferral is untouched — no extra resume attempt, no page, and the
      # budget (1) is not spent.
      assert StubAutoResumeDispatcher.resume_count() == 1
      assert StubAutoResumeDispatcher.escalations() == []

      # ...and it still fires exactly once when the fix pass finishes.
      StubAutoResumeDispatcher.arm_resume_error(fixpass_live(task_id, blocker), 0)
      send(blocker, :finish)

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 2 end, 5_000)
      assert_receive {:DOWN, ^wref, :process, ^wpid, :normal}, 5_000

      assert StubAutoResumeDispatcher.resume_count() == 2
      assert StubAutoResumeDispatcher.escalations() == []
    end
  end
end
