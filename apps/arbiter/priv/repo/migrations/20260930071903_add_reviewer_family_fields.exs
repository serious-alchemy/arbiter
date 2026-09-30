defmodule Arbiter.Repo.Migrations.AddReviewerFamilyFields do
  @moduledoc """
  Cross-family review (bd-a1ke2c): the ReviewGate reviewer's model family must
  differ from the implementer's, behind `review_agent.cross_family`.

  `review_gate_rounds` gains the audit trail for every `:review` pass:

    * `reviewer_family` — the model family that reviewed
      (`Arbiter.Agents.ModelFamily`);
    * `implementer_family` — the family it had to differ from;
    * `same_family_fallback` — true when no other family was available, and
    * `same_family_fallback_reason` — which families were unavailable and why.

  `issues` gains `reviewer_family`, the reviewer-family pin set at the task's
  first cross-family review pass and reused by every later one.

  All nullable, no backfill: with `review_agent.cross_family` unset (every
  workspace today) nothing writes them. Safe to hot-run. Written by hand,
  like the other column additions here.
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :reviewer_family, :text
      add :implementer_family, :text
      add :same_family_fallback, :boolean
      add :same_family_fallback_reason, :text
    end

    alter table(:issues) do
      add :reviewer_family, :text
    end
  end

  def down do
    alter table(:issues) do
      remove :reviewer_family
    end

    alter table(:review_gate_rounds) do
      remove :reviewer_family
      remove :implementer_family
      remove :same_family_fallback
      remove :same_family_fallback_reason
    end
  end
end
