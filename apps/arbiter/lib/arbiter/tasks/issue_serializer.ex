defmodule Arbiter.Tasks.IssueSerializer do
  @moduledoc """
  The one JSON shape of a ticket, for every surface that renders one (P-13,
  parity audit D-T-14): `GET /api/issues*` and the REST claim/sync routes
  (through `ArbiterWeb.Api.IssueJSON`), the MCP `ticket_*` tools, and the
  tracker bridge's results. Atoms are emitted as strings; timestamps as
  ISO8601.

    * `data/1` — the full record.
    * `summary/1` — the ten-field slim row an MCP caller can ask for with
      `summary: true` (and that the list/ready rows are built on).
    * `row/3` — a record or summary plus the ticket's lifecycle projection
      (`Arbiter.Tasks.Lifecycle.Projection.payload/1`) and, for a Ready card
      the scheduler is holding, its `hold_reason`.
    * `history/1` — the audit trail (`Arbiter.Tasks.History.recent/2`) as JSON.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle.Projection

  @doc "The full record."
  @spec data(Issue.t()) :: map()
  def data(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      description: issue.description,
      acceptance: issue.acceptance,
      notes: issue.notes,
      qa_notes: issue.qa_notes,
      deployment_notes: issue.deployment_notes,
      # bd-842qio: the stored lifecycle state — the ticket's one lifecycle
      # field. `close_reason` is null unless the ticket is closed; `rank`
      # orders a priority band.
      state: str(issue.state),
      close_reason: str(issue.close_reason),
      rank: issue.rank,
      priority: issue.priority,
      # ES2: the epic priority floor (nil: none). Distinct from `priority`.
      floor_priority: issue.floor_priority,
      difficulty: issue.difficulty,
      issue_type: str(issue.issue_type),
      auto_close: issue.auto_close,
      verify_after_deploy: issue.verify_after_deploy,
      # bd-13pqcp: `%{"require" => [..]}` / `%{"exclude" => [..]}`, or null.
      provider_constraint: issue.provider_constraint,
      awaiting_verification_at: iso(issue.awaiting_verification_at),
      verification_outcome: str(issue.verification_outcome),
      verification_evidence: issue.verification_evidence,
      tracker_type: str(issue.tracker_type),
      tracker_ref: issue.tracker_ref,
      tracker_context_type: str(issue.tracker_context_type),
      tracker_context_ref: issue.tracker_context_ref,
      pr_ref: issue.pr_ref,
      # bd-741sid: the ticket owns its open PR — its URL, the forge's last
      # answer (as recorded, string-keyed) and when its Watchdog read it — and
      # the cause a closed-unmerged PR sent it back to work with. A ReviewGate
      # park is an attention cause too (`attention_since` is when it parked).
      merger_url: issue.merger_url,
      merger_status: issue.merger_status,
      merger_checked_at: iso(issue.merger_checked_at),
      attention_cause: str(issue.attention_cause),
      attention_detail: issue.attention_detail,
      attention_since: iso(issue.attention_since),
      # bd-8nlez1: the attention's owner when a hand-off, a hand-back or an
      # expired limit moved it, and the note that came with the move.
      attention_owner: str(issue.attention_owner),
      attention_note: issue.attention_note,
      attention_owner_since: iso(issue.attention_owner_since),
      attention_resume_attempts: issue.attention_resume_attempts,
      pr_body: issue.pr_body,
      target_branch: issue.target_branch,
      repo: issue.repo,
      workspace_id: issue.workspace_id,
      acceptance_waived: issue.acceptance_waived,
      closed_at: iso(issue.closed_at),
      created_at: iso(issue.created_at),
      updated_at: iso(issue.updated_at)
    }
    |> maybe_put(:child_total, issue.child_total)
    |> maybe_put(:child_closed, issue.child_closed)
  end

  @doc "The slim row: id, title, state, close_reason, priority, difficulty, type, workspace, rank."
  @spec summary(Issue.t()) :: map()
  def summary(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      state: str(i.state),
      close_reason: str(i.close_reason),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: str(i.issue_type),
      workspace_id: i.workspace_id,
      acceptance_waived: i.acceptance_waived,
      rank: i.rank
    }
  end

  @doc """
  `base` (a `data/1` or `summary/1` map) with the ticket's projection merged
  over it, and `hold_reason` when `hold_reason` is a string — why the scheduler
  is not dispatching a Ready card (bd-dtdeff).
  """
  @spec row(map(), map(), String.t() | nil) :: map()
  def row(base, view, hold_reason \\ nil) do
    base
    |> Map.merge(Projection.payload(view))
    |> put_hold_reason(hold_reason)
  end

  @doc """
  The audit history, newest first. `actor` is the `Arbiter.Actor` label of whoever
  made the write, or null when none is on record; `changed` names the fields;
  `state` is the new lifecycle state when the write moved it (bd-6i7yzq).
  """
  @spec history([map()]) :: [map()]
  def history(entries) do
    Enum.map(entries, fn entry ->
      %{
        at: DateTime.to_iso8601(entry.at),
        action: entry.action,
        actor: entry.actor,
        changed: entry.changes |> Map.keys() |> Enum.sort(),
        state: entry.changes["state"]
      }
    end)
  end

  defp put_hold_reason(map, reason) when is_binary(reason), do: Map.put(map, :hold_reason, reason)
  defp put_hold_reason(map, _), do: map

  # Child-progress rollup is included only when the calcs are loaded (the show
  # endpoint loads them); a list keeps them unloaded so the field is omitted.
  defp maybe_put(map, _key, %Ash.NotLoaded{}), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp str(nil), do: nil
  defp str(a) when is_atom(a), do: Atom.to_string(a)
  defp str(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
