defmodule Arbiter.NodeAgent.K8s.SelfUpgradeTest do
  @moduledoc """
  K9 (bd-6ez9yn, `docs/design/remote-workers.md` K§2.4): the controller moves itself to a
  new image by patching **its own Deployment** and nothing else; without the RBAC (or with
  `rbac.selfUpgrade` off) it does not try, and the primary shows the `kubectl set image`
  command instead.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.SelfUpgrade
  alias Arbiter.Test.FakeK8sApi

  @old "registry.example.test/arbiter/controller:0.2.42"
  @new "registry.example.test/arbiter/controller:0.2.43"
  @spec_new %{"version" => "0.2.43", "image" => @new}

  setup do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")

    FakeK8sApi.put_deployment(env.api, %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{"name" => "arbiter-controller", "namespace" => "arbiter-workers"},
      "spec" => %{
        "template" => %{
          "spec" => %{
            "containers" => [
              %{"name" => "controller", "image" => @old},
              %{"name" => "tailscale", "image" => "ghcr.io/tailscale/tailscale:stable"}
            ]
          }
        }
      }
    })

    {:ok, env}
  end

  defp images(api) do
    api
    |> FakeK8sApi.deployment("arbiter-controller")
    |> get_in(["spec", "template", "spec", "containers"])
    |> Map.new(&{&1["name"], &1["image"]})
  end

  defp patches(api), do: Enum.filter(FakeK8sApi.requests(api), &(&1.method == "PATCH"))

  describe "run/3" do
    test "patches the controller container's image on its own Deployment, and only that",
         %{client: client, api: api} do
      assert {:ok, :patched} = SelfUpgrade.run(client, @spec_new, enabled?: true)

      assert images(api) == %{
               "controller" => @new,
               "tailscale" => "ghcr.io/tailscale/tailscale:stable"
             }

      paths = for r <- FakeK8sApi.requests(api), do: {r.method, r.path}

      assert paths == [
               {"GET", "/apis/apps/v1/namespaces/arbiter-workers/deployments/arbiter-controller"},
               {"PATCH",
                "/apis/apps/v1/namespaces/arbiter-workers/deployments/arbiter-controller"}
             ]

      [patch] = patches(api)
      assert patch.headers["content-type"] == "application/strategic-merge-patch+json"

      assert Jason.decode!(patch.body) == %{
               "spec" => %{
                 "template" => %{
                   "spec" => %{"containers" => [%{"name" => "controller", "image" => @new}]}
                 }
               }
             }
    end

    test "a spec cannot name another Deployment, container or namespace", %{
      client: client,
      api: api
    } do
      spec =
        Map.merge(@spec_new, %{
          "deployment" => "vstim",
          "container" => "tailscale",
          "namespace" => "prod"
        })

      assert {:ok, :patched} = SelfUpgrade.run(client, spec, enabled?: true)

      assert Enum.all?(
               FakeK8sApi.requests(api),
               &(&1.path =~ "/namespaces/arbiter-workers/deployments/arbiter-controller")
             )

      assert images(api)["tailscale"] == "ghcr.io/tailscale/tailscale:stable"
    end

    test "off (rbac.selfUpgrade off) it does not even ask the API", %{client: client, api: api} do
      assert {:error, :disabled} = SelfUpgrade.run(client, @spec_new, enabled?: false)
      assert FakeK8sApi.requests(api) == []
    end

    test "defaults to the ARB_K8S_SELF_UPGRADE environment the manifest sets", %{
      client: client,
      api: api
    } do
      assert {:error, :disabled} =
               SelfUpgrade.run(client, @spec_new, env: %{"ARB_K8S_SELF_UPGRADE" => "false"})

      assert {:error, :disabled} = SelfUpgrade.run(client, @spec_new, env: %{})
      assert patches(api) == []

      assert {:ok, :patched} =
               SelfUpgrade.run(client, @spec_new, env: %{"ARB_K8S_SELF_UPGRADE" => "true"})
    end

    test "waits while a run is live (when_idle)", %{client: client, api: api} do
      assert {:error, :busy} = SelfUpgrade.run(client, @spec_new, enabled?: true, idle?: false)
      assert FakeK8sApi.requests(api) == []
    end

    test "without the patch verb the API says 403 and the caller falls back to the command",
         %{client: client, api: api} do
      FakeK8sApi.fail_next(
        api,
        :deployment_patch,
        {403, "deployments.apps \"arbiter-controller\" is forbidden"}
      )

      assert {:error, {:forbidden, message}} = SelfUpgrade.run(client, @spec_new, enabled?: true)
      assert message =~ "forbidden"
      assert images(api)["controller"] == @old
    end

    test "an image already running is a no-op", %{client: client, api: api} do
      spec = %{"version" => "0.2.42", "image" => @old}
      assert {:ok, :current} = SelfUpgrade.run(client, spec, enabled?: true)
      assert patches(api) == []
    end

    test "an image from another repository, or not an image reference, is refused unpatched",
         %{client: client, api: api} do
      for image <- [
            "evil.example/controller:0.2.43",
            "registry.example.test/arbiter/worker:abc",
            "registry.example.test/arbiter/controller:0.2.43; rm -rf /",
            "",
            nil,
            42
          ] do
        assert {:error, :bad_image} = SelfUpgrade.run(client, %{"image" => image}, enabled?: true)
      end

      assert {:error, :bad_image} = SelfUpgrade.run(client, %{}, enabled?: true)
      assert patches(api) == []
    end

    test "a digest-pinned image of the same repository is accepted", %{client: client, api: api} do
      image = "registry.example.test/arbiter/controller@sha256:" <> String.duplicate("a", 64)
      assert {:ok, :patched} = SelfUpgrade.run(client, %{"image" => image}, enabled?: true)
      assert images(api)["controller"] == image
    end

    test "a Deployment that is gone is reported, not created", %{client: client, api: api} do
      FakeK8sApi.fail_next(api, :deployment_get, 404)
      assert {:error, :not_found} = SelfUpgrade.run(client, @spec_new, enabled?: true)
      assert patches(api) == []
    end
  end

  describe "available?/1" do
    test "reads ARB_K8S_SELF_UPGRADE" do
      assert SelfUpgrade.available?(%{"ARB_K8S_SELF_UPGRADE" => "true"})
      refute SelfUpgrade.available?(%{"ARB_K8S_SELF_UPGRADE" => "false"})
      refute SelfUpgrade.available?(%{})
    end
  end
end
