defmodule Arbiter.NodeAgent.K8s.IdentityTest do
  @moduledoc """
  The controller's own facts (ticket K14): the install id, registry and canary image from
  the primary (`GET /nodes/cluster`, the node credential), the owner-reference uid and the
  Service address from the API, the gate address, pod name and wall budget from the pod's
  environment. They become the `Controller`'s `:identity` and every pod's labels.
  """
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.K8s.Identity
  alias Arbiter.Test.FakeK8sApi

  @credential "arbn_node-7." <> String.duplicate("C", 52)
  @env %{
    "KUBERNETES_SERVICE_HOST" => "10.43.0.1",
    "KUBERNETES_SERVICE_PORT" => "443",
    "HOSTNAME" => "arbiter-controller-6d9c7-x2b4q"
  }

  setup do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")

    FakeK8sApi.put_deployment(env.api, %{
      "metadata" => %{
        "name" => "arbiter-controller",
        "uid" => "5f0c2a1e-1111-4222-8333-444455556666"
      }
    })

    FakeK8sApi.put_service(env.api, %{
      "metadata" => %{"name" => "arbiter-controller"},
      "spec" => %{"clusterIP" => "10.43.98.199"}
    })

    env
  end

  defp config(plug) do
    {:ok, config} =
      Config.load(
        env: %{},
        app_config: [],
        primary_url: "https://primary.example.ts.net",
        read_credential: fn _ -> {:ok, @credential} end,
        req_options: [plug: plug, retry: false]
      )

    config
  end

  defp primary(status, body) do
    test = self()

    fn conn ->
      send(test, {:asked, conn.method, conn.request_path, get_req_header(conn, "authorization")})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  @facts %{
    "install_id" => "q2w3e4r5t6y7u8i9",
    "registry" => "registry.example.test/arbiter",
    "canary_image" =>
      "registry.example.test/arbiter/controller@sha256:" <> String.duplicate("b", 64)
  }

  describe "primary_facts/1" do
    test "asks the primary with the node credential" do
      assert {:ok, facts} = Identity.primary_facts(config(primary(200, @facts)))

      assert facts == %{
               install_id: "q2w3e4r5t6y7u8i9",
               registry: "registry.example.test/arbiter",
               canary_image: @facts["canary_image"]
             }

      assert_received {:asked, "GET", "/nodes/cluster", ["Bearer " <> @credential]}
    end

    test "a refusal names the status and the primary's message" do
      body = %{"error" => %{"message" => "Not a cluster node"}}

      assert {:error, {:primary, 404, "Not a cluster node"}} =
               Identity.primary_facts(config(primary(404, body)))
    end

    test "an answer without an install id is refused" do
      assert {:error, {:primary, 200, _}} =
               Identity.primary_facts(config(primary(200, %{"registry" => "r"})))
    end
  end

  describe "resolve/4" do
    test "assembles the controller's identity", env do
      facts = %{install_id: "q2w3e4r5t6y7u8i9", registry: "registry.example.test/arbiter"}

      assert {:ok, identity} =
               Identity.resolve(env.client, config(primary(500, %{})), facts, env: @env)

      assert identity == %{
               registry: "registry.example.test/arbiter",
               install_id: "q2w3e4r5t6y7u8i9",
               node_id: "node-7",
               owner_uid: "5f0c2a1e-1111-4222-8333-444455556666",
               bridge_addr: "10.43.98.199",
               gate_addr: "10.43.0.1:443",
               own_pod: "arbiter-controller-6d9c7-x2b4q",
               max_wall_s: 86_400
             }
    end

    test "ARB_K8S_MAX_WALL_S bounds the pod deadline; a bad value is the default", env do
      facts = %{install_id: "i1234567890123456", registry: "r.example/a"}
      config = config(primary(500, %{}))

      assert {:ok, %{max_wall_s: 7200}} =
               Identity.resolve(env.client, config, facts,
                 env: Map.put(@env, "ARB_K8S_MAX_WALL_S", "7200")
               )

      assert {:ok, %{max_wall_s: 86_400}} =
               Identity.resolve(env.client, config, facts,
                 env: Map.put(@env, "ARB_K8S_MAX_WALL_S", "-3")
               )
    end

    test "a primary without nodes.registry cannot be served", env do
      assert {:error, :no_registry} =
               Identity.resolve(
                 env.client,
                 config(primary(500, %{})),
                 %{install_id: "i1234567890123456", registry: nil},
                 env: @env
               )
    end

    test "the Deployment or the Service missing is an error naming it" do
      cluster = FakeK8sApi.start!(namespace: "arbiter-workers")
      facts = %{install_id: "i1234567890123456", registry: "r.example/a"}
      config = config(primary(500, %{}))

      assert {:error, {:deployment, :not_found}} =
               Identity.resolve(cluster.client, config, facts, env: @env)

      FakeK8sApi.put_deployment(cluster.api, %{
        "metadata" => %{"name" => "arbiter-controller", "uid" => "u-1"}
      })

      assert {:error, {:service, :not_found}} =
               Identity.resolve(cluster.client, config, facts, env: @env)

      FakeK8sApi.put_service(cluster.api, %{
        "metadata" => %{"name" => "arbiter-controller"},
        "spec" => %{"clusterIP" => "None"}
      })

      assert {:error, {:service, :no_cluster_ip}} =
               Identity.resolve(cluster.client, config, facts, env: @env)
    end

    test "outside a pod there is no gate address", env do
      assert {:error, :no_gate_addr} =
               Identity.resolve(
                 env.client,
                 config(primary(500, %{})),
                 %{install_id: "i1234567890123456", registry: "r.example/a"},
                 env: Map.delete(@env, "KUBERNETES_SERVICE_HOST")
               )
    end
  end
end
