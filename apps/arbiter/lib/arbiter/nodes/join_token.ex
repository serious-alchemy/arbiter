defmodule Arbiter.Nodes.JoinToken do
  @moduledoc """
  One minted `arbj_` join token (`docs/design/remote-workers.md` §5.1).

  Only `token_hash` of the secret is stored. `used_at` / `used_by_node` are the
  single-use record, written by `Arbiter.Nodes.redeem_join_token/3` as one
  conditional update (`used_at IS NULL AND expires_at > now`); nothing else
  sets them. `name`, `labels` and `max_workers` are optional pre-bound values
  the enrolling node inherits.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Nodes,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "join_tokens"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read]

    create :mint do
      primary? true
      accept [:id, :token_hash, :expires_at, :name, :labels, :max_workers, :kind, :created_by]
    end
  end

  attributes do
    uuid_v7_primary_key :id, writable?: true

    attribute :token_hash, :string do
      allow_nil? false
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      public? true
      constraints min_length: 1, max_length: 128, match: ~r/\A[A-Za-z0-9._=:\/@-]+\z/
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

    # K9: what the token enrols. The enrolling controller must say the same
    # (`kind: cluster` in the enroll body); a machine's script says nothing.
    attribute :kind, :string do
      allow_nil? false
      public? true
      default "machine"
      constraints match: ~r/\A(machine|cluster)\z/
    end

    attribute :created_by, :string, public?: true
    attribute :used_at, :utc_datetime_usec, public?: true
    attribute :used_by_node, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_token_hash, [:token_hash]
  end
end
