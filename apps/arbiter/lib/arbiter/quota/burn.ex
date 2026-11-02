defmodule Arbiter.Quota.Burn do
  @moduledoc """
  The rolling-24h burn of a long window (bd-cklotu, the optional `daily_burn_cap`
  governor that replaces the retired 5h window as a short-horizon brake).

  `burn_24h/2` is how much of the account's 7d window was used in the last 24
  hours, as a fraction of that window: the sum of the utilization increments
  across the `quota_snapshots` samples of the last 24 h. It is pure: the samples
  come in, a number or `nil` comes out. `compute/3` reads them from
  `Arbiter.Quota.History` and `refresh/2` stores the result on the account's
  quota row at poll time.

  ## Window-reset baseline

  Utilization falls to ~0 when the window rolls over, so `u_now − u_24h_ago`
  would go negative or understate the burn. Walking the samples pairwise, a pair
  is a **reset** when `resets_at` moved by more than #{600} s (it jitters by a
  second or two between polls; a new window instance moves it by days) or, with
  no `resets_at`, when utilization fell. Across a reset the new window's
  baseline is zero, so the pair adds the later sample's whole utilization;
  otherwise it adds the (never negative) increase.

  ## Sparse samples are `nil`

  A burn read off a thin history would be wrong in both directions, so `nil` is
  returned, and the governor treats `nil` as "no reading" (it never holds on it),
  unless the samples:

    * reach back to within #{2} h of the 24 h mark (a sample at or before it is
      the baseline; else the earliest sample must be within the slack),
    * end within 1 h of `now`, and
    * have no gap longer than 3 h (a poll is every 5 min).
  """

  @window_seconds 24 * 3600
  @start_slack_seconds 2 * 3600
  @end_slack_seconds 3600
  @max_gap_seconds 3 * 3600
  @reset_jitter_seconds 600
  # Rows older than this never matter to a 24h reading.
  @lookback_seconds @window_seconds + 3 * 3600
  @grid_seconds 3600

  @type sample :: %{
          required(:utilization) => number(),
          required(:captured_at) => DateTime.t(),
          optional(:resets_at) => DateTime.t() | nil
        }

  @doc "The window length the burn is measured over, in seconds."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc """
  The utilization gained over the 24 h before `now`, or `nil` when the samples
  are too sparse to say. `samples` is oldest first.
  """
  @spec burn_24h([sample()], DateTime.t()) :: float() | nil
  def burn_24h(samples, %DateTime{} = now) do
    start = DateTime.add(now, -@window_seconds, :second)

    {before_start, inside} =
      samples
      |> Enum.filter(&is_number(&1.utilization))
      |> Enum.split_while(&(DateTime.compare(&1.captured_at, start) != :gt))

    series =
      case List.last(before_start) do
        nil -> inside
        baseline -> [baseline | inside]
      end

    if covered?(series, start, now), do: sum_increments(series)
  end

  defp covered?([_, _ | _] = series, start, now) do
    first = hd(series)
    last = List.last(series)

    DateTime.diff(first.captured_at, start) <= @start_slack_seconds and
      DateTime.diff(now, last.captured_at) <= @end_slack_seconds and
      series
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] ->
        DateTime.diff(b.captured_at, a.captured_at) <= @max_gap_seconds
      end)
  end

  defp covered?(_series, _start, _now), do: false

  defp sum_increments(series) do
    series
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc -> acc + increment(a, b) end)
  end

  defp increment(a, b) do
    if reset?(a, b),
      do: b.utilization * 1.0,
      else: max(b.utilization - a.utilization, 0.0)
  end

  defp reset?(%{resets_at: %DateTime{} = ra}, %{resets_at: %DateTime{} = rb}),
    do: abs(DateTime.diff(rb, ra)) > @reset_jitter_seconds

  defp reset?(a, b), do: b.utilization < a.utilization

  @doc """
  The rolling 24 h burn over a whole history, on an hourly grid: one
  `%{at, burn}` per grid point with a reading (`burn_24h/2` is not `nil`), oldest
  first. The input of the `burn_report`. `samples` is oldest first.
  """
  @spec deltas([sample()]) :: [%{at: DateTime.t(), burn: float()}]
  def deltas(samples) do
    samples = Enum.filter(samples, &is_number(&1.utilization))

    samples
    |> grid_points()
    |> Enum.flat_map(fn at ->
      from = DateTime.add(at, -@lookback_seconds, :second)

      window =
        Enum.filter(samples, fn s ->
          DateTime.compare(s.captured_at, from) != :lt and
            DateTime.compare(s.captured_at, at) != :gt
        end)

      case burn_24h(window, at) do
        nil -> []
        burn -> [%{at: at, burn: burn}]
      end
    end)
  end

  # The first sample of each wall-clock hour.
  defp grid_points(samples) do
    samples
    |> Enum.map(& &1.captured_at)
    |> Enum.uniq_by(&div(DateTime.to_unix(&1), @grid_seconds))
  end

  @doc "`%{n, p50, p90, p99}` of `values` (nearest rank); the percentiles are `nil` for none."
  @spec percentiles([number()]) :: %{
          n: non_neg_integer(),
          p50: float() | nil,
          p90: float() | nil,
          p99: float() | nil
        }
  def percentiles([]), do: %{n: 0, p50: nil, p90: nil, p99: nil}

  def percentiles(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    at = fn p -> Enum.at(sorted, min(round(p * (n - 1)), n - 1)) * 1.0 end
    %{n: n, p50: at.(0.5), p90: at.(0.9), p99: at.(0.99)}
  end
end
