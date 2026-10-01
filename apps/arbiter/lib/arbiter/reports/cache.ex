defmodule Arbiter.Reports.Cache do
  @moduledoc """
  Short-TTL memo for `/reports` results, keyed by `{report, filters}`
  (bd-an8t0e; design `docs/design/reports-design-v2.md` §6).

  Reports tolerate staleness, so there is no PubSub invalidation: an entry
  lives for #{div(60_000, 1000)}s and `fetch/3` returns the time the value was
  computed so the page can show its "as of". The computation runs in the
  calling process, preserving any DB sandbox connection in tests.

  `config :arbiter, #{inspect(__MODULE__)}, enabled: false` computes on every
  call (the test suite sets it, for the reason `Arbiter.Usage.EstimateCache`
  documents).
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Returns `{value, computed_at}`, computing via `compute` on a miss or expired entry."
  @spec fetch(term(), (-> any())) :: {any(), DateTime.t()}
  def fetch(key, compute) do
    if enabled?(), do: memoized(key, compute), else: {compute.(), DateTime.utc_now()}
  end

  defp memoized(key, compute) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, at, inserted}] when now - inserted < @ttl_ms ->
        {value, at}

      _ ->
        value = compute.()
        at = DateTime.utc_now()
        :ets.insert(@table, {key, value, at, now})
        {value, at}
    end
  rescue
    ArgumentError -> {compute.(), DateTime.utc_now()}
  end

  @doc "Drops every cached result. Safe to call before the table exists."
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp enabled?,
    do: :arbiter |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)
end
