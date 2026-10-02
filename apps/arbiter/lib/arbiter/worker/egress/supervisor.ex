defmodule Arbiter.Worker.Egress.Supervisor do
  @moduledoc """
  The long-lived parts of `Arbiter.Worker.Egress`: the grant cache, the
  registry that maps a run id to its proxy processes, and the dynamic
  supervisor those per-run proxies start under. Idle until something calls
  `Arbiter.Worker.Egress.start_run/2`; nothing does yet (G6 wires it).
  """
  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Arbiter.Worker.Egress.GrantCache,
      {Registry, keys: :unique, name: Arbiter.Worker.Egress.Registry},
      {DynamicSupervisor, name: Arbiter.Worker.Egress.RunSupervisors, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
