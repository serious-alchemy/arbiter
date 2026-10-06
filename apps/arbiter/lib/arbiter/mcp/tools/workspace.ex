defmodule Arbiter.MCP.Tools.Workspace do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for reading/writing workspace config and
  installation-wide settings: `workspace_show` / `workspace_config_get` /
  `workspace_config_overview` / `workspace_config_set` /
  `workspace_config_unset` / `installation_config_get` /
  `installation_config_set`. Split out of `Arbiter.MCP.Tools` (see its
  moduledoc) — called back into for the generic arg/serialization helpers it
  still owns.
  """

  alias Arbiter.Guardrails.Authority
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.AttentionLimits
  alias Arbiter.Tasks.Workspace

  @install_settings_keys Arbiter.Settings.Registry.keys()

  # `docs/design/epic-aware-scheduling.md` §6.6: the operator alone decides how
  # much of the fleet a floor may take, so the coordinator's MCP door refuses
  # these two (REST and `arb settings` carry the operator's token).
  #
  # The `nodes.*` keys (RW3, `docs/design/remote-workers.md` §15) are operator-only
  # too: they decide where machines that receive provider tokens may enrol from
  # and for how long a join token lives, so a coordinator *session* must not set
  # them.
  @operator_only_install_keys ~w(scheduling_epic_floors_enabled scheduling_max_lifted_in_flight
                                 nodes.public_url nodes.allow_public_endpoint
                                 nodes.join_token_ttl_minutes)

  # ---- workspace_show -----------------------------------------------------

  @doc """
  A workspace: config and the resolved worker security posture, plus an `update`
  block (`enabled`, `current`, `latest`, `release_url`, `update_available`).
  Resolved from the optional `workspace` arg (name or id), else the scope's bound
  workspace, else the installation default. A workspace-bound scope (worker) can
  only ever inspect its own workspace.
  """
  @spec workspace_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_show(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args) do
      case Ash.get(Workspace, ws_id) do
        {:ok, %Workspace{} = ws} ->
          {:ok, ws |> Tools.serialize_workspace() |> Map.put(:update, update_block())}

        _ ->
          {:error, {:not_found, "workspace #{ws_id} not found"}}
      end
    end
  end

  # The release update check (`Arbiter.Release.UpdateCheck`), so a headless
  # coordinator sees "an update is available" without the dashboard.
  defp update_block do
    u = Arbiter.Release.UpdateCheck.state()

    %{
      enabled: u.enabled,
      current: Arbiter.Version.app_version(),
      latest: u.latest,
      release_url: u.release_url,
      update_available: u.update_available?
    }
  end

  # ---- workspace_config_get ----------------------------------------------

  @doc """
  Read the full workspace config or a single dotted.key. Secret values are
  never returned — only secret_keys (the names of configured secrets) and any
  `credentials_ref` pointers already embedded in the config JSON.
  Resolved from the optional `workspace` arg, else the scope's bound workspace,
  else the installation default.

  The `attention` section's escalation limits (bd-8nlez1,
  `Arbiter.Tasks.AttentionLimits`) read with their documented defaults filled
  in, so the limits in force are visible whether or not they were set.

  `effective_merge_strategies` maps each `repo_paths` repo to the merge
  strategy it actually uses — its `merge.repos.<repo>.strategy` override, else
  the workspace-level `merge.strategy` (bd-73zv62).
  """
  @spec workspace_config_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_get(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      config = AttentionLimits.with_defaults(ws.config)
      key = Tools.fetch_string(args, "key")

      value =
        if key do
          config_get_in_path(config, String.split(key, "."))
        else
          config
        end

      if key != nil and value == nil do
        {:error, {:not_found, "config key not found: #{key}"}}
      else
        {:ok,
         %{
           workspace: ws.name,
           key: key,
           value: value,
           effective_merge_strategies: effective_merge_strategies(ws),
           secret_keys: workspace_secret_keys(ws)
         }}
      end
    end
  end

  # bd-73zv62: each `repo_paths` repo's effective merge strategy — a
  # `merge.repos.<repo>.strategy` override, else the workspace-level one.
  defp effective_merge_strategies(ws) do
    Map.new(Arbiter.Mergers.repo_strategies(ws), fn {repo, strategy} ->
      {repo, Atom.to_string(strategy)}
    end)
  end

  # ---- workspace_config_overview ------------------------------------------

  @doc """
  A grouped summary of the workspace config: tracker, merge, agent,
  review_agent, routing, review, review_gate, standing_orders, and the names
  of configured secrets (values never exposed). Mirrors `arb config overview`.
  Resolved from the optional `workspace` arg like `workspace_show`.
  """
  @spec workspace_config_overview(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_overview(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      config = ws.config || %{}

      {:ok,
       %{
         workspace: %{id: ws.id, name: ws.name, prefix: ws.prefix},
         tracker: Map.get(config, "tracker", %{}),
         merge: Map.get(config, "merge", %{}),
         agent: Map.get(config, "agent", %{}),
         review_agent: Map.get(config, "review_agent", %{}),
         routing: Map.get(config, "routing", %{}),
         review: Map.get(config, "review", %{}),
         review_gate: Map.get(config, "review_gate", %{}),
         standing_orders: Map.get(config, "standing_orders", []),
         attention: config |> AttentionLimits.with_defaults() |> Map.get("attention"),
         secret_keys: workspace_secret_keys(ws)
       }}
    end
  end

  # ---- workspace_config_set -----------------------------------------------

  @doc """
  Set a single dotted.key to a value via the deep-merge config endpoint.
  Coordinator only (enforced in `Arbiter.MCP.Catalog`). Sibling keys are
  preserved — this uses `PATCH /api/workspaces/:id/config`, not the
  whole-map replace path. Secret / credential top-level key prefixes are
  blocked; route those through `arb workspace secret`.
  Returns the workspace identity, the full updated config, and secret_keys.
  """
  @spec workspace_config_set(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_set(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, key} <- Tools.require_string(args, "key"),
         {:ok, value} <- require_config_value(args),
         :ok <- deny_secret_path(key),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      patch = config_put_in_path(%{}, String.split(key, "."), value)

      case Ash.update(ws, %{patch: patch, unset_paths: []},
             action: :patch_config,
             context: guardrail_context(scope)
           ) do
        {:ok, updated} -> {:ok, serialize_workspace_config(updated)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- workspace_config_unset ---------------------------------------------

  @doc """
  Remove a single dotted.key from the config via the deep-merge endpoint.
  Coordinator only (enforced in `Arbiter.MCP.Catalog`). Sibling keys are
  preserved. Returns the workspace identity, the full updated config, and
  secret_keys. Errors if the key does not exist in the current config.
  """
  @spec workspace_config_unset(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_unset(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         {:ok, key} <- Tools.require_string(args, "key"),
         :ok <- deny_secret_path(key),
         {:ok, ws} <- Tools.fetch_workspace(ws_id) do
      config = ws.config || %{}
      path = String.split(key, ".")

      if config_get_in_path(config, path) == nil do
        {:error, {:invalid, "config key not found: #{key}"}}
      else
        case Ash.update(ws, %{patch: %{}, unset_paths: [key]},
               action: :patch_config,
               context: guardrail_context(scope)
             ) do
          {:ok, updated} -> {:ok, serialize_workspace_config(updated)}
          {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
        end
      end
    end
  end

  # ---- installation_config_get --------------------------------------------

  @doc """
  Read an install-wide runtime setting (bd-2ogep0) — the system-wide
  concurrency ceiling and the `Arbiter.Agents.CredentialWatchdog` knobs
  (bd-ajgve2). Returns the full settings map when `key` is omitted. Available to
  both tiers (read-only, no workspace scoping — this is installation-wide).
  """
  @spec installation_config_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def installation_config_get(%Scope{} = _scope, args) do
    settings = Arbiter.Settings.Registry.overrides()

    case Tools.fetch_string(args, "key") do
      nil ->
        {:ok, %{key: nil, value: settings, settings: settings}}

      key when key in @install_settings_keys ->
        {:ok,
         %{key: key, value: Map.get(settings, String.to_atom(key)), settings: settings}}

      key ->
        {:error, {:not_found, "unknown installation setting: #{key}"}}
    end
  end

  # ---- installation_config_set --------------------------------------------

  @doc """
  Set an install-wide runtime setting (bd-2ogep0). Coordinator only (enforced
  in `Arbiter.MCP.Catalog`). `null` always clears an override, falling back to
  the application env / hardcoded default. Settable keys:

    * `conductor_system_max_concurrent` — positive integer, the install-wide
      worker ceiling. Takes effect on the board scheduler's next tick. (The
      `conductor_` prefix is historical; see `Arbiter.Settings`.)
    * `credential_watchdog_adapters` — list of agent-type names
      (`Arbiter.Agents.valid_agent_types/0`) the Watchdog should probe; `[]`
      probes nothing.
    * `credential_watchdog_interval_ms` / `credential_watchdog_recovery_interval_ms`
      — positive integers.
    * `quota_providers_shown` / `quota_providers_hidden` — lists of quota
      provider codes (`claude`, `codex`, `antigravity`) forced onto / off the
      status bar's quota chip and `/usage` (bd-i2gwwn,
      `Arbiter.Quota.Visibility`); `null` is auto-detect. Takes effect on the
      next page load.
    * `output_offload_enabled` — boolean; the output-offload sweeper
      (`Arbiter.Workers.OutputOffload`) ships OFF, `true` turns it on, `null`
      back off. Takes effect on the sweeper's next tick.
    * `scheduling_finish_first` (boolean) and
      `scheduling_finish_first_max_wait_hours` (positive integer) — the
      finish-first tiebreak inside a priority band and its aging escape
      (`docs/design/epic-aware-scheduling.md` §6.6). `null` is off / 24 hours.
    * `scheduling_epic_floors_enabled` (boolean kill switch) and
      `scheduling_max_lifted_in_flight` (positive integer lift cap) —
      **operator only**: refused here, set through `arb settings` or REST.

  The Watchdog keys take effect on its next poll cycle (bd-ajgve2). No restart
  is required for any of them.
  """
  @spec installation_config_set(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def installation_config_set(%Scope{} = _scope, args) do
    with {:ok, key} <- Tools.require_string(args, "key"),
         :ok <- validate_install_key(key),
         :ok <- reject_operator_only_key(key),
         {:ok, raw} <- require_install_value(key, args),
         {:ok, updated} <- Arbiter.Settings.Registry.put(key, raw) do
      {:ok, %{key: key, value: updated}}
    end
  end

  defp validate_install_key(key) when key in @install_settings_keys, do: :ok
  defp validate_install_key(key), do: {:error, {:invalid, "unknown installation setting: #{key}"}}

  defp reject_operator_only_key(key) when key in @operator_only_install_keys,
    do: {:error, {:unauthorized, "#{key} is operator-only — set it with `arb settings`"}}

  defp reject_operator_only_key(_key), do: :ok

  defp require_install_value(_key, args) do
    case Map.fetch(args, "value") do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, {:invalid, "value is required"}}
    end
  end

  # ---- workspace_config helpers -------------------------------------------

  # Sorted names of the workspace's configured secrets; values are never
  # returned. Mirrors ArbiterWeb.Api.WorkspaceJSON.secret_key_names/1.
  defp workspace_secret_keys(%Workspace{} = ws) do
    ws |> Workspace.secrets_map() |> Map.keys() |> Enum.sort()
  end

  # Top-level config key prefixes that the MCP write tools refuse to set.
  # Secrets live in the encrypted `secrets` column, not the config JSON;
  # routing them here would silently store a plaintext ref with no effect.
  # G11: the config write carries the caller's authority, so loosening
  # `guardrails.*` / `agent.security` is refused for anything but operator proof.
  defp guardrail_context(%Scope{} = scope),
    do: %{guardrail_authority: Authority.from_scope(scope)}

  defp deny_secret_path(key) when is_binary(key) do
    blocked = ~w(secret secrets credentials)
    prefix = key |> String.split(".") |> List.first() |> String.downcase()

    if prefix in blocked do
      {:error,
       {:unauthorized,
        "cannot set #{inspect(key)} via config tools — use `arb workspace secret` for secrets"}}
    else
      :ok
    end
  end

  # Fetch the `value` argument; accepts any JSON-decoded type (boolean,
  # integer, string, object, array, or null). Distinguishing absent from null
  # requires Map.fetch rather than Map.get.
  defp require_config_value(args) do
    case Map.fetch(args, "value") do
      :error -> {:error, {:invalid, "`value` is required"}}
      {:ok, v} -> {:ok, Tools.unwrap_stringified_json(v, [:list, :map])}
    end
  end

  # Build a nested map from a dotted-path segment list and a leaf value.
  defp config_put_in_path(map, [k], value) when is_map(map), do: Map.put(map, k, value)

  defp config_put_in_path(map, [k | rest], value) when is_map(map) do
    sub =
      case Map.get(map, k) do
        %{} = s -> s
        _ -> %{}
      end

    Map.put(map, k, config_put_in_path(sub, rest, value))
  end

  # Navigate a nested config map by path segments; nil if any segment is missing.
  defp config_get_in_path(value, []), do: value

  defp config_get_in_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil -> nil
      sub -> config_get_in_path(sub, rest)
    end
  end

  defp config_get_in_path(_, _), do: nil

  # The standard config result: workspace identity, full (secret-safe) config,
  # and the names of configured secrets so the caller can confirm the merge.
  defp serialize_workspace_config(%Workspace{} = ws) do
    %{
      workspace: %{id: ws.id, name: ws.name, prefix: ws.prefix},
      config: ws.config || %{},
      secret_keys: workspace_secret_keys(ws)
    }
  end
end
