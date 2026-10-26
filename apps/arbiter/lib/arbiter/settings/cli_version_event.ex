defmodule Arbiter.Settings.CliVersionEvent do
  @moduledoc """
  Append-only audit row for a change to the pinned upstream CLI versions
  (SI1a, OD13). `kind` is `cli_version_bumped` for an auto-bump: `cli` the CLI
  (`claude`, `codex`), `from_version` / `to_version` the pin before and after,
  `detail` the integrity of the fetched artefact. Written by the CLI fetcher's bump job through
  `Arbiter.Settings.record_cli_version_event/1`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "cli_version_events"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:kind, :cli, :from_version, :to_version, :detail]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :cli, :string, allow_nil?: false, public?: true
    attribute :from_version, :string, public?: true
    attribute :to_version, :string, public?: true
    attribute :detail, :map, public?: true

    create_timestamp :at
  end
end
