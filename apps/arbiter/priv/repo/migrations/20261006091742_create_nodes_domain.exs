defmodule Arbiter.Repo.Migrations.CreateNodesDomain do
  @moduledoc """
  RW3 (bd-9x9os5, `docs/design/remote-workers.md` §5): the node auth tier's
  tables.

    * `nodes` — one row per enrolled remote node. Only `sha256(secret)` of the
      node credential is stored (`credential_hash`, plus a short display
      `credential_prefix`); `previous_credential_hash` / `previous_valid_until`
      hold the rotation overlap. `revoke` clears both hashes.
    * `join_tokens` — one row per minted `arbj_` token. `token_hash` is unique
      and is all that is stored of the secret. Redemption is a conditional
      update on `used_at IS NULL AND expires_at > now`, so `used_at` /
      `used_by_node` are the single-use record.
    * `node_events` — append-only audit trail. `node_id` is deliberately not a
      foreign key: removing a node deletes its row, and its history must stay.

  Hand-written, like the other domain migrations.
  """

  use Ecto.Migration

  def change do
    create table(:nodes, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :labels, {:array, :text}, null: false, default: []
      add :max_workers, :bigint
      add :credential_hash, :text
      add :credential_prefix, :text
      add :previous_credential_hash, :text
      add :previous_valid_until, :utc_datetime_usec
      add :rotated_at, :utc_datetime_usec
      add :enrolled_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :join_token_id, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:nodes, [:name], name: :nodes_unique_name_index)

    create table(:join_tokens, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :token_hash, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :name, :text
      add :labels, {:array, :text}, null: false, default: []
      add :max_workers, :bigint
      add :created_by, :text
      add :used_at, :utc_datetime_usec
      add :used_by_node, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:join_tokens, [:token_hash], name: :join_tokens_unique_token_hash_index)

    create table(:node_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :node_id, :text
      add :kind, :text, null: false
      add :actor, :text
      add :detail, :map, null: false, default: %{}
      add :remote_addr_hint, :text
      add :at, :utc_datetime_usec, null: false
    end

    create index(:node_events, [:node_id, :at])
    create index(:node_events, [:at])
  end
end
