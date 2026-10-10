defmodule Arbiter.NodeAgent.Supervisor do
  @moduledoc """
  The only supervision tree an agent-role VM starts (`Arbiter.NodeAgent`):

      TaskSupervisor      readiness probes, the upgrade download
      Status              <node_home>/status.json (what `arbiter-node status` reads)
      Upgrader            one self-upgrade at a time
      Image.Builder       builds a run's image from the plan the spec carries
      RunRegistry         the run table (RW9: `Arbiter.NodeAgent.Runs`)
      RunSupervisor       one `Arbiter.NodeAgent.Run` per assigned run
      Connection          the WebSocket to the primary

  `start_link/1` takes the `Arbiter.NodeAgent.Config.load/1` options. A config
  that cannot be loaded (no `ARB_NODE_URL`, no credential file, a world-readable
  one, a plain-`http` non-loopback URL) does **not** crash the VM: it records
  `unconfigured` and the reason in the status file and runs only the task
  supervisor, so `arbiter-node status` says what is wrong instead of systemd
  crash-looping the unit.
  """
  use Supervisor

  alias Arbiter.NodeAgent.Backend
  alias Arbiter.NodeAgent.Bridge
  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Connection
  alias Arbiter.NodeAgent.Runs
  alias Arbiter.NodeAgent.Status
  alias Arbiter.NodeAgent.Upgrader
  alias Arbiter.Worker.Image

  require Logger

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    task_supervisor = {Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor}

    case Config.load(opts) do
      {:ok, config} ->
        backend = config.backend
        # The run table before the connection: `Connection` addresses runs.
        config = %{
          config
          | live_runs_fun: config.live_runs_fun || (&backend.inventory/0),
            run_opts: bridge_run_opts(config.run_opts)
        }

        Supervisor.init(
          [
            task_supervisor,
            {Status, path: config.status_path},
            {Upgrader, config: config}
          ] ++
            image_builder() ++
            Runs.child_specs() ++
            [{Bridge, node_home: config.node_home}, {Connection, config: config}],
          strategy: :one_for_one
        )

      {:error, {:unknown_backend, name}} ->
        raise ArgumentError,
              "unknown ARB_AGENT_BACKEND #{inspect(name)} (expected one of: " <>
                "#{Enum.join(Backend.names(), ", ")})"

      {:error, reason} ->
        Logger.error("node agent is not configured: #{inspect(reason)}")
        record_unconfigured(opts, reason)
        Supervisor.init([task_supervisor], strategy: :one_for_one)
    end
  end

  # The per-run bridge listeners (RW10): `Run` asks for them when it prepares and
  # gives them back when it ends. A test's own `:bridges_fun` wins.
  defp bridge_run_opts(run_opts) do
    run_opts
    |> Keyword.put_new(:bridges_fun, &Bridge.listen/2)
    |> Keyword.put_new(:bridges_release_fun, &Bridge.release/1)
  end

  # `Image.Builder` builds a plan's image on this node (RW9). An agent boots
  # without the primary's application tree, so it starts its own; an
  # embedded one (a test that runs the primary tree alongside) already has it.
  defp image_builder do
    if Process.whereis(Image.Builder), do: [], else: [{Image.Builder, []}]
  end

  defp record_unconfigured(opts, reason) do
    path = Path.join(Config.node_home(opts), "status.json")

    Status.write(path, %{
      "state" => "unconfigured",
      "error" => inspect(reason),
      "pid" => System.pid(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
