defmodule Arbiter.Repo.Migrations.AddWorkerImageLocalPublishedToInstallationSettings do
  @moduledoc """
  SI-L off switch: `worker.image.local_published`. Nullable; NULL means the default
  (local runs take the published image). `false` switches it, and the local image GC, off.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :worker_image_local_published, :boolean
    end
  end
end
