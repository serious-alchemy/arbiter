defmodule Arbiter.Repo.Migrations.AddProviderRoutingFields do
  @moduledoc """
  Provider routing by most quota left (bd-40pzpj).

  `worker_runs` gains what the routing decision chose and why:

    * `provider_account_id` — the provider account the run was routed to;
    * `model_family` — `anthropic` / `google` / `openai` / … for that account
      and model (`Arbiter.Agents.ModelFamily`);
    * `routing_decision` — the whole decision as JSON: per-candidate
      headroom, dropped candidates with their reasons, and any fallback or
      override.

  `issues` gains the implementer pin set at the task's first routed
  dispatch, which every later implementer role reuses:
  `implementer_account_id` and `implementer_family`.

  All nullable, no backfill: with `routing.provider_selection` unset (every
  workspace today) nothing writes them. Safe to hot-run. Written by hand,
  like the other column additions here.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add :provider_account_id, :uuid
      add :model_family, :text
      add :routing_decision, :map
    end

    alter table(:issues) do
      add :implementer_account_id, :uuid
      add :implementer_family, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :implementer_account_id
      remove :implementer_family
    end

    alter table(:worker_runs) do
      remove :provider_account_id
      remove :model_family
      remove :routing_decision
    end
  end
end
