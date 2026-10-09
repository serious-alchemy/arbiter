defmodule Arbiter.Tasks.PermissionEvent do
  @moduledoc """
  The append-only audit trail of ticket-declared permissions
  (`docs/design/guardrail-profiles.md` §5.2).

  AshPaperTrail on the issue already keeps action inputs; this table makes the
  history *queryable*: who proposed, declared, requested, granted, denied or
  revoked which permission, and why.

    * `event` — `events/0`. `declared`/`defaulted` put a permission in force;
      `requested` and `suggested` do not (see `Arbiter.Tasks.Permissions`);
      `granted`/`denied`/`revoked` settle one.
    * `source` — `sources/0`: who the event came from.
    * `actor` — `Arbiter.Actor.label/1`-style label of whoever acted.
    * `run_id` — the worker run a `request` came from, when there is one.
    * `issue_id` — a plain string, not a foreign key: a removed ticket's
      history stays.

  Only `:create` and `:read` exist: there is no update or destroy action.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer

  @events [:declared, :defaulted, :suggested, :requested, :granted, :denied, :revoked]
  @sources [:filer, :workspace_default, :repo_default, :request, :system, :refine]

  @doc "Every event kind."
  @spec events() :: [atom()]
  def events, do: @events

  @doc "Every source."
  @spec sources() :: [atom()]
  def sources, do: @sources

  sqlite do
    table "permission_events"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:issue_id, :permission, :event, :source, :actor, :reason, :run_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :issue_id, :string, allow_nil?: false, public?: true
    attribute :permission, :string, allow_nil?: false, public?: true

    attribute :event, :atom do
      allow_nil? false
      public? true
      constraints one_of: @events
    end

    attribute :source, :atom do
      allow_nil? false
      public? true
      constraints one_of: @sources
    end

    attribute :actor, :string, public?: true
    attribute :reason, :string, public?: true
    attribute :run_id, :string, public?: true

    create_timestamp :inserted_at, public?: true
  end
end
