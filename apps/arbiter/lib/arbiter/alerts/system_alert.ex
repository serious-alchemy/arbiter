defmodule Arbiter.Alerts.SystemAlert do
  @moduledoc """
  One system-alert episode (ticket lifecycle 8/13, bd-7gt8rm): a problem with
  the installation rather than a ticket — a credential that expired, the quota
  poll failing, the quota snapshot gone stale (bd-2wnkoq), overage spend past
  its alert threshold, a task's worker spend past its budget.

    * `kind` — what the alert is about (`kinds/0`).
    * `key` — which one of that kind: an adapter and source, an account-wide
      poll, a provider account's snapshot, a workspace, a task. At most one
      row per `(kind, key)` is active
      (uncleared) at a time; the partial unique index enforces it.
    * `workspace_id` — where the alert is shown and announced. Metadata only:
      it is not part of the dedupe.
    * `subject` / `detail` — a one-line headline and the full explanation.
    * `owner` — who acts on it. Every system alert is the operator's
      (bd-9yqspm §3).
    * `raised_at` — when the episode began; `last_raised_at` and
      `raise_count` — when and how often its producer last reported it.
    * `cleared_at` — when its condition cleared. nil while active.

  Write through `Arbiter.Alerts`, which folds a repeated raise into the active
  row and announces each change.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Alerts,
    data_layer: AshSqlite.DataLayer

  @kinds [
    :budget_exceeded,
    :credential_expired,
    :overage_alert,
    :quota_poll_failing,
    :quota_snapshot_stale,
    :spend_cap
  ]
  @owners [:operator, :coordinator]

  @doc "Every system-alert kind."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  sqlite do
    table "system_alerts"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :raise do
      primary? true
      accept [:kind, :key, :workspace_id, :subject, :detail, :owner]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.force_change_attribute(:raised_at, now)
        |> Ash.Changeset.force_change_attribute(:last_raised_at, now)
      end
    end

    update :refresh do
      accept [:subject, :detail]
      require_atomic? false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:last_raised_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:raise_count, changeset.data.raise_count + 1)
      end
    end

    update :clear do
      accept []
      require_atomic? false
      change set_attribute(:cleared_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints max_length: 512, trim?: false
    end

    attribute :workspace_id, :string do
      public? true
    end

    attribute :subject, :string do
      public? true
    end

    attribute :detail, :string do
      allow_nil? false
      public? true
      default ""
      constraints trim?: false, allow_empty?: true
    end

    attribute :owner, :atom do
      allow_nil? false
      public? true
      default :operator
      constraints one_of: @owners
    end

    attribute :raised_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :last_raised_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :raise_count, :integer do
      allow_nil? false
      public? true
      default 1
    end

    attribute :cleared_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
