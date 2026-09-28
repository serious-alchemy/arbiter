defmodule Arbiter.Workflows.PendingMergeSweeper do
  @moduledoc """
  Re-arms the merge of approved PRs whose owning worker is gone
  (bd-a370ak / #2002).

  ## Problem this solves

  The auto-merge decision for an approved PR lives in its
  `Arbiter.Worker.Watchdog`. It used to be paired with the worker that opened
  the PR and stop when that worker did; since bd-741sid it belongs to the
  ticket, but it still dies with the server or on a crash. A merge that was
  *waiting* when it went — CI still running, the PR still a draft, a 405/409
  from the forge — then has no owner left to notice the wait was over. Three
  approved, green, CLEAN PRs sat unmerged for 17+ hours this way (#1947,
  #1966, #1932).

  ## How

  The live Watchdog stamps the task's durable `pending_merge`
  (`Arbiter.Mergers.PendingMerge`) whenever it defers or fails an approved
  merge. On every tick — and once shortly after boot, which is what makes the
  re-evaluation survive a server restart — this sweeper walks the open tasks
  carrying a retryable stamp and, for each:

    * leaves it alone while a live lane owns it: a registered Watchdog, a
      run that is still working the ticket (a fix pass or conflict resolver
      included), or a retry already running;
    * restarts the Watchdog of a Merging ticket whose PR open recorded its
      lane (`Arbiter.Worker.Watchdog.restart/1`, bd-741sid) — the Watchdog
      belongs to the ticket, and that is the live lane's own repair;
    * otherwise starts a worker-less retry
      (`Arbiter.Worker.Watchdog.start_retry/1`), which waits out the transient
      blocker and merges through the Watchdog's own guards, or pages the
      coordinator once and latches the stamp escalated.

  Escalated stamps are never re-armed; neither is a workspace whose
  `merge.auto_merge` is now off, nor a ticket an operator pulled out of the
  merge queue (`Arbiter.Tasks.PullRequest.pull/1`). Only the primary instance
  (`Arbiter.SingleInstance.primary?/0`) sweeps: a duplicate boot must not run
  a second merge loop against the live instance's PRs.

  ## Configuration

  Via `config :arbiter, :pending_merge_sweeper`:

    * `:enabled` — master switch (default `true`; `false` in test, where tests
      drive `sweep/1` synchronously).
    * `:interval_ms` — sweep cadence (default 300 000, 5 minutes).
    * `:initial_delay_ms` — first sweep after boot (default 30 000).
    * `:max_retry_wait_ms` — how long a retry keeps waiting on a draft or
      pending CI, measured from the stamp's `since`, before it pages once and
      latches the stamp escalated (default 48 hours; read by
      `Arbiter.Worker.Watchdog.start_retry/1`).
  """

  use GenServer

  require Logger

  alias Arbiter.Mergers
  alias Arbiter.Mergers.PendingMerge
  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Watchdog

  @default_interval_ms 5 * 60_000
  @default_initial_delay_ms 30_000

  @type summary :: %{
          retried: [String.t()],
          rewatched: [String.t()],
          skipped: [{String.t(), atom()}] | atom()
        }

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Sweep counters, for tests and diagnostics."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Run one sweep synchronously in the calling process. Opts:

    * `:primary?` — zero-arity fun deciding whether this instance may sweep
      (default `Arbiter.SingleInstance.primary?/0`);
    * `:adapter` — merger adapter override (tests); otherwise resolved from
      each task's workspace;
    * `:retry_opts` — extra opts handed to `Watchdog.start_retry/1`.

  Best-effort: a failure on one task is logged and the sweep moves on.
  """
  @spec sweep(keyword()) :: summary()
  def sweep(opts \\ []) do
    if primary?(opts) do
      do_sweep(opts)
    else
      %{retried: [], rewatched: [], skipped: :not_primary}
    end
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms),
      sweep_opts: Keyword.take(opts, [:primary?, :adapter, :retry_opts]),
      sweeps: 0,
      last_summary: nil
    }

    if state.enabled,
      do: schedule(cfg_opt(:initial_delay_ms, opts, @default_initial_delay_ms))

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state),
    do: {:reply, Map.take(state, [:enabled, :interval_ms, :sweeps, :last_summary]), state}

  @impl true
  def handle_info(:sweep, state) do
    summary = sweep(state.sweep_opts)
    schedule(state.interval_ms)
    {:noreply, %{state | sweeps: state.sweeps + 1, last_summary: summary}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- sweep ----------------------------------------------------------------

  defp do_sweep(opts) do
    case PendingMerge.list_open() do
      {:ok, tasks} ->
        tasks
        |> Enum.reduce(%{retried: [], rewatched: [], skipped: []}, fn task, acc ->
          record(acc, task.id, sweep_one(task, opts))
        end)
        |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
        |> log_summary()

      {:error, reason} ->
        Logger.warning("PendingMergeSweeper: could not read pending merges: #{inspect(reason)}")
        %{retried: [], rewatched: [], skipped: :read_failed}
    end
  rescue
    e ->
      Logger.warning("PendingMergeSweeper: sweep failed: #{Exception.message(e)}")
      %{retried: [], rewatched: [], skipped: :sweep_failed}
  end

  defp record(acc, id, :retried), do: %{acc | retried: [id | acc.retried]}
  defp record(acc, id, :rewatched), do: %{acc | rewatched: [id | acc.rewatched]}
  defp record(acc, id, {:skipped, why}), do: %{acc | skipped: [{id, why} | acc.skipped]}

  defp sweep_one(task, opts) do
    pending = PendingMerge.get(task)

    cond do
      not PendingMerge.retryable?(pending) ->
        {:skipped, :escalated}

      superseded?(task, pending) ->
        # The task has since opened a different PR; this stamp describes a
        # merge nobody will ever make.
        PendingMerge.clear(task.id)
        {:skipped, :superseded}

      # bd-741sid: an operator pulled the PR out of the merge queue, and a
      # retry would merge it all the same. `PullRequest.pull/1` drops the
      # stamp; this covers one written before it landed.
      PullRequest.pulled?(task) ->
        {:skipped, :pulled}

      is_pid(Watchdog.retry_whereis(task.id)) ->
        {:skipped, :retry_running}

      true ->
        route(task, pending, Watchdog.live_merge_owner(task.id), opts)
    end
  rescue
    e ->
      Logger.warning(
        "PendingMergeSweeper: task=#{task.id} could not be swept: #{Exception.message(e)}"
      )

      {:skipped, :error}
  catch
    :exit, reason ->
      Logger.warning("PendingMergeSweeper: task=#{task.id} sweep exited: #{inspect(reason)}")
      {:skipped, :error}
  end

  defp superseded?(%{pr_ref: pr_ref}, %{mr_ref: mr_ref})
       when is_binary(pr_ref) and pr_ref != "",
       do: pr_ref != mr_ref

  defp superseded?(_task, _pending), do: false

  defp route(_task, _pending, :watchdog, _opts), do: {:skipped, :live_watchdog}

  # A run is working the ticket — a fix pass / conflict resolver pushing to the
  # PR registers under the ticket id since bd-741sid. Once it exits, a later
  # sweep re-arms the merge against whatever head it left.
  defp route(_task, _pending, {:worker, _status}, _opts), do: {:skipped, :live_worker}
  defp route(_task, _pending, {:subordinate, _key}, _opts), do: {:skipped, :live_worker}

  # bd-741sid: a Merging ticket whose PR open recorded its lane (it names the
  # adapter that opened the PR) gets its own Watchdog back from the row — the
  # live lane's own repair. A PR opened before lanes were recorded, or a
  # restart that is refused, falls through to the worker-less retry, which
  # carries the stamp's own baseline rather than guessing at the lane.
  defp route(%{state: :merging, merge_watch: %{"adapter" => _}} = task, pending, nil, opts) do
    case Watchdog.restart(task.id) do
      :ok ->
        Logger.info("PendingMergeSweeper: task=#{task.id} had no Watchdog; restarted it")
        :rewatched

      {:error, :already_running} ->
        {:skipped, :live_watchdog}

      {:error, reason} ->
        Logger.info(
          "PendingMergeSweeper: task=#{task.id} Watchdog restart refused " <>
            "(#{inspect(reason)}); starting a worker-less retry instead"
        )

        retry(task, pending, opts)
    end
  end

  defp route(task, pending, nil, opts), do: retry(task, pending, opts)

  defp retry(task, pending, opts) do
    with {:ok, %Workspace{} = ws} <- Ash.get(Workspace, task.workspace_id),
         true <- Workspace.auto_merge?(ws) || {:skipped, :auto_merge_off},
         {:ok, adapter} <- resolve_adapter(ws, opts) do
      start_retry(task, pending, ws, adapter, opts)
    else
      {:skipped, _} = skip -> skip
      _ -> {:skipped, :no_adapter}
    end
  end

  defp start_retry(task, pending, ws, adapter, opts) do
    retry_opts =
      [
        task_id: task.id,
        mr_ref: pending.mr_ref,
        adapter: adapter,
        workspace: ws,
        repo: task.repo,
        reviewed_sha: pending.reviewed_sha,
        via_review_gate: pending.via_review_gate
      ]
      |> Keyword.merge(Keyword.get(opts, :retry_opts, []))

    case Watchdog.start_retry(retry_opts) do
      {:ok, _pid} ->
        Logger.info(
          "PendingMergeSweeper: task=#{task.id} mr=#{pending.mr_ref} approved merge was " <>
            "orphaned (#{pending.reason}, since #{pending.since}); started a worker-less retry"
        )

        :retried

      {:error, {:already_started, _pid}} ->
        {:skipped, :retry_running}

      other ->
        Logger.warning(
          "PendingMergeSweeper: task=#{task.id} retry failed to start: #{inspect(other)}"
        )

        {:skipped, :start_failed}
    end
  end

  defp resolve_adapter(ws, opts) do
    case Keyword.get(opts, :adapter) do
      nil ->
        adapter = Mergers.for_workspace(ws)
        Code.ensure_loaded(adapter)

        if function_exported?(adapter, :get, 1) and function_exported?(adapter, :merge, 2),
          do: {:ok, adapter},
          else: :error

      adapter ->
        {:ok, adapter}
    end
  rescue
    ArgumentError -> :error
  end

  defp log_summary(%{retried: [], rewatched: []} = summary), do: summary

  defp log_summary(summary) do
    Logger.info(
      "PendingMergeSweeper: re-armed #{length(summary.retried)} orphaned approved merge(s), " <>
        "restarted #{length(summary.rewatched)} Watchdog(s)"
    )

    summary
  end

  defp primary?(opts) do
    case Keyword.get(opts, :primary?) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Arbiter.SingleInstance.primary?()
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        Keyword.get(Application.get_env(:arbiter, :pending_merge_sweeper, []), key, default)
    end
  end
end
