defmodule Arbiter.Board.CiBackpressure.Refresher do
  @moduledoc """
  The timer behind the CI backpressure gate (`Arbiter.Board.CiBackpressure`).

  The gate used to read the forge's CI queue only when a Ready card of a gated
  repo asked. After a quiet spell its cached reading was stale (or missing), the
  cache served that while a background poll ran, and the first card promoted was
  judged on old data or on nothing — and dispatched. This process polls every
  gated repo on a timer whether or not a card is queued, so the reading a
  promote finds is at most one interval old, and a hold or its release is logged
  when the queue changes rather than when a card next asks.

  `config :arbiter, :ci_backpressure_refresher` — `:enabled` (default `true`),
  `:interval_ms` (default #{div(45_000, 1000)}s, under the cache's 60s freshness so a reading never
  expires between ticks), `:refresh_opts` (the options `CiBackpressure.refresh/2`
  takes; tests).
  """
  use GenServer

  require Logger

  alias Arbiter.Board.CiBackpressure
  alias Arbiter.Tasks.Workspace

  @interval_ms 45_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:arbiter, :ci_backpressure_refresher, [])
    opts = Keyword.merge(config, opts)

    if Keyword.get(opts, :enabled, true) do
      interval = Keyword.get(opts, :interval_ms, @interval_ms)
      state = %{interval: interval, refresh_opts: Keyword.get(opts, :refresh_opts, [])}
      # An immediate first tick warms the cache after a boot, so the very first
      # card does not wait on a poll either.
      if interval != :never, do: send(self(), :tick)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:tick, state) do
    refresh(state.refresh_opts)
    if is_integer(state.interval), do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Never lets a database or forge failure kill the timer.
  defp refresh(opts) do
    case Ash.read(Workspace) do
      {:ok, workspaces} ->
        CiBackpressure.refresh(workspaces, opts)

      {:error, reason} ->
        Logger.warning("CiBackpressure.Refresher: no workspaces: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("CiBackpressure.Refresher: refresh raised: #{Exception.message(e)}")
  catch
    kind, reason ->
      Logger.warning("CiBackpressure.Refresher: refresh failed: #{inspect({kind, reason})}")
  end
end
