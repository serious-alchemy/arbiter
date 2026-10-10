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

  alias Arbiter.Agents.Routing.Competence
  alias Arbiter.Nodes.Liveness
  alias Arbiter.Settings.Installation
  alias Arbiter.Settings.SchedulerChange

  @topic "installation_settings"

  resources do
    resource Installation
    resource SchedulerChange
  end

  @doc """
  The PubSub topic every persisted write announces itself on, as
  `{:installation_settings_changed, field}`. A page that mirrors a setting (the
  board's concurrency cap, `/settings`) subscribes so a change made anywhere —
  the dashboard, REST, the CLI, MCP — shows without a manual refresh.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

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
  Append an audit row for a scheduler pause (`paused?` true) or resume
  (bd-cl6zjn): `actor` who asked, `surface` where from.
  """
  @spec record_scheduler_change(boolean(), String.t() | nil, String.t() | nil) ::
          {:ok, SchedulerChange.t()} | {:error, term()}
  def record_scheduler_change(paused?, actor, surface) when is_boolean(paused?) do
    Ash.create(SchedulerChange, %{paused: paused?, actor: actor, surface: surface})
  end

  @doc """
  The scheduler pause/resume audit rows, newest first.
  """
  @spec scheduler_changes() :: [SchedulerChange.t()]
  def scheduler_changes do
    SchedulerChange |> Ash.read!() |> Enum.sort_by(& &1.at, {:desc, DateTime})
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
  The operator's capability-matrix override rows (bd-57uzkl), or `nil` for
  "code defaults only". See `Arbiter.Agents.CapabilityMatrix`. Never raises.
  """
  @spec capability_matrix() :: [map()] | nil
  def capability_matrix, do: read_setting(:capability_matrix)

  @doc """
  Set the capability-matrix override. Rows are validated and normalised by
  `Arbiter.Agents.CapabilityMatrix.normalize_rows/1`; an invalid row refuses
  the whole write. `nil` clears the override. Operator-owned: no worker, MCP or
  Loop surface writes it.
  """
  @spec set_capability_matrix([map()] | nil) :: {:ok, [map()] | nil} | {:error, term()}
  def set_capability_matrix(nil), do: write_setting(:capability_matrix, nil)

  def set_capability_matrix(rows) do
    with {:ok, rows} <- Arbiter.Agents.CapabilityMatrix.normalize_rows(rows) do
      write_setting(:capability_matrix, rows)
    end
  end

  @doc """
  The install-wide competence matrix override (`nil` = code defaults only).
  """
  @spec competence_matrix() :: [map()] | nil
  def competence_matrix, do: read_setting(:competence_matrix)

  @doc """
  The live override and the candidate (bd-dde4l7) from ONE read of the
  installation row — the routing hot path wants both per evaluation and each
  read costs milliseconds. Each side is `nil` when unset; never raises.
  """
  @spec competence_matrices() :: %{live: [map()] | nil, candidate: [map()] | nil}
  def competence_matrices do
    case singleton() do
      %Installation{} = row ->
        %{live: row.competence_matrix, candidate: row.competence_matrix_candidate}

      nil ->
        %{live: nil, candidate: nil}
    end
  rescue
    _ -> %{live: nil, candidate: nil}
  end

  @doc """
  Set the competence-matrix override. Rows are validated and normalised by
  `Arbiter.Agents.Routing.Competence.normalize_rows/1`; an invalid row refuses
  the whole write. `nil` clears the override. Operator-owned.
  """
  @spec set_competence_matrix([map()] | nil) :: {:ok, [map()] | nil} | {:error, term()}
  def set_competence_matrix(nil), do: write_setting(:competence_matrix, nil)

  def set_competence_matrix(rows) do
    with {:ok, rows} <- Competence.normalize_rows(rows) do
      write_setting(:competence_matrix, rows)
    end
  end

  @doc """
  The candidate competence matrix (bd-dde4l7; `nil` = none). The scorer ranks
  with it beside the live matrix and only records the result
  (`routing_decision["shadow_candidate"]`) — it never decides a dispatch until
  `promote_competence_matrix_candidate/0` makes it live.
  """
  @spec competence_matrix_candidate() :: [map()] | nil
  def competence_matrix_candidate, do: read_setting(:competence_matrix_candidate)

  @doc """
  The live competence matrix the last promotion replaced (`nil` = none; `[]`
  = the live matrix was code-defaults only). Kept for
  `rollback_competence_matrix/0`.
  """
  @spec competence_matrix_previous() :: [map()] | nil
  def competence_matrix_previous, do: read_setting(:competence_matrix_previous)

  @doc """
  Set (or, with `nil`, discard) the candidate competence matrix. Rows are
  validated like the live matrix's; the live matrix is not touched.
  """
  @spec set_competence_matrix_candidate([map()] | nil) :: {:ok, [map()] | nil} | {:error, term()}
  def set_competence_matrix_candidate(nil), do: write_setting(:competence_matrix_candidate, nil)

  def set_competence_matrix_candidate(rows) do
    with {:ok, rows} <- Competence.normalize_rows(rows) do
      write_setting(:competence_matrix_candidate, rows)
    end
  end

  @doc """
  Promote the candidate: it becomes the live matrix, the live matrix it
  replaces is kept as the previous one (for rollback) and the candidate slot is
  cleared — in one write, so a reader never sees the candidate live AND still
  pending. `{:error, :no_candidate}` when there is nothing to promote.
  """
  @spec promote_competence_matrix_candidate() :: {:ok, [map()]} | {:error, term()}
  def promote_competence_matrix_candidate do
    with {:ok, row} <- get_or_create_singleton(),
         [_ | _] = candidate <- row.competence_matrix_candidate || {:error, :no_candidate},
         {:ok, updated} <-
           write_settings(row, %{
             competence_matrix: candidate,
             competence_matrix_previous: row.competence_matrix || [],
             competence_matrix_candidate: nil
           }) do
      {:ok, updated.competence_matrix}
    else
      [] -> {:error, :no_candidate}
      {:error, _} = error -> error
    end
  end

  @doc """
  Roll the live matrix back to the one the last promotion replaced. The
  matrix being rolled back becomes the previous one, so a second call rolls
  forward again. `{:error, :no_previous}` when there is nothing to roll back to.
  """
  @spec rollback_competence_matrix() :: {:ok, [map()]} | {:error, term()}
  def rollback_competence_matrix do
    with {:ok, row} <- get_or_create_singleton(),
         previous when is_list(previous) <-
           row.competence_matrix_previous || {:error, :no_previous},
         {:ok, updated} <-
           write_settings(row, %{
             competence_matrix: previous,
             competence_matrix_previous: row.competence_matrix || []
           }) do
      {:ok, updated.competence_matrix}
    end
  end

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

  @doc """
  Whether the operator switched the output-offload sweeper on, or `nil` if
  never set. `nil` means off — the sweeper ships disabled (bd-16ljft).
  """
  @spec output_offload_enabled() :: boolean() | nil
  def output_offload_enabled, do: read_setting(:output_offload_enabled)

  @doc "Persist the output-offload switch; `nil` clears it (off)."
  @spec set_output_offload_enabled(boolean() | nil) ::
          {:ok, boolean() | nil} | {:error, term()}
  def set_output_offload_enabled(v) when is_nil(v) or is_boolean(v),
    do: write_setting(:output_offload_enabled, v)

  def set_output_offload_enabled(_), do: {:error, :invalid_value}

  # ---- scheduling (ES3, docs/design/epic-aware-scheduling.md §6.6) ----------

  @default_finish_first_max_wait_hours 24

  @doc "The aging escape's default, in hours, when no override is set."
  @spec default_finish_first_max_wait_hours() :: pos_integer()
  def default_finish_first_max_wait_hours, do: @default_finish_first_max_wait_hours

  @doc """
  The scheduling settings in force, defaults applied:
  `%{epic_floors_enabled: true, max_lifted_in_flight: nil, finish_first: false,
  finish_first_max_wait_hours: 24}`. `max_lifted_in_flight: nil` means
  `max(slots_total - 1, 1)`, which only the board knows. Never raises: an
  unreadable row reads as no overrides.
  """
  @spec scheduling() :: %{
          epic_floors_enabled: boolean(),
          max_lifted_in_flight: pos_integer() | nil,
          finish_first: boolean(),
          finish_first_max_wait_hours: pos_integer()
        }
  def scheduling do
    %{
      epic_floors_enabled: scheduling_epic_floors_enabled() != false,
      max_lifted_in_flight: scheduling_max_lifted_in_flight(),
      finish_first: scheduling_finish_first() == true,
      finish_first_max_wait_hours:
        scheduling_finish_first_max_wait_hours() || @default_finish_first_max_wait_hours
    }
  end

  @doc "The epic-floor kill switch override; `nil` = floors apply."
  @spec scheduling_epic_floors_enabled() :: boolean() | nil
  def scheduling_epic_floors_enabled, do: read_setting(:scheduling_epic_floors_enabled)

  @doc "Persist the epic-floor kill switch; `nil` clears it (floors apply)."
  @spec set_scheduling_epic_floors_enabled(boolean() | nil) ::
          {:ok, boolean() | nil} | {:error, term()}
  def set_scheduling_epic_floors_enabled(v) when is_nil(v) or is_boolean(v),
    do: write_setting(:scheduling_epic_floors_enabled, v)

  def set_scheduling_epic_floors_enabled(_), do: {:error, :invalid_value}

  @doc "The lift cap override; `nil` = `max(slots_total - 1, 1)`."
  @spec scheduling_max_lifted_in_flight() :: pos_integer() | nil
  def scheduling_max_lifted_in_flight, do: read_setting(:scheduling_max_lifted_in_flight)

  @doc "Persist the lift cap; `nil` clears it."
  @spec set_scheduling_max_lifted_in_flight(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_scheduling_max_lifted_in_flight(n) when is_nil(n) or (is_integer(n) and n > 0),
    do: write_setting(:scheduling_max_lifted_in_flight, n)

  def set_scheduling_max_lifted_in_flight(_), do: {:error, :invalid_value}

  @doc "The finish-first switch override; `nil` = off."
  @spec scheduling_finish_first() :: boolean() | nil
  def scheduling_finish_first, do: read_setting(:scheduling_finish_first)

  @doc "Persist the finish-first switch; `nil` clears it (off)."
  @spec set_scheduling_finish_first(boolean() | nil) ::
          {:ok, boolean() | nil} | {:error, term()}
  def set_scheduling_finish_first(v) when is_nil(v) or is_boolean(v),
    do: write_setting(:scheduling_finish_first, v)

  def set_scheduling_finish_first(_), do: {:error, :invalid_value}

  @doc "The finish-first aging threshold override (hours); `nil` = #{@default_finish_first_max_wait_hours}."
  @spec scheduling_finish_first_max_wait_hours() :: pos_integer() | nil
  def scheduling_finish_first_max_wait_hours,
    do: read_setting(:scheduling_finish_first_max_wait_hours)

  @doc "Persist the finish-first aging threshold; `nil` clears it."
  @spec set_scheduling_finish_first_max_wait_hours(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_scheduling_finish_first_max_wait_hours(n)
      when is_nil(n) or (is_integer(n) and n > 0),
      do: write_setting(:scheduling_finish_first_max_wait_hours, n)

  def set_scheduling_finish_first_max_wait_hours(_), do: {:error, :invalid_value}

  # ---- nodes (RW3, docs/design/remote-workers.md §4.3, §5.1) -----------------

  @default_join_token_ttl_minutes 15
  @max_join_token_ttl_minutes 24 * 60

  @doc "The join-token TTL in force when none is overridden, in minutes."
  @spec default_join_token_ttl_minutes() :: pos_integer()
  def default_join_token_ttl_minutes, do: @default_join_token_ttl_minutes

  @doc "The longest join-token TTL a setting may name, in minutes."
  @spec max_join_token_ttl_minutes() :: pos_integer()
  def max_join_token_ttl_minutes, do: @max_join_token_ttl_minutes

  @doc "The release tag whose update banner was dismissed, or `nil`."
  @spec dismissed_update_version() :: String.t() | nil
  def dismissed_update_version, do: read_setting(:dashboard_dismissed_update_version)

  @doc "Persist the dismissed update tag; `nil` clears it."
  @spec set_dismissed_update_version(String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def set_dismissed_update_version(v) when is_nil(v) or (is_binary(v) and v != ""),
    do: write_setting(:dashboard_dismissed_update_version, v)

  def set_dismissed_update_version(_), do: {:error, :invalid_value}

  @doc "The deploy record key (`DeployStatus.dismiss_key/1`) whose banner was dismissed, or `nil`."
  @spec dismissed_deploy() :: String.t() | nil
  def dismissed_deploy, do: read_setting(:dashboard_dismissed_deploy)

  @doc "Persist the dismissed deploy key; `nil` clears it."
  @spec set_dismissed_deploy(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def set_dismissed_deploy(v) when is_nil(v) or (is_binary(v) and v != ""),
    do: write_setting(:dashboard_dismissed_deploy, v)

  def set_dismissed_deploy(_), do: {:error, :invalid_value}

  @doc "`nodes.public_url` (no trailing slash), or `nil` when unset."
  @spec nodes_public_url() :: String.t() | nil
  def nodes_public_url, do: read_setting(:nodes_public_url)

  @doc "Persist `nodes.public_url`; `nil` clears it. Must be a bare http(s) origin/path."
  @spec set_nodes_public_url(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def set_nodes_public_url(nil), do: write_setting(:nodes_public_url, nil)

  def set_nodes_public_url(url) when is_binary(url) do
    case normalize_public_url(url) do
      {:ok, normalized} -> write_setting(:nodes_public_url, normalized)
      :error -> {:error, :invalid_value}
    end
  end

  def set_nodes_public_url(_), do: {:error, :invalid_value}

  @doc """
  Normalise a `nodes.public_url`: `http` or `https`, a host, no credentials,
  query or fragment; the trailing slash is dropped. `:error` otherwise.
  """
  @spec normalize_public_url(term()) :: {:ok, String.t()} | :error
  def normalize_public_url(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri |> URI.to_string() |> String.trim_trailing("/")}

      _ ->
        :error
    end
  end

  def normalize_public_url(_), do: :error

  @doc "Whether a non-private `nodes.public_url` is tolerated (`nodes.allow_public_endpoint`)."
  @spec nodes_allow_public_endpoint?() :: boolean()
  def nodes_allow_public_endpoint?, do: read_setting(:nodes_allow_public_endpoint) == true

  @doc "The persisted `nodes.allow_public_endpoint` override; `nil` = refused."
  @spec nodes_allow_public_endpoint() :: boolean() | nil
  def nodes_allow_public_endpoint, do: read_setting(:nodes_allow_public_endpoint)

  @spec set_nodes_allow_public_endpoint(boolean() | nil) ::
          {:ok, boolean() | nil} | {:error, term()}
  def set_nodes_allow_public_endpoint(v) when is_nil(v) or is_boolean(v),
    do: write_setting(:nodes_allow_public_endpoint, v)

  def set_nodes_allow_public_endpoint(_), do: {:error, :invalid_value}

  @doc "The join-token TTL override in minutes, or `nil`."
  @spec nodes_join_token_ttl_override() :: pos_integer() | nil
  def nodes_join_token_ttl_override, do: read_setting(:nodes_join_token_ttl_minutes)

  @doc "The join-token TTL in force, in minutes (override, else 15)."
  @spec nodes_join_token_ttl_minutes() :: pos_integer()
  def nodes_join_token_ttl_minutes,
    do: nodes_join_token_ttl_override() || @default_join_token_ttl_minutes

  @spec set_nodes_join_token_ttl_minutes(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_nodes_join_token_ttl_minutes(n)
      when is_nil(n) or (is_integer(n) and n > 0 and n <= @max_join_token_ttl_minutes),
      do: write_setting(:nodes_join_token_ttl_minutes, n)

  def set_nodes_join_token_ttl_minutes(_), do: {:error, :invalid_value}

  @doc "The `nodes.fence_after_s` override in seconds, or `nil` (60)."
  @spec nodes_fence_after_s() :: pos_integer() | nil
  def nodes_fence_after_s, do: read_setting(:nodes_fence_after_s)

  @doc "The `nodes.lost_after_s` override in seconds, or `nil` (fence + 30)."
  @spec nodes_lost_after_s_override() :: pos_integer() | nil
  def nodes_lost_after_s_override, do: read_setting(:nodes_lost_after_s)

  @doc """
  Persist `nodes.fence_after_s` (30-90; `nil` clears it). Refused when it would
  reach the `lost_after_s` in force: `fence_after_s < lost_after_s` is the
  design's invariant (§10.1) and is checked on every write of either value.
  """
  @spec set_nodes_fence_after_s(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_nodes_fence_after_s(n) when is_nil(n) or is_integer(n) do
    effective = n || Liveness.default_fence_after_s()

    with {:ok, _} <- Liveness.validate(effective, nodes_lost_after_s_override()) do
      write_setting(:nodes_fence_after_s, n)
    end
  end

  def set_nodes_fence_after_s(_), do: {:error, :invalid_value}

  @doc """
  Persist `nodes.lost_after_s` (`nil` clears it back to fence + 30). Refused
  unless it is strictly above the fence in force.
  """
  @spec set_nodes_lost_after_s(pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  def set_nodes_lost_after_s(n) when is_nil(n) or is_integer(n) do
    fence = nodes_fence_after_s() || Liveness.default_fence_after_s()

    with {:ok, _} <- Liveness.validate(fence, n) do
      write_setting(:nodes_lost_after_s, n)
    end
  end

  def set_nodes_lost_after_s(_), do: {:error, :invalid_value}

  @doc "The operator's override of the primary's own worker cap (`local` on the nodes page), or `nil`."
  @spec nodes_local_max_workers() :: non_neg_integer() | nil
  def nodes_local_max_workers, do: read_setting(:nodes_local_max_workers)

  @doc "Persist the local worker cap; `0` is allowed (run nothing here), `nil` clears the override."
  @spec set_nodes_local_max_workers(non_neg_integer() | nil) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def set_nodes_local_max_workers(n) when is_nil(n) or (is_integer(n) and n >= 0),
    do: write_setting(:nodes_local_max_workers, n)

  def set_nodes_local_max_workers(_), do: {:error, :invalid_value}

  # ---- nodes.registry (K8) -------------------------------------------------

  # `host[:port]` then optional `/path` segments: no scheme, no userinfo, no
  # query. The same shape `podman push` takes as a repository prefix.
  @registry_re ~r|\A[a-z0-9][a-z0-9.-]*(:\d{1,5})?(/[a-z0-9][a-z0-9._-]*)*\z|i
  @registry_user_re ~r/\A[^\s\x00-\x1f\x7f:]{1,256}\z/
  @registry_password_max 4096

  @doc "`nodes.registry` (`host[:port][/path]`), or `nil` when no registry is configured."
  @spec nodes_registry() :: String.t() | nil
  def nodes_registry, do: read_setting(:nodes_registry)

  @doc "Whether `value` is a valid `nodes.registry` reference."
  @spec valid_registry?(term()) :: boolean()
  def valid_registry?(value) when is_binary(value),
    do: byte_size(value) <= 255 and Regex.match?(@registry_re, value)

  def valid_registry?(_), do: false

  @spec set_nodes_registry(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def set_nodes_registry(nil), do: write_setting(:nodes_registry, nil)

  def set_nodes_registry(value) when is_binary(value) do
    if valid_registry?(value),
      do: write_setting(:nodes_registry, value),
      else: {:error, :invalid_value}
  end

  def set_nodes_registry(_), do: {:error, :invalid_value}

  @doc "The registry login, or `nil`."
  @spec nodes_registry_username() :: String.t() | nil
  def nodes_registry_username, do: read_setting(:nodes_registry_username)

  @spec set_nodes_registry_username(String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def set_nodes_registry_username(nil), do: write_setting(:nodes_registry_username, nil)

  def set_nodes_registry_username(user) when is_binary(user) do
    if Regex.match?(@registry_user_re, user),
      do: write_setting(:nodes_registry_username, user),
      else: {:error, :invalid_value}
  end

  def set_nodes_registry_username(_), do: {:error, :invalid_value}

  @doc "Whether the registry is plain-HTTP or self-signed (`--tls-verify=false`)."
  @spec nodes_registry_insecure?() :: boolean()
  def nodes_registry_insecure?, do: read_setting(:nodes_registry_insecure) == true

  @doc "The persisted `nodes.registry_insecure` override."
  @spec nodes_registry_insecure() :: boolean() | nil
  def nodes_registry_insecure, do: read_setting(:nodes_registry_insecure)

  @spec set_nodes_registry_insecure(boolean() | nil) :: {:ok, boolean() | nil} | {:error, term()}
  def set_nodes_registry_insecure(v) when is_nil(v) or is_boolean(v),
    do: write_setting(:nodes_registry_insecure, v)

  def set_nodes_registry_insecure(_), do: {:error, :invalid_value}

  @doc """
  The decrypted registry password, or `nil`. For `Arbiter.Worker.Image.Registry`
  only: it is handed to podman through a 0600 auth file, never argv, and no
  settings surface (`Settings.Registry`, REST, MCP, CLI) returns it.
  """
  @spec nodes_registry_password() :: String.t() | nil
  def nodes_registry_password do
    case read_setting(:nodes_registry_password) do
      cipher when is_binary(cipher) -> Arbiter.Vault.decrypt!(cipher)
      _ -> nil
    end
  rescue
    # A key that no longer decrypts is "no password", not a crashed publish.
    _ -> nil
  end

  @doc "Whether a registry password is stored (without decrypting it)."
  @spec nodes_registry_password_set?() :: boolean()
  def nodes_registry_password_set?, do: is_binary(read_setting(:nodes_registry_password))

  @doc """
  Encrypt (`Arbiter.Vault`) and persist the registry password; `nil` clears it.
  Returns `{:ok, :set | nil}`: the plaintext and the ciphertext both stay out
  of the result.
  """
  @spec set_nodes_registry_password(String.t() | nil) :: {:ok, :set | nil} | {:error, term()}
  def set_nodes_registry_password(nil) do
    with {:ok, _} <- write_setting(:nodes_registry_password, nil), do: {:ok, nil}
  end

  def set_nodes_registry_password(pw)
      when is_binary(pw) and byte_size(pw) > 0 and byte_size(pw) <= @registry_password_max do
    with {:ok, _} <- write_setting(:nodes_registry_password, Arbiter.Vault.encrypt!(pw)),
         do: {:ok, :set}
  end

  def set_nodes_registry_password(_), do: {:error, :invalid_value}

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
      announce(field)
      {:ok, Map.fetch!(updated, field)}
    end
  end

  # Several fields in ONE update — a promotion must never be observable half-done.
  defp write_settings(row, changes) do
    with {:ok, updated} <- Ash.update(row, changes, action: :update) do
      Enum.each(Map.keys(changes), &announce/1)
      {:ok, updated}
    end
  end

  defp announce(field) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, @topic, {:installation_settings_changed, field})
  rescue
    _ -> :ok
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
