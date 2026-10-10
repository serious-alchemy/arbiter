defmodule Arbiter.Board.AdmissionShadowReport do
  @moduledoc """
  The admission shadow report (DC7, bd-6cuqcf;
  `docs/design/provider-dynamic-concurrency.md` §10.3-§10.4): under
  `scheduler_admission: shadow` (or `enforce`, which records the same until
  DC8) the scheduler walk's decision is written beside today's, and this
  reads those records so an operator can decide the gate to `enforce`.

  Sections (§10.3):

    * **Agreement** — comparable dispatches (`routing_decision.admission_shadow`
      on the run), the agreement rate, every disagreement by cause, and per
      pool. The budgets on the hold-change rows say how often a budget sat
      below today's cap and how often above it (the ceiling binds, so no
      change).
    * **Throughput** — minutes where today held and the walk would have placed
      a card, and the reverse, from the `admission_shadow_events` rows: a row
      holds until the next one. An open interval is capped at
      #{div(360, 60)} h, so a switch back to `legacy` (which writes nothing)
      cannot inflate it.
    * **Pace safety**, **Calibration**, **Stability** and **Near resets** —
      from `quota_snapshots` and `Arbiter.Quota.BudgetCalibration`
      (`Arbiter.Board.AdmissionShadowReport.Quota`).
    * **Gate** — each §10.4 criterion as `:met`, `:unmet` or `:unknown`. An
      operator's review of the disagreement classes is never inferred.

  Read-only: `collect/1` reads, `build/1` is pure, `format/1` renders. Nothing
  here reaches a dispatch decision.
  """

  require Ash.Query

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Board.AdmissionShadowEvent
  alias Arbiter.Board.AdmissionShadowReport.Quota
  alias Arbiter.Quota.BudgetCalibration
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Workers.Run

  @default_days 30
  @max_dwell_minutes 360.0
  @gate_days 14
  @gate_weekly_resets 2
  @gate_comparable 50
  @gate_bias 0.25
  @none "(none)"

  @type data :: %{
          since: DateTime.t(),
          until: DateTime.t(),
          dispatches: [%{at: DateTime.t(), record: map()}],
          events: [map()],
          snapshots: [map()],
          accounts: %{optional(String.t()) => ProviderAccount.t()},
          calibration: [map()]
        }

  @type report :: %{required(atom()) => term()}

  # ---- collect -----------------------------------------------------------------

  @doc """
  Everything the report reads. Options: `:since` (default 30 days ago) and
  `:until` (default now).
  """
  @spec collect(keyword()) :: data()
  def collect(opts \\ []) do
    until = Keyword.get_lazy(opts, :until, &DateTime.utc_now/0)

    since =
      Keyword.get_lazy(opts, :since, fn ->
        DateTime.add(until, -@default_days * 86_400, :second)
      end)

    snapshots =
      QuotaSnapshot
      |> Ash.Query.filter(captured_at >= ^since and captured_at <= ^until)
      |> Ash.Query.sort(captured_at: :asc)
      |> Ash.read!()

    %{
      since: since,
      until: until,
      dispatches: read_dispatches(since, until),
      events: read_events(since, until),
      snapshots: snapshots,
      accounts: read_accounts(snapshots),
      calibration: BudgetCalibration.calibrate(since: since, until: until)
    }
  end

  defp read_dispatches(since, until) do
    Run
    |> Ash.Query.filter(
      not is_nil(routing_decision) and started_at >= ^since and started_at <= ^until
    )
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.Query.select([:id, :started_at, :routing_decision])
    |> Ash.read!()
    |> Enum.flat_map(fn run ->
      case run.routing_decision do
        %{"admission_shadow" => %{} = record} -> [%{at: run.started_at, record: record}]
        _ -> []
      end
    end)
  end

  defp read_events(since, until) do
    AdmissionShadowEvent
    |> Ash.Query.filter(at >= ^since and at <= ^until)
    |> Ash.Query.sort(at: :asc)
    |> Ash.read!()
  end

  defp read_accounts(snapshots) do
    case snapshots |> Enum.map(& &1.provider_account_id) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        ProviderAccount |> Ash.Query.filter(id in ^ids) |> Ash.read!() |> Map.new(&{&1.id, &1})
    end
  end

  # ---- build -------------------------------------------------------------------

  @doc "Summarise `t:data/0` into the report's sections."
  @spec build(data()) :: report()
  def build(%{since: since, until: until} = data) do
    events = Enum.sort_by(data.events, & &1.at, DateTime)
    snapshots = data.snapshots

    pace = Quota.pace(snapshots, data.accounts, data.calibration)
    calibration = Quota.calibration(data.calibration)
    stability = Quota.stability(snapshots, since, until)
    near_resets = Quota.near_resets(snapshots, data.accounts, data.calibration)
    agreement = agreement(data.dispatches, events)

    report = %{
      since: since,
      until: until,
      agreement: agreement,
      throughput: throughput(events, until),
      pace: pace,
      calibration: calibration,
      stability: stability,
      near_resets: near_resets
    }

    Map.put(report, :gate, gate(report, data, events))
  end

  defp agreement(dispatches, events) do
    records = Enum.map(dispatches, & &1.record)
    {comparable, other} = Enum.split_with(records, &(&1["comparable"] == true))
    {agree, disagree} = Enum.split_with(comparable, &(&1["agrees"] == true))
    budgets = Enum.flat_map(events, & &1.budgets)

    %{
      dispatches: length(records),
      comparable: length(comparable),
      agree: length(agree),
      disagree: length(disagree),
      rate: if(comparable != [], do: length(agree) / length(comparable)),
      not_comparable: length(other),
      by_cause: cause_counts(disagree),
      pools:
        comparable
        |> Enum.group_by(&pool_of/1)
        |> Enum.map(&pool_agreement/1)
        |> Enum.sort_by(& &1.pool),
      budget_below_cap: budget_counts(budgets, &</2),
      budget_above_cap: budget_counts(budgets, &>/2)
    }
  end

  defp pool_agreement({pool, records}) do
    {agree, disagree} = Enum.split_with(records, &(&1["agrees"] == true))

    %{
      pool: pool,
      comparable: length(records),
      agree: length(agree),
      disagree: length(disagree),
      by_cause: cause_counts(disagree)
    }
  end

  defp pool_of(record), do: record["pool_label"] || record["pool"] || @none

  defp cause_counts(records), do: records |> Enum.frequencies_by(&(&1["cause"] || "unknown"))

  defp budget_counts(budgets, compare) do
    budgets
    |> Enum.filter(fn b ->
      is_integer(b["budget"]) and is_integer(b["cap"]) and compare.(b["budget"], b["cap"])
    end)
    |> Enum.frequencies_by(&(&1["label"] || &1["pool"] || @none))
  end

  defp throughput(events, until) do
    intervals =
      events
      |> Enum.zip(Enum.drop(events, 1) ++ [nil])
      |> Enum.map(fn {event, next} ->
        stop = if next, do: next.at, else: until
        minutes = max(DateTime.diff(stop, event.at), 0) / 60
        {event, min(minutes, @max_dwell_minutes), minutes > @max_dwell_minutes}
      end)

    walk_ahead =
      Enum.filter(intervals, fn {e, _, _} -> is_nil(e.legacy_pick) and not is_nil(e.walk_pick) end)

    legacy_ahead =
      Enum.filter(intervals, fn {e, _, _} -> not is_nil(e.legacy_pick) and is_nil(e.walk_pick) end)

    %{
      walk_ahead_minutes: total(walk_ahead),
      legacy_ahead_minutes: total(legacy_ahead),
      by_pool:
        walk_ahead
        |> Enum.group_by(fn {e, _, _} -> e.walk["pool_label"] || e.walk["pool"] || @none end)
        |> Map.new(fn {pool, list} -> {pool, total(list)} end),
      capped_intervals: Enum.count(walk_ahead ++ legacy_ahead, fn {_, _, capped?} -> capped? end)
    }
  end

  defp total(intervals), do: intervals |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Kernel.*(1.0)

  # ---- the gate to enforce (§10.4) ---------------------------------------------

  defp gate(report, data, events) do
    stamps = Enum.map(data.dispatches, & &1.at) ++ Enum.map(events, & &1.at)
    days = days_in_shadow(stamps)

    [
      criterion(
        :days_in_shadow,
        "#{@gate_days} days in shadow",
        days_status(days),
        days_detail(days)
      ),
      criterion(
        :weekly_resets,
        "at least #{@gate_weekly_resets} weekly resets of the binding account",
        count_status(Quota.weekly_resets(report.near_resets), @gate_weekly_resets),
        "#{Quota.weekly_resets(report.near_resets)} seen"
      ),
      criterion(
        :comparable_dispatches,
        "at least #{@gate_comparable} comparable dispatches",
        count_status(report.agreement.comparable, @gate_comparable),
        "#{report.agreement.comparable} comparable"
      ),
      criterion(
        :disagreements_reviewed,
        "every disagreement class reviewed",
        :unknown,
        "an operator's call; classes seen: #{classes(report.agreement.by_cause)}"
      ),
      bias_criterion(report.calibration.fits, binding_windows(events)),
      stability_criterion(report.stability),
      exhaustion_criterion(report.pace, data.calibration)
    ]
  end

  defp criterion(id, label, status, detail),
    do: %{id: id, label: label, status: status, detail: detail}

  # Coverage, not elapsed time: the distinct UTC days that hold a shadow record.
  # A day of shadow long ago followed by a switch back to legacy is one day.
  defp days_in_shadow(stamps),
    do: stamps |> Enum.map(&DateTime.to_date/1) |> Enum.uniq() |> length()

  defp days_status(days) when days >= @gate_days, do: :met
  defp days_status(_days), do: :unmet

  defp days_detail(days), do: "#{days} days with shadow records"

  defp count_status(n, need) when n >= need, do: :met
  defp count_status(_n, _need), do: :unmet

  defp classes(by_cause) when map_size(by_cause) == 0, do: "none"
  defp classes(by_cause), do: by_cause |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  # The windows the budget bound on, from the hold-change rows' budgets.
  defp binding_windows(events) do
    for e <- events,
        b <- e.budgets,
        "window:" <> label <- [b["binding"]],
        uniq: true,
        do: label
  end

  defp bias_criterion(fits, binding) do
    in_scope = Enum.filter(fits, &(&1.window in binding))
    scope = if in_scope == [], do: fits, else: in_scope
    biased = Enum.filter(scope, &is_number(&1.bias))
    worst = biased |> Enum.map(&abs(&1.bias)) |> Enum.max(fn -> nil end)
    label = "calibration bias within ±#{round(@gate_bias * 100)}% on the binding window"

    cond do
      worst == nil ->
        criterion(:calibration_bias, label, :unknown, "no fitted interval to compare")

      worst <= @gate_bias ->
        criterion(:calibration_bias, label, :met, "worst #{pct(worst)}")

      true ->
        criterion(:calibration_bias, label, :unmet, "worst #{pct(worst)}")
    end
  end

  defp stability_criterion(stability) do
    label = "under one published change an hour per pool"
    seen = Enum.filter(stability, &(&1.budget_captures > 0))
    busy = Enum.filter(stability, &(&1.max_changes_per_hour > 1))

    cond do
      busy != [] ->
        criterion(:stability, label, :unmet, "busy: #{Enum.map_join(busy, ", ", & &1.pool)}")

      seen == [] ->
        criterion(:stability, label, :unknown, "no published budget in the captures")

      true ->
        criterion(
          :stability,
          label,
          :met,
          "busiest hour #{seen |> Enum.map(& &1.max_changes_per_hour) |> Enum.max()}"
        )
    end
  end

  defp exhaustion_criterion(pace, calibration) do
    label = "no projected exhaustion"
    total = pace |> Enum.map(& &1.projected_exhaustions) |> Enum.sum()

    cond do
      Enum.all?(calibration, &is_nil(&1.rho)) ->
        criterion(:no_exhaustion, label, :unknown, "no rate to project with")

      total > 0 ->
        criterion(:no_exhaustion, label, :unmet, "#{total} projected")

      true ->
        criterion(:no_exhaustion, label, :met, "none projected")
    end
  end

  # ---- format ------------------------------------------------------------------

  @doc "A plain-text rendering of `build/1`, for an operator to read."
  @spec format(report()) :: String.t()
  def format(report) do
    [
      "Admission shadow report, #{day(report.since)} to #{day(report.until)}",
      agreement_text(report.agreement),
      throughput_text(report.throughput),
      pace_text(report.pace),
      calibration_text(report.calibration),
      stability_text(report.stability),
      near_resets_text(report.near_resets),
      gate_text(report.gate)
    ]
    |> Enum.join("\n\n")
  end

  defp agreement_text(a) do
    rate = if a.rate, do: "#{pct(a.rate)} agree", else: "no comparable dispatch"

    head =
      "Agreement\n  #{a.dispatches} dispatches, #{a.comparable} comparable (#{rate}), " <>
        "#{a.disagree} disagree, #{a.not_comparable} not comparable"

    [
      head,
      cause_lines("  disagreements", a.by_cause),
      Enum.map_join(a.pools, "\n", &pool_line/1),
      count_line("  budget below today's cap (rows)", a.budget_below_cap),
      count_line("  budget above today's cap, ceiling binds (rows)", a.budget_above_cap)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp pool_line(p) do
    "  #{p.pool}: #{p.comparable} comparable, #{p.agree} agree" <> cause_inline(p.by_cause)
  end

  defp cause_inline(by_cause) when map_size(by_cause) == 0, do: ""
  defp cause_inline(by_cause), do: " (" <> pairs(by_cause) <> ")"

  defp cause_lines(_label, by_cause) when map_size(by_cause) == 0, do: ""
  defp cause_lines(label, by_cause), do: "#{label}: #{pairs(by_cause)}"

  defp count_line(_label, counts) when map_size(counts) == 0, do: ""
  defp count_line(label, counts), do: "#{label}: #{pairs(counts)}"

  defp pairs(map), do: map |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k} #{v}" end)

  defp throughput_text(t) do
    pools =
      if map_size(t.by_pool) == 0,
        do: "",
        else: "\n  walk ahead by pool: #{minutes_pairs(t.by_pool)}"

    capped =
      if t.capped_intervals > 0,
        do: "\n  #{t.capped_intervals} interval(s) capped at 6 h",
        else: ""

    "Throughput\n  walk would place, today held: #{mins(t.walk_ahead_minutes)}\n" <>
      "  today places, walk would hold: #{mins(t.legacy_ahead_minutes)}" <> pools <> capped
  end

  defp minutes_pairs(map),
    do: map |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k} #{mins(v)}" end)

  defp pace_text([]), do: "Pace safety\n  no quota captures"

  defp pace_text(pools) do
    "Pace safety (u − line at captures)\n" <> Enum.map_join(pools, "\n", &pace_line/1)
  end

  defp pace_line(p) do
    "  #{p.pool}: #{p.captures} captures, median #{signed(p.p50)}, p90 #{signed(p.p90)}, " <>
      "worst #{signed(p.max_ahead)}; #{p.ahead_admissions} ahead-of-pace admission(s)" <>
      eps(p) <> "; #{p.projected_exhaustions} projected exhaustion(s)"
  end

  defp eps(%{largest_epsilon: nil}), do: ""

  defp eps(p) do
    back =
      if p.minutes_back_to_line,
        do: ", back on the line after #{mins(p.minutes_back_to_line)}",
        else: ""

    never = if p.never_back > 0, do: ", #{p.never_back} not back by the window's end", else: ""
    " (largest ε #{signed(p.largest_epsilon)}#{back}#{never})"
  end

  defp calibration_text(%{rungs: [], fits: []}),
    do: "Calibration\n  no quota history to calibrate from"

  defp calibration_text(%{rungs: rungs, fits: fits}) do
    rung_lines =
      Enum.map_join(rungs, "\n", fn r ->
        "  rung #{r.rung}: #{r.fits} fit(s), #{r.intervals} intervals, bias #{opt_pct(r.bias)}, " <>
          "mean abs error #{opt_pct(r.mean_abs_error)}"
      end)

    "Calibration (predicted vs actual draw)\n#{rung_lines}\n" <>
      Enum.map_join(fits, "\n", &fit_line/1)
  end

  defp fit_line(f) do
    se = if f.se, do: " se #{pct(f.se)}", else: ""
    t = if f.t, do: " t #{Float.round(f.t * 1.0, 2)}", else: ""
    floor = if f.floored?, do: " floored from #{pct(f.raw_rho)}", else: ""

    passed =
      Enum.map_join(f.passed_over, "", fn {rung, why} ->
        "\n      passed over rung #{rung}: #{inspect(why)}"
      end)

    "  #{f.pool} / #{f.window} (#{f.account_id}): rung #{f.rung}, ρ #{pct(f.rho)}/seat-h#{se}#{t}#{floor}" <>
      passed
  end

  defp stability_text([]), do: "Stability\n  no quota captures"

  defp stability_text(pools) do
    lines =
      Enum.map_join(pools, "\n", fn p ->
        "  #{p.pool}: #{p.changes} published change(s), #{Float.round(p.changes_per_day, 2)}/day, " <>
          "busiest hour #{trunc(p.max_changes_per_hour)}, median dwell #{opt_mins(p.median_dwell_minutes)}"
      end)

    "Stability\n" <> lines
  end

  defp near_resets_text([]), do: "Near resets\n  no reset seen in the captures"

  defp near_resets_text(resets) do
    lines =
      Enum.map_join(resets, "\n", fn r ->
        "  #{r.pool} / #{r.window} at #{Calendar.strftime(r.reset_at, "%Y-%m-%d %H:%M")}: " <>
          "last #{r.horizon_hours} h before, max seats #{opt(r.max_seats_before)}, " <>
          "min budget #{opt(r.min_budget_before)}#{if r.over_budget_before, do: " (SEATS OVER BUDGET)", else: ""}; " <>
          "first #{r.horizon_hours} h after, max used #{opt_pct(r.max_used_after)}"
      end)

    "Near resets\n" <> lines
  end

  defp gate_text(gate) do
    lines =
      Enum.map_join(gate, "\n", fn c ->
        "  [#{c.status |> to_string() |> String.upcase()}] #{c.label}: #{c.detail}"
      end)

    "Gate to enforce (§10.4; an operator's OK is also required)\n" <> lines
  end

  defp day(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100.0, decimals: 1)}%"
  defp opt_pct(nil), do: "n/a"
  defp opt_pct(x), do: pct(x)

  defp signed(nil), do: "n/a"
  defp signed(x), do: if(x >= 0, do: "+", else: "") <> pct(x)

  defp mins(m), do: "#{:erlang.float_to_binary(m * 1.0, decimals: 0)} min"
  defp opt_mins(nil), do: "n/a"
  defp opt_mins(m), do: mins(m)

  defp opt(nil), do: "n/a"
  defp opt(x), do: to_string(x)
end
