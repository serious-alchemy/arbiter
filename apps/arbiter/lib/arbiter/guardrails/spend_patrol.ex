defmodule Arbiter.Guardrails.SpendPatrol do
  @moduledoc """
  Enforces a guardrail tier's spend caps on live runs (G19,
  `docs/design/guardrail-profiles.md` §3.3).

  A tier's `spend` knob is `%{action: :park | :page, tokens: n, wall_clock_s: n}`
  (`Arbiter.Guardrails.Profile`). The effective caps a run was spawned under are
  recorded on its `guardrail_decision` (`"spend"`), so this patrol reads them
  off the live worker's meta and never re-resolves a profile mid-run.

    * **`park`** (`quarantine`, `probation`) — the run is stopped with
      `Arbiter.Worker.park_spend_cap/2`: its agent is killed, its worktree is kept,
      the run finishes `:failed` with the typed `:spend_cap` stop reason, and the
      coordinator gets the addressed `worker_stopped` escalation. This is new:
      `Arbiter.Usage.BudgetPatrol` deliberately never stops anything. The park
      is also a major `spend_cap` guardrail event (§6.1), which
      `Arbiter.Loop.Trust` counts against the subject.
    * **`page`** (`trusted`, `privileged`) — the default is *no* cap here: those
      tiers are guarded by BudgetPatrol's p90 page, unchanged. An operator who sets
      a cap on a page tier (`config :arbiter, :guardrail_tiers`) gets a
      `:spend_cap_exceeded` escalation (ticket-scoped, so a repeat refreshes the open
      one) and nothing is stopped.

  ## What is measured

    * **Wall-clock** — seconds since the live worker started. Only a worker whose
      agent port is open is looked at (`agent_live`), so time parked at the review
      gate never counts. Works for every provider, and is the in-flight guard for
      agy, whose tokens are only reported when a session ends.
    * **Tokens** — `tokens_in + tokens_out + thinking_tokens` the *subject's
      provider* has spent on the ticket: the settled ledger
      (`Arbiter.Usage.Budget.settled_tokens_by_task/2`) plus, for Claude, the
      in-flight session read (`Arbiter.Usage.LiveSpend`). So a resume or nudge loop
      that re-launches a session is caught at its next sweep even for agy.

  Only **implementer** runs are looked at: the caps are the "main implementer run"
  budget (§6.2); a reviewer is not parked mid-verdict.

  ## Configuration

  `config :arbiter, :spend_patrol`: `:enabled` (default `true`; `false` in test,
  where tests drive `sweep/1`) and `:interval_ms` (default one minute: the wall-clock
  cap is at most that late).
  """

  use GenServer

  alias Arbiter.Guardrails.Events
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.LiveSpend
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Worker.StopReason

  require Logger

  @default_interval_ms :timer.minutes(1)

  @type breach :: %{
          cap: :tokens | :wall_clock_s,
          limit: pos_integer(),
          measured: number()
        }

  @type action :: %{
          task_id: String.t(),
          action: :parked | :paged,
          cap: :tokens | :wall_clock_s,
          limit: pos_integer(),
          measured: number(),
          tier: atom()
        }

  # ---- process -------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))
    if Keyword.get(opts, :enabled, config(:enabled, true)), do: schedule(self(), interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = sweep()
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(pid, interval_ms), do: Process.send_after(pid, :tick, interval_ms)

  defp config(key, default) do
    :arbiter |> Application.get_env(:spend_patrol, []) |> Keyword.get(key, default)
  end

  # ---- the check -----------------------------------------------------------

  @doc """
  The first cap in `spend` (a decision's `"spend"` map) that `measured`
  (`%{tokens: n, wall_clock_s: n}`) is past, or `nil`. A `nil` cap is no cap.
  Tokens are checked first.
  """
  @spec check(map(), %{tokens: number(), wall_clock_s: number()}) :: breach() | nil
  def check(spend, measured) do
    Enum.find_value([:tokens, :wall_clock_s], fn cap ->
      limit = Map.get(spend, Atom.to_string(cap))
      value = Map.fetch!(measured, cap)

      if is_integer(limit) and value > limit, do: %{cap: cap, limit: limit, measured: value}
    end)
  end

  # ---- the sweep -----------------------------------------------------------

  @doc """
  One pass over the live workers. Parks (or pages for) each implementer run that is
  past a cap and returns what it did, as `t:action/0`s. Never raises: a failed read
  acts on nothing.

  Options: `:now` (a `DateTime`) and `:workers` (snapshots, as
  `Arbiter.Worker.list_children/0` returns them).
  """
  @spec sweep(keyword()) :: [action()]
  def sweep(opts \\ []) do
    workers = Keyword.get_lazy(opts, :workers, &list_workers/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case Enum.filter(workers, &capped?/1) do
      [] -> []
      capped -> capped |> measure(workers, now) |> Enum.flat_map(&enforce/1)
    end
  rescue
    error ->
      Logger.warning("Guardrails.SpendPatrol.sweep failed: #{Exception.message(error)}")
      []
  catch
    :exit, _ -> []
  end

  # A live implementer run whose decision carries at least one cap.
  defp capped?(%{agent_live: true, meta: %{guardrail_decision: %{} = decision}}) do
    decision["eligible"] == true and decision["role"] == "implementer" and
      match?(%{"action" => action} when action in ["park", "page"], decision["spend"]) and
      Enum.any?(["tokens", "wall_clock_s"], &is_integer(decision["spend"][&1]))
  end

  defp capped?(_snapshot), do: false

  defp measure(capped, all_workers, now) do
    base_ids = capped |> Enum.map(&base_id/1) |> Enum.uniq()
    settled = Budget.settled_tokens_by_task(base_ids)
    live = LiveSpend.for_tasks(base_ids, workers: all_workers, settled: %{})

    Enum.map(capped, fn snap ->
      base = base_id(snap)
      decision = snap.meta.guardrail_decision
      provider = get_in(decision, ["subject", "provider"])

      tokens =
        provider_tokens(Map.get(settled, base, %{}), provider) + live_tokens(live[base], provider)

      started = Map.get(snap, :started_at)
      elapsed = if match?(%DateTime{}, started), do: max(DateTime.diff(now, started), 0), else: 0

      {snap, base, %{tokens: tokens, wall_clock_s: elapsed}}
    end)
  end

  defp base_id(%{task_id: task_id}), do: ReviewGate.base_task_id(task_id)

  # A ledger row with no provider is a Claude row (as `LiveSpend` reads it).
  defp provider_tokens(by_provider, provider) do
    by_provider
    |> Enum.filter(fn {p, _} -> (p || "claude") == provider end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  # `LiveSpend` reads only Claude session files; another provider's tokens are
  # in the ledger once its session ends.
  defp live_tokens(%{live_tokens: n}, "claude"), do: n
  defp live_tokens(_live, _provider), do: 0

  defp enforce({snap, base, measured}) do
    decision = snap.meta.guardrail_decision
    spend = decision["spend"]

    case check(spend, measured) do
      nil ->
        []

      breach ->
        tier = String.to_existing_atom(decision["tier"])
        breach = Map.put(breach, :tier, tier)
        act(spend["action"], snap, base, breach)
    end
  end

  defp act("park", snap, base, breach) do
    case Worker.park_spend_cap(snap.pid, StopReason.spend_cap(breach)) do
      :ok ->
        Logger.warning(
          "Guardrails.SpendPatrol: parked #{snap.task_id} — #{StopReason.spend_cap_figures(breach)}"
        )

        record_event(snap, breach)
        [result(base, :parked, breach)]

      {:error, _already_not_live} ->
        []
    end
  end

  defp act("page", snap, base, breach) do
    CoordinatorNotifier.spend_cap_exceeded(
      %{task_id: base, workspace_id: Map.get(snap, :workspace_id)},
      breach
    )

    [result(base, :paged, breach)]
  end

  # A park is a major guardrail event (design §6.1: major for quarantine and
  # probation, the park tiers) against the subject the run was dispatched as, so
  # `Arbiter.Loop.Trust` counts it: two within 14 days demote. One per run.
  defp record_event(%{run_id: run_id} = snap, breach) when is_binary(run_id) do
    subject = snap.meta.guardrail_decision["subject"] || %{}

    Events.record(%{
      run_id: run_id,
      task_id: snap.task_id,
      provider: subject["provider"],
      model: subject["model"],
      kind: :spend_cap,
      severity: :major,
      source: :spend_patrol,
      detail:
        "#{breach.tier}-tier #{StopReason.spend_cap_label(breach.cap)} cap: " <>
          StopReason.spend_cap_figures(breach),
      fingerprint: "spend_cap"
    })
  end

  defp record_event(_snap, _breach), do: :error

  defp result(base, action, breach) do
    Map.merge(%{task_id: base, action: action}, breach)
  end

  defp list_workers do
    Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
