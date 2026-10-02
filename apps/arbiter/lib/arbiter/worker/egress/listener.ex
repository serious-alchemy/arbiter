defmodule Arbiter.Worker.Egress.Listener do
  @moduledoc """
  Owns one run's Unix listen socket (`<run>.proxy.sock`) and accepts on it.

  The socket a connection arrives on is the run's identity (design §4.4): the
  run context given to `start_link/1` is handed to every connection accepted
  here, and nothing the client sends can change which run, task or grants
  apply. The listen socket is created `0600`, in a directory the caller
  should keep `0700`. A stale socket file from a crashed predecessor is
  removed first; on terminate the socket is closed and the file removed, so a
  stopped (or dead) proxy leaves nothing to connect to and egress fails
  closed.

  A listener built with a `:handler` (`fun(socket)`, run in the connection's
  own process) serves something other than the CONNECT proxy: the fixed-target
  bridges `Arbiter.Worker.Egress.Forward` runs for a jailed run's Arbiter
  endpoint and tunnels.
  """
  use GenServer

  alias Arbiter.Worker.Egress.Connection

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(opts, :socket_path)
    ctx = Keyword.get(opts, :context)
    handler = Keyword.get(opts, :handler) || fn socket -> Connection.run(socket, ctx) end
    task_sup = Keyword.fetch!(opts, :task_supervisor)

    _ = File.rm(path)

    listen_opts = [
      :binary,
      packet: :raw,
      active: false,
      exit_on_close: false,
      backlog: 128,
      ifaddr: {:local, String.to_charlist(path)}
    ]

    with {:ok, listen} <- :gen_tcp.listen(0, listen_opts),
         :ok <- File.chmod(path, 0o600) do
      acceptor = spawn_link(fn -> accept_loop(listen, task_sup, handler) end)
      {:ok, %{listen: listen, path: path, acceptor: acceptor}}
    else
      {:error, reason} -> {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state) do
    {:stop, {:acceptor_exited, reason}, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) when reason in [:normal, :shutdown],
    do: {:noreply, state}

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{listen: listen, path: path}) do
    :gen_tcp.close(listen)
    _ = File.rm(path)
    :ok
  end

  defp accept_loop(listen, task_sup, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} =
          Task.Supervisor.start_child(task_sup, fn ->
            receive do
              :go -> handler.(socket)
            end
          end)

        case :gen_tcp.controlling_process(socket, pid) do
          :ok -> send(pid, :go)
          {:error, _} -> :gen_tcp.close(socket)
        end

        accept_loop(listen, task_sup, handler)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end
end
