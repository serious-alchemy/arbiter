defmodule Arbiter.Machine.Derate.Config do
  @moduledoc """
  The thresholds behind `Arbiter.Machine.Derate`, per machine. On by default.

  | key               | default | meaning                                                         |
  |-------------------|---------|-----------------------------------------------------------------|
  | `enabled`         | `true`  | `false` turns derating off for the machine                      |
  | `thermal_soft_c`  | `90`    | at or above: offer no new slots (offered = live)                |
  | `thermal_hard_c`  | `95`    | at or above: also hold new resumes and fix passes               |
  | `thermal_delta_c` | `5`     | hysteresis: recover only below `soft - delta` / `hard - delta`  |
  | `psi_some_avg10`  | `25`    | memory PSI `some avg10` (%) at or above: offer no new slots     |
  | `psi_delta`       | `10`    | hysteresis for PSI                                              |
  | `mem_floor_gib`   | `4`     | `MemAvailable` below this: offer no new slots (one worker's worth) |
  | `mem_delta_gib`   | `1`     | hysteresis for the floor                                        |
  | `recover_s`       | `180`   | seconds the readings must stay clear before the derate lifts    |

  `build/1` takes a map with string or atom keys (the installation setting
  `machine.derate`, a node's config); a missing, unknown or invalid entry
  falls back to its default, so a typo can never turn the guard off.
  `from_env/1` reads a node agent's `ARB_NODE_*` variables.
  """

  @gib 1024 * 1024 * 1024

  defstruct enabled: true,
            thermal_soft_c: 90.0,
            thermal_hard_c: 95.0,
            thermal_delta_c: 5.0,
            psi_some_avg10: 25.0,
            psi_delta: 10.0,
            mem_floor_bytes: 4 * @gib,
            mem_delta_bytes: 1 * @gib,
            recover_s: 180

  @type t :: %__MODULE__{
          enabled: boolean(),
          thermal_soft_c: float(),
          thermal_hard_c: float(),
          thermal_delta_c: float(),
          psi_some_avg10: float(),
          psi_delta: float(),
          mem_floor_bytes: non_neg_integer(),
          mem_delta_bytes: non_neg_integer(),
          recover_s: pos_integer()
        }

  # key => {struct field, kind}
  @keys %{
    "enabled" => {:enabled, :boolean},
    "thermal_soft_c" => {:thermal_soft_c, :float},
    "thermal_hard_c" => {:thermal_hard_c, :float},
    "thermal_delta_c" => {:thermal_delta_c, :float},
    "psi_some_avg10" => {:psi_some_avg10, :float},
    "psi_delta" => {:psi_delta, :float},
    "mem_floor_gib" => {:mem_floor_bytes, :gib},
    "mem_delta_gib" => {:mem_delta_bytes, :gib},
    "recover_s" => {:recover_s, :seconds}
  }

  # env var => config key
  @env %{
    "ARB_NODE_DERATE" => "enabled",
    "ARB_NODE_THERMAL_SOFT_C" => "thermal_soft_c",
    "ARB_NODE_THERMAL_HARD_C" => "thermal_hard_c",
    "ARB_NODE_THERMAL_DELTA_C" => "thermal_delta_c",
    "ARB_NODE_MEM_PSI_SOME" => "psi_some_avg10",
    "ARB_NODE_MEM_PSI_DELTA" => "psi_delta",
    "ARB_NODE_MEM_FLOOR_GIB" => "mem_floor_gib",
    "ARB_NODE_MEM_DELTA_GIB" => "mem_delta_gib",
    "ARB_NODE_DERATE_RECOVER_S" => "recover_s"
  }

  @doc "Every config key, as written in settings and node config."
  @spec keys() :: [String.t()]
  def keys, do: @keys |> Map.keys() |> Enum.sort()

  @doc "The environment variables a node agent reads, `%{env var => key}`."
  @spec env_vars() :: %{String.t() => String.t()}
  def env_vars, do: @env

  @doc "The defaults, as the same `key => value` map `build/1` accepts."
  @spec defaults() :: %{String.t() => term()}
  def defaults do
    d = %__MODULE__{}

    %{
      "enabled" => d.enabled,
      "thermal_soft_c" => d.thermal_soft_c,
      "thermal_hard_c" => d.thermal_hard_c,
      "thermal_delta_c" => d.thermal_delta_c,
      "psi_some_avg10" => d.psi_some_avg10,
      "psi_delta" => d.psi_delta,
      "mem_floor_gib" => d.mem_floor_bytes / @gib,
      "mem_delta_gib" => d.mem_delta_bytes / @gib,
      "recover_s" => d.recover_s
    }
  end

  @doc "Build a config from overrides (see the moduledoc)."
  @spec build(map() | keyword() | nil) :: t()
  def build(overrides) when is_list(overrides), do: build(Map.new(overrides))

  def build(overrides) when is_map(overrides) do
    fields =
      for {raw_key, raw} <- overrides,
          key = to_string(raw_key),
          {field, kind} <- [Map.get(@keys, key)],
          {:ok, value} <- [cast(kind, raw)],
          do: {field, value}

    base = struct(__MODULE__, fields)
    %{base | thermal_hard_c: max(base.thermal_hard_c, base.thermal_soft_c)}
  end

  def build(_), do: %__MODULE__{}

  @doc "The `key => raw string` overrides an environment (a map of strings) sets."
  @spec env_overrides(map()) :: %{String.t() => String.t()}
  def env_overrides(env) when is_map(env) do
    for {var, key} <- @env, value = Map.get(env, var), is_binary(value), value != "", into: %{} do
      {key, value}
    end
  end

  @doc "Build a config from `ARB_NODE_*` environment variables (a map of strings)."
  @spec from_env(map()) :: t()
  def from_env(env) when is_map(env), do: env |> env_overrides() |> build()

  defp cast(:boolean, v) when is_boolean(v), do: {:ok, v}
  defp cast(:boolean, v) when v in ["true", "on", "1", "yes"], do: {:ok, true}
  defp cast(:boolean, v) when v in ["false", "off", "0", "no"], do: {:ok, false}

  defp cast(:float, v) do
    case number(v) do
      {:ok, n} when n > 0 -> {:ok, n * 1.0}
      _ -> :error
    end
  end

  defp cast(:gib, v) do
    case number(v) do
      {:ok, n} when n >= 0 -> {:ok, round(n * @gib)}
      _ -> :error
    end
  end

  defp cast(:seconds, v) do
    case number(v) do
      {:ok, n} when n > 0 -> {:ok, round(n)}
      _ -> :error
    end
  end

  defp cast(_kind, _v), do: :error

  defp number(n) when is_number(n), do: {:ok, n}

  defp number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp number(_), do: :error
end
