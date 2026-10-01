defmodule Arbiter.Settings do
  @moduledoc """
  Ash domain + public API for install-wide runtime settings (bd-2ogep0).

  Backs a small persisted singleton (`Arbiter.Settings.Installation`) so
  settings that used to require editing `config/*.exs` and redeploying — e.g.
  the system-wide `max_concurrent` worker ceiling
  (`Arbiter.Board.Snapshot`), or which adapters
  `Arbiter.Agents.CredentialWatchdog` probes — can be read and changed at
  runtime, taking effect on the next drain / poll cycle with no restart.

  Every setting is nullable and `nil` means "no override" — the caller falls
  back to the application env / its own hardcoded default, so an install that
  never writes here behaves exactly as it did before the setting existed.

  Reads are resilient: any DB error (including "table doesn't exist yet" on a
  not-yet-migrated install) is swallowed and treated as "no override set",
  falling back to the caller's own default. Writes surface errors normally —
  a failed write should be visible to whoever asked for the change.
  """

  use Ash.Domain

  alias Arbiter.Settings.Installation

  resources do
    resource Installation
  end

  @doc """
  The install-wide worker concurrency ceiling override, or `nil` if unset
  (caller should fall back to app env / hardcoded default). Never raises —
  any read failure is treated as "unset".
  """
  @spec conductor_system_max_concurrent() :: pos_integer() | nil
  def conductor_system_max_concurrent, do: read_setting(:conductor_system_max_concurrent)

  @doc """
  Set the install-wide worker concurrency ceiling. `nil` clears the
  override (falls back to app env / hardcoded default). Returns the updated
  value (or `nil` when cleared).
  """
  @spec set_conductor_system_max_concurrent(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_conductor_system_max_concurrent(n) when is_nil(n) or (is_integer(n) and n > 0),
    do: write_setting(:conductor_system_max_concurrent, n)

  def set_conductor_system_max_concurrent(_), do: {:error, :invalid_value}

  @doc """
  The adapter names `Arbiter.Agents.CredentialWatchdog` should probe, or `nil`
  if unset (the Watchdog then probes every adapter in
  `Arbiter.Agents.adapters/0`). An empty list is a real value meaning "probe
  nothing". Never raises — any read failure is treated as "unset".
  """
  @spec credential_watchdog_adapters() :: [String.t()] | nil
  def credential_watchdog_adapters, do: read_setting(:credential_watchdog_adapters)

  @doc """
  Set the adapter names the Watchdog probes. Each entry must be one of
  `Arbiter.Agents.valid_agent_types/0`. `nil` clears the override (probe every
  adapter); `[]` disables probing entirely. Takes effect on the Watchdog's next
  poll cycle — no restart.
  """
  @spec set_credential_watchdog_adapters([String.t()] | nil) ::
          {:ok, [String.t()] | nil} | {:error, term()}
  def set_credential_watchdog_adapters(nil), do: write_setting(:credential_watchdog_adapters, nil)

  def set_credential_watchdog_adapters(names) when is_list(names) do
    valid = Arbiter.Agents.valid_agent_types()

    if Enum.all?(names, &(is_binary(&1) and &1 in valid)) do
      write_setting(:credential_watchdog_adapters, names)
    else
      {:error, :invalid_value}
    end
  end

  def set_credential_watchdog_adapters(_), do: {:error, :invalid_value}

  @doc """
  The Watchdog's normal poll interval in ms, or `nil` if unset (caller falls
  back to app env / hardcoded default). Never raises.
  """
  @spec credential_watchdog_interval_ms() :: pos_integer() | nil
  def credential_watchdog_interval_ms, do: read_setting(:credential_watchdog_interval_ms)

  @doc """
  Set the Watchdog's normal poll interval in ms. `nil` clears the override.
  Takes effect on the poll cycle after the currently-armed timer fires — no
  restart.
  """
  @spec set_credential_watchdog_interval_ms(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_credential_watchdog_interval_ms(ms) when is_nil(ms) or (is_integer(ms) and ms > 0),
    do: write_setting(:credential_watchdog_interval_ms, ms)

  def set_credential_watchdog_interval_ms(_), do: {:error, :invalid_value}

  @doc """
  The Watchdog's re-probe interval (ms) while an adapter is known-expired, or
  `nil` if unset. Never raises.
  """
  @spec credential_watchdog_recovery_interval_ms() :: pos_integer() | nil
  def credential_watchdog_recovery_interval_ms,
    do: read_setting(:credential_watchdog_recovery_interval_ms)

  @doc """
  Set the Watchdog's expired-adapter re-probe interval in ms. `nil` clears the
  override.
  """
  @spec set_credential_watchdog_recovery_interval_ms(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_credential_watchdog_recovery_interval_ms(ms)
      when is_nil(ms) or (is_integer(ms) and ms > 0),
      do: write_setting(:credential_watchdog_recovery_interval_ms, ms)

  def set_credential_watchdog_recovery_interval_ms(_), do: {:error, :invalid_value}

  @doc """
  The persisted `Arbiter.Board.Autopilot` pause state and when/by-what it was
  last changed. `paused: nil` means "no persisted value — caller should fall
  back to the `:arbiter, :board_autopilot, enabled:` application env, else
  paused"; `changed_at` / `changed_by` are then also `nil`. Never raises — any
  read failure is treated as unset.
  """
  @spec board_autopilot_status() :: %{
          paused: boolean() | nil,
          changed_at: DateTime.t() | nil,
          changed_by: String.t() | nil
        }
  def board_autopilot_status do
    case read_board_autopilot_status() do
      {:ok, status} -> status
      {:error, _reason} -> unset_autopilot_status()
    end
  end

  @doc """
  Like `board_autopilot_status/0`, but tells "nothing persisted" (`{:ok,
  %{paused: nil, ...}}`) apart from "could not read" (`{:error, reason}`) — a
  schema that is not migrated yet, a missing connection. `Arbiter.Board.Autopilot`
  needs the difference: an unreadable row must not be mistaken for the
  config default. Never raises.
  """
  @spec read_board_autopilot_status() ::
          {:ok,
           %{
             paused: boolean() | nil,
             changed_at: DateTime.t() | nil,
             changed_by: String.t() | nil
           }}
          | {:error, term()}
  def read_board_autopilot_status do
    case Ash.read(Installation) do
      {:ok, [row | _]} ->
        {:ok,
         %{
           paused: row.board_autopilot_paused,
           changed_at: row.board_autopilot_paused_at,
           changed_by: row.board_autopilot_paused_by
         }}

      {:ok, []} ->
        {:ok, unset_autopilot_status()}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp unset_autopilot_status, do: %{paused: nil, changed_at: nil, changed_by: nil}

  @doc """
  Persist the `Arbiter.Board.Autopilot` pause state, stamping when it changed
  and, where known, who/what changed it (an MCP tool, the REST API, the
  dashboard — free text, `nil` when the caller doesn't know). Returns the
  stored state. Writes surface errors normally.
  """
  @spec set_board_autopilot_paused(boolean(), String.t() | nil) ::
          {:ok, %{paused: boolean(), changed_at: DateTime.t(), changed_by: String.t() | nil}}
          | {:error, term()}
  def set_board_autopilot_paused(paused?, by \\ nil)
      when is_boolean(paused?) and (is_binary(by) or is_nil(by)) do
    with {:ok, row} <- get_or_create_singleton(),
         {:ok, updated} <-
           Ash.update(
             row,
             %{
               board_autopilot_paused: paused?,
               board_autopilot_paused_at: DateTime.utc_now(),
               board_autopilot_paused_by: by
             },
             action: :update
           ) do
      {:ok,
       %{
         paused: updated.board_autopilot_paused,
         changed_at: updated.board_autopilot_paused_at,
         changed_by: updated.board_autopilot_paused_by
       }}
    end
  end

  @doc """
  The persisted provider / account pauses (`Arbiter.Providers.Pause`), as
  `%{target => %{"reason", "by", "at"}}`. Never raises — any read failure is
  treated as "nothing paused".
  """
  @spec provider_pauses() :: %{optional(String.t()) => map()}
  def provider_pauses, do: read_setting(:provider_pauses) || %{}

  @doc "Replace the persisted provider / account pause map."
  @spec set_provider_pauses(map()) :: {:ok, map()} | {:error, term()}
  def set_provider_pauses(map) when is_map(map), do: write_setting(:provider_pauses, map)

  @doc """
  Quota provider codes forced onto the status bar's quota chip and `/usage`'s
  rate limits (bd-i2gwwn, `Arbiter.Quota.Visibility`), or `nil` when unset —
  auto-detect. Never raises.
  """
  @spec quota_providers_shown() :: [String.t()] | nil
  def quota_providers_shown, do: read_setting(:quota_providers_shown)

  @doc """
  Quota provider codes forced off both surfaces, or `nil` when unset. Wins
  over `quota_providers_shown/0`. Never raises.
  """
  @spec quota_providers_hidden() :: [String.t()] | nil
  def quota_providers_hidden, do: read_setting(:quota_providers_hidden)

  @doc """
  Both quota-provider overrides from one read, as `%{shown:, hidden:}` (each
  `nil` when unset). Never raises.
  """
  @spec quota_provider_overrides() :: %{shown: [String.t()] | nil, hidden: [String.t()] | nil}
  def quota_provider_overrides do
    case singleton() do
      %Installation{} = row ->
        %{shown: row.quota_providers_shown, hidden: row.quota_providers_hidden}

      nil ->
        %{shown: nil, hidden: nil}
    end
  rescue
    _ -> %{shown: nil, hidden: nil}
  end

  @doc """
  Force providers onto the quota surfaces. Each entry must be one of
  `Arbiter.Quota.Visibility.provider_codes/0`; `nil` clears the override.
  Takes effect on the next page load — the cached top-bar quota is dropped.
  """
  @spec set_quota_providers_shown([String.t()] | nil) ::
          {:ok, [String.t()] | nil} | {:error, term()}
  def set_quota_providers_shown(codes), do: write_quota_providers(:quota_providers_shown, codes)

  @doc "Force providers off the quota surfaces; see `set_quota_providers_shown/1`."
  @spec set_quota_providers_hidden([String.t()] | nil) ::
          {:ok, [String.t()] | nil} | {:error, term()}
  def set_quota_providers_hidden(codes), do: write_quota_providers(:quota_providers_hidden, codes)

  defp write_quota_providers(field, codes) when is_nil(codes) or is_list(codes) do
    valid = Arbiter.Quota.Visibility.provider_codes()

    if is_nil(codes) or Enum.all?(codes, &(&1 in valid)) do
      with {:ok, value} <- write_setting(field, codes && Enum.uniq(codes)) do
        Arbiter.Quota.QuotaCache.invalidate_all()
        {:ok, value}
      end
    else
      {:error, :invalid_value}
    end
  end

  defp write_quota_providers(_field, _codes), do: {:error, :invalid_value}

  # ---- singleton plumbing --------------------------------------------------

  # Reads never raise: a missing table (not-yet-migrated install) or any other
  # DB error is treated as "no override set".
  defp read_setting(field) do
    case singleton() do
      %Installation{} = row -> Map.fetch!(row, field)
      nil -> nil
    end
  rescue
    _ -> nil
  end

  # Writes surface errors normally — a failed write should be visible to
  # whoever asked for the change.
  defp write_setting(field, value) do
    with {:ok, row} <- get_or_create_singleton(),
         {:ok, updated} <- Ash.update(row, %{field => value}, action: :update) do
      {:ok, Map.fetch!(updated, field)}
    end
  end

  defp singleton do
    case Ash.read(Installation) do
      {:ok, [row | _]} -> row
      _ -> nil
    end
  end

  defp get_or_create_singleton do
    case Ash.read(Installation) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> Ash.create(Installation, %{})
      {:error, reason} -> {:error, reason}
    end
  end
end
