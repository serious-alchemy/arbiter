defmodule Arbiter.Worker.CliFetcher.Scheduler do
  @moduledoc """
  The periodic CLI fetch job (SI1a, OD13): once a day, and on demand
  (`run_now/1`), it

    1. checks upstream for the newest stable version of each CLI and bumps the
       pins (`Arbiter.Worker.CliFetcher.Bump`: held by `worker.cli_set.hold`,
       skipped per CLI by `worker.cli.manual`), then
    2. makes sure every pinned version, and the running release's `arb`, is in
       the verified cache (`Arbiter.Worker.CliFetcher.ensure_pinned/1`), so a pin
       an operator set by hand, or a wiped cache, is fetched here and never on a
       dispatch.

  The work runs in a task so `status/1` (the doctor's read) stays answerable
  while a 160 MB download is in flight. A failure is recorded in the report and
  logged; it never crashes the process.

  ## Configuration

  `config :arbiter, :cli_fetcher` (prod enables it; dev and test leave it off):

    * `:enabled` — master switch. `ARBITER_CLI_FETCHER=0` also disables it, for
      air-gapped installs.
    * `:interval_ms` — default 24 hours.
    * `:initial_delay_ms` — delay before the first full run (default 5 minutes).
    * `:fill_delay_ms` — delay before the boot fill (default 10 seconds): the
      cache fill alone, with no upstream check or bump, so workers can spawn
      right after a start or an upgrade instead of waiting out the first run.
      A pinned version already cached costs no network. `:infinity` skips it.

  Where the scheduler is off, `mix arbiter.fetch_clis` (a release:
  `Arbiter.Release.fetch_clis/0`) fills the cache by hand.
  """

  use GenServer

  alias Arbiter.Worker.CliFetcher
  alias Arbiter.Worker.CliFetcher.Bump

  require Logger

  @default_interval_ms :timer.hours(24)
  @default_initial_delay_ms :timer.minutes(5)
  @default_fill_delay_ms :timer.seconds(10)
  @run_timeout_ms :timer.minutes(30)

  @empty %{enabled: false, checked_at: nil, latest: %{}, bump: %{}, ensured: %{}}

  def start_link(opts \\ []) do
    if enabled?(opts) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
    else
      :ignore
    end
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Run the bump and the cache fill now; returns the report once it finishes."
  @spec run_now(GenServer.server()) :: map()
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now, @run_timeout_ms)

  @doc """
  The last report: `%{enabled, checked_at, latest, bump, ensured}`. A scheduler
  that is not running reads as `enabled: false`.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> @empty
  end

  @impl true
  def init(opts) do
    state = %{
      report: %{@empty | enabled: true},
      task: nil,
      waiters: [],
      interval_ms: Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms)),
      fetch_opts: Keyword.get(opts, :fetch_opts, [])
    }

    case Keyword.get(
           opts,
           :initial_delay_ms,
           config(:initial_delay_ms, @default_initial_delay_ms)
         ) do
      :infinity -> :ok
      ms -> Process.send_after(self(), :tick, ms)
    end

    case Keyword.get(opts, :fill_delay_ms, config(:fill_delay_ms, @default_fill_delay_ms)) do
      :infinity -> :ok
      ms -> Process.send_after(self(), :fill, ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.report, state}

  def handle_call(:run_now, from, state),
    do: {:noreply, state |> start_run() |> Map.update!(:waiters, &[from | &1])}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, start_run(state)}
  end

  def handle_info(:fill, state), do: {:noreply, start_run(state, :fill)}

  # The boot fill reports only what it cached; it is not the daily job, so it
  # leaves `checked_at` and the upstream view alone.
  def handle_info({ref, {:fill, ensured}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | report: %{state.report | ensured: ensured}, task: nil}}
  end

  def handle_info({ref, report}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Enum.each(state.waiters, &GenServer.reply(&1, report))
    {:noreply, %{state | report: report, task: nil, waiters: []}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("CliFetcher.Scheduler: run exited: #{inspect(reason)}")
    report = %{state.report | checked_at: DateTime.utc_now(), bump: %{}, ensured: %{}}
    Enum.each(state.waiters, &GenServer.reply(&1, report))
    {:noreply, %{state | report: report, task: nil, waiters: []}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_run(state, mode \\ :full)

  defp start_run(%{task: nil} = state, mode) do
    fetch_opts = state.fetch_opts
    %{state | task: Task.async(fn -> run(fetch_opts, mode) end)}
  end

  defp start_run(state, _mode), do: state

  # `:full` bumps the pins and fills the cache; `:fill` (the boot run) only fills it.
  defp run(fetch_opts, mode) do
    checks = if mode == :full, do: Bump.check(fetch_opts), else: %{}
    ensured = ensure(fetch_opts)

    case mode do
      :fill ->
        {:fill, ensured}

      :full ->
        %{
          enabled: true,
          checked_at: DateTime.utc_now(),
          latest: Map.new(checks, fn {name, %{latest: l}} -> {name, latest_version(l)} end),
          bump: Map.new(checks, fn {name, %{action: a}} -> {name, a} end),
          ensured: ensured
        }
    end
  rescue
    e ->
      Logger.warning("CliFetcher.Scheduler: run raised: #{Exception.message(e)}")
      %{@empty | enabled: true, checked_at: DateTime.utc_now()}
  end

  defp ensure(fetch_opts) do
    ensured =
      Map.new(CliFetcher.ensure_pinned(fetch_opts), fn
        {name, {:ok, _}} -> {name, :ok}
        {name, other} -> {name, other}
      end)

    Enum.each(ensured, fn
      {name, {:error, reason}} ->
        Logger.warning("CliFetcher: #{name} not cached: #{inspect(reason)}")

      _ ->
        :ok
    end)

    ensured
  end

  defp latest_version({:ok, version}), do: version
  defp latest_version(_), do: nil

  defp enabled?(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, flag} -> flag == true
      :error -> config(:enabled, false) == true and System.get_env("ARBITER_CLI_FETCHER") != "0"
    end
  end

  defp config(key, default),
    do: Application.get_env(:arbiter, :cli_fetcher, []) |> Keyword.get(key, default)
end
