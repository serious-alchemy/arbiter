defmodule Arbiter.Repo.Migrations.AddWindowMinutesToCodexQuotas do
  @moduledoc """
  bd-7lkvb6: persist each Codex window's length (`wham/usage`
  `limit_window_seconds`, stored as minutes) so the gate can label and pace
  the free tier's single 30-day window instead of treating it as an
  unpaceable `"session"`.

  Two nullable columns, no backfill: `NULL` keeps the legacy
  `"session"`/`"weekly"` labels until the next poll fills them in. Additive
  and safe to hot-run; rollback drops the columns.
  """

  use Ecto.Migration

  def up do
    alter table(:codex_quotas) do
      add :session_window_minutes, :integer
      add :weekly_window_minutes, :integer
    end
  end

  def down do
    alter table(:codex_quotas) do
      remove :session_window_minutes
      remove :weekly_window_minutes
    end
  end
end
