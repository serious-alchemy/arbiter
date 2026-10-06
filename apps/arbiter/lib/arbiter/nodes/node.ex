defmodule Arbiter.Nodes.Node do
  @moduledoc """
  An enrolled remote node (`docs/design/remote-workers.md` §5.2).

    * `status` — `:active`, `:draining` or `:revoked`. Online/offline is a live
      property of the node's channel session (a later child), not persisted.
    * `credential_hash` — `sha256` of the secret half of the node's
      `arbn_<id>.<secret>` credential. The secret itself is never stored, and
      the attribute is not public. `nil` once revoked.
    * `previous_credential_hash` / `previous_valid_until` — the credential
      before the last rotation, honoured until the overlap ends so the agent
      can persist the new one before the old one stops working.

  Write through `Arbiter.Nodes`: it owns redemption, rotation, revocation and
  the `NodeEvent` for each.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Nodes,
    data_layer: AshSqlite.DataLayer

  @statuses [:active, :draining, :revoked]

  @doc "Every node status."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  sqlite do
    table "nodes"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :enroll do
      primary? true

      accept [
        :id,
        :name,
        :labels,
        :max_workers,
        :credential_hash,
        :credential_prefix,
        :join_token_id,
        :enrolled_at
      ]
    end

    update :rotate do
      accept [
        :credential_hash,
        :credential_prefix,
        :previous_credential_hash,
        :previous_valid_until,
        :rotated_at
      ]
    end

    update :revoke do
      accept []
      require_atomic? false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :revoked)
        |> Ash.Changeset.force_change_attribute(:revoked_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:credential_hash, nil)
        |> Ash.Changeset.force_change_attribute(:previous_credential_hash, nil)
        |> Ash.Changeset.force_change_attribute(:previous_valid_until, nil)
      end
    end

    # The operator's edit surface (`arb node set`): what the node is called and
    # how much it may run. Never credentials or status.
    update :set do
      accept [:name, :labels, :max_workers]
    end

    update :touch do
      accept [:last_seen_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 128
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: @statuses
    end

    attribute :labels, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :max_workers, :integer do
      public? true
      constraints min: 1
    end

    # Secret-derived: not public, never serialized.
    attribute :credential_hash, :string
    attribute :credential_prefix, :string, public?: true
    attribute :previous_credential_hash, :string
    attribute :previous_valid_until, :utc_datetime_usec

    attribute :rotated_at, :utc_datetime_usec, public?: true

    attribute :enrolled_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec, public?: true
    attribute :last_seen_at, :utc_datetime_usec, public?: true
    attribute :join_token_id, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
