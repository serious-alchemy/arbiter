defmodule Arbiter.ReviewGate.RoundsReport do
  @moduledoc """
  One task's `Arbiter.ReviewGate.Round` history as a report (parity audit P-12,
  D-W-21) — the read behind `review_gate_rounds_list` (MCP) and
  `GET /api/review_gate_rounds` (REST, and so `arb review rounds`).

  The rounds are oldest-first, one row per ReviewGate reviewer or implementer
  pass, so a round-1 rejection and a round-2 approval surface as two rows
  rather than being collapsed into the task's terminal outcome. Beside them:

    * `total_count` — how many rounds exist, whatever `limit` trimmed the list to;
    * `outcome` / `resolution` / `resolutions` — the coordinator's recorded
      answer to a gate escalation (bd-4qjl0q), so a run that escalated and was
      amended no longer reads like one that converged;
    * `conflict_review` — how much re-review the conflict-resolution path saved,
      for this ticket and fleet-wide (bd-954ym8).
  """

  require Ash.Query

  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Reviews.ConflictReview

  @max_limit 200

  @doc "The cap on `limit`: the most rounds one call returns."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  The report for `task_id`. `limit` (nil = every round) keeps only the most
  recent N rounds, still oldest-first.
  """
  @spec build(String.t(), pos_integer() | nil) :: map()
  def build(task_id, limit \\ nil) when is_binary(task_id) do
    all_rounds =
      Round
      |> Ash.Query.filter(task_id == ^task_id)
      # bd-6d3h8m: sort on `fix_round_attempt` first — `round` restarts at 1
      # on every automatic fix round's fresh gate, so sorting on `round`
      # alone interleaves a fix round's rounds 1..N with the original pass's.
      |> Ash.Query.sort(fix_round_attempt: :asc, round: :asc, inserted_at: :asc)
      |> Ash.read!()

    rounds = all_rounds |> take_last(limit) |> Enum.map(&serialize_round/1)
    resolutions = Resolutions.list(task_id)
    serialized_resolutions = Enum.map(resolutions, &Resolutions.serialize/1)

    %{
      rounds: rounds,
      count: length(rounds),
      total_count: length(all_rounds),
      conflict_review: %{
        task: ConflictReview.report(task_id),
        fleet: ConflictReview.report()
      },
      outcome: Resolutions.outcome(all_rounds, resolutions),
      resolution: List.last(serialized_resolutions),
      resolutions: serialized_resolutions
    }
  end

  @doc "One round, as every surface renders it."
  @spec serialize_round(Round.t()) :: map()
  def serialize_round(%Round{} = r) do
    %{
      id: r.id,
      task_id: r.task_id,
      run_id: r.run_id,
      round: r.round,
      fix_round_attempt: r.fix_round_attempt,
      role: r.role,
      verdict: r.verdict,
      findings: r.findings,
      finding_count: r.finding_count,
      reviewer_model: r.reviewer_model,
      reviewer_tier: r.reviewer_tier,
      # bd-3hb4ih: which provider ran the pass — the only way to see a reviewer
      # print-timeout rotation without re-reading transcripts.
      reviewer_provider: r.reviewer_provider,
      # bd-a1ke2c: under `review_agent.cross_family`, who reviewed whom, and a
      # same-family fallback with its reason — never silent.
      reviewer_family: r.reviewer_family,
      implementer_family: r.implementer_family,
      same_family_fallback: r.same_family_fallback,
      same_family_fallback_reason: r.same_family_fallback_reason,
      cost_usd: r.cost_usd,
      converged: r.converged,
      inserted_at: iso(r.inserted_at)
    }
  end

  defp take_last(list, nil), do: list
  defp take_last(list, n), do: Enum.take(list, -n)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
