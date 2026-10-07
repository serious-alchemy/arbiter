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
    },
    %{
      key: "nodes.public_url",
      type: "http_url",
      description:
        "The https origin a remote node dials to enroll and open its socket " <>
          "(e.g. https://<host>.<tailnet>.ts.net); null = unset. Operator-only."
    },
    %{
      key: "nodes.allow_public_endpoint",
      type: "boolean",
      description:
        "Tolerate a nodes.public_url that is not a private/tailnet address (internet " <>
          "exposure); null/false = refused. Operator-only."
    },
    %{
      key: "nodes.join_token_ttl_minutes",
      type: "join_token_ttl",
      description:
        "Default lifetime of a minted join token, in minutes (max 1440); null = 15. " <>
          "Operator-only."
    },
    %{
      key: "nodes.fence_after_s",
      type: "positive_integer",
      description:
        "Seconds without a heartbeat ack after which a node agent stops its containers " <>
          "(30-90); null = 60. Must stay below nodes.lost_after_s. Operator-only."
    },
    %{
      key: "nodes.lost_after_s",
      type: "positive_integer",
      description:
        "Seconds of silence after which the primary declares a node lost and interrupts " <>
          "its runs; must exceed nodes.fence_after_s; null = fence + 30. Operator-only."
    }
  ]

  @keys Enum.map(@schema, & &1.key)

  # `docs/design/epic-aware-scheduling.md` §6.6: the operator alone decides how
  # much of the fleet an epic floor may take. The `nodes.*` keys (RW3,
  # `docs/design/remote-workers.md` §15) decide where machines that receive
  # provider tokens may enrol from and for how long a join token lives, so a
  # coordinator *session* must not set them either. Enforced in `put/3`, so
  # MCP, REST and `arb settings` all refuse them for a non-operator token.
  @operator_only ~w(scheduling_epic_floors_enabled scheduling_max_lifted_in_flight
                    nodes.public_url nodes.allow_public_endpoint
                    nodes.join_token_ttl_minutes nodes.fence_after_s nodes.lost_after_s)

  # Built at compile time from the fixed schema above, so no input ever mints an
  # atom (some keys are dotted: `:"nodes.public_url"`).
  @key_atoms Map.new(@keys, &{&1, String.to_atom(&1)})

  @doc "Every settable key, in display order."
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc "The keys only an operator-authority caller may write (`put/3`)."
  @spec operator_only_keys() :: [key()]
  def operator_only_keys, do: @operator_only

  @doc """
  Key, type, description, `operator_only` and (for enum-typed keys) allowed
  values.
  """
  @spec schema() :: [map()]
  def schema do
    Enum.map(@schema, fn entry ->
      entry
      |> Map.put(:allowed, allowed(entry.type))
      |> Map.put(:operator_only, entry.key in @operator_only)
    end)
  end

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

  defp do_cast("http_url", url) when is_binary(url) do
    case Settings.normalize_public_url(url) do
      {:ok, normalized} ->
        {:ok, normalized}

      :error ->
        {:error,
         "value must be an http(s) URL with a host and no credentials, query or fragment, or null"}
    end
  end

  defp do_cast("http_url", _),
    do:
      {:error,
       "value must be an http(s) URL with a host and no credentials, query or fragment, or null"}

  defp do_cast("join_token_ttl", n) when is_integer(n) and n > 0 do
    max = Settings.max_join_token_ttl_minutes()

    if n <= max,
      do: {:ok, n},
      else: {:error, "value must be at most #{max} minutes (24 hours) or null"}
  end

  defp do_cast("join_token_ttl", _),
    do: {:error, "value must be a positive integer of minutes or null"}

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
  Authorize, validate, then persist. Returns the stored override (`nil` once
  cleared). A refused or invalid value is rejected before anything is written.

  `opts[:authority]` is the caller's `Arbiter.Guardrails.Authority` (default
  `:operator`: in-process callers such as the dashboard are trusted, and every
  untrusted entry point — REST, MCP — passes its token's authority). The
  `operator_only_keys/0` are refused for any other authority with
  `{:unauthorized, message}`, ahead of validation.
  """
  @spec put(key(), term(), keyword()) ::
          {:ok, term()} | {:error, error() | {:unauthorized, String.t()}}
  def put(key, raw, opts \\ []) do
    authority = Keyword.get(opts, :authority, :operator)

    with :ok <- authorize(key, authority),
         {:ok, value} <- cast_for_put(key, raw),
         do: write(key, value)
  end

  defp authorize(key, authority) when key in @operator_only and authority != :operator,
    do: {:error, {:unauthorized, "#{key} is operator-only — it needs an operator-proof token"}}

  defp authorize(_key, _authority), do: :ok

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

  defp write("nodes.public_url", v), do: wrap(Settings.set_nodes_public_url(v))

  defp write("nodes.allow_public_endpoint", v),
    do: wrap(Settings.set_nodes_allow_public_endpoint(v))

  defp write("nodes.join_token_ttl_minutes", v),
    do: wrap(Settings.set_nodes_join_token_ttl_minutes(v))

  defp write("nodes.fence_after_s", v), do: wrap(Settings.set_nodes_fence_after_s(v))
  defp write("nodes.lost_after_s", v), do: wrap(Settings.set_nodes_lost_after_s(v))

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

  def override("nodes.public_url"), do: Settings.nodes_public_url()
  def override("nodes.allow_public_endpoint"), do: Settings.nodes_allow_public_endpoint()
  def override("nodes.join_token_ttl_minutes"), do: Settings.nodes_join_token_ttl_override()
  def override("nodes.fence_after_s"), do: Settings.nodes_fence_after_s()
  def override("nodes.lost_after_s"), do: Settings.nodes_lost_after_s_override()

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

  def default("nodes.public_url"), do: nil
  def default("nodes.allow_public_endpoint"), do: false
  def default("nodes.join_token_ttl_minutes"), do: Settings.default_join_token_ttl_minutes()
  def default("nodes.fence_after_s"), do: Arbiter.Nodes.Liveness.default_fence_after_s()

  # Follows the fence in force, so the value shown is `fence + 30` once the
  # fence is overridden.
  def default("nodes.lost_after_s"), do: Arbiter.Nodes.Liveness.current().lost_after_s

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
  def overrides, do: Map.new(@keys, &{key_atom(&1), override(&1)})

  @doc "The atom a key is reported under in `overrides/0`; dotted keys are quoted atoms."
  @spec key_atom(key()) :: atom()
  def key_atom(key) when key in @keys, do: Map.fetch!(@key_atoms, key)
end
