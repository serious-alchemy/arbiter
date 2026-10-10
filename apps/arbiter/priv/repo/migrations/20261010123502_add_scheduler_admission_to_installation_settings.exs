defmodule Arbiter.Repo.Migrations.AddSchedulerAdmissionToInstallationSettings do
  @moduledoc """
  DC6 (bd-9ycsk4, `docs/design/provider-dynamic-concurrency.md` §10.1): the
  install-wide `scheduler_admission` mode, `legacy | shadow | enforce`.
  Nullable; NULL means `legacy`, so an install that never sets it dispatches
  exactly as before. Additive, so rollback drops the column.
  """

  use Ecto.Migration

  def change do
    alter table(:installation_settings) do
      add :scheduler_admission, :string
    end
  end
end
