defmodule Arbiter.Repo.Migrations.AddImageFallbackToWorkerRuns do
  @moduledoc """
  SI-L (bd-4cq0qt, OD11): a local run takes the published per-repo image and, when it
  cannot be had (cold cache with the registry unreachable, nothing published yet, a
  label mismatch), builds the image locally instead. `image_fallback` is why, a short
  credential-free line; nil for a run that took the image it asked for and for rows
  before this migration.
  """

  use Ecto.Migration

  def change do
    alter table(:worker_runs) do
      add :image_fallback, :text
    end
  end
end
