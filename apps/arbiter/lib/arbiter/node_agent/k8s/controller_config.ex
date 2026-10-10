defmodule Arbiter.NodeAgent.K8s.ControllerConfig do
  @moduledoc """
  The operator's `arbiter-controller-config` ConfigMap as a **closed schema**
  (`docs/design/remote-workers.md` K§4.1): `controller.yaml` text (or its decoded
  map) in, a validated config out. Pure; `Arbiter.NodeAgent.K8s.ConfigLoader` owns
  the file, the polling and the keep-the-last-good rule.

  The keys are the operator's knobs only: `max_concurrent` (the node ceiling), and
  the `Arbiter.NodeAgent.K8s.PodConfig` keys `namespace`, `worker`,
  `services_resources`, `placement`, `image_pull_secrets`, `timeouts` and
  `snapshot_interval_s`. Anything else, including the facts the controller knows
  itself (`registry`, `install_id`, `owner_uid`, …) and everything the builder owns
  (security context, volumes, image), is `{:error, {:bad_config, {:unknown_key,
  key}}}`: a mistaken `securityContext:` is a loud error, not a silent no-op.

  The nested values are validated by `PodConfig.normalize/1` itself, so the rules
  the builder enforces and the rules the loader enforces cannot drift.

  `timeouts` is filled to the full set the controller reads: `schedule_s` (120),
  `pull_s` (600), `boot_s` (120), `grace_s` (120), `retain_failed_s` (300),
  `gate_timeout_s` (30).
  """

  alias Arbiter.NodeAgent.K8s.PodConfig

  @default_max_concurrent 2
  @max_concurrent_limit 1000
  @timeout_defaults %{
    "schedule_s" => 120,
    "pull_s" => 600,
    "boot_s" => 120,
    "grace_s" => 120,
    "retain_failed_s" => 300,
    "gate_timeout_s" => 30
  }

  # String key (as the YAML has it) -> atom key. A fixed table: no `String.to_atom/1`
  # on file content.
  @pod_keys %{
    "namespace" => :namespace,
    "worker" => :worker,
    "services_resources" => :services_resources,
    "placement" => :placement,
    "image_pull_secrets" => :image_pull_secrets,
    "timeouts" => :timeouts,
    "snapshot_interval_s" => :snapshot_interval_s
  }

  # Valid stand-ins for the facts only the controller knows, so `PodConfig` can
  # validate the operator keys on their own.
  @placeholder %{
    registry: "registry.invalid/arbiter",
    install_id: "install",
    node_id: "node",
    owner_uid: "owner",
    bridge_addr: "bridge",
    gate_addr: "gate",
    boot_nonce: String.duplicate("n", 43),
    max_wall_s: 3600
  }

  @type t :: %{
          required(:max_concurrent) => pos_integer(),
          required(:timeouts) => %{optional(String.t()) => non_neg_integer()},
          optional(atom()) => term()
        }

  @doc "Parse `controller.yaml` text."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:bad_config, term()}}
  def parse(text) when is_binary(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, decoded} -> from_map(decoded)
      {:error, reason} -> bad({:yaml, yaml_reason(reason)})
    end
  rescue
    error -> bad({:yaml, Exception.message(error)})
  catch
    kind, reason -> bad({:yaml, inspect({kind, reason}, limit: 5)})
  end

  def parse(_other), do: bad(:not_a_map)

  @doc "Validate a decoded config (string keys). `nil` (an empty file) is the defaults."
  @spec from_map(term()) :: {:ok, t()} | {:error, {:bad_config, term()}}
  def from_map(nil), do: from_map(%{})

  def from_map(%{} = map) do
    map = Map.new(map, fn {k, v} -> {to_string(k), v} end)

    with :ok <- known_keys(map),
         {:ok, max_concurrent} <- max_concurrent(map),
         operator = operator_keys(map),
         {:ok, normal} <- PodConfig.normalize(Map.merge(@placeholder, operator)) do
      pod = Map.take(normal, Map.values(@pod_keys))

      {:ok,
       pod
       |> Map.put(:max_concurrent, max_concurrent)
       |> Map.update!(:timeouts, &Map.merge(@timeout_defaults, &1))}
    end
  end

  def from_map(_other), do: bad(:not_a_map)

  @doc """
  The map `PodSpec.build/2` takes: the operator's keys plus the controller's own
  `facts` (`registry`, `install_id`, `node_id`, `owner_uid`, `bridge_addr`,
  `gate_addr`, `boot_nonce`, `max_wall_s`). `max_concurrent` is not a pod key and
  is left out.
  """
  @spec pod_config(t(), map()) :: map()
  def pod_config(config, facts) do
    config |> Map.delete(:max_concurrent) |> Map.merge(facts)
  end

  # -- internals ----------------------------------------------------------------

  defp known_keys(map) do
    case Enum.find(Map.keys(map), &(&1 != "max_concurrent" and not is_map_key(@pod_keys, &1))) do
      nil -> :ok
      key -> bad({:unknown_key, key})
    end
  end

  defp max_concurrent(map) do
    case Map.get(map, "max_concurrent", @default_max_concurrent) do
      n when is_integer(n) and n >= 1 and n <= @max_concurrent_limit -> {:ok, n}
      _ -> bad({:bad_value, :max_concurrent})
    end
  end

  defp operator_keys(map) do
    for {key, atom} <- @pod_keys,
        Map.has_key?(map, key),
        into: %{},
        do: {atom, Map.fetch!(map, key)}
  end

  defp yaml_reason(error), do: Exception.message(error)

  defp bad(reason), do: {:error, {:bad_config, reason}}
end
