defmodule ArbiterWeb.Api.IssueJSON do
  @moduledoc """
  Render functions for Issue resources.

  Atoms are emitted as strings; timestamps as ISO8601.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle.Projection

  @doc "Renders a single issue."
  def show(%{issue: issue, warnings: warnings}) when warnings != [],
    do: Map.put(data(issue), :warnings, warnings)

  # bd-3j4ch4: the single-issue read carries a cost estimate (or an explicit
  # null — "no estimate yet" has to be distinguishable from "$0").
  # bd-18vl9q: and the epic cost rollup, null for a non-epic issue.
  # bd-1defgu: and the issue's dependency edges — `arb issue show` was
  # write-only for them before.
  # bd-6fkgvo: and the ticket's lifecycle projection (column, step,
  # blocked_by, attention) and its current run, for `arb issue show`.
  def show(
        %{issue: issue, estimate: estimate, epic_rollup: epic_rollup, dependencies: deps} =
          assigns
      ) do
    %{data: rendered_deps} = ArbiterWeb.Api.DependencyJSON.index(%{dependencies: deps})

    issue
    |> data()
    |> Map.put(:estimate, estimate)
    |> Map.put(:epic_rollup, epic_rollup)
    |> Map.put(:dependencies, rendered_deps)
    |> put_lifecycle(Map.get(assigns, :lifecycle))
    |> Map.put(
      :current_run,
      ArbiterWeb.Api.WorkerJSON.current_run(Map.get(assigns, :current_run))
    )
  end

  def show(%{issue: issue}), do: data(issue)

  @doc "Renders a list of issues wrapped under :data."
  def index(%{issues: issues}) do
    %{data: Enum.map(issues, &data/1)}
  end

  @doc """
  `GET /api/issues/lifecycle` (bd-6fkgvo): each open ticket with its
  lifecycle projection, in the order given (dispatch order). A slim row — what
  `arb prime` prints — not the full record.
  """
  def lifecycle(%{tickets: tickets}) do
    %{
      data:
        Enum.map(tickets, fn {issue, view} ->
          %{
            id: issue.id,
            title: issue.title,
            priority: issue.priority,
            difficulty: issue.difficulty,
            issue_type: to_string_atom(issue.issue_type),
            rank: issue.rank,
            workspace_id: issue.workspace_id,
            pr_ref: issue.pr_ref,
            merger_url: issue.merger_url,
            awaiting_verification_at: iso(issue.awaiting_verification_at),
            created_at: iso(issue.created_at),
            updated_at: iso(issue.updated_at)
          }
          |> Map.merge(Projection.payload(view))
        end)
    }
  end

  defp put_lifecycle(map, nil), do: map
  defp put_lifecycle(map, view), do: Map.merge(map, Projection.payload(view))

  def data(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      description: issue.description,
      acceptance: issue.acceptance,
      notes: issue.notes,
      qa_notes: issue.qa_notes,
      deployment_notes: issue.deployment_notes,
      status: to_string_atom(issue.status),
      # bd-842qio: the stored lifecycle state, which the later lifecycle
      # children move every consumer onto. `close_reason` is null unless the
      # ticket is closed; `rank` orders a priority band.
      state: to_string_atom(issue.state),
      close_reason: to_string_atom(issue.close_reason),
      rank: issue.rank,
      priority: issue.priority,
      difficulty: issue.difficulty,
      issue_type: to_string_atom(issue.issue_type),
      auto_close: issue.auto_close,
      verify_after_deploy: issue.verify_after_deploy,
      awaiting_verification_at: iso(issue.awaiting_verification_at),
      verification_outcome: to_string_atom(issue.verification_outcome),
      verification_evidence: issue.verification_evidence,
      # bd-9zuvbh: the ReviewGate park. Present (and null) on every issue so a
      # consumer can tell "not parked" from "this API predates the field".
      review_park_reason: issue.review_park_reason,
      review_parked_at: iso(issue.review_parked_at),
      tracker_type: to_string_atom(issue.tracker_type),
      tracker_ref: issue.tracker_ref,
      pr_ref: issue.pr_ref,
      # bd-741sid: the ticket owns its open PR — its URL, the forge's last
      # answer (as recorded, string-keyed) and when its Watchdog read it — and
      # the cause a closed-unmerged PR sent it back to work with.
      merger_url: issue.merger_url,
      merger_status: issue.merger_status,
      merger_checked_at: iso(issue.merger_checked_at),
      attention_cause: to_string_atom(issue.attention_cause),
      attention_detail: issue.attention_detail,
      attention_since: iso(issue.attention_since),
      # bd-8nlez1: the attention's owner when a hand-off, a hand-back or an
      # expired limit moved it, and the note that came with the move.
      attention_owner: to_string_atom(issue.attention_owner),
      attention_note: issue.attention_note,
      attention_owner_since: iso(issue.attention_owner_since),
      pr_body: issue.pr_body,
      target_branch: issue.target_branch,
      repo: issue.repo,
      workspace_id: issue.workspace_id,
      refined: issue.refined,
      acceptance_waived: issue.acceptance_waived,
      closed_at: iso(issue.closed_at),
      created_at: iso(issue.created_at),
      updated_at: iso(issue.updated_at)
    }
    |> maybe_put(:child_total, issue.child_total)
    |> maybe_put(:child_closed, issue.child_closed)
  end

  # Child-progress rollup is included only when the calcs are loaded (the show
  # endpoint loads them); index keeps them unloaded so the field is omitted.
  defp maybe_put(map, _key, %Ash.NotLoaded{}), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
