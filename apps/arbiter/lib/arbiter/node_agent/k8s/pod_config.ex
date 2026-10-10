defmodule Arbiter.NodeAgent.K8s.PodConfig do
  @moduledoc """
  The configuration `Arbiter.NodeAgent.K8s.PodSpec.build/2` reads, as a **closed
  schema** (`docs/design/remote-workers.md` §4.1): the operator-settable ConfigMap
  keys plus the facts the controller itself knows per run. Anything else is
  `{:error, {:bad_config, {:unknown_key, key}}}`.

  *Not settable, ever*: the security context, volumes, service account, network,
  host namespaces and the image. They have no key here because the builder owns
  them; a config that names one is refused rather than ignored, so a mistaken
  `security_context:` in a ConfigMap is a loud error and not a silent no-op.

  Top-level keys are atoms (the loader, K5, converts the YAML); nested maps may
  use atom or string keys and are normalised to strings, which is what lands in
  the pod.

  | key | |
  |---|---|
  | `registry` | **required**: the image prefix the admission policy allows (`registry.example/arbiter`) |
  | `install_id`, `node_id` | **required**: the labels the reaper keys on |
  | `owner_uid` | **required**: the controller Deployment's UID (owner reference) |
  | `bridge_addr`, `gate_addr` | **required**: the controller Service address and the netpol-gate address (`host:port`) |
  | `boot_nonce` | **required**: the single-use 256-bit nonce for this pod |
  | `max_wall_s` | **required**: the run's wall budget; the pod deadline is this plus 1800 |
  | `namespace` | default `arbiter-workers` |
  | `worker` | `requests`, `limits`, `work_size_limit`, `tmp_size_limit` |
  | `services_resources` | `requests` / `limits` for the `seed`, `snapshotter` and service containers |
  | `placement` | `node_selector`, `tolerations`, `priority_class`, `runtime_class` |
  | `image_pull_secrets` | names |
  | `timeouts` | `grace_s` (pod grace), `gate_timeout_s`; the others belong to the controller |
  | `snapshot_interval_s` | default 300 |
  | `service_image_allowlist` | extra service image prefixes (`docker.io/pgsty/`) |
  """

  alias Arbiter.NodeAgent.K8s.Quantity

  @required ~w(registry install_id node_id owner_uid bridge_addr gate_addr boot_nonce max_wall_s)a
  @optional ~w(namespace worker services_resources placement image_pull_secrets timeouts snapshot_interval_s service_image_allowlist)a

  @dns_re ~r/\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/
  @subdomain_re ~r/\A[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?\z/
  @label_re ~r/\A([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?\z/
  @registry_re ~r/\A[a-z0-9][a-z0-9.-]*(:\d{1,5})?(\/[a-z0-9][a-z0-9._-]*)*\z/
  @addr_re ~r/\A[A-Za-z0-9][A-Za-z0-9.-]*(:\d{1,5})?\z/
  @nonce_re ~r/\A[A-Za-z0-9_-]{16,128}\z/
  @uid_re ~r/\A[A-Za-z0-9-]{1,64}\z/
  @prefix_re ~r/\A[a-z0-9][a-z0-9.:\/_-]*\/\z/

  @resource_names ~w(cpu memory ephemeral-storage)
  @toleration_keys ~w(key operator value effect tolerationSeconds)
  @timeout_keys ~w(schedule_s pull_s boot_s grace_s retain_failed_s gate_timeout_s)
  @max_wall_s 31_536_000

  @defaults %{
    namespace: "arbiter-workers",
    worker: %{
      "requests" => %{"cpu" => "1", "memory" => "2Gi", "ephemeral-storage" => "4Gi"},
      "limits" => %{"cpu" => "2", "memory" => "4Gi"},
      "work_size_limit" => "8Gi",
      "tmp_size_limit" => "1Gi"
    },
    services_resources: %{
      "requests" => %{"cpu" => "100m", "memory" => "256Mi"},
      "limits" => %{"memory" => "512Mi"}
    },
    placement: %{
      "node_selector" => %{},
      "tolerations" => [],
      "priority_class" => "arbiter-worker",
      "runtime_class" => ""
    },
    image_pull_secrets: [],
    timeouts: %{"grace_s" => 120, "gate_timeout_s" => 30},
    snapshot_interval_s: 300,
    service_image_allowlist: []
  }

  @type t :: %{required(atom()) => term()}

  @doc "Validate `config` (a map or keyword list) and fill the defaults."
  @spec normalize(map() | keyword()) :: {:ok, t()} | {:error, {:bad_config, term()}}
  def normalize(config) when is_list(config), do: config |> Map.new() |> normalize()

  def normalize(config) when is_map(config) do
    config = Map.drop(config, [:__struct__])

    with :ok <- known_keys(config),
         :ok <- required(config),
         {:ok, registry} <- fetch(config, :registry, &registry/1),
         {:ok, install_id} <- fetch(config, :install_id, &label/1),
         {:ok, node_id} <- fetch(config, :node_id, &label/1),
         {:ok, owner_uid} <- fetch(config, :owner_uid, &matching(&1, @uid_re)),
         {:ok, bridge_addr} <- fetch(config, :bridge_addr, &matching(&1, @addr_re)),
         {:ok, gate_addr} <- fetch(config, :gate_addr, &matching(&1, @addr_re)),
         {:ok, boot_nonce} <- fetch(config, :boot_nonce, &matching(&1, @nonce_re)),
         {:ok, max_wall_s} <- fetch(config, :max_wall_s, &int(&1, 1..@max_wall_s//1)),
         {:ok, namespace} <- optional(config, :namespace, &matching(&1, @dns_re)),
         {:ok, worker} <- optional(config, :worker, &worker/1),
         {:ok, services} <- optional(config, :services_resources, &resources/1),
         {:ok, placement} <- optional(config, :placement, &placement/1),
         {:ok, pull} <- optional(config, :image_pull_secrets, &names/1),
         {:ok, timeouts} <- optional(config, :timeouts, &timeouts/1),
         {:ok, interval} <- optional(config, :snapshot_interval_s, &int(&1, 10..3600//1)),
         {:ok, allow} <- optional(config, :service_image_allowlist, &prefixes/1) do
      {:ok,
       %{
         registry: registry,
         install_id: install_id,
         node_id: node_id,
         owner_uid: owner_uid,
         bridge_addr: bridge_addr,
         gate_addr: gate_addr,
         boot_nonce: boot_nonce,
         max_wall_s: max_wall_s,
         namespace: namespace,
         worker: worker,
         services_resources: services,
         placement: placement,
         image_pull_secrets: pull,
         timeouts: timeouts,
         snapshot_interval_s: interval,
         service_image_allowlist: allow
       }}
    end
  end

  def normalize(_other), do: bad({:not_a_map, :config})

  # -- keys ---------------------------------------------------------------------------

  defp known_keys(config) do
    case Enum.find(Map.keys(config), &(&1 not in @required and &1 not in @optional)) do
      nil -> :ok
      key -> bad({:unknown_key, key})
    end
  end

  defp required(config) do
    case Enum.find(@required, &(not Map.has_key?(config, &1) or Map.get(config, &1) == nil)) do
      nil -> :ok
      key -> bad({:missing, key})
    end
  end

  defp fetch(config, key, validate) do
    case validate.(Map.fetch!(config, key)) do
      {:ok, _} = ok -> ok
      :error -> bad({:bad_value, key})
      {:error, reason} -> bad(reason)
    end
  end

  defp optional(config, key, validate) do
    case Map.fetch(config, key) do
      :error -> {:ok, Map.fetch!(@defaults, key)}
      {:ok, nil} -> {:ok, Map.fetch!(@defaults, key)}
      {:ok, _} -> fetch(config, key, merge_default(key, validate))
    end
  end

  # Nested maps are merged over the defaults, so a ConfigMap that sets only
  # `worker.limits.memory` keeps the rest.
  defp merge_default(key, validate)
       when key in [:worker, :services_resources, :placement, :timeouts] do
    fn value ->
      with {:ok, normal} <- validate.(value),
           do: {:ok, deep_merge(Map.fetch!(@defaults, key), normal)}
    end
  end

  defp merge_default(_key, validate), do: validate

  defp deep_merge(base, over) do
    Map.merge(base, over, fn
      _k, %{} = a, %{} = b -> deep_merge(a, b)
      _k, _a, b -> b
    end)
  end

  # -- scalars --------------------------------------------------------------------------

  defp registry(value) when is_binary(value),
    do: if(Regex.match?(@registry_re, value), do: {:ok, value}, else: :error)

  defp registry(_), do: :error

  defp label(value) when is_binary(value) and byte_size(value) in 1..63,
    do: matching(value, @label_re)

  defp label(_), do: :error

  defp matching(value, re) when is_binary(value),
    do: if(Regex.match?(re, value), do: {:ok, value}, else: :error)

  defp matching(_, _), do: :error

  defp int(value, range) when is_integer(value),
    do: if(value in range, do: {:ok, value}, else: :error)

  defp int(_, _), do: :error

  defp names(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and Regex.match?(@subdomain_re, &1))),
      do: {:ok, list},
      else: :error
  end

  defp names(_), do: :error

  defp prefixes(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and Regex.match?(@prefix_re, &1))),
      do: {:ok, list},
      else: {:error, {:bad_value, :service_image_allowlist}}
  end

  defp prefixes(_), do: :error

  # -- nested ---------------------------------------------------------------------------------

  defp worker(%{} = map) do
    map = stringify(map)

    with :ok <- only_keys(map, ~w(requests limits work_size_limit tmp_size_limit), :worker),
         {:ok, res} <- resources(Map.take(map, ~w(requests limits))),
         {:ok, work} <- size(map, "work_size_limit"),
         {:ok, tmp} <- size(map, "tmp_size_limit") do
      {:ok, res |> Map.merge(work) |> Map.merge(tmp)}
    end
  end

  defp worker(_), do: :error

  defp size(map, key) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, %{}}

      {:ok, value} ->
        if Quantity.valid?(value),
          do: {:ok, %{key => value}},
          else: {:error, {:bad_quantity, value}}
    end
  end

  defp resources(%{} = map) do
    map = stringify(map)

    with :ok <- only_keys(map, ~w(requests limits), :resources),
         {:ok, requests} <- quantities(Map.get(map, "requests", %{})),
         {:ok, limits} <- quantities(Map.get(map, "limits", %{})) do
      {:ok,
       Enum.reject(%{"requests" => requests, "limits" => limits}, fn {_, v} -> v == %{} end)
       |> Map.new()}
    end
  end

  defp resources(_), do: :error

  defp quantities(%{} = map) do
    map = stringify(map)

    with :ok <- only_keys(map, @resource_names, :resource) do
      case Enum.find(map, fn {_k, v} -> not Quantity.valid?(v) end) do
        nil -> {:ok, map}
        {_k, v} -> {:error, {:bad_quantity, v}}
      end
    end
  end

  defp quantities(_), do: :error

  defp placement(%{} = map) do
    map = stringify(map)

    with :ok <-
           only_keys(map, ~w(node_selector tolerations priority_class runtime_class), :placement),
         {:ok, selector} <- node_selector(Map.get(map, "node_selector", %{})),
         {:ok, tolerations} <- tolerations(Map.get(map, "tolerations", [])),
         {:ok, priority} <- name_or_empty(Map.get(map, "priority_class", "arbiter-worker")),
         {:ok, runtime} <- name_or_empty(Map.get(map, "runtime_class", "")) do
      {:ok,
       %{
         "node_selector" => selector,
         "tolerations" => tolerations,
         "priority_class" => priority,
         "runtime_class" => runtime
       }}
    end
  end

  defp placement(_), do: :error

  defp node_selector(%{} = map) do
    map = stringify(map)

    if Enum.all?(map, fn {k, v} ->
         is_binary(v) and
           Regex.match?(~r/\A([a-z0-9.-]+\/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?\z/, k) and
           Regex.match?(@label_re, v)
       end),
       do: {:ok, map},
       else: {:error, {:bad_value, :node_selector}}
  end

  defp node_selector(_), do: {:error, {:bad_value, :node_selector}}

  defp tolerations(list) when is_list(list) do
    normal = Enum.map(list, &if(is_map(&1), do: stringify(&1), else: &1))

    if Enum.all?(normal, &toleration?/1),
      do: {:ok, normal},
      else: {:error, {:bad_value, :tolerations}}
  end

  defp tolerations(_), do: {:error, {:bad_value, :tolerations}}

  defp toleration?(%{} = t) do
    Map.keys(t) -- @toleration_keys == [] and Enum.all?(t, &toleration_field?/1)
  end

  defp toleration?(_), do: false

  defp toleration_field?({"tolerationSeconds", v}), do: is_integer(v)
  defp toleration_field?({_k, v}), do: is_binary(v)

  defp name_or_empty(""), do: {:ok, ""}
  defp name_or_empty(value), do: matching(value, @subdomain_re)

  defp timeouts(%{} = map) do
    map = stringify(map)

    with :ok <- only_keys(map, @timeout_keys, :timeouts) do
      if Enum.all?(map, fn {_k, v} -> is_integer(v) and v >= 0 and v <= 86_400 end),
        do: {:ok, map},
        else: {:error, {:bad_value, :timeouts}}
    end
  end

  defp timeouts(_), do: :error

  defp only_keys(map, allowed, where) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:unknown_key, {where, key}}}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp bad(reason), do: {:error, {:bad_config, reason}}
end
