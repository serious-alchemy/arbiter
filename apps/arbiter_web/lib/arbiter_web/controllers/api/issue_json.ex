defmodule ArbiterWeb.Api.IssueJSON do
  @moduledoc """
  Render functions for Issue resources.

  Atoms are emitted as strings; timestamps as ISO8601.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle.Projection
  alias ArbiterWeb.Api.WorkspaceParam

  @doc "Renders a single issue."
  def show(%{issue: issue, warnings: warnings}) when warnings != [],
    do: Map.put(data(issue), :warnings, warnings)

  # bd-3j4ch4: the single-issue read carries a cost estimate (or an explicit
  # null — "no estimate yet" has to be distinguishable from "$0").
  # bd-18vl9q: and the epic cost rollup, null for a non-epic issue.
  # bd-1defgu: and the issue's dependency edges — `arb ticket show` was
  # write-only for them before.
  # bd-6fkgvo: and the ticket's lifecycle projection (column, step,
  # blocked_by, attention) and its current run, for `arb ticket show`.
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
    # ES4: `priority` is the own priority; these say what the ticket is
    # scheduled as (`Arbiter.Tasks.EffectivePriority.fields/1`).
    |> Map.merge(Map.get(assigns, :priority_fields, %{}))
    |> Map.put(
      :current_run,
      ArbiterWeb.Api.WorkerJSON.current_run(Map.get(assigns, :current_run))
    )
    |> put_history(Map.get(assigns, :history))
  end

  def show(%{issue: issue}), do: data(issue)

  @doc "Renders a list of issues wrapped under :data."
  def index(%{issues: issues} = assigns) do
    %{data: Enum.map(issues, &data/1)} |> WorkspaceParam.echo(assigns)
  end

  @doc """
  `GET /api/issues/lifecycle` (bd-6fkgvo): each open ticket with its
  lifecycle projection, in the order given (dispatch order). A slim row — what
  `arb prime` prints — not the full record.
  """
  def lifecycle(%{tickets: tickets} = assigns) do
    holds = Map.get(assigns, :holds, %{})

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
          |> put_hold_reason(Map.get(holds, issue.id))
        end)
    }
    |> WorkspaceParam.echo(assigns)
  end

  # bd-6i7yzq: newest first. `actor` is the `Arbiter.Actor` label of whoever made
  # the write, or null when none is on record (written before actors existed, or
  # with no actor in scope). `changed` names the fields; `state` is the new
  # lifecycle state when the write moved it.
  defp put_history(map, nil), do: map

  defp put_history(map, history) do
    Map.put(
      map,
      :history,
      Enum.map(history, fn entry ->
        %{
          at: DateTime.to_iso8601(entry.at),
          action: entry.action,
          actor: entry.actor,
          changed: entry.changes |> Map.keys() |> Enum.sort(),
          state: entry.changes["state"]
        }
      end)
    )
  end

  # bd-dtdeff: why a Ready card is not being dispatched; absent when it is not held.
  defp put_hold_reason(map, nil), do: map
  defp put_hold_reason(map, reason), do: Map.put(map, :hold_reason, reason)

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
      # bd-842qio: the stored lifecycle state — the ticket's one lifecycle
      # field. `close_reason` is null unless the ticket is closed; `rank`
      # orders a priority band.
      state: to_string_atom(issue.state),
      close_reason: to_string_atom(issue.close_reason),
      rank: issue.rank,
      priority: issue.priority,
      # ES2: the epic priority floor (nil: none). Distinct from `priority`.
      floor_priority: issue.floor_priority,
      difficulty: issue.difficulty,
      issue_type: to_string_atom(issue.issue_type),
      auto_close: issue.auto_close,
      verify_after_deploy: issue.verify_after_deploy,
      # bd-13pqcp: `%{"require" => [..]}` / `%{"exclude" => [..]}`, or null.
      provider_constraint: issue.provider_constraint,
      awaiting_verification_at: iso(issue.awaiting_verification_at),
      verification_outcome: to_string_atom(issue.verification_outcome),
      verification_evidence: issue.verification_evidence,
      tracker_type: to_string_atom(issue.tracker_type),
      tracker_ref: issue.tracker_ref,
      pr_ref: issue.pr_ref,
      # bd-741sid: the ticket owns its open PR — its URL, the forge's last
      # answer (as recorded, string-keyed) and when its Watchdog read it — and
      # the cause a closed-unmerged PR sent it back to work with. A ReviewGate
      # park is an attention cause too (`attention_since` is when it parked).
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
