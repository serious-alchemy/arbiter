defmodule Arbiter.NodeAgent.Backend.Podman do
  @moduledoc """
  `Arbiter.NodeAgent.Backend` over podman: the RW9 run supervisor
  (`Arbiter.NodeAgent.Runs` / `Arbiter.NodeAgent.Run`), the install-scoped
  `Arbiter.NodeAgent.Reaper` and `Arbiter.Worker.PodmanReadiness`. A thin
  delegation layer: it adds no behaviour of its own.
  """
  @behaviour Arbiter.NodeAgent.Backend

  alias Arbiter.NodeAgent.{Exec, Protocol, Reaper, Run, Runs}
  alias Arbiter.Worker.PodmanReadiness

  @impl true
  def inventory, do: Runs.inventory()

  @impl true
  def start_run(%{spec: spec, opts: opts}), do: Runs.assign(spec, opts)

  @impl true
  def signal(run, signal), do: Run.signal(run, signal)

  @impl true
  def stop({run, reason}), do: Run.cancel(run, reason)
  def stop(run), do: Run.cancel(run, "cancelled")

  @impl true
  def outcome(run), do: Run.outcome(run)

  @impl true
  def collect(run, opts) do
    case Keyword.get(opts, :kind, "checkout") do
      "checkout" -> Run.collect(run)
      other -> {:error, {:unsupported_kind, other}}
    end
  end

  @impl true
  def exec(run, command, timeout_s, opts), do: Exec.run(run, command, timeout_s, opts)

  @impl true
  def list_owned,
    do: Runs.run_ids()

  @impl true
  def reap(%{config: config, request: request, opts: opts}),
    do: Reaper.reap(config, request, opts)

  @impl true
  def capacity, do: Protocol.capacity_facts()

  @impl true
  def readiness, do: PodmanReadiness.diagnose()
end
