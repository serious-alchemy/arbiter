defmodule Arbiter.Usage.EstimateCache do
  @moduledoc """
  Memoizes `Arbiter.Usage.Estimate.sample/1` — the 60-day ledger scan and
  issue-linking query that empirical cost estimates and over-budget checks
  read from — so `Board.Snapshot.load/1` and `Arbiter.Board.Autopilot` don't
  pay for a fresh 60-day sample on every board refresh and dispatch cycle.

  A 60-second TTL covers repeat mounts, board refreshes, and autopilot passes
  with zero queries; `invalidate/0` (called from `Arbiter.Usage.Event`'s
  `:create` and `:refresh_snapshot` actions) drops it early the moment new
  usage lands, so a worker's session finishing immediately refreshes the
  sample on the next pass.

  Backed by a `:public` ETS table owned by this GenServer with read_concurrency: true.
  The computation itself runs in the calling process, preserving any DB sandbox
  connection in tests.

  `config :arbiter, #{inspect(__MODULE__)}, enabled: false` makes `fetch/2`
  compute every time. The test suite sets it: a memo shared by the whole VM
  hands one test's sample to the next, and a sandbox rollback deletes the rows
  without invalidating it, so an "empty ledger" test read the previous test's
  rolled-back fixtures (bd-jw7cb0).
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Fetch the sample for `opts`, computing via `compute` on miss or after #{@ttl_ms}ms TTL.
  """
  @spec fetch(keyword(), (-> any())) :: any()
  def fetch(opts, compute) do
    if enabled?(), do: memoized(opts, compute), else: compute.()
  end

  defp memoized(opts, compute) do
    key = cache_key(opts)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, inserted_at}] when now - inserted_at < @ttl_ms ->
        value

      _ ->
        value = compute.()
        :ets.insert(@table, {key, value, now})
        value
    end
  rescue
    ArgumentError -> compute.()
  end

  @doc """
  Drops every cached sample. Safe to call before the table exists.
  """
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp enabled? do
    :arbiter |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)
  end

  defp cache_key(opts) do
    {
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :window_days),
      Keyword.get(opts, :now)
    }
  end
end
