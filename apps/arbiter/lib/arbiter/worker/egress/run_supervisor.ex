defmodule Arbiter.Worker.Egress.RunSupervisor do
  @moduledoc """
  One run's egress proxy: a `Task.Supervisor` for its connections and the
  `Arbiter.Worker.Egress.Listener` that accepts them. `:one_for_all`, so a
  dead listener takes its live tunnels down with it rather than leaving
  unattributed connections running. Shutdown is reverse start order: the
  listener closes first, then the connections are killed.
  """
  use Supervisor

  alias Arbiter.Worker.Egress.Listener

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

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end
end
