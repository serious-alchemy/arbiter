defmodule ArbiterWeb.Plugs.ApiConcurrencyLimit.Counter do
  @moduledoc """
  The slot table behind `ArbiterWeb.Plugs.ApiConcurrencyLimit`: a GenServer
  that monitors each holder so a crashed request process can never leak a slot.
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec acquire(pid(), pos_integer()) :: :ok | :full
  def acquire(pid, max), do: GenServer.call(__MODULE__, {:acquire, pid, max})

  @spec release(pid()) :: :ok
  def release(pid), do: GenServer.cast(__MODULE__, {:release, pid})

  @spec in_flight() :: non_neg_integer()
  def in_flight, do: GenServer.call(__MODULE__, :in_flight)

  @impl GenServer
  def init(:ok), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:acquire, pid, max}, _from, holders) do
    cond do
      Map.has_key?(holders, pid) ->
        {:reply, :ok, holders}

      map_size(holders) >= max ->
        {:reply, :full, holders}

      true ->
        {:reply, :ok, Map.put(holders, pid, Process.monitor(pid))}
    end
  end

  def handle_call(:in_flight, _from, holders), do: {:reply, map_size(holders), holders}

  @impl GenServer
  def handle_cast({:release, pid}, holders), do: {:noreply, drop(holders, pid)}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, holders),
    do: {:noreply, Map.delete(holders, pid)}

  defp drop(holders, pid) do
    case Map.pop(holders, pid) do
      {nil, holders} ->
        holders

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        holders
    end
  end
end
