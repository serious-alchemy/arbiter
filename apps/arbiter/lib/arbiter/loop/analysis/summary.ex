defmodule Arbiter.Loop.Analysis.Summary do
  @moduledoc """
  The wire shape of a loop-analysis pass (P-23): the compact structured
  `summary` alongside the markdown, and the `envelope/1` both
  `POST /api/loop/analyze|propose` and `loop_analyze` / `loop_propose` return.

  Lifted out of the REST controller so the MCP tools serialise the report
  exactly as REST does instead of drifting from it. Proposal rows are rendered
  by the adapter (`render`), since each surface already owns its row shape.
  """

  # A compact structured summary alongside the markdown, for programmatic callers.
  @doc "The structured summary of `report`."
  @spec summary(Arbiter.Loop.Report.t()) :: map()
  def summary(report) do
    %{
      window: report.window[:label],
      totals: report.totals,
      misclassification_rate: report.misclassification[:rate],
      finding_categories: length(report.finding_categories),
      finding_residue: finding_residue_summary(report.finding_residue),
      difficulty_misestimates: length(report.difficulty_misestimates),
      fleet_wide_suggestions: Enum.count(report.suggestions, &(&1.verdict == :fleet_wide)),
      ci: ci_summary(report.ci)
    }
    |> maybe_put_discovery(report.discovery)
  end

  # bd-4f6opo: present only under `discover=true`, so the default summary is
  # byte-identical to before. Carries the verified candidates and every
  # rejection with its reason — nothing the pre-check dropped goes unreported.
  defp maybe_put_discovery(summary, nil), do: summary

  defp maybe_put_discovery(summary, d) do
    Map.put(summary, :discovery, %{
      status: d.status,
      error: d.error,
      slice: d.slice,
      history: d.history,
      candidates: d.candidates,
      rejected: d.rejected,
      cost: d.cost
    })
  end

  # bd-cuu8n3: the CI section, structured. Per-run rows carry their class,
  # basis and reason (not the briefed check logs — those can run to kilobytes
  # per run); `meta` states the approved-PR-only undercount so a JSON caller
  # reads the same caveat the markdown prints.
  defp ci_summary(ci) do
    %{
      red_rate: ci.red_rate,
      by_repo: ci.by_repo,
      by_model: ci.by_model,
      by_difficulty: ci.by_difficulty,
      outcomes: ci.outcomes,
      outcomes_by_repo: ci.outcomes_by_repo,
      runs: Enum.map(ci.runs, &Map.take(&1, [:run_id, :task_id, :repo, :class, :basis, :reason])),
      lint_flags: Enum.map(ci.lint_flags, &Map.drop(&1, [:run_ids])),
      recurring_flakes: Enum.map(ci.recurring_flakes, &Map.drop(&1, [:run_ids])),
      meta: %{
        undercount: ci.undercount,
        classes: Arbiter.Loop.FixPassClassifier.classes(),
        lint_share_threshold: ci.lint_share_threshold,
        min_fix_passes: ci.min_fix_passes,
        flake_recurrence_threshold: ci.flake_recurrence_threshold,
        red_rate_definition:
          "share of tasks with a main run in the window and a PR that needed >= 1 CI fix_pass " <>
            "started in the window; attributed to the task's latest main run in the window"
      }
    }
  end

  # bd-5ja2vb: the count/rate/distinct-task shape, without the retained
  # `units` sample (potentially hundreds of finding-text strings) — that
  # belongs to the in-process `Report` a future backfill pass reads, not the
  # compact summary a CLI/dashboard renders.
  defp finding_residue_summary(fr) do
    %{
      total_units: Map.get(fr, :total_units, 0),
      count: Map.get(fr, :count, 0),
      rate: Map.get(fr, :rate),
      distinct_tasks: Map.get(fr, :distinct_tasks, 0)
    }
  end

  @doc """
  The response body for an `Analysis.analyze/1` result. `render` renders one
  queued `PendingWrite`. `:proposals` / `:proposals_dropped` (bd-3dasqm) are
  only present when the caller opted in, so a read-only body is byte-identical
  to what it was before Stage 2.
  """
  @spec envelope(map(), (struct() -> map())) :: map()
  def envelope(%{markdown: markdown, report: report, usage_event_id: uid} = result, render) do
    body = %{markdown: markdown, usage_event_id: uid, summary: summary(report)}

    case result do
      %{proposals: rows} ->
        dropped = Map.get(result, :proposals_dropped, [])

        body
        |> Map.put(:proposals, Enum.map(rows, render))
        |> Map.put(
          :proposals_dropped,
          Enum.map(dropped, &%{gist: &1.gist, reason: inspect(&1.reason)})
        )

      _ ->
        body
    end
  end
end
