defmodule Arbiter.Board.Snapshot do
  @moduledoc """
  The board, derived. One read of the world in, five columns and a dispatch
  decision out.

  The operator console's board is not a stored object — Arbiter has no "board"
  table and deliberately doesn't want one. Every column is a *view* of state
  that already exists (issues, live workers, merge requests), so the board can
  never drift from the system it describes: there is nothing to keep in sync.

  ## The five columns

  Every ticket's column comes from one projection, `Arbiter.Tasks.Lifecycle.view/2`
  (bd-6zapbl), mapped onto these five until the seven-column board lands
  (bd-79w1fs) by `Arbiter.Tasks.Lifecycle.board_column/2`. The same call
  classifies the epic mini-board (`classify_columns/3`) and the `/epics`
  rollup (`Arbiter.Tasks.EpicRollup`), so the three cannot disagree. Each card
  builder below only builds cards for tickets in its own column, so a ticket
  lands in exactly one.

    * **Backlog** — `:backlog` tickets: filed, not refined. Newest first,
      deliberately: an unrefined pile is a to-think-about list, not a queue,
      and ordering it by priority would imply a ranking the refinement hasn't
      earned.
    * **Ready** — `:queued` tickets, Blocked and Ready alike. A real queue,
      ordered by priority then age, each card carrying the reason
      `Arbiter.Board.Scheduler` gave it (`next up — dispatching...`,
      `2 ahead in queue`, `blocked — waiting on bd-9`). A leftover finished
      author row does not hide a queued ticket: the column is the ticket's,
      not the run's.
    * **Running** — `:in_progress` tickets whose primary author run is live:
      `:starting`, `:working`, or `:waiting` on the review gate (while a
      *reviewer agent* reads the diff — automated, so still the machine's
      turn). Reviewer workers fold into the author's card rather
      than occupying one of their own; a review is a phase of the author's
      work, not a second piece of it. An in-progress ticket whose run has not
      registered yet (inside the dispatch grace) is a "dispatching" card here.
    * **Waiting** — `:merging` and `:verifying` tickets, plus an
      `:in_progress` ticket whose author run is done and whose outcome now
      depends on something outside it: `:waiting` on a question (it asked a
      human), finished `:failed` (parked; send it back or close it) — or that
      has **no live worker at all** past the dispatch grace (e.g. `arb worker
      stop`, the documented pre-flight for `arb server deploy`), which always
      flags `needs_you` since nothing will retry it on its own. Longest wait first, because a stalled card is the
      thing worth seeing.
    * **Closed · last 24h** — `:closed` tickets closed in the last 24 hours
      (rolling window, keyed on `closed_at`). The day's evidence of progress,
      and the only column with no action on it.

  Epics are excluded from every column (bd-38of5i): the evidence of a day's
  progress is the children that closed, not the container that closed because
  they did, and an epic reaches the board only as the `↳` chip a child card
  carries.

  ## Backlog, and why Blocked is not a separate column (yet)

  Refinement and dependency-readiness are orthogonal questions: a refined
  card whose blocker is still open is `:blocked` in the lifecycle, and on this
  interim board it stays in Ready carrying its own `blocked — waiting on
  bd-9` reason. A blocker is satisfied once it is `:verifying` or `:closed` —
  verifying unblocks dependents (`Arbiter.Tasks.Lifecycle.blocker_satisfied?/1`).

  ## Waiting, and the needs-you flag

  Waiting used to be two columns — Needs you and Merge queue — which split
  cards by *what* they wait on: a person, or a poll. That is not the split an
  operator acts on. Every card in the column is equally out of the worker's
  hands; the only question that changes what a human does next is whether the
  system has anything left to try on its own.

  So it is one column, and that narrower signal rides on the card as
  `:needs_you`:

    * a run `:waiting` on a question always flags — there is no such thing as
      retrying a question.
    * a run finished `:failed` always flags — a parked worker is terminal by
      definition, so whatever it was last seen waiting on, nothing is going
      to turn it.
    * an open MR flags unless its block is one the Watchdog still resolves by
      itself — `:behind_base` (it rebases) and `:ci_failed` (it dispatches a
      fix pass). Everything else, from `:conflict` to `:needs_approval` to
      `:draft`, waits on a person; an unblocked MR is simply mid-review, which
      is still the machine's turn.

  The block reason is read through `Arbiter.Worker.Watchdog`
  (`effective_block_reason/1`, itself gated on `classify/1 == :approved`), the
  same surface the merge-queue screen reads, so the flag can never disagree
  with the status text rendered next to it. The exempt list is the Watchdog's
  own `auto_resolvable?/1` set rather than a hand-kept roster of human blocks,
  so it *shrinks* as more auto-recovery lands and a newly-invented block
  reason defaults to "a person's" instead of silently reading as pipeline
  wait. It measures "still needs a human today", not "something is imperfect".

  `slots_used` is the tickets In progress — stored state `:active` — and
  nothing else (bd-asxw4e): a ticket between ReviewGate rounds holds its slot
  with no agent live, and one Merging on its open PR or Verifying holds none,
  whatever worker row lingers. `slots_free` means "tickets I could start
  dispatching right now given the cap", which is a different number from
  `agents_live`, "agents actually burning quota this instant" — see
  `Arbiter.Tasks.SlotGate`'s "A slot is a ticket In progress" section.

  ## Deriving vs loading

  `derive/1` is pure: hand it issues, worker snapshots and a clock and it
  computes the board, including the dispatch plan. `load/1` is the thin shell
  that reads those inputs from the repo, the worker supervisor, the settings
  and the quota gate. All the interesting rules live in the pure half, so the
  board's behaviour is testable without a database.
  """

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Board.FileScope
  alias Arbiter.Board.Scheduler
  alias Arbiter.Tasks.EdgeGate
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Tasks.SlotGate
  alias Arbiter.Usage.Budget
  alias Arbiter.Worker
  alias Arbiter.Worker.Phase
  alias Arbiter.Worker.Watchdog

  require Ash.Query

  # Run states that *used* to define a slot (the `:issues` basis).
  # bd-aw2cyt moved the question to `Arbiter.Tasks.SlotGate`, which counts live
  # agent sessions instead; this list is still what `:issues` falls back to, and
  # its definition lives there now.
  @slot_states SlotGate.slot_states()

  # The only blocks the Watchdog still clears on its own — mirrors its
  # `auto_resolvable?/1`. Everything else needs a person today.
  @auto_resolving_block_reasons [:behind_base, :ci_failed]

  @default_system_max 16

  # bd-6bax7s: what a live worker's run state is *called* on a card held back
  # by a `:conflicts_with` mutex (`conflict_state/1`), and — by omission —
  # which states count as in flight at all. A `:finished` run is absent on
  # purpose: it holds nothing back. An open MR on the counterpart is exactly
  # the thing a mutex exists to keep a second worker away from — since
  # bd-741sid that is a Merging ticket, claimed from its state
  # (`@merging_state`).

  @merging_state "merging"

  # A reviewer / implementer worker claims the mutex on behalf of the author it
  # is working for, for the window where the author's own worker has already
  # gone away.
  @reviewer_state "in review"
  @fix_pass_state "fix pass"

  # An issue flipped to :in_progress whose worker has not registered yet.
  @dispatching_state "dispatching"

  # Dispatch flips an issue to :in_progress before the worker is registered
  # (worktree provisioning, fetch, etc. — seconds on a large repo). Below this
  # age, treat it as mid-dispatch rather than orphaned. The window is the
  # lifecycle projection's (`Lifecycle.board_column/2`), so the two agree.
  @orphan_grace_seconds Lifecycle.View.orphan_grace_seconds()

  @type t :: %{
          backlog: [map()],
          ready: [Scheduler.entry()],
          running: [map()],
          waiting: [map()],
          closed_today: [map()],
          promote: String.t() | nil,
          slots_total: non_neg_integer(),
          slots_free: non_neg_integer(),
          slots_used: non_neg_integer(),
          agents_live: non_neg_integer(),
          quota: Scheduler.quota(),
          paused: boolean(),
          now: DateTime.t()
        }

  @doc """
  Derive the board from an already-read picture of the world.

  Expected keys: `:issues`, `:workers`, `:blocked_by` (issue id → unsatisfied
  blocker ids, from `EdgeGate.blockers/2`), `:conflicts_with` (`{a, b}` pairs
  from the mutex edges), `:changed_files` (task id → repo-relative paths a worktree has touched),
  `:now`, `:slots_total`, `:quota` and `:paused`. Every key has a sane
  default, so a caller may pass only what it has.

  The Ready queue is in `Arbiter.Board.Scheduler.order/1`'s order — priority,
  then the persisted `rank`, then age (bd-asxw4e) — the same order Autopilot
  dispatches in. The LiveView-only `:ready_order` hand-ranking it used to
  take is gone: Autopilot never saw it, so it made the board promise a
  dispatch order the scheduler did not follow.
  """
  @spec derive(map()) :: t()
  def derive(input) when is_map(input) do
    issues = Map.get(input, :issues, [])
    workers = Map.get(input, :workers, [])
    blocked_by = Map.get(input, :blocked_by, %{})
    # bd-6bax7s: `{a, b}` pairs from the `:conflicts_with` edges, an *input*
    # like `:blocked_by` — the pure half never goes looking for rows.
    # `EdgeGate` folds them into symmetric adjacency, so a card is held
    # whichever direction the coordinator happened to store the edge in.
    conflicts = EdgeGate.adjacency(Map.get(input, :conflicts_with, []))
    changed = Map.get(input, :changed_files, %{})
    now = Map.get(input, :now) || DateTime.utc_now()
    slots_total = Map.get(input, :slots_total, 0)
    quota = Map.get(input, :quota, :ok)
    paused? = Map.get(input, :paused) == true
    # bd-38of5i: `{parent_id, child_id}` pairs from the `:parent_of` edges. An
    # *input*, like `:blocked_by` — the pure half never goes looking for rows.
    parent_of = Map.get(input, :parent_of, [])
    # bd-8jixav: which tasks have a live Watchdog. A Registry read, so it is an
    # *input* here rather than something `derive/1` goes and looks up — the
    # pure half stays pure and a caller that can't answer passes nothing, which
    # reads as "unknown" on the card rather than a false "no watchdog" alarm.
    watchdog_live = Map.get(input, :watchdog_live)
    # bd-8j9i9p (design bd-9jj5lf §3): the ids whose worker spend has passed
    # their estimate group's p90. An *input* like the two above — the flag is a
    # ledger question, and the pure half never goes to the ledger. A caller
    # that can't answer passes nothing, and no card flags.
    over_budget = over_budget_set(Map.get(input, :over_budget))
    # bd-aw2cyt: how a slot is counted. An *input*, like everything else here —
    # `load/1` resolves the configured basis and the pure half just applies it.
    slot_basis = SlotGate.normalize_basis(Map.get(input, :slot_basis))

    issues_by_id = Map.new(issues, &{&1.id, &1})
    parents = parent_refs(parent_of, issues_by_id)

    {authors, gate_workers} =
      Enum.split_with(workers, &(worker_role(&1) not in [:reviewer, :implementer]))

    gate_workers_by_author =
      gate_workers
      |> Enum.sort_by(&since/1, {:asc, DateTime})
      |> Map.new(&{gate_author(&1), &1})

    worked = MapSet.new(authors, & &1.task_id)

    # bd-6zapbl: every ticket's column, from `Lifecycle.view/2` through the
    # interim five-column mapping. Each card builder below only ever builds a
    # card for a ticket in its own column, so a ticket lands in exactly one.
    # Epics stay off the board.
    columns =
      issues
      |> ticket_columns(workers, blocked_by, now)
      |> Map.reject(fn {id, _column} -> epic?(Map.get(issues_by_id, id)) end)

    running =
      (running_cards(authors, issues_by_id, gate_workers_by_author, workers, columns) ++
         dispatching_cards(issues, authors, columns))
      |> Enum.sort_by(& &1.since, {:asc, DateTime})

    # bd-aw2cyt: a live agent session in any role — author, reviewer,
    # implementer round, CI fix pass, conflict resolver. Counted over ALL
    # workers, not just the author rows: a reviewer is a second paid session.
    # This is "agents live" on the header — what's actually burning quota —
    # and no longer what the dispatch cap is measured against; see below.
    agents_live = SlotGate.occupied(workers, slot_basis)

    # bd-asxw4e: the dispatch cap is measured in TICKETS In progress — the
    # tickets whose stored state is `:active`, the same set as the In progress
    # column. A ticket between ReviewGate rounds keeps its slot with no agent
    # live (bd-45pwo1); Merging and Verifying release it. The worker rows
    # never enter into it. See `SlotGate`'s "A slot is a ticket In progress".
    slots_used = SlotGate.slots_used(issues)
    slots_free = max(slots_total - slots_used, 0)

    plan =
      Scheduler.plan(%{
        ready: ready_cards(issues, columns, blocked_by, conflicts),
        running: in_flight(authors, issues_by_id, changed),
        conflict_claims: conflict_claims(authors, gate_workers, issues, worked, now),
        slots_free: slots_free,
        quota: quota,
        paused: paused?
      })

    %{
      backlog:
        backlog_cards(issues, columns) |> with_parents(parents) |> with_over_budget(over_budget),
      ready:
        plan.entries
        |> with_parents_in_entries(parents)
        |> with_over_budget_in_entries(over_budget),
      running: running |> with_parents(parents) |> with_over_budget(over_budget),
      waiting:
        authors
        |> waiting(issues, issues_by_id, columns, watchdog_live, workers)
        |> with_parents(parents)
        |> with_over_budget(over_budget),
      # A closed task that ran over is done — there is nothing left to act on,
      # so the Closed column never flags, whatever the input says.
      closed_today:
        closed_today_cards(issues, columns, now)
        |> with_parents(parents)
        |> with_over_budget(nil),
      promote: plan.promote,
      slots_total: slots_total,
      slots_free: slots_free,
      slots_used: slots_used,
      agents_live: agents_live,
      quota: quota,
      paused: paused?,
      now: now
    }
  end

  @doc """
  Read the world and derive the board.

  Options mirror `derive/1`'s inputs and override what would otherwise be
  read: `:now`, `:slots_total`, `:quota`, `:paused`,
  `:issues`, `:workers`, `:changed_files`, `:workspace_id`. Every read is
  best-effort — a board that renders five columns beats one that raises.

  **Workspace-level scoping:** `slots_total` and `quota` are computed for the
  specified workspace (defaulting to the default workspace if not given).
  However, `:issues` and `:workers` span all workspaces. Per-workspace
  concurrency limits are enforced at dispatch by `effective_max_concurrent/1`;
  this board is a global view with workspace-specific slot constraints. Multi-workspace
  boards with workspace-specific caps are a known limitation (see #1359).
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    issues = Keyword.get_lazy(opts, :issues, &load_issues/0)
    workers = Keyword.get_lazy(opts, :workers, &load_workers/0)
    workspace_id = Keyword.get(opts, :workspace_id) || default_workspace_id()
    # bd-aw2cyt: `load/1` is the impure boundary, so it is where the configured
    # basis is read. `derive/1` stays a function of its inputs, and an explicit
    # `:slot_basis` (the pure tests, a caller with its own opinion) still wins.
    slot_basis = SlotGate.normalize_basis(Keyword.get(opts, :slot_basis) || SlotGate.basis())

    # One read of the dependency rows feeds both derived inputs — the gating
    # blockers and (bd-38of5i) the `parent_of` pairs. Skipped entirely when the
    # caller supplied both, which is how the pure tests stay repo-free.
    deps = dependency_rows(opts)

    derive(%{
      issues: issues,
      workers: workers,
      blocked_by: Keyword.get_lazy(opts, :blocked_by, fn -> blockers_from(deps, issues) end),
      parent_of: Keyword.get_lazy(opts, :parent_of, fn -> parent_of_from(deps) end),
      conflicts_with:
        Keyword.get_lazy(opts, :conflicts_with, fn -> EdgeGate.conflict_pairs(deps) end),
      changed_files: Keyword.get(opts, :changed_files, %{}),
      now: Keyword.get(opts, :now) || DateTime.utc_now(),
      slot_basis: slot_basis,
      # `derive/1` subtracts the used slots from this total, and the account
      # term folded in below is a headroom expressed in the caller's own frame
      # — so the two have to agree on what "used" means. Since bd-asxw4e that
      # is the tickets In progress: hand it the same count `derive/1` will
      # subtract.
      slots_total:
        Keyword.get(opts, :slots_total) ||
          effective_max_concurrent(workspace_id, SlotGate.slots_used(issues)),
      quota: Keyword.get_lazy(opts, :quota, fn -> quota_hold(workspace_id) end),
      paused: Keyword.get(opts, :paused, false),
      watchdog_live: Keyword.get_lazy(opts, :watchdog_live, fn -> watchdog_live(issues) end),
      over_budget: Keyword.get_lazy(opts, :over_budget, fn -> Budget.over_budget_ids(issues) end)
    })
  end

  @doc """
  Which of the Merging tickets among `issues` still have a live Watchdog
  (bd-8jixav, bd-741sid). One Registry lookup per Merging ticket — cheap, and
  only for the one state a ticket's Watchdog is supposed to be running in.

  Public so a caller scoped to fewer than the whole fleet (e.g.
  `Arbiter.Tasks.EpicRollup`, bd-58z2tu) can build the same liveness set
  `merging_needs_you?/3` expects without going through `load/1`.
  """
  @spec watchdog_live([map()]) :: MapSet.t() | nil
  def watchdog_live(issues) do
    issues
    |> Enum.filter(&(Lifecycle.state_of(&1) == :merging and Watchdog.alive?(&1.id)))
    |> MapSet.new(& &1.id)
  rescue
    # A board that renders five columns beats one that raises: an unreadable
    # registry degrades to "unknown", not to a false alarm on every card.
    _ -> nil
  end

  @doc """
  A board with five empty columns and nothing to promote.

  What a caller renders when its read of the world failed. It reports itself
  `paused: true` on purpose: a queue nobody could read is not one anything
  should be dispatching from, and every Ready card would otherwise claim a
  position in a queue that isn't moving.
  """
  @spec empty(DateTime.t() | nil) :: t()
  def empty(now \\ nil) do
    %{
      backlog: [],
      ready: [],
      running: [],
      waiting: [],
      closed_today: [],
      promote: nil,
      slots_total: 0,
      slots_free: 0,
      slots_used: 0,
      agents_live: 0,
      quota: :ok,
      paused: true,
      now: now || DateTime.utc_now()
    }
  end

  @doc """
  The install-wide worker ceiling — the runtime `Arbiter.Settings` override,
  else app env, else #{@default_system_max}. (The `conductor_` prefix on the
  setting name is historical — the board scheduler is the only dispatcher.)
  """
  @spec system_max_concurrent() :: pos_integer()
  def system_max_concurrent do
    Arbiter.Settings.conductor_system_max_concurrent() ||
      Application.get_env(:arbiter, :conductor_system_max_concurrent, @default_system_max)
  rescue
    _ -> @default_system_max
  end

  @doc """
  The effective maximum concurrent workers for a workspace: the minimum of the
  workspace-level cap (if set), the system-wide cap, and — since P8
  (`docs/provider-account-design.md` §4.2) — the headroom left on the provider
  account this workspace is metered under.

  The account term matters because `slots_total` is what every Ready card's queue position is computed from: a
  board that ignores a full account promises slots the next scheduler tick will
  refuse. It can therefore return **0**, which the pre-P8 signature could not.

  The workspace's own live workers are added back before the min (via
  `Concurrency.clamp/3`) because `load/1` subtracts the running cards from
  `slots_total` itself — counting them in both places would halve the number.
  `already_counted` is exactly what the caller will subtract; since bd-aw2cyt
  that is the *live agent* count, so `load/1` passes it rather than letting
  this function guess with `Concurrency.workspace_live_count/2`. Omitting it
  keeps the pre-bd-aw2cyt behaviour for callers that have no worker list.

  When workspace_id is nil, returns the system max: a fleet-wide board is not
  scoped to any one account.
  """
  @spec effective_max_concurrent(String.t() | nil, non_neg_integer() | nil) ::
          non_neg_integer()
  def effective_max_concurrent(workspace_id, already_counted \\ nil)

  def effective_max_concurrent(nil, _already_counted) do
    system_max_concurrent()
  end

  def effective_max_concurrent(workspace_id, already_counted) when is_binary(workspace_id) do
    system_max = system_max_concurrent()

    base =
      case workspace_config_max(workspace_id) do
        n when is_integer(n) and n > 0 -> min(n, system_max)
        _ -> system_max
      end

    provider = Arbiter.Quota.default_provider(workspace_id)

    already_counted =
      already_counted || Concurrency.workspace_live_count(workspace_id, provider)

    Concurrency.clamp(base, Concurrency.headroom(workspace_id, provider), already_counted)
  rescue
    _ -> system_max_concurrent()
  end

  # Read the workspace's `conductor.max_concurrent` config key, if set. The key
  # name is historical (bd-a14qd1); it is the board scheduler's per-workspace cap.
  defp workspace_config_max(workspace_id) do
    case Ash.get(Arbiter.Tasks.Workspace, workspace_id) do
      {:ok, ws} -> Arbiter.Tasks.Workspace.max_concurrent(ws)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Whether quota permits a dispatch right now, as `:ok` or `{:hold, reason}`.

  Distinguishes an actually-exhausted window ("the provider is refusing") from
  one that has crossed the throttle threshold ("we chose to stop here"),
  because the operator's next move differs: wait for the reset, or raise the
  ceiling.

  Reads the snapshot for the **provider account** the workspace is metered
  under, on that workspace's default agent provider
  (`Arbiter.Quota.default_provider/1`), and defers the over-cap decision to
  `Arbiter.Quota.Gate.hold_phrase/2` (`gating_window/2`) — the same shared
  implementation the `dispatch/2` quota seam uses (bd-5j6nmn), so Autopilot's
  one-per-tick promotion gate and the dispatcher agree on the same underlying
  data.

  A `:continue`-mode workspace (`Arbiter.Quota.continue_mode?/1`) never holds
  here: the `dispatch/2` seam is the single choke point for the allow/overage decision,
  so the board must not show a `blocked — quota exhausted` hold that the
  dispatcher itself would not honor (reviewer round 1, finding 1).

  An open `Arbiter.Agents.AuthHold` on the workspace's default agent provider
  (bd-21bmdh — N consecutive workers died on auth) rides the same board-wide
  hold, ahead of the quota window and regardless of `:continue` mode: the
  dispatcher's auth guard refuses those dispatches unconditionally, so
  `Arbiter.Board.Autopilot` must not keep promoting a card only to have it
  refused. This is what stops a reopened auth-failed task from being
  re-attempted every tick while credentials are dead.
  """
  @spec quota_hold(String.t() | nil) :: Scheduler.quota()
  def quota_hold(workspace_id \\ nil) do
    workspace_id = workspace_id || default_workspace_id()
    auth_hold(workspace_id) || quota_window_hold(workspace_id)
  end

  # The board's read of the hold is `AuthHold.held/2`, which fails open: the
  # dispatch guard's own fail-closed read is the backstop, and a board must
  # not paint a hold that is not there.
  defp auth_hold(ws_id) when is_binary(ws_id) do
    with %Arbiter.Tasks.Workspace{} = workspace <- safe_workspace(ws_id),
         adapter when is_atom(adapter) <- Arbiter.Agents.for_workspace(workspace),
         %{provider: provider, deaths: deaths} <- Arbiter.Agents.AuthHold.held(adapter) do
      {:hold, "#{provider} auth hold (#{deaths} consecutive auth deaths)"}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp auth_hold(_ws_id), do: nil

  defp quota_window_hold(workspace_id) do
    with ws_id when is_binary(ws_id) <- workspace_id,
         workspace <- safe_workspace(ws_id),
         false <- Arbiter.Quota.continue_mode?(workspace),
         provider <- quota_provider(workspace),
         account <- quota_account(ws_id, provider),
         snapshot when not is_nil(snapshot) <- latest_quota(account, provider) do
      describe_quota(snapshot, {account, workspace})
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # ---- shared column classification -----------------------------------------

  @doc """
  The board's own column classification, applied to an arbitrary set of
  issues rather than the whole board.

  Design bd-2s901b §3: an epic detail page groups its children into a
  "Children by status" mini-board using these same five columns, so it needs
  the same answer the board itself would give. Since bd-6zapbl both read it
  from `Arbiter.Tasks.Lifecycle.board_column/2` — the ticket's
  `Lifecycle.view/2` column through the interim five-column mapping — and
  so does `Arbiter.Tasks.EpicRollup`.

  `workers` need only be the live workers for these issues' ids (a caller
  scoped to one epic's children has no reason to pass the whole fleet); they
  are the runs the projection reads. Unlike the board, an epic child gets a
  column here too — a sub-epic still belongs on its parent's mini-board.

  Options: `:now` (the dispatch-grace clock, default now) and `:blocked_by`
  (issue id → unsatisfied blocker ids, which only splits Blocked from Ready
  and so cannot move a card between these five columns).

  Returns `%{issue_id => :backlog | :ready | :running | :waiting | :closed}`.
  """
  @spec classify_columns([map()], [map()], keyword()) :: %{String.t() => atom()}
  def classify_columns(issues, workers \\ [], opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    columns = ticket_columns(issues, workers, Keyword.get(opts, :blocked_by, %{}), now)

    Map.new(issues, &{&1.id, Map.get(columns, &1.id) || :backlog})
  end

  # bd-6zapbl: the one place the board asks "which column?". Every issue, plus
  # a bare `%{id: task_id}` for an author worker whose issue was not read, so
  # its card still lands somewhere.
  defp ticket_columns(issues, workers, blocked_by, now) do
    runs = runs_by_ticket(workers)
    known = MapSet.new(issues, & &1.id)

    unread =
      for w <- workers,
          Lifecycle.View.author?(w),
          not MapSet.member?(known, w.task_id),
          uniq: true,
          do: %{id: w.task_id}

    Map.new(issues ++ unread, fn ticket ->
      ctx = %{
        runs: Map.get(runs, ticket.id, []),
        blocked_by: Map.get(blocked_by, ticket.id, []),
        now: now
      }

      {ticket.id, Lifecycle.board_column(ticket, ctx)}
    end)
  end

  # Every worker row under each ticket it touches: its own task id, and the
  # author a reviewer / implementer round points back at.
  defp runs_by_ticket(workers) do
    workers
    |> Enum.flat_map(fn w ->
      [w.task_id, gate_author(w)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&{&1, w})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp in_column?(columns, id, column), do: Map.get(columns, id) == column

  defp epic?(nil), do: false
  defp epic?(issue), do: dispatchable_type_excluded?(issue)

  # Board-level dispatch is per-issue, so containers never queue: an epic is a
  # rollup of children, not something a worker can be handed. bd-38of5i
  # extended the same exclusion to Closed-today, the one column they still
  # leaked into; epics now live on `/epics` and reach the board only as the
  # `↳` chip a child card carries. bd-cnfwtr: the list itself lives on
  # `Arbiter.Tasks.Issue`, which `ready/1` also reads, so the two surfaces
  # can't drift apart.
  defp dispatchable_type_excluded?(issue) do
    Map.get(issue, :issue_type) in Arbiter.Tasks.Issue.non_dispatchable_types()
  end

  # Newest first, and only newest first. This is provisional on purpose: the
  # moment Backlog grows a priority order it starts reading as a second queue,
  # and there is exactly one queue.
  defp backlog_cards(issues, columns) do
    issues
    |> Enum.filter(&in_column?(columns, &1.id, :backlog))
    |> Enum.sort_by(&created_at/1, {:desc, DateTime})
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        created_at: created_at(issue)
      }
    end)
  end

  # In no particular order: `Scheduler.plan/1` orders the queue.
  defp ready_cards(issues, columns, blocked_by, conflicts) do
    issues
    |> Enum.filter(&in_column?(columns, &1.id, :ready))
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        rank: Map.get(issue, :rank),
        created_at: created_at(issue),
        difficulty: Map.get(issue, :difficulty),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        scope: FileScope.declared_paths(issue),
        blocked_by: Map.get(blocked_by, issue.id, []),
        conflicts_with: EdgeGate.conflicts(conflicts, issue.id),
        refined: true,
        state: Lifecycle.state_of(issue),
        status: Map.get(issue, :status)
      }
    end)
  end

  # ---- running / waiting ----------------------------------------------------

  defp running_cards(workers, issues_by_id, gate_workers_by_author, all_workers, columns) do
    workers
    |> Enum.filter(&(running_run?(&1) and in_column?(columns, &1.task_id, :running)))
    # One ticket, one card: the primary row over a live pass sharing its id.
    |> one_row_per_task()
    |> Enum.map(fn {w, _group} ->
      gate_worker = Map.get(gate_workers_by_author, w.task_id)

      w
      |> base_card(issues_by_id)
      |> Map.merge(%{
        step: Map.get(w, :current_step),
        activity: activity(w, gate_worker),
        provider: card_provider(w, gate_worker),
        since: since(w)
      })
      |> with_phase(w, all_workers)
    end)
  end

  # bd-6zapbl: an in-progress ticket whose run has not registered yet — inside
  # the dispatch grace window (worktree provisioning, fetch). It is Running,
  # not missing: the ticket holds its slot, and the card says it is still
  # being dispatched.
  defp dispatching_cards(issues, authors, columns) do
    live = for w <- authors, running_run?(w), into: MapSet.new(), do: w.task_id

    issues
    |> Enum.filter(&(in_column?(columns, &1.id, :running) and not MapSet.member?(live, &1.id)))
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        status: :in_progress,
        step: nil,
        activity: @dispatching_state,
        provider: nil,
        since: Map.get(issue, :updated_at) || created_at(issue),
        phase: :implementing,
        agent_live: false
      }
    end)
  end

  # One column, so one card shape: a parked worker's card still carries the
  # (empty) merge fields and a merge-parked one still carries a (nil) reason,
  # and an orphaned issue (no live worker at all) still carries both, nil.
  # The view reads whichever it has instead of branching on which shape
  # produced the card.
  #
  # bd-6zapbl: one card per Waiting ticket. A verifying ticket gets its
  # verification card and a merging one its merge card (bd-741sid), whatever
  # worker rows linger; any other gets a card from its non-completed author
  # rows, or — with none left — the orphan card.
  defp waiting(workers, issues, issues_by_id, columns, watchdog_live, all_workers) do
    verifying = ids_in_state(issues, :verifying)
    merging = ids_in_state(issues, :merging)

    carded =
      Enum.filter(workers, fn w ->
        not succeeded?(w) and in_column?(columns, w.task_id, :waiting) and
          not MapSet.member?(verifying, w.task_id) and not MapSet.member?(merging, w.task_id)
      end)

    with_rows = MapSet.new(carded, & &1.task_id)

    waiting_issues = Enum.filter(issues, &in_column?(columns, &1.id, :waiting))

    {verifying_issues, others} =
      Enum.split_with(waiting_issues, &MapSet.member?(verifying, &1.id))

    {merging_issues, others} = Enum.split_with(others, &MapSet.member?(merging, &1.id))

    (waiting_cards(carded, issues_by_id, watchdog_live, all_workers) ++
       merging_cards(merging_issues, all_workers, watchdog_live) ++
       orphaned_cards(Enum.reject(others, &MapSet.member?(with_rows, &1.id))) ++
       awaiting_verification_cards(verifying_issues))
    |> Enum.sort_by(& &1.since, {:asc, DateTime})
  end

  defp ids_in_state(issues, state),
    do: for(i <- issues, Lifecycle.state_of(i) == state, into: MapSet.new(), do: i.id)

  # bd-741sid: a Merging ticket's implementer stopped when its PR opened, so
  # the card is built from the ticket — the PR on its row, the forge's last
  # answer its Watchdog recorded, and whether that Watchdog is still running,
  # or was stopped on purpose (`merge_pulled`, `PullRequest.pull/1`). A worker
  # row still registered under the ticket (a pass that failed) keeps its vote
  # and its note, as a collapsed row does on a worker card.
  defp merging_cards(issues, workers, watchdog_live) do
    rows = Enum.group_by(workers, & &1.task_id)

    Enum.map(issues, fn issue ->
      group = rows |> Map.get(issue.id, []) |> Enum.reject(&succeeded?/1)

      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        status: :merging,
        reason: nil,
        mr_ref: Map.get(issue, :pr_ref),
        merger_url: Map.get(issue, :merger_url),
        merger_status: PullRequest.merger_status(issue),
        watchdog_alive: ticket_watchdog_alive(issue.id, watchdog_live),
        merge_pulled: PullRequest.pulled?(issue),
        needs_you: merging_needs_you?(issue, group, watchdog_live),
        collapsed_note: collapsed_note(nil, group),
        since: Map.get(issue, :updated_at) || created_at(issue),
        phase: :waiting_ci_merge,
        agent_live: false
      }
    end)
  end

  @doc """
  Whether a Merging ticket needs the operator (bd-741sid): its Watchdog is
  gone (`false` in `watchdog_live`, see `watchdog_live/1`) so nothing polls
  the PR; the forge's last answer is a block the Watchdog cannot clear itself;
  or a worker row still registered under it (`rows`, e.g. a pass that failed)
  needs the operator per `child_needs_you?/2`.

  Public so `Arbiter.Tasks.EpicRollup` flags a Merging child exactly as the
  board's merge card does.
  """
  @spec merging_needs_you?(map(), [map()], MapSet.t() | nil) :: boolean()
  def merging_needs_you?(ticket, rows, watchdog_live) do
    ticket_watchdog_alive(ticket.id, watchdog_live) == false or
      blocked_for_you?(PullRequest.merger_status(ticket) || %{}) or
      child_needs_you?(rows, watchdog_live)
  end

  defp ticket_watchdog_alive(id, live) when is_struct(live, MapSet), do: MapSet.member?(live, id)
  defp ticket_watchdog_alive(_id, _live), do: nil

  # bd-9so315: a task merged but parked until someone restarts the server and
  # observes the new path. It has no worker (the merge tore it down), so it
  # produces no worker-derived card and would otherwise be invisible — which is
  # precisely the failure the state exists to fix. It is always `needs_you`:
  # nothing in the fleet can clear it, only a human observation can.
  defp awaiting_verification_cards(issues) do
    Enum.map(issues, fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        status: :awaiting_verification,
        reason: "merged — awaiting verification (restart and observe)",
        mr_ref: Map.get(issue, :pr_ref),
        merger_url: nil,
        merger_status: nil,
        watchdog_alive: nil,
        merge_pulled: false,
        needs_you: true,
        collapsed_note: nil,
        since: awaiting_since(issue)
      }
      |> workerless_phase()
    end)
  end

  # The parked-at stamp, falling back to `updated_at` for rows that entered the
  # state before the column existed, so the card still renders an age. Shared
  # with the rest of the verification surface so "how long has this waited" has
  # exactly one definition.
  defp awaiting_since(issue) do
    Arbiter.Tasks.Verification.awaiting_since(issue) || created_at(issue)
  end

  defp waiting_cards(workers, issues_by_id, watchdog_live, all_workers) do
    workers
    |> one_row_per_task()
    |> Enum.map(fn {w, group} ->
      w
      |> base_card(issues_by_id)
      |> Map.merge(%{
        reason: waiting_reason(w),
        mr_ref: Map.get(w, :mr_ref),
        merger_url: Map.get(w, :merger_url),
        merger_status: get_meta(w, :last_merger_status),
        # bd-741sid: no run stays resident on an open PR, so a worker card has
        # no Watchdog of its own to report — a Merging ticket's card does.
        watchdog_alive: nil,
        merge_pulled: false,
        # The collapsed rows keep their vote: a dead fix pass under a
        # legitimately-parked primary still needs a human, even though the
        # primary row alone reads as "the machine has this".
        needs_you: child_needs_you?(group, watchdog_live),
        collapsed_note: collapsed_note(w, group),
        since: since(w)
      })
      |> with_phase(w, all_workers)
    end)
  end

  # bd-aw2cyt: what the card is *actually* doing, and whether anything is
  # burning quota for it. Two separate facts on purpose — `:in_review` names
  # the stage, `agent_live` says whether a process exists, and a card with a
  # stage but no process is exactly the thing this ticket made visible.
  defp with_phase(card, worker, all_workers) do
    subordinates = Phase.subordinates_of(worker, all_workers)

    Map.merge(card, %{
      phase: Phase.of(worker, all_workers),
      agent_live: Phase.any_agent_live?(worker, subordinates)
    })
  end

  # A card with no worker behind it at all: nothing is running, and a human is
  # the only thing that moves it.
  defp workerless_phase(card),
    do: Map.merge(card, %{phase: :waiting_on_you, agent_live: false})

  # What the collapsed subordinate rows say that the primary row's own fields
  # cannot: a `:failed` fix pass / conflict pass under the card. Nil when
  # nothing was collapsed away, or when the surviving row is itself the
  # subordinate (its own outcome already says it).
  defp collapsed_note(primary, group) do
    group
    |> Enum.reject(&(&1 == primary))
    |> Enum.filter(&failed_run?/1)
    |> Enum.map(&(Arbiter.Worker.subordinate_label(&1) || "subordinate pass"))
    |> Enum.uniq()
    |> case do
      [] -> nil
      labels -> Enum.join(labels, ", ") <> " failed"
    end
  end

  # One task, one card (bd-8jixav). A task's primary row and a subordinate
  # fix / conflict pass's row can both be parked, so the column used to render
  # one task as two cards that read at a glance as two different stuck
  # tickets.
  #
  # The primary row (`role: nil`) wins where both exist: it is the one holding
  # the MR, and the one whose fields the card's actions address. `Enum.min_by`
  # returns the first row of the minimal rank, so among rows of the same rank
  # the caller's order survives.
  #
  # Returns `{primary_row, all_rows_for_the_task}`: the card renders the
  # primary's fields, but the whole group is still there for the signals a
  # collapsed row would otherwise take with it (its `needs_you?` vote, its
  # failure).
  defp one_row_per_task(workers) do
    workers
    |> Enum.group_by(& &1.task_id)
    |> Enum.map(fn {_task_id, group} -> {Enum.min_by(group, &subordinate_rank/1), group} end)
  end

  defp subordinate_rank(worker), do: if(is_nil(Map.get(worker, :role)), do: 0, else: 1)

  # bd-2mv3lx: an in-progress (or merging) ticket with no live worker — e.g.
  # `arb worker stop`, the documented pre-flight for `arb server deploy` —
  # used to vanish from the board
  # entirely. It reads truest as Waiting: the work is out of the machine's
  # hands, and nothing will retry it on its own, so it always flags
  # `needs_you`. Past the dispatch grace only; inside it the ticket is a
  # Running "dispatching" card (`Lifecycle.board_column/2`).
  defp orphaned_cards(issues) do
    Enum.map(issues, fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        status: :in_progress,
        reason: orphan_reason(issue),
        mr_ref: Map.get(issue, :pr_ref),
        merger_url: nil,
        merger_status: nil,
        # No live worker at all, so no Watchdog is expected either — the card
        # already says "worker stopped", which is the stronger statement.
        watchdog_alive: nil,
        merge_pulled: false,
        needs_you: true,
        collapsed_note: nil,
        since: Map.get(issue, :updated_at) || created_at(issue)
      }
      |> workerless_phase()
    end)
  end

  # bd-6lvc1r: names the park when one is on record (`review_park_reason`,
  # e.g. `resume_blocked`) so a card produced from a stale/terminal worker row
  # reads as a specific park rather than the generic "gone" message a truly
  # workerless issue gets.
  defp orphan_reason(issue) do
    case Map.get(issue, :review_park_reason) do
      reason when is_binary(reason) and reason != "" ->
        "review-parked (#{reason}) — resume or close"

      _ ->
        "worker stopped — resume or close"
    end
  end

  # A parked worker says why; any other row on a Waiting card (an open MR, or
  # a run still live on a merging ticket) has no halt to report.
  defp waiting_reason(worker) do
    if waiting_on_question?(worker) or failed_run?(worker), do: halt_reason(worker)
  end

  @doc """
  Whether a single live worker row needs the operator: a run `:waiting` on a
  question, a run finished `:failed` (a park), or an open MR blocked for a
  reason outside the Watchdog's auto-resolvable set. `alive` is the ticket's
  Watchdog-liveness bit — `false` always flags, since nothing is polling the
  MR.

  Public (bd-58z2tu) so `Arbiter.Tasks.EpicRollup` can classify a child's
  worker the same way the board's Waiting column does, through
  `child_needs_you?/2`, rather than re-deriving the rule.
  """
  @spec needs_you?(map(), boolean() | nil) :: boolean()
  # bd-8jixav: the MR is open and *nothing is polling it*. This outranks every
  # block-reason nuance below — a `:ci_failed` block the Watchdog would
  # ordinarily clear by itself is not getting cleared by a process that no
  # longer exists.
  def needs_you?(_worker, false), do: true

  def needs_you?(worker, _alive) do
    cond do
      # A question has no retry, so it is always the human's.
      waiting_on_question?(worker) -> true
      # A parked worker is terminal — the system has exhausted itself by
      # definition, whatever its last poll happened to record.
      failed_run?(worker) -> true
      true -> blocked_for_you?(get_meta(worker, :last_merger_status) || %{})
    end
  end

  defp blocked_for_you?(merger_status) do
    case Watchdog.effective_block_reason(merger_status) do
      # No block the forge will admit to: the MR is simply mid-review, which is
      # still the machine's turn.
      nil -> false
      reason -> reason not in @auto_resolving_block_reasons
    end
  end

  @doc """
  Whether any of a task's live worker rows need the operator — the
  collapsed-group vote `waiting_cards/3` casts for a card, factored out so
  `Arbiter.Tasks.EpicRollup` can cast the same vote for an epic's child
  (bd-58z2tu). Pass every worker row for the task (a collapsed primary plus
  any subordinate fix/conflict pass), not just the primary, so a failed fix
  pass under a legitimately-parked primary still counts. An empty list reads
  as `false` — a child with no live worker at all is not this function's
  question; the caller decides what "no worker" means for it.

  `watchdog_live` is accepted for the callers' convenience and not consulted:
  since bd-741sid no worker row holds an open PR, so no row has a Watchdog of
  its own — a Merging ticket's Watchdog is `merging_needs_you?/3`'s question.
  """
  @spec child_needs_you?([map()], MapSet.t() | nil) :: boolean()
  def child_needs_you?(workers, _watchdog_live) do
    Enum.any?(workers, &needs_you?(&1, nil))
  end

  # ---- parent refs (bd-38of5i) ---------------------------------------------
  #
  # Design bd-2s901b §4: epics are gone from every column, so a child card is
  # the only place on the board an epic stays discoverable. Every card carries
  # a ref to its parent — id, title and the parent's own child progress —
  # which the view renders as a compact `↳ bd-epic` chip.
  #
  # Counts are derived from the edges and the issues already in hand rather
  # than from `Issue`'s `child_total` / `child_closed` calculations: the board
  # has read every issue anyway, and a pure `derive/1` must not go to a repo.

  defp with_parents(cards, parents) do
    Enum.map(cards, &Map.put(&1, :parent, Map.get(parents, &1.id)))
  end

  # ---- over-budget flag (bd-8j9i9p) ----------------------------------------
  #
  # Every card carries the key, `false` where it doesn't apply, so the view
  # reads one field everywhere instead of branching on which column built the
  # card — the same shape rule the parent ref follows.

  defp over_budget_set(nil), do: MapSet.new()
  defp over_budget_set(%MapSet{} = set), do: set
  defp over_budget_set(ids) when is_list(ids), do: MapSet.new(ids)

  defp with_over_budget(cards, nil),
    do: Enum.map(cards, &Map.put(&1, :over_budget, false))

  defp with_over_budget(cards, set),
    do: Enum.map(cards, &Map.put(&1, :over_budget, MapSet.member?(set, &1.id)))

  defp with_over_budget_in_entries(entries, set) do
    Enum.map(entries, fn entry ->
      %{entry | card: Map.put(entry.card, :over_budget, MapSet.member?(set, entry.card.id))}
    end)
  end

  # A Ready entry wraps its card; the ref belongs on the card, where every
  # other column's ref lives, so the view reads one key everywhere.
  defp with_parents_in_entries(entries, parents) do
    Enum.map(entries, fn entry ->
      %{entry | card: Map.put(entry.card, :parent, Map.get(parents, entry.card.id))}
    end)
  end

  defp parent_refs([], _issues_by_id), do: %{}

  defp parent_refs(parent_of, issues_by_id) do
    pairs = Enum.uniq(parent_of)
    children_by_parent = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))

    pairs
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.reduce(%{}, fn {child_id, parent_ids}, acc ->
      case pick_parent(parent_ids, issues_by_id) do
        # A dangling edge (the parent is not among the issues the board read)
        # is not a chip: better none than one linking to a blank title.
        nil -> acc
        parent -> Map.put(acc, child_id, parent_ref(parent, children_by_parent, issues_by_id))
      end
    end)
  end

  # One card has room for one chip. Multiple `parent_of` parents are unusual
  # but legal, so it takes the most recently updated one — the same tie-break
  # the detail page's banner stacks by, so the two surfaces agree on which
  # parent leads.
  defp pick_parent(parent_ids, issues_by_id) do
    parent_ids
    |> Enum.sort()
    |> Enum.map(&Map.get(issues_by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parents -> Enum.max_by(parents, &parent_recency/1, DateTime)
    end
  end

  defp parent_recency(issue), do: Map.get(issue, :updated_at) || created_at(issue)

  defp parent_ref(parent, children_by_parent, issues_by_id) do
    children = children_by_parent |> Map.get(parent.id, []) |> Enum.uniq()

    %{
      id: parent.id,
      title: Map.get(parent, :title),
      issue_type: Map.get(parent, :issue_type),
      child_total: length(children),
      child_closed: Enum.count(children, &child_closed?(&1, issues_by_id))
    }
  end

  defp child_closed?(child_id, issues_by_id) do
    case Map.get(issues_by_id, child_id) do
      nil -> false
      issue -> Map.get(issue, :status) == :closed
    end
  end

  defp closed_today_cards(issues, columns, now) do
    twenty_four_hours_ago = DateTime.add(now, -24, :hour)

    issues
    |> Enum.filter(fn issue ->
      in_column?(columns, issue.id, :closed) and
        closed_within_24h?(
          Map.get(issue, :closed_at),
          Map.get(issue, :updated_at),
          twenty_four_hours_ago
        )
    end)
    |> Enum.sort_by(&closed_sort_key/1, {:desc, DateTime})
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        closed_at: Map.get(issue, :closed_at) || Map.get(issue, :updated_at)
      }
    end)
  end

  defp closed_within_24h?(%DateTime{} = closed_at, _updated_at, cutoff) do
    DateTime.compare(closed_at, cutoff) != :lt
  end

  defp closed_within_24h?(nil, %DateTime{} = updated_at, cutoff) do
    DateTime.compare(updated_at, cutoff) != :lt
  end

  defp closed_within_24h?(nil, nil, _cutoff) do
    false
  end

  defp closed_sort_key(issue) do
    Map.get(issue, :closed_at) || Map.get(issue, :updated_at)
  end

  defp base_card(worker, issues_by_id) do
    issue = Map.get(issues_by_id, worker.task_id)

    %{
      id: worker.task_id,
      title: (issue && Map.get(issue, :title)) || worker.task_id,
      priority: issue && Map.get(issue, :priority),
      difficulty: issue && Map.get(issue, :difficulty),
      workspace_id: Map.get(worker, :workspace_id),
      # bd-1uu19b: a worker card's status is its run's state; the outcome and
      # what a waiting run waits on ride alongside.
      status: Map.get(worker, :state),
      outcome: Map.get(worker, :outcome),
      waiting_on: Map.get(worker, :waiting_on)
    }
  end

  # A run the Running column shows: live and driving an agent, or waiting on
  # the review gate (a reviewer agent is reading — still the machine's turn).
  defp running_run?(worker),
    do: Map.get(worker, :state) in [:starting, :working] or Worker.awaiting_review_gate?(worker)

  defp waiting_on_question?(worker),
    do: Map.get(worker, :state) == :waiting and not Worker.awaiting_review_gate?(worker)

  defp succeeded?(worker),
    do: Map.get(worker, :state) == :finished and Map.get(worker, :outcome) == :succeeded

  # A finished run that did not succeed: failed, or cut off by the server.
  defp failed_run?(worker),
    do:
      Map.get(worker, :state) == :finished and
        Map.get(worker, :outcome) in [:failed, :interrupted]

  # What the in-flight work has claimed: the issue's declared paths plus
  # whatever the worktree has actually changed. The union matters — a worker
  # ten minutes in has touched files its ticket never named.
  # bd-6bax7s: everything a `:conflicts_with` counterpart must not run beside,
  # as `%{task_id => state}`. Wider than `in_flight/3`, which answers the *file*
  # question and so only counts slot-holders: a Merging counterpart holds an
  # open MR rather than a slot, and is still very much mid-flight as far as a
  # declared mutex is concerned.
  #
  # Three sources, in increasing authority:
  #
  #   * an issue flipped to `:in_progress` whose worker has not registered yet
  #     (inside `@orphan_grace_seconds`) — the window the bd-1780 incident
  #     dispatched into. Past the grace it reads as *orphaned* instead, and
  #     releases the mutex: nothing is going to retry it on its own, so holding
  #     its counterpart hostage would strand both.
  #   * a Merging ticket (bd-741sid): its PR is open and no worker stays on
  #     it, however long ago it opened.
  #   * a reviewer / implementer worker, claiming on behalf of the author it
  #     works for — covers a fix pass whose author worker has already gone.
  #   * the author's own live worker, which knows its run state exactly.
  #
  # A counterpart that is `:closed`, parked at `:awaiting_verification`
  # (merged — the worktree is gone, nothing left to collide with) or whose run
  # finished (parked, terminal) appears in none of them.
  defp conflict_claims(authors, gate_workers, issues, worked, now) do
    issues
    |> Enum.filter(&mid_dispatch?(&1, worked, now))
    |> Map.new(&{&1.id, @dispatching_state})
    |> Map.merge(
      for i <- issues, Lifecycle.state_of(i) == :merging, into: %{}, do: {i.id, @merging_state}
    )
    |> Map.merge(Map.new(claims_from(gate_workers, &gate_author/1, &gate_state/1)))
    |> Map.merge(Map.new(claims_from(authors, & &1.task_id, &author_state/1)))
  end

  defp claims_from(workers, id_fun, state_fun) do
    Enum.flat_map(workers, fn w ->
      case {id_fun.(w), state_fun.(w)} do
        {nil, _} -> []
        {_, nil} -> []
        {id, state} -> [{id, state}]
      end
    end)
  end

  defp author_state(worker) do
    case Map.get(worker, :state) do
      :starting -> if resumed?(worker), do: "resuming", else: "running"
      :working -> "running"
      :waiting -> if Worker.awaiting_review_gate?(worker), do: "in review", else: "awaiting input"
      _finished -> nil
    end
  end

  defp resumed?(worker), do: get_meta(worker, :resume) == true

  defp gate_state(worker) do
    case worker_role(worker) do
      :implementer -> @fix_pass_state
      _ -> @reviewer_state
    end
  end

  # The inverse of `orphaned?/3` for an `:in_progress` issue: young enough that
  # the missing worker reads as "still provisioning", not "stopped".
  defp mid_dispatch?(issue, worked, now) do
    issue.status == :in_progress and
      not dispatchable_type_excluded?(issue) and
      not MapSet.member?(worked, issue.id) and
      DateTime.diff(now, Map.get(issue, :updated_at) || created_at(issue)) <
        @orphan_grace_seconds
  end

  defp in_flight(workers, issues_by_id, changed) do
    workers
    |> Enum.filter(&(Map.get(&1, :state) in @slot_states))
    |> Enum.map(fn w ->
      declared =
        case Map.get(issues_by_id, w.task_id) do
          nil -> MapSet.new()
          issue -> FileScope.declared_paths(issue)
        end

      %{
        task_id: w.task_id,
        scope: MapSet.union(declared, MapSet.new(Map.get(changed, w.task_id, [])))
      }
    end)
  end

  defp activity(w, gate_worker) do
    if Worker.awaiting_review_gate?(w),
      do: review_activity(w, gate_worker),
      else: live_label(w) || "working"
  end

  defp review_activity(w, gate_worker) do
    case gate_worker && round_label(gate_worker.task_id, w.task_id) do
      nil ->
        case gate_worker && live_label(gate_worker) do
          nil -> "in review"
          label -> "in review · #{label}"
        end

      phase ->
        case live_label(gate_worker) do
          nil -> phase
          label -> "#{phase} · #{label}"
        end
    end
  end

  # While an author waits on the review gate, the gate worker (reviewer or
  # implementer) is the one actually running for the issue, so its provider
  # is what the card shows — not the waiting author's.
  defp card_provider(worker, %{} = gate_worker) do
    if Worker.awaiting_review_gate?(worker),
      do: Worker.provider(Map.get(gate_worker, :meta)),
      else: Worker.provider(Map.get(worker, :meta))
  end

  defp card_provider(worker, _gate_worker), do: Worker.provider(Map.get(worker, :meta))

  # A reviewer/implementer's synthetic id is `<base>#<suffix>` where suffix
  # may itself be a chain (e.g. `#review#impl2`, `#review#r2#v2`) —
  # `Arbiter.Worker.ReviewGate.base_task_id/1` recovers the base id
  # regardless of chain depth; recovering it here is how its card folds onto
  # the original issue's card instead of rendering a second one titled with
  # the raw suffixed id.
  defp gate_author(worker), do: reviews_task(worker) || revises_task(worker)

  # Human-readable round label for a fix-up round actively in progress: a
  # round-2+ reviewer pass (`#r<N>`) or an implementer revise pass
  # (`#impl<N>`). A plain first-round reviewer (`#review`, or a same-round
  # re-prompt `#v<N>`) has no fix-up in progress yet, so it renders as before
  # ("in review") rather than a manufactured "round 1 review".
  #
  # ReviewGate's real synthetic ids chain suffixes onto `#review`
  # (`<base>#review#impl<N>`, `<base>#review#r<N>`, possibly followed by a
  # re-prompt `#v<N>`), so the round marker is not necessarily the first
  # `#`-segment after the base id — it's whichever segment in the chain
  # matches `#impl<N>`/`#r<N>`, found by scanning from the end.
  defp round_label(gate_task_id, base_id) do
    if Arbiter.Worker.ReviewGate.base_task_id(gate_task_id) == base_id do
      gate_task_id
      |> String.split("#")
      |> Enum.drop(1)
      |> Enum.reverse()
      |> Enum.find_value(&parse_round_suffix/1)
    end
  end

  defp parse_round_suffix(segment) do
    cond do
      match = Regex.run(~r/^impl(\d+)$/, segment) -> "round #{Enum.at(match, 1)} implementation"
      match = Regex.run(~r/^r(\d+)$/, segment) -> "round #{Enum.at(match, 1)} review"
      true -> nil
    end
  end

  defp live_label(worker) do
    case get_meta(worker, :activity) do
      %{"label" => label} when is_binary(label) -> label
      %{label: label} when is_binary(label) -> label
      label when is_binary(label) -> label
      _ -> nil
    end
  end

  defp halt_reason(worker) do
    if waiting_on_question?(worker),
      do: get_meta(worker, :await_reason) || "waiting on you",
      else: stop_summary(worker)
  end

  defp stop_summary(worker) do
    case get_meta(worker, :stop_reason) do
      %{summary: summary} when is_binary(summary) -> summary
      %{"summary" => summary} when is_binary(summary) -> summary
      summary when is_binary(summary) -> summary
      _ -> "failed"
    end
  end

  defp worker_role(worker), do: get_meta(worker, :role)
  defp reviews_task(worker), do: get_meta(worker, :reviews)
  defp revises_task(worker), do: get_meta(worker, :revises)

  defp get_meta(worker, key) do
    case Map.get(worker, :meta) do
      %{} = meta -> Map.get(meta, key)
      _ -> nil
    end
  end

  defp since(worker), do: Map.get(worker, :step_started_at) || Map.get(worker, :started_at)

  defp created_at(issue), do: Map.get(issue, :created_at) || ~U[1970-01-01 00:00:00Z]

  # ---- reads ---------------------------------------------------------------

  defp load_issues do
    Ash.read!(Arbiter.Tasks.Issue)
  rescue
    _ -> []
  end

  defp load_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp dependency_rows(opts) do
    if Enum.all?([:blocked_by, :parent_of, :conflicts_with], &Keyword.has_key?(opts, &1)) do
      []
    else
      Ash.read!(Arbiter.Tasks.Dependency)
    end
  rescue
    _ -> []
  end

  # bd-38of5i: `{parent_id, child_id}` for every `:parent_of` row. The board
  # reads every issue anyway, so `derive/1` turns these into per-card refs
  # (title + child progress) without a second query.
  defp parent_of_from(deps) do
    for %{type: :parent_of} = dep <- deps, do: {dep.from_issue_id, dep.to_issue_id}
  end

  # Open gating blockers per issue. The rule itself lives in
  # `Arbiter.Tasks.EdgeGate` (bd-6bax7s); this is only the read that feeds it.
  defp blockers_from(deps, issues) do
    EdgeGate.blockers(deps, issues)
  rescue
    _ -> %{}
  end

  defp default_workspace_id do
    case Arbiter.Quota.default_workspace_id() do
      {:ok, ws_id} -> ws_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_workspace(ws_id) do
    case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp quota_provider(workspace) do
    if workspace, do: Arbiter.Quota.default_provider(workspace), else: :claude
  end

  defp latest_quota(nil, _provider), do: nil

  defp latest_quota(%{id: account_id}, provider) do
    Arbiter.Quota.latest_for_provider(account_id, provider)
  rescue
    _ -> nil
  end

  # P7 (§4.2): the snapshot is the account's, so its thresholds are too —
  # the board would otherwise report headroom the dispatch gate has already
  # closed whenever the account's threshold is stricter than the workspace's.
  defp quota_account(ws_id, provider) do
    Arbiter.Accounts.Resolver.get(Arbiter.Quota.account_id(ws_id, provider))
  rescue
    _ -> nil
  end

  # "Exhausted" and "near exhaustion" are different operator problems: the
  # first clears when the window resets, the second clears if you raise the
  # ceiling. A 7d hold is a third: it clears at the weekly reset, days away, so
  # `Arbiter.Quota.Gate.hold_phrase/2` labels it with the window explicitly
  # (`7d quota 0.91 ≥ 0.90`) rather than reusing the 5h wording (bd-1tuxv8).
  defp describe_quota(snapshot, policy) do
    case Arbiter.Quota.Gate.hold_phrase(snapshot, policy) do
      nil -> :ok
      phrase -> {:hold, phrase}
    end
  end
end
