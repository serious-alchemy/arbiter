defmodule Arbiter.Settings.Registry do
  @moduledoc """
  The single description of the install-wide settings (`Arbiter.Settings`):
  which keys exist, their types, how a raw value is validated, and how they are
  read and written. The `installation_config_get` / `installation_config_set`
  MCP tools, `GET|PATCH /api/installation/config` and `arb settings` all go
  through here, so the three surfaces cannot drift — adding a key means
  extending `@schema` (plus the `Arbiter.Settings` getter/setter).

  `nil` always means "no override"; for the list-valued keys `[]` is a real,
  distinct value (e.g. `credential_watchdog_adapters: []` probes nothing).
  """

  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Board.Snapshot
  alias Arbiter.Settings

  @type key :: String.t()
  @type error :: {:invalid, String.t()}

  @schema [
    %{
      key: "conductor_system_max_concurrent",
      type: "positive_integer",
      description:
        "System-wide worker concurrency ceiling the board scheduler dispatches under. " <>
          "Takes effect on the next scheduler tick."
    },
    %{
      key: "credential_watchdog_adapters",
      type: "agent_type_list",
      description:
        "Agent types the CredentialWatchdog probes; null = all, [] = none. " <>
          "Takes effect on its next poll."
    },
    %{
      key: "credential_watchdog_interval_ms",
      type: "positive_integer",
      description: "CredentialWatchdog poll interval (ms). Takes effect on its next poll."
    },
    %{
      key: "credential_watchdog_recovery_interval_ms",
      type: "positive_integer",
      description:
        "CredentialWatchdog re-probe interval (ms) while an adapter is expired. " <>
          "Takes effect on its next poll."
    },
    %{
      key: "quota_providers_shown",
      type: "quota_provider_list",
      description:
        "Quota providers forced onto the status-bar quota chip and /usage; null = auto-detect."
    },
    %{
      key: "quota_providers_hidden",
      type: "quota_provider_list",
      description:
        "Quota providers forced off the quota surfaces (wins over shown); null = auto-detect."
    },
    %{
      key: "output_offload_enabled",
      type: "boolean",
      description:
        "Run the daily output-offload sweeper, which clears worker_runs.output_lines and " <>
          "worker_run_steps.output_summary once the durable on-disk copy exists; null/false = off. " <>
          "Takes effect on its next tick."
    },
    %{
      key: "scheduling_epic_floors_enabled",
      type: "boolean",
      description:
        "Kill switch for epic priority floors: false ignores every floor; null/true = floors " <>
          "apply (a no-op until an epic has one). Takes effect on the next scheduler tick."
    },
    %{
      key: "scheduling_max_lifted_in_flight",
      type: "positive_integer",
      description:
        "Most in-progress tickets an epic floor may have lifted at once; past it every other " <>
          "lifted card is ordered by its own priority. null = max(slots_total - 1, 1). " <>
          "Takes effect on the next scheduler tick."
    },
    %{
      key: "scheduling_finish_first",
      type: "boolean",
      description:
        "Finish-first tiebreak inside a priority band: children of in-progress epics go first, " <>
          "fewest open leaves first; null/false = off. Takes effect on the next scheduler tick."
    },
    %{
      key: "scheduling_finish_first_max_wait_hours",
      type: "positive_integer",
      description:
        "Hours a card may wait Ready and unblocked before it escapes the finish-first " <>
          "tiebreak; null = 24. Takes effect on the next scheduler tick."
    }
  ]

  @keys Enum.map(@schema, & &1.key)

  @doc "Every settable key, in display order."
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc "Key, type, description and (for enum-typed keys) allowed values."
  @spec schema() :: [map()]
  def schema, do: Enum.map(@schema, &Map.put(&1, :allowed, allowed(&1.type)))

  defp allowed("agent_type_list"), do: Arbiter.Agents.valid_agent_types()
  defp allowed("quota_provider_list"), do: Arbiter.Quota.Visibility.provider_codes()
  defp allowed(_), do: nil

  @doc """
  Validate and normalise a raw value for `key` (`nil` clears). Stringified JSON
  (`"[\\"claude\\"]"`, `"5"`) is unwrapped. Returns `{:error, message}` with the
  message every surface reports.
  """
  @spec cast(key(), term()) :: {:ok, term()} | {:error, String.t()}
  def cast(key, raw) when key in @keys do
    type = Enum.find(@schema, &(&1.key == key)).type
    do_cast(type, unwrap(raw))
  end

  def cast(key, _raw), do: {:error, "unknown installation setting: #{key}"}

  defp do_cast(_type, nil), do: {:ok, nil}
  defp do_cast("boolean", b) when is_boolean(b), do: {:ok, b}
  defp do_cast("boolean", _), do: {:error, "value must be true, false or null"}
  defp do_cast("positive_integer", n) when is_integer(n) and n > 0, do: {:ok, n}

  defp do_cast("positive_integer", _),
    do: {:error, "value must be a positive integer or null"}

  defp do_cast(type, list) when type in ["agent_type_list", "quota_provider_list"] do
    valid = allowed(type)

    if is_list(list) and Enum.all?(list, &(is_binary(&1) and &1 in valid)) do
      {:ok, list}
    else
      noun = if type == "agent_type_list", do: "agent types", else: "quota providers"
      {:error, "value must be a list of #{noun} (#{Enum.join(valid, ", ")}) or null"}
    end
  end

  defp unwrap(raw) when is_binary(raw) do
    case Jason.decode(String.trim(raw)) do
      {:ok, decoded}
      when is_integer(decoded) or is_list(decoded) or is_nil(decoded) or
             is_boolean(decoded) ->
        decoded

      _ ->
        raw
    end
  end

  defp unwrap(raw), do: raw

  @doc """
  Validate then persist. Returns the stored override (`nil` once cleared).
  An invalid value is rejected before anything is written.
  """
  @spec put(key(), term()) :: {:ok, term()} | {:error, error()}
  def put(key, raw) do
    with {:ok, value} <- cast_for_put(key, raw), do: write(key, value)
  end

  defp cast_for_put(key, raw) do
    case cast(key, raw) do
      {:ok, v} -> {:ok, v}
      {:error, msg} -> {:error, {:invalid, msg}}
    end
  end

  defp write("conductor_system_max_concurrent", v),
    do: wrap(Settings.set_conductor_system_max_concurrent(v))

  defp write("credential_watchdog_adapters", v),
    do: wrap(Settings.set_credential_watchdog_adapters(v))

  defp write("credential_watchdog_interval_ms", v),
    do: wrap(Settings.set_credential_watchdog_interval_ms(v))

  defp write("credential_watchdog_recovery_interval_ms", v),
    do: wrap(Settings.set_credential_watchdog_recovery_interval_ms(v))

  defp write("quota_providers_shown", v), do: wrap(Settings.set_quota_providers_shown(v))
  defp write("quota_providers_hidden", v), do: wrap(Settings.set_quota_providers_hidden(v))

  defp write("output_offload_enabled", v), do: wrap(Settings.set_output_offload_enabled(v))

  defp write("scheduling_epic_floors_enabled", v),
    do: wrap(Settings.set_scheduling_epic_floors_enabled(v))

  defp write("scheduling_max_lifted_in_flight", v),
    do: wrap(Settings.set_scheduling_max_lifted_in_flight(v))

  defp write("scheduling_finish_first", v), do: wrap(Settings.set_scheduling_finish_first(v))

  defp write("scheduling_finish_first_max_wait_hours", v),
    do: wrap(Settings.set_scheduling_finish_first_max_wait_hours(v))

  defp wrap({:ok, updated}), do: {:ok, updated}
  defp wrap({:error, reason}), do: {:error, {:invalid, inspect(reason)}}

  @doc "The raw persisted override (`nil` = none) for a key."
  @spec override(key()) :: term()
  def override("conductor_system_max_concurrent"), do: Settings.conductor_system_max_concurrent()
  def override("credential_watchdog_adapters"), do: Settings.credential_watchdog_adapters()
  def override("credential_watchdog_interval_ms"), do: Settings.credential_watchdog_interval_ms()

  def override("credential_watchdog_recovery_interval_ms"),
    do: Settings.credential_watchdog_recovery_interval_ms()

  def override("quota_providers_shown"), do: Settings.quota_providers_shown()
  def override("quota_providers_hidden"), do: Settings.quota_providers_hidden()

  def override("output_offload_enabled"), do: Settings.output_offload_enabled()

  def override("scheduling_epic_floors_enabled"), do: Settings.scheduling_epic_floors_enabled()
  def override("scheduling_max_lifted_in_flight"), do: Settings.scheduling_max_lifted_in_flight()
  def override("scheduling_finish_first"), do: Settings.scheduling_finish_first()

  def override("scheduling_finish_first_max_wait_hours"),
    do: Settings.scheduling_finish_first_max_wait_hours()

  @doc "The value in force with no override (app env, else hardcoded); `nil` = auto-detect."
  @spec default(key()) :: term()
  def default("conductor_system_max_concurrent"), do: Snapshot.default_system_max_concurrent()

  def default("credential_watchdog_adapters"),
    do: Enum.map(Arbiter.Agents.adapters(), fn {type, _} -> to_string(type) end)

  def default("credential_watchdog_interval_ms"),
    do: CredentialWatchdog.default_interval_ms(:interval_ms)

  def default("credential_watchdog_recovery_interval_ms"),
    do: CredentialWatchdog.default_interval_ms(:recovery_interval_ms)

  def default("output_offload_enabled"), do: false

  def default("scheduling_epic_floors_enabled"), do: true
  def default("scheduling_finish_first"), do: false

  def default("scheduling_finish_first_max_wait_hours"),
    do: Settings.default_finish_first_max_wait_hours()

  # nil = max(slots_total - 1, 1), which depends on the board.
  def default("scheduling_max_lifted_in_flight"), do: nil

  def default(key) when key in ["quota_providers_shown", "quota_providers_hidden"], do: nil

  @doc """
  One key as `%{key, type, description, allowed, value, override, overridden,
  default}`: `value` is what is in force (the override, else the default),
  `override` the raw persisted value. `nil` for an unknown key.
  """
  @spec describe(key()) :: map() | nil
  def describe(key) when key in @keys do
    entry = Enum.find(schema(), &(&1.key == key))
    override = override(key)
    default = default(key)

    Map.merge(entry, %{
      value: if(is_nil(override), do: default, else: override),
      override: override,
      overridden: not is_nil(override),
      default: default
    })
  end

  def describe(_key), do: nil

  @doc "`describe/1` for every key."
  @spec all() :: [map()]
  def all, do: Enum.map(@keys, &describe/1)

  @doc "`%{key_atom => override}` — what `installation_config_get` returns as `settings`."
  @spec overrides() :: %{atom() => term()}
  def overrides, do: Map.new(@keys, &{String.to_existing_atom(&1), override(&1)})
end
