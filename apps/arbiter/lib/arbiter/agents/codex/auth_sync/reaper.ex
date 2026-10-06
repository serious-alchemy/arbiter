defmodule Arbiter.Agents.Codex.AuthSync.Reaper do
  @moduledoc """
  Persists a podman Codex run's rotated `auth.json` when the worker that owns the
  run goes down for **any** reason, including a brutal `:kill` that skips the
  worker's own `terminate/2` (bd-50d5j6).

  The run's copy lives in its per-run temp dir, which `Arbiter.Worker.RunTmp.Reaper`
  removes on the same `:DOWN`. A rotation that was only ever in that copy would be
  lost with it, and the operator's real login would be left holding a refresh
  token the server has already retired. So `Arbiter.Worker.ContainerSpawn` calls
  `track/4` when it seeds a run, `RunTmp.Reaper` calls `flush/2` *before* it
  removes the directory (a synchronous call, so the ordering holds), and this
  server also syncs on its own `:DOWN` for any other path.

  The paths are held here, in the server's memory, never read back from the run
  directory: a worker can write there and must not choose where the sync lands.
  """

  use GenServer

  alias Arbiter.Agents.Codex.AuthSync

  require Logger

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, if(name, do: [name: name], else: []))
  end

  @doc "Sync `run` into `source` when `owner` exits."
  @spec track(pid(), Path.t(), Path.t(), GenServer.server()) :: :ok
  def track(owner, source, run, server \\ __MODULE__) when is_pid(owner),
    do: GenServer.call(server, {:track, owner, source, run})

  @doc """
  Sync every run `owner` has now. `:ok` also when nothing is tracked or the
  reaper is not running.
  """
  @spec flush(pid(), GenServer.server()) :: :ok
  def flush(owner, server \\ __MODULE__) when is_pid(owner) do
    GenServer.call(server, {:flush, owner}, 30_000)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(:ok), do: {:ok, %{refs: %{}}}

  @impl true
  def handle_call({:track, owner, source, run}, _from, %{refs: refs} = state) do
    refs =
      case Enum.find(refs, fn {_ref, {pid, _}} -> pid == owner end) do
        {ref, {^owner, runs}} -> Map.put(refs, ref, {owner, Enum.uniq([{source, run} | runs])})
        nil -> Map.put(refs, Process.monitor(owner), {owner, [{source, run}]})
      end

    {:reply, :ok, %{state | refs: refs}}
  end

  def handle_call({:flush, owner}, _from, %{refs: refs} = state) do
    for {_ref, {^owner, runs}} <- refs, do: sync_all(runs)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refs: refs} = state) do
    {{_owner, runs}, refs} = Map.pop(refs, ref, {nil, []})
    sync_all(runs)
    {:noreply, %{state | refs: refs}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A raise here would restart the reaper and forget every live run.
  defp sync_all(runs) do
    Enum.each(runs, fn {source, run} ->
      try do
        AuthSync.sync(source, run)
      rescue
        e -> Logger.error("Codex.AuthSync.Reaper: sync failed: #{Exception.message(e)}")
      end
    end)
  end
end
