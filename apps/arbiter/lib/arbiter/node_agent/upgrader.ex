defmodule Arbiter.NodeAgent.Upgrader do
  @moduledoc """
  Runs at most one self-upgrade at a time (`Arbiter.NodeAgent.Upgrade`). The
  connection hands it the `upgrade{version, sha256}` the primary put in
  `hello_ok`; a request for the version already running, or already in flight,
  is ignored. The work (download, then wait for idle, then flip and stop) runs in
  a task so the connection keeps heartbeating, which is what lets the primary see
  the node as alive while it drains.
  """
  use GenServer

  alias Arbiter.NodeAgent.Status
  alias Arbiter.NodeAgent.Upgrade

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Ask for an upgrade; `:started | :ignored`."
  @spec request(GenServer.server(), map()) :: :started | :ignored
  def request(server \\ __MODULE__, spec), do: GenServer.call(server, {:request, spec})

  @impl true
  def init(opts) do
    {:ok,
     %{
       config: Keyword.fetch!(opts, :config),
       task_supervisor: Keyword.get(opts, :task_supervisor, Arbiter.NodeAgent.TaskSupervisor),
       status: Keyword.get(opts, :status, Status),
       in_flight: nil
     }}
  end

  @impl true
  def handle_call({:request, %{"version" => version} = spec}, _from, state)
      when is_binary(version) do
    cond do
      Upgrade.same_version?(version, state.config.version) -> {:reply, :ignored, state}
      state.in_flight -> {:reply, :ignored, state}
      true -> {:reply, :started, start(state, version, spec)}
    end
  end

  def handle_call({:request, _spec}, _from, state), do: {:reply, :ignored, state}

  @impl true
  def handle_info({ref, result}, %{in_flight: {version, ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("node agent upgrade to #{version} failed: #{inspect(reason)}")

        Status.put(state.status, %{
          upgrade: %{state: "failed", version: version, error: inspect(reason)}
        })
    end

    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: {version, ref}} = state) do
    Logger.error("node agent upgrade to #{version} crashed: #{inspect(reason)}")

    Status.put(state.status, %{
      upgrade: %{state: "failed", version: version, error: inspect(reason)}
    })

    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp start(state, version, spec) do
    config = state.config
    status = state.status
    Status.put(status, %{upgrade: %{state: "downloading", version: version}})

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        run(config, status, version, spec)
      end)

    %{state | in_flight: {version, task.ref}}
  end

  defp run(config, status, version, spec) do
    with {:ok, _dir} <- Upgrade.prepare(config, spec) do
      Status.put(status, %{upgrade: %{state: "waiting_for_idle", version: version}})
      Upgrade.commit(config, version)
    end
  end
end
