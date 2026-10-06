defmodule Arbiter.NodeAgent.Supervisor do
  @moduledoc """
  The only supervision tree an agent-role VM starts (`Arbiter.NodeAgent`):

      TaskSupervisor      readiness probes, the upgrade download
      Status              <node_home>/status.json (what `arbiter-node status` reads)
      Upgrader            one self-upgrade at a time
      Connection          the WebSocket to the primary

  `start_link/1` takes the `Arbiter.NodeAgent.Config.load/1` options. A config
  that cannot be loaded (no `ARB_NODE_URL`, no credential file, a world-readable
  one, a plain-`http` non-loopback URL) does **not** crash the VM: it records
  `unconfigured` and the reason in the status file and runs only the task
  supervisor, so `arbiter-node status` says what is wrong instead of systemd
  crash-looping the unit.
  """
  use Supervisor

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Connection
  alias Arbiter.NodeAgent.Status
  alias Arbiter.NodeAgent.Upgrader

  require Logger

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    task_supervisor = {Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor}

    case Config.load(opts) do
      {:ok, config} ->
        Supervisor.init(
          [
            task_supervisor,
            {Status, path: config.status_path},
            {Upgrader, config: config},
            {Connection, config: config}
          ],
          strategy: :one_for_one
        )

      {:error, reason} ->
        Logger.error("node agent is not configured: #{inspect(reason)}")
        record_unconfigured(opts, reason)
        Supervisor.init([task_supervisor], strategy: :one_for_one)
    end
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
