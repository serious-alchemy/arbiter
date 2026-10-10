defmodule Arbiter.Loop.Trust.View do
  @moduledoc """
  The trust records as every surface shows them (G18, guardrail-profiles §6.5):
  `arb trust show`, `GET /api/trust`, the MCP `trust_show` tool and the `/trust`
  dashboard all render these maps, so they cannot disagree.

  `list/0` is one summary per subject; `detail/1` adds the recent events, the
  history and the pending promotion proposal. A suspended subject's
  `effective_tier` is `quarantine`, whatever its rule's `tier` says.
  """

  alias Arbiter.Guardrails.TrustRecord
  alias Arbiter.Loop.PendingWrite
  alias Arbiter.Loop.Trust

  require Ash.Query

  @doc "One summary per subject, subject order."
  @spec list() :: [map()]
  def list do
    pending = pending_by_target()
    Enum.map(Trust.list(), &summary(&1, Map.get(pending, Trust.key(&1), [])))
  end

  @doc "One subject in full, or `{:error, :not_found}`."
  @spec detail(Trust.subject() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def detail(subject) do
    case Trust.get(subject) do
      nil ->
        {:error, :not_found}

      %TrustRecord{} = record ->
        pending = pending_by_target(Trust.key(record))

        {:ok,
         record
         |> summary(Map.get(pending, Trust.key(record), []))
         |> Map.merge(%{
           recent_events: record.recent_events || [],
           history: record.history || [],
           quality: record.quality
         })}
    end
  end

  @doc "The summary of one record, given its live proposals."
  @spec summary(TrustRecord.t(), [PendingWrite.t()]) :: map()
  def summary(%TrustRecord{} = r, pending \\ []) do
    %{
      subject: Trust.key(r),
      provider: r.provider,
      model: r.model,
      family: r.family,
      tier: atom(r.tier),
      effective_tier: if(r.suspended_at, do: "quarantine", else: atom(r.tier)),
      pinned: r.pinned,
      suspended: suspended(r),
      record: %{
        window_days: r.window_days,
        runs: r.runs,
        clean_runs: r.clean_runs,
        clean_tickets: r.clean_tickets,
        clean_repos: r.clean_repos,
        critical_events: r.critical_events,
        major_events: r.major_events,
        minor_events: r.minor_events,
        reviewed: r.reviewed,
        round1_approve_rate: r.round1_approve_rate,
        clock_started_at: r.clock_started_at,
        tier_since: r.tier_since,
        last_run_at: r.last_run_at
      },
      versions: %{harness: r.harness_version, model: r.model_version},
      eligibility: Map.put(r.eligibility || %{}, :eligible_for, atom(r.eligible_for)),
      pending: Enum.map(pending, &proposal/1),
      computed_at: r.computed_at
    }
  end

  defp suspended(%TrustRecord{suspended_at: nil}), do: nil

  defp suspended(%TrustRecord{suspended_at: at, suspension: s}) do
    s = s || %{}

    %{
      at: at,
      kind: s["kind"],
      severity: s["severity"],
      detail: s["detail"],
      event_id: s["id"],
      run_id: s["run_id"],
      task_id: s["task_id"],
      prior_tier: s["prior_tier"],
      parked: s["parked"] || []
    }
  end

  defp proposal(%PendingWrite{} = row) do
    payload = row.payload || %{}

    %{
      id: row.id,
      state: atom(row.state),
      gist: row.gist,
      from: payload["from"],
      to: payload["to"],
      evidence_count: row.evidence_count,
      distinct_tasks: row.distinct_tasks,
      created_at: row.created_at
    }
  end

  # Live (`:proposed` / `:hypothesis`) trust_promotion proposals by target.
  defp pending_by_target(target \\ nil) do
    PendingWrite
    |> Ash.Query.filter(kind == :trust_promotion and state in [:proposed, :hypothesis])
    |> then(fn q -> if target, do: Ash.Query.filter(q, target == ^target), else: q end)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!()
    |> Enum.group_by(& &1.target)
  end

  defp atom(nil), do: nil
  defp atom(value), do: to_string(value)
end
