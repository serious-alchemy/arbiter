defmodule Arbiter.Repo.Migrations.AddDispositionSourceToReviewGateRounds do
  @moduledoc """
  Adds `disposition_source` to `review_gate_rounds` (#925): where a `:review`
  round's `dispositions` came from — `"reviewer"` (its own DISPOSITIONS block)
  or `"targeted_check"` (the one-shot ADDRESSED-or-OPEN check run before an
  approval without dispositions is rejected).
  """

  use Ecto.Migration

  def up do
    alter table(:review_gate_rounds) do
      add :disposition_source, :text
    end
  end

  def down do
    alter table(:review_gate_rounds) do
      remove :disposition_source
    end
  end
end
