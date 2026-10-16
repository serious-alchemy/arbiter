defmodule Arbiter.NodeAgent.K8s.BootTest do
  @moduledoc """
  The node-agent boot with `ARB_AGENT_BACKEND=k8s` (ticket K14,
  `docs/design/remote-workers.md` K§2.4): `Arbiter.NodeAgent.Supervisor` starts the
  cluster tree instead of the machine's, `Arbiter.NodeAgent.K8s.Boot` reads (or enrols and
  stores) the credential, asks the primary for the install id and registry, resolves the
  controller's identity, and starts the controller (`K8s.NodeTree`) under the node
  supervisor. The cluster is the fake API server; the primary's HTTP side is a Req plug
  (its WebSocket is out of reach here: `ArbiterWeb.RemoteClusterTest` drives the real one).
  Every process runs under its production name, so this module is not async.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Plug.Conn

  alias Arbiter.NodeAgent.K8s.Boot
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.K8s.ControllerSupervisor
  alias Arbiter.NodeAgent.Supervisor, as: AgentSupervisor
  alias Arbiter.Test.FakeK8sApi

  @credential "arbn_node-7." <> String.duplicate("C", 52)
  @install "q2w3e4r5t6y7u8i9"
  @registry "registry.example.test/arbiter"

  setup do
    home = Path.join(System.tmp_dir!(), "arb-k8sboot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    cluster = FakeK8sApi.start!(namespace: "arbiter-workers")
    api = cluster.api
    FakeK8sApi.set_clock(api, DateTime.utc_now())

    for name <- ~w(arbiter-node-credential arbiter-controller-ca) do
      FakeK8sApi.put_secret(api, %{"metadata" => %{"name" => name}, "type" => "Opaque"})
    end

    FakeK8sApi.put_config_map(api, %{"metadata" => %{"name" => "arbiter-ca"}})

    FakeK8sApi.put_service(api, %{
      "metadata" => %{"name" => "arbiter-controller"},
      "spec" => %{"clusterIP" => "127.0.0.1"}
    })

    FakeK8sApi.put_deployment(api, %{
      "metadata" => %{
        "name" => "arbiter-controller",
        "uid" => "5f0c2a1e-1111-4222-8333-444455556666"
      },
      "spec" => %{
        "template" => %{
          "spec" => %{
            "containers" => [
              %{"name" => "controller", "image" => "#{@registry}/controller:1.2.3"}
            ]
          }
        }
      }
    })

    FakeK8sApi.put_lease(api, %{"metadata" => %{"name" => "arbiter-controller"}, "spec" => %{}})

    hard = %{"pods" => "8", "requests.cpu" => "16", "requests.memory" => "64Gi"}

    FakeK8sApi.put_quota(api, %{
      "metadata" => %{"name" => "q"},
      "spec" => %{"hard" => hard},
      "status" => %{"hard" => hard, "used" => %{}}
    })

    config_path = Path.join(home, "controller.yaml")
    File.write!(config_path, "max_concurrent: 2\n")

    %{home: home, api: api, client: cluster.client, config_path: config_path}
  end

  # The primary's HTTP side: enrolment and the cluster facts, reported to the test.
  defp primary(opts \\ []) do
    test = self()
    facts_status = Keyword.get(opts, :facts_status, 200)

    fn conn ->
      {:ok, raw, conn} = read_body(conn)
      send(test, {:primary, conn.method, conn.request_path, raw})

      {status, body} =
        case {conn.method, conn.request_path} do
          {"POST", "/nodes/enroll"} ->
            {200, %{"credential" => @credential, "node_id" => "node-7"}}

          {"GET", "/nodes/cluster"} when facts_status == 200 ->
            {200, %{"install_id" => @install, "registry" => @registry, "canary_image" => nil}}

          {"GET", "/nodes/cluster"} ->
            {facts_status, %{"error" => %{"message" => "Invalid node credential"}}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  defp boot!(ctx, opts \\ []) do
    token_file = Path.join(ctx.home, "token")

    start_supervised!({AgentSupervisor,
     [
       env: %{
         "ARB_AGENT_BACKEND" => "k8s",
         # Refused at once: the WebSocket half is not under test here.
         "ARB_PRIMARY_URL" => "https://127.0.0.1:1",
         "ARB_NODE_NAME" => "mesaana-k3s",
         "ARB_K8S_SELF_UPGRADE" => "true",
         "KUBERNETES_SERVICE_HOST" => "10.43.0.1",
         "KUBERNETES_SERVICE_PORT" => "443",
         "HOSTNAME" => "arbiter-controller-6d9c7-x2b4q"
       },
       app_config: [],
       node_home: ctx.home,
       k8s_client: ctx.client,
       token_file: token_file,
       req_options: [plug: Keyword.get(opts, :primary, primary()), retry: false],
       backoff: [base: 20, max: 50],
       tree: [
         config_loader: [path: ctx.config_path, interval_ms: nil],
         informer: [backoff_ms: {5, 20}],
         pod_channel: [ip: {127, 0, 0, 1}, bridge_port: 0, boot_port: 0],
         controller_supervisor: [
           listen_port: 0,
           targets: %{api: "10.43.0.1:443"},
           readiness: [interval_ms: nil, poll_ms: 5, timeout_ms: 500, autostart: false]
         ]
       ]
     ]})
  end

  defp status(ctx), do: ctx.home |> Path.join("status.json") |> File.read!() |> Jason.decode!()

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # The connection is the tree's last child: once it is up, everything before it is.
  defp booted?, do: is_pid(Process.whereis(Arbiter.NodeAgent.Connection))

  defp stored(api, secret, key) do
    case FakeK8sApi.secret(api, secret)["data"] do
      %{^key => value} -> Base.decode64!(value)
      _ -> nil
    end
  end

  test "the node supervisor starts the cluster tree, not the machine's", ctx do
    File.write!(Path.join(ctx.home, "token"), "arbj_join\n")
    boot!(ctx)

    children =
      AgentSupervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.reverse()

    assert children == [
             Arbiter.NodeAgent.TaskSupervisor,
             Arbiter.NodeAgent.Status,
             Arbiter.NodeAgent.Bridge,
             Arbiter.NodeAgent.K8s.TreeSupervisor,
             Arbiter.NodeAgent.K8s.Boot
           ]

    wait_until(&booted?/0)

    tree =
      Arbiter.NodeAgent.K8s.NodeTree
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    assert tree == [
             Arbiter.NodeAgent.PodChannel,
             Arbiter.NodeAgent.K8s.ConfigLoader,
             Arbiter.NodeAgent.K8s.Informer,
             Arbiter.NodeAgent.K8s.Lease,
             ControllerSupervisor,
             Arbiter.NodeAgent.K8s.Upgrader,
             Arbiter.NodeAgent.Connection
           ]

    # No machine process: no run table, no podman image builder, no derate monitor.
    for name <- [
          Arbiter.NodeAgent.RunRegistry,
          Arbiter.NodeAgent.RunSupervisor,
          Arbiter.NodeAgent.Monitor,
          Arbiter.NodeAgent.Upgrader
        ],
        do: assert(Process.whereis(name) == nil, "#{inspect(name)} is a machine process")
  end

  test "first boot: the join token is redeemed and the credential lives only in the Secret",
       ctx do
    File.write!(Path.join(ctx.home, "token"), "arbj_join\n")
    boot!(ctx)
    wait_until(&booted?/0)

    assert_receive {:primary, "POST", "/nodes/enroll", body}

    assert %{
             "token" => "arbj_join",
             "kind" => "cluster",
             "name" => "mesaana-k3s",
             "k8s_version" => "v1.31.2+fake"
           } = Jason.decode!(body)

    assert stored(ctx.api, "arbiter-node-credential", "credential") == @credential
    refute File.read!(Path.join(ctx.home, "status.json")) =~ "CCCCCCCC"
    assert status(ctx)["node_id"] == "node-7"
  end

  test "the controller is labelled, owned and placed from the primary's and the API's facts",
       ctx do
    File.write!(Path.join(ctx.home, "token"), "arbj_join\n")
    boot!(ctx)
    wait_until(&booted?/0)

    assert_receive {:primary, "GET", "/nodes/cluster", _}
    assert %{capacity: %{"ceiling" => 2}, runs: []} = Controller.report(Controller)

    informer_list =
      ctx.api
      |> FakeK8sApi.requests()
      |> Enum.find(&(&1.method == "GET" and String.ends_with?(&1.path, "/pods")))

    assert informer_list.params["labelSelector"] ==
             "arbiter.dev/install=#{@install},arbiter.dev/node=node-7"
  end

  test "the pod channel's CA goes to its Secret, the certificate to the ConfigMap", ctx do
    File.write!(Path.join(ctx.home, "token"), "arbj_join\n")
    boot!(ctx)
    wait_until(&booted?/0)

    assert stored(ctx.api, "arbiter-controller-ca", "ca.key") =~ "PRIVATE KEY"
    cert = stored(ctx.api, "arbiter-controller-ca", "ca.crt")
    assert FakeK8sApi.config_map(ctx.api, "arbiter-ca")["data"] == %{"ca.crt" => cert}
  end

  # KH8: the chart sets these on the Deployment; the controller reports them in `caps.install`.
  test "install_from_env reads the chart's ARB_INSTALL_METHOD, release and chart" do
    assert Boot.install_from_env(%{
             "ARB_INSTALL_METHOD" => "helm",
             "ARB_HELM_RELEASE" => "node-a",
             "ARB_CHART_REF" => "oci://ghcr.io/acme/charts/arbiter-node"
           }) == %{
             method: "helm",
             release: "node-a",
             chart: "oci://ghcr.io/acme/charts/arbiter-node"
           }

    assert Boot.install_from_env(%{"ARB_INSTALL_METHOD" => "helm", "ARB_CHART_REF" => ""}) ==
             %{method: "helm"}

    assert Boot.install_from_env(%{}) == %{method: "manifest"}
    assert Boot.install_from_env(%{"ARB_INSTALL_METHOD" => "bogus"}) == %{method: "manifest"}
  end

  # The self-upgrade switch is read once, from the boot's environment: what `hello` reports
  # as `caps.self_upgrade` is what the upgrader does.
  test "the upgrader follows the boot's ARB_K8S_SELF_UPGRADE", ctx do
    File.write!(Path.join(ctx.home, "token"), "arbj_join\n")
    boot!(ctx)
    wait_until(&booted?/0)

    image = "#{@registry}/controller:2.0.0"

    assert :started =
             Arbiter.NodeAgent.K8s.Upgrader.request(
               Arbiter.NodeAgent.K8s.Upgrader,
               %{"version" => "2.0.0", "image" => image}
             )

    containers =
      FakeK8sApi.deployment(ctx.api, "arbiter-controller")["spec"]["template"]["spec"][
        "containers"
      ]

    assert [%{"name" => "controller", "image" => ^image}] = containers
  end

  test "a credential that could not be stored is kept, retried, and never shown", ctx do
    File.write!(Path.join(ctx.home, "token"), "arbj_join\n")
    FakeK8sApi.fail_next(ctx.api, :secret_update, {403, "secrets is forbidden"}, 3)
    boot!(ctx)

    wait_until(fn -> (status(ctx)["last_error"] || "") =~ "forbidden" end)
    # What a crash report or `:sys.get_status/1` would print of the boot's state.
    refute inspect(:sys.get_status(Arbiter.NodeAgent.K8s.Boot)) =~ "CCCCCCCC"
    refute File.read!(Path.join(ctx.home, "status.json")) =~ "CCCCCCCC"

    # Once the API lets it, the same credential is stored: one enrolment, no second token.
    wait_until(&booted?/0)
    assert stored(ctx.api, "arbiter-node-credential", "credential") == @credential
    assert_receive {:primary, "POST", "/nodes/enroll", _}
    refute_received {:primary, "POST", "/nodes/enroll", _}
  end

  test "a later boot reads the Secret and never enrols", ctx do
    FakeK8sApi.put_secret(ctx.api, %{
      "metadata" => %{"name" => "arbiter-node-credential"},
      "data" => %{"credential" => Base.encode64(@credential)}
    })

    boot!(ctx)
    wait_until(&booted?/0)

    refute_received {:primary, "POST", "/nodes/enroll", _}
    assert_receive {:primary, "GET", "/nodes/cluster", _}
  end

  test "before the join Secret exists it stays up, says why, and boots once it appears", ctx do
    boot!(ctx)

    wait_until(fn -> (status(ctx)["last_error"] || "") =~ "join" end)
    assert status(ctx)["state"] == "booting"
    refute booted?()

    File.write!(Path.join(ctx.home, "token"), "arbj_join\n")
    wait_until(&booted?/0)
  end

  test "an API server the controller cannot reach is named, with the policy fix, not a raw transport error",
       ctx do
    # Nothing listens on port 1: the connection is refused, as kube-router does for an
    # egress rule that only names the Service address (the policy is applied post-DNAT).
    client = %{ctx.client | base_url: "http://127.0.0.1:1"}
    boot!(%{ctx | client: client})

    wait_until(fn -> (status(ctx)["last_error"] || "") =~ "cannot reach the Kubernetes API" end)

    assert status(ctx)["state"] == "booting"
    assert status(ctx)["boot_step"] == "credential"
    assert status(ctx)["last_error"] =~ "--api-cidrs"
    refute status(ctx)["last_error"] =~ "%Req.TransportError"
    refute booted?()
  end

  test "a credential the primary refuses keeps the controller down, retrying", ctx do
    FakeK8sApi.put_secret(ctx.api, %{
      "metadata" => %{"name" => "arbiter-node-credential"},
      "data" => %{"credential" => Base.encode64(@credential)}
    })

    boot!(ctx, primary: primary(facts_status: 401))

    wait_until(fn -> (status(ctx)["last_error"] || "") =~ "401" end)
    assert_receive {:primary, "GET", "/nodes/cluster", _}, 5_000
    assert_receive {:primary, "GET", "/nodes/cluster", _}, 5_000
    refute booted?()
  end
end
