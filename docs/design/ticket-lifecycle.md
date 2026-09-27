# Ticket Lifecycle — Design Document

**Status:** in progress — children 1 (stored state) and 2 (the view) of 13 implemented
**Last updated:** 2026-09-27
**Epic:** bd-9yqspm (refined with the operator on 2026-09-27)
**Code:** `Arbiter.Tasks.Lifecycle` (the table), `Arbiter.Tasks.Issue` (the
actions), `Arbiter.Tasks.Issue.Changes.Transition` (applies a transition),
`Arbiter.Tasks.Lifecycle.View` (the projection every surface reads)

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
| `Worker.finalize_opened_mr/5`, and the `MergeQueue` opening or adopting a PR, via `Issue.pr_opened/2` | `open_pr` if the ticket is `active`, with the ref in the same write |
| `MergeQueue.FixPassDispatcher` / `.ConflictResolver`, once the pass is spawned | `return_to_work` if the ticket is `merging` (`Issue.back_to_work/1`) |
| `Tasks.Verification.finalize_merged/2` | `await_verification` (flagged) or `close` |
| `Tasks.Verification.observed/2` / `failed/2` | `close` / `reopen` |

The `task_state` event and the PubSub `"tasks"` message carry `state` and
`close_reason` beside `status`, and so do `GET /api/issues/:id` (so
`arb issue show --json`) and MCP `task_show` in its full view.

### The overlap

These are the rules that hold only while `status` still exists (they go with
it in bd-36ytcl):

- **Legacy `status` writes carry the state.** `:update` refuses `state`,
  `close_reason` and `rank` outright. But a few writers still set `status`
  directly, for moves the table has no transition for: a requeue (in_progress
  → open, from `Worker.AuthDeath` and the board's drag back to Ready), an
  operator's status edit (`arb update --status`, MCP `task_update`, the task
  page), and `:return_to_backlog` on an in-progress ticket whose worker
  already stopped (bd-2098). `Changes.FollowLegacyStatus` re-derives `state`
  from the row by the backfill rule, so the two never disagree. It is the only
  writer of `state` besides the transitions and `:create`.
- **A manual dispatch from Backlog** has no transition either: bd-asxw4e puts
  it behind `--force`. Until then, `Issue.start_work/2` keeps its legacy
  single write (`status: :in_progress`), and the state follows it to `active`.
- **`await_verification` is stricter than the old status guard**, which
  allowed `open`. A merge that lands while its ticket sits in the queue (a
  requeue after the PR opened, or a merge by hand) is put to work first by
  `finalize_merged/2` (`start_work/2`), so it still parks for verification.
- **`reopen` lands in `queued`**, so a reopened ticket is refined whatever it
  was when it closed. The old reopen left `refined` alone.
- **After a fix or conflict pass** the ticket stays `active` until it merges.
  Moving it back to `merging` when the pass finishes is bd-741sid's, along
  with the rest of the run model.

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
| `Issue.ready/1` (`task_ready`, `GET /api/issues/ready`, `arb ready`, `arb prime`) | open + no open blocker, ignoring `refined` | exactly the tickets whose column is `:ready` |

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

Until the seven-column board (bd-79w1fs), `Lifecycle.board_column/2` maps the
columns onto today's five:

| board | lifecycle |
|---|---|
| Backlog | `backlog` |
| Ready | `blocked` + `ready` (blocked cards keep their reason) |
| Running | `in_progress` whose primary author run is live, or still inside the 60 s dispatch grace |
| Waiting | `merging`, `verifying`, and `in_progress` whose primary author run is `awaiting`, `failed` or `awaiting_review`, or gone past the grace |
| Closed | `closed` |

The primary author row decides, not a subordinate fix or conflict pass
sharing its id; a ticket gets exactly one card.
