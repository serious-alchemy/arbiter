defmodule Arbiter.Workflows.MergedPRFinalizer do
  @moduledoc """
  Per-repo GenServer that sweeps open arbiter tasks with a `pr_ref` and
  finalizes those whose PR was merged on GitHub outside arbiter's merge queue
  (or after the worker/Watchdog for that task was gone).

  ## Problem this solves

  When a PR is merged manually on GitHub — or merged after the worker and its
  `restart: :temporary` Watchdog have already exited — nothing polls for the
  merge. The linked Jira ticket stalls at "In Code Review" and the arbiter task
  stays open indefinitely. This was the root cause of the AX-17892 symptom.

  ## Detection

  On each tick the finalizer:

    1. Queries `Issue` for tasks in this workspace with `pr_ref != nil` and
       `status != :closed`. A task already parked at `:awaiting_verification`
       (bd-9so315) is excluded too: its PR *is* merged, so without that the
       sweep would try to re-finalize it on every tick.
    2. For each, calls `adapter.get(pr_ref)` — the same forge call the Watchdog
       uses — and checks whether `status == :merged`.
    3. If merged, fires `Arbiter.Trackers.Sync.lifecycle(task, :merged)` and
       then closes the task with `close_upstream: true`.

  Tasks whose PR returns an API error (e.g. 404 from a different repo in a
  multi-repo workspace) are silently skipped — the finalizer for the correct
  repo picks them up.

  ## Cost (bd-8y1i58)

  Every call this sweep makes is unattended periodic polling, so it runs under
  the limiter's `:background` class (`Arbiter.GitHub.Limiter.with_priority/3`)
  and is shed before it can starve foreground work or the operator's own `gh`.

  It is also **budgeted**: at most `:max_checks_per_tick` tasks are checked per
  sweep (default 25, app env `:merged_pr_finalizer_max_checks_per_tick`; a
  non-positive value disables the cap). Without it the sweep cost scaled with
  the whole open backlog on every tick — one GitHub call per open task every
  120s — which by itself exhausted the account's hourly quota on an idle fleet.
  The window rolls: `cursor` remembers the last task swept and the next tick
  resumes after it, wrapping at the end, so the tail of a backlog larger than
  one budget is still reached (just later).

  ## Relationship to PRPatrol

  PRPatrol queries `list_open()` (open PRs only, never merged) and deliberately
  uses `tracker_type: :none` on its follow-up tasks to avoid transitioning
  merged PRs. This module works the orthogonal path: it queries open **arbiter
  tasks** that have their own `pr_ref`, and finalizes exactly those.

  In addition, this module sweeps PRPatrol follow-up tasks that were never
  assigned their own `pr_ref` but whose **source PR** has since merged. Two
  formats are handled:

    * Modern: `source_pr` field set (added by bd-ci2jl2, `tracker_type: :none`).
    * Legacy: `tracker_type: :github`, `tracker_ref` is a bare PR number,
      `source_pr` nil (pre-bd-ci2jl2 format) — and, since bd-6dghdv, only a
      task that carries PRPatrol's own markers (the `PR #<n>: … needs
      follow-up` title with `n == tracker_ref`, and the `Auto-filed by PRPatrol
      against <owner/repo>.` description naming exactly the repo this
      finalizer queries). An ordinary GitHub-issue-tracked task has the same
      columns, but its `tracker_ref` is an *issue* number: treating it as a PR
      number closed 20 ordinary tasks when a repo move renumbered issues 1–38
      onto the old repo's merged PRs #1–#38.

  Every close logs the rule that matched (`rule=pr_ref|source_pr|
  legacy_tracker_ref`) and the owner/repo queried.

  **Critical guard:** these tasks are closed local-only — `Sync.lifecycle` is
  NOT invoked. For modern follow-ups `tracker_type: :none` would already
  short-circuit it, but for legacy tasks with `tracker_type: :github` the
  `tracker_ref` is a merged-PR number, and transitioning a merged PR returns
  `Validation Failed` (bd-ci2jl2 hazard). Closing via an explicit
  `close_upstream: false` (bd-2wilou flipped the `:close` action's default to
  `true`) avoids any upstream write-back.

  ## Idempotency

  `Sync.lifecycle/2` is best-effort and logs quietly on a benign non-transition
  (`:transition_not_found`, `:status_unmapped`). The `:close` action on an
  already-closed task is blocked by `GuardStatus` and returns an error, which
  is caught and logged without crashing the sweep.

  ## Lifecycle

  Not in `Application.children`. Started per-workspace via
  `MergedPRFinalizerSupervisor` — one instance per (workspace, repo).
  Test convenience: `tick/1` forces a synchronous sweep.

  The workspace is re-read every tick (bd-6dghdv), so a config edit applies on
  the next sweep. The `repo` is fixed per instance: a workspace edit that moves
  it makes `MergedPRFinalizerSupervisor.reconcile/1` replace the instance, and
  until then a tick whose workspace no longer resolves to `repo` sweeps
  nothing.
  """

  use GenServer

  alias Arbiter.GitHub.Limiter
  alias Arbiter.{Mergers, Tasks.Workspace}
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Verification
  alias Arbiter.Trackers.Sync
  alias Arbiter.Worker
  alias Arbiter.Workflows.{MergedPRFinalizerSupervisor, PatrolRepoScope, PatrolServer}
  require Ash.Query
  require Logger

  @default_interval_ms 120_000
  @default_max_checks_per_tick 25

  defstruct [
    :repo,
    :workspace_id,
    :workspace,
    :interval_ms,
    :timer_ref,
    :cursor,
    max_checks_per_tick: @default_max_checks_per_tick,
    ticks: 0,
    last_tick_at: nil
  ]

  # ---- public API ----

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Synchronously force a finalizer sweep. Returns :ok after the sweep completes."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Snapshot of internal state."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    max_checks_per_tick =
      Keyword.get(
        opts,
        :max_checks_per_tick,
        Application.get_env(
          :arbiter,
          :merged_pr_finalizer_max_checks_per_tick,
          @default_max_checks_per_tick
        )
      )

    # bd-6dghdv: the workspace is NOT loaded here — `do_tick_body/1` re-reads
    # it every tick, so a config edit takes effect without a restart.
    state = %__MODULE__{
      repo: repo,
      workspace_id: workspace_id,
      interval_ms: interval_ms,
      max_checks_per_tick: max_checks_per_tick
    }

    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    new_state = do_tick(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:state, _from, state) do
    {:reply,
     %{
       repo: state.repo,
       workspace_id: state.workspace_id,
       interval_ms: state.interval_ms,
       max_checks_per_tick: state.max_checks_per_tick,
       cursor: state.cursor,
       ticks: state.ticks,
       last_tick_at: state.last_tick_at
     }, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state) |> schedule_next()
    {:noreply, new_state}
  end

  # ---- sweep logic ----

  # bd-8y1i58: every GitHub call this sweep issues is unattended periodic
  # polling — the limiter's `:background` class by definition. Untagged, the
  # ambient class defaults to `:foreground`, so the sweep was both counted as
  # and treated as foreground: unshuttable even at zero headroom, and on an
  # install with a large open backlog it was thousands of calls per hour with
  # zero work in flight. The tag is process-scoped and `do_tick_body/1` runs
  # synchronously in this process, so it applies to every call below.
  defp do_tick(state) do
    Limiter.with_priority(:background, :merged_pr_finalizer, fn -> do_tick_body(state) end)
  end

  # bd-6dghdv: the workspace is re-read every tick (it used to be loaded once in
  # init/1), so a merge-config edit — credentials, owner/repo — is honoured on
  # the next tick without a restart. This finalizer is still pinned to the
  # `repo` it was started for, though: if the workspace no longer resolves to
  # that repo (merge.config or repo_paths moved), the tick queries nothing
  # rather than keep sweeping the old repo. `MergedPRFinalizerSupervisor.
  # reconcile/1`, run on workspace update, replaces it with a finalizer for the
  # new one.
  defp do_tick_body(state) do
    workspace = PatrolServer.refetch_workspace(state.workspace_id)
    state = %{state | workspace: workspace}

    {result, cursor} =
      with %Workspace{} <- workspace,
           true <- repo_still_configured?(workspace, state.repo),
           adapter when not is_nil(adapter) <- resolve_adapter(workspace),
           true <- function_exported?(adapter, :get, 1),
           :ok <- Mergers.prepare_with_repo(workspace, state.repo),
           {:ok, pr_ref_tasks} <- open_tasks_with_pr_ref(state.workspace_id),
           {:ok, follow_up_tasks} <- open_follow_up_tasks(state.workspace_id),
           {:ok, legacy_tasks} <- open_legacy_pr_tracker_tasks(state.workspace_id, state.repo) do
        candidates =
          Enum.sort_by(
            Enum.map(pr_ref_tasks, &{&1, :pr_ref}) ++
              Enum.map(follow_up_tasks, &{&1, :source_pr}) ++
              Enum.map(legacy_tasks, &{&1, :legacy_tracker_ref}),
            fn {task, _rule} -> task.id end
          )

        {window, next_cursor} = window(candidates, state.cursor, state.max_checks_per_tick)

        Enum.each(window, fn
          {task, :pr_ref} -> maybe_finalize(task, adapter, state.repo)
          {task, rule} -> maybe_finalize_follow_up(task, rule, adapter, state.repo)
        end)

        {:ok, next_cursor}
      else
        _ -> {:noop, state.cursor}
      end

    _ = result

    %{state | ticks: state.ticks + 1, last_tick_at: DateTime.utc_now(), cursor: cursor}
  end

  # bd-8y1i58: bound the per-tick fan-out. The sweep used to issue one GitHub
  # call per open task *every* tick, so its cost scaled with the backlog and
  # never fell to zero on an idle fleet. A flat cap alone would re-check the
  # same head of the list forever and never reach the tail, so the window rolls:
  # `cursor` holds the id of the last task swept, and the next tick resumes
  # after it, wrapping around at the end. Candidates are sorted by id, which is
  # stable across ticks even as tasks open and close.
  #
  # A non-positive budget disables the cap (sweep everything, the old
  # behaviour) — useful for a small install or a one-off catch-up.
  defp window(candidates, _cursor, budget) when not is_integer(budget) or budget <= 0,
    do: {candidates, nil}

  defp window([], _cursor, _budget), do: {[], nil}

  defp window(candidates, cursor, budget) do
    {before_cursor, after_cursor} =
      case cursor do
        nil -> {[], candidates}
        id -> Enum.split_while(candidates, fn {task, _} -> task.id <= id end)
      end

    window =
      (after_cursor ++ before_cursor)
      |> Enum.take(min(budget, length(candidates)))

    case List.last(window) do
      {task, _kind} -> {window, task.id}
      nil -> {window, nil}
    end
  end

  defp repo_still_configured?(workspace, repo) do
    if repo in MergedPRFinalizerSupervisor.finalizer_repos(workspace) do
      true
    else
      Logger.warning(
        "MergedPRFinalizer: workspace #{workspace.id} no longer resolves to repo=#{repo} — " <>
          "skipping the sweep (awaiting reconcile to a finalizer for the current repo)"
      )

      false
    end
  end

  defp resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  defp open_tasks_with_pr_ref(workspace_id) do
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        not is_nil(pr_ref) and
        status not in [:closed, :awaiting_verification]
    )
    |> Ash.read()
  end

  # Modern PRPatrol follow-ups: source_pr set, tracker_type: :none (bd-ci2jl2).
  # Excludes tasks that already have their own PR opened (pr_ref set) — those
  # are owned by the pr_ref pass. Also excludes ReviewPatrol engagements
  # (review_only: true) which share the source_pr field but must never be
  # closed by this sweep (disjointness invariant, see review_patrol.ex:270).
  defp open_follow_up_tasks(workspace_id) do
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        not is_nil(source_pr) and
        is_nil(pr_ref) and
        review_only != true and
        status not in [:closed, :awaiting_verification]
    )
    |> Ash.read()
  end

  # Legacy PRPatrol follow-ups: pre-bd-ci2jl2 format used tracker_type: :github
  # and stored the source PR number in tracker_ref. We only sweep tasks that
  # have no source_pr (already handled above) and no pr_ref (handled by the
  # pr_ref pass).
  #
  # bd-6dghdv: that query alone also matches every ordinary GitHub-issue-
  # tracked task, and a tracker_ref there is an ISSUE number. This used to rely
  # on the PR API 404ing on an issue number, which is only true in the repo
  # that issued it: after the move to serious-alchemy/arbiter renumbered issues
  # 1–38, each matched a merged PR of the same number in the queried repo, and
  # 20 ordinary tasks were closed. A tracker_ref is now treated as a PR number
  # only when the task is positively a PRPatrol follow-up (see
  # `legacy_pr_patrol_follow_up?/2`) filed against exactly the repo queried.
  defp open_legacy_pr_tracker_tasks(workspace_id, repo) do
    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        tracker_type == :github and
        not is_nil(tracker_ref) and
        is_nil(source_pr) and
        is_nil(pr_ref) and
        review_only != true and
        status not in [:closed, :awaiting_verification]
    )
    |> Ash.read()
    |> case do
      {:ok, tasks} -> {:ok, Enum.filter(tasks, &legacy_pr_patrol_follow_up?(&1, repo))}
      error -> error
    end
  end

  # The pre-bd-ci2jl2 `PRPatrol.create_follow_up/4` wrote exactly this shape:
  #
  #   title:       "PR #<n>: <PR title> needs follow-up"   (n == tracker_ref)
  #   description: "Auto-filed by PRPatrol against <owner/repo>.\n..."
  #
  # Both markers must hold, the title's number must be the tracker_ref, and the
  # description's repo must be the one this finalizer queries — so the number
  # is known to be a pull request in that repo, never an issue number or a PR
  # of some other repo.
  @doc false
  @spec legacy_pr_patrol_follow_up?(Issue.t(), String.t() | nil) :: boolean()
  def legacy_pr_patrol_follow_up?(
        %Issue{title: title, description: description, tracker_ref: ref},
        repo
      )
      when is_binary(title) and is_binary(description) and is_binary(ref) and is_binary(repo) do
    String.starts_with?(title, "PR ##{ref}: ") and
      String.ends_with?(title, " needs follow-up") and
      String.starts_with?(
        String.trim_leading(description),
        "Auto-filed by PRPatrol against #{repo}."
      )
  end

  def legacy_pr_patrol_follow_up?(_task, _repo), do: false

  defp maybe_finalize(%Issue{pr_ref: pr_ref} = task, adapter, repo) do
    if live_worker?(task) do
      skip_live_worker(task)
    else
      case adapter.get(pr_ref) do
        {:ok, %{status: :merged}} ->
          finalize(task, queried_repo(pr_ref, repo))

        # PR is open, approved-but-not-merged, closed without merge, or API
        # error (including 404 for a PR in a different repo). All are no-ops.
        _ ->
          :noop
      end
    end
  end

  defp finalize(%Issue{} = task, queried_repo) do
    Logger.info(
      "MergedPRFinalizer: detected externally-merged PR #{task.pr_ref} for task=#{task.id} " <>
        "rule=pr_ref repo=#{queried_repo} " <>
        "(tracker=#{task.tracker_type} ref=#{task.tracker_ref}) — finalizing"
    )

    Sync.lifecycle(task, :merged)

    # bd-9so315: the same funnel the merge queue uses — closes as before unless
    # the task carries `verify_after_deploy`, in which case it parks at
    # `:awaiting_verification` and escalates the restart-and-observe.
    case Verification.finalize_merged(task, close_upstream: true, mr_ref: task.pr_ref) do
      {:ok, :closed, _} ->
        Logger.info("MergedPRFinalizer: closed task=#{task.id}")

      {:ok, :awaiting_verification, _} ->
        Logger.info(
          "MergedPRFinalizer: task=#{task.id} merged but flagged verify_after_deploy — " <>
            "parked at :awaiting_verification pending a restart-and-observe result"
        )

      {:error, reason} ->
        Logger.warning("MergedPRFinalizer: failed to close task=#{task.id}: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "MergedPRFinalizer: error finalizing task=#{task.id}: #{Exception.message(e)}"
      )

      :ok
  end

  # Determines the source PR ref for a follow-up task from the rule that
  # selected it (modern: source_pr; legacy: tracker_ref, only ever reached for a
  # task `legacy_pr_patrol_follow_up?/2` identified) and closes the task
  # local-only if the source PR merged.
  defp maybe_finalize_follow_up(%Issue{} = task, rule, adapter, repo) do
    ref = follow_up_ref(task, rule)

    if live_worker?(task) do
      skip_live_worker(task)
    else
      case adapter.get(ref) do
        {:ok, %{status: :merged}} ->
          finalize_follow_up(task, rule, ref, queried_repo(ref, repo))

        _ ->
          :noop
      end
    end
  end

  defp follow_up_ref(%Issue{source_pr: source_pr}, :source_pr), do: source_pr
  defp follow_up_ref(%Issue{tracker_ref: tracker_ref}, :legacy_tracker_ref), do: tracker_ref

  # The owner/repo a ref is looked up in: a qualified `owner/repo#N` ref names
  # its own repo (`Github.get/1` resolves it there); a bare ref resolves against
  # this finalizer's repo, which `Mergers.prepare_with_repo/2` seeded.
  defp queried_repo(ref, repo) do
    case PatrolRepoScope.repo_of_ref(ref) do
      {:ok, slug} -> slug
      :bare -> repo
    end
  end

  # Run states that mean the worker is still actively doing something — the
  # complement, `:finished`, means its own job is done and it's just sitting
  # there waiting to be reaped (see actively_working?/1).
  @active_run_states [:starting, :working, :waiting]

  # bd-38l3px: does the task have a live worker registered right now? The sweep
  # is a fallback for orphaned tasks (worker/Watchdog gone) — a task with a live
  # worker is left to that worker to finalize, so a stale `pr_ref`/`source_pr`
  # from a prior run can never make this sweep close an in-flight task.
  #
  # bd-6w7j8h: registration alone isn't enough. `Worker.complete_now/2` never
  # stops the Worker GenServer — it lingers `:finished`, still
  # registered, until the task's `:close` action's after-action reaps it
  # (Worker.stop, mirrors `Arbiter.Workers.Reconciler`'s moduledoc on this same
  # reap-on-close design). If the task never gets closed — e.g. the MergeQueue
  # lost the item that would have closed it — a merely-registered-but-done
  # worker used to make this sweep defer to it forever: the fallback safety net
  # explicitly built to route around a stuck task instead got deadlocked
  # against it. Checking the worker's actual run state (not just its
  # registration) breaks that deadlock: only a worker still doing something
  # protects the task from finalization.
  #
  # bd-741sid: a Merging ticket has no worker at all — its Watchdog owns the
  # merge and finalizes the ticket itself — so a live Watchdog protects it too.
  defp live_worker?(%Issue{id: id}) when is_binary(id) do
    Arbiter.Worker.Watchdog.alive?(id) or
      case Worker.whereis(id) do
        nil -> false
        pid -> actively_working?(pid)
      end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp live_worker?(_), do: false

  defp actively_working?(pid) do
    case Worker.state(pid) do
      %{state: run_state} = snap -> run_state in @active_run_states and not parked?(snap)
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # bd-2g179m: a run `:waiting` on the review gate with no agent live is
  # parked, not working — with `merge.auto_merge` off an approved task sits
  # there until a human merges. Its PR merging is the fact the finalizer exists
  # to act on, and nothing else polls it (the worker holds no Watchdog once the
  # gate has verdicted), so it must not protect the task. A snapshot that says
  # nothing about `agent_live` is unknown, and stays protected.
  defp parked?(snap),
    do: Worker.awaiting_review_gate?(snap) and Map.get(snap, :agent_live) == false

  defp skip_live_worker(%Issue{} = task) do
    Logger.debug(
      "MergedPRFinalizer: skipping task=#{task.id} — a live worker owns it (not an orphan)"
    )

    :noop
  end

  # Closes a PRPatrol follow-up task local-only: no Sync.lifecycle, no
  # close_upstream. The source PR is a merged PR number — calling Sync.lifecycle
  # on it would attempt a tracker transition on a merged PR and fail with
  # Validation Failed (bd-ci2jl2 hazard).
  defp finalize_follow_up(%Issue{} = task, rule, source_ref, queried_repo) do
    Logger.info(
      "MergedPRFinalizer: source PR #{source_ref} merged — closing follow-up task=#{task.id} " <>
        "rule=#{rule} repo=#{queried_repo} (tracker=#{task.tracker_type} source_pr=#{task.source_pr} tracker_ref=#{task.tracker_ref})"
    )

    case Ash.update(task, %{close_upstream: false}, action: :close) do
      {:ok, _} ->
        Logger.info("MergedPRFinalizer: closed follow-up task=#{task.id}")

      {:error, reason} ->
        Logger.warning(
          "MergedPRFinalizer: failed to close follow-up task=#{task.id}: #{inspect(reason)}"
        )
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "MergedPRFinalizer: error closing follow-up task=#{task.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
