defmodule Arbiter.Repo.Migrations.AddAllowUnenforcedNetworkToNodes do
  @moduledoc """
  K12 (bd-4x1usg, `docs/design/remote-workers.md` §16 amendment A7):
  `nodes.allow_unenforced_network` — the operator's per-node override that lets
  `Arbiter.Nodes.Placement` use a cluster node reporting `degraded: netpol_unenforced`.
  Off by default; every change is audited (`node_events.kind = network_override`).

  Hand-written, like the other nodes migrations.
  """

  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :allow_unenforced_network, :boolean, null: false, default: false
    end
  end
end
