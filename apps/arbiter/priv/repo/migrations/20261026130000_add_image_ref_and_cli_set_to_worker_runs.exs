defmodule Arbiter.Repo.Migrations.AddImageRefAndCliSetToWorkerRuns do
  @moduledoc """
  SI3 (`docs/design/remote-workers.md` §21.9): what a run ran *in*. `image_ref`
  is the image the spawn used (the digest-pinned ref for a registry node, else
  the tag) and `cli_set` the CLI set's short hash (`Arbiter.Worker.CliSet`, the
  image's `arbiter.cli-set` label). Both nullable: a host-local run uses the
  host's own toolchain, and rows before this migration recorded neither.
  """

  use Ecto.Migration

  def change do
    alter table(:worker_runs) do
      add :image_ref, :text
      add :cli_set, :text
    end
  end
end
