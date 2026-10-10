defmodule Arbiter.Repo.Migrations.AddKindToNodesAndJoinTokens do
  @moduledoc """
  K9 (bd-6ez9yn, `docs/design/remote-workers.md` K§2.1): a join token is minted for a
  `machine` or a `cluster`, and the node it enrols inherits that kind, so the nodes
  page knows a cluster node before its controller has ever connected.

  `NOT NULL DEFAULT 'machine'`: every existing row is a machine, which is what it was.
  Written by hand, like the other column additions here.
  """

  use Ecto.Migration

  def up do
    alter table(:join_tokens) do
      add :kind, :text, null: false, default: "machine"
    end

    alter table(:nodes) do
      add :kind, :text, null: false, default: "machine"
    end
  end

  def down do
    alter table(:nodes) do
      remove :kind
    end

    alter table(:join_tokens) do
      remove :kind
    end
  end
end
