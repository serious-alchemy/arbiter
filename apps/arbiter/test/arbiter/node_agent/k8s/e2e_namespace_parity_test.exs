defmodule Arbiter.NodeAgent.K8s.E2ENamespaceParityTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.{InstallManifest, PodSpec}
  alias Arbiter.Test.K8sE2E

  defp kinds(docs), do: Enum.map(docs, &{&1["kind"], &1["metadata"]["name"]})

  test "the e2e namespace carries what the install manifest and pod spec require" do
    objects = K8sE2E.base_objects("arb-e2e-x", "arbiter-e2e-x", true)
    present = kinds(objects)

    for want <- [
          {"ServiceAccount", "arbiter-worker"},
          {"ConfigMap", "arbiter-ca"},
          {"LimitRange", "arbiter-workers"},
          {"ResourceQuota", "arbiter-workers"},
          {"Deployment", "arbiter-controller"},
          {"Service", "arbiter-controller"}
        ] do
      assert want in present
    end
  end

  test "quota and LimitRange are the install manifest's, byte for byte" do
    {:ok, spec} = InstallManifest.parse(%{"name" => "e2e", "namespace" => "arb-e2e-x"})

    %{bootstrap: bootstrap} =
      InstallManifest.documents(spec,
        image: K8sE2E.image(),
        primary_url: "https://primary.invalid",
        registry: K8sE2E.registry()
      )

    objects = K8sE2E.base_objects("arb-e2e-x", "arbiter-e2e-x", false)

    for kind <- ["ResourceQuota", "LimitRange", "Namespace"] do
      assert Enum.find(objects, &(&1["kind"] == kind)) ==
               Enum.find(bootstrap, &(&1["kind"] == kind))
    end
  end

  test "the stand-in listener satisfies the quota's limits.cpu" do
    deployment = Enum.find(K8sE2E.base_objects("n", "p", true), &(&1["kind"] == "Deployment"))
    [container] = deployment["spec"]["template"]["spec"]["containers"]
    assert container["resources"]["limits"]["cpu"]
  end

  test "policies: false drops the NetworkPolicies" do
    refute Enum.any?(K8sE2E.base_objects("n", "p", false), &(&1["kind"] == "NetworkPolicy"))
  end

  test "pod_spec still names the objects the helper provides" do
    src = File.read!(Path.join(File.cwd!(), "lib/arbiter/node_agent/k8s/pod_spec.ex"))
    assert src =~ "arbiter-worker"
    assert src =~ "arbiter-ca"
    assert Code.ensure_loaded?(PodSpec)
  end
end
