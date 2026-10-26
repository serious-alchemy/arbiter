defmodule Arbiter.Repo.Migrations.AddWorkerCliToInstallationSettings do
  @moduledoc """
  SI1a (`docs/design/remote-workers.md` §21.2.3, OD13): the pinned upstream CLI
  versions (`worker.cli.versions`), the CLIs auto-bump leaves alone
  (`worker.cli.manual`), the CLI-set hold (`worker.cli_set.hold`), and the
  append-only audit trail of version bumps. All nullable; NULL means no pin, no
  opt-out, no hold.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :worker_cli_versions, :map
      add :worker_cli_manual, {:array, :text}
      add :worker_cli_set_hold, :text
    end

    create table(:cli_version_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :kind, :text, null: false
      add :cli, :text, null: false
      add :from_version, :text
      add :to_version, :text
      add :detail, :map
      add :at, :utc_datetime_usec, null: false
    end

    create index(:cli_version_events, [:cli, :at])
  end
end
