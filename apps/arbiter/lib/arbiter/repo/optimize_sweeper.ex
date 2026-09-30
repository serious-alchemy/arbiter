defmodule Arbiter.Repo.OptimizeSweeper do
  @moduledoc """
  Periodically executes `PRAGMA optimize` on all configured SQLite repos (bd-2zjtca / bd-91rxi7).

  ## Configuration

  Via `config :arbiter, :db_optimize`:

    * `:enabled`     — master switch (default `true`; `false` in test, where tests
                       call `sweep_now/1` or send `:sweep` directly).
    * `:interval_ms` — periodic schedule cadence (default 24 hours: 86_400_000 ms).

  ## Primary instance gating

  Only runs on the primary instance (`Arbiter.SingleInstance.primary?/0`), so
  secondary/duplicate nodes do not run optimizations concurrently.
  """

  use GenServer

  require Logger

  alias Arbiter.Boot.Optimize
  alias Arbiter.SingleInstance

  # Default interval: 24 hours (SQLite docs recommend PRAGMA optimize once per day or upon closing)
  @default_interval_ms 24 * 60 * 60_000

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Child spec for the supervision tree."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc "Run one optimization pass now on the server."
  @spec sweep_now(GenServer.server()) :: :ok
  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep_now, 60_000)
  end

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms),
      primary?: Keyword.get(opts, :primary?, &SingleInstance.primary?/0)
    }

    if state.enabled, do: schedule(state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = run_sweep(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {:reply, run_sweep(state), state}
  end

  defp run_sweep(state) do
    if state.primary?.() do
      Optimize.run()
    else
      Logger.info("Repo.OptimizeSweeper: not the primary instance — skipping PRAGMA optimize")
      :ok
    end
  rescue
    e ->
      Logger.warning("Repo.OptimizeSweeper: sweep failed: #{Exception.message(e)}")
      :ok
  end

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case Keyword.get(Application.get_env(:arbiter, :db_optimize, []), key) do
      nil -> default
      val -> val
    end
  end
end
