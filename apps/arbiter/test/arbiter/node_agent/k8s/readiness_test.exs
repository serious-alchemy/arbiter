defmodule Arbiter.NodeAgent.K8s.ReadinessTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Readiness
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.K8sPodFixtures, as: Fx

  @now ~U[2026-10-10 12:00:00Z]

  setup do
    cluster = FakeK8sApi.start!(namespace: "arbiter-workers")
    FakeK8sApi.set_clock(cluster.api, @now)
    FakeK8sApi.enforce_psa(cluster.api)
    FakeK8sApi.put_quota(cluster.api, quota())
    cluster
  end

  defp quota(used \\ %{}) do
    hard = %{
      "pods" => "6",
      "requests.cpu" => "6",
      "requests.memory" => "12Gi",
      "limits.cpu" => "12",
      "limits.memory" => "24Gi",
      "requests.ephemeral-storage" => "24Gi"
    }

    %{
      "metadata" => %{"name" => "arbiter-workers"},
      "spec" => %{"hard" => hard},
      "status" => %{"hard" => hard, "used" => used}
    }
  end

  defp canary(fields \\ %{}) do
    Map.merge(
      %{outcome: :enforced, open: [], skipped: [], bridge: :open, reason: nil, pull: :ok},
      fields
    )
  end

  defp run(client, canary \\ canary(), config \\ Fx.config(), opts \\ []) do
    client
    |> Readiness.run(
      config,
      canary,
      [image: "#{Fx.registry()}/beam@sha256:#{Fx.digest()}", now_fun: fn -> @now end] ++ opts
    )
    |> Map.new(&{&1["id"], &1})
  end

  test "a healthy, locked-down cluster is all ok", %{client: client} do
    checks = run(client)

    assert Map.keys(checks) |> Enum.sort() ==
             ~w(clock priority_class psa quota registry_pull runtime_class)

    for {id, check} <- checks, do: assert(check["status"] == "ok", "#{id}: #{inspect(check)}")
    assert Enum.all?(Map.values(checks), &(is_binary(&1["name"]) and is_binary(&1["detail"])))
  end

  describe "psa" do
    test "the probe spec is internally consistent: privileged implies escalation is not false" do
      pod = %{
        "spec" => %{
          "containers" => [
            %{
              "name" => "worker",
              "securityContext" => %{
                "allowPrivilegeEscalation" => false,
                "capabilities" => %{"drop" => ["ALL"]}
              }
            }
          ]
        }
      }

      [worker] = Readiness.psa_probe_pod(pod)["spec"]["containers"]
      sc = worker["securityContext"]
      assert sc["privileged"] == true
      refute sc["allowPrivilegeEscalation"] == false
      refute Map.has_key?(sc, "capabilities")
    end

    test "a namespace that accepts a privileged pod does not enforce restricted" do
      cluster = FakeK8sApi.start!(namespace: "arbiter-workers")
      FakeK8sApi.set_clock(cluster.api, @now)
      FakeK8sApi.put_quota(cluster.api, quota())

      check = run(cluster.client)["psa"]
      assert check["status"] == "warn"
      assert check["detail"] =~ "not enforce"
      assert check["hint"] =~ "pod-security.kubernetes.io/enforce"
    end

    test "the builder's own pod violating Pod Security is a failure", %{client: client, api: api} do
      FakeK8sApi.fail_next(
        api,
        :create,
        {403,
         ~s(pods "x" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false)}
      )

      checks = run(client)
      assert checks["psa"]["status"] == "fail"
      assert checks["psa"]["detail"] =~ "violates PodSecurity"
    end

    test "a pod rejected by something else says so and leaves psa unproven", %{
      client: client,
      api: api
    } do
      FakeK8sApi.fail_next(
        api,
        :create,
        {403,
         ~s(ValidatingAdmissionPolicy 'arbiter-worker-pods' with binding 'b' denied request: no hostPath)}
      )

      checks = run(client)
      assert checks["psa"]["status"] == "warn"
      assert checks["psa"]["detail"] =~ "ValidatingAdmissionPolicy"
    end
  end

  describe "runtime_class" do
    test "none configured is ok and names the shared kernel", %{client: client} do
      check = run(client)["runtime_class"]
      assert check["status"] == "ok"
      assert check["runtime_class"] == nil
      assert check["detail"] =~ "kernel"
    end

    test "a RuntimeClass the cluster does not have is a failure", %{client: client, api: api} do
      FakeK8sApi.fail_next(
        api,
        :create,
        {403, ~s(pods "x" is forbidden: pod rejected: RuntimeClass "gvisor" not found)}
      )

      check = run(client)["runtime_class"]
      assert check["status"] == "fail"
      assert check["detail"] =~ "gvisor"
    end
  end

  describe "runtime_class: a real pod under the class (KH1, bd-27o4ls)" do
    @sandbox_error ~s(Failed to create pod sandbox: can't set spec.hostUsers: false, RuntimeClass handler "runsc" does not support user namespaces)

    defp gvisor,
      do: Fx.config(%{placement: %{runtime_class: "gvisor", runtime_handler: "runsc"}})

    defp probe_opts, do: [sandbox_timeout_ms: 200, poll_ms: 5]

    defp real_creates(api) do
      for %{method: "POST", params: params} = req <- FakeK8sApi.requests(api),
          params["dryRun"] != "All",
          do: Jason.decode!(req.body)
    end

    defp kubelet(status) do
      fn pod -> {Map.put(pod, "status", status), []} end
    end

    defp creating do
      kubelet(%{
        "phase" => "Pending",
        "initContainerStatuses" => [
          %{"name" => "seed", "state" => %{"waiting" => %{"reason" => "PodInitializing"}}}
        ],
        "containerStatuses" => [
          %{"name" => "worker", "state" => %{"waiting" => %{"reason" => "ContainerCreating"}}}
        ]
      })
    end

    test "no class configured creates no real pod", %{client: client, api: api} do
      assert run(client)["runtime_class"]["status"] == "ok"
      assert real_creates(api) == []
    end

    test "a started pod is ok, runs under the class without hostUsers, and is deleted", %{
      client: client,
      api: api
    } do
      FakeK8sApi.on_create(
        api,
        kubelet(%{
          "phase" => "Running",
          "initContainerStatuses" => [
            %{
              "name" => "seed",
              "state" => %{"running" => %{"startedAt" => "2026-10-10T12:00:00Z"}}
            }
          ]
        })
      )

      check = run(client, canary(), gvisor(), probe_opts())["runtime_class"]
      assert check["status"] == "ok"
      assert check["detail"] =~ "gvisor"
      assert check["detail"] =~ "started"
      assert check["runtime_class"] == "gvisor"

      assert [pod] = real_creates(api)
      assert pod["spec"]["runtimeClassName"] == "gvisor"
      refute Map.has_key?(pod["spec"], "hostUsers")

      assert {:ok, %{items: []}} = Arbiter.NodeAgent.K8s.Client.list_pods(client)
    end

    test "a sandbox that cannot be created is an explicit failure naming the kubelet's error", %{
      client: client,
      api: api
    } do
      FakeK8sApi.on_create(api, creating())

      FakeK8sApi.put_event(api, %{
        "type" => "Warning",
        "reason" => "FailedCreatePodSandBox",
        "message" => @sandbox_error
      })

      check = run(client, canary(), gvisor(), probe_opts())["runtime_class"]
      assert check["status"] == "fail"
      assert check["detail"] =~ "sandbox"
      assert check["detail"] =~ "does not support user namespaces"
      assert check["hint"] =~ "RuntimeClass handler"
      assert check["runtime_class"] == "gvisor"

      # the probe pod is deleted whatever happened
      assert {:ok, %{items: []}} = Arbiter.NodeAgent.K8s.Client.list_pods(client)
    end

    test "a class whose handler refuses hostUsers, with no handler named, hints at runtime_handler",
         %{
           client: client,
           api: api
         } do
      FakeK8sApi.on_create(api, creating())

      FakeK8sApi.put_event(api, %{
        "reason" => "FailedCreatePodSandBox",
        "message" => @sandbox_error
      })

      config = Fx.config(%{placement: %{runtime_class: "gvisor"}})
      check = run(client, canary(), config, probe_opts())["runtime_class"]
      assert check["status"] == "fail"
      assert check["hint"] =~ "placement.runtime_handler: runsc"

      # and the pod it created carried hostUsers: false, which is what runsc refused
      assert [%{"spec" => %{"hostUsers" => false}}] = real_creates(api)
    end

    test "a pod that neither starts nor says why is a warning, not a pass", %{
      client: client,
      api: api
    } do
      FakeK8sApi.on_create(api, creating())

      check = run(client, canary(), gvisor(), probe_opts())["runtime_class"]
      assert check["status"] == "warn"
      assert check["detail"] =~ "did not start"
      assert {:ok, %{items: []}} = Arbiter.NodeAgent.K8s.Client.list_pods(client)
    end

    test "events the Role cannot read leave the failure unnamed but still a warning", %{
      client: client,
      api: api
    } do
      FakeK8sApi.on_create(api, creating())
      FakeK8sApi.fail_next(api, :events, 403, 100)

      check = run(client, canary(), gvisor(), probe_opts())["runtime_class"]
      assert check["status"] == "warn"
    end

    test "a RuntimeClass the dry run refused is not probed with a real pod", %{
      client: client,
      api: api
    } do
      FakeK8sApi.fail_next(
        api,
        :create,
        {403, ~s(pods "x" is forbidden: pod rejected: RuntimeClass "gvisor" not found)}
      )

      assert run(client, canary(), gvisor(), probe_opts())["runtime_class"]["status"] == "fail"
      assert real_creates(api) == []
    end
  end

  describe "priority_class" do
    test "a missing PriorityClass is a failure with the fix", %{client: client, api: api} do
      FakeK8sApi.fail_next(
        api,
        :create,
        {403, ~s(pods "x" is forbidden: no PriorityClass with name arbiter-worker was found)}
      )

      check = run(client)["priority_class"]
      assert check["status"] == "fail"
      assert check["detail"] =~ "arbiter-worker"
      assert check["hint"] =~ "PriorityClass"
    end
  end

  describe "quota" do
    test "no ResourceQuota in the namespace is a warning" do
      cluster = FakeK8sApi.start!(namespace: "arbiter-workers")
      FakeK8sApi.set_clock(cluster.api, @now)

      check = run(cluster.client)["quota"]
      assert check["status"] == "warn"
      assert check["detail"] =~ "no ResourceQuota"
    end

    test "headroom is reported", %{client: client} do
      check = run(client)["quota"]
      assert check["status"] == "ok"
      assert check["detail"] =~ "room for"
    end

    test "an exhausted quota is a warning", %{client: client, api: api} do
      FakeK8sApi.put_quota(api, quota(%{"pods" => "6"}))
      check = run(client)["quota"]
      assert check["status"] == "warn"
      assert check["detail"] =~ "no room"
    end

    test "an unreadable quota is a warning, not a crash", %{client: client, api: api} do
      FakeK8sApi.fail_next(api, :quota, 403)
      check = run(client)["quota"]
      assert check["status"] == "warn"
      assert check["detail"] =~ "could not read"
    end
  end

  describe "clock" do
    test "skew within 30 s is ok", %{client: client, api: api} do
      FakeK8sApi.set_clock(api, DateTime.add(@now, 12, :second))
      assert run(client)["clock"]["status"] == "ok"
    end

    test "a skewed API server clock is a warning with the skew", %{client: client, api: api} do
      FakeK8sApi.set_clock(api, DateTime.add(@now, -300, :second))
      check = run(client)["clock"]
      assert check["status"] == "warn"
      assert check["detail"] =~ "300"
    end
  end

  describe "an unreachable API server" do
    test "the clock check names the network cause and the policy fix", %{client: client} do
      client = %{client | base_url: "http://127.0.0.1:1"}
      check = run(client)["clock"]

      assert check["status"] == "warn"
      assert check["detail"] =~ "cannot reach the Kubernetes API server"
      assert check["hint"] =~ "api_cidrs"
    end
  end

  describe "registry_pull" do
    test "a failed pull is a failure with the kubelet's message", %{client: client} do
      check =
        run(client, canary(%{outcome: :inconclusive, pull: {:failed, "denied: requires auth"}}))[
          "registry_pull"
        ]

      assert check["status"] == "fail"
      assert check["detail"] =~ "denied: requires auth"
      assert check["hint"] =~ "image_pull_secrets"
    end

    test "an unknown pull (the canary never ran) is a warning", %{client: client} do
      check =
        run(client, canary(%{outcome: :inconclusive, pull: :unknown, reason: :timeout}))[
          "registry_pull"
        ]

      assert check["status"] == "warn"
    end
  end

  describe "netpol/2" do
    test "enforced is ok and says what was skipped" do
      check = Readiness.netpol(canary(%{skipped: ["foreign"]}), nil)
      assert check["id"] == "netpol"
      assert check["status"] == "ok"
      assert check["detail"] =~ "foreign"
    end

    test "unenforced is a failure naming what connected" do
      check = Readiness.netpol(canary(%{outcome: :unenforced, open: ["internet", "node"]}), nil)
      assert check["status"] == "fail"
      assert check["detail"] =~ "internet"
      assert check["detail"] =~ "node"
      assert check["hint"] =~ "NetworkPolicy"
    end

    test "a closed bridge path is a warning even though the policy is enforced" do
      check = Readiness.netpol(canary(%{bridge: :closed}), nil)
      assert check["status"] == "warn"
      assert check["detail"] =~ "bridge"
    end

    test "inconclusive is a failure that says nothing was proven" do
      check = Readiness.netpol(canary(%{outcome: :inconclusive, reason: :timeout}), nil)
      assert check["status"] == "fail"
      assert check["detail"] =~ "not proven"
    end

    test "no canary has run yet is a failure (fail closed)" do
      check = Readiness.netpol(nil, nil)
      assert check["status"] == "fail"
      assert check["detail"] =~ "not run yet"
    end
  end
end
