defmodule Arbiter.NodeAgent.K8s.PodConfigTest do
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures, only: [config: 1]

  alias Arbiter.NodeAgent.K8s.PodConfig

  test "defaults are the design's §4.1 values" do
    assert {:ok, cfg} = PodConfig.normalize(config(%{}))
    assert cfg.namespace == "arbiter-workers"
    assert cfg.worker["limits"] == %{"cpu" => "2", "memory" => "4Gi"}

    assert cfg.worker["requests"] == %{
             "cpu" => "1",
             "memory" => "2Gi",
             "ephemeral-storage" => "4Gi"
           }

    assert cfg.worker["work_size_limit"] == "8Gi"
    assert cfg.worker["tmp_size_limit"] == "1Gi"
    assert cfg.placement["priority_class"] == "arbiter-worker"
    assert cfg.timeouts["grace_s"] == 120
    assert cfg.snapshot_interval_s == 300
  end

  test "a partial nested map keeps the other defaults; atom and string keys both work" do
    assert {:ok, cfg} = PodConfig.normalize(config(%{worker: %{limits: %{memory: "8Gi"}}}))
    assert cfg.worker["limits"] == %{"cpu" => "2", "memory" => "8Gi"}
    assert cfg.worker["requests"]["memory"] == "2Gi"

    assert {:ok, cfg} =
             PodConfig.normalize(config(%{worker: %{"limits" => %{"memory" => "8Gi"}}}))

    assert cfg.worker["limits"]["memory"] == "8Gi"
  end

  test "a keyword list is accepted" do
    assert {:ok, _} = PodConfig.normalize(Map.to_list(config(%{})))
  end

  test "unknown keys are refused at every level" do
    assert {:error, {:bad_config, {:unknown_key, :hostNetwork}}} =
             PodConfig.normalize(config(%{hostNetwork: true}))

    assert {:error, {:bad_config, {:unknown_key, {:worker, "security_context"}}}} =
             PodConfig.normalize(config(%{worker: %{security_context: %{}}}))

    assert {:error, {:bad_config, {:unknown_key, {:resource, "gpu"}}}} =
             PodConfig.normalize(config(%{worker: %{limits: %{gpu: "1"}}}))

    assert {:error, {:bad_config, {:unknown_key, {:placement, "affinity"}}}} =
             PodConfig.normalize(config(%{placement: %{affinity: %{}}}))

    assert {:error, {:bad_config, {:unknown_key, {:timeouts, "forever"}}}} =
             PodConfig.normalize(config(%{timeouts: %{forever: 1}}))
  end

  test "malformed values are bad_config" do
    for {key, value} <- [
          namespace: "Bad_NS",
          registry: "UPPER/case",
          snapshot_interval_s: 5,
          image_pull_secrets: ["ok", "Bad Name"],
          service_image_allowlist: ["no-trailing-slash"],
          placement: %{node_selector: %{"a" => 1}},
          placement: %{tolerations: [%{bogus: "x"}]},
          timeouts: %{grace_s: -1}
        ] do
      assert {:error, {:bad_config, _}} = PodConfig.normalize(config(%{key => value})),
             "#{key}: #{inspect(value)}"
    end
  end

  test "non-maps are refused" do
    assert {:error, {:bad_config, {:not_a_map, :config}}} = PodConfig.normalize("x")
  end
end
