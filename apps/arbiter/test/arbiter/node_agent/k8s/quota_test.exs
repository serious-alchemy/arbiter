defmodule Arbiter.NodeAgent.K8s.QuotaTest do
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures, only: [build!: 0]

  alias Arbiter.NodeAgent.K8s.ControllerConfig
  alias Arbiter.NodeAgent.K8s.InstallManifest
  alias Arbiter.NodeAgent.K8s.Quota

  # The design's §4.3 quota for max_concurrent 2.
  defp quota(hard, used \\ %{}) do
    %{
      "metadata" => %{"name" => "arbiter-workers"},
      "spec" => %{"hard" => hard},
      "status" => %{"hard" => hard, "used" => used}
    }
  end

  @design_hard %{
    "pods" => "4",
    "requests.cpu" => "3",
    "requests.memory" => "6Gi",
    "limits.cpu" => "6",
    "limits.memory" => "10Gi",
    "requests.ephemeral-storage" => "12Gi"
  }

  defp demand do
    {:ok, cfg} = ControllerConfig.parse("{}")
    Quota.demand(cfg)
  end

  describe "demand/1" do
    test "a pod is the worker plus the snapshotter sidecar; the seed init counts only as a max" do
      d = demand()
      assert d["pods"] == 1
      # worker 1 cpu + the snapshotter's 100m (seed's 100m runs before it, alone)
      assert d["requests.cpu"] == 1100
      assert d["requests.memory"] == 2 * 1_073_741_824 + 256 * 1_048_576
      # worker 4Gi + the snapshotter's LimitRange defaultRequest of 128Mi
      assert d["requests.ephemeral-storage"] == 4 * 1_073_741_824 + 128 * 1_048_576
      # worker limit 2 cpu + the LimitRange default 500m for the snapshotter
      assert d["limits.cpu"] == 2500
      assert d["limits.memory"] == 4 * 1_073_741_824 + 512 * 1_048_576
    end

    test "effective_pod/1 on a real PodSpec pod never exceeds demand/1 (a run may clamp the limits)" do
      real = Quota.effective_pod(build!())

      for {name, per_pod} <- demand() do
        assert real[name] <= per_pod, name
      end

      # the snapshotter's defaulted 500m sits on top of the worker's cpu limit
      worker_cpu =
        build!()["spec"]["containers"] |> hd() |> get_in(["resources", "limits", "cpu"])

      {:ok, worker_m} = Arbiter.NodeAgent.K8s.Quantity.cpu(worker_cpu, :k8s)
      assert real["limits.cpu"] == worker_m + 500
    end
  end

  describe "the install quota fits max_concurrent worker pods plus the controller" do
    @server [image: "img:1", primary_url: "https://arbiter.example.test", registry: "r.test/a"]

    for reach <- ~w(direct tailscale), n <- [1, 2, 5, 40] do
      test "reach=#{reach} max_concurrent=#{n}" do
        {:ok, spec} =
          InstallManifest.parse(%{
            "reach" => unquote(reach),
            "max" => to_string(unquote(n)),
            "primary_cidrs" => "100.64.0.10/32",
            "name" => "node-1"
          })

        %{bootstrap: bootstrap, node: node} = InstallManifest.documents(spec, @server)
        hard = Enum.find(bootstrap, &(&1["kind"] == "ResourceQuota"))["spec"]["hard"]
        deployment = Enum.find(node, &(&1["kind"] == "Deployment"))
        controller = Quota.effective_pod(deployment["spec"]["template"])
        worker = Quota.effective_pod(build!())

        for {name, limit} <- hard do
          total = unquote(n) * Map.get(worker, name, 0) + Map.get(controller, name, 0)
          assert total <= Quota.parse_quantity(name, limit), "#{name}: #{total} > #{limit}"
        end
      end
    end

    test "n=2 with tailscale sizes limits.cpu at 6500m" do
      {:ok, spec} =
        InstallManifest.parse(%{"reach" => "tailscale", "max" => "2", "name" => "n1"})

      %{bootstrap: bootstrap} = InstallManifest.documents(spec, @server)
      quota = Enum.find(bootstrap, &(&1["kind"] == "ResourceQuota"))
      assert quota["spec"]["hard"]["limits.cpu"] == "6500m"
    end
  end

  describe "headroom/2" do
    test "an unused quota: the tightest resource decides" do
      # cpu requests: 3000 / 1200 = 2; memory 6Gi / 2.5Gi = 2; pods 4; eph 12Gi/4Gi = 3
      assert Quota.headroom([quota(@design_hard)], demand()) == 2
    end

    test "usage is subtracted" do
      used = %{"pods" => "1", "requests.cpu" => "1200m", "requests.memory" => "2560Mi"}
      assert Quota.headroom([quota(@design_hard, used)], demand()) == 1
    end

    test "no room for one more pod is zero, never negative" do
      used = %{"requests.cpu" => "3"}
      assert Quota.headroom([quota(@design_hard, used)], demand()) == 0

      over = %{"requests.cpu" => "9"}
      assert Quota.headroom([quota(@design_hard, over)], demand()) == 0
    end

    test "the pods count alone can be the limit" do
      hard = %{"pods" => "2"}
      assert Quota.headroom([quota(hard, %{"pods" => "2"})], demand()) == 0
      assert Quota.headroom([quota(hard, %{"pods" => "1"})], demand()) == 1
    end

    test "a quota that names none of our resources does not bound us" do
      assert Quota.headroom([quota(%{"secrets" => "10"})], demand()) == :unbounded
      assert Quota.headroom([], demand()) == :unbounded
    end

    test "several quotas: the smallest headroom wins" do
      assert Quota.headroom([quota(%{"pods" => "10"}), quota(%{"pods" => "1"})], demand()) == 1
    end

    test "the unprefixed names are the request names; count/pods is pods" do
      assert Quota.headroom([quota(%{"cpu" => "2400m"})], demand()) == 2
      assert Quota.headroom([quota(%{"count/pods" => "3"})], demand()) == 3
    end

    test "falls back to spec.hard when the status is not populated yet" do
      q = %{"spec" => %{"hard" => %{"pods" => "5"}}}
      assert Quota.headroom([q], demand()) == 5
    end

    test "a zero hard limit is zero headroom (and parses)" do
      assert Quota.headroom([quota(%{"requests.cpu" => "0"})], demand()) == 0
    end

    test "an unparsable quantity is treated as no room, not as unbounded" do
      assert Quota.headroom([quota(%{"requests.cpu" => "lots"})], demand()) == 0
    end
  end
end
