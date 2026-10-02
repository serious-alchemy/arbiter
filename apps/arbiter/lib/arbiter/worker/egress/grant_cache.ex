defmodule Arbiter.Worker.Egress.GrantCache do
  @moduledoc """
  The ETS cache between the egress proxy and a ticket's current `network:`
  grants (bd-aspkyr, design §4.4 "Grants apply live").

  The proxy reads grants on every `CONNECT`, so the read has to be cheap: a
  hit is one `:ets.lookup/2` and no query. A grant (or revocation) calls
  `invalidate/1` for the task, so the next `CONNECT` reloads and a mid-run
  grant takes effect without a restart. The TTL is only a backstop for a
  writer that forgot to invalidate; it is not the mechanism.

  Keyed by task id, because grants belong to the ticket and a resumed run of
  the same ticket shares them. The loader is supplied per run
  (`Arbiter.Worker.Egress.start_run/2`), so this module knows nothing about
  where grants are stored.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  The grants for `task_id`: the cached list, or `loader.(task_id)` stored for
  next time. A loader that raises or returns a non-list yields `[]` and is
  not cached, so a transient failure denies (fail closed) and retries on the
  next `CONNECT`.
  """
  @spec fetch(String.t() | nil, (String.t() | nil -> [String.t()])) :: [String.t()]
  def fetch(task_id, loader) do
    now = System.monotonic_time(:millisecond)

    case lookup(task_id) do
      {:ok, grants, inserted_at} when now - inserted_at < @ttl_ms -> grants
      _ -> load(task_id, loader, now)
    end
  end

  @doc "Drops the cached grants for `task_id`. Safe before the table exists."
  @spec invalidate(String.t() | nil) :: :ok
  def invalidate(task_id) do
    :ets.delete(@table, task_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp lookup(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, grants, inserted_at}] -> {:ok, grants, inserted_at}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp load(task_id, loader, now) do
    case safe_load(loader, task_id) do
      {:ok, grants} ->
        store(task_id, grants, now)
        grants

      :error ->
        []
    end
  end

  defp safe_load(loader, task_id) do
    case loader.(task_id) do
      grants when is_list(grants) -> {:ok, grants}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp store(task_id, grants, now) do
    :ets.insert(@table, {task_id, grants, now})
  rescue
    ArgumentError -> true
  end
end
