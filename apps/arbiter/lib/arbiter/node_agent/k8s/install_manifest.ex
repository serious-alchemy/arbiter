defmodule Arbiter.NodeAgent.K8s.InstallManifest do
  @moduledoc """
  The cluster install as plain manifests (`docs/design/remote-workers.md` K§2.1–K§2.2,
  ticket K9): what `GET /nodes/join/k8s.yaml`, the "Add node" modal and
  `arb node add --kind cluster` all hand the operator.

  Two parts, applied in order (`?part=bootstrap|node`, default both):

    * **bootstrap** (needs cluster-admin once): the `Namespace` with Pod Security
      `restricted`, the never-preempting `PriorityClass`, the `ResourceQuota` and
      `LimitRange`, the four `NetworkPolicy` objects of K§9.1 and, with
      `?admission=policy`, the `ValidatingAdmissionPolicy` and its binding
      (`Arbiter.NodeAgent.K8s.AdmissionPolicy`).
    * **node** (namespace-scoped): both `ServiceAccount`s, the `Role` and `RoleBinding`
      of K§7, the empty `arbiter-node-credential` / `arbiter-controller-ca` Secrets
      and `arbiter-ca` ConfigMap the controller fills in, the controller's config
      `ConfigMap`, the `Lease`, the `Service` and the `Deployment`
      (`Arbiter.NodeAgent.K8s.ControllerManifest`, with the tailscale sidecar when
      `?reach=tailscale`).

  **It contains no secret.** There is no option that takes a token, a credential or a
  key, so a request that offers one (`?token=…`) is ignored rather than echoed; the
  join token reaches the cluster through `kubectl create secret` reading the terminal,
  and the tailscale auth key through a Secret the operator creates. A Secret in the
  render is a placeholder with no payload. That is why the route can be anonymous,
  cached, diffed and committed.

  `rbac.selfUpgrade` (`?self_upgrade=on|off`, default on) decides whether the Role may
  `patch` the controller's own Deployment (and only that one, by `resourceNames`);
  the Deployment's `ARB_K8S_SELF_UPGRADE` tells the controller which. Off, the node
  shows `outdated` with the `kubectl set image` command instead.

  Everything is built as JSON-shaped string-keyed maps and emitted with `Ymlr`, so
  quoting is the emitter's job and no request value is ever spliced into text.
  """

  alias Arbiter.NodeAgent.K8s.{AdmissionPolicy, ControllerConfig, ControllerManifest, Quantity}
  alias Arbiter.Nodes

  @default_namespace "arbiter-workers"
  @default_max 2
  @max_limit 64
  @default_cpu "1"
  @default_memory "2Gi"
  @worker_storage "4Gi"
  @default_api_cidrs ["10.43.0.1/32"]
  @default_cluster_cidrs ["10.42.0.0/16", "10.43.0.0/16"]

  # What one worker pod adds to the worker container's own request (`seed` and
  # `snapshotter` at their default sizes), and what the controller (with room for
  # the tailscale sidecar) reserves. They size the quota; the quota, not these, is
  # what the cluster enforces.
  @pod_overhead_cpu_m 150
  @pod_overhead_mem_mi 320
  @controller_cpu_m 150
  @controller_mem_mi 320
  @controller_limit_cpu_m 1_500
  @pod_overhead_limit_mem_mi 1024
  @controller_limit_mem_mi 768

  @dns_label ~r/\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/
  @dns_subdomain ~r/\A[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?\z/
  @selector_key ~r/\A([a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?\/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?\z/
  @selector_value ~r/\A([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?\z/

  @type spec :: %{
          node_name: String.t(),
          namespace: String.t(),
          max_concurrent: pos_integer(),
          cpu: String.t(),
          memory: String.t(),
          node_selector: %{optional(String.t()) => String.t()},
          pull_secret: String.t() | nil,
          reach: ControllerManifest.reach(),
          admission: boolean(),
          self_upgrade: boolean(),
          api_cidrs: [String.t()],
          cluster_cidrs: [String.t()],
          part: :all | :bootstrap | :node
        }

  @type server :: [image: String.t(), primary_url: String.t(), registry: String.t()]

  @doc "The namespace the manifests default to."
  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  # ---- input ------------------------------------------------------------------

  @doc """
  Parse the query / form values (string keys): `name` (required), `namespace`, `max`,
  `cpu`, `memory`, `node_selector` (`k=v,k=v`), `pull_secret`, `reach`
  (`direct|tailscale`), `admission` (`policy` or none), `self_upgrade` (`on|off`),
  `api_cidrs`, `cluster_cidrs` (comma separated) and `part`. Unknown keys are
  ignored. Every refusal is one string starting with the field name.
  """
  @spec parse(map()) :: {:ok, spec()} | {:error, [String.t()]}
  def parse(params) when is_map(params) do
    fields = [
      name: field(params, "name", &name/1),
      namespace: field(params, "namespace", &dns_label/1, @default_namespace),
      max: field(params, "max", &max/1, @default_max),
      cpu: field(params, "cpu", &cpu/1, @default_cpu),
      memory: field(params, "memory", &memory/1, @default_memory),
      node_selector: field(params, "node_selector", &selector/1, %{}),
      pull_secret: field(params, "pull_secret", &subdomain/1, nil),
      reach: field(params, "reach", &reach/1, :direct),
      admission: field(params, "admission", &admission/1, false),
      self_upgrade: field(params, "self_upgrade", &self_upgrade/1, true),
      api_cidrs: field(params, "api_cidrs", &cidrs/1, @default_api_cidrs),
      cluster_cidrs: field(params, "cluster_cidrs", &cidrs/1, @default_cluster_cidrs),
      part: field(params, "part", &part/1, :all)
    ]

    case Enum.flat_map(fields, fn {key, result} -> error_for(key, result) end) do
      [] -> checked(fields)
      errors -> {:error, errors}
    end
  end

  def parse(_other), do: {:error, ["params must be a map"]}

  defp checked(fields) do
    v = Map.new(fields, fn {key, {:ok, value}} -> {key, value} end)

    spec = %{
      node_name: v.name,
      namespace: v.namespace,
      max_concurrent: v.max,
      cpu: v.cpu,
      memory: v.memory,
      node_selector: v.node_selector,
      pull_secret: v.pull_secret,
      reach: v.reach,
      admission: v.admission,
      self_upgrade: v.self_upgrade,
      api_cidrs: v.api_cidrs,
      cluster_cidrs: v.cluster_cidrs,
      part: v.part
    }

    # The controller will load this config; refuse here whatever it would refuse there.
    case ControllerConfig.from_map(config(spec)) do
      {:ok, _} -> {:ok, spec}
      {:error, {:bad_config, reason}} -> {:error, ["config: #{inspect(reason, limit: 6)}"]}
    end
  end

  defp field(params, key, parser, default \\ :required) do
    case Map.get(params, key) do
      value when value in [nil, ""] ->
        if default == :required, do: {:error, "is required"}, else: {:ok, default}

      value when is_binary(value) ->
        parser.(String.trim(value))

      _ ->
        {:error, "must be a string"}
    end
  end

  defp error_for(key, {:error, message}), do: ["#{key} #{message}"]
  defp error_for(_key, _ok), do: []

  defp name(value) do
    if Nodes.valid_name?(value),
      do: {:ok, value},
      else: {:error, "may only contain A-Za-z0-9._=:/@- (1-128 characters) and not be \"local\""}
  end

  defp dns_label(value),
    do: matching(value, @dns_label, "must be a DNS label (lowercase letters, digits, -)")

  defp subdomain(value),
    do: matching(value, @dns_subdomain, "must be a DNS name (lowercase letters, digits, - .)")

  defp matching(value, regex, message),
    do: if(Regex.match?(regex, value), do: {:ok, value}, else: {:error, message})

  defp max(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 and n <= @max_limit -> {:ok, n}
      _ -> {:error, "must be a whole number from 1 to #{@max_limit}"}
    end
  end

  defp cpu(value),
    do: if(match?({:ok, _}, Quantity.cpu(value, :k8s)), do: {:ok, value}, else: bad_quantity())

  defp memory(value),
    do: if(match?({:ok, _}, Quantity.memory(value, :k8s)), do: {:ok, value}, else: bad_quantity())

  defp bad_quantity, do: {:error, "must be a Kubernetes quantity such as 500m, 2 or 4Gi"}

  defp selector(value) do
    pairs =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.split(String.trim(&1), "=", parts: 2))

    if pairs != [] and Enum.all?(pairs, &selector_pair?/1),
      do: {:ok, Map.new(pairs, fn [k, v] -> {k, v} end)},
      else: {:error, "must be comma separated key=value pairs"}
  end

  defp selector_pair?([key, value]),
    do: Regex.match?(@selector_key, key) and Regex.match?(@selector_value, value)

  defp selector_pair?(_), do: false

  defp reach(value) do
    case ControllerManifest.parse_reach(value) do
      {:ok, reach} -> {:ok, reach}
      {:error, _} -> {:error, "must be direct or tailscale"}
    end
  end

  defp admission(value) when value in ["policy", "on", "true"], do: {:ok, true}
  defp admission(value) when value in ["none", "off", "false"], do: {:ok, false}
  defp admission(_), do: {:error, "must be policy or none"}

  defp self_upgrade(value) when value in ["on", "true", "yes"], do: {:ok, true}
  defp self_upgrade(value) when value in ["off", "false", "no"], do: {:ok, false}
  defp self_upgrade(_), do: {:error, "must be on or off"}

  defp part("all"), do: {:ok, :all}
  defp part("bootstrap"), do: {:ok, :bootstrap}
  defp part("node"), do: {:ok, :node}
  defp part(_), do: {:error, "must be all, bootstrap or node"}

  defp cidrs(value) do
    list = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if list != [] and Enum.all?(list, &cidr?/1),
      do: {:ok, list},
      else: {:error, "must be comma separated CIDRs such as 10.43.0.1/32"}
  end

  defp cidr?(text) do
    with [address, bits] <- String.split(text, "/"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
         {n, ""} <- Integer.parse(bits) do
      n >= 0 and n <= if(tuple_size(ip) == 4, do: 32, else: 128)
    else
      _ -> false
    end
  end

  # ---- output -----------------------------------------------------------------

  @doc """
  The documents, as `%{bootstrap: [map], node: [map]}`. `server` is what only the
  primary knows: the controller `:image`, its own `:primary_url` and the image
  `:registry` prefix (the admission policy's allow-list).
  """
  @spec documents(spec(), server()) :: %{bootstrap: [map()], node: [map()]}
  def documents(spec, server) do
    {:ok, deployment} =
      ControllerManifest.deployment(
        image: Keyword.fetch!(server, :image),
        primary_url: Keyword.fetch!(server, :primary_url),
        node_name: spec.node_name,
        namespace: spec.namespace,
        reach: spec.reach,
        self_upgrade: spec.self_upgrade
      )

    %{
      bootstrap:
        [namespace(spec), priority_class(), quota(spec), limit_range(spec)] ++
          network_policies(spec) ++ admission(spec, server),
      node: [
        service_account("arbiter-controller", spec.namespace, true),
        service_account("arbiter-worker", spec.namespace, false),
        role(spec),
        role_binding(spec),
        placeholder_secret("arbiter-node-credential", spec.namespace),
        placeholder_secret("arbiter-controller-ca", spec.namespace),
        config_map(spec),
        ca_config_map(spec.namespace),
        lease(spec.namespace),
        service(spec.namespace),
        deployment
      ]
    }
  end

  @doc "All documents the spec's `part` selects, in apply order."
  @spec render(spec(), server()) :: {:ok, [map()]} | {:error, {:missing, atom()}}
  def render(spec, server) do
    with :ok <- require_server(server) do
      %{bootstrap: bootstrap, node: node} = documents(spec, server)

      {:ok,
       case spec.part do
         :all -> bootstrap ++ node
         :bootstrap -> bootstrap
         :node -> node
       end}
    end
  end

  @doc "`render/2` as one YAML stream (`---` separated, with a header comment)."
  @spec yaml(spec(), server()) :: {:ok, String.t()} | {:error, {:missing, atom()}}
  def yaml(spec, server) do
    with {:ok, docs} <- render(spec, server) do
      {:ok, header(spec) <> Ymlr.documents!(docs)}
    end
  end

  defp require_server(server) do
    Enum.find_value([:image, :primary_url, :registry], :ok, fn key ->
      value = Keyword.get(server, key)
      if is_binary(value) and value != "", do: nil, else: {:error, {:missing, key}}
    end)
  end

  defp header(spec) do
    """
    # Arbiter cluster node #{spec.node_name} -- rendered by the primary. This file contains no
    # secret: no join token, no node credential, no CA key. Create the join Secret
    # separately (the token is read from your terminal):
    #   read -rs T && printf %s "$T" | kubectl -n #{spec.namespace} create secret generic arbiter-join --from-file=token=/dev/stdin
    # bootstrap (cluster-admin, once) comes first, then node.
    """
  end

  # ---- bootstrap documents ------------------------------------------------------

  defp namespace(spec) do
    labels =
      for level <- ~w(enforce audit warn), into: %{} do
        {"pod-security.kubernetes.io/#{level}", "restricted"}
      end
      |> Map.put("pod-security.kubernetes.io/enforce-version", "latest")

    %{
      "apiVersion" => "v1",
      "kind" => "Namespace",
      "metadata" => %{"name" => spec.namespace, "labels" => labels}
    }
  end

  defp priority_class do
    %{
      "apiVersion" => "scheduling.k8s.io/v1",
      "kind" => "PriorityClass",
      "metadata" => %{"name" => "arbiter-worker"},
      "value" => -100,
      "preemptionPolicy" => "Never",
      "globalDefault" => false,
      "description" => "Arbiter worker pods: every other workload wins a contention."
    }
  end

  # K§4.3: the numbers come from max_concurrent and the per-pod figures, so the quota
  # and the ConfigMap cannot disagree at install time.
  defp quota(spec) do
    {:ok, cpu_m} = Quantity.cpu(spec.cpu, :k8s)
    {:ok, mem_b} = Quantity.memory(spec.memory, :k8s)
    n = spec.max_concurrent
    mi = 1_048_576
    {:ok, storage} = Quantity.memory(@worker_storage, :k8s)

    hard = %{
      "pods" => Integer.to_string(n + 2),
      "requests.cpu" => fmt_cpu(n * (cpu_m + @pod_overhead_cpu_m) + @controller_cpu_m),
      "requests.memory" =>
        fmt_mem(n * (mem_b + @pod_overhead_mem_mi * mi) + @controller_mem_mi * mi),
      "limits.cpu" => fmt_cpu(n * 2 * cpu_m + @controller_limit_cpu_m),
      "limits.memory" =>
        fmt_mem(n * (2 * mem_b + @pod_overhead_limit_mem_mi * mi) + @controller_limit_mem_mi * mi),
      "requests.ephemeral-storage" => fmt_mem((n + 1) * storage)
    }

    %{
      "apiVersion" => "v1",
      "kind" => "ResourceQuota",
      "metadata" => %{"name" => "arbiter-workers", "namespace" => spec.namespace},
      "spec" => %{"hard" => hard}
    }
  end

  defp fmt_cpu(millis), do: Quantity.format_cpu(millis)
  defp fmt_mem(bytes), do: Quantity.format_memory(bytes)

  defp limit_range(spec) do
    %{
      "apiVersion" => "v1",
      "kind" => "LimitRange",
      "metadata" => %{"name" => "arbiter-workers", "namespace" => spec.namespace},
      "spec" => %{
        "limits" => [
          %{
            "type" => "Container",
            # The quota counts ephemeral-storage requests, so a container that names none
            # (the controller, the tailscale sidecar) would be refused without a default.
            "defaultRequest" => %{
              "cpu" => "100m",
              "memory" => "128Mi",
              "ephemeral-storage" => "128Mi"
            },
            "default" => %{"cpu" => "500m", "memory" => "512Mi"}
          }
        ]
      }
    }
  end

  # K§9.1. Workers get no DNS and one destination (the controller's bridge and boot
  # ports); the controller gets the API server, DNS and outbound 443 / tailscale
  # but never the pod or service network.
  defp network_policies(spec) do
    controller = %{"app.kubernetes.io/component" => "controller"}
    worker = %{"app.kubernetes.io/component" => "worker"}

    bridge_ports = [
      %{"protocol" => "TCP", "port" => 9443},
      %{"protocol" => "TCP", "port" => 9444}
    ]

    [
      network_policy(spec, "default-deny", %{}, ["Ingress", "Egress"], %{}),
      network_policy(spec, "worker-to-controller", worker, ["Egress"], %{
        "egress" => [
          %{"to" => [%{"podSelector" => %{"matchLabels" => controller}}], "ports" => bridge_ports}
        ]
      }),
      network_policy(spec, "controller-ingress-from-workers", controller, ["Ingress"], %{
        "ingress" => [
          %{"from" => [%{"podSelector" => %{"matchLabels" => worker}}], "ports" => bridge_ports}
        ]
      }),
      network_policy(spec, "controller-egress", controller, ["Egress"], %{
        "egress" => [
          %{
            "to" => Enum.map(spec.api_cidrs, &%{"ipBlock" => %{"cidr" => &1}}),
            "ports" => [
              %{"protocol" => "TCP", "port" => 6443},
              %{"protocol" => "TCP", "port" => 443}
            ]
          },
          %{
            "to" => [
              %{
                "namespaceSelector" => %{
                  "matchLabels" => %{"kubernetes.io/metadata.name" => "kube-system"}
                },
                "podSelector" => %{"matchLabels" => %{"k8s-app" => "kube-dns"}}
              }
            ],
            "ports" => [
              %{"protocol" => "UDP", "port" => 53},
              %{"protocol" => "TCP", "port" => 53}
            ]
          },
          %{
            "to" => [%{"ipBlock" => %{"cidr" => "0.0.0.0/0", "except" => spec.cluster_cidrs}}],
            "ports" => [
              %{"protocol" => "TCP", "port" => 443},
              %{"protocol" => "UDP", "port" => 41_641},
              %{"protocol" => "UDP", "port" => 3478}
            ]
          }
        ]
      })
    ]
  end

  defp network_policy(spec, name, match_labels, types, rules) do
    selector = if match_labels == %{}, do: %{}, else: %{"matchLabels" => match_labels}

    %{
      "apiVersion" => "networking.k8s.io/v1",
      "kind" => "NetworkPolicy",
      "metadata" => %{"name" => name, "namespace" => spec.namespace},
      "spec" => Map.merge(%{"podSelector" => selector, "policyTypes" => types}, rules)
    }
  end

  defp admission(%{admission: false}, _server), do: []

  defp admission(spec, server),
    do:
      AdmissionPolicy.manifests(
        registry: Keyword.fetch!(server, :registry),
        namespace: spec.namespace
      )

  # ---- node documents -------------------------------------------------------------

  defp service_account(name, namespace, automount?) do
    base = %{
      "apiVersion" => "v1",
      "kind" => "ServiceAccount",
      "metadata" => %{"name" => name, "namespace" => namespace}
    }

    # Worker pods get a powerless account that mounts no token (K§7).
    if automount?, do: base, else: Map.put(base, "automountServiceAccountToken", false)
  end

  # K§7, namespaced only. `patch` on the Deployment is the only line `self_upgrade` moves.
  defp role(spec) do
    deployment_verbs = if spec.self_upgrade, do: ["get", "patch"], else: ["get"]

    %{
      "apiVersion" => "rbac.authorization.k8s.io/v1",
      "kind" => "Role",
      "metadata" => %{"name" => "arbiter-controller", "namespace" => spec.namespace},
      "rules" => [
        rule([""], ["pods"], ["create", "get", "list", "watch", "delete"]),
        rule([""], ["pods/log"], ["get"]),
        rule([""], ["resourcequotas"], ["get", "list", "watch"]),
        rule([""], ["services"], ["get"], ["arbiter-controller"]),
        rule([""], ["secrets"], ["get", "update"], [
          "arbiter-node-credential",
          "arbiter-controller-ca"
        ]),
        rule([""], ["configmaps"], ["get", "update"], ["arbiter-ca"]),
        rule(["coordination.k8s.io"], ["leases"], ["get", "update"], ["arbiter-controller"]),
        rule(["apps"], ["deployments"], deployment_verbs, ["arbiter-controller"])
      ]
    }
  end

  defp rule(groups, resources, verbs, names \\ nil) do
    base = %{"apiGroups" => groups, "resources" => resources, "verbs" => verbs}
    if names, do: Map.put(base, "resourceNames", names), else: base
  end

  defp role_binding(spec) do
    %{
      "apiVersion" => "rbac.authorization.k8s.io/v1",
      "kind" => "RoleBinding",
      "metadata" => %{"name" => "arbiter-controller", "namespace" => spec.namespace},
      "roleRef" => %{
        "apiGroup" => "rbac.authorization.k8s.io",
        "kind" => "Role",
        "name" => "arbiter-controller"
      },
      "subjects" => [
        %{
          "kind" => "ServiceAccount",
          "name" => "arbiter-controller",
          "namespace" => spec.namespace
        }
      ]
    }
  end

  # Empty on purpose: the controller writes the credential and the CA key here at first
  # boot, so the render never carries either.
  defp placeholder_secret(name, namespace) do
    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "metadata" => %{"name" => name, "namespace" => namespace},
      "type" => "Opaque"
    }
  end

  defp ca_config_map(namespace) do
    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{"name" => "arbiter-ca", "namespace" => namespace}
    }
  end

  defp config_map(spec) do
    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{"name" => "arbiter-controller-config", "namespace" => spec.namespace},
      "data" => %{"controller.yaml" => Ymlr.document!(config(spec)) |> strip_document_marker()}
    }
  end

  defp strip_document_marker("---\n" <> rest), do: rest
  defp strip_document_marker(text), do: text

  # The controller's closed-schema config (K§4.1) for this install.
  defp config(spec) do
    {:ok, cpu_m} = Quantity.cpu(spec.cpu, :k8s)
    {:ok, mem_b} = Quantity.memory(spec.memory, :k8s)

    base = %{
      "max_concurrent" => spec.max_concurrent,
      "namespace" => spec.namespace,
      "worker" => %{
        "requests" => %{
          "cpu" => spec.cpu,
          "memory" => spec.memory,
          "ephemeral-storage" => @worker_storage
        },
        "limits" => %{"cpu" => fmt_cpu(2 * cpu_m), "memory" => fmt_mem(2 * mem_b)}
      }
    }

    base
    |> put_unless_empty("placement", %{"node_selector" => spec.node_selector}, spec.node_selector)
    |> put_unless_empty("image_pull_secrets", List.wrap(spec.pull_secret), spec.pull_secret)
  end

  defp put_unless_empty(map, _key, _value, empty) when empty in [nil, %{}], do: map
  defp put_unless_empty(map, key, value, _), do: Map.put(map, key, value)

  defp lease(namespace) do
    %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => %{"name" => "arbiter-controller", "namespace" => namespace},
      "spec" => %{}
    }
  end

  defp service(namespace) do
    %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => %{"name" => "arbiter-controller", "namespace" => namespace},
      "spec" => %{
        "type" => "ClusterIP",
        "selector" => %{"app.kubernetes.io/name" => "arbiter-controller"},
        "ports" => [
          %{"name" => "bridge", "port" => 9443, "targetPort" => 9443, "protocol" => "TCP"},
          %{"name" => "boot", "port" => 9444, "targetPort" => 9444, "protocol" => "TCP"}
        ]
      }
    }
  end
end
