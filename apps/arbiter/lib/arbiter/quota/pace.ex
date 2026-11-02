defmodule Arbiter.Quota.Pace do
  @approaching_margin 0.10
  @sampling_floor 0.05

  @moduledoc """
  The per-window pace verdict (bd-clzkvp): the one definition of "ahead of
  pace" that both the dispatch gate and the quota bars read.

  `evaluate/4` is pure. It takes one window's utilization, how far into the
  window we are, the window's length, and the thresholds that apply to it,
  and returns a verdict:

    * `:holding` — `utilization >= ceiling`. This is exactly the condition
      under which `Arbiter.Quota.Gate` holds dispatch on the window's
      utilization rule; the gate makes that decision through this function.
    * `:approaching` — within `#{@approaching_margin}` (ten percentage points of the window)
      of the ceiling: `utilization >= ceiling - #{@approaching_margin}`. On a paced ceiling
      that is the last tenth of a window's worth of on-pace burn before the
      gate would hold — 30 minutes of a 5h window, about 17 hours of a 7d one.
    * `:sampling` — neither of the above, and either less than `#{@sampling_floor}` of
      the window has elapsed (15 minutes of 5h, ~8.4 hours of 7d) or less
      than `#{@sampling_floor}` of it is used. Too early or too little to call a pace.
    * `:ok` — none of the above, including no utilization reading at all.

  `:holding` and `:approaching` outrank `:sampling`: a paced floor makes the
  ceiling meaningful from the first second, so the gate holds however early a
  window is, and the verdict must say so.

  ## The ceiling

  The thresholds argument is `%{sides: [side], default: ceiling}` — the
  gate's `min(account, workspace)` composition, already resolved into one
  entry per side that configured anything:

    * `{:paced, floor, flat_fallback, curve}` — the paced line for `curve`
      (below), where `elapsed` is the elapsed fraction of the window; without
      a known `elapsed` (no window length, no reset) it falls back to the
      side's own flat ceiling, or drops out when it has none. The 3-tuple
      `{:paced, floor, flat_fallback}` is the `:plateau` curve.
    * `{:paced_exempt, floor, flat_fallback, cap, curve}` — a `:paced` side
      for an exempt dispatch (bd-6bxv7h, design §4.2): `max(line, cap)`, where
      `line` is the paced line and `cap` is `min(exempt_cap, flat)` already
      resolved by the gate. It only ever raises the paced line, never lowers
      it, and reports mode `:exempt` only when it actually lifted the line.
      Without a known `elapsed` it falls back exactly like `:paced`. The
      4-tuple `{:paced_exempt, floor, flat_fallback, cap}` is the `:plateau`
      curve.
    * `{:flat, ceiling}` — a fixed ceiling.

  ## The pace curve

  Two curves turn `floor` and `elapsed` into the paced line (operator ruling
  2026-11-02; the account's / workspace's `pace_curve` setting picks one):

    * `:plateau` (the default, `"plateau"`) — `max(floor, elapsed)`: flat at
      the floor until `elapsed` overtakes it, then equal to `elapsed`. A pool
      that reaches the floor early waits, and the line only reaches 1.0 at the
      reset.
    * `:ramp` (`"ramp"`) — `floor + (1 - floor) * elapsed`: a straight line
      from `floor` at the reset to 1.0 at the next one, with no plateau. At
      floor 0.10 a 7d window reads 23% at one day, 55% at 3.5 days and 74% at
      five days; a 5h window 28% at one hour, 55% at 2.5h, 82% at four.

  With `floor == 0` the two are the same line (`elapsed`), which is why the
  dollar spend side is unaffected by the choice. `approaching_margin/0` and
  the sampling floor are fractions of the *window*, not of the line, so they
  read the same on either curve; on a ramp the line starts at the floor, so a
  window's first stretch is `:approaching` for any utilization within a tenth
  of that floor.

  Each side is turned into a number for *now* and the smallest wins, ties
  going to the earlier side; with no side left, `default` applies. See
  "Threshold modes" in `Arbiter.Quota.Gate` for where each number comes from.
  """

  @type verdict :: :ok | :approaching | :holding | :sampling
  @type curve :: :plateau | :ramp
  @type side ::
          {:paced, float(), float() | nil}
          | {:paced, float(), float() | nil, curve()}
          | {:paced_exempt, float(), float() | nil, float()}
          | {:paced_exempt, float(), float() | nil, float(), curve()}
          | {:flat, float()}
  @type thresholds :: %{sides: [side()], default: float()}

  @typedoc """
  `ceiling` is the threshold in force at the moment of the check, `mode` says
  whether pacing produced it, and `elapsed` is the elapsed fraction of the
  window (`nil` when unknown).
  """
  @type t :: %{
          verdict: verdict(),
          ceiling: float(),
          mode: :paced | :flat | :exempt,
          elapsed: float() | nil
        }

  @doc "How far below the ceiling `:approaching` starts, as a fraction of the window."
  @spec approaching_margin() :: float()
  def approaching_margin, do: @approaching_margin

  @doc """
  The pace verdict for one window. `elapsed_seconds` is how far into the window
  the check is (see `elapsed_seconds/3`); either it or `window_seconds` being
  `nil` means the elapsed fraction is unknown and paced sides fall back.
  """
  @spec evaluate(number() | nil, number() | nil, pos_integer() | nil, thresholds()) :: t()
  def evaluate(utilization, elapsed_seconds, window_seconds, %{sides: sides, default: default}) do
    elapsed = elapsed_fraction(elapsed_seconds, window_seconds)

    {ceiling, mode} =
      sides
      |> Enum.map(&side_ceiling(&1, elapsed))
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(fn {c, _mode} -> c end, fn -> {default, :flat} end)

    %{
      verdict: verdict(utilization, ceiling, elapsed),
      ceiling: ceiling,
      mode: mode,
      elapsed: elapsed
    }
  end

  @doc """
  Seconds elapsed in a window of `window_seconds` that resets at `reset_at`,
  as of `now`. `nil` when either is unknown. Unclamped — `evaluate/4` clamps.
  """
  @spec elapsed_seconds(DateTime.t() | nil, pos_integer() | nil, DateTime.t()) :: float() | nil
  def elapsed_seconds(%DateTime{} = reset_at, window_seconds, %DateTime{} = now)
      when is_integer(window_seconds) do
    window_seconds - DateTime.diff(reset_at, now, :millisecond) / 1000
  end

  def elapsed_seconds(_reset_at, _window_seconds, _now), do: nil

  @doc """
  How far into a window `elapsed` seconds (out of `window`) is, clamped to
  `0.0..1.0`, or `nil` when either input is unknown — public so a caller that
  computes its own `elapsed_seconds/3` (`Arbiter.Quota.Gate.binding_side/3`,
  bd-c7ll4t) can turn it into the same fraction `evaluate/4` uses internally,
  rather than re-deriving the clamp.
  """
  @spec elapsed_fraction(number() | nil, pos_integer() | nil) :: float() | nil
  def elapsed_fraction(elapsed, window) when is_number(elapsed) and is_integer(window) do
    (elapsed / window) |> max(0.0) |> min(1.0)
  end

  def elapsed_fraction(_elapsed, _window), do: nil

  @doc """
  The ceiling (and its mode) a single `side/0` resolves to right now, given
  the window's `elapsed` fraction (`nil` when unknown). Public so
  `Arbiter.Quota.Gate.binding_side/3` (bd-c7ll4t) can rank each side of
  `min(account, workspace)` the same way `evaluate/4` picks the smallest —
  there is deliberately only one place a paced side turns into a number.
  """
  @spec side_ceiling(side(), float() | nil) :: {float(), :paced | :flat | :exempt} | nil
  def side_ceiling({:paced, floor, flat}, elapsed),
    do: side_ceiling({:paced, floor, flat, :plateau}, elapsed)

  def side_ceiling({:paced, floor, _flat, curve}, elapsed) when is_float(elapsed),
    do: {line(curve, floor, elapsed), :paced}

  def side_ceiling({:paced_exempt, floor, flat, cap}, elapsed),
    do: side_ceiling({:paced_exempt, floor, flat, cap, :plateau}, elapsed)

  def side_ceiling({:paced_exempt, floor, _flat, cap, curve}, elapsed) when is_float(elapsed) do
    line = line(curve, floor, elapsed)
    if cap > line, do: {cap, :exempt}, else: {line, :paced}
  end

  def side_ceiling({:paced_exempt, floor, flat, _cap, curve}, elapsed),
    do: side_ceiling({:paced, floor, flat, curve}, elapsed)

  def side_ceiling({:paced, _floor, nil, _curve}, _elapsed), do: nil
  def side_ceiling({:paced, _floor, flat, _curve}, _elapsed), do: {flat, :flat}
  def side_ceiling({:flat, ceiling}, _elapsed), do: {ceiling, :flat}

  @doc """
  The paced line itself, for `floor` and an `elapsed` fraction in `0.0..1.0`,
  under `curve` (see "The pace curve" in the moduledoc). The one place the two
  formulas live; `side_ceiling/2` and any caller that draws or reports the line
  (the quota chart, `Arbiter.Quota.Budget`) go through it.
  """
  @spec line(curve(), float(), float()) :: float()
  def line(:ramp, floor, elapsed), do: floor + (1.0 - floor) * elapsed
  def line(_plateau, floor, elapsed), do: max(floor, elapsed)

  defp verdict(u, ceiling, elapsed) when is_number(u) do
    cond do
      u >= ceiling -> :holding
      u >= ceiling - @approaching_margin -> :approaching
      sampling?(u, elapsed) -> :sampling
      true -> :ok
    end
  end

  defp verdict(_u, _ceiling, _elapsed), do: :ok

  defp sampling?(u, elapsed),
    do: u < @sampling_floor or (is_float(elapsed) and elapsed < @sampling_floor)
end
