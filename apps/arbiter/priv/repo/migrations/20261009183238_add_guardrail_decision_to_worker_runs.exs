defmodule Arbiter.Repo.Migrations.AddGuardrailDecisionToWorkerRuns do
  @moduledoc """
  Routing eligibility from guardrails (G13, bd-atll60;
  `docs/design/guardrail-profiles.md` §5.2).

  `worker_runs` gains `guardrail_decision`, alongside `routing_decision`: the
  subject a run was spawned as, its tier, a digest of the effective profile, the
  permissions projected (and any withheld, with why) and any optional permission
  that was dropped to dispatch (`permission_fallback`), as JSON.

  Nullable, no backfill: with no subject rule configured (every install today)
  nothing writes it. Safe to hot-run. Written by hand, like the other column
  additions here.
  """

  use Ecto.Migration

  def up do
    alter table(:worker_runs) do
      add :guardrail_decision, :map
    end
  end

  def down do
    alter table(:worker_runs) do
      remove :guardrail_decision
    end
  end
end
