defmodule Arbiter.Guardrails.Subject do
  @moduledoc """
  One installation-level subject rule (G11, `docs/design/guardrail-profiles.md`
  §3.1, §7.1): assigns `tier` to every (provider, model) the `provider` /
  `family` / `model` keys match, optionally narrowed by `scope`
  (`%{workspace => [repo]}`) and `overrides` (tighten-only cap fields).

  Operator-owned: write through `Arbiter.Guardrails.Subjects`, which applies
  `Arbiter.Guardrails.Authority` (the coordinator may only tighten). `position`
  orders rules; the most specific match wins and ties go to the lower position.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Guardrails.Subjects,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "guardrail_subjects"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:position, :provider, :family, :model, :tier, :scope, :overrides, :pinned, :reason, :updated_by]
      validate present([:provider, :family, :model], at_least: 1)
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:position, :provider, :family, :model, :tier, :scope, :overrides, :pinned, :reason, :updated_by]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :position, :integer, allow_nil?: false, default: 0, public?: true
    attribute :provider, :string, public?: true
    attribute :family, :string, public?: true
    attribute :model, :string, public?: true

    attribute :tier, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:quarantine, :probation, :trusted, :privileged]
    end

    attribute :scope, :map, public?: true
    attribute :overrides, :map, public?: true
    attribute :pinned, :boolean, allow_nil?: false, default: false, public?: true
    attribute :reason, :string, public?: true
    attribute :updated_by, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
