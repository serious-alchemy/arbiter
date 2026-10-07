defmodule Arbiter.Reviews.Serializer do
  @moduledoc """
  The one serialization of an `Arbiter.Reviews.Record` (parity audit P-12,
  D-W-20). `external_review_list`/`external_review_show` (MCP) and
  `GET /api/external_reviews[/:id]` (REST, and so the CLI) all render through
  here, so the surfaces cannot drift on which fields a record carries — notably
  `mode`, `greenlight_status` and the `proposed_*` counts that say which
  report-only reviews are awaiting a greenlight.
  """

  alias Arbiter.Reviews.{Record, Transcript}

  @doc """
  Serialize a record. Options:

    * `proposed_comments: true` — include the full `proposed_comments` list
      (show only; a list of records carries just the counts).
    * `transcript: true` — include the durable-corpus state (`transcript_exists`,
      `prompt_exists`, ...). Show only: each call stats/reads files, which a
      200-record list must not do.
  """
  @spec record(Record.t(), keyword()) :: map()
  def record(%Record{} = r, opts \\ []) do
    proposed = r.proposed_comments || []

    %{
      id: r.id,
      pr_ref: r.pr_ref,
      pr: r.pr,
      workspace_id: r.workspace_id,
      strategy: r.strategy,
      link: r.link,
      status: r.status,
      mode: r.mode,
      greenlight_status: r.greenlight_status,
      proposed_count: length(proposed),
      # bd-887swr: in/out-of-diff breakdown of the proposed comments, so a
      # coordinator can see how many are postable without fetching the full
      # `proposed_comments` list or diffing the PR by hand. Comments persisted
      # before the "in_diff" label existed count toward neither.
      in_diff_count: Enum.count(proposed, &(&1["in_diff"] == true)),
      out_of_diff_count: Enum.count(proposed, &(&1["in_diff"] == false)),
      verdict: r.verdict,
      finding_count: r.finding_count,
      findings_summary: r.findings_summary,
      model: r.model,
      cost_usd: r.cost_usd,
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      dispatched_by: r.dispatched_by,
      engagement_id: r.engagement_id,
      failure_stage: r.failure_stage,
      failure_reason: r.failure_reason,
      started_at: iso(r.started_at),
      completed_at: iso(r.completed_at),
      inserted_at: iso(r.inserted_at)
    }
    |> maybe_proposed(r, opts)
    |> maybe_transcript(r, opts)
  end

  defp maybe_proposed(map, %Record{} = r, opts) do
    if Keyword.get(opts, :proposed_comments, false),
      do: Map.put(map, :proposed_comments, r.proposed_comments || []),
      else: map
  end

  # bd-7efini: capture state of the review's durable corpus.
  defp maybe_transcript(map, %Record{} = r, opts) do
    if Keyword.get(opts, :transcript, false) do
      summary = Transcript.summary(r.id)

      Map.merge(map, %{
        transcript_exists: summary.exists,
        transcript_path: summary.path,
        transcript_line_count: summary.line_count,
        prompt_exists: summary.prompt_exists,
        tool_use_count: summary.tool_use_count,
        tools_used: summary.tools_used
      })
    else
      map
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
