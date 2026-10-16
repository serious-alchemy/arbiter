defmodule Arbiter.NodeAgent.K8s.Quota do
  @moduledoc """
  `ResourceQuota` headroom (`docs/design/remote-workers.md` K§4.2): how many more
  worker pods fit the namespace right now,
  `min over resources of floor((hard - used) / per-pod demand)`. Pure: the
  controller reads `resourcequotas` (`get/list/watch`, namespaced, read-only) and
  hands the items here.

  `demand/1` is what one pod asks for, derived from the same config the builder
  reads and sized the way Kubernetes sizes a pod for quota: the worker, plus the
  restartable `snapshotter` sidecar, with the `seed` init container counting only as
  a max, and the install's `LimitRange` defaults (shared with `InstallManifest`)
  filling whatever a container leaves unset. Test-service sidecars depend on the
  run and are not counted; the API server's own 403 on `POST pods` is the backstop
  for them.

  Only resources a quota bounds *and* a pod demands count. A namespace with no
  quota (or none that names those resources) is `:unbounded`. A quantity the
  parser cannot read is treated as **no room**: guessing "unbounded" would
  over-admit into a quota we cannot see the size of.
  """

  alias Arbiter.NodeAgent.K8s.Quantity

  # Quota resource names that mean the same thing as a prefixed one.
  @aliases %{
    "count/pods" => "pods",
    "cpu" => "requests.cpu",
    "memory" => "requests.memory",
    "ephemeral-storage" => "requests.ephemeral-storage"
  }

  @type demand :: %{optional(String.t()) => non_neg_integer()}

  # What the install's `LimitRange` gives a container that states nothing (K§4.3). The
  # install manifest renders these same maps, so the quota arithmetic here and the
  # object the API server enforces cannot drift apart.
  @limit_range_default_request %{
    "cpu" => "100m",
    "memory" => "128Mi",
    "ephemeral-storage" => "128Mi"
  }
  # The default limit stays within the `LimitRange`'s `maxLimitRequestRatio` (cpu 4,
  # memory 2) of the default request, so a container that states nothing is admitted;
  # and the ephemeral-storage default stops the `max` from becoming every sidecar's
  # limit (a `LimitRange` with a `max` and no `default` defaults the limit to the max).
  @limit_range_default_limit %{
    "cpu" => "400m",
    "memory" => "256Mi",
    "ephemeral-storage" => "1Gi"
  }

  # The controller pod's containers, stated (never defaulted): `ControllerManifest`
  # renders these and `InstallManifest` sizes the `LimitRange` / quota from them.
  @controller_resources %{
    "requests" => %{"cpu" => "250m", "memory" => "256Mi"},
    "limits" => %{"cpu" => "1", "memory" => "512Mi"}
  }
  @tailscale_resources %{
    "requests" => %{"cpu" => "125m", "memory" => "128Mi"},
    "limits" => %{"cpu" => "500m", "memory" => "256Mi"}
  }

  @doc "Resources of the controller container (shared by the Deployment and the install sizing)."
  @spec controller_resources() :: map()
  def controller_resources, do: @controller_resources

  @doc "Resources of the tailscale sidecar in the controller pod."
  @spec tailscale_resources() :: map()
  def tailscale_resources, do: @tailscale_resources

  @doc "The `LimitRange` `defaultRequest`: applied to a container with no request and no limit."
  @spec limit_range_default_request() :: %{String.t() => String.t()}
  def limit_range_default_request, do: @limit_range_default_request

  @doc "The `LimitRange` `default` (limit): applied to a container that names no limit."
  @spec limit_range_default_limit() :: %{String.t() => String.t()}
  def limit_range_default_limit, do: @limit_range_default_limit

  @doc """
  One pod's demand, keyed by quota resource name: the Kubernetes *effective* pod
  size of the pod the builder makes, a `seed` init container (runs alone, before
  the sidecar), a restartable `snapshotter` sidecar and the worker, with the
  `LimitRange` defaults applied.
  """
  @spec demand(map()) :: demand()
  def demand(config) do
    aux = %{"resources" => config.services_resources}

    effective_pod(%{
      "spec" => %{
        "initContainers" => [
          Map.put(aux, "name", "seed"),
          aux |> Map.put("name", "snapshotter") |> Map.put("restartPolicy", "Always")
        ],
        "containers" => [%{"name" => "worker", "resources" => config.worker}]
      }
    })
  end

  @doc """
  The effective request/limit of a Pod (or pod template) map, as the quota
  charges it: `max(app containers + restartable init sidecars, peak over the
  init containers in order)` where a plain init container counts with the sidecars
  started before it and a sidecar keeps counting for everything after it.
  `LimitRange` defaults fill what a container leaves unset: a request defaults to
  its own limit, then to the `defaultRequest`; a limit to the `default`.
  """
  @spec effective_pod(map()) :: demand()
  def effective_pod(pod) do
    spec = pod["spec"] || %{}
    init = spec["initContainers"] || []
    app = Enum.map(spec["containers"] || [], &container_demand/1)

    {peak, sidecars} =
      Enum.reduce(init, {%{}, %{}}, fn container, {peak, sidecars} ->
        own = container_demand(container)

        if container["restartPolicy"] == "Always" do
          sidecars = sum_demands([sidecars, own])
          {max_demands(peak, sidecars), sidecars}
        else
          {max_demands(peak, sum_demands([sidecars, own])), sidecars}
        end
      end)

    steady = sum_demands([sidecars | app])
    Map.put(max_demands(peak, steady), "pods", 1)
  end

  @doc """
  What one container with `resources` (`requests` / `limits`) is charged, the
  `LimitRange` defaults applied.
  """
  @spec demand_of(map()) :: demand()
  def demand_of(resources), do: container_demand(%{"resources" => resources})

  @doc "A quota quantity as an integer (millicores for cpu, bytes otherwise), or `:error`."
  @spec parse_quantity(String.t(), String.t() | integer()) :: non_neg_integer() | :error
  def parse_quantity(name, value), do: parse(name, value)

  defp container_demand(container) do
    resources = container["resources"] || %{}
    limits = resources["limits"] || %{}
    requests = resources["requests"] || %{}
    default_limits = @limit_range_default_limit

    effective_limits = Map.merge(default_limits, limits)

    effective_requests =
      @limit_range_default_request
      |> Map.merge(Map.take(limits, Map.keys(@limit_range_default_request)))
      |> Map.merge(requests)

    %{}
    |> add_resources("requests", [effective_requests])
    |> add_resources("limits", [effective_limits])
  end

  defp sum_demands(demands) do
    Enum.reduce(demands, %{}, fn d, acc -> Map.merge(acc, d, fn _k, a, b -> a + b end) end)
  end

  defp max_demands(a, b), do: Map.merge(a, b, fn _k, x, y -> max(x, y) end)

  @doc """
  Pods that still fit: a non-negative integer, or `:unbounded` when no quota bounds
  what a pod demands. `quotas` are `ResourceQuota` objects (string keys).
  """
  @spec headroom([map()], demand()) :: non_neg_integer() | :unbounded
  def headroom(quotas, demand) do
    quotas
    |> Enum.flat_map(&quota_headrooms(&1, demand))
    |> case do
      [] -> :unbounded
      rooms -> Enum.min(rooms)
    end
  end

  # -- internals ----------------------------------------------------------------

  defp add_resources(demand, prefix, resource_maps) do
    Enum.reduce(resource_maps, demand, fn resources, acc ->
      Enum.reduce(resources || %{}, acc, fn {name, value}, acc ->
        key = prefix <> "." <> name
        Map.update(acc, key, parse(name, value), &(&1 + parse(name, value)))
      end)
    end)
  end

  defp quota_headrooms(quota, demand) do
    status = quota["status"] || %{}
    hard = non_empty(status["hard"]) || get_in(quota, ["spec", "hard"]) || %{}
    used = status["used"] || %{}

    for {raw_name, limit} <- hard,
        name = Map.get(@aliases, raw_name, raw_name),
        per_pod = Map.get(demand, name, 0),
        per_pod > 0 do
      room(parse(name, limit), parse(name, used[raw_name] || "0"), per_pod)
    end
  end

  defp room(:error, _used, _per_pod), do: 0
  defp room(_hard, :error, _per_pod), do: 0
  defp room(hard, used, per_pod), do: max(div(hard - used, per_pod), 0)

  defp non_empty(%{} = map) when map_size(map) > 0, do: map
  defp non_empty(_), do: nil

  # Pod counts are plain integers; cpu is millicores; everything else is bytes.
  defp parse("pods", value), do: integer(value)
  defp parse(name, value), do: quantity(String.split(name, ".") |> List.last(), value)

  defp integer(n) when is_integer(n), do: n

  defp integer(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp integer(_), do: :error

  defp quantity(_resource, 0), do: 0

  defp quantity(resource, value) when is_binary(value) do
    if zero?(value) do
      0
    else
      parsed =
        if resource == "cpu", do: Quantity.cpu(value, :k8s), else: Quantity.memory(value, :k8s)

      case parsed do
        {:ok, n} -> n
        :error -> :error
      end
    end
  end

  defp quantity(_resource, _value), do: :error

  defp zero?(value), do: Regex.match?(~r/\A0+(\.0+)?([a-zA-Z]{1,2})?\z/, value)
end
