defmodule Arbiter.Repo.Migrations.AddSpendToAnthropicQuotas do
  @moduledoc """
  The `spend` block of `/api/oauth/usage`, stored as the raw map (bd-6sxrud).

  Anthropic's 2026-11 payload added a `spend` object
  (`{used: {amount_minor, currency, exponent}, limit, percent, severity,
  enabled, ...}`) next to `extra_usage`. Its shape is not yet modeled, so it is
  kept verbatim for later consumers. Legacy rows keep `NULL`.
  """

  use Ecto.Migration

  def up do
    alter table(:anthropic_quotas) do
      add :spend, :map
    end
  end

  def down do
    alter table(:anthropic_quotas) do
      remove :spend
    end
  end
end
