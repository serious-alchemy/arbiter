defmodule Arbiter.NodeAgent.K8s.QuotaTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.ControllerConfig
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
    test "a pod costs the worker plus the seed and snapshotter at services_resources" do
      d = demand()
      assert d["pods"] == 1
      # worker 1 cpu + 2 x 100m
      assert d["requests.cpu"] == 1200
      # 2Gi + 2 x 256Mi
      assert d["requests.memory"] == 2 * 1_073_741_824 + 2 * 256 * 1_048_576
      assert d["requests.ephemeral-storage"] == 4 * 1_073_741_824
      # worker limit 2 cpu; the services set no cpu limit
      assert d["limits.cpu"] == 2000
      assert d["limits.memory"] == 4 * 1_073_741_824 + 2 * 512 * 1_048_576
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
