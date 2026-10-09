defmodule Arbiter.Worker.TestServices.Reaper do
  @moduledoc """
  Removes a worker's test-services pod (`Arbiter.Worker.TestServices`) when the
  worker that owns it goes down for **any** reason, including a brutal `:kill`
  that skips the worker's own `terminate/2` (bd-dmcbos). The pod outlives its
  worker container (`--rm` removes only the container), so without this a crash
  would leave a Postgres running until the next boot.

  `track/3` is called by `Arbiter.Worker.ContainerSpawn.prepare/1` with the
  worker pid; the reaper monitors it and removes the pod on `:DOWN`. A resumed
  spawn reuses the worker's pod, a later `prepare/1` makes a new one, and every
  pod hanging off one owner goes when it does.

  At boot it also removes the pods a dead server left behind
  (`TestServices.reap_orphans/1`: only pods whose recorded server pid is gone).
  The boot sweep is off under `config :arbiter, :test_services_reaper,
  enabled: false` (test), where `reap_orphans/1` is called directly.
  """

  use GenServer

  alias Arbiter.Worker.TestServices

  require Logger

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Remove `pod` when `owner` exits. `pod_opts` (`:runner`, `:podman`) go to `TestServices.stop/2`."
  @spec track(pid(), String.t(), keyword(), GenServer.server()) :: :ok
  def track(owner, pod, pod_opts \\ [], server \\ __MODULE__)
      when is_pid(owner) and is_binary(pod),
      do: GenServer.call(server, {:track, owner, pod, pod_opts})

  @impl true
  def init(opts) do
    cfg = Application.get_env(:arbiter, :test_services_reaper, [])
    state = %{refs: %{}, sweep_opts: Keyword.take(opts, [:runner, :podman, :alive?])}

    if Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true)),
      do: {:ok, state, {:continue, :sweep}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:sweep, %{sweep_opts: opts} = state) do
    try do
      case TestServices.reap_orphans(opts) do
        [] -> :ok
        removed -> Logger.info("TestServices.Reaper: removed #{length(removed)} orphaned pod(s)")
      end

      # bd-9cygoo (G16): deploy keys a dead server left staged on disk, and any in
      # podman's secret store.
      _ = Arbiter.Worker.GitCredential.sweep(max_age_ms: 0)

      case Arbiter.Worker.Container.reap_git_secrets(Keyword.take(opts, [:runner, :podman])) do
        [] -> :ok
        removed -> Logger.info("TestServices.Reaper: removed #{length(removed)} orphaned git secret(s)")
      end
    rescue
      e -> Logger.warning("TestServices.Reaper: sweep failed: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:track, owner, pod, pod_opts}, _from, %{refs: refs} = state) do
    refs =
      case Enum.find(refs, fn {_ref, {pid, _}} -> pid == owner end) do
        {ref, {^owner, pods}} -> Map.put(refs, ref, {owner, [{pod, pod_opts} | pods]})
        nil -> Map.put(refs, Process.monitor(owner), {owner, [{pod, pod_opts}]})
      end

    {:reply, :ok, %{state | refs: refs}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refs: refs} = state) do
    {{_owner, pods}, refs} = Map.pop(refs, ref, {nil, []})

    # A raise here would restart the reaper and forget every live run's pod.
    Enum.each(pods, fn {pod, pod_opts} ->
      try do
        TestServices.teardown(pod, pod_opts)
      rescue
        _ -> :ok
      end
    end)

    {:noreply, %{state | refs: refs}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
