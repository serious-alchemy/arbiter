defmodule Arbiter.NodeAgent.K8s.ControllerSupervisor do
  @moduledoc """
  The controller boot (`docs/design/remote-workers.md` k8s §9.4, ticket K13): it starts
  the `Arbiter.NodeAgent.K8s.ReadinessMonitor` and then the
  `Arbiter.NodeAgent.K8s.Controller` that carries the monitor's verdict.

      ReadinessMonitor    canary + readiness at start, on config change, every 10 min
      Controller          readiness: the monitor above

  The strategy is `:rest_for_one`: a restarted monitor restarts the controller, which
  subscribes to the monitor again in `handle_continue`, so the controller never holds
  a stale monitor pid. The monitor subscribes itself to the `ConfigLoader`
  (`:config_loader`), so a restarted monitor is also subscribed again, and a good config
  change reaches it as `{:controller_config, loader, config}` and re-runs the canary.

  Until the first canary has finished the monitor's report is the fail-closed one
  (`degraded: ["netpol_unenforced"]`), and `Controller.report/1` carries it from the
  moment the controller is up.

  The `ConfigLoader` and `Informer` are started by the caller, **by name** (a pid
  would go stale when they restart). Options:

    * `:client`, `:informer`, `:config_loader`, `:identity` (required; the controller's)
    * `:image` (required): the digest-pinned worker image the canary pod runs
    * `:targets`: the canary's probe targets (default `Canary.targets_from_env/0`)
    * `:listen_port`: where the monitor accepts and closes for the `controller_port`
      probe (default #{9445}; `0` picks one, `nil` opens none)
    * `:monitor_name` (default `Arbiter.NodeAgent.K8s.ReadinessMonitor`), `:name`
      (the supervisor's, default none), `:controller_name` (default `Controller`)
    * `:readiness` : extra `ReadinessMonitor` options (`:interval_ms`, `:poll_ms`, …)
    * `:controller` : extra `Controller` options (`:lease`, `:sink`, `:pod_channel`, …)
  """

  use Supervisor

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.K8s.ControllerConfig
  alias Arbiter.NodeAgent.K8s.ReadinessMonitor

  @default_listen_port 9445
  @pod_facts ~w(registry install_id node_id owner_uid bridge_addr gate_addr max_wall_s)a

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    Supervisor.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The supervised `ReadinessMonitor` (its pid)."
  @spec monitor(Supervisor.supervisor()) :: pid() | nil
  def monitor(supervisor), do: child(supervisor, ReadinessMonitor)

  @doc "The supervised `Controller` (its pid)."
  @spec controller(Supervisor.supervisor()) :: pid() | nil
  def controller(supervisor), do: child(supervisor, Controller)

  defp child(supervisor, id) do
    Enum.find_value(Supervisor.which_children(supervisor), fn
      {^id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  @impl true
  def init(opts) do
    loader = Keyword.fetch!(opts, :config_loader)
    identity = Keyword.fetch!(opts, :identity)
    monitor_name = Keyword.get(opts, :monitor_name, ReadinessMonitor)

    monitor_opts =
      [
        client: Keyword.fetch!(opts, :client),
        config_loader: loader,
        config_fun: fn -> canary_config(loader, identity) end,
        image: Keyword.fetch!(opts, :image),
        targets: Keyword.get_lazy(opts, :targets, &Canary.targets_from_env/0),
        listen_port: Keyword.get(opts, :listen_port, @default_listen_port),
        name: monitor_name
      ] ++ Keyword.get(opts, :readiness, [])

    controller_opts =
      Keyword.take(opts, [:client, :informer, :config_loader, :identity]) ++
        [readiness: monitor_name, name: Keyword.get(opts, :controller_name, Controller)] ++
        Keyword.get(opts, :controller, [])

    Supervisor.init(
      [
        Supervisor.child_spec({ReadinessMonitor, monitor_opts}, id: ReadinessMonitor),
        Supervisor.child_spec({Controller, controller_opts}, id: Controller)
      ],
      strategy: :rest_for_one
    )
  end

  # The `PodSpec` config for one canary run: the operator's good config, the facts the
  # controller knows, and a single-use nonce (the canary pod is not a run, so no pod
  # channel ever sees it).
  defp canary_config(loader, identity) do
    with {:ok, config} <- ConfigLoader.current(loader) do
      facts =
        identity
        |> Map.take(@pod_facts)
        |> Map.put(:boot_nonce, Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))

      {:ok, ControllerConfig.pod_config(config, facts)}
    end
  end
end
