defmodule Arbiter.Repo.Migrations.AddNodesLivenessToInstallationSettings do
  @moduledoc """
  RW6 (bd-uixe28, `docs/design/remote-workers.md` §10.1): the `nodes.fence_after_s`
  and `nodes.lost_after_s` liveness thresholds. Both are nullable and NULL means
  "no override" (fence 60 s, lost fence + 30 s), so an install that never sets
  them behaves as the design's defaults.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_fence_after_s, :integer
      add :nodes_lost_after_s, :integer
    end
  end
end
