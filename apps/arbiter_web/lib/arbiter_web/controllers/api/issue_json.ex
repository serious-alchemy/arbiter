defmodule ArbiterWeb.Api.IssueJSON do
  @moduledoc """
  Render functions for Issue resources.

  Atoms are emitted as strings; timestamps as ISO8601.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueSerializer
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
    |> Map.put(:pending_permissions, Map.get(assigns, :pending_permissions, []))
  end

  def show(%{issue: issue}), do: data(issue)

  @doc "A ranked ticket plus where it landed in its priority band."
  def rank(%{issue: issue, band: band}), do: Map.merge(data(issue), band)

  @doc "A ticket a hand-off / hand-back just moved: the record plus its projection."
  def handoff(%{issue: issue, view: view}), do: IssueSerializer.row(data(issue), view)

  @doc """
  Renders a list of issues wrapped under :data. With `:views` (a
  `%{ticket_id => view}` map from `Projection.views/2`) each row also carries
  its lifecycle projection (`column`, `step`, `blocked_by`, ...), and with
  `:holds` a Ready card the scheduler is holding carries its `hold_reason`.
  """
  def index(%{issues: issues} = assigns) do
    views = Map.get(assigns, :views, %{})
    holds = Map.get(assigns, :holds, %{})

    rows =
      Enum.map(issues, fn issue ->
        case Map.fetch(views, issue.id) do
          {:ok, view} -> IssueSerializer.row(data(issue), view, Map.get(holds, issue.id))
          :error -> data(issue)
        end
      end)

    %{data: rows} |> WorkspaceParam.echo(assigns)
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
          |> IssueSerializer.row(view, Map.get(holds, issue.id))
        end)
    }
    |> WorkspaceParam.echo(assigns)
  end

  # bd-6i7yzq: newest first (`IssueSerializer.history/1`).
  defp put_history(map, nil), do: map
  defp put_history(map, history), do: Map.put(map, :history, IssueSerializer.history(history))

  defp put_lifecycle(map, nil), do: map
  defp put_lifecycle(map, view), do: Map.merge(map, Projection.payload(view))

  @doc """
  The one ticket record (`Arbiter.Tasks.IssueSerializer.data/1`) — shared with
  the MCP `ticket_*` tools.
  """
  def data(%Issue{} = issue), do: IssueSerializer.data(issue)

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
