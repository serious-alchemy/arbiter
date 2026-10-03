defmodule Arbiter.Worker.Egress.RunSupervisor do
  @moduledoc """
  One run's egress proxy: a `Task.Supervisor` for its connections and the
  `Arbiter.Worker.Egress.Listener` that accepts them. `:one_for_all`, so a
  dead listener takes its live tunnels down with it rather than leaving
  unattributed connections running. Shutdown is reverse start order: the
  listeners close first, then the connections are killed.

  Besides the proxy listener there is one fixed-target `Forward` listener per
  `:bridges` entry, and, when `:owner` is given, an `OwnerWatch` that ends the
  whole run when the owner exits.
  """
  use Supervisor

  alias Arbiter.Worker.Egress.{Forward, Listener, OwnerWatch}

  @registry Arbiter.Worker.Egress.Registry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    Supervisor.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, {run_id, :sup}}})
  end

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    tasks = {:via, Registry, {@registry, {run_id, :tasks}}}

    children = [
      {Task.Supervisor, name: tasks},
      %{
        id: Listener,
        start:
          {Listener, :start_link,
           [
             [
               name: {:via, Registry, {@registry, {run_id, :listener}}},
               socket_path: Keyword.fetch!(opts, :socket_path),
               context: Keyword.fetch!(opts, :context),
               task_supervisor: tasks
             ]
           ]},
        shutdown: 5_000
      }
    ]

    children =
      children ++
        Enum.map(Keyword.get(opts, :bridges, []), &bridge_child(run_id, &1, tasks)) ++
        owner_child(Keyword.get(opts, :owner))

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  defp bridge_child(run_id, %{name: name, path: path, host: host, port: port}, tasks) do
    %{
      id: {Listener, name},
      start:
        {Listener, :start_link,
         [
           [
             name: {:via, Registry, {@registry, {run_id, {:bridge, name}}}},
             socket_path: path,
             handler: fn socket -> Forward.run(socket, run_id, host, port) end,
             task_supervisor: tasks
           ]
         ]},
      shutdown: 5_000
    }
  end

  defp owner_child(owner) when is_pid(owner),
    do: [%{id: OwnerWatch, start: {OwnerWatch, :start_link, [owner]}, restart: :permanent}]

  defp owner_child(_), do: []
end
