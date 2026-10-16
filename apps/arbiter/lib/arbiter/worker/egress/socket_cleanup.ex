defmodule Arbiter.Worker.Egress.SocketCleanup do
  @moduledoc """
  Removes a run's socket files when its `RunSupervisor` shuts down.

  It is the first child, so it is terminated last: after every listener has
  closed (or been killed). A listener that dies abruptly never runs its own
  `terminate/2`, and closing a listen socket is deferred inside the VM (the
  port's `:DOWN` can arrive while the fd is still open and accepting into its
  backlog), so the file removal is what makes the supervisor's exit
  deterministic: a client connecting afterwards gets `:enoent`, never a
  connection to a dying proxy.
  """
  use GenServer

  @spec start_link([Path.t()]) :: GenServer.on_start()
  def start_link(paths), do: GenServer.start_link(__MODULE__, paths)

  @impl true
  def init(paths) do
    Process.flag(:trap_exit, true)
    {:ok, paths}
  end

  @impl true
  def terminate(_reason, paths) do
    Enum.each(paths, &File.rm/1)
    :ok
  end
end
