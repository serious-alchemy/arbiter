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

  defp run(client, canary \\ canary()) do
    client
    |> Readiness.run(Fx.config(), canary,
      image: "#{Fx.registry()}/beam@sha256:#{Fx.digest()}",
      now_fun: fn -> @now end
    )
    |> Map.new(&{&1["id"], &1})
  end

  test "a healthy, locked-down cluster is all ok", %{client: client} do
    checks = run(client)

    assert Map.keys(checks) |> Enum.sort() ==
             ~w(clock priority_class psa quota registry_pull)

    for {id, check} <- checks, do: assert(check["status"] == "ok", "#{id}: #{inspect(check)}")
    assert Enum.all?(Map.values(checks), &(is_binary(&1["name"]) and is_binary(&1["detail"])))
  end

  describe "psa" do
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
