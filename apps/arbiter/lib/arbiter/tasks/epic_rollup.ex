defmodule Arbiter.Tasks.EpicRollup do
  @moduledoc """
  Per-status child aggregation for an epic, plus the `needs_you` signal the
  `/epics` page uses to decide which rows deserve the operator's attention
  (bd-58z2tu, superseding the three-signal "stuck" rule from bd-2wmxt5).

  Neither `child_open` nor a per-status count exists on `Issue` — the resource
  only carries the `child_total` / `child_closed` calculations — so this module
  derives the breakdown from the children themselves.

  ## Buckets

  The five buckets are the board's own columns, read from the same place
  (bd-6zapbl): `Arbiter.Tasks.Lifecycle.board_column/2`, the child's
  `Lifecycle.view/2` column through the interim five-column mapping, given
  its live author workers and the clock. So a workerless in-progress child
  past the dispatch grace is `:waiting` here exactly as it is on the board,
  and `Arbiter.Board.Snapshot.classify_columns/3` (the epic detail page's
  mini-board) gives the same answer for every child.

      :backlog   backlog
      :ready     queued — blocked or ready
      :running   in progress, with a live author run (or still dispatching)
      :waiting   merging, verifying, or in progress with its run parked/gone
      :closed    closed

  ## `needs_you`

  Operator feedback (2026-09-17): flagging a row for *any* blocked child made
  every chained epic read as stuck, since a healthy dependency chain always
  has an open blocker somewhere. `needs_you` instead means "this epic can't
  move forward without me" — true exactly when at least one child satisfies
  one of:

    1. Parked in `:awaiting_verification` — nothing but a human observation
       clears that state.
    2. Its own live worker needs the operator, per
       `Arbiter.Board.Snapshot.child_needs_you?/2` — the same predicate the
       board's Waiting column votes with, not a second definition. Covers a
       run `:waiting` on a question, a failed run, an MR blocked for a reason
       outside the Watchdog's auto-resolvable set, and an `:in_progress`
       child with no live worker that has sat past `Snapshot.orphaned?/3`'s
       dispatch grace window (nothing will retry it on its own). A child
       still inside that window, or of a non-dispatchable type (`:epic`),
       does not flag — `orphaned?/3` is reused rather than re-derived so the
       two surfaces can't drift apart.
    3. It is blocked by an unsatisfied gating blocker that itself needs the
       operator: the blocker needs-you per rule 2, or is unrefined
       (`:backlog` — it will never be dispatched until promoted). Checked one
       level deep, not as a graph traversal, and the blocker may live outside
       the epic.

  A blocker that is Ready, running, or mid-review/CI is the machine's turn —
  it does not flag rule 3. Nor does a `:verifying` blocker: verifying
  unblocks dependents (`Arbiter.Tasks.Lifecycle.blocker_satisfied?/1`), so it
  is not blocking anything. The verifying ticket itself still flags rule 1
  when it is a child of the epic. A paused Autopilot is a deliberate operator act,
  not a rule here either.

  `blocked_children` and `idle_with_ready_work` stay on the rollup as
  informational counts — the page still shows them as neutral chips — they
  just no longer drive the attention style on their own.

  ## Queries

  Children come from `Arbiter.Tasks.Dependencies.for_issue/1` — the same facade
  the detail page reads — one call per epic, rather than a second hand-rolled
  `:parent_of` query. The gating edges and the blockers' own status/refined
  are then read in bulk queries across *all* the epics' children, so the
  signal costs a constant number of reads regardless of how many epics are
  listed. Live workers come from `Arbiter.Worker.list_children/0` (or the
  `:workers` option, for tests), scoped down to the children and blockers
  actually touched.
  """

  require Ash.Query

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.DependencyGraph
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle

  @empty_counts %{backlog: 0, ready: 0, running: 0, waiting: 0, closed: 0}

  @type t :: %{
          epic_id: String.t(),
          counts: %{
            backlog: non_neg_integer(),
            ready: non_neg_integer(),
            running: non_neg_integer(),
            waiting: non_neg_integer(),
            closed: non_neg_integer()
          },
          total: non_neg_integer(),
          closed: non_neg_integer(),
          percent_complete: non_neg_integer(),
          blocked_children: non_neg_integer(),
          awaiting_verification: non_neg_integer(),
          idle_with_ready_work: boolean(),
          needs_you: boolean(),
          needs_you_reasons: [String.t()],
          last_child_activity_at: DateTime.t() | nil
        }

  @doc """
  Roll up every epic in `epics`, keyed by epic id.

  Accepts `%Issue{}` structs or bare ids. Every epic passed in gets a rollup,
  including childless ones (all-zero counts, `needs_you: false`).

  `opts`:

    * `:workers` — live worker rows to classify children/blockers against,
      overriding `Arbiter.Worker.list_children/0`. Tests supply plain maps
      here the same way `Arbiter.Board.Snapshot.derive/1`'s tests do.
    * `:watchdog_live` — overrides the set of Merging tickets whose Watchdog
      is alive, which `Arbiter.Board.Snapshot.watchdog_live/1` would otherwise
      compute from the children and their blockers (a real Registry read).
  """
  @spec for_epics([Issue.t() | String.t()], keyword()) :: %{String.t() => t()}
  def for_epics(epics, opts \\ []) do
    epic_ids = Enum.map(epics, &epic_id/1)

    children_by_epic = Map.new(epic_ids, &{&1, children_of(&1)})

    all_children =
      children_by_epic |> Map.values() |> List.flatten() |> Map.new(&{&1.id, &1}) |> Map.values()

    ctx = build_context(all_children, opts)

    Map.new(children_by_epic, fn {epic_id, children} ->
      {epic_id, rollup(epic_id, children, ctx)}
    end)
  end

  @doc """
  The rollup for a single epic. Convenience over `for_epics/2`.
  """
  @spec for_epic(Issue.t() | String.t(), keyword()) :: t()
  def for_epic(epic, opts \\ []) do
    id = epic_id(epic)
    Map.fetch!(for_epics([epic], opts), id)
  end

  @doc """
  Per-child classification for one epic: bucket (see moduledoc) plus whether
  the child is held by an unsatisfied gating blocker. The shared basis for
  `for_epics/2`'s counts and `Arbiter.Usage.Estimate.epic_cost_rollup/2`'s
  dispatchable/excluded split (design bd-9jj5lf §4) — one membership +
  blocking read, not two independently-derived ones.

  `opts` takes `:workers` and `:now`, as `for_epics/2` does.
  """
  @spec children_with_status(Issue.t() | String.t(), keyword()) :: [
          %{issue: Issue.t(), bucket: atom(), blocked?: boolean()}
        ]
  def children_with_status(epic, opts \\ []) do
    children = children_of(epic_id(epic))
    blocked = blocked_ids(children)

    ctx = %{
      workers_by_task:
        opts |> live_workers(Enum.map(children, & &1.id)) |> Enum.group_by(& &1.task_id),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    }

    Enum.map(children, fn child ->
      %{issue: child, bucket: bucket(child, ctx), blocked?: MapSet.member?(blocked, child.id)}
    end)
  end

  defp epic_id(%{id: id}), do: id
  defp epic_id(id) when is_binary(id), do: id

  defp children_of(epic_id) do
    epic_id
    |> Dependencies.for_issue()
    |> Map.get(:children, [])
    |> Enum.map(& &1.issue)
    |> Enum.reject(&is_nil/1)
  end

  defp rollup(epic_id, children, ctx) do
    counts =
      Enum.reduce(children, @empty_counts, fn child, acc ->
        Map.update!(acc, bucket(child, ctx), &(&1 + 1))
      end)

    total = length(children)
    blocked_children = Enum.count(children, &MapSet.member?(ctx.blocked, &1.id))
    idle? = counts.running == 0 and counts.ready > 0

    {needs_you, reasons} = needs_you_signal(children, ctx)

    %{
      epic_id: epic_id,
      counts: counts,
      total: total,
      closed: counts.closed,
      percent_complete: percent(counts.closed, total),
      blocked_children: blocked_children,
      awaiting_verification: counts.waiting,
      idle_with_ready_work: idle?,
      needs_you: needs_you,
      needs_you_reasons: reasons,
      last_child_activity_at: last_activity(children)
    }
  end

  # The board's column for this child (bd-6zapbl). Blockers only split Blocked
  # from Ready, which share a bucket, so none are passed.
  defp bucket(child, ctx) do
    runs = Map.get(ctx.workers_by_task, child.id, [])
    Lifecycle.board_column(child, %{runs: runs, now: ctx.now}) || :backlog
  end

  defp percent(_closed, 0), do: 0
  defp percent(closed, total), do: round(closed * 100 / total)

  defp last_activity([]), do: nil

  defp last_activity(children) do
    children
    |> Enum.map(&Map.get(&1, :updated_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # ---- needs_you (bd-58z2tu) -------------------------------------------------

  # One read of the world shared by every epic in the batch: the open gating
  # blockers (and their own status/refined, for rule 3), plus the live
  # workers touching any child or blocker (for rule 2).
  defp build_context(children, opts) do
    child_ids = Enum.map(children, & &1.id)
    open_children = open_ids(children)

    pairs = gating_pairs(MapSet.to_list(open_children), open_children)
    blocker_ids = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    blockers_by_id = blocker_issues(blocker_ids)

    # The same predicate `EdgeGate.blockers/2` gates on: a `:verifying` or
    # `:closed` blocker holds nothing back, and an unknown one still does.
    open_pairs =
      Enum.reject(pairs, fn {_blocked, blocker_id} ->
        Lifecycle.blocker_satisfied?(Map.get(blockers_by_id, blocker_id))
      end)

    blocked = open_pairs |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    blocked_by = Enum.group_by(open_pairs, &elem(&1, 0), &elem(&1, 1))

    watched_ids = Enum.uniq(child_ids ++ blocker_ids)
    workers = live_workers(opts, watched_ids)

    watchdog_live =
      Keyword.get_lazy(opts, :watchdog_live, fn ->
        Snapshot.watchdog_live(children ++ Map.values(blockers_by_id))
      end)

    workers_by_task = Enum.group_by(workers, & &1.task_id)
    worked = for {id, ws} <- workers_by_task, ws != [], into: MapSet.new(), do: id
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    %{
      blocked: blocked,
      blocked_by: blocked_by,
      blockers_by_id: blockers_by_id,
      workers_by_task: workers_by_task,
      watchdog_live: watchdog_live,
      worked: worked,
      now: now
    }
  end

  defp needs_you_signal(children, ctx) do
    Enum.reduce(children, {false, []}, fn child, {flag, reasons} ->
      cond do
        Lifecycle.state_of(child) == :verifying ->
          {true, reasons ++ ["verify #{child.id}"]}

        needs_you_directly?(child, ctx) ->
          {true, reasons ++ ["#{child.id} parked"]}

        cause = blocked_cause(child, ctx) ->
          {true, reasons ++ [cause]}

        true ->
          {flag, reasons}
      end
    end)
  end

  # Rule 2: does this issue's own live worker (or lack of one) need the
  # operator, per the board's `Snapshot.child_needs_you?/2`. A `:verifying`
  # issue is handled by the caller (rule 1) before this is ever reached for a
  # child; a blocker checked under rule 3 never is one, since verifying
  # satisfies its dependents.
  #
  # A workerless in-progress issue flags exactly when the board gives it the
  # orphan card: `Lifecycle.board_column/2` says `:waiting` with no run at
  # all. Dispatch moves a ticket to `:active` before its worker registers, so
  # a fresh dispatch (inside the grace window) is still `:running` there and
  # does not read as "parked", and a non-dispatchable child (an :epic) never
  # gets a worker, so it never flags on that basis. A merging one has no
  # worker by design (bd-741sid), so its row and its Watchdog decide, as on
  # the board's merge card.
  defp needs_you_directly?(issue, ctx) do
    case Lifecycle.state_of(issue) do
      :verifying ->
        true

      :merging ->
        Snapshot.merging_needs_you?(
          issue,
          Map.get(ctx.workers_by_task, issue.id, []),
          ctx.watchdog_live
        )

      :active ->
        case Map.get(ctx.workers_by_task, issue.id, []) do
          [] -> Lifecycle.board_column(issue, %{runs: [], now: ctx.now}) == :waiting
          workers -> Snapshot.child_needs_you?(workers, ctx.watchdog_live)
        end

      _ ->
        false
    end
  end

  # Rule 3: the first unsatisfied gating blocker (in or out of the epic) that itself
  # needs the operator, formatted as the chip's reason. One level deep — a
  # blocker's own blockers are not walked.
  defp blocked_cause(child, ctx) do
    ctx.blocked_by
    |> Map.get(child.id, [])
    |> Enum.find_value(fn blocker_id ->
      case Map.get(ctx.blockers_by_id, blocker_id) do
        nil -> nil
        blocker -> blocker_cause(blocker, ctx)
      end
    end)
  end

  defp blocker_cause(blocker, ctx) do
    cond do
      Lifecycle.state_of(blocker) == :backlog ->
        "blocked by unrefined #{blocker.id}"

      needs_you_directly?(blocker, ctx) ->
        "blocked by #{blocker.id} (parked)"

      true ->
        nil
    end
  end

  defp blocker_issues([]), do: %{}

  defp blocker_issues(ids) do
    Issue
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([
      :id,
      :state,
      :status,
      :refined,
      :issue_type,
      :merger_status,
      :updated_at,
      :created_at
    ])
    |> Ash.read!()
    |> Map.new(&{&1.id, &1})
  end

  defp live_workers(opts, watched_ids) do
    ids = MapSet.new(watched_ids)

    opts
    |> Keyword.get_lazy(:workers, &default_workers/0)
    |> Enum.filter(&(author_worker?(&1) and MapSet.member?(ids, Map.get(&1, :task_id))))
  end

  # Only author workers count, matching `Snapshot.classify_columns/3`: a
  # reviewer/implementer gate pass rides on the author's card and is not a
  # second vote on whether the task itself needs the operator.
  defp author_worker?(worker), do: Lifecycle.View.author?(worker)

  defp default_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Ids of children held by at least one unsatisfied gating edge. Standalone from
  # `build_context/2` above — `children_with_status/1` is a single-epic call
  # with no reason to also fetch blocker status/refined or live workers.
  defp blocked_ids([]), do: MapSet.new()

  defp blocked_ids(children) do
    open_children = open_ids(children)

    if MapSet.size(open_children) == 0 do
      MapSet.new()
    else
      ids = MapSet.to_list(open_children)
      pairs = gating_pairs(ids, open_children)
      satisfied = satisfied_ids(Enum.map(pairs, &elem(&1, 1)))

      for {blocked, blocker} <- pairs,
          not MapSet.member?(satisfied, blocker),
          into: MapSet.new(),
          do: blocked
    end
  end

  defp open_ids(children) do
    for child <- children, Lifecycle.state_of(child) != :closed, into: MapSet.new(), do: child.id
  end

  # `{blocked_id, blocker_id}` for every gating row with a child on the blocked
  # end — the same orientation `Arbiter.Board.Snapshot.blockers_from/2` uses.
  defp gating_pairs(ids, open_children) do
    gating = DependencyGraph.gating_types()

    Dependency
    |> Ash.Query.filter(type in ^gating and (from_issue_id in ^ids or to_issue_id in ^ids))
    |> Ash.read!()
    |> Enum.flat_map(fn
      %{type: :depends_on} = dep -> [{dep.from_issue_id, dep.to_issue_id}]
      %{type: :blocks} = dep -> [{dep.to_issue_id, dep.from_issue_id}]
      _ -> []
    end)
    |> Enum.filter(fn {blocked, _blocker} -> MapSet.member?(open_children, blocked) end)
  end

  # Blockers that no longer hold their dependents back: `:verifying` or
  # `:closed` (`Lifecycle.blocker_satisfied?/1`).
  defp satisfied_ids([]), do: MapSet.new()

  defp satisfied_ids(ids) do
    ids = Enum.uniq(ids)

    Issue
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :state, :status])
    |> Ash.read!()
    |> Enum.filter(&Lifecycle.blocker_satisfied?/1)
    |> MapSet.new(& &1.id)
  end
end
