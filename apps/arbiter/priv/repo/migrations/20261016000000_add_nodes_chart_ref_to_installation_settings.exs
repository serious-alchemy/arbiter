defmodule Arbiter.Repo.Migrations.AddNodesChartRefToInstallationSettings do
  @moduledoc """
  KH8 (bd-c2x975, `docs/design/remote-workers.md` §20.14): `nodes.chart_ref`, the
  `arbiter-node` chart reference the primary prints in `helm upgrade ...`. Nullable;
  NULL means "use the chart the node reports".
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :nodes_chart_ref, :string
    end
  end
end
