defmodule Arbiter.Tasks.Lifecycle.View do
  @moduledoc """
  The one projection of a ticket (bd-9yqspm, child 2: bd-6zapbl): its column,
  its computed step, what blocks it and — once child 6 fills it — whether it
  needs attention. Every surface that asks "where is this ticket?" reads the
  answer from here: the board (`Arbiter.Board.Snapshot.derive/1`), the epic
  mini-board (`Snapshot.classify_columns/2`), the `/epics` rollup
  (`Arbiter.Tasks.EpicRollup`) and `Arbiter.Tasks.Issue.ready/1`.

  It is pure. Everything that would need a read — the ticket's blockers, its
  runs, its PR's last poll, the clock — arrives in `ctx`:

    * `:blocked_by` — ids of the ticket's **unsatisfied** gating blockers,
      as `Arbiter.Tasks.EdgeGate.blockers/2` computes them (with
      `blocker_satisfied?/1`);
    * `:runs` — the worker rows touching the ticket: its author, any
      subordinate fix / conflict pass under the same id, and any reviewer /
      implementer round pointing back at it;
    * `:merger_status` — the PR's last `Arbiter.Mergers.get/1` result,
      defaulting to the one the ticket's Watchdog recorded on its row;
    * `:now` — for the interim board's dispatch grace (`board_column/2`).

  ## Column

  | state | column |
  |---|---|
  | `:backlog` | `:backlog` |
  | `:queued` | `:blocked` when `:blocked_by` is non-empty, else `:ready` |
  | `:active` | `:in_progress` |
  | `:merging` | `:merging` |
  | `:verifying` | `:verifying` |
  | `:closed` | `:closed` |

  A gating blocker is satisfied once it is `:verifying` or `:closed`:
  **verifying unblocks dependents** (`blocker_satisfied?/1`).

  The column comes from the stored state, never from a run: a `:queued`
  ticket with a leftover `:completed` or `:failed` author row is still Ready
  or Blocked. The one exception is a *live* author run on a `:backlog` or
  `:queued` ticket. Dispatch moves the ticket to `:active` before its run
  starts, so that pair means the write lags a run that is already working
  (a run started around the dispatch path, or a write that failed), and the
  ticket reads as `:in_progress`. A row with no stored or legacy state at all
  (a run whose ticket was not read) is claimed by any non-completed author row.

  ## Step

  Computed for `:in_progress` and `:merging` only, `nil` elsewhere.

    * in progress: `:implementing | :in_review | :addressing_review |
      :fixing_ci | :resolving_conflict`, from the runs through
      `Arbiter.Worker.Phase` — a live subordinate round names the step,
      otherwise the author's own phase does, and a ticket with nothing more
      specific on record is `:implementing`.
    * merging: `:waiting_ci | :in_merge_queue | :behind_base |
      :merge_blocked`, from the merger status. A conflict, red CI or a draft
      blocks whatever the approval state; an approval-type block counts only
      once the PR is approved (`Arbiter.Worker.Watchdog.effective_block_reason/1`),
      since an unapproved PR waiting on its review is simply queued.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Worker
  alias Arbiter.Worker.Phase
  alias Arbiter.Worker.Watchdog

  @type column ::
          :backlog | :blocked | :ready | :in_progress | :merging | :verifying | :closed

  @type step ::
          :implementing
          | :in_review
          | :addressing_review
          | :fixing_ci
          | :resolving_conflict
          | :waiting_ci
          | :in_merge_queue
          | :behind_base
          | :merge_blocked

  @type t :: %{
          state: Lifecycle.state() | nil,
          column: column() | nil,
          step: step() | nil,
          blocked_by: [String.t()],
          attention: nil
        }

  @type board_column :: :backlog | :ready | :running | :waiting | :closed

  @columns %{
    backlog: :backlog,
    active: :in_progress,
    merging: :merging,
    verifying: :verifying,
    closed: :closed
  }

  @active_steps [:implementing, :in_review, :addressing_review, :fixing_ci, :resolving_conflict]

  @ci_pending [:running, :pending, :not_started]
  @hard_blocks [:conflict, :ci_failed, :draft]

  # Dispatch moves a ticket to :active before its run registers (worktree
  # provisioning, fetch). Below this age a workerless :active ticket is still
  # mid-dispatch, not orphaned.
  @orphan_grace_seconds 60

  @doc "Project `ticket` given `ctx`. See the moduledoc."
  @spec view(map(), map()) :: t()
  def view(ticket, ctx \\ %{}) when is_map(ticket) and is_map(ctx) do
    runs = runs_for(ticket, ctx)
    state = effective_state(ticket, runs)
    blocked_by = ctx |> Map.get(:blocked_by) |> List.wrap() |> Enum.uniq() |> Enum.sort()
    column = column(state, blocked_by)

    %{
      state: state,
      column: column,
      step: step(column, ticket, runs, ctx),
      blocked_by: blocked_by,
      attention: nil
    }
  end

  @doc """
  The ticket's stored state, falling back to the state its legacy columns
  imply (`Lifecycle.legacy_state/1`) for a row that predates it. `nil` when
  there is neither.
  """
  @spec state_of(map() | nil) :: Lifecycle.state() | nil
  def state_of(%{state: state}) when is_atom(state) and not is_nil(state), do: state

  def state_of(%{status: status} = ticket)
      when status in [:open, :in_progress, :awaiting_verification, :closed],
      do: Lifecycle.legacy_state(ticket)

  def state_of(_), do: nil

  @doc """
  Whether a gating blocker in this state (or this ticket) no longer holds its
  dependents back: `:verifying` or `:closed`. The one predicate
  `Arbiter.Tasks.EdgeGate.blockers/2`, `Issue.ready/1` and
  `Arbiter.Tasks.EpicRollup` all gate on.
  """
  @spec blocker_satisfied?(map() | atom() | nil) :: boolean()
  def blocker_satisfied?(state) when state in [:verifying, :closed], do: true
  def blocker_satisfied?(ticket) when is_map(ticket), do: blocker_satisfied?(state_of(ticket))
  def blocker_satisfied?(_), do: false

  @doc """
  The interim mapping onto today's five board columns, until the
  seven-column board (child 9, bd-79w1fs):

  | board | lifecycle |
  |---|---|
  | `:backlog` | `:backlog` |
  | `:ready` | `:blocked` and `:ready` (a blocked card keeps its reason) |
  | `:running` | `:in_progress` |
  | `:waiting` | `:merging`, `:verifying`, and an `:in_progress` ticket whose primary author run is parked (`:waiting` on a question, or finished without succeeding) or gone past the dispatch grace |
  | `:closed` | `:closed` |

  An `:in_progress` ticket whose primary author run (or, with that gone, any
  subordinate pass) is still live is Running; with no author run left it is
  Running only inside the dispatch grace window, and
  never flagged at all when it is a non-dispatchable type (an epic never gets
  a run). `nil` when the ticket has no column.
  """
  @spec board_column(map(), map()) :: board_column() | nil
  def board_column(ticket, ctx \\ %{}) when is_map(ticket) and is_map(ctx) do
    case view(ticket, ctx).column do
      nil -> nil
      :backlog -> :backlog
      column when column in [:blocked, :ready] -> :ready
      :in_progress -> in_progress_board_column(ticket, runs_for(ticket, ctx), ctx)
      column when column in [:merging, :verifying] -> :waiting
      :closed -> :closed
    end
  end

  @doc """
  The author rows among `runs` — the worker rows registered under the ticket's
  own id that are not a reviewer / implementer round. A subordinate fix or
  conflict pass shares the id and counts, as it does on the board.
  """
  @spec author_runs([map()], String.t() | nil) :: [map()]
  def author_runs(runs, ticket_id) do
    Enum.filter(runs, &(Map.get(&1, :task_id) == ticket_id and author?(&1)))
  end

  @doc "Whether a worker row is an author row (not a reviewer / implementer round)."
  @spec author?(map()) :: boolean()
  def author?(run), do: meta(run, :role) not in [:reviewer, :implementer]

  @doc "The dispatch grace window, in seconds (see `board_column/2`)."
  @spec orphan_grace_seconds() :: pos_integer()
  def orphan_grace_seconds, do: @orphan_grace_seconds

  # ---- column -------------------------------------------------------------

  defp effective_state(ticket, runs) do
    authors = author_runs(runs, Map.get(ticket, :id))

    case state_of(ticket) do
      state when state in [:backlog, :queued] ->
        if Enum.any?(authors, &(Map.get(&1, :state) != :finished)),
          do: :active,
          else: state

      nil ->
        if Enum.any?(authors, &(run_class(&1) != :succeeded)), do: :active

      state ->
        state
    end
  end

  defp column(nil, _blocked_by), do: nil
  defp column(:queued, []), do: :ready
  defp column(:queued, _blocked_by), do: :blocked
  defp column(state, _blocked_by), do: Map.fetch!(@columns, state)

  # The primary author row decides: a fix pass running under a parked author
  # does not make the card Running, and a failed pass under a working author
  # does not make it Waiting. Only once the primary is gone do the subordinate
  # passes speak for the ticket.
  defp in_progress_board_column(ticket, runs, ctx) do
    id = Map.get(ticket, :id)

    classes =
      case primary(runs, id) do
        nil -> runs |> author_runs(id) |> Enum.map(&run_class/1)
        author -> [run_class(author)]
      end

    cond do
      :running in classes -> :running
      :waiting in classes -> :waiting
      orphaned?(ticket, ctx) -> :waiting
      true -> :running
    end
  end

  # How an author run's state reads on the board (bd-1uu19b):
  #   * `:running` — its agent (or its reviewer) is still the machine's turn:
  #     `:starting`, `:working`, or `:waiting` on the review gate;
  #   * `:waiting` — done, and the outcome is someone else's: `:waiting` on a
  #     question, or finished without succeeding;
  #   * `:succeeded` — finished and successful; it no longer claims the ticket.
  defp run_class(run) do
    case {Map.get(run, :state), Map.get(run, :outcome)} do
      {state, _} when state in [:starting, :working] -> :running
      {:waiting, _} -> if Worker.awaiting_review_gate?(run), do: :running, else: :waiting
      {:finished, :succeeded} -> :succeeded
      {:finished, _} -> :waiting
      _ -> nil
    end
  end

  # No live author run at all: orphaned once past the dispatch grace. An epic
  # never gets a run, so it never reads as orphaned.
  defp orphaned?(ticket, ctx) do
    Map.get(ticket, :issue_type) not in Issue.non_dispatchable_types() and
      past_grace?(ticket, Map.get(ctx, :now))
  end

  defp past_grace?(_ticket, nil), do: true

  defp past_grace?(ticket, now) do
    case Map.get(ticket, :updated_at) || Map.get(ticket, :created_at) do
      %DateTime{} = at -> DateTime.diff(now, at) >= @orphan_grace_seconds
      _ -> true
    end
  end

  # ---- step ---------------------------------------------------------------

  defp step(:in_progress, ticket, runs, _ctx), do: active_step(Map.get(ticket, :id), runs)
  defp step(:merging, ticket, _runs, ctx), do: merging_step(ticket, ctx)
  defp step(_column, _ticket, _runs, _ctx), do: nil

  defp active_step(ticket_id, runs) do
    phase =
      case primary(runs, ticket_id) do
        nil -> live_subordinate_phase(runs, ticket_id)
        author -> Phase.of(author, runs)
      end

    if phase in @active_steps, do: phase, else: :implementing
  end

  # A fix / conflict pass whose author row is already gone still names the
  # round it is.
  defp live_subordinate_phase(runs, ticket_id) do
    runs
    |> Enum.filter(&(Map.get(&1, :task_id) == ticket_id))
    |> Enum.map(&Phase.of(&1, runs))
    |> Enum.find(&(&1 in @active_steps))
  end

  defp merging_step(ticket, ctx) do
    status = merger_status(ticket, ctx)
    raw = Watchdog.block_reason(status)

    cond do
      raw == :behind_base -> :behind_base
      raw in @hard_blocks or Watchdog.effective_block_reason(status) != nil -> :merge_blocked
      ci_pending?(status, Map.get(ticket, :pending_merge)) -> :waiting_ci
      true -> :in_merge_queue
    end
  end

  # The PR's last poll: `ctx` wins, then what the ticket's Watchdog recorded on
  # its row (bd-741sid).
  defp merger_status(ticket, ctx) do
    case Map.get(ctx, :merger_status) do
      %{} = status -> status
      _ -> PullRequest.merger_status(ticket) || %{}
    end
  end

  defp ci_pending?(status, pending_merge) do
    Map.get(status, :pipeline) in @ci_pending or pending_reason(pending_merge) == "ci_pending"
  end

  defp pending_reason(%{} = pending), do: Map.get(pending, "reason") || Map.get(pending, :reason)
  defp pending_reason(_), do: nil

  # ---- runs ---------------------------------------------------------------

  defp runs_for(ticket, ctx) do
    ctx |> Map.get(:runs) |> List.wrap() |> Enum.filter(&touches?(&1, Map.get(ticket, :id)))
  end

  defp touches?(run, id) do
    Map.get(run, :task_id) == id or meta(run, :reviews) == id or meta(run, :revises) == id
  end

  # The author's primary row — no role of its own — rather than a subordinate
  # pass sharing its id. nil when every author row is a subordinate.
  defp primary(runs, ticket_id) do
    case author_runs(runs, ticket_id) do
      [] ->
        nil

      authors ->
        Enum.find(authors, &(is_nil(Map.get(&1, :role)) and is_nil(meta(&1, :role))))
    end
  end

  defp meta(run, key) do
    case Map.get(run, :meta) do
      %{} = meta -> Map.get(meta, key)
      _ -> nil
    end
  end
end
