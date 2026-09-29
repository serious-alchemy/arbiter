defmodule Arbiter.Workers.Reconciler do
  @moduledoc """
  Reconciles orphaned live `Arbiter.Workers.Run` rows on boot.

  A worker GenServer is ephemeral: it writes its Run row on init, keeps the
  row's state in step (`:starting` / `:working` / `:waiting`), and stamps it
  `:finished` with an outcome when it stops (`Arbiter.Workers.RunState`). If
  the node dies before that last write — a crash, a hard restart — the row is
  left live forever. `arb prime` tracks live processes, so it correctly shows
  no active workers, but the durable history lies: it claims work is still in
  flight when the process that owned it is long gone.

  This module sweeps those orphans. A live row (`:working`, and the rarer
  `:starting` / `:waiting`) whose `task_id` has no live worker registered under
  `Arbiter.Worker.Registry` is marked `:finished` / `:interrupted` with a
  `failure_reason` of `"server restarted"` (bd-1uu19b): the run did not fail,
  the server stopped under it. Run on application start (see
  `Arbiter.Application`) after the Repo and the Worker Registry are online.

  This is the **backstop**, not the shutdown path. Since bd-aje6fj a worker
  traps exits, so an orderly application stop runs its `terminate/2`, which
  reaps the agent and stamps the run `:finished` / `:interrupted`, "server
  shutdown", itself.
  Only a run that missed that — a hard crash of the node, a teardown that
  overran `Arbiter.Worker.shutdown_grace_ms/0` and was killed, systemd's stop
  timeout firing first — is still live when this sweep sees it.

  ## Single-instance gate

  Liveness is keyed off the LOCAL process registry, which is empty on a fresh
  boot — so this sweep is only correct on the *one* canonical instance per DB.
  A second instance booting against the same DB (e.g. an worker running
  `mix phx.server` / `iex -S mix` / `mix run` while the real server is up) has
  an empty registry too, so it would mistake the primary instance's live runs
  for orphans and fail them. The boot path therefore gates the sweep on
  `Arbiter.SingleInstance.primary?/0` (a session advisory lock) and passes the
  verdict as the `:primary?` option; a non-primary boot skips the sweep
  entirely and returns `{:ok, :skipped}`. See bd-9rouwh / bd-6k8519.

  The sweep is best-effort: a DB hiccup logs a warning and returns `{:error, _}`
  rather than crashing the supervision tree at boot.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.Resolver, as: AccountResolver
  alias Arbiter.Messages.Escalation
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergedPRFinalizerSupervisor
  alias Arbiter.Workflows.PRPatrolSupervisor
  alias Arbiter.Workflows.ReviewPatrolSupervisor

  # The failure_reason stamped onto reconciled orphans. Distinct, greppable,
  # and human-legible on the dashboard's "Completed Workers" view.
  @failure_reason "server restarted"

  # bd-146u20: what `Arbiter.Worker` stamps on a graceful shutdown, and the
  # `:machine_died` stamp a shutdown used to leave instead. The window covers
  # systemd's 45s stop timeout plus the restart, with room for a slow deploy.
  @shutdown_reason "server shutdown"
  @machine_died_reason ":machine_died"
  @shutdown_window_ms 300_000

  @doc """
  Sweep live Run rows with no live worker and mark them `:finished` /
  `:interrupted`, "server restarted".

  Returns `{:ok, count}` where `count` is the number of rows reconciled, or
  `{:error, reason}` if the read failed (in which case nothing was written).

  ## Options

    * `:primary?` — whether this instance is the canonical single instance and
      may sweep. Defaults to `true` (the mechanism is permissive on its own;
      the boot path supplies the real verdict from `Arbiter.SingleInstance`).
      When `false`, the sweep is skipped and `{:ok, :skipped}` is returned
      without touching any row — this is what keeps a transient/duplicate boot
      from failing the primary instance's live runs.
  """
  @spec reconcile_orphaned_runs(keyword()) ::
          {:ok, non_neg_integer() | :skipped} | {:error, term()}
  def reconcile_orphaned_runs(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile()
    else
      Logger.info(
        "Workers.Reconciler: not the primary instance; skipping orphan sweep " <>
          "(advisory lock held elsewhere)"
      )

      {:ok, :skipped}
    end
  end

  defp do_reconcile do
    orphans =
      Run
      |> Ash.Query.filter(state in [:starting, :working, :waiting])
      |> Ash.read!()
      |> Enum.reject(&live_worker?/1)

    reconciled = Enum.count(orphans, &mark_interrupted/1)

    if reconciled > 0 do
      Logger.info(
        "Workers.Reconciler: marked #{reconciled} orphaned live run(s) finished/interrupted"
      )
    end

    {:ok, reconciled}
  rescue
    e ->
      Logger.warning("Workers.Reconciler: sweep failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  Re-stamp runs a server shutdown recorded as `:failed` / `:machine_died` as
  what they were: `:interrupted` / "server shutdown". bd-146u20 / #2053.

  Before bd-146u20 an application stop could fail a live worker `:machine_died`
  (its `Arbiter.Worker.Driver` saw the workflow Machine shut down first and
  failed the worker ahead of the worker's own terminate/2). That parked resumable
  work as a failure: the resume sweep passed it over and the task lost its slot.
  A release still carrying that bug is the one being stopped on the next deploy,
  so the booting release corrects its rows.

  A `:machine_died` run is a shutdown casualty when it completed within
  `:shutdown_window_ms` (default #{div(@shutdown_window_ms, 1_000)}s) before this
  node booted: the stop that killed it is what this boot follows. A genuine
  machine crash that far from a restart is left alone.

  Run it before `reconcile_resumable_tasks/1`, which then resumes the task
  (`Arbiter.Worker.ResumeSlot.cut_off_by_restart?/1` picks an open-PR task's
  cut-off revision up; whether the resume needs a slot is the ticket state's).

  ## Options

    * `:primary?` — same single-instance gate as `reconcile_orphaned_runs/1`.
    * `:booted_at` — when this node booted. Defaults to the VM's start time.
    * `:shutdown_window_ms` — how long before boot counts as the shutdown.
  """
  @spec reconcile_shutdown_casualties(keyword()) ::
          {:ok, non_neg_integer() | :skipped} | {:error, term()}
  def reconcile_shutdown_casualties(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      booted_at = Keyword.get_lazy(opts, :booted_at, &vm_booted_at/0)
      window_ms = Keyword.get(opts, :shutdown_window_ms, @shutdown_window_ms)
      do_reconcile_shutdown_casualties(DateTime.add(booted_at, -window_ms, :millisecond))
    else
      {:ok, :skipped}
    end
  end

  defp do_reconcile_shutdown_casualties(since) do
    casualties =
      Run
      |> Ash.Query.filter(
        outcome == :failed and failure_reason == ^@machine_died_reason and
          completed_at >= ^since
      )
      |> Ash.read!()
      |> Enum.reject(&live_worker?/1)

    restamped = Enum.count(casualties, &restamp_interrupted/1)

    if restamped > 0 do
      Logger.info(
        "Workers.Reconciler: re-stamped #{restamped} :machine_died run(s) from the " <>
          "shutdown window as interrupted (server shutdown)"
      )
    end

    {:ok, restamped}
  rescue
    e ->
      Logger.warning(
        "Workers.Reconciler: shutdown-casualty sweep failed: #{Exception.message(e)}"
      )

      {:error, e}
  end

  defp restamp_interrupted(%Run{} = run) do
    case Ash.update(run, %{outcome: :interrupted, failure_reason: @shutdown_reason},
           action: :update
         ) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning(
          "Workers.Reconciler: failed to re-stamp run for task=#{run.task_id}: #{inspect(reason)}"
        )

        false
    end
  end

  defp vm_booted_at do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    DateTime.add(DateTime.utc_now(), -uptime_ms, :millisecond)
  end

  @doc """
  Re-establish monitoring for orphaned `:in_progress` Issues whose PR is still
  open (or which are review-only engagements), instead of merely escalating
  them.

  After a reboot nothing in memory is following any PR. bd-741sid: a
  `:merging` ticket owns its PR's state and its Watchdog is restartable from
  the row alone, so every Merging ticket with no live Watchdog gets one again
  (`Arbiter.Worker.Watchdog.restart/2`) — polling resumes exactly where it was,
  with no escalation and no worker. One an operator pulled out of the merge
  queue (`Arbiter.Tasks.PullRequest.pull/1`) is left as it is.

  The patrol layer (`PRPatrol` + `MergedPRFinalizer`, or `ReviewPatrol` for
  review-only engagements) remains the durable watcher for what a Watchdog does
  not cover: a Merging ticket whose Watchdog cannot start, and an In-progress
  ticket with a PR on record whose run the restart cut off. This sweep hands
  those back to that layer explicitly so:

    * `MergedPRFinalizer` finalizes the task when the PR merges (keys on `pr_ref`), and
    * `PRPatrol` re-drives review-feedback (CHANGES_REQUESTED / unresolved threads).

  Escalation is kept only as the last fallback: a task whose workspace has no
  patrol coverage (e.g. no hosted-forge merger configured) can't be
  auto-watched, so it still lands in the coordinator's mailbox rather than
  being silently dropped.

  Respects the `worker_live?` guard (C6): a task that still has a live worker is
  left untouched — no duplicate watcher is established.

  Returns `{:ok, %{watched: n, rewatched: n, escalated: n}}`, `{:ok, :skipped}`
  when not the primary instance, or `{:error, reason}`.

  ## Options

    * `:primary?` — same single-instance gate as `reconcile_orphaned_runs/1`.
      When `false`, skips and returns `{:ok, :skipped}`.
    * `:watch_fun` — 1-arity fun `(Issue.t() -> :ok | {:error, term()})` that
      starts a Merging ticket's Watchdog. Defaults to `Watchdog.restart/1` on
      the ticket id.
    * `:rewatch_fun` — 1-arity fun `(Issue.t() -> :ok | {:error, term()})` used to
      re-establish patrol coverage for a task. Defaults to `&default_rewatch/1`
      (starts the real patrol supervisors for the task's workspace). Injectable so
      tests can drive the re-watch/escalate branches without booting patrols.
  """
  @spec reconcile_open_pr_tasks(keyword()) ::
          {:ok,
           %{
             watched: non_neg_integer(),
             rewatched: non_neg_integer(),
             escalated: non_neg_integer()
           }
           | :skipped}
          | {:error, term()}
  def reconcile_open_pr_tasks(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile_open_pr_tasks(
        Keyword.get(opts, :watch_fun, &default_watch/1),
        Keyword.get(opts, :rewatch_fun, &default_rewatch/1)
      )
    else
      {:ok, :skipped}
    end
  end

  defp do_reconcile_open_pr_tasks(watch_fun, rewatch_fun) do
    stuck =
      Issue
      |> Ash.Query.filter(status == :in_progress)
      |> Ash.read!()
      |> Enum.reject(&live_worker_for_issue?/1)
      |> Enum.filter(&rewatchable?/1)
      |> Enum.reject(&watched?/1)

    counts =
      Enum.reduce(stuck, %{watched: 0, rewatched: 0, escalated: 0}, fn issue, counts ->
        case reconcile_open_pr(issue, watch_fun, rewatch_fun) do
          :none -> counts
          outcome -> Map.update!(counts, outcome, &(&1 + 1))
        end
      end)

    if counts.watched + counts.rewatched + counts.escalated > 0 do
      Logger.info(
        "Workers.Reconciler: open-PR sweep — watched #{counts.watched}, re-watched " <>
          "#{counts.rewatched}, escalated #{counts.escalated}"
      )
    end

    {:ok, counts}
  rescue
    e ->
      Logger.warning("Workers.Reconciler: open-PR task sweep failed: #{Exception.message(e)}")

      {:error, e}
  end

  @doc """
  Resume orphaned `:in_progress` Issues that were mid-flight (a `:running` /
  revising worker killed by the restart) but have **no** open PR yet — via the
  existing `bd-auma3z` resume path (`Arbiter.Worker.Dispatch.resume/2`), which
  re-attaches a fresh agent to the task's *preserved* worktree.

  Resume is delegated to `Dispatch.resume/2`, which already enforces the safety
  guards this sweep requires: it refuses a closed task, refuses when a worker is
  still active for the task (the `worker_live?` / C6 guard — no duplicate worker),
  and refuses (`{:error, :no_outpost}`) when the worktree was cleaned up. Any task
  that cannot be safely resumed falls back to an escalation rather than being
  dropped.

  Open-PR / awaiting_review tasks whose last run ended on its own terms are
  intentionally **not** handled here — they belong to the patrol layer via
  `reconcile_open_pr_tasks/1`; resuming them would spawn a redundant worker to
  redo already-shipped work. The exception (bd-146u20 / #2053) is an open-PR
  task whose latest main run the restart itself cut off
  (`Arbiter.Worker.ResumeSlot.cut_off_by_restart?/1` — a revision or fix pass on
  the PR that was mid-flight): a patrol only watches the PR, so without a resume
  that work is simply lost until an operator restarts it by hand.

  Returns `{:ok, %{resumed: non_neg_integer(), escalated: non_neg_integer()}}`,
  `{:ok, :skipped}` when not the primary instance, or `{:error, reason}`.

  ## Options

    * `:primary?` — same single-instance gate as `reconcile_orphaned_runs/1`.
    * `:resume_fun` — 1-arity fun `(Issue.t() -> {:ok, term()} | {:error, term()})`
      used to resume a task. Defaults to `&default_resume/1` (the real
      `Dispatch.resume/2`). Injectable so tests can exercise the resume/escalate
      branches without spawning a real worker.
  """
  @spec reconcile_resumable_tasks(keyword()) ::
          {:ok, %{resumed: non_neg_integer(), escalated: non_neg_integer()} | :skipped}
          | {:error, term()}
  def reconcile_resumable_tasks(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile_resumable_tasks(Keyword.get(opts, :resume_fun, &default_resume/1))
    else
      {:ok, :skipped}
    end
  end

  defp do_reconcile_resumable_tasks(resume_fun) do
    stuck =
      Issue
      |> Ash.Query.filter(status == :in_progress)
      |> Ash.read!()
      # bd-741sid: a Merging ticket's PR is its Watchdog's, which
      # `reconcile_open_pr_tasks/1` restarts from the row. A revision runs with
      # its ticket In progress, so a cut-off run on a Merging ticket can only
      # be an implementer parked on its PR before bd-741sid, its work done.
      |> Enum.reject(&(&1.state == :merging or live_worker_for_issue?(&1) or review_only?(&1)))
      |> Enum.filter(&(is_nil(&1.pr_ref) or ResumeSlot.cut_off_by_restart?(&1.id)))

    {resumed, escalated} =
      Enum.reduce(stuck, {0, 0}, fn issue, {res, esc} ->
        case resume_fun.(issue) do
          {:ok, %{deferred: true}} ->
            Logger.info(
              "Workers.Reconciler: task #{issue.id} is not In progress, so holds no slot; " <>
                "its resume is deferred until a worker slot frees"
            )

            {res + 1, esc}

          {:ok, _result} ->
            Logger.info(
              "Workers.Reconciler: resumed mid-flight task #{issue.id} from its preserved worktree"
            )

            {res + 1, esc}

          {:error, reason} ->
            Logger.warning(
              "Workers.Reconciler: cannot safely resume task #{issue.id} " <>
                "(#{inspect(reason)}) — escalating"
            )

            if escalate_stuck_issue(issue, {:unresumable, reason}),
              do: {res, esc + 1},
              else: {res, esc}
        end
      end)

    if resumed + escalated > 0 do
      Logger.info("Workers.Reconciler: resume sweep — resumed #{resumed}, escalated #{escalated}")
    end

    {:ok, %{resumed: resumed, escalated: escalated}}
  rescue
    e ->
      Logger.warning("Workers.Reconciler: resumable task sweep failed: #{Exception.message(e)}")

      {:error, e}
  end

  # An orphaned in_progress task is re-watchable (belongs to the patrol layer)
  # when it has an open PR of its own (pr_ref) or is a review-only engagement
  # (driven by ReviewPatrol via source_pr).
  defp rewatchable?(%Issue{} = issue), do: not is_nil(issue.pr_ref) or review_only?(issue)

  defp review_only?(%Issue{review_only: true}), do: true
  defp review_only?(%Issue{}), do: false

  defp live_worker_for_issue?(%Issue{id: task_id}), do: not is_nil(Worker.whereis(task_id))

  # bd-741sid: a ticket whose Watchdog is running is watched already.
  defp watched?(%Issue{id: task_id}), do: Watchdog.alive?(task_id)

  # One orphaned open-PR ticket: `:watched`, `:rewatched`, `:escalated` or
  # `:none` (an escalation deduped away, or a ticket pulled out of the merge
  # queue, left as the operator left it). A Merging ticket gets its Watchdog
  # back from its row; only when that cannot start does it fall back to the
  # patrols, and past them to the coordinator.
  defp reconcile_open_pr(%Issue{state: :merging} = issue, watch_fun, rewatch_fun) do
    case watch_fun.(issue) do
      result when result in [:ok, {:error, :already_running}] ->
        Logger.info(
          "Workers.Reconciler: Merging ticket #{issue.id} (PR #{issue.pr_ref}) is watched " <>
            "again — its Watchdog restarted from the row"
        )

        :watched

      # An operator pulled it out of the merge queue (`PullRequest.pull/1`);
      # a reboot does not put it back. `MergedPRFinalizer` still closes it if
      # someone merges the PR by hand.
      {:error, :pulled} ->
        Logger.info(
          "Workers.Reconciler: Merging ticket #{issue.id} (PR #{issue.pr_ref}) was pulled out " <>
            "of the merge queue; leaving it unwatched"
        )

        :none

      {:error, reason} ->
        Logger.warning(
          "Workers.Reconciler: could not restart the Watchdog for Merging ticket #{issue.id} " <>
            "(PR #{issue.pr_ref}): #{inspect(reason)} — handing it to the patrols"
        )

        rewatch_or_escalate(issue, rewatch_fun)
    end
  end

  # bd-741sid: a fix or conflict pass the restart cut off leaves its ticket In
  # progress with the PR still open and nothing working it. Back to Merging,
  # which restarts its Watchdog from the row: it sees the same red CI or
  # conflict and asks for the pass again.
  defp reconcile_open_pr(%Issue{state: :active} = issue, watch_fun, rewatch_fun) do
    if pass_cut_off?(issue.id) do
      case Arbiter.Tasks.PullRequest.back_to_merging(issue.id) do
        :ok ->
          Logger.info(
            "Workers.Reconciler: ticket #{issue.id}'s pass was cut off by the restart; " <>
              "back to Merging (PR #{issue.pr_ref})"
          )

          Issue |> Ash.get!(issue.id) |> watch_merging(watch_fun, rewatch_fun)

        {:error, reason} ->
          Logger.warning(
            "Workers.Reconciler: could not return ticket #{issue.id} to Merging after its " <>
              "pass was cut off: #{inspect(reason)}"
          )

          rewatch_or_escalate(issue, rewatch_fun)
      end
    else
      rewatch_or_escalate(issue, rewatch_fun)
    end
  end

  defp reconcile_open_pr(issue, _watch_fun, rewatch_fun),
    do: rewatch_or_escalate(issue, rewatch_fun)

  # `back_to_merging/1` restarts the Watchdog itself; count it, or start it now.
  defp watch_merging(%Issue{state: :merging} = issue, watch_fun, rewatch_fun) do
    if Watchdog.alive?(issue.id),
      do: :watched,
      else: reconcile_open_pr(issue, watch_fun, rewatch_fun)
  end

  defp watch_merging(issue, _watch_fun, rewatch_fun), do: rewatch_or_escalate(issue, rewatch_fun)

  # The ticket's latest run was a fix or conflict pass that the restart cut off
  # (the graceful-shutdown `:interrupted`, a row still live, or the orphan
  # sweep's "server restarted").
  defp pass_cut_off?(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Run{kind: kind} = run] when kind in [:fix_pass, :conflict] -> cut_off?(run)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp cut_off?(%Run{state: state}) when state != :finished, do: true
  defp cut_off?(%Run{outcome: :interrupted}), do: true

  defp cut_off?(%Run{failure_reason: reason}),
    do: reason in ["server restarted", "server shutdown"]

  defp rewatch_or_escalate(issue, rewatch_fun) do
    case rewatch_fun.(issue) do
      :ok ->
        Logger.info(
          "Workers.Reconciler: re-established patrol watching for in_progress task " <>
            "#{issue.id} (PR #{issue.pr_ref}) — handed to patrol layer, not escalated"
        )

        :rewatched

      {:error, reason} ->
        Logger.warning(
          "Workers.Reconciler: could not re-watch task #{issue.id} (PR #{issue.pr_ref}): " <>
            "#{inspect(reason)} — escalating"
        )

        if escalate_stuck_issue(issue, :open_pr), do: :escalated, else: :none
    end
  end

  defp default_watch(%Issue{id: task_id}), do: Watchdog.restart(task_id)

  # Default re-watch: hand the task back to the durable patrol layer for its
  # workspace. Review-only engagements go to ReviewPatrol; author-side open-PR
  # tasks go to PRPatrol (review-feedback follow-up) + MergedPRFinalizer (merge
  # finalization). All supervisor starts are idempotent — an already-running
  # patrol reports `{:error, {:already_started, _}}`, which we treat as covered.
  # Returns `:ok` when at least one relevant patrol is established, otherwise
  # `{:error, reason}` so the caller escalates as the fallback.
  defp default_rewatch(%Issue{workspace_id: workspace_id} = issue) do
    case load_workspace(workspace_id) do
      {:ok, %Workspace{} = workspace} ->
        results =
          if review_only?(issue) do
            [ReviewPatrolSupervisor.start_patrol(workspace)]
          else
            [
              PRPatrolSupervisor.start_patrol(workspace),
              MergedPRFinalizerSupervisor.start_finalizer(workspace)
            ]
          end

        if Enum.any?(results, &patrol_established?/1),
          do: :ok,
          else: {:error, {:no_patrol_coverage, results}}

      {:error, reason} ->
        {:error, {:workspace_unavailable, reason}}
    end
  end

  defp load_workspace(nil), do: {:error, :no_workspace}

  defp load_workspace(workspace_id) when is_binary(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, reason} -> {:error, reason}
    end
  end

  # A patrol is considered established either when we just started it or when it
  # was already running (idempotent start). `:skip` (no repos / unsupported
  # adapter) and any other error mean the workspace can't be watched.
  defp patrol_established?({:ok, _pid}), do: true
  defp patrol_established?({:error, {:already_started, _pid}}), do: true
  defp patrol_established?(_), do: false

  # bd-92mx1m: automatic. A task cut off mid-flight by the restart held its
  # slot and passes `ResumeSlot` uncapped; one that had parked or stopped before
  # the restart released it, and at a full cap is deferred to the scheduler.
  #
  # Public (`@doc false`) so the provider-routing tests (bd-40pzpj) can drive
  # the real resume this module performs; `opts` is merged over it.
  @doc false
  def default_resume(%Issue{id: task_id}, opts \\ []) do
    Dispatch.resume(
      task_id,
      Keyword.merge([resume_origin: :automatic, routing_role: :reconciler_resume], opts)
    )
  end

  defp escalate_stuck_issue(%Issue{} = issue, reason) do
    %Issue{id: task_id, pr_ref: pr_ref, workspace_id: workspace_id} = issue
    {subject, body} = escalation_copy(task_id, pr_ref, reason)

    Escalation.post(%{
      kind: :ticket_stuck,
      from_ref: "system",
      workspace_id: workspace_id,
      task_ref: task_id,
      subject: subject,
      body: body
    })

    true
  rescue
    e ->
      Logger.warning(
        "Workers.Reconciler: failed to escalate stuck task #{issue.id}: #{Exception.message(e)}"
      )

      false
  end

  defp escalation_copy(task_id, pr_ref, :open_pr) do
    subject = "#{task_id} stuck — PR ##{pr_ref} open but no live worker or patrol coverage"

    body =
      "Task #{task_id} has an open PR (#{pr_ref}) but no live worker, and its workspace has " <>
        "no patrol coverage to re-establish monitoring automatically.\n" <>
        "Action: verify the PR is ready to merge, then run `arb ticket dispatch #{task_id}` to re-drive " <>
        "or manually merge and close the task."

    {subject, body}
  end

  defp escalation_copy(task_id, _pr_ref, {:unresumable, reason}) do
    subject = "#{task_id} stuck — mid-flight worker lost and cannot be safely resumed"

    body =
      "Task #{task_id} was in_progress with no live worker after a restart, and could not be " <>
        "auto-resumed (#{inspect(reason)} — e.g. the worktree was cleaned up or the repo is " <>
        "unresolvable).\n" <>
        "Action: inspect the task state, then run `arb ticket dispatch #{task_id}` to re-drive from scratch."

    {subject, body}
  end

  # A run is live iff a worker GenServer is registered for its task_id. After a
  # boot the registry is empty, so every live row is an orphan; mid-life this
  # guards against racing a worker that is legitimately still working.
  defp live_worker?(%Run{task_id: task_id}), do: not is_nil(Worker.whereis(task_id))

  # Returns true when the row was successfully reconciled (so the caller can
  # count it), false on a per-row write failure that we've logged and skipped.
  defp mark_interrupted(%Run{} = run) do
    attrs = %{
      state: :finished,
      outcome: :interrupted,
      completed_at: DateTime.utc_now(),
      failure_reason: @failure_reason
    }

    case Ash.update(run, attrs, action: :update) do
      {:ok, updated} ->
        # bd-au3xrq: a node that died mid-run left no usage row (the worker
        # never reached its own record_usage_event). If this run captured its
        # Claude session coordinates, reconcile the token ledger from the
        # on-disk session JSONL that survived the crash.
        maybe_backfill_usage_from_disk(updated)
        true

      {:error, reason} ->
        Logger.warning(
          "Workers.Reconciler: failed to reconcile run for task=#{run.task_id}: #{inspect(reason)}"
        )

        false
    end
  end

  # Best-effort on-disk usage backfill for a just-reconciled orphan. Only fires
  # when the run recorded a `session_id` + `config_dir` (Claude runs past their
  # `init` event) AND no `Arbiter.Usage.Event` already exists for the run — so a
  # run whose stdout path DID land a row is never double-counted. Cost comes off
  # the file's own `cost-state` records when it has any (bd-be804c), and stays
  # nil when it doesn't. Any failure logs and is swallowed: backfilling the
  # ledger must never break the boot-time sweep.
  #
  # `since: run.started_at` is load-bearing, not decoration: a session-level
  # resume (`Dispatch.resume_session/2`) opens a NEW run row but re-spawns with
  # `--resume <sid>`, and the CLI appends to the SAME <sid>.jsonl. Reading the
  # whole file would bill this run for every token the parent run already spent
  # (and `usage_event_exists?/1` can't catch it — it's keyed on this run's id).
  # The cutoff bounds the read to this run's own turns.
  defp maybe_backfill_usage_from_disk(%Run{session_id: sid, config_dir: cfg} = run)
       when is_binary(sid) and sid != "" and is_binary(cfg) and cfg != "" do
    if usage_event_exists?(run.id) do
      :ok
    else
      case ClaudeSessionFile.usage_for(cfg, sid, since: run.started_at) do
        {:ok, %{message_count: n} = totals} when n > 0 ->
          write_reconciled_usage(run, totals)

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning(
        "Workers.Reconciler: usage backfill raised for task=#{run.task_id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp maybe_backfill_usage_from_disk(%Run{}), do: :ok

  defp usage_event_exists?(run_id) do
    Event
    |> Ash.Query.filter(worker_run_id == ^run_id)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> Kernel.!=([])
  end

  defp write_reconciled_usage(%Run{} = run, totals) do
    provider_account_id = AccountResolver.account_id(run.workspace_id, "claude")

    attrs = %{
      task_id: run.task_id,
      workspace_id: run.workspace_id,
      repo: run.repo,
      step: usage_step_for(run),
      model: run.model || totals.model,
      provider: "claude",
      provider_account_id: provider_account_id,
      provider_credential_id: AccountResolver.credential_id(provider_account_id),
      tokens_in: totals.tokens_in,
      tokens_out: totals.tokens_out,
      cache_creation_tokens: totals.cache_creation_tokens,
      cache_read_tokens: totals.cache_read_tokens,
      # The CLI's own figure, summed per `cost-state` segment and windowed by
      # `since` — never a locally recomputed price when one exists. A 2.1.270+
      # file carries no `cost-state` at all and falls back to a token-priced
      # estimate; either way `cost_note_for/1` records which it was, and a
      # model we can't price still lands as an explained null.
      cost_usd: totals.cost_usd,
      cost_note: ClaudeSessionFile.cost_note_for(totals),
      duration_ms: totals.duration_ms,
      worker_run_id: run.id,
      session_id: run.session_id,
      occurred_at: DateTime.utc_now(),
      # bd-3j4ch4: carry the run's place in the hierarchy onto the ledger row,
      # exactly as `Worker.record_usage_event/3` does for a live session.
      # Without it a reconciled review-gate implementer or merge-queue fix pass
      # lands as an unlabelled `step: :work` row, and every consumer that folds
      # subordinate passes onto the base task (`Arbiter.Usage.Estimate`) reads
      # it as a second base work session — i.e. a re-dispatch that never
      # happened.
      base_task_id: run.base_task_id || Worker.ReviewGate.base_task_id(run.task_id),
      role: run.role || usage_role_for(run.kind),
      raw: %{
        "arb_usage_source" => %{
          "reconciled_from" => "session_jsonl",
          "via" => "reconciler",
          "message_count" => totals.message_count,
          "skipped_before_since" => totals.skipped_before_since,
          "cost_state_count" => totals.cost_state_count
        }
      }
    }

    case Ash.create(Event, attrs) do
      {:ok, _ev} ->
        Logger.info(
          "Workers.Reconciler: reconciled usage from on-disk session JSONL for " <>
            "task=#{run.task_id} run=#{run.id} (#{totals.message_count} msgs, " <>
            "#{totals.tokens_in} in / #{totals.tokens_out} out)"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Workers.Reconciler: could not write reconciled usage for task=#{run.task_id}: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  end

  # Mirrors `Worker.record_usage_event/3`: only a reviewer and a review-gate
  # implementer get their own step; the merge queue's fix/conflict passes are
  # still work, distinguished by `role`.
  defp usage_step_for(%Run{kind: :review}), do: :review
  defp usage_step_for(%Run{role: "impl"}), do: :impl
  defp usage_step_for(_run), do: :work

  defp usage_role_for(:implement), do: "base"
  defp usage_role_for(nil), do: "base"
  defp usage_role_for(kind), do: Atom.to_string(kind)
end
