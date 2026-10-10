defmodule Arbiter.NodeAgent.K8s.ControllerSupervisorTest do
  # The controller boot against a fake API server: the supervision tree starts the
  # ReadinessMonitor, hands it to the Controller, and a config change re-runs the canary.
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.K8s.ControllerSupervisor
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.NodeAgent.K8s.ReadinessMonitor
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.FakePodChannel
  alias Arbiter.Test.K8sPodFixtures, as: Fx

  @moduletag :tmp_dir

  @all_closed """
  probe api closed
  probe controller_port closed
  probe foreign closed
  probe internet closed
  probe node closed
  probe bridge open
  canary done
  """

  setup %{tmp_dir: dir} do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")
    FakeK8sApi.set_clock(env.api, DateTime.utc_now())

    hard = %{"pods" => "6", "requests.cpu" => "6", "requests.memory" => "12Gi"}

    FakeK8sApi.put_quota(env.api, %{
      "metadata" => %{"name" => "q"},
      "spec" => %{"hard" => hard},
      "status" => %{"hard" => hard, "used" => %{}}
    })

    config_path = Path.join(dir, "controller.yaml")
    File.write!(config_path, "max_concurrent: 2\n")

    loader =
      start_supervised!({ConfigLoader, path: config_path, interval_ms: nil, notify: nil},
        id: :loader
      )

    informer =
      start_supervised!(
        {Informer,
         client: env.client,
         label_selector:
           Client.label_selector(%{
             "arbiter.dev/install" => "inst-1",
             "arbiter.dev/node" => "node-1"
           }),
         backoff_ms: {5, 20},
         name: nil},
        id: :informer
      )

    :ok = Informer.await_sync(informer, 5_000)
    channel = start_supervised!(FakePodChannel)

    {:ok,
     Map.merge(env, %{loader: loader, informer: informer, channel: channel, path: config_path})}
  end

  defp script(api, log) do
    FakeK8sApi.on_create(api, fn pod ->
      {Map.put(pod, "status", %{"phase" => "Succeeded"}), String.split(log, "\n", trim: true)}
    end)
  end

  defp start!(env, log \\ @all_closed) do
    script(env.api, log)

    start_supervised!(
      {ControllerSupervisor,
       client: env.client,
       informer: env.informer,
       config_loader: env.loader,
       image: "#{Fx.registry()}/beam@sha256:#{Fx.digest()}",
       targets: %{api: "10.43.0.1:443"},
       listen_port: 0,
       monitor_name: :"readiness_monitor_#{System.unique_integer([:positive])}",
       controller_name: nil,
       readiness: [interval_ms: nil, poll_ms: 5, timeout_ms: 500],
       controller: [
         lease: nil,
         pod_channel: {FakePodChannel, env.channel},
         sink: self(),
         tick_ms: nil
       ],
       identity: %{
         registry: Fx.registry(),
         install_id: "inst-1",
         node_id: "node-1",
         owner_uid: "0b6c1d7e-8f35-4a58-9c1f-3d2f1b1c1a11",
         bridge_addr: "10.43.98.199",
         gate_addr: "10.43.0.1:443",
         own_pod: "arbiter-controller-7d9f-abc",
         max_wall_s: 3600
       }}
    )
  end

  test "the boot starts the ReadinessMonitor and the Controller", env do
    sup = start!(env)

    ids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert ids == [Controller, ReadinessMonitor]
    assert is_pid(ControllerSupervisor.monitor(sup))
    assert is_pid(ControllerSupervisor.controller(sup))
  end

  test "the controller's report carries the monitor's verdict", env do
    sup = start!(env)
    monitor = ControllerSupervisor.monitor(sup)
    controller = ControllerSupervisor.controller(sup)

    report = ReadinessMonitor.refresh(monitor)
    assert report.degraded == []

    assert %{degraded: [], readiness: %{"ready" => true, "checks" => [%{"id" => "netpol"} | _]}} =
             Controller.report(controller)
  end

  test "the controller is degraded: netpol_unenforced when the canary connects", env do
    sup = start!(env, String.replace(@all_closed, "probe internet closed", "probe internet open"))
    monitor = ControllerSupervisor.monitor(sup)

    assert %{degraded: ["netpol_unenforced"]} = ReadinessMonitor.refresh(monitor)

    assert %{degraded: ["netpol_unenforced"]} =
             sup |> ControllerSupervisor.controller() |> Controller.report()
  end

  test "a config change re-runs the canary", env do
    sup = start!(env)
    monitor = ControllerSupervisor.monitor(sup)
    assert %{degraded: []} = ReadinessMonitor.refresh(monitor)
    :ok = ReadinessMonitor.subscribe(monitor, self())

    script(env.api, String.replace(@all_closed, "probe node closed", "probe node open"))
    File.write!(env.path, "max_concurrent: 1\n")
    assert :ok = ConfigLoader.reload(env.loader)

    assert_receive {:k8s_readiness, ^monitor, %{degraded: ["netpol_unenforced"]}}, 5_000

    assert %{degraded: ["netpol_unenforced"]} =
             sup |> ControllerSupervisor.controller() |> Controller.report()
  end

  test "a restarted monitor restarts the controller and is subscribed to the loader again", env do
    sup = start!(env)
    old_monitor = ControllerSupervisor.monitor(sup)
    old_controller = ControllerSupervisor.controller(sup)
    ref = Process.monitor(old_controller)

    Process.exit(old_monitor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_controller, _}, 5_000

    monitor = ControllerSupervisor.monitor(sup)
    controller = ControllerSupervisor.controller(sup)
    assert monitor != old_monitor
    assert controller != old_controller

    # Fail closed until the new monitor's first run has finished, then the real verdict.
    assert %{degraded: [_ | _]} = Controller.report(controller)
    assert %{degraded: []} = ReadinessMonitor.refresh(monitor)

    :ok = ReadinessMonitor.subscribe(monitor, self())
    File.write!(env.path, "max_concurrent: 1\n")
    assert :ok = ConfigLoader.reload(env.loader)
    assert_receive {:k8s_readiness, ^monitor, _}, 5_000
  end
end
