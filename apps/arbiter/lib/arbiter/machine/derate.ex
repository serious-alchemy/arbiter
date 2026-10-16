defmodule Arbiter.Machine.Derate do
  @moduledoc """
  A machine derates itself: under thermal or memory pressure it stops offering
  new slots to the scheduler, and lifts that once the pressure has stayed gone.
  The pure rule behind `Arbiter.Machine.Monitor` (bd-6w7usy); the thresholds
  are `Arbiter.Machine.Derate.Config`, the readings `Arbiter.Machine.Sensors`.

  ## Levels

    * `:none` — offer the configured cap.
    * `:soft` — **no new slots**: `offered = min(cap, live)`. Running workers
      are never stopped; a slot that frees is not re-offered.
      Entered at `thermal_soft_c`, a PSI `some avg10` at `psi_some_avg10`, or
      `MemAvailable` under `mem_floor_bytes`.
    * `:hard` — as `:soft`, and also hold new resumes and fix passes
      (`hold_new_work?/1`), which a soft derate lets through on the primary
      because they are follow-ups of work already in flight. Entered at
      `thermal_hard_c`. Memory pressure alone is never hard.

  ## Hysteresis

  Hard entry is immediate: one sample at `thermal_hard_c` is the runaway stop
  and is never smoothed. Soft entry is smoothed, because AMD `Tctl` is an
  instantaneous hotspot reading and one spike would otherwise bench the node
  for `recover_s`: the thermal reading is the median of the last
  `thermal_entry_samples` samples (default 3, ~30 s), and soft needs a full
  window whose median is at or above `thermal_soft_c`. The release test below
  reads the same median, so a single cool sample cannot start the recovery
  clock either. An unknown reading clears the window. PSI and memory are
  already averaged or slow-moving and are used as sampled. Lifting needs the readings below
  the *release* thresholds (`threshold - delta`) continuously for `recover_s`;
  a reading back inside the band `release..threshold` holds the level and
  restarts the clock. A hard derate steps down to soft (or none) on the same
  rule, one window per step. A reading that is unknown counts as clear: unknown
  never derates.

  `evaluate/4` is `(input, config, prior, now_ms) -> {result, state}`; keep
  `state` and feed it back in.
  """

  alias Arbiter.Machine.Derate.Config

  @type level :: :none | :soft | :hard
  @type reason ::
          nil
          | {:thermal, float()}
          | {:psi, float()}
          | {:mem_available, non_neg_integer()}
  @type state :: %{
          level: level(),
          reason: reason(),
          recover_since: integer() | nil,
          temps: [number()]
        }
  @type input :: %{
          required(:cap) => non_neg_integer(),
          required(:live) => non_neg_integer(),
          required(:readings) => map()
        }
  @type result :: %{
          level: level(),
          offered: non_neg_integer(),
          reason: reason(),
          reason_text: String.t() | nil
        }

  @rank %{none: 0, soft: 1, hard: 2}
  @gib 1024 * 1024 * 1024

  @doc "The state of a machine that has never been derated."
  @spec initial() :: state()
  def initial, do: %{level: :none, reason: nil, recover_since: nil, temps: []}

  @doc "See the moduledoc. `now_ms` is any monotonic millisecond clock."
  @spec evaluate(input(), Config.t(), state(), integer()) :: {result(), state()}
  def evaluate(%{cap: cap, live: live, readings: readings}, %Config{} = config, prior, now_ms) do
    state = if config.enabled, do: step(readings, config, prior, now_ms), else: initial()
    {result(cap, live, state), state}
  end

  @doc """
  What a machine offers at `level`: the cap, or with any derate no more than it
  has running (and never more than the cap). The primary uses this on the
  level a node reports, against the node's effective cap.
  """
  @spec apply_level(non_neg_integer(), non_neg_integer(), level()) :: non_neg_integer()
  def apply_level(cap, _live, :none), do: cap
  def apply_level(cap, live, level) when level in [:soft, :hard], do: min(cap, live)

  @doc "Whether a derate at `level` also holds new resumes and fix passes."
  @spec hold_new_work?(level()) :: boolean()
  def hold_new_work?(:hard), do: true
  def hold_new_work?(_level), do: false

  @doc "A level named on the wire; anything unrecognised is `:none` (unknown never derates)."
  @spec parse_level(term()) :: level()
  def parse_level("soft"), do: :soft
  def parse_level("hard"), do: :hard
  def parse_level(_), do: :none

  @doc "A human phrase for a reason, e.g. `thermal 96 °C`."
  @spec describe(reason()) :: String.t() | nil
  def describe(nil), do: nil
  def describe({:thermal, c}), do: "thermal #{round(c)} °C"
  def describe({:psi, v}), do: "memory pressure (PSI some avg10 #{Float.round(v * 1.0, 1)}%)"

  def describe({:mem_available, bytes}),
    do: "low memory (MemAvailable #{Float.round(bytes / @gib, 1)} GiB)"

  # ---- the rule --------------------------------------------------------------

  defp result(cap, live, %{level: level, reason: reason}) do
    %{
      level: level,
      offered: apply_level(cap, live, level),
      reason: reason,
      reason_text: describe(reason)
    }
  end

  defp step(readings, config, prior, now_ms) do
    temps = window(readings, config, prior)
    readings = Map.put(readings, :temps, temps)
    {enter_level, enter_reason} = assess(readings, config, :enter)
    {release_level, release_reason} = assess(readings, config, :release)
    held = prior.level
    recover_ms = config.recover_s * 1000

    cond do
      @rank[enter_level] > @rank[held] ->
        %{level: enter_level, reason: enter_reason, recover_since: nil, temps: temps}

      held == :none ->
        %{initial() | temps: temps}

      @rank[release_level] < @rank[held] ->
        since = prior.recover_since || now_ms

        if now_ms - since >= recover_ms do
          if release_level == :none,
            do: %{initial() | temps: temps},
            else: %{
              level: release_level,
              reason: release_reason,
              recover_since: now_ms,
              temps: temps
            }
        else
          %{prior | recover_since: since, temps: temps}
        end

      true ->
        # Still inside the hysteresis band of the level held: hold, restart the clock.
        %{level: held, reason: release_reason || prior.reason, recover_since: nil, temps: temps}
    end
  end

  # The last `thermal_entry_samples` temperatures, newest first; an unknown
  # reading empties it.
  defp window(%{temp_c: temp}, config, prior) when is_number(temp) do
    Enum.take([temp | Map.get(prior, :temps, [])], config.thermal_entry_samples)
  end

  defp window(_readings, _config, _prior), do: []

  defp median(temps) do
    sorted = Enum.sort(temps)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  # The level the readings call for against the enter thresholds, or against
  # the release thresholds (`threshold - delta`) when deciding to lift.
  defp assess(readings, config, mode) do
    [thermal(readings, config, mode), memory(readings, config, mode)]
    |> Enum.max_by(fn {level, _} -> @rank[level] end)
  end

  # Entering: hard on the raw sample (immediate), soft on the median of a full
  # window. Releasing: both on the median of what the window holds.
  defp thermal(%{temp_c: temp, temps: temps}, config, :enter) when is_number(temp) do
    smoothed = if length(temps) >= config.thermal_entry_samples, do: median(temps)

    cond do
      temp >= config.thermal_hard_c -> {:hard, {:thermal, temp}}
      is_number(smoothed) and smoothed >= config.thermal_soft_c -> {:soft, {:thermal, smoothed}}
      true -> {:none, nil}
    end
  end

  defp thermal(%{temps: [_ | _] = temps}, config, :release) do
    smoothed = median(temps)

    cond do
      smoothed >= config.thermal_hard_c - config.thermal_delta_c -> {:hard, {:thermal, smoothed}}
      smoothed >= config.thermal_soft_c - config.thermal_delta_c -> {:soft, {:thermal, smoothed}}
      true -> {:none, nil}
    end
  end

  defp thermal(_readings, _config, _mode), do: {:none, nil}

  defp memory(readings, config, mode) do
    psi_margin = if mode == :enter, do: 0.0, else: config.psi_delta
    mem_margin = if mode == :enter, do: 0, else: config.mem_delta_bytes
    psi = readings |> Map.get(:psi) |> psi_some()
    mem = Map.get(readings, :mem_available)

    cond do
      is_number(psi) and psi >= config.psi_some_avg10 - psi_margin ->
        {:soft, {:psi, psi}}

      is_number(mem) and mem < config.mem_floor_bytes + mem_margin ->
        {:soft, {:mem_available, mem}}

      true ->
        {:none, nil}
    end
  end

  defp psi_some(%{some_avg10: v}), do: v
  defp psi_some(_), do: nil
end
