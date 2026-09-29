# Ticket Lifecycle — Design Document

**Status:** in progress — children 1 (stored state), 2 (the view), 3 (the scheduler) and 4 (PR state and the Watchdog on the ticket) of 13 implemented
**Last updated:** 2026-09-27
**Epic:** bd-9yqspm (refined with the operator on 2026-09-27)
**Code:** `Arbiter.Tasks.Lifecycle` (the table), `Arbiter.Tasks.Issue` (the
actions), `Arbiter.Tasks.Issue.Changes.Transition` (applies a transition),
`Arbiter.Tasks.Lifecycle.View` (the projection every surface reads),
`Arbiter.Tasks.Lifecycle.Dispatchable` (the dispatch-eligibility predicate),
`Arbiter.Tasks.SlotGate` (the slot count), `Arbiter.Tasks.PullRequest` (the
ticket's open PR), `Arbiter.Worker.Watchdog` (the ticket's merge watch)

---

## Why

A ticket's state used to be spread over fields that overlap and disagree:
`status`, the `refined` flag, the ReviewGate park flag, and the
`awaiting_verification` status and its verification fields. Nothing answered
"what state is this ticket in, and does anything need attention?" The survey
on 2026-09-27 found:

- three column classifiers that disagree (`Board.Snapshot.derive/1`,
  `Snapshot.column_for/3`, `EpicRollup.bucket/1`) and four "Ready" predicates;
- slots held invisibly through `waiting_ci_merge`, `in_review`, `handing_off`
  and `:unknown`;
- two worker vocabularies (the GenServer FSM and `Run` rows), so `worker list`
  and `worker show` disagree, and an implementer that stays resident because
  it is the only home of an open PR's state;
- a stale author row hiding an open ticket from every column;
- escalations that never clear themselves and are told apart only by subject
  text;
- `awaiting_verification` blocking dependents;
- a manual `ready_order` that only the LiveView knows, so Autopilot ignores it.

The redesign gives every ticket **one stored state**, changed only by named
transitions. Everything finer than that is computed, and attention is an
overlay on the state rather than another state.

---

## 1. Stored state

| state | meaning |
|---|---|
| `backlog` | filed, not refined — never dispatched automatically |
| `queued` | refined; waiting for a slot |
| `active` | holding a slot: a run is working on it |
| `merging` | its PR is open and the merge path owns it |
| `verifying` | merged; waiting for the post-merge restart-and-observe |
| `closed` | done — `close_reason` says how |

- **`close_reason`** is `completed | wont_do | duplicate`. The close transition
  sets it (`completed` when none is given), and it is nil in every other
  state, so `reopen` clears it.
- **The step is computed.** Anything finer than the state — for example,
  which run is working on the ticket, or what its open PR is waiting on — is
  derived, never stored.
- **`rank`** is the manual order inside a priority band. Backlog and Ready sort
  by priority, then rank, and Autopilot dispatches in the same order. Dragging
  a card across priority bands changes its priority.

## 2. Transitions

The state changes only through these named actions on `Issue`:

| transition | from → to |
|---|---|
| `promote` | backlog → queued |
| `demote` | queued → backlog |
| `start` | queued → active |
| `open_pr` | active → merging |
| `return_to_work` | merging → active |
| `await_verification` | active \| merging → verifying |
| `close` | any non-closed → closed |
| `reopen` | closed \| verifying → queued |

```
            promote          start            open_pr
  backlog ──────────► queued ──────► active ──────────► merging
          ◄──────────   ▲             ▲  ◄──────────────   │
            demote      │             │   return_to_work   │
                        │             └────────┬───────────┘
                        │                      ▼ await_verification
                        ├──── reopen ──── verifying
                        └──── reopen ──── closed  ◄── close, from any other state
```

Any pair not in the table is refused. A **no-PR ticket** (`task`, and
`research` once bd-9s9dqz adds it) goes active → closed or active → verifying
directly. The table already allows both, since `close` and
`await_verification` accept `active` for every type.

## 3. Board columns

The board has seven columns: **Backlog, Blocked, Ready, In progress, Merging,
Verifying, Closed**.

| state | column |
|---|---|
| `backlog` | Backlog |
| `queued` | **Blocked** or **Ready**, computed from the ticket's dependency edges |
| `active` | In progress |
| `merging` | Merging |
| `verifying` | Verifying |
| `closed` | Closed |

- `verifying` does **not** block dependents: a blocker that has merged and is
  waiting on its verification no longer holds its dependents back.
- Transient scheduler holds stay in Ready, with a reason. They are not a
  column.
- Epics stay off the board.

## 4. Attention is an overlay, not a column

A ticket keeps its column and gains
`attention: {owner: coordinator | operator, waiting_on, reason}`.

- **The coordinator comes first.** The coordinator inbox is the coordinator
  agent's queue, not the operator's. An item reaches the operator only by an
  explicit hand-off, or when a limit expires.
- **Ticket-scoped escalations clear automatically** when the ticket's state
  changes. Escalations have typed kinds instead of being told apart by
  subject text.
- **System alerts** — not tied to a ticket — are separate, and clear when
  their condition clears.
- The board gets a toggleable **Needs-attention swimlane**. It shows
  operator-owned items by default, and a chip adds the coordinator's.

The ReviewGate park (`review_park_reason` / `review_parked_at`) becomes
attention too (bd-8if9zt).

## 5. Slots

- **In progress is exactly the set of tickets holding a slot.** No slot is
  held from anywhere else, and none invisibly.
- **Merging and Verifying release the slot.** This replaces the 2026-09-21
  rule "another slot doesn't open until the issue occupying it is merged".
- **A CI failure or a conflict moves the ticket back to In progress**
  (`return_to_work`), and its run takes the fast lane, ahead of Ready.
- **Manual dispatch** of a Backlog or Blocked ticket requires `--force`.

## 6. Runs

- **A run is one attempt at a ticket, and never describes the ticket.**
- **Every worker stops when its agent stops**, the implementer included. PR
  state and the Watchdog live on the ticket, not on a resident worker.
- One run vocabulary:
  - kind: `implement | review | fix_pass | conflict`;
  - state: `starting | working | waiting | finished`;
  - outcome: `succeeded | failed | interrupted | handed_off`.

`worker list` and `worker show` read the same thing.

## 7. Types and vocabulary

- `research` is added beside `task`. Both are no-PR types: `research` must
  record findings, and `task` is an operational action (bd-9s9dqz).
- "Issue" becomes **ticket** in user-facing surfaces, with one-release aliases.
  Internals keep their names (bd-4jojpw).

---

## Rollout

The children run mostly in series: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → {9, 10} →
11 → 13 → 12. They share `worker.ex`, `coordinator_notifier.ex` and
`mcp/catalog.ex`, and Autopilot does not honour `conflicts_with` (bd-6bax7s).

| # | id | scope |
|---|---|---|
| 1 | bd-842qio | stored `state`, named transitions, `close_reason`, `rank`, row migration, legacy dual-write |
| 2 | bd-6zapbl | one `Lifecycle.view` projection replaces the three column classifiers and four Ready predicates; Verifying unblocks dependents |
| 3 | bd-asxw4e | slot = ticket In progress; one dispatch-eligibility predicate; `--force` for Backlog/Blocked; priority + rank order |
| 4 | bd-741sid | PR state and the Watchdog move to the ticket; the implementer stops with its agent; fix/conflict passes are ordinary runs; fast lane |
| 5 | bd-1uu19b | one run vocabulary; `worker list` = `worker show` |
| 6 | bd-8if9zt | the attention overlay and typed escalation kinds; auto-clear on a state change |
| 7 | bd-8nlez1 | coordinator-first ownership, hand-off, escalation limits, computed coordinator queue |
| 8 | bd-7gt8rm | system alerts that aren't tied to a ticket and clear with their condition |
| 9 | bd-79w1fs | seven-column board, Needs-attention swimlane, drag-to-rank |
| 10 | bd-6fkgvo | CLI / MCP / `arb prime` / events / seed skills on the new vocabulary |
| 11 | bd-4jojpw | issue → ticket in user-facing surfaces, with one-release aliases |
| 13 | bd-9s9dqz | the no-PR type split: `research` vs `task` |
| 12 | bd-36ytcl | delete the superseded fields, statuses and classifiers |

---

## Child 1 (bd-842qio): the stored state

### Columns

Migration `20260927184052_add_lifecycle_state_to_issues` (hand-written; the
Ash resource snapshots are stale) adds:

- `state` — non-null, default `backlog`;
- `close_reason` — nullable;
- `rank` — non-null, default 0. A new ticket is ranked one step past the
  highest rank in its workspace (`Changes.AssignRank`), so it sorts after
  every ticket with its priority. Ranks run per workspace rather than per band
  so that a priority change keeps creation order, exactly as the old
  priority-then-age order did. They are spaced 1024 apart, so drag-to-rank can
  drop a card between two neighbours by writing one row.

### Legacy dual-write

Consumers keep reading `status` and `refined` until the later children switch
them, so every transition also writes them:

| state | status | refined |
|---|---|---|
| backlog | open | false |
| queued | open | true |
| active / merging | in_progress | true |
| verifying | awaiting_verification | true |
| closed | closed | unchanged |

### Backfill

Every existing row got its state from its legacy columns
(`Lifecycle.legacy_state/1` is the same rule in code, and the migration test
checks that the two agree):

| existing row | state | other |
|---|---|---|
| open, refined false | backlog | |
| open, refined true | queued | |
| in_progress with `pr_ref` or a non-empty `pending_merge` | merging | |
| other in_progress | active | |
| awaiting_verification | verifying | |
| closed | closed | `close_reason: completed` |

A rehearsal on a snapshot of the live install DB (1,287 tickets, 2026-09-27)
gave backlog 63, queued 18, active 2, merging 3, verifying 12 and closed 1,189.
It left no null state and no rank out of creation order.

### Who calls which transition

| caller | transition |
|---|---|
| `:promote_to_ready` / `:return_to_backlog` (the legacy doors: `arb promote`/`demote`, MCP, the task page) | `promote` / `demote`, idempotent as before |
| `Worker.Dispatch.transition_to_in_progress/2` via `Issue.start_work/2` | `start` |
| `Worker.finalize_opened_mr/5`, and the `MergeQueue` opening or adopting a PR, via `Issue.pr_opened/3` | `open_pr` if the ticket is `active`, with the ref (and, since bd-741sid, its URL and lane) in the same write |
| `MergeQueue.PassAdmission`, admitting a fix or conflict pass into a slot (bd-741sid) | `return_to_work` if the ticket is `merging` (`Issue.back_to_work/1`), the moment the pass is admitted |
| `PullRequest.back_to_merging/1`, when that pass ends, or never starts (bd-741sid) | `open_pr` |
| `Worker.Dispatch`, a resume of a `merging` ticket (bd-asxw4e) | `return_to_work`, once its Watchdog is stopped (bd-741sid) |
| `PullRequest.closed/2`, the PR closed unmerged (bd-741sid) | `pr_closed`: `return_to_work` with `attention_cause: :pr_closed` |
| `Tasks.Verification.finalize_merged/2` | `await_verification` (flagged) or `close` |
| `Tasks.Verification.observed/2` / `failed/2` | `close` / `reopen` |

The `task_state` event and the PubSub `"tasks"` message carry `state` and
`close_reason` beside `status`, and so do `GET /api/issues/:id` (so
`arb ticket show --json`) and MCP `ticket_show` in its full view.

### The overlap

These are the rules that hold only while `status` still exists (they go with
it in bd-36ytcl):

- **Legacy `status` writes carry the state.** `:update` refuses `state`,
  `close_reason` and `rank` outright. But a few writers still set `status`
  directly, for moves the table has no transition for: a requeue (in_progress
  → open, from `Worker.AuthDeath` and the board's drag back to Ready), an
  operator's status edit (`arb update --status`, MCP `ticket_update`, the task
  page), and `:return_to_backlog` on an in-progress ticket whose worker
  already stopped (bd-2098). `Changes.FollowLegacyStatus` re-derives `state`
  from the row by the backfill rule, so the two never disagree. It is the only
  writer of `state` besides the transitions and `:create`.
- **A manual dispatch from Backlog** has no transition either. Since bd-asxw4e
  it needs `--force` (and is recorded); the forced dispatch still goes through
  `Issue.start_work/2`'s legacy single write (`status: :in_progress`), and the
  state follows it to `active`.
- **`await_verification` is stricter than the old status guard**, which
  allowed `open`. A merge that lands while its ticket sits in the queue (a
  requeue after the PR opened, or a merge by hand) is put to work first by
  `finalize_merged/2` (`start_work/2`), so it still parks for verification.
- **`reopen` lands in `queued`**, so a reopened ticket is refined whatever it
  was when it closed. The old reopen left `refined` alone.
- **After a fix or conflict pass** the ticket goes back to `merging`
  (bd-741sid, below).

---

## Child 2 (bd-6zapbl): one projection

`Lifecycle.view(ticket, ctx)` (implemented in `Arbiter.Tasks.Lifecycle.View`)
is pure. It returns `%{state, column, step, blocked_by, attention}`, and
everything it would otherwise have to read arrives in `ctx`: `:blocked_by`
(the unsatisfied gating blockers), `:runs` (the ticket's worker rows),
`:merger_status` (the PR's last poll, defaulting to the author run's) and
`:now`. `attention` is `nil` until bd-8if9zt.

### Who reads it

| surface | before | now |
|---|---|---|
| board (`Board.Snapshot.derive/1`) | worker-first card builders, `queueable?` | `Lifecycle.board_column/2` per ticket; each builder only builds for its own column |
| epic mini-board (`Snapshot.classify_columns/3`) | `column_for/3` | the same `board_column/2` |
| `/epics` rollup (`EpicRollup`) | `bucket/1`, status only | the same `board_column/2`, given the child's live author workers |
| `Issue.ready/1` (`ticket_ready`, `GET /api/issues/ready`, `arb ready`, `arb prime`) | open + no open blocker, ignoring `refined` | exactly the tickets whose column is `:ready` |

`Arbiter.Board.ColumnAgreementTest` runs one ticket per state × {no worker,
live author, completed author row, failed author row} through the first three
and asserts they agree.

### Verifying unblocks dependents

A gating blocker is satisfied once it is `verifying` or `closed`
(`Lifecycle.blocker_satisfied?/1`). `EdgeGate.blockers/2`, `Issue.ready/1` and
`EpicRollup` all use that one predicate, so a merged blocker waiting on its
post-merge check no longer holds its dependents — nor counts as a needs-you
cause on `/epics`.

### Runs never set the column — with one exception

A leftover `completed` or `failed` author row on a `queued` ticket leaves it
Ready or Blocked; it used to hide the ticket from every column. The one
exception is a **live** author run on a `backlog` or `queued` ticket: dispatch
moves the ticket to `active` before its run starts, so that pair means the
stored write lags a run that is already working, and the ticket reads as in
progress. `Issue.ready/1` passes no runs, so for that window it still lists
the ticket.

### Step

- In progress: `implementing | in_review | addressing_review | fixing_ci |
  resolving_conflict`, from `Arbiter.Worker.Phase` over the runs — a live
  subordinate round wins, and `implementing` is the default.
- Merging: `behind_base` for a PR behind its base; `merge_blocked` for a
  conflict, red CI, a draft, or an approved PR the forge still refuses;
  `waiting_ci` while CI runs (or a deferred merge on record is `ci_pending`);
  otherwise `in_merge_queue`.

### The interim board

`Lifecycle.board_column/2` maps the columns onto five. The board itself moved
to the seven lifecycle columns in bd-79w1fs (Child 9 below); this mapping
remains for the epic mini-board and the `/epics` rollup:

| board | lifecycle |
|---|---|
| Backlog | `backlog` |
| Ready | `blocked` + `ready` (blocked cards keep their reason) |
| Running | `in_progress` whose primary author run is live, or still inside the 60 s dispatch grace |
| Waiting | `merging`, `verifying`, and `in_progress` whose primary author run is `awaiting`, `failed` or `awaiting_review`, or gone past the grace |
| Closed | `closed` |

The primary author row decides, not a subordinate fix or conflict pass
sharing its id; a ticket gets exactly one card.

---

## Child 3 (bd-asxw4e): the scheduler on ticket state

### A slot is a ticket In progress

`SlotGate.slots_used/1` counts the tickets whose stored state is `:active`
(`holds_slot?/1`; epics never count). The worker rows are not an input:

| ticket | before (author row's `Worker.Phase`) | now |
|---|---|---|
| between ReviewGate rounds, no agent live | held (`handing_off`) | held — `:active` (bd-45pwo1 still holds) |
| parked on a human (`:waiting_on_you`) | **released** | held — `:active`, with attention |
| open PR (`waiting_ci_merge`) | held | released — `:merging` |
| `:unknown` liveness probe | held | whatever the state says |
| merged, waiting on verification | released | released — `:verifying` |

This replaces the operator's 2026-09-21 rule "another slot doesn't open until
the issue occupying it is merged" (confirmed 2026-09-27). The board header's
`slots_used`, `scheduler_status` (`Board.Drain.status/1`: `slots_used`,
`slot_holders`; `arb scheduler status` prints them) and `ResumeSlot` all read
this one count. `conductor_slot_basis` now only changes `agents live`.

The count is fleet-wide, like the board it sits on: the cap it is measured
against is the default workspace's (#1359, unchanged).

### ResumeSlot

A resume of an `:active` ticket needs no new slot, whatever its worker did
(parked, failed mid hand-off, cut off by a restart). Any other state —
`:queued`, `:merging`, `:verifying` — must acquire one: refused for a human at
a full cap (`force` goes over, recorded), deferred to Autopilot for an
automatic caller. An admitted resume of a `:merging` ticket (a revise round on
its PR) moves it back to `:active` (`return_to_work`), so the round holds the
slot it was admitted into. First it stops the ticket's Watchdog and drops the
pending merge it stamped (bd-741sid). Otherwise the Watchdog, which belongs to
the ticket and not to any run, would merge the very head the round is
revising. The round's approved PR open starts a fresh Watchdog on the new
head. A ticket whose Watchdog merged it during the stop is not resumed. The
boot reconciler resumes `:active` tickets first.

### One dispatch-eligibility predicate

`Lifecycle.dispatchable(ticket, ctx)` is `:ok` when the ticket's column is
`:ready` and the scheduler holds nothing against it, else `{:held, hold}`:

| precedence | hold | phrased |
|---|---|---|
| 1 | `{:column, :backlog}` | in Backlog |
| 1 | `{:blocked_by, ids}` | blocked by ids |
| 1 | `{:column, :in_progress \| :merging \| :verifying \| :closed}` | already In progress, … |
| 2 | `{:conflicts_with, id}` | conflicts with id |
| 3 | `{:file_overlap, files, id}` | files in flight on id |
| 4 | `:paused` | scheduler paused |
| 5 | `{:quota, reason}` | the reason |
| 6 | `:no_slot` | no free worker slot |

Every hold is an input; one the caller does not pass is not asked about.

- **`Board.Scheduler.plan/1`** asks it for every Ready card with every hold,
  and keeps its queue semantics on top: only the head carries a board-wide
  hold (quota, slot), paused holds every eligible card, a card's own hold
  never advances the queue position. The card reasons are unchanged.
- **`Worker.Dispatch`** asks it with the ticket's open blockers
  (`EdgeGate.blockers_of/1`) and no scheduler holds — a dispatch that reaches
  it was either planned by the scheduler or is a person overriding it:

  | caller | Backlog / Blocked | In progress / Merging / Verifying | Closed |
  |---|---|---|---|
  | Autopilot (`dispatched_by: "autopilot"`) | refused `task_not_ready` | refused `task_not_ready` | refused |
  | manual (`arb dispatch`, MCP `worker_dispatch`, REST, the task page) | refused `not_dispatchable` with the reason, unless `force` | passes (a re-dispatch) — except Merging, refused `task_awaiting_review` (bd-741sid) | refused |
  | resume, review | passes | passes — except a review of a Merging ticket, refused `task_awaiting_review` | refused |

  A forced dispatch of a Backlog or Blocked ticket writes a `dispatch_forced`
  event (`task_id`, `bypassed`, `column`, `blocked_by`, `dispatched_by`).
  PRPatrol's auto-filed follow-ups are created in Backlog and dispatched at
  once, so they force — recorded as `dispatched_by: "pr_patrol"`.

### Order

`Scheduler.order/1` sorts Ready by priority, then `rank`, then `created_at`
— the order the board shows and Autopilot dispatches in. The LiveView's
session-only `ready_order` hand-ranking is gone: Autopilot never saw it.
Drag-to-rank writes `rank` (bd-79w1fs, Child 9 below).

---

## Child 4 (bd-741sid): PR state and the Watchdog on the ticket

The implementer used to stay resident at `:awaiting_review` after opening its
PR, because it was the only home of the PR's state and the Watchdog was
paired with it. Now the ticket owns the PR, the run ends when its agent
does, and the Watchdog is the ticket's.

### The ticket owns its PR

Migration `20260928000034_add_pr_state_to_issues` adds `merger_url`,
`merger_status`, `merger_checked_at`, `merge_watch`, `review_gate_state` and
the `pr_closed` cause (`attention_cause`, `attention_detail`,
`attention_since` — the first cause bd-8if9zt's overlay will read).
`Arbiter.Tasks.PullRequest` reads and writes them:

| the parked worker held | the ticket holds |
|---|---|
| `mr_ref`, `merger_url` | `pr_ref`, `merger_url` |
| `meta.last_merger_status` / `last_checked_at` | `merger_status` / `merger_checked_at`, written on every poll (`record_merger_status/2`) — no paper-trail version, `updated_at` untouched, announced on `PullRequest.topic/0` rather than `"tasks"` |
| the Watchdog's start options | `merge_watch`, the lane: adapter, repo, `via_review_gate`, `auto_merge` / `force_merge`, the pushed head (`local_head_sha`), poll overrides, `review_only` |
| the reviewed-SHA baseline | `last_reviewed_sha` (the ReviewGate's stamp, as before) and the Watchdog's latched baseline, `merge_watch.reviewed_sha` |
| `meta.awaiting_review_resume_attempts` | `merge_watch.auto_resumes` |
| the ReviewGate round in `meta` | `review_gate_state` |

`GET /api/issues/:id` (so `arb ticket show --json`) and MCP `ticket_show` (full)
carry `merger_url`, `merger_status`, `merger_checked_at` and the attention
fields.

### The run ends at PR open

`Worker.finalize_opened_mr/5` writes the ref, URL and lane in the `open_pr`
write, starts the ticket's Watchdog from the row, marks its run finished and
successful (`result: :pr_opened`) and exits. It does not announce the ticket
done — the merge does. The Driver leaves a `:pr_opened` completion alone and
never cleans up a Merging ticket's worktree. A Watchdog that will not start
pages the coordinator; the PR is on the row, so `arb queue restart-watchdog`
or the next boot watches it.

A review-only coordinator reviewer that approves an existing PR records it
without the transition and with `review_only` on the lane, so its merge
leaves the engagement open (bd-cw3w9p).

### The ticket's Watchdog

It is registered under `<ticket>:watchdog` and started from the row:
`Watchdog.watch/2` at PR open, `restart/2` on a reboot, from an operator or
from the sweeper. `stop/1` takes the PR off the merge path, for a resume
(above) and for the board's pull out of the merge queue. The pull is
`PullRequest.pull/1`: it stops the Watchdog, drops the pending merge and
records `merge_watch.pulled_at`. Every automatic restart honours the mark
(`restart/2` refuses it with `:pulled`: the reconciler, the sweeper, a
finished pass). An operator's restart (the worker page, `arb queue
restart-watchdog`, MCP `queue_restart_watchdog`) passes `clear_pull: true`
and puts the ticket back in the queue, and so does a run that re-opens the PR
with a fresh lane. A pass is not admitted on a pulled ticket.
`Worker.restart_watchdog/1` takes a ticket id. `restart_refusal/2` phrases
every refusal once, for MCP `queue_restart_watchdog`, the REST endpoint (so
the CLI) and the worker page. The Watchdog neither monitors nor calls a
worker, and announces its outcomes on `Watchdog.subscribe/1`:

| the PR | the ticket |
|---|---|
| merged | `Verification.finalize_merged/2` — closed, or verifying when `verify_after_deploy`; `{:worker_done}` to the MergeQueue and the coordinator's "completed" |
| CI failed | a fix pass: `:active`, the pass a run under the ticket id |
| conflicted | a conflict resolver, the same way |
| closed unmerged | `:active` with `attention_cause: :pr_closed`; the coordinator is paged |
| past its poll ceiling, or an unreviewed head | `{:timed_out, n}` / `{:unreviewed_head, sha}` and an auto-resume, its budget on the lane — no worker is failed |

A PR opened before this change has no lane. `watch_opts/1` then uses the
workspace's adapter and puts the PR on the ReviewGate's lane when the gate's
approval stamp (`last_reviewed_sha`) is on the row — without it a restarted
Watchdog would wait on a forge approval an Arbiter-authored PR never gets.

### Fix and conflict passes are ordinary runs, with a fast lane

`MergeQueue.FixPassDispatcher` and `.ConflictResolver` register a pass under
the ticket id (roles `:fix_pass` / `:conflict_resolver`), refuse it beside a
live run on the ticket (`Worker.live_run_refusal/4`, bd-8tjcms), and admit it
through the slot (`MergeQueue.PassAdmission`, `ResumeSlot.admit/2` as an
automatic caller). A free slot moves the ticket back to work before the pass is
provisioned (`PassAdmission.with_slot/2`), so the slot is held from the moment
the pass is admitted rather than from the moment its agent is up. At a full
cap the pass waits in Autopilot's fast lane (kinds `:fix_pass` and
`:conflict`) and starts ahead of every Ready ticket when a slot frees. The
Watchdog knows its pass is queued, not lost. When the pass ends, done or
failed, `PullRequest.back_to_merging/1` returns the ticket to Merging and
restarts its Watchdog if it is gone. It does the same for a pass that never
starts, unless another run holds the ticket by then. A pass whose agent fails
to start is failed rather than left `:idle` holding the ticket's key.

The slot hand-off (`meta[:slot_handoff]`) and `Worker.Phase`'s
`:handing_off` are gone: a ticket In progress is the slot.

### The ReviewGate reports to the ticket

`ReviewGate.deliver_verdict/4` hands a verdict to its author when that run is
still resident. Otherwise it applies it to the ticket: an approval opens the
PR from `review_gate_state` and the gate's context — the bd-3wumco late
approval reconciles the rejected run to completed — and a rejection is
recorded and escalated. A verdict for a round a newer run has superseded is
not applied.

### After a restart

`Reconciler.reconcile_open_pr_tasks/1` starts a Watchdog, from the row and
without escalating, for every Merging ticket that has none, and puts a ticket
whose pass the restart cut off back into Merging. It falls back to the
patrols only when a Watchdog cannot start. `PendingMergeSweeper` gives a
Merging ticket whose lane names its adapter its Watchdog back; a PR from
before lanes gets the worker-less retry, which carries its stamp's baseline.
The retry ends the ticket the way a live Watchdog does: `PullRequest.merged/2`
on a merge, `PullRequest.closed/2` on a PR closed unmerged. Neither the
reconciler nor the sweeper re-arms a ticket pulled out of the merge queue.

### Surfaces

- **Board.** A Merging ticket's Waiting card is built from the ticket
  (`status: :merging`, the PR fields, `watchdog_alive`, phase
  `waiting_ci_merge`). It needs you when its Watchdog is gone, when the
  forge's block is one the Watchdog cannot clear, or when a pass under it
  failed. A ticket pulled out of the merge queue (`merge_pulled`) reads
  "pulled from merge queue", not "no watchdog polling". `/epics` flags a Merging child by the same rule
  (`Snapshot.merging_needs_you?/3`), and the view's Merging step reads the
  ticket's recorded poll.
- **`/merge_queue`.** Queued is the Merging tickets still in the queue (a
  pulled one is not listed); Landed today is the
  tickets merged today (closed completed, or verifying) — not runs, since the
  run that opens a PR completes when the PR opens.
- **The worker page.** The Merge request panel — the no-watchdog warning or
  the pulled notice, Restart watchdog, Retry auto-resolve — is the ticket's,
  with or without a worker.
- **Dispatch.** A plain dispatch of a Merging ticket is refused
  (`task_awaiting_review`): a fresh run would hold no slot while the Watchdog
  could merge underneath it. A resume takes the ticket back to work, and
  stops its Watchdog first.

## Child 5 (bd-1uu19b): one run vocabulary

### The vocabulary

`Arbiter.Workers.RunState` is the one vocabulary the worker GenServer and its
`worker_runs` row share. A worker snapshot and a row both carry `kind`,
`state` and, once `:finished`, `outcome`; neither carries a `status`.

| old | kind / state / outcome |
|---|---|
| `worker_type` main, impl | `implement` (`role` still says `base` / `impl`) |
| `worker_type` review, fix_pass, conflict | `review`, `fix_pass`, `conflict` |
| FSM `idle`, `resuming` | `starting` (a resume keeps `meta.resume`) |
| FSM / row `running` | `working` |
| FSM `awaiting` | `waiting`, `waiting_on: :question` |
| FSM `awaiting_review_gate` | `waiting`, `waiting_on: :review_gate` |
| FSM `awaiting_review` | gone — no run stays resident on an open PR (child 4) |
| `completed` | `finished` / `succeeded` |
| `failed`, `review_parked`, `review_not_started` | `finished` / `failed`; a park's cause is the ticket's `review_park_reason` and the run's `failure_reason` |
| `interrupted` | `finished` / `interrupted` |

`handed_off` is written when a resume starts a new run (`resumed_from_run_id`)
and the prior row is still live. The row follows every state change, not just
start and finish. Migration `20260928131352` backfills `kind`, `state`,
`outcome` (and a NULL `role`) and drops `status` and `worker_type`.

The author waiting on the ReviewGate is still resident, so it is `waiting`
with `waiting_on: :review_gate` rather than gone: a verdict applied to a
resident author is still the common path (`ReviewGate.deliver_verdict/4`).

### `worker list` = `worker show`

`Arbiter.Workers.Current` is the one read. `current_run/3` picks a ticket's
current run — its newest unfinished live run, else its newest registered one,
else its newest row — and `list/1` (REST `GET /api/workers`, MCP
`worker_list`) is that run for every ticket with a live one, while `show/2`
(`GET /api/workers/:task_id`, MCP `worker_show`) adds the recent runs, each
labelled with its kind. A row is read into the same view as a live snapshot,
so there is no history fallback with a vocabulary of its own. A reviewer's run
is reported under its ticket's id and workspace (`run_task_id` keeps its own
`#review` id), which is what puts it in `arb prime`'s active workers.

### After a restart

`Reconciler.reconcile_orphaned_runs/1` sweeps a live row with no worker to
`finished` / `interrupted`, "server restarted" — the server stopped under the
run; it did not fail.

## Child 6 (bd-8if9zt): the attention overlay and typed escalation kinds

### Typed escalation kinds

Every `:escalation` message carries an `escalation_kind` from
`Arbiter.Messages.EscalationKind`, and the `Message` resource refuses an
escalation without one. A kind is **ticket-scoped** (about one `task_ref`) or
**system-scoped** (credentials, quota, budget, the circuit breaker, the loop,
and PRPatrol's failed follow-up dispatch, whose follow-up ticket is closed at
once so the patrol can retry).
System kinds are typed here; their lifecycle is child 8 (bd-7gt8rm).

Producers go through `Arbiter.Messages.Escalation.post/1`. A ticket-scoped
kind is deduplicated by `(kind, ticket)`: while one is open, raising it again
refreshes that row's subject and body, whatever its subject text says.
`Message.last_escalation/2` is the lookup; `last_with_subject/3` is off the
escalation path. `:agent_raised` (sent by hand through `arb message`, MCP
`message_send` or `POST /api/messages`) and `:legacy` (the backfill) are
ticket-scoped but never deduplicated.

### The attention cause

The ticket stores `attention_cause`, `attention_detail` and `attention_since`.
A cause is raised by what knows it: a ReviewGate park (its reason), a PR closed
unmerged (`:pr_closed`), entering verification (`:awaiting_verification`), or
an escalation whose kind names a cause (`EscalationKind.cause/1`:
`:merge_blocked`, `:run_crashed`, `:awaiting_manual_merge`). Only an
`:active`, `:merging` or `:verifying` ticket takes one.

The ReviewGate park moves into the cause. Migration `20260928170000` copies a
known `review_park_reason` / `review_parked_at` into it and backfills every
existing escalation as `:legacy`. The park columns stay as a dual-write until
bd-36ytcl.

### The owner table

`Lifecycle.view/2` fills `attention: %{owner, waiting_on, reason}` (plus the
`cause` and `since` it came from), or nil. The table lives in
`Arbiter.Tasks.Lifecycle.Attention`. The coordinator comes first; a row is the
operator's only when nothing in the fleet can move it.

| cause | owner | waiting on |
|---|---|---|
| a ReviewGate park reason | coordinator | `:review_decision` |
| `:pr_closed` | coordinator | `:pr_decision` |
| `:merge_blocked` | coordinator | `:merge_block` |
| `:merge_blocked`, needing an approval the fleet cannot give | operator | `:approval` |
| `:awaiting_manual_merge` | operator | `:manual_merge` |
| `:run_crashed` | coordinator | `:resume` |
| `:run_asked_question` | coordinator | `:answer` |
| `:awaiting_verification` | coordinator | `:verification` |

A stored cause wins. With none stored, one is derived: `:verifying` →
`:awaiting_verification`; `:merging` with a block the Watchdog does not clear
by itself, or with no Watchdog → `:merge_blocked`; `:active` whose author run
asked a question → `:run_asked_question`; `:active` whose author runs all
failed, or with no run past the dispatch grace → `:run_crashed`. The last one
does not apply while any run on the ticket is live, because a failed run with
a follow-up round under way is still the machine's turn. Child 7 adds the
hand-off and the limits that move an item to the operator.

### Auto-clear

The cause clears, and the ticket's open ticket-scoped escalations are marked
`resolved_at`, when:

- **the ticket transitions.** `Changes.Transition` runs
  `Changes.ClearAttention`, and so does a legacy status write that moves the
  state. An action that raises its own cause (`:pr_closed`,
  `:await_verification`) sets it after the clear.
- **its run restarts.** A resumed run calls `Attention.clear/2`.
- **its park is cleared.** `ReviewPark.clear/2` does the same.

Only escalations inserted before the write started are resolved, so a page
raised by the same write survives.

### The board

The Waiting column's `needs_you` is `attention.owner == :operator`, and every
Waiting card carries its `attention`. A failed run with a follow-up round
under way no longer flags. `EpicRollup` still uses the older worker-status
rule until the epic surfaces move onto attention.

## Child 7 (bd-8nlez1): coordinator-first attention

The coordinator inbox is the coordinator agent's work queue. An attention
item reaches the operator only by an explicit hand-off, or when a
coordinator-owned item stays unresolved past a limit.

### Ownership

The owner table (child 6) is the default. The ticket stores an override —
`attention_owner`, the `attention_owner_cause` it applies to, the
`attention_note` that came with it and `attention_owner_since` — set by
`Arbiter.Tasks.Attention.hand_off/3` or by a promotion, through the
`:set_attention_owner` action. `Lifecycle.Attention.of/2` applies it only
while the ticket's attention is still that cause, and adds `note` and
`owner_since` to the attention map. The override clears with the rest of the
attention (a transition, a run restart, a cleared park), and raising a
different cause drops it.

- **Hand-off.** MCP `ticket_handoff(id, note)`, `POST /api/issues/:id/handoff`,
  `arb ticket handoff <id> --note …`. The note is required; the ticket must have
  attention now, not already the operator's.
- **Hand-back.** MCP `ticket_handback(id, note?)`, `POST /api/issues/:id/handback`,
  `arb ticket handback <id>`, and the *Hand back to coordinator* button on the
  task page's attention strip. The coordinator gets a fresh clock and a fresh
  attempt budget.

`ticket_show` returns the stored fields (full view) and the computed `attention`
map (both views).

### Limits

Workspace config `attention` (`Arbiter.Tasks.AttentionLimits`), read with its
defaults filled in by `workspace_config_get`:

| key | default | |
|---|---|---|
| `coordinator_limit_minutes` | 240 | a coordinator-owned item unresolved this long goes to the operator |
| `run_crashed_max_resumes` | 3 | a `run_crashed` item whose ticket was already resumed this many times out of a failed run goes to the operator |

`0` turns a limit off. `Arbiter.Tasks.AttentionSweep` (every minute, primary
instance only) promotes an item past either limit with the note "coordinator
did not resolve within 4h" / "… within 3 resume attempts". The clock runs from
`attention_since`, or from a hand-back if later. A derived item has no stored
`since`, so the sweep keeps its first-seen time in memory and forgets it when
the item goes; a restart starts that clock again.

Resume attempts are `attention_resume_attempts`: a resumed run whose prior
run failed or was interrupted adds one (`Attention.clear/3`,
`resumed_from_failure: true`); a transition and a hand-back reset it.

`tracker_sync_failed` now records the `:tracker_sync_failed` cause
(coordinator, waiting on `:tracker_sync`), so it follows the same rule. It
yields to a cause the ticket already has, so a failed sync never masks a crash
or a blocked merge. A sync that fails on close has no open ticket to carry the
cause and stays a plain coordinator message.

### The computed queue

`coordinator_inbox` returns `attention` — `Attention.items(owner: :coordinator)`
for the workspace, oldest first — beside its messages, in both states. The
queue has no read or clear state: an item is listed exactly while its ticket's
attention is. `coordinator_inbox_clear` still clears messages.

### Wake-ups

`Attention.announce/3` puts `%{kind: "attention", event, task_id, cause, owner,
note}` on the `inbox` topic when a cause is raised (`Changes.AnnounceAttention`
on `:raise_attention`, `:park_review`, `:pr_closed` and `:await_verification`;
the sweep for a derived item it sees for the first time), promoted, handed off
or handed back.

## Child 8 (bd-7gt8rm): system alerts

A system alert is a problem with the installation rather than a ticket. It is
its own record, `Arbiter.Alerts.SystemAlert` (table `system_alerts`), not an
escalation message:

| field | |
|---|---|
| `kind` | `credential_expired`, `quota_poll_failing`, `overage_alert`, `budget_exceeded` |
| `key` | which one of the kind (below) |
| `workspace_id` | where it is shown and announced; not part of the dedupe |
| `subject`, `detail` | the headline and the full explanation |
| `owner` | always `operator` (bd-9yqspm §3) |
| `raised_at` | when the episode began |
| `last_raised_at`, `raise_count` | when and how often its producer last reported it |
| `cleared_at` | when its condition cleared; nil while active |

At most one row per `(kind, key)` is active, enforced by a partial unique
index. `Arbiter.Alerts.raise_alert/1` refreshes the active row's subject,
detail and `last_raised_at` instead of adding a second; a raise after a clear
opens a fresh episode. Opening and clearing are announced on the workspace's
`inbox` topic as `%{kind: "alert", event: "raised" | "cleared", alert_id,
alert_kind, key, subject, owner}`. A refresh is not announced: producers
re-raise on every check.

### Producers and their clears

The four producers in `CoordinatorNotifier` raise an alert and no longer post
an escalation. Each has a hook where its condition is seen healthy again.

| kind | key | raised by | cleared when |
|---|---|---|---|
| `credential_expired` | adapter and detection source | `CredentialWatchdog` (probe, worker deaths, the usage poll) | the same source succeeds again (`credential_restored/3`) |
| `quota_poll_failing` | `anthropic_oauth_usage` (account-wide) | `Quota.CloudProbe` at the failure threshold | any successful poll (`quota_poll_recovered/0`) |
| `overage_alert` | workspace and provider | `DispatchQueue` on a threshold crossing | the windowed spend is back under the threshold, the threshold is raised or removed (the queue re-reads it on each record), or the gate allows a dispatch on that provider outside overage |
| `budget_exceeded` | task | `Usage.BudgetPatrol`, every sweep while over | the sweep finds the task no longer over its p90 (the estimate moved) or no longer open; a failed sweep clears nothing |

`credential_restored` no longer posts a "restored" message: the clear is the
signal. `operator_login_lapsed` and `quota_grant_failing`, which fire in place
of `quota_poll_failing` for a lapsed login, stay coordinator escalations.
Escalation rows written before this change keep their kinds and are cleared by
hand as before.

### Reading them

`GET /api/alerts` (`?workspace=`, `?kind=`) and the coordinator MCP tool
`alert_list` return the active alerts, oldest first, as `{alerts, count}`.
Child 9 puts them in the Needs-attention swimlane as cards with no ticket.

## Child 9 (bd-79w1fs): the seven-column board

### Columns

`Board.Snapshot.derive/1` returns `backlog`, `blocked`, `ready` (the
scheduler's entries), `in_progress`, `merging`, `verifying` and
`closed_today`, each ticket placed purely by its `Lifecycle.view/2` column;
epics stay off. Only the Ready column is handed to `Scheduler.plan/1` — a
Blocked ticket is held by its dependencies, which the plan would skip over
anyway, so `promote` is unchanged. Every card carries the view's `step` and
`attention`.

| column | card detail |
|---|---|
| Blocked | `waiting on <ids>` |
| Ready | the scheduler's reason; a hold reads `held — …` on the board |
| In progress, Merging | the computed `step` |
| Verifying | awaiting verification |
| Closed | `close_reason`: completed / won't do / duplicate |

In progress holds every `:active` ticket, whatever its run is doing: a parked
or crashed run keeps its card there, wearing the coordinator's attention.

### The Needs-attention swimlane

`derive/1` also returns `attention`: every card with attention, with its
column, owner and reason, operator-owned first. The board shows the
operator's by default; the `+ coordinator` chip adds the coordinator's.
Active system alerts (`Alerts.active/1`) are lane cards with no ticket, and
the board refreshes on the `inbox` topic's `alert` / `attention` events, so a
cleared alert goes on the next update. The lane collapses to a count. Whether
it is open and whether the chip is on are kept per viewer in `localStorage`
by the `.AttentionLane` hook; with no usable storage the lane starts open,
operator-only (`scripts/verify_board_attention_lane.mjs` exercises both).

### Drags

- **Within Backlog or Ready**: re-rank through `Tasks.Rank.move/2`
  (`:set_rank`, bd-djapyj), after the nearest same-workspace card above the
  drop, else before the nearest one below — rank is per workspace. Dropping
  next to a card of another priority first sets the ticket's priority to that
  band. Backlog sorts like Ready: priority, then rank, then age.
- **Backlog → Blocked / Ready**: the `:promote` transition, with its
  acceptance-criteria rule; where it lands is its dependencies' call.
  **Blocked / Ready → Backlog**: `:demote`.
- **Everything else** is refused with a flash — including the old stop-the-
  worker drag out of Running and the Waiting drags: those moves need evidence
  or a deliberate stop, which live on the ticket and worker pages.

---

## Child 10 (bd-6fkgvo): CLI, MCP, `arb prime` and events

Every surface that is not the board reads a ticket through one reader,
`Arbiter.Tasks.Lifecycle.Projection`. It does the reads `Lifecycle.view/2`
needs, once per call — the gating edges and the tickets they point at (a
blocker outside the set still counts), the live runs, each Merging ticket's
Watchdog, the clock — and `payload/1` is the one JSON shape of a view:
`state`, `column`, `step`, `blocked_by`, `attention`.

| surface | reads |
|---|---|
| `GET /api/issues/lifecycle?workspace_id=` | `Projection.open/2`: every open, non-epic ticket, projected, in dispatch order |
| `GET /api/issues/:id` (so `arb ticket show`) | `Projection.view/2`, plus `current_run` (`Workers.Current`, kind/state/outcome/phase) |
| MCP `ticket_show` | the payload, plus `close_reason`, on both views |
| MCP `ticket_list` | new `state` and `column` filters; each row carries the payload |
| MCP `ticket_ready` | `Projection.open/2`, column `:ready` only, dispatch order |
| `task_state` event | `column` and `attention`, beside `state`, `close_reason` and the legacy `status` |

### `arb prime`

Per workspace, after the standing orders: **Needs attention**, **In progress**
(with step), **Merging** (with step and PR), **Verifying** (with the age of the
wait), **Ready** (dispatch order), **Blocked** (with blockers), and a
**Backlog** count; then the live runs and the coordinator inbox. Each ticket
lands in exactly one section: attention wins over the column, with one
exception — a Verifying ticket whose attention is still the coordinator's
`awaiting_verification` is listed under Verifying, since that section *is*
the verification queue. Handed to the operator, it moves up to Needs
attention. Needs attention lists the coordinator's items before the
operator's. The "Review parked" and refined-blind "Ready issues" sections are
gone; `--json` keeps `awaiting_verification` as an alias of `verifying` for
one release and reports the backlog as `backlog_count`.

### The event projects the row, not the runs

The `task_state` event fires from inside the write (`Issue.broadcast_lifecycle/2`),
whose caller may be a worker. Reading the live runs there would call that
worker back, so the event's column and attention come from the row, its
blockers and its Watchdog only. The one thing that loses is the brief window
where a `:queued` ticket already has a live run: the event says Ready where
the board says In progress, until the `start` write that follows.
