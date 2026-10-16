defmodule Arbiter.Nodes.ClusterInstallTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes.ClusterInstall
  alias Arbiter.Settings

  setup do
    {:ok, _} = Settings.set_nodes_public_url("https://arbiter.tail1234.ts.net")
    {:ok, _} = Settings.set_nodes_registry("registry.example.test/arbiter")
    :ok
  end

  @params %{
    "name" => "mesaana-k3s",
    "namespace" => "ci-workers",
    "max" => "3",
    "reach" => "tailscale"
  }

  test "plan/2 gives the manifest URL, the apply command, the join-Secret command and the image" do
    assert {:ok, plan} = ClusterInstall.plan(@params, version: "0.2.43")

    assert plan.manifest_url ==
             "https://arbiter.tail1234.ts.net/nodes/join/k8s.yaml?" <>
               "name=mesaana-k3s&namespace=ci-workers&max=3&reach=tailscale"

    assert plan.apply_command == ~s|kubectl apply -f <(curl -fsSL "#{plan.manifest_url}")|

    assert plan.secret_command ==
             "read -rs T && printf %s \"$T\" | kubectl -n ci-workers create secret generic " <>
               "arbiter-join --from-file=token=/dev/stdin"

    assert plan.image == "registry.example.test/arbiter/controller:0.2.43"
    assert plan.namespace == "ci-workers"
  end

  test "no token ever reaches a URL or command: only the known form keys are carried" do
    assert {:ok, plan} =
             ClusterInstall.plan(
               Map.merge(@params, %{"token" => "arbj_x", "credential" => "arbn_y"}),
               version: "1"
             )

    refute plan.manifest_url =~ "arbj_"
    refute plan.manifest_url =~ "arbn_"
    refute plan.secret_command =~ "arbj_"
  end

  test "a cluster node needs a registry, a public URL and a release" do
    {:ok, _} = Settings.set_nodes_registry(nil)
    assert {:error, :no_registry} = ClusterInstall.plan(@params, version: "1")

    {:ok, _} = Settings.set_nodes_registry("registry.example.test/arbiter")
    assert {:error, :no_release} = ClusterInstall.plan(@params, version: nil)

    {:ok, _} = Settings.set_nodes_public_url(nil)
    assert {:error, :no_public_url} = ClusterInstall.plan(@params, version: "1")
  end

  test "a public URL the controller would refuse (http, non-loopback) is not rendered" do
    {:ok, _} = Settings.set_nodes_public_url("http://172.26.0.1:4949")

    assert {:error, {:insecure_public_url, "http://172.26.0.1:4949"}} =
             ClusterInstall.plan(@params, version: "1")

    {:ok, _} = Settings.set_nodes_public_url("http://127.0.0.1:4949")
    assert {:ok, _} = ClusterInstall.plan(@params, version: "1")
  end

  test "plan/2 refuses what the renderer would refuse" do
    assert {:error, [error]} =
             ClusterInstall.plan(
               %{"name" => "x", "max" => "0", "primary_cidrs" => "100.64.0.10/32"},
               version: "1"
             )

    assert error =~ "max"
  end

  test "a direct install without the primary's CIDRs is refused, and with them carried into the URL" do
    assert {:error, [error]} = ClusterInstall.plan(%{"name" => "x"}, version: "1")
    assert error =~ "primary_cidrs is required"

    assert {:ok, plan} =
             ClusterInstall.plan(
               %{"name" => "x", "primary_cidrs" => "100.64.0.10/32,100.64.0.11/32"},
               version: "1"
             )

    assert plan.manifest_url =~ "primary_cidrs=100.64.0.10%2F32%2C100.64.0.11%2F32"
  end

  test "set_image_command/2 names the controller's own Deployment and container" do
    assert ClusterInstall.set_image_command(
             "arbiter-workers",
             "r.example/arbiter/controller:0.2.43"
           ) ==
             "kubectl -n arbiter-workers set image deployment/arbiter-controller " <>
               "controller=r.example/arbiter/controller:0.2.43"
  end

  test "image/2 sanitises the tag the way the publisher does" do
    assert ClusterInstall.image("r.example/a", "0.2.43+build/1") ==
             "r.example/a/controller:0.2.43_build_1"
  end

  describe "controller_facts/1 (K14: GET /nodes/cluster)" do
    @worker "registry.example.test/arbiter/worker@sha256:" <> String.duplicate("a", 64)
    @controller "registry.example.test/arbiter/controller@sha256:" <> String.duplicate("b", 64)

    test "names the install id and the registry" do
      facts = ClusterInstall.controller_facts(published: [])

      assert facts.install_id == Arbiter.Nodes.InstallId.get()
      assert facts.registry == "registry.example.test/arbiter"
      assert facts.canary_image == nil
    end

    test "the canary runs the published worker image, else the controller image" do
      worker = %{kind: :worker, ref: @worker}
      controller = %{kind: :controller, ref: @controller}

      assert ClusterInstall.controller_facts(published: [controller, worker]).canary_image ==
               @worker

      assert ClusterInstall.controller_facts(published: [controller]).canary_image ==
               @controller
    end

    test "an image published under another registry is not offered" do
      {:ok, _} = Settings.set_nodes_registry("registry.example.test/moved")
      published = [%{kind: :worker, ref: @worker}, %{kind: :controller, ref: @controller}]

      assert ClusterInstall.controller_facts(published: published).canary_image == nil
    end
  end
end
