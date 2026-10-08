defmodule Arbiter.Repo.Migrations.CreateNodePairingRequests do
  @moduledoc """
  `pairing_requests` — one row per device-code style enrolment request
  (`docs/design/remote-workers.md` §5.7).

    * `code` is the short, typable, **non-secret** code the operator approves;
      unique, so a lookup by code is unambiguous.
    * `secret_hash` is `sha256` of the node's poll secret, the only thing that
      can collect the credential. The credential itself is never stored: it is
      generated when the approved request is redeemed.
    * `state` moves `pending` → `approved` → `redeemed`, or to `denied` /
      `expired`; every move is one conditional update (see `Arbiter.Nodes.Pairing`).

  Hand-written, like the other nodes-domain migrations.
  """

  use Ecto.Migration

  def change do
    create table(:pairing_requests, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :code, :text, null: false
      add :secret_hash, :text, null: false
      add :state, :text, null: false, default: "pending"
      add :hostname, :text, null: false
      add :peer, :text, null: false
      add :name, :text
      add :labels, {:array, :text}, null: false, default: []
      add :max_workers, :bigint
      add :expires_at, :utc_datetime_usec, null: false
      add :approved_by, :text
      add :approved_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
      add :node_id, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:pairing_requests, [:code], name: :pairing_requests_unique_code_index)
    create index(:pairing_requests, [:state, :expires_at])
  end
end
