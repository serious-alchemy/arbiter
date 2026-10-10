defmodule Arbiter.NodeAgent.K8s.Quota do
  @moduledoc """
  `ResourceQuota` headroom (`docs/design/remote-workers.md` K§4.2): how many more
  worker pods fit the namespace right now,
  `min over resources of floor((hard - used) / per-pod demand)`. Pure: the
  controller reads `resourcequotas` (`get/list/watch`, namespaced, read-only) and
  hands the items here.

  `demand/1` is what one pod asks for, derived from the same config the builder
  reads: the worker container plus the `seed` and `snapshotter` containers at
  `services_resources` (a quota that counts requests needs every container to state
  some). Test-service sidecars depend on the run and are not counted; the API
  server's own 403 on `POST pods` is the backstop for them.

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

  @doc "One pod's demand, keyed by quota resource name."
  @spec demand(map()) :: demand()
  def demand(config) do
    worker = config.worker
    services = config.services_resources

    %{"pods" => 1}
    |> add_resources("requests", [worker["requests"], services["requests"], services["requests"]])
    |> add_resources("limits", [worker["limits"], services["limits"], services["limits"]])
  end

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
