defmodule Arbiter.Board.AdmissionShadowEvent do
  @moduledoc """
  One admission hold change under `scheduler_admission: shadow` or `enforce`
  (DC6, `docs/design/provider-dynamic-concurrency.md` §10.2), written by
  `Arbiter.Board.AdmissionShadow` when either side's outcome changes — never
  per tick.

    * `legacy_pick` / `walk_pick` — the card today's plan and the scheduler
      walk would dispatch next (`nil` when that side holds); `agrees` when they
      are the same, `comparable` when both had one.
    * `cause` — why they differ: the walk's wait cause for today's pick
      (`capacity:provider`, `capacity:node`, `capacity:repo`, `queued`,
      `own_hold`, `paused`), or `legacy_hold` when today holds the card the
      walk places.
    * `legacy` / `walk` — each side's decision: the pick or the head it holds,
      with its hold or wait cause and reason; the walk's pair and placements.
    * `budgets` — every pool the walk planned against: budget, live seats,
      free seats, today's cap, binding and reason.

  Append-only: only `:record` and `:read` (and `:destroy`, for a report's
  retention) exist.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "admission_shadow_events"
    repo Arbiter.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      primary? true

      accept [
        :at,
        :policy,
        :legacy_pick,
        :walk_pick,
        :agrees,
        :comparable,
        :cause,
        :legacy,
        :walk,
        :budgets
      ]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :policy, :string, allow_nil?: false, public?: true
    attribute :legacy_pick, :string, public?: true
    attribute :walk_pick, :string, public?: true
    attribute :agrees, :boolean, allow_nil?: false, public?: true
    attribute :comparable, :boolean, allow_nil?: false, public?: true
    attribute :cause, :string, public?: true
    attribute :legacy, :map, allow_nil?: false, public?: true
    attribute :walk, :map, allow_nil?: false, public?: true
    attribute :budgets, {:array, :map}, allow_nil?: false, default: [], public?: true
    create_timestamp :inserted_at
  end
end
