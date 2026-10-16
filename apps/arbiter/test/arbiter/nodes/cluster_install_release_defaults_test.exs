defmodule Arbiter.Nodes.ClusterInstallReleaseDefaultsTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.InstallManifest
  alias Arbiter.Nodes.ClusterInstall

  @chart_values Path.expand("../../../../../charts/arbiter-node/values.yaml", __DIR__)
  @release_yml Path.expand("../../../../../.github/workflows/release.yml", __DIR__)

  # Release CI publishes under ghcr.io/${OWNER}; the owner is this repo's.
  @owner "serious-alchemy"

  test "chart defaults point where release CI publishes" do
    values = File.read!(@chart_values)
    release = File.read!(@release_yml)

    assert release =~ ~s(CONTROLLER=ghcr.io/${OWNER}/arbiter-controller)
    assert release =~ ~s(CHARTS=oci://ghcr.io/${OWNER}/charts)
    assert values =~ "repository: ghcr.io/#{@owner}/arbiter-controller"
    assert values =~ "chartRef: oci://ghcr.io/#{@owner}/charts/arbiter-node"
    assert ClusterInstall.chart_ref() =~ "oci://ghcr.io/#{@owner}/charts/arbiter-node"
  end

  test "values emit image.repository and image.tag when the server names them" do
    {:ok, spec} = InstallManifest.parse(%{"name" => "n1", "primary_cidrs" => "100.64.0.10/32"})

    {:ok, values} =
      InstallManifest.values(spec,
        primary_url: "https://a.example.test",
        image_repository: "ghcr.io/#{@owner}/arbiter-controller",
        image_tag: "1.2.3"
      )

    assert values["image"] == %{
             "repository" => "ghcr.io/#{@owner}/arbiter-controller",
             "tag" => "1.2.3"
           }
  end
end
