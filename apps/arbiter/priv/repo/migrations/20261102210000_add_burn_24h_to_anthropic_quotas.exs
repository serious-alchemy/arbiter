defmodule Arbiter.Repo.Migrations.AddBurn24hToAnthropicQuotas do
  @moduledoc """
  The rolling-24h burn of the 7d window, computed at poll time (bd-cklotu).

  `burn_24h` is the fraction of the 7d window used in the last 24 h
  (`Arbiter.Quota.Burn`), `burn_24h_at` when it was computed. `NULL` is "no
  reading" (sparse history, or never polled). Legacy rows keep `NULL`.
  """

  use Ecto.Migration

  def up do
    alter table(:anthropic_quotas) do
      add :burn_24h, :float
      add :burn_24h_at, :utc_datetime
    end
  end

  def down do
    alter table(:anthropic_quotas) do
      remove :burn_24h_at
      remove :burn_24h
    end
  end
end
