defmodule Arbiter.Board.AdmissionShadowReport.Quota do
  @moduledoc """
  The quota-side sections of the admission shadow report (DC7, bd-6cuqcf;
  `docs/design/provider-dynamic-concurrency.md` §10.3): pace safety,
  calibration, stability and the neighbourhood of each reset. All pure, over
  `quota_snapshots`-shaped rows (`:provider_account_id`, `:provider`,
  `:bucket`, `:window`, `:utilization`, `:resets_at`, `:captured_at`, `:seats`,
  `:budget`) and the `Arbiter.Quota.BudgetCalibration` results.

  The line is `Arbiter.Quota.Gate.pace/6`'s ceiling under the account's real
  policy, read at each capture's own time: the same definition the budget uses
  (I6), so `u − line` here is the margin the budget was built to keep.
  Read-only; nothing here reaches a dispatch decision.
  """

  alias Arbiter.Loop.Scarcity.Draw
  alias Arbiter.Quota.Gate

  @default_horizon_hours 2.0
  @long_window_seconds 2 * 86_400
  @weekly_seconds 6 * 86_400

  @type rows :: [map()]

  # ---- pace safety -------------------------------------------------------------

  @doc """
  Per pool: the distribution of `u − line` at captures, the admissions made
  ahead of the line (a capture where the account's seats rose and `u` was over
  it) with the largest `ε` and the time back to the line, and the projected
  exhaustion episodes (`u + (S·ρ + b)·t_r ≥ 1` at a capture, once per run of
  consecutive captures).
  """
  @spec pace(rows(), %{optional(String.t()) => term()}, [map()]) :: [map()]
  def pace(snapshots, accounts, calibration) do
    rates = rates(calibration)

    snapshots
    |> series()
    |> Enum.map(fn {{account, provider, bucket, window}, rows} ->
      {Draw.pool(provider, bucket), pace_series(rows, Map.get(accounts, account), window, rates, account)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {pool, parts} -> pace_pool(pool, parts) end)
    |> Enum.sort_by(& &1.pool)
  end

  defp pace_series(rows, account, window, rates, account_id) do
    side = if (Gate.window_seconds(window, account) || 0) >= @long_window_seconds, do: :long, else: :primary

    margins =
      Enum.map(rows, fn r ->
        pace = Gate.pace({account, nil}, side, window, r.utilization, r.resets_at, now: r.captured_at)
        Map.put(r, :ahead, r.utilization - pace.ceiling)
      end)

    %{
      margins: Enum.map(margins, & &1.ahead),
      admissions: admissions(margins),
      projected: projected(margins, Map.get(rates, {account_id, window}))
    }
  end

  # A capture where the seat count rose over the previous capture's.
  defp admissions(rows) do
    rows
    |> Enum.with_index()
    |> Enum.filter(fn {r, i} -> i > 0 and seat_rise?(Enum.at(rows, i - 1), r) and r.ahead > 0.0 end)
    |> Enum.map(fn {r, i} ->
      back =
        rows
        |> Enum.drop(i + 1)
        |> Enum.find(&(&1.ahead <= 0.0))

      %{epsilon: r.ahead, minutes_back: back && DateTime.diff(back.captured_at, r.captured_at) / 60}
    end)
  end

  defp seat_rise?(%{seats: a}, %{seats: b}) when is_integer(a) and is_integer(b), do: b > a
  defp seat_rise?(_prev, _row), do: false

  defp projected(_rows, nil), do: 0

  defp projected(rows, {rho, background}) do
    rows
    |> Enum.map(&exhausts?(&1, rho, background))
    |> Enum.chunk_by(& &1)
    |> Enum.count(&(hd(&1) == true))
  end

  defp exhausts?(%{seats: seats, resets_at: %DateTime{} = reset} = r, rho, background)
       when is_integer(seats) do
    t_r = max(DateTime.diff(reset, r.captured_at), 0) / 3600
    r.utilization + (seats * rho + background) * t_r >= 1.0
  end

  defp exhausts?(_row, _rho, _background), do: false

  defp rates(calibration) do
    for r <- calibration, is_number(r.rho), into: %{} do
      background =
        case r.fit do
          %{background_share_per_hour: b} when is_number(b) -> b
          _ -> 0.0
        end

      {{r.account_id, r.window}, {r.rho, background}}
    end
  end

  defp pace_pool(pool, parts) do
    margins = Enum.flat_map(parts, & &1.margins)
    admissions = Enum.flat_map(parts, & &1.admissions)
    back = for %{minutes_back: m} <- admissions, is_number(m), do: m

    %{
      pool: pool,
      captures: length(margins),
      p50: percentile(margins, 0.5),
      p90: percentile(margins, 0.9),
      max_ahead: margins |> Enum.max(fn -> 0.0 end) |> max(0.0),
      ahead_admissions: length(admissions),
      largest_epsilon: admissions |> Enum.map(& &1.epsilon) |> Enum.max(fn -> nil end),
      minutes_back_to_line: Enum.max(back, fn -> nil end),
      never_back: Enum.count(admissions, &is_nil(&1.minutes_back)),
      projected_exhaustions: parts |> Enum.map(& &1.projected) |> Enum.sum()
    }
  end

  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(round(p * (length(sorted) - 1)), length(sorted) - 1))
  end

  # ---- calibration -------------------------------------------------------------

  @doc """
  Predicted draw `Σ S·ρ·Δt + b·Δt` against the actual `Δu` per observed
  interval: bias (`Σ(pred − actual) / Σ actual`, positive when the model
  over-predicts) and mean absolute error, per rung of the ladder, plus each
  fit with its `ρ`, `se`, `t` and the rungs it passed over.
  """
  @spec calibration([map()]) :: %{rungs: [map()], fits: [map()]}
  def calibration(results) do
    fits = results |> Enum.filter(& &1.rung) |> Enum.map(&fit_entry/1)

    rungs =
      fits
      |> Enum.group_by(& &1.rung)
      |> Enum.map(fn {rung, group} ->
        pairs = Enum.flat_map(group, & &1.pairs)
        Map.merge(errors(pairs), %{rung: rung, fits: length(group)})
      end)
      |> Enum.sort_by(& &1.rung)

    %{rungs: rungs, fits: Enum.map(fits, &(&1 |> Map.merge(errors(&1.pairs)) |> Map.delete(:pairs)))}
  end

  defp fit_entry(r) do
    background = if is_number(background_of(r)), do: background_of(r), else: 0.0

    pairs =
      for o <- Map.get(r, :observations, []) do
        {r.rho * Map.get(o.draws, "seat", 0.0) + background * o.hours, o.share}
      end

    seat = get_in(r.fit, [Access.key(:models, %{}), Access.key("seat", %{})]) || %{}
    se = Map.get(seat, :std_error)
    raw = Map.get(seat, :share_per_weighted_token)

    %{
      account_id: r.account_id,
      pool: r.pool,
      window: r.window,
      rung: r.rung,
      rho: r.rho,
      raw_rho: r.raw_rho,
      floored?: r.floored?,
      se: se,
      t: if(is_number(se) and se > 0 and is_number(raw), do: raw / se),
      passed_over: r.passed_over,
      pairs: pairs
    }
  end

  defp background_of(%{fit: %{background_share_per_hour: b}}), do: b
  defp background_of(_), do: nil

  defp errors(pairs) do
    n = length(pairs)
    actual = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    predicted = pairs |> Enum.map(&elem(&1, 0)) |> Enum.sum()

    %{
      intervals: n,
      bias: if(n > 0 and actual > 0, do: (predicted - actual) / actual),
      mean_abs_error: if(n > 0, do: pairs |> Enum.map(fn {p, a} -> abs(p - a) end) |> Enum.sum() |> Kernel./(n))
    }
  end

  # ---- stability ---------------------------------------------------------------

  @doc """
  Per pool: published budget changes seen across captures (the column is
  `nil` before DC2, and those captures count for nothing), per day over the
  window, the busiest rolling hour, and the median dwell between changes.
  A change shorter than the poll interval is invisible here.
  """
  @spec stability(rows(), DateTime.t(), DateTime.t()) :: [map()]
  def stability(snapshots, since, until) do
    days = max(DateTime.diff(until, since), 1) / 86_400

    snapshots
    |> Enum.group_by(&{&1.provider_account_id, Draw.pool(&1.provider, &1.bucket)})
    |> Enum.map(fn {{_account, pool}, rows} -> {pool, budget_runs(rows)} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {pool, runs} ->
      changes = Enum.flat_map(runs, & &1.changes)
      dwells = Enum.flat_map(runs, & &1.dwells)

      %{
        pool: pool,
        budget_captures: runs |> Enum.map(& &1.captures) |> Enum.sum(),
        changes: length(changes),
        changes_per_day: length(changes) / days,
        max_changes_per_hour: runs |> Enum.map(&busiest_hour(&1.changes)) |> Enum.max() |> Kernel.*(1.0),
        median_dwell_minutes: median(dwells)
      }
    end)
    |> Enum.sort_by(& &1.pool)
  end

  # One budget per capture (the windows of a capture share it); the times it
  # changed and how long each value held.
  defp budget_runs(rows) do
    points =
      rows
      |> Enum.filter(&is_integer(&1.budget))
      |> Enum.uniq_by(& &1.captured_at)
      |> Enum.sort_by(& &1.captured_at, DateTime)

    starts =
      points
      |> Enum.chunk_while(
        nil,
        fn p, prev -> if prev == p.budget, do: {:cont, p.budget}, else: {:cont, p, p.budget} end,
        fn _ -> {:cont, nil} end
      )

    changes = starts |> Enum.drop(1) |> Enum.map(& &1.captured_at)

    dwells =
      starts
      |> Enum.zip(Enum.drop(starts, 1))
      |> Enum.map(fn {a, b} -> DateTime.diff(b.captured_at, a.captured_at) / 60 end)

    %{changes: changes, dwells: dwells, captures: length(points)}
  end

  defp busiest_hour([]), do: 0

  defp busiest_hour(times) do
    times
    |> Enum.map(fn t -> Enum.count(times, &(DateTime.diff(&1, t) in 0..3600)) end)
    |> Enum.max()
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)
    if rem(n, 2) == 1, do: Enum.at(sorted, mid) * 1.0, else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  # ---- near resets -------------------------------------------------------------

  @doc """
  For each reset the history saw: the seats and the budget in the last horizon
  `H` before it, whether seats ever exceeded the budget there, and the highest
  usage in the first `H` after it. `H` is the calibration's, 2 h when none.
  """
  @spec near_resets(rows(), %{optional(String.t()) => term()}, [map()]) :: [map()]
  def near_resets(snapshots, accounts, calibration) do
    horizons = Map.new(calibration, &{{&1.account_id, &1.window}, &1.horizon_hours})

    snapshots
    |> series()
    |> Enum.flat_map(fn {{account, provider, bucket, window}, rows} ->
      h = Map.get(horizons, {account, window}, @default_horizon_hours)
      seconds = Gate.window_seconds(window, Map.get(accounts, account))
      pool = Draw.pool(provider, bucket)

      rows
      |> Enum.map(& &1.resets_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(&reset_entry(&1, rows, h, %{account: account, pool: pool, window: window, seconds: seconds}))
    end)
    |> Enum.sort_by(&{&1.pool, &1.window, &1.reset_at}, fn a, b -> a <= b end)
  end

  defp reset_entry(reset, rows, h, meta) do
    span = round(h * 3600)

    before =
      Enum.filter(rows, fn r ->
        r.resets_at == reset and DateTime.diff(reset, r.captured_at) in 1..span
      end)

    after_rows =
      Enum.filter(rows, fn r ->
        r.resets_at != reset and DateTime.diff(r.captured_at, reset) in 0..span
      end)

    seen_after? = Enum.any?(rows, &(DateTime.compare(&1.captured_at, reset) != :lt))

    if before != [] and seen_after? do
      seats = for %{seats: s} <- before, is_integer(s), do: s
      budgets = for %{budget: b} <- before, is_integer(b), do: b

      [
        %{
          account_id: meta.account,
          pool: meta.pool,
          window: meta.window,
          window_seconds: meta.seconds,
          reset_at: reset,
          horizon_hours: h,
          max_seats_before: Enum.max(seats, fn -> nil end),
          min_budget_before: Enum.min(budgets, fn -> nil end),
          over_budget_before: Enum.any?(before, &over_budget?/1),
          max_used_after: after_rows |> Enum.map(& &1.utilization) |> Enum.max(fn -> nil end)
        }
      ]
    else
      []
    end
  end

  defp over_budget?(%{seats: s, budget: b}) when is_integer(s) and is_integer(b), do: s > b
  defp over_budget?(_), do: false

  @doc "How many distinct weekly-scale resets each account saw, as the largest count."
  @spec weekly_resets([map()]) :: non_neg_integer()
  def weekly_resets(near_resets) do
    near_resets
    |> Enum.filter(&((&1.window_seconds || 0) >= @weekly_seconds))
    |> Enum.group_by(& &1.account_id, & &1.reset_at)
    |> Enum.map(fn {_account, resets} -> resets |> Enum.uniq() |> length() end)
    |> Enum.max(fn -> 0 end)
  end

  # ---- shared ------------------------------------------------------------------

  defp series(snapshots) do
    snapshots
    |> Enum.group_by(&{&1.provider_account_id, &1.provider, &1.bucket, &1.window})
    |> Enum.map(fn {key, rows} -> {key, Enum.sort_by(rows, & &1.captured_at, DateTime)} end)
  end
end
