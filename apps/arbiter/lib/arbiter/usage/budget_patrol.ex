defmodule Arbiter.Usage.BudgetPatrol do
  @moduledoc """
  Walks the open tasks on a timer and pages the coordinator the first time one
  crosses its estimate group's p90 (bd-8j9i9p AC5, operator decision
  2026-09-15).

  The chip on the issue header and the flag on the board are *pull* surfaces:
  they say "this ran over" to whoever happens to look. The operator's decision
  was that an overrun should also *push*, once, so the coordinator can rule on
  whether the behaviour is expected — a D2 that is really a D3 needs a
  re-rating, a worker going in circles needs stopping, and those look identical
  from the number alone.

  ## What it deliberately does not do

  Nothing is stopped, paused or tripped. Cost overrun on its own is not
  evidence of a stuck worker the way repeated review failures are (design
  bd-9jj5lf §3), and conflating the two would kill legitimately-hard tasks. The
  page is the whole intervention.

  ## Once per task

  The dedupe is `Arbiter.Messages.Message.last_escalation/2` on the
  `:budget_exceeded` kind and the task (bd-8if9zt), so it
  holds across ticks *and* across a restart — the state lives in the message
  table, not in this process. A task whose total keeps climbing is not paged
  again: the second page would say exactly what the first said.

  A task awaiting verification with no live worker is not paged either, and
  its open alert is cleared: it has merged, so its spend cannot grow
  (bd-9jipdh).

  A closed task is never paged, however far over it ran (it is done — that is
  calibration-report material, design §6), and neither is one with no estimate
  at all: `:insufficient_data` has no p90 to be over.

  ## Live spend (bd-8vnuy3)

  The figure assessed is `Arbiter.Usage.LiveSpend`'s: the settled ledger plus
  whatever the task's in-flight passes have spent so far, read off their
  session JSONL. Before this, spend only accrued when a session *ended*, so a
  runaway pass — the case this page exists for — could not trip it until it
  stopped running away. The page says how much of its figure is an in-flight
  estimate. The dedupe is unchanged: one page per task, whatever the figure
  does afterwards.

  ## Configuration

  Via `config :arbiter, :budget_patrol`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests drive `sweep/1` synchronously instead).
    * `:interval_ms` — sweep interval (default 5 minutes). Now that live
                       spend moves between ticks, the interval is how late a
                       runaway pass gets paged. Re-reading the in-flight
                       session files is not what bounds it: a read is ~7 ms at
                       the p90 worker session file size and ~110 ms for the
                       largest on the host (5.7 MB), and only tasks with a live
                       agent are read at all. The sweep's ledger reads (the
                       settled totals and the estimator sample) are the same
                       per-tick cost they always were — 5 minutes doubles that
                       rate, not more, for half the paging lag.
  """

  use GenServer

  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Tasks.Issue
  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.Estimate
  alias Arbiter.Usage.LiveSpend

  require Ash.Query
  require Logger

  @default_interval_ms :timer.minutes(5)

  # Containers, not work: an epic has no worker and no spend of its own.
  @non_dispatchable_types [:epic]

  # ---- process -------------------------------------------------------------

  # `name: nil` starts an unregistered instance — how a test drives its own
  # copy while the application's singleton is already up under the module name.
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Run one sweep synchronously (tests, and `arb`-driven pokes)."
  @spec poll(GenServer.server()) :: :ok
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll, 30_000)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))

    if Keyword.get(opts, :enabled, config(:enabled, true)) do
      schedule(self(), interval)
    end

    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_call(:poll, _from, state) do
    sweep([])
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    sweep([])
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, interval_ms), do: Process.send_after(pid, :tick, interval_ms)

  defp config(key, default) do
    :arbiter
    |> Application.get_env(:budget_patrol, [])
    |> Keyword.get(key, default)
  end

  # ---- the sweep -----------------------------------------------------------

  @doc """
  One pass: raise (or refresh) the budget alert of each open task past its
  p90, and clear the alert of every task that is not (bd-7gt8rm). Always
  returns `:ok` — a ledger read that fails must not take the ticker down with
  it, and clears nothing.

  Options are `Arbiter.Usage.Estimate.for_issue/2`'s (`:now`, `:min_n`,
  `:window_days`, `:sample`), plus `:issues` to supply the open tasks
  directly and `:workers` to supply the worker snapshots
  (`Arbiter.Worker.list_children/0` by default).
  """
  @spec sweep(keyword()) :: :ok
  def sweep(opts \\ []) do
    issues = Keyword.get_lazy(opts, :issues, &open_issues/0)

    case issues do
      [] ->
        CoordinatorNotifier.budget_recovered([])

      issues ->
        sample = Keyword.get_lazy(opts, :sample, fn -> Estimate.sample(opts) end)
        workers = Keyword.get_lazy(opts, :workers, &list_workers/0)

        spends =
          LiveSpend.for_tasks(Enum.map(issues, & &1.id), Keyword.put(opts, :workers, workers))

        opts = Keyword.put(opts, :sample, sample)
        states = worker_states(workers)

        over =
          Enum.filter(issues, fn issue ->
            spend = spends[issue.id]

            total(spend) > 0.0 and spend_can_grow?(issue, states) and
              over_budget?(issue, spend, states, opts)
          end)

        # bd-7gt8rm: every open task was just assessed, so an alert for a task
        # not over now — its threshold moved, or it closed — has cleared. Only
        # reached when the whole sweep succeeded: a failed read clears nothing.
        CoordinatorNotifier.budget_recovered(Enum.map(over, & &1.id))
    end
  rescue
    error ->
      Logger.warning("Usage.BudgetPatrol.sweep failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  # A task awaiting verification with no live worker has merged and stopped:
  # its spend is final, so an overrun is calibration material, not a page
  # (bd-9jipdh). Left out of `over`, its alert is cleared by `budget_recovered/1`.
  defp spend_can_grow?(issue, states) do
    Arbiter.Tasks.Lifecycle.state_of(issue) != :verifying or Map.has_key?(states, issue.id)
  end

  # Assess one task with spend; raise (or refresh) its alert when it is over.
  defp over_budget?(issue, spend, states, opts) do
    assessment = Budget.assess(issue, Keyword.put(opts, :spend, total(spend)))
    if assessment.over_budget?, do: escalate(issue, assessment, spend, states)
    assessment.over_budget?
  end

  # `nil` is "nothing priced" (an agy-only task): there is no figure to be over.
  defp total(%{total_usd: total}) when is_number(total), do: total
  defp total(_spend), do: 0.0

  defp escalate(%Issue{} = issue, assessment, spend, workers) do
    CoordinatorNotifier.budget_exceeded(
      %{task_id: issue.id, workspace_id: issue.workspace_id},
      %{
        spend: assessment.spend,
        live_spend: if(spend.live_usd > 0.0, do: spend.live_usd),
        degraded?: spend.degraded?,
        estimate: assessment.estimate,
        difficulty: issue.difficulty,
        worker_state: Map.get(workers, issue.id) || "no live worker (#{issue.state})"
      }
    )
  end

  defp open_issues do
    closed = :closed

    Issue
    |> Ash.Query.filter(state != ^closed)
    |> Ash.read!()
    |> Enum.reject(&(&1.issue_type in @non_dispatchable_types))
  end

  defp list_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # `<status> · <step>` for whatever is actually running, keyed by the task the
  # spend belongs to — a reviewer or fix pass runs under a synthetic id, and
  # its state is still this task's state.
  defp worker_states(workers) do
    workers
    |> Enum.map(fn w ->
      {Arbiter.Worker.ReviewGate.base_task_id(w.task_id), describe_worker(w)}
    end)
    |> Enum.reject(fn {task_id, _} -> is_nil(task_id) end)
    |> Map.new()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp describe_worker(worker) do
    [Map.get(worker, :kind), Map.get(worker, :state), Map.get(worker, :current_step)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" · ", &to_string/1)
  end
end
