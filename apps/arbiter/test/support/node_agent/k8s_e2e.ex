defmodule Arbiter.Test.K8sE2E do
  @moduledoc """
  Helpers for the `:k8s` end-to-end suite (`apps/arbiter/test/k8s/`, ticket K13): real
  Kubernetes, a **disposable** kind or k3d cluster, never anything else.

  ## The safety rules (they are code, not advice)

    * Nothing runs unless `ARB_K8S_E2E=1` **and** `ARB_K8S_E2E_KUBECONFIG` names a file.
      The default kubeconfig (`~/.kube/config`, `$KUBECONFIG`) is never read: every
      `kubectl` call passes `--kubeconfig <that file>` and sets `KUBECONFIG` to it.
    * `connect!/0` refuses a kubeconfig whose current context is not named `kind-*` or
      `k3d-*`, and one whose API server is not on a loopback address. An operator's
      k3s (a LAN address, any other context name) fails both, so the suite cannot be
      pointed at it by accident.
    * Every namespace it creates is `arb-e2e-<random>` and is deleted by its exact name
      at the end of the test; the one cluster-scoped object, a `PriorityClass`, carries
      the same suffix and is deleted by exact name too.

  Run it with `scripts/k8s-e2e.sh` (creates a kind or k3d cluster, runs the suite,
  deletes the cluster by name) or by hand against a cluster you made:

      ARB_K8S_E2E=1 ARB_K8S_E2E_KUBECONFIG=/path/to/kubeconfig \\
        mix test --include k8s test/k8s

  `kubectl` must be on `PATH`. The cluster needs a CNI that enforces NetworkPolicy
  (kind's kindnet and k3d's kube-router both do) and access to Docker Hub.

  ## The image

  The canary needs only `sh` and `socat`, so the suite uses `alpine/socat` pinned by
  digest (`image/0`, tag 1.8.0.3, the socat of the real base image); its registry
  prefix `docker.io/alpine` is the `registry` of the pod config. Override with
  `ARB_K8S_E2E_IMAGE` (a digest-pinned reference under `docker.io/alpine/`).
  """

  alias Arbiter.NodeAgent.K8s.Client

  @image "docker.io/alpine/socat@sha256:beb4a68d9e4fe6b0f21ea774a0fde6c31f580dde6368939ed70100c5385b015e"
  @registry "docker.io/alpine"

  defstruct [:kubeconfig, :context, :server]

  @type t :: %__MODULE__{}

  def image, do: System.get_env("ARB_K8S_E2E_IMAGE") || @image
  def registry, do: @registry

  # -- connecting, with the guards ----------------------------------------------------------

  @doc "Connect to the disposable cluster or raise with why not."
  @spec connect!() :: t()
  def connect! do
    with "1" <- System.get_env("ARB_K8S_E2E"),
         path when is_binary(path) <- System.get_env("ARB_K8S_E2E_KUBECONFIG"),
         true <- File.regular?(path) do
      env = %__MODULE__{kubeconfig: Path.expand(path)}
      view = config_view!(env)
      guard!(env, view)
      %{env | context: view["current-context"], server: server(view)}
    else
      _ ->
        raise "the :k8s suite needs ARB_K8S_E2E=1 and ARB_K8S_E2E_KUBECONFIG=<kubeconfig of a " <>
                "disposable kind/k3d cluster>; it never reads the default kubeconfig"
    end
  end

  @doc "The guard: a `kind-`/`k3d-` context on a loopback API server, nothing else."
  @spec guard!(t(), map()) :: :ok
  def guard!(_env, view) do
    context = view["current-context"] || ""
    host = view |> server() |> URI.parse() |> Map.get(:host)

    cond do
      not String.starts_with?(context, ["kind-", "k3d-"]) ->
        raise "refusing context #{inspect(context)}: the :k8s suite runs only on kind-* / k3d-* clusters"

      host not in ["127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0"] ->
        raise "refusing API server #{inspect(host)}: a disposable cluster listens on loopback"

      true ->
        :ok
    end
  end

  defp config_view!(env) do
    env |> kubectl!(["config", "view", "--raw", "--minify", "-o", "json"]) |> Jason.decode!()
  end

  defp server(view), do: get_in(view, ["clusters", Access.at(0), "cluster", "server"])

  @doc "A `Client` for the cluster in `namespace`, authenticating as the kubeconfig's user."
  @spec client(t(), String.t()) :: Client.t()
  def client(env, namespace) do
    view = config_view!(env)
    cluster = get_in(view, ["clusters", Access.at(0), "cluster"])
    user = get_in(view, ["users", Access.at(0), "user"])

    transport =
      [cacerts: pem_certs(cluster["certificate-authority-data"])] ++ user_auth(user)

    Client.new(
      base_url: cluster["server"],
      namespace: namespace,
      token: user["token"],
      req_options: [connect_options: [transport_opts: transport]]
    )
  end

  defp user_auth(%{"client-certificate-data" => cert, "client-key-data" => key}) do
    [{type, der, _} | _] = key |> Base.decode64!() |> :public_key.pem_decode()
    [cert: hd(pem_certs(cert)), key: {type, der}]
  end

  defp user_auth(_), do: []

  defp pem_certs(nil), do: []

  defp pem_certs(b64) do
    for {:Certificate, der, :not_encrypted} <- b64 |> Base.decode64!() |> :public_key.pem_decode(),
        do: der
  end

  # -- kubectl ------------------------------------------------------------------------------

  @doc "Run `kubectl` against the disposable cluster only; raises on a non-zero exit."
  @spec kubectl!(t(), [String.t()]) :: String.t()
  def kubectl!(env, args) do
    case kubectl(env, args) do
      {out, 0} -> out
      {out, code} -> raise "kubectl #{Enum.join(args, " ")} exited #{code}: #{out}"
    end
  end

  def kubectl(%__MODULE__{kubeconfig: path}, args) do
    System.cmd("kubectl", ["--kubeconfig", path | args],
      env: [{"KUBECONFIG", path}],
      stderr_to_stdout: true
    )
  end

  defp apply!(env, objects) do
    dir = Path.join(System.tmp_dir!(), "arb-k8s-e2e-#{random()}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "objects.json")

    File.write!(
      file,
      Jason.encode!(%{"apiVersion" => "v1", "kind" => "List", "items" => objects})
    )

    try do
      kubectl!(env, ["apply", "-f", file])
    after
      File.rm_rf!(dir)
    end
  end

  defp random, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  # -- the throwaway namespace --------------------------------------------------------------

  @doc """
  Create `arb-e2e-<random>` with Pod Security `restricted` enforced, a ResourceQuota, a
  PriorityClass, a stand-in controller (a Deployment named `arbiter-controller` with
  `socat` listeners on 9443, 9444 and 9445, and its Service) and, with `policies: true`
  (the default), the four NetworkPolicies of the bootstrap manifest. Registers the
  cleanup with ExUnit. Returns `%{namespace:, priority_class:, controller_ip:,
  controller_uid:, service_ip:}`.
  """
  @spec namespace!(t(), keyword()) :: map()
  def namespace!(env, opts \\ []) do
    suffix = random()
    ns = "arb-e2e-" <> suffix
    priority = "arbiter-e2e-" <> suffix

    ExUnit.Callbacks.on_exit(fn ->
      kubectl(env, ["delete", "namespace", ns, "--wait=false", "--ignore-not-found"])
      kubectl(env, ["delete", "priorityclass", priority, "--ignore-not-found"])
    end)

    apply!(env, base_objects(ns, priority, Keyword.get(opts, :policies, true)))

    kubectl!(env, [
      "-n",
      ns,
      "rollout",
      "status",
      "deployment/arbiter-controller",
      "--timeout=180s"
    ])

    %{
      namespace: ns,
      priority_class: priority,
      service_ip:
        jsonpath(env, ["-n", ns, "get", "service", "arbiter-controller"], ".spec.clusterIP"),
      controller_uid:
        jsonpath(env, ["-n", ns, "get", "deployment", "arbiter-controller"], ".metadata.uid"),
      controller_ip:
        jsonpath(
          env,
          ["-n", ns, "get", "pods", "-l", "app.kubernetes.io/component=controller"],
          ".items[0].status.podIP"
        )
    }
  end

  defp jsonpath(env, args, path) do
    out =
      kubectl!(env, args ++ ["-o", "jsonpath={#{path}}"])

    String.trim(out)
  end

  @doc "The `PodSpec` config for `ns` (see `namespace!/2`)."
  @spec pod_config(t(), map()) :: map()
  def pod_config(env, ns) do
    api_ip = jsonpath(env, ["-n", "default", "get", "service", "kubernetes"], ".spec.clusterIP")

    %{
      registry: @registry,
      install_id: "e2e",
      node_id: "e2e-node",
      owner_uid: ns.controller_uid,
      bridge_addr: ns.service_ip,
      gate_addr: "#{api_ip}:443",
      boot_nonce: String.duplicate("e2e-nonce-", 4),
      max_wall_s: 600,
      namespace: ns.namespace,
      placement: %{"priority_class" => ns.priority_class},
      timeouts: %{"gate_timeout_s" => 20}
    }
  end

  @doc "The canary's probe targets in `ns`, read from the real cluster."
  @spec targets(t(), map()) :: map()
  def targets(env, ns) do
    api = jsonpath(env, ["-n", "default", "get", "service", "kubernetes"], ".spec.clusterIP")
    dns = jsonpath(env, ["-n", "kube-system", "get", "service", "kube-dns"], ".spec.clusterIP")

    node =
      jsonpath(
        env,
        ["get", "nodes"],
        ~s|.items[0].status.addresses[?(@.type=="InternalIP")].address|
      )

    %{
      api: "#{api}:443",
      controller_port: "#{ns.controller_ip}:9445",
      foreign: "#{dns}:53",
      node: "#{node}:10250"
    }
  end

  # -- objects ------------------------------------------------------------------------------

  defp base_objects(ns, priority, policies?) do
    [
      %{
        "apiVersion" => "v1",
        "kind" => "Namespace",
        "metadata" => %{
          "name" => ns,
          "labels" => %{
            "pod-security.kubernetes.io/enforce" => "restricted",
            "pod-security.kubernetes.io/enforce-version" => "latest"
          }
        }
      },
      %{
        "apiVersion" => "scheduling.k8s.io/v1",
        "kind" => "PriorityClass",
        "metadata" => %{"name" => priority},
        "value" => -100,
        "preemptionPolicy" => "Never",
        "description" => "arbiter e2e (disposable)"
      },
      %{
        "apiVersion" => "v1",
        "kind" => "ResourceQuota",
        "metadata" => %{"name" => "arbiter-workers", "namespace" => ns},
        "spec" => %{
          "hard" => %{
            "pods" => "10",
            "requests.cpu" => "4",
            "requests.memory" => "8Gi",
            "limits.cpu" => "8",
            "limits.memory" => "16Gi",
            "requests.ephemeral-storage" => "16Gi"
          }
        }
      },
      controller_deployment(ns),
      %{
        "apiVersion" => "v1",
        "kind" => "Service",
        "metadata" => %{"name" => "arbiter-controller", "namespace" => ns},
        "spec" => %{
          "selector" => %{"app.kubernetes.io/name" => "arbiter-controller"},
          "ports" => [
            %{"name" => "bridge", "port" => 9443, "targetPort" => 9443},
            %{"name" => "http", "port" => 9444, "targetPort" => 9444}
          ]
        }
      }
    ] ++ if(policies?, do: policies(ns), else: [])
  end

  # A listener on the bridge ports and on 9445 (a port that is not a bridge port, the
  # canary's `controller_port` probe), and nothing else.
  defp controller_deployment(ns) do
    listeners =
      for port <- [9443, 9444, 9445],
          do: "socat TCP-LISTEN:#{port},fork,reuseaddr EXEC:/bin/true &"

    script = Enum.join(listeners, "\n") <> "\nwait\n"

    labels = %{
      "app.kubernetes.io/name" => "arbiter-controller",
      "app.kubernetes.io/component" => "controller"
    }

    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{"name" => "arbiter-controller", "namespace" => ns},
      "spec" => %{
        "replicas" => 1,
        "selector" => %{"matchLabels" => %{"app.kubernetes.io/name" => "arbiter-controller"}},
        "template" => %{
          "metadata" => %{"labels" => labels},
          "spec" => %{
            "securityContext" => %{
              "runAsNonRoot" => true,
              "runAsUser" => 10_001,
              "seccompProfile" => %{"type" => "RuntimeDefault"}
            },
            "containers" => [
              %{
                "name" => "listener",
                "image" => image(),
                "command" => ["sh", "-c", script],
                "securityContext" => %{
                  "allowPrivilegeEscalation" => false,
                  "capabilities" => %{"drop" => ["ALL"]},
                  "readOnlyRootFilesystem" => true
                },
                "resources" => %{
                  "requests" => %{"cpu" => "10m", "memory" => "16Mi"},
                  "limits" => %{"memory" => "64Mi"}
                }
              }
            ]
          }
        }
      }
    }
  end

  # Section 9.1 of the design, minus the controller's egress (the stand-in controller
  # only listens).
  defp policies(ns) do
    worker = %{"matchLabels" => %{"app.kubernetes.io/component" => "worker"}}
    controller = %{"matchLabels" => %{"app.kubernetes.io/component" => "controller"}}
    ports = [%{"protocol" => "TCP", "port" => 9443}, %{"protocol" => "TCP", "port" => 9444}]

    [
      policy(ns, "default-deny", %{
        "podSelector" => %{},
        "policyTypes" => ["Ingress", "Egress"]
      }),
      policy(ns, "worker-to-controller", %{
        "podSelector" => worker,
        "policyTypes" => ["Egress"],
        "egress" => [%{"to" => [%{"podSelector" => controller}], "ports" => ports}]
      }),
      policy(ns, "controller-ingress-from-workers", %{
        "podSelector" => controller,
        "policyTypes" => ["Ingress"],
        "ingress" => [%{"from" => [%{"podSelector" => worker}], "ports" => ports}]
      })
    ]
  end

  defp policy(ns, name, spec) do
    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => %{"name" => name, "namespace" => ns},
      "spec" => spec
    }
  end
end
