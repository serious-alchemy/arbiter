defmodule Arbiter.NodeAgent.Backend.K8sTest do
  @moduledoc """
  `Arbiter.NodeAgent.Backend.K8s` (ticket K14, `docs/design/remote-workers.md` K§3.2):
  the backend a cluster controller's `Connection` speaks to, over a real
  `Arbiter.NodeAgent.K8s.Controller` on the fake API server. The controller runs under
  its production name, as the node-agent boot starts it, so this module is not async.
  """
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.Backend
  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.NodeAgent.PodChannel
  alias Arbiter.NodeAgent.PodChannel.Cert
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.FakePodChannel
  alias Arbiter.Test.K8sPodFixtures, as: Fx

  @moduletag :tmp_dir
  @credential "arbn_node-1." <> String.duplicate("A", 52)

  setup %{tmp_dir: dir} do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")
    hard = %{"pods" => "8", "requests.cpu" => "16", "requests.memory" => "64Gi"}

    FakeK8sApi.put_quota(env.api, %{
      "metadata" => %{"name" => "q"},
      "spec" => %{"hard" => hard},
      "status" => %{"hard" => hard, "used" => %{}}
    })

    path = Path.join(dir, "controller.yaml")
    File.write!(path, "max_concurrent: 2\n")
    loader = start_supervised!({ConfigLoader, path: path, interval_ms: nil}, id: :loader)

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

    start_supervised!(
      {Controller,
       client: env.client,
       informer: informer,
       config_loader: loader,
       lease: nil,
       pod_channel: {FakePodChannel, channel},
       identity:
         Map.take(
           Fx.config(),
           ~w(registry install_id node_id owner_uid bridge_addr gate_addr max_wall_s)a
         ),
       sink: self(),
       tick_ms: nil}
    )

    {:ok, config} =
      Config.load(
        env: %{},
        app_config: [],
        primary_url: "https://primary.example.ts.net",
        node_home: dir,
        read_credential: fn _ -> {:ok, @credential} end,
        version: "1.2.3",
        backend: Backend.K8s,
        cluster: %{namespace: "arbiter-workers", k8s_version: "v1.31.2+fake", self_upgrade?: true}
      )

    Map.merge(env, %{config: config, path: path, loader: loader})
  end

  defp wire(n),
    do:
      Fx.wire_spec(%{
        "run" => "run-#{n}",
        "name" => "arb-run-#{n}",
        "image" => %{
          "tag" => "t",
          "plan" => nil,
          "ref" => "#{Fx.registry()}/beam@sha256:#{Fx.digest()}"
        }
      })

  defp start!(n), do: Backend.K8s.start_run(%{spec: wire(n), opts: [sink: self()]})

  defp running(env, n) do
    pod = FakeK8sApi.handle(env.api, {:get, "arb-run-#{n}"})

    FakeK8sApi.put_pod(
      env.api,
      Map.put(pod, "status", %{
        "phase" => "Running",
        "podIP" => "10.42.0.#{n}",
        "conditions" => [%{"type" => "PodScheduled", "status" => "True"}],
        "containerStatuses" => [%{"name" => "worker", "state" => %{"running" => %{}}}]
      })
    )

    run = "run-#{n}"
    assert_receive {:run_push, ^run, "run.ready", _}, 5_000
  end

  describe "registration" do
    test "ARB_AGENT_BACKEND=k8s names this backend" do
      assert {:ok, Backend.K8s} = Backend.resolve("k8s")
      assert {:ok, Backend.K8s} = Backend.resolve(" K8S ")
      assert "k8s" in Backend.names()

      assert {:ok, Backend.K8s} =
               Config.backend(env: %{"ARB_AGENT_BACKEND" => "k8s"}, app_config: [])

      assert {:ok, Backend.Podman} = Config.backend(env: %{}, app_config: [])
    end

    test "implements every callback of the behaviour" do
      Code.ensure_loaded!(Backend.K8s)

      for {fun, arity} <- Backend.behaviour_info(:callbacks), {fun, arity} != {:exec, 4} do
        assert function_exported?(Backend.K8s, fun, arity), "#{fun}/#{arity} missing"
      end
    end
  end

  describe "hello and hb" do
    test "hello is a cluster's: kind, caps, the controller's capacity, degraded and inventory",
         env do
      {:ok, "run-1"} = start!(1)

      hello = Backend.K8s.hello(env.config, Backend.K8s.readiness())

      assert hello["kind"] == "cluster"
      assert hello["agent_version"] == "1.2.3"
      assert hello["proto"] == Config.proto()
      assert hello["k8s_version"] == "v1.31.2+fake"
      assert is_binary(hello["arch"])

      assert hello["caps"] == %{
               "backend" => "k8s",
               "image" => "registry",
               "limits" => "pod",
               "bridge_streams" => "mux",
               "upgrade" => "image",
               "self_upgrade" => true,
               "namespace" => "arbiter-workers"
             }

      assert %{"ceiling" => 2, "pending" => 1, "running" => 0} = hello["capacity"]
      assert hello["degraded"] == []

      assert %{"runs" => [%{"id" => "run-1", "state" => "pending"}], "retained" => []} =
               hello["inventory"]

      # The JSON the channel will carry: string keys all the way down.
      assert hello == hello |> Jason.encode!() |> Jason.decode!()
    end

    test "a heartbeat carries the runs, capacity, degraded and readiness", env do
      {:ok, "run-1"} = start!(1)
      running(env, 1)

      hb = Backend.K8s.heartbeat(env.config, 4)

      assert %{"seq" => 4, "runs" => [%{"id" => "run-1", "state" => "running"}]} = hb
      assert %{"ceiling" => 2, "running" => 1} = hb["capacity"]
      assert hb["degraded"] == []
    end

    test "a bad ConfigMap shows as degraded: bad_config", env do
      File.write!(env.path, "max_concurrent: [nope\n")
      ConfigLoader.reload(env.loader)

      assert "bad_config" in Backend.K8s.heartbeat(env.config, 1)["degraded"]
      assert "bad_config" in Backend.K8s.hello(env.config, %{})["degraded"]
    end

    test "with no controller to ask, a heartbeat says only its seq (nothing is cleared)", env do
      stop_supervised!(Controller)

      assert Backend.K8s.heartbeat(env.config, 9) == %{"seq" => 9}
      assert Backend.K8s.inventory() == []
      assert Backend.K8s.capacity() == %{}
    end
  end

  describe "runs" do
    test "start_run assigns; the controller's refusal comes back as it said it", env do
      assert {:ok, "run-1"} = start!(1)
      assert {:ok, "run-2"} = start!(2)

      assert {:error, {:refuse, :no_capacity, detail}} = start!(3)
      assert detail =~ "max_concurrent"
      assert {:error, :already_running} = start!(1)
      assert Enum.sort(Backend.K8s.list_owned()) == ["run-1", "run-2"]
      _ = env
    end

    test "a repeated assign re-announces the run", env do
      {:ok, "run-1"} = start!(1)
      running(env, 1)

      assert :ok = Backend.K8s.attach("run-1")
      assert_receive {:run_push, "run-1", "run.ready", _}, 5_000
      assert {:error, :not_found} = Backend.K8s.attach("run-9")
    end

    test "stop deletes the pod at once; quiesce and the fence give it its grace period", env do
      {:ok, "run-1"} = start!(1)
      {:ok, "run-2"} = start!(2)

      assert :ok = Backend.K8s.stop({"run-1", "cancelled by owner"})
      assert :ok = Backend.K8s.quiesce("run-2")
      assert {:error, :not_found} = Backend.K8s.stop({"run-9", "x"})

      graces =
        for %{method: "DELETE", path: path, body: body} <- FakeK8sApi.requests(env.api),
            into: %{},
            do: {Path.basename(path), Jason.decode!(body)["gracePeriodSeconds"]}

      assert graces == %{"arb-run-1" => 0, "arb-run-2" => 120}
    end

    test "fence_all stops every live run with its grace period", env do
      {:ok, "run-1"} = start!(1)
      running(env, 1)
      {:ok, "run-2"} = start!(2)

      assert :ok = Backend.K8s.fence_all()

      deleted =
        for %{method: "DELETE", path: path, body: body} <- FakeK8sApi.requests(env.api),
            do: {Path.basename(path), Jason.decode!(body)["gracePeriodSeconds"]}

      assert Enum.sort(deleted) == [{"arb-run-1", 120}, {"arb-run-2", 120}]
    end

    test "signal and exit_ack reach the controller", env do
      {:ok, "run-1"} = start!(1)
      assert :ok = Backend.K8s.signal("run-1", "KILL")
      assert {:error, :not_found} = Backend.K8s.signal("run-9", "TERM")
      assert :ok = Backend.K8s.exit_ack("run-1")
      assert Backend.K8s.outcome("run-1") == nil
      _ = env
    end

    test "there is no run adoption across a primary restart, and nothing to detach", _env do
      assert {:error, :unsupported} = Backend.K8s.adopt("run-1")
      assert :ok = Backend.K8s.detach_all()
    end

    # K15
    test "the stdout stream: frames reach the sink; resume and ack reach the follower", env do
      {:ok, "run-1"} = start!(1)
      running(env, 1)
      FakeK8sApi.push_log(env.api, "arb-run-1", "one")
      assert_receive {:run_push, "run-1", "stdout", {:binary, f1}}, 5_000
      FakeK8sApi.push_log(env.api, "arb-run-1", "two")
      assert_receive {:run_push, "run-1", "stdout", {:binary, f2}}, 5_000
      {:ok, _, {:cursor, c1}, "one\n"} = Arbiter.Nodes.StdoutFrame.decode(f1)
      {:ok, _, {:cursor, c2}, "two\n"} = Arbiter.Nodes.StdoutFrame.decode(f2)

      assert :ok = Backend.K8s.resume(%{"run-1" => c1})
      assert :ok = Backend.K8s.attach_all([])
      assert_receive {:run_push, "run-1", "stdout", {:binary, ^f2}}, 5_000
      refute_receive {:run_push, "run-1", "stdout", _}, 100

      assert :ok = Backend.K8s.ack("run-1", c2)
      assert :ok = Backend.K8s.ack("run-9", c2)
      assert :ok = Backend.K8s.attach_all([])
      refute_receive {:run_push, "run-1", "stdout", _}, 100
    end

    test "collect asks the run's snapshotter for a checkpoint over the pod channel", _env do
      now = DateTime.utc_now()
      ca = Cert.ca(DateTime.add(now, -60), DateTime.add(now, 86_400))
      start_supervised!({PodChannel.Runs, ca: ca})
      spec = Fx.run_spec()
      {:ok, _nonce} = PodChannel.Runs.register(spec, DateTime.add(now, 3600))

      assert :ok = Backend.K8s.collect(spec.run, kind: "checkout")
      assert {:ok, [%{"op" => "checkpoint"}]} = PodChannel.Runs.await_commands(spec.run, 0)
      assert {:error, :not_found} = Backend.K8s.collect("run-9", kind: "checkout")
      assert {:error, {:unsupported_kind, "x"}} = Backend.K8s.collect(spec.run, kind: "x")
    end

    test "reap is the controller's sweeper, install-scoped", env do
      assert %{containers: [], pods: [], dirs: []} =
               Backend.K8s.reap(%{
                 config: env.config,
                 request: %{install: "inst-1", live_set: []},
                 opts: []
               })

      assert {:error, :install_mismatch} =
               Backend.K8s.reap(%{
                 config: env.config,
                 request: %{install: "other", live_set: []},
                 opts: []
               })
    end
  end
end
