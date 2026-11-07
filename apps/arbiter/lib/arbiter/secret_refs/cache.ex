defmodule Arbiter.SecretRefs.Cache do
  @moduledoc """
  Owner of the in-memory ETS table behind `Arbiter.SecretRefs.External`'s TTL cache.

  The table lives only in this VM's memory — resolved values are never written
  to disk or to a log. It is started first in the supervision tree so the
  Vault's own boot-time lookups are cached too. When the table does not exist
  (a release `eval`, `runtime.exs`, a CLI process) callers simply fetch without
  caching.
  """

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True when the cache table exists in this VM."
  @spec running?() :: boolean()
  def running?, do: :ets.whereis(@table) != :undefined

  @doc "Look up `key`: `{:fresh, value}`, `{:stale, value}` (past its TTL) or `:miss`."
  @spec get(term()) :: {:fresh, term()} | {:stale, term()} | :miss
  def get(key) do
    case running?() && :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at,
          do: {:fresh, value},
          else: {:stale, value}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Store `value` under `key` for `ttl_ms` milliseconds (a no-op when the cache is not running)."
  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_ms) do
    if running?() do
      :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl_ms})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The values of every cached entry whose key satisfies `key_filter`."
  @spec values((term() -> boolean())) :: [term()]
  def values(key_filter) do
    if running?() do
      @table
      |> :ets.tab2list()
      |> Enum.flat_map(fn {key, value, _exp} -> if key_filter.(key), do: [value], else: [] end)
    else
      []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Drop everything (tests)."
  @spec clear() :: :ok
  def clear do
    if running?(), do: :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
