defmodule Arbiter.Worker.Egress.OwnerWatch do
  @moduledoc """
  Ties a run's proxy to the process that owns the run (the worker). When the
  owner exits the watch stops normally; as a `:permanent` child of a
  `max_restarts: 0` supervisor that takes the whole run (sockets, live
  tunnels) down with it, so a finished worker leaves nothing listening.
  """
  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(owner) when is_pid(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner) do
    ref = Process.monitor(owner)
    {:ok, ref}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, ref), do: {:stop, :normal, ref}
  def handle_info(_msg, ref), do: {:noreply, ref}
end
