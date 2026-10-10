defmodule Arbiter.NodeAgent.K8s.ControllerConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.ControllerConfig
  alias Arbiter.NodeAgent.K8s.PodConfig

  @full """
  max_concurrent: 3
  namespace: arbiter-workers
  worker:
    requests: {cpu: "1", memory: 2Gi, ephemeral-storage: 4Gi}
    limits: {cpu: "2", memory: 4Gi}
    work_size_limit: 8Gi
    tmp_size_limit: 1Gi
  services_resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 512Mi}}
  placement:
    node_selector: {kubernetes.io/hostname: mesanna}
    tolerations: []
    priority_class: arbiter-worker
    runtime_class: ""
  image_pull_secrets: [gitlab-registry]
  timeouts: {schedule_s: 30, pull_s: 600, boot_s: 120, grace_s: 90, retain_failed_s: 300}
  snapshot_interval_s: 300
  """

  describe "parse/1" do
    test "the design's example file loads" do
      assert {:ok, cfg} = ControllerConfig.parse(@full)
      assert cfg.max_concurrent == 3
      assert cfg.namespace == "arbiter-workers"
      assert cfg.timeouts["schedule_s"] == 30
      assert cfg.timeouts["grace_s"] == 90
      assert cfg.image_pull_secrets == ["gitlab-registry"]
      assert cfg.placement["node_selector"] == %{"kubernetes.io/hostname" => "mesanna"}
    end

    test "an empty file is the defaults: ceiling 2, every timeout filled" do
      assert {:ok, cfg} = ControllerConfig.parse("{}")
      assert cfg.max_concurrent == 2

      assert %{
               "schedule_s" => 120,
               "pull_s" => 600,
               "boot_s" => 120,
               "grace_s" => 120,
               "retain_failed_s" => 300
             } = cfg.timeouts
    end

    test "a partial timeouts map keeps the defaults of the rest" do
      assert {:ok, cfg} = ControllerConfig.parse("timeouts: {schedule_s: 5}")
      assert cfg.timeouts["schedule_s"] == 5
      assert cfg.timeouts["pull_s"] == 600
    end

    test "unknown top-level keys are refused" do
      assert {:error, {:bad_config, {:unknown_key, "securityContext"}}} =
               ControllerConfig.parse("securityContext: {privileged: true}")
    end

    test "the controller's own facts are not operator-settable" do
      for key <- ~w(registry install_id node_id owner_uid boot_nonce bridge_addr image) do
        assert {:error, {:bad_config, {:unknown_key, ^key}}} =
                 ControllerConfig.parse("#{key}: whatever")
      end
    end

    test "unknown nested keys are refused" do
      assert {:error, {:bad_config, _}} = ControllerConfig.parse("timeouts: {sched_s: 5}")
      assert {:error, {:bad_config, _}} = ControllerConfig.parse("worker: {privileged: true}")
    end

    test "max_concurrent must be a positive integer" do
      for bad <- ["0", "-1", "two", "1.5", "[]"] do
        assert {:error, {:bad_config, _}} = ControllerConfig.parse("max_concurrent: #{bad}")
      end
    end

    test "invalid YAML and non-maps are errors, never raises" do
      assert {:error, {:bad_config, {:yaml, _}}} = ControllerConfig.parse("a: [unclosed")
      assert {:error, {:bad_config, :not_a_map}} = ControllerConfig.parse("- a\n- b")
      assert {:error, {:bad_config, :not_a_map}} = ControllerConfig.parse("just a string")
    end

    test "a bad quantity is refused" do
      assert {:error, {:bad_config, _}} =
               ControllerConfig.parse("worker: {requests: {cpu: lots}}")
    end
  end

  describe "pod_config/2" do
    test "merges the controller's own facts into the operator keys for PodSpec" do
      {:ok, cfg} = ControllerConfig.parse(@full)

      facts = %{
        registry: "registry.example.test/arbiter",
        install_id: "inst-1",
        node_id: "node-1",
        owner_uid: "0b6c1d7e",
        bridge_addr: "10.43.98.199",
        gate_addr: "10.43.0.1:443",
        boot_nonce: String.duplicate("n", 43),
        max_wall_s: 3600
      }

      pod = ControllerConfig.pod_config(cfg, facts)
      assert pod.namespace == "arbiter-workers"
      assert pod.install_id == "inst-1"
      refute Map.has_key?(pod, :max_concurrent)
      assert {:ok, _} = PodConfig.normalize(pod)
    end
  end
end
