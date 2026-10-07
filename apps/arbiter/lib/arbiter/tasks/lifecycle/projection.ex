defmodule Arbiter.Tasks.Lifecycle.Projection do
  @moduledoc """
  The impure edge of `Arbiter.Tasks.Lifecycle.View` for every surface that is
  not the board (ticket lifecycle 10/13, bd-6fkgvo): `arb prime`,
  `arb ticket show`, MCP `ticket_show` / `ticket_list` / `ticket_ready` and
  `GET /api/issues/lifecycle`.

  `Lifecycle.view/2` is pure; this module does the reads it needs, once per
  call, the way `Arbiter.Board.Snapshot.load/1` does for the board:

    * the gating edges, and the tickets they point at, through
      `Arbiter.Tasks.EdgeGate.blockers/2` — a blocker outside the projected
      set (another workspace, an already-merged ticket) still counts;
    * the live runs (`Arbiter.Worker.list_children/0`);
    * whether each Merging ticket's Watchdog is alive;
    * the clock.

  Each read is best-effort, like the board's: an unreadable input degrades to
  "none", never to a raise. Opts override the reads: `:workers`, `:now`,
  `:blocked_by` (a `%{ticket_id => [blocker_id]}` map).

  `payload/1` is the one JSON shape of a view — string values, attention
  flattened — that the REST API, MCP and the `task_state` event all emit.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.DependencyGraph
  alias Arbiter.Tasks.EdgeGate
  alias Arbiter.Tasks.EffectivePriority
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Lifecycle.View
  alias Arbiter.Worker.Watchdog

  # SQLite refuses a very wide `id in ^ids` (bd memory: past ~1000 ids).
  @id_chunk 500

  @doc "The columns a view can report, in board order."
  @spec columns() :: [View.column()]
  def columns, do: [:backlog, :blocked, :ready, :in_progress, :merging, :verifying, :closed]

  @doc """
  The stored states a ticket in `column` can have. A `:backlog` or `:queued`
  ticket with a live author run reads as `:in_progress` (`View`), so that
  column also takes those two states.
  """
  @spec states_for_column(View.column()) :: [Lifecycle.state()]
  def states_for_column(:backlog), do: [:backlog]
  def states_for_column(:ready), do: [:queued]
  # bd-abg443: an `:active` ticket held by the quota gate reads Blocked.
  def states_for_column(:blocked), do: [:queued, :active]
  def states_for_column(:in_progress), do: [:active, :backlog, :queued]
  def states_for_column(:merging), do: [:merging, :active]
  def states_for_column(:verifying), do: [:verifying]
  def states_for_column(:closed), do: [:closed]

  @doc "Every ticket in `issues`, projected: `%{ticket_id => View.t()}`."
  @spec views([Issue.t() | map()], keyword()) :: %{optional(String.t()) => View.t()}
  def views(issues, opts \\ []) when is_list(issues) do
    workers = Keyword.get_lazy(opts, :workers, &live_workers/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    blocked_by = Keyword.get_lazy(opts, :blocked_by, fn -> blockers(issues) end)

    Map.new(issues, fn issue ->
      {issue.id,
       Lifecycle.view(issue, %{
         runs: workers,
         now: now,
         blocked_by: Map.get(blocked_by, issue.id, []),
         watchdog_alive: watchdog_alive(issue)
       })}
    end)
  end

  @doc "One ticket, projected."
  @spec view(Issue.t() | map(), keyword()) :: View.t()
  def view(issue, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :blocked_by, fn -> own_blockers(issue) end)

    [issue] |> views(opts) |> Map.fetch!(issue.id)
  end

  @doc """
  Every ticket in workspace `workspace_id` that is not closed and not an epic
  (epics stay off the board), with its view, in dispatch order
  (`Arbiter.Tasks.EffectivePriority.order/1`, the §4 key of `Arbiter.Board.Scheduler.order/1`:
  effective priority, …, own priority, rank, age — plain priority, rank, age while no epic has a floor).
  """
  @spec open(String.t() | nil, keyword()) :: [{Issue.t(), View.t()}]
  def open(workspace_id, opts \\ []) when is_binary(workspace_id) or is_nil(workspace_id) do
    excluded = Issue.non_dispatchable_types()

    issues =
      Issue
      |> open_in_workspace(workspace_id)
      |> Ash.Query.filter(state != :closed and issue_type not in ^excluded)
      |> Ash.read!()
      |> EffectivePriority.order()

    views = views(issues, opts)
    Enum.map(issues, &{&1, Map.fetch!(views, &1.id)})
  end

  # `nil` is every workspace (the omitted-workspace read rule).
  defp open_in_workspace(query, nil), do: query
  defp open_in_workspace(query, ws_id), do: Ash.Query.filter(query, workspace_id == ^ws_id)

  @doc """
  A view as JSON: `state`, `column`, `step`, `blocked_by`, `attention`
  (`attention_payload/1`) and `ci_wait` (`ci_wait_payload/1`), atoms as strings.
  """
  @spec payload(View.t()) :: map()
  def payload(%{} = view) do
    %{
      state: str(view.state),
      column: str(view.column),
      step: str(view.step),
      blocked_by: view.blocked_by,
      hold: hold_payload(Map.get(view, :hold)),
      attention: attention_payload(view.attention),
      ci_wait: ci_wait_payload(Map.get(view, :ci_wait))
    }
  end

  @doc "A quota hold (`View.hold/0`) as JSON — `reason` and an ISO-8601 `resumes_at`; nil stays nil."
  @spec hold_payload(map() | nil) :: map() | nil
  def hold_payload(nil), do: nil

  def hold_payload(%{reason: reason} = hold),
    do: %{reason: reason, resumes_at: iso(Map.get(hold, :resumes_at))}

  @doc """
  A ticket's ReviewGate CI wait (bd-cut6uv) as JSON — `sha`, `since` and the
  `label` surfaces render (`waiting on CI <sha>`); nil when the ticket is not
  waiting on CI.
  """
  @spec ci_wait_payload(map() | nil) :: map() | nil
  def ci_wait_payload(nil), do: nil

  def ci_wait_payload(%{sha: sha} = wait) do
    %{
      "sha" => sha,
      "since" => Map.get(wait, :since),
      "label" => Arbiter.Worker.ReviewCi.wait_label(wait)
    }
  end

  @doc "A ticket's attention (`Lifecycle.Attention.t/0`) as JSON; nil stays nil."
  @spec attention_payload(map() | nil) :: map() | nil
  def attention_payload(nil), do: nil

  def attention_payload(%{} = a) do
    %{
      owner: str(a.owner),
      waiting_on: str(a.waiting_on),
      reason: a.reason,
      cause: str(a.cause),
      since: iso(Map.get(a, :since)),
      note: Map.get(a, :note),
      owner_since: iso(Map.get(a, :owner_since))
    }
  end

  # ---- reads ----------------------------------------------------------------

  # Gating blockers only matter for a ticket still waiting to start; skip the
  # edge read entirely when there is none.
  defp blockers(issues) do
    if Enum.any?(issues, &(Lifecycle.state_of(&1) in [:backlog, :queued])) do
      gating = DependencyGraph.gating_types()
      deps = Dependency |> Ash.Query.filter(type in ^gating) |> Ash.read!()
      EdgeGate.blockers(deps, issues ++ endpoints_outside(deps, issues))
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("Lifecycle.Projection: could not read blockers: #{Exception.message(e)}")
      %{}
  end

  defp own_blockers(issue) do
    if Lifecycle.state_of(issue) in [:backlog, :queued],
      do: %{issue.id => EdgeGate.blockers_of(issue)},
      else: %{}
  rescue
    e ->
      Logger.warning("Lifecycle.Projection: could not read blockers: #{Exception.message(e)}")
      %{}
  end

  defp endpoints_outside(deps, issues) do
    known = MapSet.new(issues, & &1.id)

    deps
    |> Enum.flat_map(&[&1.from_issue_id, &1.to_issue_id])
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.chunk_every(@id_chunk)
    |> Enum.flat_map(fn ids -> Issue |> Ash.Query.filter(id in ^ids) |> Ash.read!() end)
  end

  defp live_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Only a Merging ticket's Watchdog is supposed to be running; unknown (nil)
  # elsewhere, and when the registry cannot answer.
  defp watchdog_alive(issue) do
    if Lifecycle.state_of(issue) == :merging, do: Watchdog.alive?(issue.id)
  rescue
    _ -> nil
  end

  defp str(nil), do: nil
  defp str(a) when is_atom(a), do: Atom.to_string(a)
  defp str(s) when is_binary(s), do: s

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil
end
