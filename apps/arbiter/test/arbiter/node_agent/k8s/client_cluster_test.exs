defmodule Arbiter.NodeAgent.K8s.ClientClusterTest do
  # The verbs beyond pods that the controller core (K5) needs: ResourceQuota reads
  # (headroom) and the single-active-controller Lease.
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.Test.FakeK8sApi

  setup do
    {:ok, FakeK8sApi.start!()}
  end

  defp lease(name \\ "arbiter-controller") do
    %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => %{"name" => name, "namespace" => "arb"},
      "spec" => %{"leaseDurationSeconds" => 30}
    }
  end

  describe "list_resource_quotas/1" do
    test "returns the namespace's quotas", %{api: api, client: client} do
      FakeK8sApi.put_quota(api, %{
        "metadata" => %{"name" => "arbiter-workers"},
        "spec" => %{"hard" => %{"pods" => "4"}}
      })

      assert {:ok, [%{"metadata" => %{"name" => "arbiter-workers"}}]} =
               Client.list_resource_quotas(client)

      assert [%{method: "GET", path: "/api/v1/namespaces/arb/resourcequotas"}] =
               FakeK8sApi.requests(api)
    end

    test "none is an empty list; a failure is an error, not a crash", %{api: api, client: client} do
      assert {:ok, []} = Client.list_resource_quotas(client)
      FakeK8sApi.fail_next(api, :quota, 500)
      assert {:error, {:http, 500, _}} = Client.list_resource_quotas(client)
    end

    test "403 (RBAC) is reported as forbidden", %{api: api, client: client} do
      FakeK8sApi.fail_next(api, :quota, 403)
      assert {:error, {:forbidden, _}} = Client.list_resource_quotas(client)
    end
  end

  describe "get_lease/2 and update_lease/2" do
    test "reads the pre-created lease", %{api: api, client: client} do
      FakeK8sApi.put_lease(api, lease())
      assert {:ok, %{"metadata" => %{"name" => "arbiter-controller"}}} = Client.get_lease(client, "arbiter-controller")

      assert [%{path: "/apis/coordination.k8s.io/v1/namespaces/arb/leases/arbiter-controller"}] =
               FakeK8sApi.requests(api)
    end

    test "a missing lease is :not_found", %{client: client} do
      assert {:error, :not_found} = Client.get_lease(client, "arbiter-controller")
    end

    test "update PUTs the whole object and returns the new resourceVersion", %{
      api: api,
      client: client
    } do
      FakeK8sApi.put_lease(api, lease())
      {:ok, held} = Client.get_lease(client, "arbiter-controller")
      held = put_in(held, ["spec", "holderIdentity"], "pod-a")

      assert {:ok, updated} = Client.update_lease(client, held)
      assert updated["spec"]["holderIdentity"] == "pod-a"
      assert updated["metadata"]["resourceVersion"] != held["metadata"]["resourceVersion"]
      assert FakeK8sApi.lease(api, "arbiter-controller")["spec"]["holderIdentity"] == "pod-a"
    end

    test "a stale resourceVersion is :conflict (someone else renewed)", %{
      api: api,
      client: client
    } do
      FakeK8sApi.put_lease(api, lease())
      {:ok, held} = Client.get_lease(client, "arbiter-controller")
      FakeK8sApi.put_lease(api, lease())

      assert {:error, :conflict} = Client.update_lease(client, held)
    end
  end
end
