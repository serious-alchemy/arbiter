defmodule Arbiter.NodeAgent.K8s.PodGoldenTest do
  @moduledoc """
  K4 (bd-7m6quu): the built pods as YAML, pinned under `test/fixtures/k8s/`. A
  change to the pod the cluster sees is a change to these files, so it shows up
  in review as a diff instead of passing silently. `ARB_UPDATE_GOLDEN=1 mix test`
  rewrites them after a deliberate change.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures

  alias Arbiter.NodeAgent.K8s.PodSecurity

  @opts [registry: registry(), image_prefixes: ["docker.io/pgsty/"]]

  test "the minimal pod: worktree, home, config dir, tmp, cli and prompt, no bridges or services" do
    pod = build!()
    assert PodSecurity.check(pod, @opts) == :ok
    assert_golden("pod_minimal", golden_yaml(pod))
  end

  test "the full pod: bridges, Postgres and S3 services, placement and a checkout interval" do
    pod =
      build!(
        run_spec(
          Map.merge(with_bridges(), %{
            "services" => [
              %{"preset" => "postgres", "database" => "vstim_test"},
              %{"preset" => "s3"}
            ],
            "checkout" => %{"branch" => "feature/x", "base" => "main", "interval_s" => 120}
          })
        ),
        %{
          service_image_allowlist: ["docker.io/pgsty/"],
          image_pull_secrets: ["gitlab-registry"],
          placement: %{
            node_selector: %{"kubernetes.io/hostname" => "mesanna"},
            tolerations: [
              %{key: "dedicated", operator: "Equal", value: "arbiter", effect: "NoSchedule"}
            ],
            runtime_class: "gvisor"
          }
        }
      )

    assert PodSecurity.check(pod, @opts) == :ok
    assert_golden("pod_full", golden_yaml(pod))
  end

  test "the golden files parse back to the pod that was built" do
    pod = build!()
    assert {:ok, parsed} = YamlElixir.read_from_string(golden_yaml(pod))
    assert parsed == pod
  end
end
