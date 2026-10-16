defmodule ArbiterWeb.RemoteClusterTest do
  @moduledoc """
  K14 (bd-54nxyr, `docs/design/remote-workers.md` K§2.4, K§3.2): a Kubernetes cluster node
  end to end across the real halves. The primary is real: `NodeController`
  (`/nodes/enroll`, `/nodes/cluster`), `NodeSocket`/`NodeChannel` over a Bandit listener,
  the node's `Session`, `Executor.Node`. The agent is real too: `Arbiter.NodeAgent.Supervisor`
  with `ARB_AGENT_BACKEND=k8s` boots `K8s.Boot`, which enrols with the operator's join
  token, starts the controller (`K8s.NodeTree`) and connects.

  The Kubernetes API server is `Arbiter.Test.FakeK8sApi`. **Nothing here touches a real
  cluster** (no kubeconfig is read; the `:k8s`-tagged suite is the real-cluster one).
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Lease
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{InstallId, Overview, RateLimit, Registry, Session}
  alias Arbiter.Settings
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.K8sPodFixtures, as: Fx
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias ArbiterWeb.NodeTestEndpoint

  # The primary's version, and the deployed release `NodeFixtures.install_release!/1` names.
  @version "9.9.9"
  @release "v9.9.9"
  @canary_image "#{Fx.registry()}/beam@sha256:#{Fx.digest()}"

  @all_closed """
  probe api closed
  probe controller_port closed
  probe foreign closed
  probe internet closed
  probe node closed
  probe bridge open
  canary done
  """

  setup %{tmp_dir: tmp_dir} do
    data = Path.join(tmp_dir, "data")
    ArbiterWeb.NodeFixtures.use_data_home!(data)
    ArbiterWeb.NodeFixtures.install_release!(data)
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)
    url = "http://127.0.0.1:#{NodeTestEndpoint.port()}"

    {:ok, _} = Settings.set_nodes_public_url(url)
    {:ok, _} = Settings.set_nodes_registry(Fx.registry())

    on_exit(fn ->
      Settings.set_nodes_public_url(nil)
      Settings.set_nodes_registry(nil)
    end)

    {:ok, %{token: join}} =
      Nodes.mint_join_token([kind: "cluster", name: "k3s-e2e"], "operator:test")

    home = Path.join(System.tmp_dir!(), "rc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    token_file = Path.join(home, "token")
    File.write!(token_file, join <> "\n")
    config_path = Path.join(home, "controller.yaml")
    File.write!(config_path, "max_concurrent: 2\n")

    cluster = cluster!()

    %{
      url: url,
      home: home,
      token_file: token_file,
      config_path: config_path,
      api: cluster.api,
      client: cluster.client
    }
  end

  defp put_env_restoring(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  # What the install's manifests leave in the namespace (K9): the placeholders the
  # controller fills, its Service, Deployment and Lease, and a ResourceQuota.
  defp cluster! do
    cluster = FakeK8sApi.start!(namespace: "arbiter-workers")
    FakeK8sApi.enforce_psa(cluster.api)
    api = cluster.api
    FakeK8sApi.set_clock(api, DateTime.utc_now())

    for name <- ~w(arbiter-node-credential arbiter-controller-ca),
        do: FakeK8sApi.put_secret(api, %{"metadata" => %{"name" => name}, "type" => "Opaque"})

    FakeK8sApi.put_config_map(api, %{"metadata" => %{"name" => "arbiter-ca"}})

    FakeK8sApi.put_service(api, %{
      "metadata" => %{"name" => "arbiter-controller"},
      "spec" => %{"clusterIP" => "127.0.0.1"}
    })

    FakeK8sApi.put_deployment(api, %{
      "metadata" => %{
        "name" => "arbiter-controller",
        "uid" => "5f0c2a1e-1111-4222-8333-444455556666"
      },
      "spec" => %{
        "template" => %{
          "spec" => %{
            "containers" => [
              %{"name" => "controller", "image" => "#{Fx.registry()}/controller:1.0.0"}
            ]
          }
        }
      }
    })

    FakeK8sApi.put_lease(api, %{"metadata" => %{"name" => "arbiter-controller"}, "spec" => %{}})
    put_quota(api, %{})

    # The kubelet's part: a canary pod runs to completion with every probe closed but the
    # bridge; a worker pod stays as created (unscheduled) until a test moves it.
    FakeK8sApi.on_create(api, fn pod ->
      if get_in(pod, ["metadata", "labels", "arbiter.dev/canary"]),
        do:
          {Map.put(pod, "status", %{"phase" => "Succeeded"}),
           String.split(@all_closed, "\n", trim: true)},
        else: {pod, []}
    end)

    cluster
  end

  defp put_quota(api, used) do
    hard = %{"pods" => "8", "requests.cpu" => "16", "requests.memory" => "64Gi"}

    FakeK8sApi.put_quota(api, %{
      "metadata" => %{"name" => "arbiter-workers"},
      "spec" => %{"hard" => hard},
      "status" => %{"hard" => hard, "used" => used}
    })
  end

  defp boot_agent(ctx, opts \\ []) do
    readiness = [interval_ms: nil, poll_ms: 5, timeout_ms: 2_000]

    controller_supervisor =
      [listen_port: 0, targets: %{api: "10.43.0.1:443"}, readiness: readiness] ++
        if(opts[:canary_from_primary], do: [], else: [image: @canary_image])

    start_supervised!(
      {Arbiter.NodeAgent.Supervisor,
       [
         env: %{
           "ARB_AGENT_BACKEND" => "k8s",
           "ARB_PRIMARY_URL" => ctx.url,
           "ARB_NODE_NAME" => "k3s-e2e",
           "ARB_K8S_SELF_UPGRADE" => "true",
           "KUBERNETES_SERVICE_HOST" => "10.43.0.1",
           "KUBERNETES_SERVICE_PORT" => "443",
           "HOSTNAME" => "arbiter-controller-6d9c7-x2b4q"
         },
         app_config: [],
         node_home: ctx.home,
         version: Keyword.get(opts, :version, @version),
         k8s_client: ctx.client,
         token_file: ctx.token_file,
         backoff: [base: 20, max: 80],
         tree: [
           config_loader: [path: ctx.config_path, interval_ms: nil],
           informer: [backoff_ms: {5, 20}],
           pod_channel: [ip: {127, 0, 0, 1}, bridge_port: 0, boot_port: 0],
           controller_supervisor: controller_supervisor
         ]
       ]}
    )

    assert_receive {:node_state, node_id, :online}, 15_000
    node_id
  end

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # The agent heartbeats every 10 s (the primary's fixed interval); a test that needs the
  # next one now sends the connection the timer message it would get.
  defp heartbeat_now, do: send(Arbiter.NodeAgent.Connection, :heartbeat)

  defp spec(run, overrides \\ %{}) do
    Fx.wire_spec(
      Map.merge(
        %{
          "run" => run,
          "name" => "arb-#{run}",
          "install" => InstallId.get(),
          "image" => %{"tag" => "arbiter-dev/beam:abc", "plan" => nil, "ref" => @canary_image}
        },
        overrides
      )
    )
  end

  defp lease_held!, do: wait_until(fn -> Lease.held?(Lease) end)

  describe "boot and hello" do
    test "enrols over the real join flow, connects, and is listed as a cluster node", ctx do
      node_id = boot_agent(ctx)

      node = Nodes.get_node(node_id)
      assert node.kind == "cluster"
      assert node.name == "k3s-e2e"

      # The credential lives in the cluster's Secret, and it is the one the node uses.
      stored = FakeK8sApi.secret(ctx.api, "arbiter-node-credential")["data"]["credential"]
      assert "arbn_" <> _ = credential = Base.decode64!(stored)
      assert String.starts_with?(credential, "arbn_#{node_id}.")

      snapshot = Session.snapshot(node_id)
      assert snapshot.kind == "cluster"
      assert snapshot.k8s_version == "v1.31.2+fake"

      assert %{
               "backend" => "k8s",
               "image" => "registry",
               "limits" => "pod",
               "upgrade" => "image",
               "self_upgrade" => true,
               "namespace" => "arbiter-workers"
             } = snapshot.caps

      # The ConfigMap's max_concurrent is the node's ceiling, hence its effective cap.
      assert snapshot.capacity["ceiling"] == 2
      assert snapshot.max_workers == 2

      assert %{kind: :cluster} = Overview.get(node_id)
    end

    test "a restarted controller reads its Secret: same node, no second enrolment", ctx do
      node_id = boot_agent(ctx)
      stop_supervised!(Arbiter.NodeAgent.Supervisor)
      # The join token is spent: only the stored credential can bring the node back.
      assert boot_agent(ctx) == node_id
      assert length(Nodes.list_nodes()) == 1
    end
  end

  describe "hb, capacity and the canary" do
    test "the canary's verdict reaches the primary, and so does a ConfigMap change", ctx do
      node_id = boot_agent(ctx)

      # Fail closed until the canary has proven the policies; then the controller pushes
      # the verdict and the node is placeable.
      wait_until(fn -> Session.snapshot(node_id).degraded == [] end)

      assert %{readiness: [%{"id" => "netpol", "status" => "ok"} | _]} =
               Session.snapshot(node_id)

      File.write!(ctx.config_path, "max_concurrent: 3\n")
      ConfigLoader.reload(ConfigLoader)
      assert_receive {:node_capacity, ^node_id, %{"ceiling" => 3}}, 5_000
      assert Session.snapshot(node_id).max_workers == 3
    end

    test "with no image to run the canary on, the node stays degraded (fail closed)", ctx do
      node_id = boot_agent(ctx, canary_from_primary: true)

      # The primary has published neither a worker nor a controller image.
      wait_until(fn ->
        match?(
          %{readiness: [%{"id" => "netpol", "detail" => "not proven" <> _} | _]},
          Session.snapshot(node_id)
        )
      end)

      assert %{degraded: ["netpol_unenforced"], readiness: [netpol | _]} =
               Session.snapshot(node_id)

      assert netpol["detail"] =~ "not_published"
    end
  end

  describe "runs" do
    test "a pod is pending in hb, and the assign is answered once the worker runs", ctx do
      node_id = boot_agent(ctx)
      lease_held!()
      me = self()
      task = Task.async(fn -> Executor.prepare(%{id: node_id}, spec("run-e1"), owner: me) end)

      wait_until(fn -> FakeK8sApi.handle(ctx.api, {:get, "arb-run-e1"}) != nil end)
      heartbeat_now()
      wait_until(fn -> Session.run_stage(Registry.lookup(node_id), "run-e1") == :pending end)

      pod = FakeK8sApi.handle(ctx.api, {:get, "arb-run-e1"})

      FakeK8sApi.put_pod(
        ctx.api,
        Map.put(pod, "status", %{
          "phase" => "Running",
          "podIP" => "10.42.0.9",
          "conditions" => [%{"type" => "PodScheduled", "status" => "True"}],
          "containerStatuses" => [%{"name" => "worker", "state" => %{"running" => %{}}}]
        })
      )

      assert {:ok, %{run: "run-e1", node_id: ^node_id}} = Task.await(task, 15_000)
      assert Session.run_started?(Registry.lookup(node_id), "run-e1")
    end

    test "a spec the pod builder cannot represent is refused bad_spec", ctx do
      node_id = boot_agent(ctx)
      lease_held!()

      outside = %{
        "tag" => "x",
        "plan" => nil,
        "ref" => "docker.io/library/alpine@sha256:#{Fx.digest()}"
      }

      assert {:error, {:refused, "bad_spec", detail}} =
               Executor.prepare(%{id: node_id}, spec("run-e2", %{"image" => outside}),
                 owner: self()
               )

      assert detail =~ "image"
    end

    test "no ResourceQuota headroom is refused no_capacity: a hold, not a failure", ctx do
      node_id = boot_agent(ctx)
      lease_held!()
      put_quota(ctx.api, %{"pods" => "8"})

      assert {:error, {:refused, "no_capacity", detail}} =
               Executor.prepare(%{id: node_id}, spec("run-e3"), owner: self())

      assert detail =~ "ResourceQuota"
      assert FakeK8sApi.handle(ctx.api, {:get, "arb-run-e3"}) == nil
    end
  end

  # K15: a cluster run's output, its exit, and a controller restart, against the real
  # primary session and the real pod channel (the fake API server is the kubelet).
  describe "run completeness (K15)" do
    @pod_ip "10.42.0.9"

    defp pod_status(ctx, name, worker, snapshotter) do
      pod = FakeK8sApi.handle(ctx.api, {:get, name})

      FakeK8sApi.put_pod(
        ctx.api,
        Map.put(pod, "status", %{
          "phase" => if(worker == :running, do: "Running", else: "Succeeded"),
          "podIP" => @pod_ip,
          "conditions" => [%{"type" => "PodScheduled", "status" => "True"}],
          "containerStatuses" => [
            %{
              "name" => "worker",
              "state" =>
                if(worker == :running,
                  do: %{"running" => %{}},
                  else: %{"terminated" => %{"exitCode" => 0, "reason" => "Completed"}}
                )
            }
          ],
          "initContainerStatuses" => [
            %{"name" => "seed", "state" => %{"terminated" => %{"exitCode" => 0}}},
            %{
              "name" => "snapshotter",
              "state" =>
                if(snapshotter == :running,
                  do: %{"running" => %{}},
                  else: %{"terminated" => %{"exitCode" => 0, "reason" => "Completed"}}
                )
            }
          ]
        })
      )
    end

    defp place!(ctx, node_id, run, overrides \\ %{}) do
      me = self()

      task =
        Task.async(fn -> Executor.prepare(%{id: node_id}, spec(run, overrides), owner: me) end)

      name = "arb-" <> run
      wait_until(fn -> FakeK8sApi.handle(ctx.api, {:get, name}) != nil end)
      pod_status(ctx, name, :running, :running)
      assert {:ok, %{handle: handle}} = Task.await(task, 15_000)
      handle
    end

    test "the worker's log reaches its owner, and the exit waits for the final checkpoint",
         ctx do
      node_id = boot_agent(ctx)
      lease_held!()
      handle = place!(ctx, node_id, "run-s1")

      FakeK8sApi.push_log(ctx.api, "arb-run-s1", "hello from the pod")
      assert_receive {^handle, {:data, {:eol, "hello from the pod"}}}, 10_000
      FakeK8sApi.push_log(ctx.api, "arb-run-s1", "second line")
      assert_receive {^handle, {:data, {:eol, "second line"}}}, 10_000

      # the worker ends; the snapshotter is still forwarding the final checkpoint
      FakeK8sApi.push_log(ctx.api, "arb-run-s1", "the last line")
      pod_status(ctx, "arb-run-s1", :exited, :running)
      refute_receive {^handle, {:outcome, _}}, 400

      pod_status(ctx, "arb-run-s1", :exited, :complete)
      assert_receive {^handle, {:data, {:eol, "the last line"}}}, 10_000
      assert_receive {^handle, {:outcome, %{exit_code: 0, oom?: false}}}, 10_000
      assert_receive {^handle, {:exit_status, 0}}, 10_000

      # the primary has the exit: the controller lets the clean pod go
      wait_until(fn -> FakeK8sApi.handle(ctx.api, {:get, "arb-run-s1"}) == nil end)
    end

    test "a run with no output still ends", ctx do
      node_id = boot_agent(ctx)
      lease_held!()
      handle = place!(ctx, node_id, "run-s2")
      pod_status(ctx, "arb-run-s2", :exited, :complete)
      assert_receive {^handle, {:outcome, %{exit_code: 0}}}, 10_000
    end

    test "after a controller restart the adopted pod's bridges work again and its output resumes",
         ctx do
      alias Arbiter.NodeAgent.PodChannel.Runs

      node_id = boot_agent(ctx)
      lease_held!()

      bridges = [%{"name" => "proxy", "path" => "/var/lib/arb/run/sockets/proxy.sock"}]
      handle = place!(ctx, node_id, "run-s3", %{"bridges" => bridges})
      ip = {10, 42, 0, 9}

      # what `/boot` gave the pod: its leaves, read back out of the tar
      pod = FakeK8sApi.handle(ctx.api, {:get, "arb-run-s3"})
      nonce = pod_env(pod, "ARB_BOOT_NONCE")
      wait_until(fn -> match?({:ok, _, _}, peek_redeem(nonce, ip)) end)
      {:ok, files} = :erl_tar.extract({:binary, redeemed_tar!()}, [:memory])
      files = Map.new(files, fn {n, b} -> {to_string(n), b} end)
      [{:Certificate, proxy, _}] = :public_key.pem_decode(files["tls/proxy.crt"])
      [{:Certificate, control, _}] = :public_key.pem_decode(files["tls/control.crt"])

      assert {:ok, %{run: "run-s3", name: "proxy"}} = Runs.authorize(Runs, :bridge, proxy, ip)

      FakeK8sApi.push_log(ctx.api, "arb-run-s3", "before the restart")
      assert_receive {^handle, {:data, {:eol, "before the restart"}}}, 10_000

      # the controller restarts: every process of the tree, the pod channel's run table with it
      old = Process.whereis(Runs)
      Process.exit(Process.whereis(Arbiter.NodeAgent.PodChannel), :kill)
      wait_until(fn -> (pid = Process.whereis(Runs)) != nil and pid != old end)
      wait_until(fn -> "run-s3" in live_runs() end)

      # the same leaves, from the same pod, are let in as before; nothing else is
      assert {:ok, %{run: "run-s3", name: "proxy"}} = Runs.authorize(Runs, :bridge, proxy, ip)
      assert {:ok, %{run: "run-s3"}} = Runs.authorize(Runs, :control, control, ip)
      assert {:error, :wrong_ip} = Runs.authorize(Runs, :bridge, proxy, {10, 42, 0, 99})
      assert :ok = Arbiter.NodeAgent.PodChannel.push_command("run-s3", %{"op" => "checkpoint"})

      # and the output carries on after what the owner already has, with no replay
      wait_until(fn -> Session.run_started?(Registry.lookup(node_id), "run-s3") end)
      FakeK8sApi.push_log(ctx.api, "arb-run-s3", "after the restart")
      assert_receive {^handle, {:data, {:eol, "after the restart"}}}, 15_000
      refute_received {^handle, {:data, {:eol, "before the restart"}}}
      refute_received {^handle, {:outcome, _}}
    end

    defp pod_env(pod, name) do
      pod["spec"]["initContainers"]
      |> Enum.flat_map(&(&1["env"] || []))
      |> Enum.find_value(fn
        %{"name" => ^name, "value" => value} -> value
        _ -> nil
      end)
    end

    # `Runs.redeem/3` spends the nonce, so the tar is kept from the first success.
    defp peek_redeem(nonce, ip) do
      result =
        Arbiter.NodeAgent.PodChannel.Runs.redeem(Arbiter.NodeAgent.PodChannel.Runs, nonce, ip)

      with {:ok, _run, tar} <- result, do: Process.put(:redeemed_tar, tar)
      result
    end

    defp redeemed_tar!, do: Process.get(:redeemed_tar)

    defp live_runs do
      Arbiter.NodeAgent.PodChannel.Runs.live_runs(Arbiter.NodeAgent.PodChannel.Runs)
    catch
      :exit, _ -> []
    end
  end

  describe "self-upgrade" do
    test "an outdated cluster node patches its own Deployment to this primary's image", ctx do
      node_id = boot_agent(ctx, version: "1.0.0")

      assert Session.snapshot(node_id).health == :outdated
      image = "#{Fx.registry()}/controller:#{@release}"

      wait_until(fn ->
        containers =
          FakeK8sApi.deployment(ctx.api, "arbiter-controller")["spec"]["template"]["spec"][
            "containers"
          ]

        match?([%{"name" => "controller", "image" => ^image}], containers)
      end)

      # It reports that it can patch itself, so no `kubectl set image` is shown for it.
      assert %{upgrade_command: nil, self_upgrade?: true} = Overview.get(node_id)
    end
  end
end
