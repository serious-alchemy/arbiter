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
      `?reach=tailscale`, or pointed at the operator's HTTP proxy with `?reach=proxy`).

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

  **Controller egress is an allowlist** (`docs/design/remote-workers.md` §20.4, KH3).
  Workers get no egress but the controller (an allowlist on workers would bypass the
  primary's `Egress` policy and audit). The controller gets the API server (the
  `kubernetes` ClusterIP **and** the `api_cidrs` endpoint addresses: a post-DNAT CNI such
  as k3s's kube-router matches only the latter), cluster DNS
  and exactly one more destination, by `reach`: `direct` the `primary_cidrs` on the port
  of the primary URL; `proxy` the `proxy_cidrs` on the port of `proxy_url`. Neither takes
  a catch-all CIDR, and both refuse to render without theirs. `tailscale` keeps the wide
  `0.0.0.0/0` rule (443, UDP 41641 and 3478): the tailnet control plane and DERP relays
  are hostnames with changing addresses, which a plain `NetworkPolicy` cannot name. That
  residual is the price of the sidecar; `reach=proxy` is the narrow alternative.

  Everything is built as JSON-shaped string-keyed maps and emitted with `Ymlr`, so
  quoting is the emitter's job and no request value is ever spliced into text.
  """

  alias Arbiter.NodeAgent.K8s.{
    AdmissionPolicy,
    ControllerConfig,
    ControllerManifest,
    PodConfig,
    Quantity,
    Quota
  }

  alias Arbiter.Nodes

  @default_namespace "arbiter-workers"
  @default_max 2
  @max_limit 64
  @default_cpu "1"
  @default_memory "2Gi"
  @worker_storage "4Gi"
  # The `kubernetes` Service's ClusterIP on k3s. Always in the controller's API rule.
  @api_cluster_ip "10.43.0.1/32"
  @default_cluster_cidrs ["10.42.0.0/16", "10.43.0.0/16"]

  # Per-worker cpu limits and ephemeral storage come from `Quota.demand/1` (the
  # effective pod size, `LimitRange` defaults included, so the snapshotter's
  # defaulted 400m cpu limit counts). The rest is a flat per-pod allowance over the
  # worker container's own request (a little over the `seed`/`snapshotter` sizes, so
  # run services have room) and what the controller (with room for the tailscale
  # sidecar) reserves. They size the quota; the quota, not these, is what the
  # cluster enforces.
  @pod_overhead_cpu_m 150
  @pod_overhead_mem_mi 320
  @pod_overhead_limit_mem_mi 1024
  # The controller pod's own sizes come from `Quota.controller_resources/0` and
  # `Quota.tailscale_resources/0` (what `ControllerManifest` renders): the controller
  # container's limits bound the LimitRange `max` whatever worker size is configured,
  # and controller + tailscale sidecar are what the quota reserves for it.
  # ephemeral-storage limits: the controller and the tailscale sidecar take the
  # LimitRange default (1Gi each); a pod allows one run service on top.
  @controller_limit_storage_gi 2
  @pod_service_limit_storage_gi 1
  # How many run services (each sized by `services_resources`) the `Pod` max leaves
  # room for beyond the worker and the snapshotter.
  @pod_services 4

  @dns_label ~r/\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/
  @dns_subdomain ~r/\A[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?\z/
  @registry_prefix ~r/\A[a-z0-9][a-z0-9.:\/_-]*\/\z/
  @selector_key ~r/\A([a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?\/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?\z/
  @selector_value ~r/\A([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?\z/

  @type spec :: %{
          node_name: String.t(),
          namespace: String.t(),
          max_concurrent: pos_integer(),
          cpu: String.t(),
          memory: String.t(),
          node_selector: %{optional(String.t()) => String.t()},
          runtime_class: String.t(),
          runtime_handler: String.t(),
          pull_secret: String.t() | nil,
          registries: [%{prefix: String.t(), pull_secret: String.t() | nil}],
          reach: ControllerManifest.reach(),
          admission: boolean(),
          self_upgrade: boolean(),
          api_cidrs: [String.t()],
          cluster_cidrs: [String.t()],
          primary_cidrs: [String.t()],
          proxy_url: String.t() | nil,
          proxy_cidrs: [String.t()],
          part: :all | :bootstrap | :node
        }

  @type server :: [image: String.t(), primary_url: String.t(), registry: String.t()]

  @doc "The namespace the manifests default to."
  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  # ---- input ------------------------------------------------------------------

  @doc """
  Parse the query / form values (string keys): `name` (required), `namespace`, `max`,
  `cpu`, `memory`, `node_selector` (`k=v,k=v`), `runtime_class` and `runtime_handler`
  (`placement.runtime_class` / `placement.runtime_handler`; a `runsc*` handler marks a kernel
  sandbox and relaxes the admission policy's `hostUsers` rule for that class), `pull_secret`, `registries`
  (KH13: `prefix=secret,prefix=secret`, each prefix ending in `/`; a bare prefix pulls anonymously), `reach`
  (`direct|tailscale|proxy`), `primary_cidrs` (required for `direct`), `proxy_url` and
  `proxy_cidrs` (required for `proxy`), `admission` (`policy` or none), `self_upgrade`
  (`on|off`), `api_cidrs` (the API server's node addresses, added to the ClusterIP),
  `cluster_cidrs` (comma separated) and `part`. Unknown keys are
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
      runtime_class: field(params, "runtime_class", &subdomain/1, ""),
      runtime_handler: field(params, "runtime_handler", &subdomain/1, ""),
      pull_secret: field(params, "pull_secret", &subdomain/1, nil),
      registries: field(params, "registries", &registries/1, []),
      reach: field(params, "reach", &reach/1, :direct),
      admission: field(params, "admission", &admission/1, false),
      self_upgrade: field(params, "self_upgrade", &self_upgrade/1, true),
      api_cidrs: field(params, "api_cidrs", &bounded_cidrs/1, []),
      cluster_cidrs: field(params, "cluster_cidrs", &cidrs/1, @default_cluster_cidrs),
      primary_cidrs: field(params, "primary_cidrs", &bounded_cidrs/1, []),
      proxy_url: field(params, "proxy_url", &proxy_url/1, nil),
      proxy_cidrs: field(params, "proxy_cidrs", &bounded_cidrs/1, []),
      part: field(params, "part", &part/1, :all)
    ]

    case Enum.flat_map(fields, fn {key, result} -> error_for(key, result) end) ++
           missing_for_reach(fields) do
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
      runtime_class: v.runtime_class,
      runtime_handler: v.runtime_handler,
      pull_secret: v.pull_secret,
      registries: v.registries,
      reach: v.reach,
      admission: v.admission,
      self_upgrade: v.self_upgrade,
      api_cidrs: v.api_cidrs,
      cluster_cidrs: v.cluster_cidrs,
      primary_cidrs: v.primary_cidrs,
      proxy_url: v.proxy_url,
      proxy_cidrs: v.proxy_cidrs,
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

  # The controller's one egress destination is named by the operator: `direct` needs the
  # primary's CIDRs, `proxy` the proxy's URL and CIDRs. Nothing is guessed (a hostname
  # resolved here would not be what the cluster resolves) and nothing defaults to wide.
  defp missing_for_reach(fields) do
    needed =
      case fields[:reach] do
        {:ok, :direct} -> [primary_cidrs: []]
        {:ok, :proxy} -> [proxy_url: nil, proxy_cidrs: []]
        _ -> []
      end

    for {key, empty} <- needed, fields[key] == {:ok, empty} do
      "#{key} is required for reach=#{elem(fields[:reach], 1)}"
    end
  end

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

  # KH13 (§20.10): `prefix=secret,prefix=secret`. The prefix is a registry path ending in
  # `/`, the secret a Secret name already in the namespace (a name, never a credential);
  # a bare prefix pulls anonymously.
  defp registries(value) do
    parsed =
      value
      |> String.split(",", trim: true)
      |> Enum.map(fn entry ->
        case entry |> String.trim() |> String.split("=", parts: 2) do
          [prefix] -> %{prefix: prefix, pull_secret: nil}
          [prefix, secret] -> %{prefix: prefix, pull_secret: secret}
        end
      end)

    if parsed != [] and Enum.all?(parsed, &registry_entry?/1) and
         length(Enum.uniq_by(parsed, &String.trim_trailing(&1.prefix, "/"))) == length(parsed),
       do: {:ok, parsed},
       else:
         {:error,
          "must be comma separated prefix=secret pairs, each prefix a registry path ending in / " <>
            "(registry.gitlab.com/vstim/=gitlab-vstim), listed once"}
  end

  defp registry_entry?(%{prefix: prefix, pull_secret: secret}) do
    Regex.match?(@registry_prefix, prefix) and
      (secret == nil or Regex.match?(@dns_subdomain, secret))
  end

  defp reach(value) do
    case ControllerManifest.parse_reach(value) do
      {:ok, reach} -> {:ok, reach}
      {:error, _} -> {:error, "must be direct, tailscale or proxy"}
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

  # An egress allowlist entry: a CIDR, and never the catch-all (`0.0.0.0/0`, `::/0`).
  defp bounded_cidrs(value) do
    with {:ok, list} <- cidrs(value) do
      if Enum.any?(list, &String.ends_with?(&1, "/0")),
        do: {:error, "must not contain a /0 (a catch-all is not an allowlist)"},
        else: {:ok, list}
    end
  end

  # The proxy as the controller dials it (`ARB_NODE_PROXY`): scheme, host and an optional
  # port, nothing else. Credentials would put a secret in a manifest that holds none.
  defp proxy_url(value) do
    case URI.new(value) do
      {:ok,
       %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        {:ok, value}

      _ ->
        {:error,
         "must be a bare http(s) URL without credentials, such as http://proxy.example:3128"}
    end
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
        proxy_url: spec.proxy_url,
        self_upgrade: spec.self_upgrade
      )

    %{
      bootstrap:
        [namespace(spec), priority_class(), quota(spec), limit_range(spec)] ++
          network_policies(spec, server) ++ admission(spec, server),
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

  # ---- Helm values (KH9) ----------------------------------------------------------

  @typedoc """
  What only the primary knows for a Helm install: `:primary_url`, the worker image
  `:registry` prefix (optional: the chart does not need it for its own image) and the
  `:chart_ref` the node reports back for `helm upgrade` (optional).
  """
  @type values_server :: [
          primary_url: String.t(),
          registry: String.t(),
          chart_ref: String.t(),
          image_repository: String.t(),
          image_tag: String.t()
        ]

  @doc """
  The `arbiter-node` chart's values for `spec` (`charts/arbiter-node/values.yaml`), as a
  string-keyed map holding only what differs from the chart's defaults and no secret. The
  quota and LimitRange figures are the ones `render/2` computes, so `helm install` and
  `kubectl apply` bound a namespace identically, whatever `max`, `cpu` and `memory` are.

  The namespace is not a value (Helm takes it from `--namespace`). `self_upgrade` is not
  one either: the chart's Role cannot patch its Deployment. `{:error, {:missing, key}}`
  when `server` lacks `:primary_url`, or `:registry` for values that name one
  (`admission`, `pull_secret`).
  """
  @spec values(spec(), values_server()) :: {:ok, map()} | {:error, {:missing, atom()}}
  def values(spec, server) do
    registry = present(Keyword.get(server, :registry))

    with {:ok, url} <- required(server, :primary_url),
         :ok <- registry_needed(spec, registry) do
      {:ok,
       %{
         "mode" => to_string(spec.part),
         "node" => %{"name" => spec.node_name},
         "primary" => %{"url" => url},
         "concurrency" => %{"max" => spec.max_concurrent},
         "workers" => worker_values(spec),
         "reach" => reach_values(spec),
         "networkPolicy" => network_values(spec),
         "quota" => %{"hard" => quota(spec)["spec"]["hard"]},
         "limitRange" => limit_range_values(spec)
       }
       |> put_value("chartRef", present(Keyword.get(server, :chart_ref)))
       |> put_value("image", image_values(server))
       |> put_value("placement", placement_values(spec))
       |> put_value("admissionPolicy", if(spec.admission, do: %{"enabled" => true}))
       |> put_value("registries", registry_values(spec, registry))}
    end
  end

  # The running release's controller image, so a default install pulls what exists.
  defp image_values(server) do
    for {key, opt} <- [{"repository", :image_repository}, {"tag", :image_tag}],
        value = present(Keyword.get(server, opt)),
        into: %{},
        do: {key, value}
  end

  @doc "`values/2` as a values file, headed by a comment (no secret: safe to commit)."
  @spec values_yaml(spec(), values_server()) :: {:ok, String.t()} | {:error, {:missing, atom()}}
  def values_yaml(spec, server) do
    with {:ok, values} <- values(spec, server) do
      {:ok,
       """
       # Arbiter cluster node #{spec.node_name} -- chart values rendered by the primary for
       # the arbiter-node Helm chart. This file contains no secret. Install into namespace
       # #{spec.namespace} after creating the namespace and the arbiter-join Secret.
       """ <> strip_document_marker(Ymlr.document!(values))}
    end
  end

  defp required(server, key) do
    case present(Keyword.get(server, key)) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp registry_needed(spec, nil) do
    if spec.admission or spec.pull_secret, do: {:error, {:missing, :registry}}, else: :ok
  end

  defp registry_needed(_spec, _registry), do: :ok

  defp put_value(map, _key, value) when value in [nil, %{}, []], do: map
  defp put_value(map, key, value), do: Map.put(map, key, value)

  defp worker_values(spec) do
    worker = config(spec)["worker"]

    %{
      "requests" => Map.take(worker["requests"], ~w(cpu memory ephemeral-storage)),
      "limits" => Map.take(worker["limits"], ~w(cpu memory))
    }
  end

  defp placement_values(spec) do
    %{}
    |> put_value("nodeSelector", spec.node_selector)
    |> put_value("runtimeClassName", present(spec.runtime_class))
  end

  defp reach_values(%{reach: :proxy} = spec),
    do: %{"mode" => "proxy", "proxy" => %{"url" => spec.proxy_url, "cidrs" => spec.proxy_cidrs}}

  defp reach_values(spec), do: %{"mode" => to_string(spec.reach)}

  defp network_values(spec) do
    %{"apiServerCIDRs" => api_cidrs(spec), "clusterCIDRs" => spec.cluster_cidrs}
    |> put_value("controllerEgress", put_value(%{}, "primaryCIDRs", spec.primary_cidrs))
  end

  # The raw LimitRange's `Container` and `Pod` entries, in the chart's key names.
  defp limit_range_values(spec) do
    [container, pod] = limit_range(spec)["spec"]["limits"]

    %{
      "container" => Map.take(container, ~w(defaultRequest default max maxLimitRequestRatio)),
      "pod" => Map.take(pod, ~w(max))
    }
  end

  defp registry_values(_spec, nil), do: nil

  defp registry_values(%{registries: [_ | _] = registries}, registry) do
    extra =
      for %{prefix: prefix, pull_secret: secret} <- registries do
        put_value(%{"prefix" => prefix}, "pullSecret", secret)
      end

    default = %{"prefix" => registry}
    norm = String.trim_trailing(registry, "/")

    if Enum.any?(extra, &(String.trim_trailing(&1["prefix"], "/") == norm)),
      do: extra,
      else: [default | extra]
  end

  defp registry_values(%{admission: false, pull_secret: nil}, _registry), do: nil

  defp registry_values(spec, registry),
    do: [put_value(%{"prefix" => registry}, "pullSecret", spec.pull_secret)]

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
    gi = 1_073_741_824
    {:ok, storage} = Quantity.memory(@worker_storage, :k8s)
    {:ok, controller_config} = ControllerConfig.parse(Ymlr.document!(config(spec)))
    pod = Quota.demand(controller_config)
    controller = controller_pod_demand()

    hard = %{
      "pods" => Integer.to_string(n + 2),
      "requests.cpu" => fmt_cpu(n * (cpu_m + @pod_overhead_cpu_m) + controller["requests.cpu"]),
      "requests.memory" =>
        fmt_mem(n * (mem_b + @pod_overhead_mem_mi * mi) + controller["requests.memory"]),
      "limits.cpu" => fmt_cpu(n * pod["limits.cpu"] + controller["limits.cpu"]),
      "limits.memory" =>
        fmt_mem(n * (2 * mem_b + @pod_overhead_limit_mem_mi * mi) + controller["limits.memory"]),
      # `storage` once more for the controller (and its sidecar) and the run services.
      "requests.ephemeral-storage" => fmt_mem(n * pod["requests.ephemeral-storage"] + storage),
      # §20.2: the runaway write is bounded by the container limit and this quota, not
      # only by an eviction tick.
      "limits.ephemeral-storage" =>
        fmt_mem(
          n * (pod["limits.ephemeral-storage"] + @pod_service_limit_storage_gi * gi) +
            @controller_limit_storage_gi * gi
        )
    }

    %{
      "apiVersion" => "v1",
      "kind" => "ResourceQuota",
      "metadata" => %{"name" => "arbiter-workers", "namespace" => spec.namespace},
      "spec" => %{"hard" => hard}
    }
  end

  # Controller container + tailscale sidecar (sized for the worst case, with the sidecar).
  defp controller_pod_demand do
    Map.merge(
      Quota.demand_of(Quota.controller_resources()),
      Quota.demand_of(Quota.tailscale_resources()),
      fn _k, a, b -> a + b end
    )
  end

  defp fmt_cpu(millis), do: Quantity.format_cpu(millis)
  defp fmt_mem(bytes), do: Quantity.format_memory(bytes)

  # §20.2: the cluster, not only the builder, bounds a pod. `max` caps what one
  # container may ask for (cpu 2x the worker limit, memory the worker limit,
  # ephemeral-storage the work + tmp volumes) and `maxLimitRequestRatio` how far a limit
  # may sit above its request. The `Pod` max is the effective pod: the worker plus the
  # native `snapshotter` sidecar plus room for run services. A `Pod` max equal to the
  # worker limit would refuse the worker's own pod (H14).
  defp limit_range(spec) do
    {:ok, controller_config} = ControllerConfig.parse(Ymlr.document!(config(spec)))
    {:ok, worker_cpu} = Quantity.cpu(controller_config.worker["limits"]["cpu"], :k8s)
    {:ok, worker_mem} = Quantity.memory(controller_config.worker["limits"]["memory"], :k8s)
    pod = Quota.demand(controller_config)
    aux = Quota.demand_of(controller_config.services_resources)
    controller = controller_pod_demand()
    container = Quota.demand_of(Quota.controller_resources())

    container_max = %{
      "cpu" => fmt_cpu(max(2 * worker_cpu, container["limits.cpu"])),
      "memory" => fmt_mem(max(worker_mem, container["limits.memory"])),
      "ephemeral-storage" => controller_config.worker["limits"]["ephemeral-storage"]
    }

    pod_max = %{
      "cpu" =>
        fmt_cpu(
          max(pod["limits.cpu"] + @pod_services * aux["limits.cpu"], controller["limits.cpu"])
        ),
      "memory" =>
        fmt_mem(
          max(
            pod["limits.memory"] + @pod_services * aux["limits.memory"],
            controller["limits.memory"]
          )
        ),
      "ephemeral-storage" =>
        fmt_mem(pod["limits.ephemeral-storage"] + @pod_services * aux["limits.ephemeral-storage"])
    }

    %{
      "apiVersion" => "v1",
      "kind" => "LimitRange",
      "metadata" => %{"name" => "arbiter-workers", "namespace" => spec.namespace},
      "spec" => %{
        "limits" => [
          %{
            "type" => "Container",
            # The quota counts ephemeral-storage requests and limits, so a container that
            # names none (the controller, the tailscale sidecar) would be refused without
            # a default, and one with no limit would otherwise be given the `max`.
            "defaultRequest" => Quota.limit_range_default_request(),
            "default" => Quota.limit_range_default_limit(),
            "max" => container_max,
            "maxLimitRequestRatio" => %{"cpu" => "4", "memory" => "2"}
          },
          %{"type" => "Pod", "max" => pod_max}
        ]
      }
    }
  end

  # K§9.1. Workers get no DNS and one destination (the controller's bridge and boot
  # ports); the controller gets the API server, DNS and its `reach` destination (the
  # primary's CIDRs, the proxy's, or the tailscale control plane; KH3) but never the
  # pod or service network.
  defp network_policies(spec, server) do
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
            "to" => Enum.map(api_cidrs(spec), &%{"ipBlock" => %{"cidr" => &1}}),
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
          reach_rule(spec, server)
        ]
      })
    ]
  end

  # The controller dials the API server by the `kubernetes` Service's ClusterIP, but whether
  # a policy sees that address or the endpoint it is DNATed to depends on the CNI:
  # kube-router (k3s) evaluates egress after DNAT, so only `<node IP>:6443` matches there.
  # The ClusterIP is therefore always listed and `api_cidrs` adds to it, never replaces it:
  # one rule that holds under both orderings.
  defp api_cidrs(spec), do: Enum.uniq([@api_cluster_ip | spec.api_cidrs])

  # The controller's last egress rule: how it reaches the primary (KH3).
  defp reach_rule(%{reach: :direct} = spec, server) do
    %{
      "to" => Enum.map(spec.primary_cidrs, &%{"ipBlock" => %{"cidr" => &1}}),
      "ports" => [
        %{"protocol" => "TCP", "port" => url_port(Keyword.fetch!(server, :primary_url))}
      ]
    }
  end

  defp reach_rule(%{reach: :proxy} = spec, _server) do
    %{
      "to" => Enum.map(spec.proxy_cidrs, &%{"ipBlock" => %{"cidr" => &1}}),
      "ports" => [%{"protocol" => "TCP", "port" => url_port(spec.proxy_url)}]
    }
  end

  # The tailnet control plane and DERP relays have no stable addresses: see the moduledoc.
  defp reach_rule(%{reach: :tailscale} = spec, _server) do
    %{
      "to" => [%{"ipBlock" => %{"cidr" => "0.0.0.0/0", "except" => spec.cluster_cidrs}}],
      "ports" => [
        %{"protocol" => "TCP", "port" => 443},
        %{"protocol" => "UDP", "port" => 41_641},
        %{"protocol" => "UDP", "port" => 3478}
      ]
    }
  end

  # `URI.parse/1` knows the scheme defaults (https 443, http 80).
  defp url_port(url), do: URI.parse(url).port || 443

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
        namespace: spec.namespace,
        registries: Enum.map(spec.registries, & &1.prefix),
        sandbox_classes: sandbox_classes(spec)
      )

  defp sandbox_classes(spec) do
    if PodConfig.kernel_sandboxed?(%{
         "runtime_class" => spec.runtime_class,
         "runtime_handler" => spec.runtime_handler
       }),
       do: [spec.runtime_class],
       else: []
  end

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
        rule([""], ["events"], ["get", "list"]),
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
    |> put_runtime(spec)
    |> put_unless_empty("image_pull_secrets", List.wrap(spec.pull_secret), spec.pull_secret)
    |> put_unless_empty("registries", registry_entries(spec.registries), spec.registries)
  end

  defp put_runtime(config, %{runtime_class: ""}), do: config

  defp put_runtime(config, spec) do
    runtime = %{"runtime_class" => spec.runtime_class, "runtime_handler" => spec.runtime_handler}
    Map.update(config, "placement", runtime, &Map.merge(&1, runtime))
  end

  defp registry_entries(registries) do
    for %{prefix: prefix, pull_secret: secret} <- registries do
      if secret,
        do: %{"prefix" => prefix, "pull_secret" => secret},
        else: %{"prefix" => prefix}
    end
  end

  defp put_unless_empty(map, _key, _value, empty) when empty in [nil, %{}, []], do: map
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
