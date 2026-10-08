defmodule Arbiter.Nodes.NodeEvent do
  @moduledoc """
  The append-only audit trail of the node auth tier
  (`docs/design/remote-workers.md` §5.4): who minted, redeemed, rotated,
  revoked or removed what.

    * `kind` — `kinds/0`.
    * `node_id` — the node concerned, or `nil` for an event with no node yet
      (`token_minted`, `join_failed`). A plain string, not a foreign key: a
      removed node's history stays.
    * `actor` — `Arbiter.Actor.label/1` of whoever acted (`operator:cli`,
      `node:<name>`).
    * `detail` — a small map. Never a secret: no token, credential or hash.
    * `remote_addr_hint` — the caller's address as the route saw it, for
      forensics only.

  Only `:create` and `:read` exist: there is no update or destroy action.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Nodes,
    data_layer: AshSqlite.DataLayer

  @kinds [
    :token_minted,
    :join_failed,
    :enrolled,
    :connected,
    :disconnected,
    :rotated,
    :updated,
    :drained,
    :revoked,
    :removed,
    :upgraded,
    :fenced,
    :node_lost,
    :checkout_rejected,
    :retained,
    :recovered,
    :reaped,
    :pairing_requested,
    :pairing_approved,
    :pairing_denied,
    :pairing_expired,
    :pairing_rejected
  ]

  @doc "Every event kind."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  sqlite do
    table "node_events"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [:node_id, :kind, :actor, :detail, :remote_addr_hint]

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :at, DateTime.utc_now())
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :node_id, :string, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :actor, :string, public?: true

    attribute :detail, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :remote_addr_hint, :string, public?: true

    attribute :at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end
  end
end
