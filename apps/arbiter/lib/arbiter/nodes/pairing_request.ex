defmodule Arbiter.Nodes.PairingRequest do
  @moduledoc """
  One device-code style enrolment request (`docs/design/remote-workers.md`
  §5.7). Created by `Arbiter.Nodes.Pairing.request/2`; the state moves only
  through the conditional updates in that module (nothing else writes `state`).

    * `code` — the short, typable, non-secret code both screens show.
    * `secret_hash` — hash of the poll secret only the requesting node holds.
    * `hostname` / `peer` — what the operator sees when deciding: the hostname
      is the node's own (sanitised, untrusted) claim, the peer is the address
      the primary saw.
    * `name` / `labels` / `max_workers` — the node's proposal; the operator's
      values given at approval replace them.
    * `state` — `:pending`, `:approved`, `:redeemed`, `:denied` or `:expired`.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Nodes,
    data_layer: AshSqlite.DataLayer

  @states [:pending, :approved, :redeemed, :denied, :expired]

  @doc "Every pairing state."
  @spec states() :: [atom()]
  def states, do: @states

  sqlite do
    table "pairing_requests"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :request do
      primary? true

      accept [
        :id,
        :code,
        :secret_hash,
        :hostname,
        :peer,
        :name,
        :labels,
        :max_workers,
        :expires_at
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :code, :string, allow_nil?: false, public?: true
    attribute :secret_hash, :string, allow_nil?: false

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: @states
    end

    attribute :hostname, :string, allow_nil?: false, public?: true
    attribute :peer, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :labels, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :max_workers, :integer, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :approved_by, :string, public?: true
    attribute :approved_at, :utc_datetime_usec, public?: true
    attribute :resolved_at, :utc_datetime_usec, public?: true
    attribute :node_id, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_code, [:code]
  end
end
