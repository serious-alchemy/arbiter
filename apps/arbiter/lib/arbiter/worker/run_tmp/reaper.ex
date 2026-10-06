defmodule Arbiter.Worker.RunTmp.Reaper do
  @moduledoc """
  Removes a run's per-run temp dir (`Arbiter.Worker.RunTmp`) when the worker
  that owns it goes down — for **any** reason, including a brutal `:kill` that
  skips the worker's own `terminate/2`. The dir is tied to the run lifecycle,
  not to the agent's own cleanup (bd-5ad4ch).

  `track/2` is called by `Arbiter.Worker.ClaudeSession.start/1` with the port
  owner; the reaper monitors it and removes the dir on `:DOWN`. A resumed or
  nudged spawn reuses the same worker, so several dirs may hang off one owner;
  all go when it does.
  """

  use GenServer

  alias Arbiter.Agents.Codex.AuthSync
  alias Arbiter.Worker.RunTmp

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Remove `dir` when `owner` exits."
  @spec track(pid(), String.t(), GenServer.server()) :: :ok
  def track(owner, dir, server \\ __MODULE__) when is_pid(owner) and is_binary(dir),
    do: GenServer.call(server, {:track, owner, dir})

  @impl true
  def init(:ok), do: {:ok, %{refs: %{}}}

  @impl true
  def handle_call({:track, owner, dir}, _from, %{refs: refs} = state) do
    refs =
      case Enum.find(refs, fn {_ref, {pid, _}} -> pid == owner end) do
        {ref, {^owner, dirs}} -> Map.put(refs, ref, {owner, [dir | dirs]})
        nil -> Map.put(refs, Process.monitor(owner), {owner, [dir]})
      end

    {:reply, :ok, %{state | refs: refs}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{refs: refs} = state) do
    {{_owner, dirs}, refs} = Map.pop(refs, ref, {nil, []})

    # bd-50d5j6: a podman Codex run keeps a rotated auth.json in this dir; it is
    # persisted to the operator's login before the dir goes (a no-op otherwise).
    AuthSync.Reaper.flush(pid)

    # A raise here would restart the reaper and forget every live run's dir.
    Enum.each(dirs, fn dir ->
      try do
        RunTmp.remove(dir)
      rescue
        _ -> :ok
      end
    end)

    {:noreply, %{state | refs: refs}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
