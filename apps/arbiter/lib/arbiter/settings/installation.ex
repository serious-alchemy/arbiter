defmodule Arbiter.Settings.Installation do
  @moduledoc """
  Singleton row holding install-wide runtime settings that were previously
  only changeable by editing `config/*.exs` and redeploying (bd-2ogep0).

  Exactly one row is expected to exist at any time — enforced in
  `Arbiter.Settings` (get-or-create-singleton on first read/write), not at the
  DB layer, so future settings can be added here as plain nullable columns
  without a new singleton mechanism.

  ## Fields

    * `:local_cap_advisory` — the line the DC1 migration left when it removed a
      stored `conductor_system_max_concurrent`
      (`Arbiter.Settings.local_cap_advisory/0`); cleared when the operator sets
      the local cap.
    * `:credential_watchdog_adapters` — agent-type names
      (`Arbiter.Agents.valid_agent_types/0`) the
      `Arbiter.Agents.CredentialWatchdog` should probe. `nil` means "probe
      every adapter in `Arbiter.Agents.adapters/0`"; `[]` means "probe
      nothing".
    * `:credential_watchdog_interval_ms` / `:credential_watchdog_recovery_interval_ms`
      — Watchdog poll intervals. `nil` falls back to the
      `:arbiter, :credential_watchdog` application env, else the Watchdog's
      hardcoded defaults (5 minutes / 1 minute).
    * `:output_offload_enabled` — operator switch for
      `Arbiter.Workers.OutputOffload`, read on every tick. `nil` and `false`
      both mean off; only `true` sweeps.
    * `:scheduling_epic_floors_enabled` / `:scheduling_max_lifted_in_flight` /
      `:scheduling_finish_first` / `:scheduling_finish_first_max_wait_hours` —
      the epic-aware Ready order (`docs/design/epic-aware-scheduling.md` §6.6,
      read by `Arbiter.Board.Snapshot`). `nil` means the default: floors on,
      lift cap `max(slots_total - 1, 1)`, finish-first off, 24 hour aging.
    * `:board_autopilot_paused` — `Arbiter.Board.Autopilot`'s pause flag.
      `nil` means "no persisted value — fall back to the
      `:arbiter, :board_autopilot, enabled:` application env, else paused".
    * `:board_autopilot_paused_at` / `:board_autopilot_paused_by` — when the
      flag was last changed and, where known, by what caller (an MCP tool, the
      REST API, the dashboard). `nil` until the first pause/resume.

    * `:nodes_public_url` / `:nodes_allow_public_endpoint` /
      `:nodes_join_token_ttl_minutes` — the `nodes.*` settings of the remote-worker
      node tier (`docs/design/remote-workers.md` §4.3, §5.1): the URL a node dials,
      whether a non-private endpoint is tolerated, and the join-token TTL
      (`nil` = off / refused / 15 minutes).
    * `:nodes_local_max_workers` — the override of the primary's own worker cap
      (the nodes page's `local` row); nil = no override, 0 allowed.
    * `:nodes_fence_after_s` / `:nodes_lost_after_s` — the liveness thresholds
      (§10.1; `Arbiter.Nodes.Liveness`): `nil` = 60 s / fence + 30 s.
    * `:nodes_registry` / `:nodes_registry_username` / `:nodes_registry_password` /
      `:nodes_registry_insecure` — the registry the primary publishes images to
      (`Arbiter.Worker.Image.Publisher`, K8). The password is a Cloak ciphertext;
      `nil` registry = nothing is published.

  Every field is nullable and `nil` always means "no override" — a fresh
  install that never writes here behaves exactly as it did before the setting
  existed.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "installation_settings"
    repo Arbiter.Repo
  end

  @settable [
    :local_cap_advisory,
    :credential_watchdog_adapters,
    :credential_watchdog_interval_ms,
    :credential_watchdog_recovery_interval_ms,
    :board_autopilot_paused,
    :board_autopilot_paused_at,
    :board_autopilot_paused_by,
    :provider_pauses,
    :capability_matrix,
    :competence_matrix,
    :competence_matrix_candidate,
    :competence_matrix_previous,
    :quota_providers_shown,
    :quota_providers_hidden,
    :output_offload_enabled,
    :scheduling_epic_floors_enabled,
    :scheduling_max_lifted_in_flight,
    :scheduling_finish_first,
    :scheduling_finish_first_max_wait_hours,
    :nodes_public_url,
    :nodes_allow_public_endpoint,
    :nodes_join_token_ttl_minutes,
    :nodes_fence_after_s,
    :nodes_lost_after_s,
    :nodes_local_max_workers,
    :nodes_registry,
    :nodes_registry_username,
    :nodes_registry_password,
    :nodes_registry_insecure,
    :dashboard_dismissed_update_version,
    :dashboard_dismissed_deploy
  ]

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @settable
    end

    update :update do
      primary? true
      require_atomic? false
      accept @settable
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :local_cap_advisory, :string do
      public? true
      allow_nil? true

      description "Advisory left by the DC1 migration for a removed conductor_system_max_concurrent; shown by doctor until the local cap is set."
    end

    attribute :credential_watchdog_adapters, {:array, :string} do
      public? true
      allow_nil? true

      description "Agent-type names the CredentialWatchdog probes; nil probes every adapter, [] probes none."
    end

    attribute :credential_watchdog_interval_ms, :integer do
      public? true
      allow_nil? true
      constraints min: 1

      description "CredentialWatchdog normal poll interval (ms); nil falls back to app env / default."
    end

    attribute :credential_watchdog_recovery_interval_ms, :integer do
      public? true
      allow_nil? true
      constraints min: 1

      description "CredentialWatchdog re-probe interval while an adapter is expired (ms); nil falls back to app env / default."
    end

    attribute :board_autopilot_paused, :boolean do
      public? true
      allow_nil? true

      description "Board Autopilot's persisted pause flag; nil falls back to app env / paused."
    end

    attribute :board_autopilot_paused_at, :utc_datetime_usec do
      public? true
      allow_nil? true

      description "When board_autopilot_paused was last changed."
    end

    attribute :board_autopilot_paused_by, :string do
      public? true
      allow_nil? true

      description ~s[Who/what last changed board_autopilot_paused, where known (e.g. "mcp", "api", "dashboard").]
    end

    attribute :provider_pauses, :map do
      public? true
      allow_nil? true

      description ~s[Provider / account pauses (bd-5ef587): %{target => %{"reason", "by", "at"}}, target being a provider code ("claude") or "account:<id>". nil = nothing paused.]
    end

    attribute :capability_matrix, {:array, :map} do
      public? true
      allow_nil? true

      description ~s[Operator-owned capability matrix override (bd-57uzkl): rows %{"match" => %{"provider", "model"}, "resume", "async_verification", "evidence"} consulted ahead of the code defaults. nil = defaults only.]
    end

    attribute :competence_matrix, {:array, :map} do
      public? true
      allow_nil? true

      description ~s[Operator-owned competence matrix (bd-biycyw): rows consulted ahead of code defaults.]
    end

    attribute :competence_matrix_candidate, {:array, :map} do
      public? true
      allow_nil? true

      description "Candidate competence matrix (bd-dde4l7): ranked beside the live one in shadow only (recorded as routing_decision shadow_candidate); never dispatches until promoted. nil = no candidate."
    end

    attribute :competence_matrix_previous, {:array, :map} do
      public? true
      allow_nil? true

      description "The live competence matrix a promotion replaced (bd-dde4l7), kept for rollback. nil = nothing to roll back to."
    end

    attribute :quota_providers_shown, {:array, :string} do
      public? true
      allow_nil? true

      description "Quota provider codes forced onto the status bar and /usage (bd-i2gwwn); nil = auto-detect."
    end

    attribute :quota_providers_hidden, {:array, :string} do
      public? true
      allow_nil? true

      description "Quota provider codes forced off the status bar and /usage (bd-i2gwwn); wins over shown. nil = auto-detect."
    end

    attribute :output_offload_enabled, :boolean do
      public? true
      allow_nil? true

      description "Whether the OutputOffload sweeper runs (bd-16ljft); nil / false = off, only true sweeps."
    end

    attribute :scheduling_epic_floors_enabled, :boolean do
      public? true
      allow_nil? true

      description "Kill switch for epic priority floors (ES3); nil / true = floors apply, false ignores every floor."
    end

    attribute :scheduling_max_lifted_in_flight, :integer do
      public? true
      allow_nil? true
      constraints min: 1

      description "Most :active tickets an epic floor may have lifted at once (ES3); nil = max(slots_total - 1, 1)."
    end

    attribute :scheduling_finish_first, :boolean do
      public? true
      allow_nil? true

      description "Finish-first tiebreak inside a priority band (ES3); nil / false = off."
    end

    attribute :scheduling_finish_first_max_wait_hours, :integer do
      public? true
      allow_nil? true
      constraints min: 1

      description "Hours a card may wait Ready and unblocked before it escapes the finish-first tiebreak (ES3); nil = 24."
    end

    attribute :dashboard_dismissed_update_version, :string do
      public? true
      allow_nil? true

      description "dashboard.dismissed_update_version: the release tag whose update banner the operator dismissed; nil = none."
    end

    attribute :dashboard_dismissed_deploy, :string do
      public? true
      allow_nil? true

      description "dashboard.dismissed_deploy: key (tag + finish time) of the deploy-outcome banner the operator dismissed; nil = none."
    end

    attribute :nodes_public_url, :string do
      public? true
      allow_nil? true

      description "nodes.public_url: the origin an agent dials for enrollment and its socket (RW3); nil = unset."
    end

    attribute :nodes_allow_public_endpoint, :boolean do
      public? true
      allow_nil? true

      description "nodes.allow_public_endpoint: tolerate a non-private nodes.public_url (RW3); nil / false = refused."
    end

    attribute :nodes_join_token_ttl_minutes, :integer do
      public? true
      allow_nil? true
      constraints min: 1, max: 1440

      description "nodes.join_token_ttl_minutes: default join-token lifetime (RW3); nil = 15, max 1440."
    end

    attribute :nodes_fence_after_s, :integer do
      public? true
      allow_nil? true
      constraints min: 30, max: 90

      description "nodes.fence_after_s: silence after which a node agent stops its containers (RW6); nil = 60, 30-90."
    end

    attribute :nodes_lost_after_s, :integer do
      public? true
      allow_nil? true
      constraints min: 31, max: 3600

      description "nodes.lost_after_s: silence after which the primary declares a node lost (RW6); must exceed the fence; nil = fence + 30."
    end

    attribute :nodes_local_max_workers, :integer do
      public? true
      allow_nil? true
      constraints min: 0

      description "nodes.local_max_workers: the operator's cap on the primary's own workers (RW7); nil = the primary's hardware suggestion, 0 = run nothing locally."
    end

    attribute :nodes_registry, :string do
      public? true
      allow_nil? true

      description "nodes.registry: the host[:port]/path the primary publishes worker, seed and controller images to (K8); nil = no registry, nothing is pushed."
    end

    attribute :nodes_registry_username, :string do
      public? true
      allow_nil? true

      description "nodes.registry_username: the registry login (K8)."
    end

    # A `Arbiter.Vault` (Cloak) ciphertext, never the plaintext: not public, and
    # `sensitive?` keeps even the ciphertext out of inspect output.
    attribute :nodes_registry_password, :binary do
      public? false
      allow_nil? true
      sensitive? true

      description "nodes.registry_password: Cloak-encrypted registry password (K8); write-only."
    end

    attribute :nodes_registry_insecure, :boolean do
      public? true
      allow_nil? true

      description "nodes.registry_insecure: push to a plain-HTTP or self-signed registry (K8); nil/false = TLS verified."
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
