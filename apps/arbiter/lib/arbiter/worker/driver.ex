defmodule Arbiter.Worker.Driver do
  @moduledoc """
  Drives a task to completion. Has two modes:

  ### Workflow mode (default)

  Ticks `Arbiter.Workflows.Machine` forward and mirrors its progress onto
  the paired `Arbiter.Worker`. Closes the task when the workflow
  completes. Used for bookkeeping-only workers.

  ### Claude-driven mode (`claude_driven: true`)

  A Claude subprocess is doing the real work; the Driver does NOT tick the
  Machine. Instead it polls the worker's run state and closes the task when
  the run finishes `:succeeded` (typically triggered by Claude printing
  `arb done` on stdout — see `Worker.ClaudeSession`).

  This mode resolves the Driver/Claude race that `arb dispatch --with-claude`
  exposed: the bookkeeping workflow used to finish in ~500ms and close the
  task before Claude had time to respond.

  ## Lifecycle (workflow mode)

  - On start: schedules the first tick immediately.
  - On each tick: calls `Machine.advance/1` and reacts:
    - `{:ok, :completed}` → `Worker.complete/2`, close the task, stop.
    - `{:ok, next_step}` → `Worker.advance/2`, schedule next tick.
    - `{:error, reason}` → `Worker.fail/2`, stop (task remains `:active`).

  ## Lifecycle (claude-driven mode)

  - On start: schedules the first worker check.
  - On each check: reads the worker's run state:
    - `:finished` / `:succeeded` → finalize the task (a `:merged` completion routes through
      `Arbiter.Tasks.Verification.finalize_merged/2`, so a `verify_after_deploy`
      task parks at `:verifying` rather than closing), optionally
      cleanup worktree, stop. A run that completed by opening its PR
      (`result: :pr_opened`, bd-741sid) finalizes nothing: its ticket is
      Merging, and the ticket's Watchdog closes it when the PR merges.
    - `:finished` otherwise → log, stop (task remains `:active` for
      inspection).
    - `:starting | :working | :waiting` → schedule next check (the
      ReviewGate, not the Driver, drives a run waiting on the review gate to
      its verdict).

  ## Shared lifecycle

  - On worker or machine `:DOWN`: stop cleanly; if the machine died first
    (workflow mode), finish the run `:failed`.

  ## Safety backstops

  `:max_ticks` bounds the loop. Defaults differ by mode:
    - workflow mode: 50 ticks × 100ms = 5 seconds (plenty for no-op steps).
    - claude-driven mode: 1800 ticks × 1000ms = 30 minutes (room for real
      Claude work; tune via the `:max_ticks` and `:interval_ms` opts). Past the
      budget the Driver still waits on a live run (bd-6dxqkg) — it only gives
      up on a worker that is gone or failed.
  """

  use GenServer
  require Ash.Query
  require Logger

  alias Arbiter.Reviews.Checkout
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Verification
  alias Arbiter.Worker
  alias Arbiter.Worker.AuthDeath
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workflows.Machine

  @workflow_default_interval_ms 100
  @workflow_default_max_ticks 50

  @claude_default_interval_ms 1_000
  @claude_default_max_ticks 1_800

  @type opts :: [
          task_id: String.t(),
          worker_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          interval_ms: non_neg_integer(),
          max_ticks: non_neg_integer(),
          worktree_path: String.t() | nil,
          cleanup_worktree: boolean(),
          review_checkout_path: String.t() | nil,
          claude_driven: boolean()
        ]

  @spec start(opts()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Worker.Supervisor, {__MODULE__, opts})
  end

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # ---- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    # bd-6i7yzq: writes this process makes are attributed to it (`Arbiter.Actor`).
    Arbiter.Actor.put(Arbiter.Actor.system("driver"))

    claude_driven = Keyword.get(opts, :claude_driven, false)

    state = %{
      task_id: Keyword.fetch!(opts, :task_id),
      worker_pid: Keyword.fetch!(opts, :worker_pid),
      machine_id: Keyword.fetch!(opts, :machine_id),
      machine_pid: Keyword.fetch!(opts, :machine_pid),
      claude_driven: claude_driven,
      interval_ms: Keyword.get(opts, :interval_ms, default_interval_for(claude_driven)),
      max_ticks: Keyword.get(opts, :max_ticks, default_max_ticks_for(claude_driven)),
      worktree_path: Keyword.get(opts, :worktree_path),
      cleanup_worktree: Keyword.get(opts, :cleanup_worktree, false),
      # bd-199giy: a review dispatch's throwaway PR-head checkout, if
      # `Arbiter.Worker.Dispatch` provisioned one. Distinct from
      # `worktree_path` — nothing is ever committed here, so it is always
      # force-removed on the way out rather than run through the
      # dirty/ahead-of-base guards `maybe_cleanup_worktree/1` applies.
      review_checkout_path: Keyword.get(opts, :review_checkout_path),
      ticks: 0,
      overrun_logged: false
    }

    Process.monitor(state.worker_pid)
    Process.monitor(state.machine_pid)

    schedule_first(state)
    {:ok, state}
  end

  defp default_interval_for(true), do: @claude_default_interval_ms
  defp default_interval_for(false), do: @workflow_default_interval_ms

  defp default_max_ticks_for(true), do: @claude_default_max_ticks
  defp default_max_ticks_for(false), do: @workflow_default_max_ticks

  # bd-21bmdh: an auth death reclaims its debris and returns the task to Ready
  # (behind the provider's AuthHold). Every other failure keeps the task
  # :active. Shared by the in-budget and past-budget (#372) paths.
  defp handle_failed_worker(state, worker_state) do
    case AuthDeath.handle(
           state.task_id,
           state.worker_pid,
           worker_state,
           blocking_workers(state)
         ) do
      :not_auth ->
        Logger.warning(
          "Worker.Driver (claude_driven): worker failed for task=#{state.task_id}; leaving task :active"
        )

      {:auth, _outcome} ->
        :ok
    end

    maybe_cleanup_worktree(state)
    {:stop, :normal, state}
  end

  defp schedule_first(%{claude_driven: true}), do: Process.send_after(self(), :check_worker, 0)
  defp schedule_first(%{claude_driven: false}), do: Process.send_after(self(), :tick, 0)

  @impl true
  def handle_info(:tick, %{ticks: t, max_ticks: m} = state) when t >= m do
    Logger.warning("Worker.Driver hit max_ticks=#{m} for task=#{state.task_id}; stopping")

    safe(fn -> Worker.fail(state.worker_pid, {:driver_timeout, m}) end)
    maybe_cleanup_worktree(state)
    {:stop, :normal, state}
  end

  def handle_info(:check_worker, %{ticks: t, max_ticks: m} = state) when t >= m do
    # Even at max_ticks, close a completed worker rather than leaving the task
    # stranded. This handles the race where the Watchdog calls Worker.complete
    # in the same window the Driver's tick budget expires (bd-d1jp4r).
    case safe_worker_state(state.worker_pid) do
      %{state: :finished, outcome: :succeeded} = worker_state ->
        # bd-cw3w9p: review_only tasks are long-lived engagements (ReviewPatrol).
        # The Driver must NOT auto-close them — they stay :active so
        # ReviewPatrol can keep engaging on subsequent commits.
        unless live_review_engagement?(worker_state) do
          finalize_task(
            state.task_id,
            should_close_upstream_for_task(state.task_id, worker_state),
            worker_state
          )
        end

        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      %{state: :waiting, waiting_on: :review_gate} ->
        # bd-7b46wd: the tick budget was spent on active worker work, but the
        # worker has since handed off to the ReviewGate (review gate), which
        # owns the terminal transition and has its own bounds, so giving up
        # here would strand a task that is legitimately mid-review. Keep
        # waiting for the run to finish rather than stopping — same reasoning
        # as the pre-max_ticks handler below.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, state}

      # bd-6dxqkg (#372): a run still in flight when the budget lapses (a long
      # research spike outlives 30 minutes) must not be abandoned. Stopping here
      # left nobody to close the ticket when the run later finished `arb done`,
      # so it sat `:active` holding its scheduler slot. Keep polling — the
      # worker has its own bounds, and its exit or failure still ends this loop.
      %{state: run_state} when run_state in [:starting, :working, :waiting] ->
        unless state.overrun_logged do
          Logger.warning(
            "Worker.Driver (claude_driven) past max_ticks=#{m} for task=#{state.task_id} " <>
              "with the run still live; continuing to wait for it"
          )
        end

        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, %{state | overrun_logged: true}}

      %{state: :finished} = worker_state ->
        handle_failed_worker(state, worker_state)

      _ ->
        Logger.warning(
          "Worker.Driver (claude_driven) hit max_ticks=#{m} for task=#{state.task_id}; stopping"
        )

        maybe_cleanup_worktree(state)
        {:stop, :normal, state}
    end
  end

  def handle_info(:check_worker, state) do
    case safe_worker_state(state.worker_pid) do
      %{state: :finished, outcome: :succeeded} = worker_state ->
        # bd-cw3w9p: review_only tasks are long-lived engagements (ReviewPatrol).
        # The Driver must NOT auto-close them — they stay :active so
        # ReviewPatrol can keep engaging on subsequent commits.
        unless live_review_engagement?(worker_state) do
          close_upstream = should_close_upstream_for_task(state.task_id, worker_state)
          finalize_task(state.task_id, close_upstream, worker_state)
        end

        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      %{state: :finished} = worker_state ->
        handle_failed_worker(state, worker_state)

      %{state: :waiting, waiting_on: :review_gate} ->
        # A distinct reviewer worker (ReviewGate) is evaluating the diff; it
        # will report a verdict that opens the PR or parks. Not "Claude stuck"
        # — an externally owned hand-off, so it burns no tick budget: the
        # ReviewGate has its own bounds.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, state}

      %{state: run_state} when run_state in [:starting, :working, :waiting] ->
        # Active states — Claude is working; count against the tick budget.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}

      nil ->
        # Worker snapshot unavailable (process likely dead) — the :DOWN
        # handler will fire next, just stop trying for now.
        Process.send_after(self(), :check_worker, state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}
    end
  end

  def handle_info(:tick, state) do
    case safe_advance(state.machine_pid) do
      {:ok, :completed} ->
        safe(fn -> Worker.complete(state.worker_pid, :workflow_completed) end)
        close_task(state.task_id)
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}

      {:ok, next_step} when is_atom(next_step) ->
        safe(fn -> Worker.advance(state.worker_pid, next_step) end)
        schedule_tick(state.interval_ms)
        {:noreply, %{state | ticks: state.ticks + 1}}

      {:error, reason} ->
        Logger.warning(
          "Worker.Driver: machine.advance error for task=#{state.task_id}: #{inspect(reason)}"
        )

        safe(fn -> Worker.fail(state.worker_pid, reason) end)
        maybe_cleanup_worktree(state)
        {:stop, :normal, state}
    end
  end

  # bd-741sid: a run whose PR is open ends there — the worker exits and the
  # ticket's Watchdog owns the PR — so its exit is not a death.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{worker_pid: pid} = state) do
    if merging?(state.task_id) do
      Logger.info(
        "Worker.Driver: run for task=#{state.task_id} ended (#{inspect(reason)}); " <>
          "its ticket is Merging"
      )
    else
      Logger.warning("Worker.Driver: worker died for task=#{state.task_id}")
    end

    maybe_cleanup_worktree(state)
    {:stop, :normal, state}
  end

  # bd-146u20 / #2053: on an application stop the Machine goes down first —
  # `Arbiter.Workflows.MachineSupervisor` is started after
  # `Arbiter.Worker.Supervisor`, so it is stopped before it. That is the node
  # stopping, not the machine crashing: stand down without failing the worker,
  # whose own terminate/2 records the run :interrupted / "server shutdown" for
  # the boot resume sweep. Failing it here won the race to the worker whenever
  # the stop dawdled in between (a live Watchdog), stamping :machine_died.
  # Leave the worktree alone too — the resume re-attaches to it.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{machine_pid: pid} = state) do
    if shutdown_exit?(reason) or Worker.node_stopping?(),
      do: machine_stopped_with_node(state),
      else: machine_died(state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    maybe_cleanup_worktree(state)
    teardown_review_checkout(state)
  end

  defp machine_stopped_with_node(state) do
    Logger.info(
      "Worker.Driver: machine stopped with the node for task=#{state.task_id}; " <>
        "leaving the worker to record the run interrupted"
    )

    {:stop, :normal, %{state | cleanup_worktree: false}}
  end

  # Its supervisor shut it down. A Machine is `restart: :temporary` and nothing
  # else terminates one, so that only happens when the node stops; a machine
  # that overran its shutdown budget is `:killed` instead, which the
  # node_stopping? check covers.
  defp shutdown_exit?(:shutdown), do: true
  defp shutdown_exit?({:shutdown, _}), do: true
  defp shutdown_exit?(_reason), do: false

  defp machine_died(state) do
    Logger.warning("Worker.Driver: machine died for task=#{state.task_id}")
    safe(fn -> Worker.fail(state.worker_pid, :machine_died) end)
    maybe_cleanup_worktree(state)
    {:stop, :normal, state}
  end

  # bd-199giy: reclaim the reviewer's throwaway checkout on every exit path —
  # completion, failure, driver timeout, a dead worker or machine. Unlike a
  # task worktree there is nothing to preserve: the reviewer cannot write to
  # it (Edit/Write are denied at spawn) and never commits, so a leftover
  # directory is pure garbage. `Checkout.teardown/1` is idempotent, nil-safe,
  # and never raises, so this stays a one-liner on the shutdown path.
  defp teardown_review_checkout(%{review_checkout_path: path}), do: Checkout.teardown(path)
  defp teardown_review_checkout(_state), do: :ok

  # ---- internals ---------------------------------------------------------

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp safe_advance(machine_pid) do
    Machine.advance(machine_pid)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    # Machine process is gone — normalize to the same reason the :DOWN handler produces.
    :exit, {:noproc, _} -> {:error, :machine_died}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp merging?(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{state: :merging}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp safe_worker_state(pid) do
    Worker.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp should_close_upstream_for_task(task_id, worker_state) do
    # bd-6xaaam: review-only workers never transition a tracker issue they
    # don't own — even if the task has a tracker_ref. The flag is stamped on
    # the Issue by Dispatch when review: true, and echoed in worker meta.
    if review_only_worker?(worker_state) do
      false
    else
      # Pass close_upstream: true if either:
      # 1. there's an mr_ref (existing logic), OR
      # 2. the task has a tracker_ref (need to sync upstream on close)
      case should_close_upstream(worker_state) do
        true ->
          true

        false ->
          # Check if the task has a tracker_ref that needs syncing
          case Ash.get(Issue, task_id) do
            {:ok, task} ->
              has_tracker_ref?(task)

            {:error, _} ->
              false
          end
      end
    end
  rescue
    _ -> false
  end

  defp review_only_worker?(%{meta: %{review_only: true}}), do: true
  defp review_only_worker?(%{meta: %{"review_only" => true}}), do: true
  defp review_only_worker?(_), do: false

  # bd-cw3w9p: a "live review engagement" is a review_only task kept open so
  # ReviewPatrol can keep engaging on subsequent commits. The Driver must never
  # auto-close these — ReviewPatrol drives closure when appropriate.
  defp live_review_engagement?(worker_state), do: review_only_worker?(worker_state)

  defp has_tracker_ref?(%Issue{tracker_ref: ref, tracker_type: type})
       when is_binary(ref) and ref != "" and type != :none do
    true
  end

  defp has_tracker_ref?(_), do: false

  defp should_close_upstream(%{mr_ref: mr_ref}) when is_binary(mr_ref) and mr_ref != "", do: true
  defp should_close_upstream(_), do: false

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # bd-9so315: the Driver is the third path that finalizes a merged PR (after
  # MergeQueue's own merge and MergedPRFinalizer's sweep). The Watchdog calls
  # `Worker.complete(pid, :merged)` both when it observes an MR merged and when
  # it performs the auto-merge itself; `complete_now/2` leaves the worker alive
  # at `:completed` and this loop then closes the task — within ~1s, long
  # before the MergeQueue's next poll. Closing directly here would silently
  # skip the `verify_after_deploy` park (and its escalation) for exactly the
  # tasks the flag exists to protect, so a merge completion goes through the
  # same `Verification.finalize_merged/2` funnel every other merge path uses.
  #
  # A non-merge completion (`:claude_done`, `:workflow_completed`) is not a
  # deploy and still closes directly — the flag is about observing merged code
  # on the running server, and parking a task that never merged would strand it.
  #
  # bd-741sid: a run that completed by opening its PR (`result: :pr_opened`) is
  # not the ticket finishing. The ticket is Merging and its Watchdog finishes it
  # when the PR merges, so there is nothing for the Driver to do.
  defp finalize_task(task_id, close_upstream, worker_state) do
    cond do
      pr_opened_completion?(worker_state) ->
        :ok

      merge_completion?(worker_state) ->
        finalize_merged_task(task_id, close_upstream, worker_state)

      true ->
        close_task(task_id, close_upstream)
    end
  end

  defp pr_opened_completion?(%{meta: meta}) when is_map(meta),
    do: Map.get(meta, :result) == :pr_opened

  defp pr_opened_completion?(_), do: false

  defp merge_completion?(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :result) || Map.get(meta, "result") do
      :merged -> true
      "merged" -> true
      _ -> false
    end
  end

  defp merge_completion?(_), do: false

  defp finalize_merged_task(task_id, close_upstream, worker_state) do
    case Ash.get(Issue, task_id) do
      # The MergeQueue (or MergedPRFinalizer) may have won the race and already
      # driven the task to its terminal state. Re-running `finalize_merged/2`
      # on a parked task is refused by the `:await_verification` guard and on a
      # closed one by `:close`; both would log a misleading failure, so no-op
      # explicitly instead.
      {:ok, %Issue{state: state}} when state in [:closed, :verifying] ->
        :ok

      {:ok, task} ->
        case Verification.finalize_merged(task,
               close_upstream: close_upstream,
               mr_ref: Map.get(worker_state, :mr_ref) || task.pr_ref
             ) do
          {:ok, :closed, _} ->
            :ok

          {:ok, :awaiting_verification, _} ->
            Logger.info(
              "Worker.Driver: task #{task_id} merged with verify_after_deploy — " <>
                "parked at :verifying instead of closing"
            )

            :ok

          {:error, err} ->
            Logger.warning(
              "Worker.Driver: failed to finalize merged task #{task_id}: #{inspect(err)}"
            )

            :error
        end

      err ->
        Logger.warning("Worker.Driver: failed to close task #{task_id}: #{inspect(err)}")
        :error
    end
  end

  defp close_task(task_id, close_upstream \\ false) do
    case Ash.get(Issue, task_id) do
      {:ok, task} ->
        attrs = %{close_upstream: close_upstream}

        case Ash.update(task, attrs, action: :close) do
          {:ok, _} ->
            :ok

          {:error, err} ->
            Logger.warning("Worker.Driver: failed to close task #{task_id}: #{inspect(err)}")
            :error
        end

      err ->
        Logger.warning("Worker.Driver: failed to close task #{task_id}: #{inspect(err)}")
        :error
    end
  end

  # Best-effort worktree cleanup after a successful workflow.
  #
  # Skipped when:
  #   - `cleanup_worktree` is false (default)
  #   - `worktree_path` is nil (no worktree was provisioned)
  #   - the worktree has uncommitted changes (operator should inspect)
  #   - a worker for this task is still registered and alive (bd-bmmj4w)
  #
  # Failures are logged but never propagated — the task is already closed
  # and the workflow is done, so we don't want to crash the Driver over a
  # cleanup hiccup.
  defp maybe_cleanup_worktree(%{cleanup_worktree: false}), do: :ok
  defp maybe_cleanup_worktree(%{worktree_path: nil}), do: :ok

  # RW12 (docs/design/remote-workers.md §10.3): a run cut off by a lost node is
  # interrupted, not failed, and its home clone is what the resume re-enters (the
  # node's own work is lost beyond the last checkpoint, but the checkpoint is here).
  # The Worker is gone by the time this runs, so the run row says which it was.
  defp maybe_cleanup_worktree(%{task_id: task_id} = state) when is_binary(task_id) do
    cond do
      node_lost_run?(task_id) ->
        Logger.info(
          "Worker.Driver: run for task=#{task_id} was interrupted by a lost node; " <>
            "keeping its worktree for the resume"
        )

        :ok

      # bd-a6vh2x: a run stopped on its provider's quota is queued to resume in
      # this very worktree once the account is free.
      quota_held_run?(task_id) ->
        Logger.info(
          "Worker.Driver: run for task=#{task_id} is held for provider quota; " <>
            "keeping its worktree for the resume"
        )

        :ok

      true ->
        cleanup_unless_merging(state)
    end
  end

  defp maybe_cleanup_worktree(state), do: cleanup_unless_merging(state)

  defp quota_held_run?(task_id) do
    with {:ok, %{workspace_id: ws_id}} when is_binary(ws_id) <-
           Ash.get(Arbiter.Tasks.Issue, task_id),
         %{opts: opts} <- Arbiter.Workflows.DispatchQueue.held_item(ws_id, task_id) do
      Keyword.get(opts, :quota_resume) == true
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # bd-741sid: a Merging ticket's worktree belongs to its merge path — a fix or
  # conflict pass works in it, and the ticket's close removes it.
  defp cleanup_unless_merging(%{task_id: task_id} = state) when is_binary(task_id) do
    if merging?(task_id), do: :ok, else: do_maybe_cleanup_worktree(state)
  end

  defp cleanup_unless_merging(state), do: do_maybe_cleanup_worktree(state)

  defp node_lost_run?(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id and kind == :implement)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%{outcome: :interrupted, stop_category: category}]
      when category in ["node_lost", "pod_disrupted"] ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp do_maybe_cleanup_worktree(%{worktree_path: path} = state) do
    # The task's :close after_action may already have removed the worktree
    # (see Arbiter.Tasks.Issue.Changes.CleanupWorktree) — nothing left to do,
    # and skipping silently keeps this legacy Driver-side path from logging a
    # warning about a path that is already gone.
    if File.dir?(path), do: cleanup_unowned_worktree(state), else: :ok
  end

  defp cleanup_unowned_worktree(%{worktree_path: path, task_id: task_id} = state) do
    blocking = blocking_workers(state)

    cond do
      # bd-bmmj4w: same invariant the `:close` hook enforces — never remove a
      # directory a worker may still be running an agent in.
      blocking != [] ->
        Logger.info(
          "Worker.Driver: worker(s) #{Enum.join(blocking, ", ")} still live for " <>
            "task=#{task_id}; skipping worktree cleanup"
        )

      worktree_dirty?(path, task_id) ->
        Logger.info(
          "Worker.Driver: worktree has uncommitted changes for task=#{task_id}; skipping cleanup"
        )

      worktree_ahead_of_base?(path, task_id) ->
        Logger.info(
          "Worker.Driver: worktree has commits ahead of base for task=#{task_id}; skipping cleanup"
        )

      true ->
        case Worktree.cleanup(path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Worker.Driver: cleanup_worktree failed for task=#{task_id}: #{inspect(reason)}"
            )
        end
    end

    :ok
  end

  # bd-bmmj4w: which workers still owning this task's worktree must block its
  # removal. Every live registry entry for the task counts — most importantly
  # sub-workers (`<task_id>:fixpass`, `<task_id>#review`, ...) which this
  # Driver never started, never stops, and whose agents may well be mid-run in
  # the very directory it is about to delete.
  #
  # The Driver's OWN worker is exempt once its run is finished: a failure runs
  # `fail_now/2` (which SIGKILLs the agent before the state flips, bd-7a0pi8)
  # and a success reaches here only after `close_task/2` stopped it, so in
  # both cases its agent is provably dead even though the GenServer may linger.
  # A non-terminal own worker — the max_ticks giving-up branch, where nothing
  # failed it — is NOT exempt: its agent can still be running.
  #
  # The `<task_id>:watchdog` entry (bd-bspakl) is also exempt: it registers
  # under this same registry so `retry_auto_resolve/1` can look it up by
  # task_id, but it never touches the worktree — it only polls the forge and
  # dispatches sub-workers, which register (and block) under their own keys.
  # Without this it would leak the worktree on every reap while a parked
  # Watchdog is still watching for an out-of-band fix.
  defp blocking_workers(%{task_id: task_id, worker_pid: own_pid}) do
    watchdog_key = task_id <> Arbiter.Worker.Watchdog.registry_suffix()

    Arbiter.Worker.Registry.live_for(task_id)
    |> Enum.reject(fn {key, pid} ->
      (pid == own_pid and agent_terminal?(pid)) or key == watchdog_key
    end)
    |> Enum.map(fn {key, _pid} -> key end)
  rescue
    # A registry that isn't running (a bare unit-test Driver) must not crash
    # the reap. "Can't tell" resolves to "don't delete" — leaking a worktree
    # is recoverable, deleting a live one is not.
    _ -> ["<registry-unavailable>"]
  end

  defp agent_terminal?(pid) do
    case safe_worker_state(pid) do
      %{state: run_state} -> run_state == :finished
      _ -> false
    end
  end

  defp worktree_dirty?(path, task_id) do
    case Worktree.has_uncommitted?(path) do
      {:ok, dirty} ->
        dirty

      {:error, reason} ->
        Logger.warning(
          "Worker.Driver: cleanup-dirty-probe failed for task=#{task_id}: #{inspect(reason)}"
        )

        # Conservative: treat probe failure as "might be dirty" — skip cleanup.
        true
    end
  end

  defp worktree_ahead_of_base?(path, _task_id) do
    # `Worktree.has_commits_ahead?/2` already swallows git errors and
    # returns {:ok, true} as the conservative default, so we only need
    # to handle the OK shape here.
    case Worktree.has_commits_ahead?(path, "main") do
      {:ok, ahead?} -> ahead?
    end
  end
end
