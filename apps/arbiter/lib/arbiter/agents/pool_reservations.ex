defmodule Arbiter.Agents.PoolReservations do
  @moduledoc """
  In-flight reservations on a quota pool (bd-3go56q, R9 of
  `docs/design/paced-quota-routing-signals.md`, §2.5).

  A quota snapshot lags a dispatch by minutes (a polled row is trusted for 1,200
  seconds), so several dispatches in one Autopilot tick would all read the same
  headroom and herd onto the cheapest pool. Every dispatch that gets past
  admission reserves a run on the (account, pool) routing sent it to
  (`reserve/4`). When the scorer prices a pool it adds the reservations made
  **after that pool's snapshot was captured** to the draw (`pending/4`): a run
  started before the capture is already in `used`, one started after it is not.
  Runs that land on the same pool add up before pricing (§2.1).

  A reservation ends by itself: it stops counting once a newer snapshot is
  captured, and it is forgotten after `ttl_seconds/0` regardless. It only ever
  adds to a price, never removes a candidate, so feasibility stays the paced
  gate's and one eligible candidate still gets the choice it always did (§9).

  The table is `:public` so reads bypass the GenServer, which owns it and prunes
  on write. With the process down every read is `0` and every write a no-op.
  """

  use GenServer

  @table :arbiter_pool_reservations
  @ttl_seconds 1_200

  @doc "Starts the table's owner."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "How long a reservation counts without a newer snapshot: the polled-row trust window."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Reserve a run of `task_id` on `pool` of `account_id`, started at `at`. A task
  holds one reservation: reserving again replaces it. A no-op without an account
  and pool.
  """
  @spec reserve(String.t(), String.t() | nil, String.t() | nil, DateTime.t()) :: :ok
  def reserve(task_id, account_id, pool, at \\ DateTime.utc_now())

  def reserve(task_id, account_id, pool, %DateTime{} = at)
      when is_binary(task_id) and is_binary(account_id) and is_binary(pool) do
    if table_up?() do
      prune(at)
      :ets.insert(@table, {task_id, account_id, pool, micros(at)})
    end

    :ok
  end

  def reserve(_task_id, _account_id, _pool, _at), do: :ok

  @doc "Forget `task_id`'s reservation."
  @spec release(String.t()) :: :ok
  def release(task_id) when is_binary(task_id) do
    if table_up?(), do: :ets.delete(@table, task_id)
    :ok
  end

  @doc """
  How many runs are reserved on (`account_id`, `pool`) that the snapshot captured
  at `captured_at` cannot have seen: reserved after it (every live one when
  `captured_at` is `nil`) and not older than `ttl_seconds/0` at `now`.

  Option: `:exclude` — a task id whose own reservation is left out (a task being
  re-evaluated must not price against itself).
  """
  @spec pending(String.t() | nil, String.t() | nil, DateTime.t() | nil, DateTime.t(), keyword()) ::
          non_neg_integer()
  def pending(account_id, pool, captured_at, now, opts \\ [])

  def pending(account_id, pool, captured_at, %DateTime{} = now, opts)
      when is_binary(account_id) and is_binary(pool) do
    exclude = Keyword.get(opts, :exclude)

    if table_up?() do
      @table
      |> :ets.match_object({:_, account_id, pool, :_})
      |> Enum.count(fn {task_id, _account, _pool, at} ->
        task_id != exclude and live?(at, now) and after_capture?(at, captured_at)
      end)
    else
      0
    end
  end

  def pending(_account_id, _pool, _captured_at, _now, _opts), do: 0

  # Instants are stored as integer microseconds: ETS compares terms, not structs.
  defp micros(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp live?(at, now), do: micros(now) - at <= @ttl_seconds * 1_000_000

  defp after_capture?(at, %DateTime{} = captured_at), do: at > micros(captured_at)
  defp after_capture?(_at, _no_capture), do: true

  defp prune(now) do
    cutoff = micros(now) - @ttl_seconds * 1_000_000
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  defp table_up?, do: :ets.info(@table) != :undefined
end
