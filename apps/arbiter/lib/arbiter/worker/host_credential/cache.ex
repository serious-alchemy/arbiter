defmodule Arbiter.Worker.HostCredential.Cache do
  @moduledoc """
  Short-lived memo of the host's minted GitHub App installation tokens
  (`Arbiter.Worker.HostCredential`). A Watchdog polls a PR every few seconds and
  each poll re-seeds the merger adapter; minting per poll would be a JWT signature
  and a GitHub round trip each time. An installation token lives an hour, so one
  is reused for #{div(30 * 60_000, 60_000)} minutes, then minted afresh.

  Only successes are cached: a failed mint is retried by the next caller. The
  table is in memory only, so a restart mints again.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 30 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "The cached `{:ok, value}` for `key`, or `compute.()`, cached when it is `{:ok, _}`."
  @spec fetch(term(), (-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def fetch(key, compute) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, inserted}] when now - inserted < @ttl_ms ->
        {:ok, value}

      _ ->
        with {:ok, value} <- compute.() do
          :ets.insert(@table, {key, value, now})
          {:ok, value}
        end
    end
  rescue
    ArgumentError -> compute.()
  end

  @doc "Drops every cached token. Safe to call before the table exists."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
