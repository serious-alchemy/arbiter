defmodule Arbiter.Machine.Monitor do
  @moduledoc """
  Samples this machine every ~10 s (`Arbiter.Machine.Sensors`), smooths the
  readings with an EWMA (a single spike does not flap capacity) and runs the
  derate rule (`Arbiter.Machine.Derate`) with its hysteresis state. One runs on
  the primary (for the primary's own slots) and one in each node agent (whose
  heartbeat reports the result).

  The latest result is kept in a protected ETS table named after the process,
  so the hot paths (`LocalCapacity.admit/3`, the board's capacity read) never
  call into the GenServer. A machine whose monitor is not running — or has not
  sampled yet — reads as `nil` / level `:none`: unknown never derates.

  ## Options

    * `:name` — process and table name (default `#{inspect(__MODULE__)}`)
    * `:config_fun` — `() -> Derate.Config.t()`, read every sample so a settings
      change applies without a restart
    * `:cap_fun`, `:live_fun` — `() -> non_neg_integer()`, for the `offered`
      figure in the snapshot (the level itself does not depend on them)
    * `:interval_ms` — sample period (default 10 000); `:manual` disables the
      timer (tests drive `sample/1`)
    * `:alpha` — EWMA weight of the newest sample (default 0.4)
    * `:sensor_fun`, `:clock` — seams for tests (`Sensors.read/0`, monotonic ms)
    * `:on_transition` — `(%{from:, to:, snapshot:}) -> any`, called when the
      level changes; failures are logged, never raised
  """

  use GenServer

  alias Arbiter.Machine.{Derate, Sensors}
  alias Arbiter.Machine.Derate.Config

  require Logger

  @default_interval_ms 10_000
  @default_alpha 0.4

  @type snapshot :: %{
          temp_c: float() | nil,
          psi: Sensors.psi() | nil,
          mem_available: non_neg_integer() | nil,
          level: Derate.level(),
          offered: non_neg_integer(),
          reason: Derate.reason(),
          reason_text: String.t() | nil,
          sampled_at: DateTime.t()
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The latest snapshot, or `nil` when nothing has been sampled."
  @spec current(atom()) :: snapshot() | nil
  def current(name \\ __MODULE__) do
    case :ets.lookup(name, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "The current derate level (`:none` when unknown)."
  @spec level(atom()) :: Derate.level()
  def level(name \\ __MODULE__) do
    case current(name) do
      %{level: level} -> level
      nil -> :none
    end
  end

  @doc "Take a sample now and return the resulting snapshot."
  @spec sample(atom()) :: snapshot()
  def sample(name \\ __MODULE__), do: GenServer.call(name, :sample)

  @doc """
  EWMA of two readings maps: the first sample is taken as is, a reading that is
  unknown now is unknown (a vanished sensor is not carried forward), and each
  PSI field smooths on its own.
  """
  @spec smooth(Sensors.readings() | nil, Sensors.readings(), float()) :: Sensors.readings()
  def smooth(nil, new, _alpha), do: new

  def smooth(prev, new, alpha) do
    %{
      temp_c: ewma(prev.temp_c, new.temp_c, alpha),
      psi: smooth_psi(prev.psi, new.psi, alpha),
      mem_available: ewma(prev.mem_available, new.mem_available, alpha)
    }
  end

  defp smooth_psi(prev, new, alpha) when is_map(prev) and is_map(new) do
    Map.new(new, fn {key, value} -> {key, ewma(Map.get(prev, key), value, alpha)} end)
  end

  defp smooth_psi(_prev, new, _alpha), do: new

  defp ewma(_prev, nil, _alpha), do: nil
  defp ewma(nil, new, _alpha), do: new

  defp ewma(prev, new, alpha) when is_integer(prev) and is_integer(new),
    do: round(prev + alpha * (new - prev))

  defp ewma(prev, new, alpha), do: prev + alpha * (new - prev)

  # ---- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    :ets.new(name, [:named_table, :protected, read_concurrency: true])

    state = %{
      name: name,
      config_fun: Keyword.get(opts, :config_fun, fn -> %Config{} end),
      cap_fun: Keyword.get(opts, :cap_fun, fn -> 0 end),
      live_fun: Keyword.get(opts, :live_fun, fn -> 0 end),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      alpha: Keyword.get(opts, :alpha, @default_alpha),
      sensor_fun: Keyword.get(opts, :sensor_fun, &Sensors.read/0),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      on_transition: Keyword.get(opts, :on_transition),
      smoothed: nil,
      derate: Derate.initial()
    }

    {:ok, state, {:continue, :first_sample}}
  end

  @impl true
  def handle_continue(:first_sample, state) do
    {_snapshot, state} = take_sample(state)
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_call(:sample, _from, state) do
    {snapshot, state} = take_sample(state)
    {:reply, snapshot, state}
  end

  @impl true
  def handle_info(:sample, state) do
    {_snapshot, state} = take_sample(state)
    {:noreply, schedule(state)}
  end

  defp schedule(%{interval_ms: :manual} = state), do: state

  defp schedule(%{interval_ms: ms} = state) do
    Process.send_after(self(), :sample, ms)
    state
  end

  defp take_sample(state) do
    smoothed = smooth(state.smoothed, safe_read(state.sensor_fun), state.alpha)
    config = safe(state.config_fun, %Config{})

    input = %{
      cap: safe(state.cap_fun, 0),
      live: safe(state.live_fun, 0),
      readings: smoothed
    }

    {result, derate} = Derate.evaluate(input, config, state.derate, state.clock.())

    snapshot =
      Map.merge(smoothed, %{
        level: result.level,
        offered: result.offered,
        reason: result.reason,
        reason_text: result.reason_text,
        sampled_at: DateTime.utc_now()
      })

    :ets.insert(state.name, {:snapshot, snapshot})
    announce(state, state.derate.level, result.level, snapshot)
    {snapshot, %{state | smoothed: smoothed, derate: derate}}
  end

  defp announce(_state, level, level, _snapshot), do: :ok
  defp announce(%{on_transition: nil}, _from, _to, _snapshot), do: :ok

  defp announce(%{on_transition: fun}, from, to, snapshot) do
    fun.(%{from: from, to: to, snapshot: snapshot})
  rescue
    e -> Logger.warning("Machine.Monitor: transition hook raised: #{Exception.message(e)}")
  catch
    :exit, _ -> :ok
  end

  defp safe_read(fun) do
    fun.()
  rescue
    _ -> %{temp_c: nil, psi: nil, mem_available: nil}
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
