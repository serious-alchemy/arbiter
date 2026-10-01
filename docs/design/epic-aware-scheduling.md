# Epic-aware scheduling, so an epic's last 10% gets done: decision

**Task:** bd-1d1yaj (decision, GitHub #201) · **Builds on:** the Ready queue
and its one dispatch-eligibility predicate ([ticket lifecycle](ticket-lifecycle.md)
§1–2; bd-asxw4e, bd-79w1fs), `ticket_transitions` (bd-5gkqdr, bd-d8fi92) ·
**Reconciles with:** [paced quota routing signals](paced-quota-routing-signals.md)
(bd-9ck2a7, epic bd-gfob09; R5, R7 bd-6bxv7h, R10 bd-3jshn8) · **Status:**
proposed 2026-10-01. Nothing here is implemented. The ticket plan is in
[§9](#9-phased-ticket-breakdown). The measurements are reproducible with
[`epic-aware-scheduling/measure_epic_waits.py`](epic-aware-scheduling/measure_epic_waits.py)
([Appendix A](#appendix-a-method)).

## Decision

1. **The Ready order becomes:** effective priority → pinned → finish-first
   class → open leaves left in the epic → own priority → rank → age. Every
   term after effective priority only breaks ties inside one band, so urgency
   across bands is unchanged except where an operator sets a floor. See
   [§4](#4-the-ordering-key).
2. **Option 1, the floor, is adopted as an explicit, opt-in field.** An epic
   gets a nullable `floor_priority` (P1–P3). A ticket's effective priority is
   `min(own, every floor on its parent_of ancestors)`. It does **not** reuse
   the epic's `priority`, because that column is non-null with default P2
   (`apps/arbiter/lib/arbiter/tasks/issue.ex:1174-1180`). Every one of the 40
   epics already carries a priority nobody chose as a floor, so reusing it
   would change today's order on day one. With no floor set, the order is
   exactly today's. See [§6.2](#62-an-unset-floor-changes-nothing).
3. **Option 2, the finish-first tiebreak, is adopted.** Inside a band,
   children of epics already in progress go first, fewest open leaves first
   (shortest remaining work). A card that has waited in Ready for more than
   24 hours (unblocked) escapes the tiebreak. The tiebreak ships off and is
   switched on after a readout. See [§3.2](#32-option-2-finish-first-tiebreak--adopted).
4. **Starvation is bounded four ways.** No floor can be P0, so incidents
   always come first. At most `slots_total − 1` lifted tickets can be in
   flight at once, so one slot always serves unlifted work in its own order.
   The tiebreak never crosses a band, and it yields to 24-hour aging. A floor
   never loosens a quota, eligibility or spend limit. See
   [§3.5](#35-starvation-and-how-it-is-bounded).
5. **Effective priority decides *when*; own priority decides *what may be
   spent*.** The Ready order, the Backlog and Blocked order, the
   DispatchQueue's drain order and R10 defer-until-reset read the effective
   priority. R7's pace exemption and its board hold, R5's time weight
   `w(priority)` and the `routing.rules."P<n>"` model tiers read the ticket's
   own priority. See [§6.4](#64-routing-and-the-quota-gate-own-or-effective).
6. **Option 3, an epic WIP limit, is specified as an opt-in phase 3, off by
   default.** Six to seven epics are started and unfinished at once on most
   days, against 3 slots, so a limit is a real policy change. It waits for
   the phase 1 readout. **Option 4, reserved finishing capacity, is
   rejected.** The lift cap gives the same predictability without idling a
   slot. See [§3](#3-the-options).
7. **Config is install-wide, plus one field per epic.** There is one
   Autopilot and one Ready queue across every workspace
   (`apps/arbiter/lib/arbiter/board/snapshot.ex:337-344`), so the keys that
   shape the order live in installation settings. See [§6.6](#66-config).
8. **The evidence says ordering is only part of the fix.** Tail children do
   wait longer in Ready than head children (median 2.8h vs 0.3h, p90 31h vs
   11h), and they're passed over by newer work almost four times as often.
   But most of a tail child's open time is spent Blocked (30h mean) and in
   Backlog (12h). The two most stalled epics have their last children in
   **Backlog**, where no Ready ordering can reach them. Phase 2 surfaces
   unblocked Backlog children of in-progress epics to the coordinator. See
   [§2](#2-evidence) and [§7](#7-the-backlog-tail).

---

## 1. How Ready work is ordered today

| What | Where | Today |
|---|---|---|
| The order | `Scheduler.order/1`, `order_key/1` (`apps/arbiter/lib/arbiter/board/scheduler.ex:197-206`) | `{priority, rank, created_at}`, ascending. A missing key sorts last |
| The queue | `Scheduler.plan/1` (`scheduler.ex:160-186`), `step/3` (`:212-233`) | Walks the ordered Ready cards. Only the head carries a board-wide hold (`:no_slot`, `{:quota, _}`). A card's own hold is skipped without advancing the queue position. Pause holds every card |
| The holds | `Lifecycle.dispatchable/2` (`apps/arbiter/lib/arbiter/tasks/lifecycle/dispatchable.ex:79-85`), `@type hold` (`:58-65`), `board_hold/1` (`:136-142`) | Column, then conflicts, then file overlap, then paused / quota / no slot |
| Who dispatches | `Autopilot.plan/1` (`apps/arbiter/lib/arbiter/board/autopilot.ex:742-752`) | Dispatches `snapshot.promote`, one card per pass, with a follow-up pass after each success. Deferred resumes go first |
| The board | `Snapshot.derive/1` (`snapshot.ex:226-255`) | Ready rows are `plan.entries`. Backlog and Blocked use the same `Scheduler.order/1` (`:912-935`). Epics are kept off every column (`:205-208`) and appear only as the `↳` parent chip (`parent_refs/2`, `:1312-1355`) |
| The scope | `Snapshot.load/1` (`snapshot.ex:332-380`) | Issues and edges are read **unscoped**: one queue across every workspace. Slots and the quota hold come from the default workspace |
| Slots | `effective_max_concurrent/3` (`snapshot.ex:491-527`), `slots_free` (`:224-225`) | `min(workspace conductor.max_concurrent, system max, account headroom)`. Live: `default` has 4, the installation's system max is 3, so 3 slots. A slot is a ticket in `:active` |
| Quota-held intents | `DispatchQueue.queue_order_key/1` (`apps/arbiter/lib/arbiter/workflows/dispatch_queue.ex:1163-1165`), `priority_of/1` (`:1126-1127`) | `{priority, opened_at}` |
| Model tier | `Routing.ByPriority` (`apps/arbiter/lib/arbiter/agents/routing/by_priority.ex:44-62`) | `routing.rules."P<n>"` by `task.priority` |
| The card badge | `priority_tag/1` (`apps/arbiter_web/lib/arbiter_web/components/core_components/data.ex:85-96`), used at `domain.ex:333` from `board_live.ex:1393` | `P<n>`. P0–P1 use `badge-error`, P2 `badge-neutral`, P3–P4 `badge-ghost` |
| Manual order | `board_live.ex` moduledoc (`:37-45`), `reorder/4` (`:424-435`); `Tasks.Rank.move/2` | A drag rewrites `rank`. A drop into another band changes `priority` first. `set_rank` has run 34 times (`issues_versions`) |
| Epics | `@non_dispatchable_types ~w(epic)a` (`issue.ex:109`); children by `:parent_of` (`apps/arbiter/lib/arbiter/tasks/dependency.ex:20-24`); `EpicRollup.children_of/1` is one level (`apps/arbiter/lib/arbiter/tasks/epic_rollup.ex:177-183`) | **Nothing reads an epic's priority for scheduling.** Rank is per workspace, assigned on create and on promote (`RankOnPromote`), so inside a band, promotion order is dispatch order |

Nested epics exist (bd-dqvv90 Login relay and bd-gfob09 routing signals are
both children of bd-9dr65f). No child has more than one `parent_of` parent
today, but the schema allows it. Nine non-epic tickets (features, tasks, a
chore) also have `parent_of` children.

## 2. Evidence

All numbers come from a read-only snapshot of the live database
(`~/.arbiter/arbiter.sqlite3`, taken 2026-10-01T23:07:33Z), from the `bd`
workspace unless a line says otherwise. The script prints every table. The
method and its caveats are in [Appendix A](#appendix-a-method).

### 2.1 Tail children wait longer in Ready

A child's **position** is where it falls in its epic's close order:
**head** is the first 50% of siblings to close, **middle** 50–80%, **tail**
the last 20%. **Ready wait** is time in `queued` after every gating blocker
had closed, so it excludes time in Blocked.

| Closed epic children | n | median | p75 | p90 | mean |
|---|---|---|---|---|---|
| Head | 124 | 0.3h | 2.1h | 10.6h | 5.2h |
| Middle | 62 | 0.7h | 7.4h | 15.1h | 10.2h |
| **Tail** | 52 | **2.8h** | 14.9h | **31.0h** | 10.4h |
| Head, own P2 only | 68 | 0.5h | 2.7h | 23.9h | 6.4h |
| **Tail, own P2 only** | 27 | **1.9h** | 13.9h | 32.5h | 9.5h |

The gap survives holding priority fixed: inside P2, tail children wait about
four times as long at the median. So it isn't only that tails are P3.

**Tails are passed over by newer work.** This counts the tickets that were
started while a child sat Ready (unblocked) and that had entered Ready after
it:

| | n | mean | max | passed over by |
|---|---|---|---|---|
| Head | 124 | 1.2 | 25 | P0 1, P1 83, P2 61, P3 2 |
| **Tail** | 52 | **4.4** | **53** | P0 2, **P1 97, P2 112**, P3 12, P4 4 |

That is the operator's complaint, measured: newer P1 and P2 work goes past
tail children.

**Epic children wait longer than parentless tickets of the same priority,
at P3:**

| Own priority | Epic child: n / median / p90 | No parent: n / median / p90 |
|---|---|---|
| P1 | 51 / 0.3h / 3.8h | 115 / 0.3h / 7.9h |
| P2 | 135 / 0.8h / 19.8h | 312 / 0.3h / 24.2h |
| **P3** | 43 / **6.5h** / 44.8h | 118 / **0.1h** / 54.6h |

### 2.2 A floor would reach the tail, not the head

A child is **liftable** when its own priority is worse than its epic's
priority, which is what option 1 would raise if every epic's priority were a
floor:

| | Priority mix | Own priority worse than the epic's |
|---|---|---|
| Head | P0 3, P1 43, P2 68, P3 9, P4 1 | 24 / 124 (19%) |
| Middle | P0 1, P1 4, P2 40, P3 14, P4 3 | 32 / 62 (52%) |
| **Tail** | P1 4, P2 27, P3 20, P4 1 | **32 / 52 (62%)** |

Liftable children waited a median of 1.4h (p90 31.0h) in Ready, against
0.5h (p90 14.1h) for the rest. So the floor targets the right tickets. It
also shows the risk in reusing the epic's `priority` as the floor (§6.2): 88
historical children would have been lifted with no one having chosen it.

### 2.3 Most tail time is not in Ready

Mean hours per closed child, by state:

| | Backlog | Blocked | Ready | Active | Merging | Verifying |
|---|---|---|---|---|---|---|
| Head | 4.3 | 5.3 | 5.2 | 0.9 | 0.5 | 1.8 |
| **Tail** | **11.9** | **30.0** | 10.4 | 1.0 | 3.5 | 9.1 |

Tail children are mostly waiting on their siblings (Blocked), or waiting to
be promoted (Backlog). Ordering helps the Blocked share only indirectly: a
tail's blockers are usually its own siblings, and the floor and the
finish-first tiebreak lift those siblings too. The Backlog share is out of
the scheduler's reach.

**Open epic children right now:** 50 are in Backlog (20 of them unblocked),
16 are queued (14 of them unblocked), and 1 is verifying.

### 2.4 Completion curves

Percentage of leaf descendants closed, by days since the first one was filed:

| Epic | Leaves | d1 | d2 | d3 | d5 | d7 | d10 | d14 | now |
|---|---|---|---|---|---|---|---|---|---|
| bd-ibiwci Reports | 14 | 7% | 7% | 7% | | | | | 43% |
| bd-dqvv90 Login relay | 6 | 0% | 33% | | | | | | 33% |
| bd-de2g19 Codex parity | 23 | 0% | 4% | 9% | | | | | 22% |
| bd-9dr65f Provider accounts go-live (parent of Login relay) | 28 | 0% | 0% | 0% | 0% | 4% | 25% | | 29% |
| **bd-cv1inp** Browser-hosted coordinator sessions (P1) | 22 | 5% | 41% | 86% | **91%** | **91%** | **91%** | **91%** | **91%** |
| **bd-4i9az1** Dashboard slowdown | 10 | 40% | 40% | 40% | 80% | | | | **90%** |
| bd-3sa0y9 agy parity (done) | 22 | 0% | 0% | 0% | 27% | 32% | 32% | 55% | 100% |
| bd-blrsde Provider accounts (done) | 14 | 14% | 21% | 21% | 21% | 29% | 64% | 100% | 100% |
| bd-22hgkx Review coverage (done) | 11 | 36% | 55% | 64% | 64% | 64% | 100% | 100% | 100% |

- **The stall at 90% is real, and it lives in Backlog.** bd-cv1inp has sat
  at 20 of 22 since its fifth day. Its last two leaves are bd-19qve3 (P3) and
  bd-avt4lt (P4), both in **Backlog**, and the first is unblocked. bd-4i9az1
  is at 9 of 10. Its last leaf is bd-6jcebm, a P3 decision that is unblocked
  but still in **Backlog**.
- **The three named epics are early, not stalled at 80–90%.** Reports is at
  43%, Login relay at 33% and Codex parity at 22%. Their delay so far is
  partly Ready wait: Login relay's first two children waited 24h each in
  Ready at P2. The rest is promotion. Login relay 3/6 (bd-c99hys) has been
  unblocked in Backlog since 2026-09-30 18:04, and 10 of Codex parity's 18
  open leaves are in Backlog.
- **Finished epics mostly finish cleanly.** Across 20 finished epics (all
  workspaces, ≥5 leaves), the median share of elapsed time spent on the last
  20% is 0.11. This number is subject to survivorship bias: the epics that
  stall are, by definition, not in it.

### 2.5 Load and parallelism

- **Inflow.** In ISO weeks 38–40, the `bd` workspace filed 105–145 P0–P2
  tickets a week and closed 105–135. It filed 23–35 P3–P4 tickets a week and
  closed 12–23. Low-priority work accumulates.
- **Slots.** 3 slots. Since 2026-09-24, 436 implement runs had a median
  duration of 0.53h. Zero, one, two and three runs were live 25%, 24%, 28%
  and 18% of the time.
- **Epics in parallel.** Six to seven `bd` epics were started and unfinished
  at once on most days (two to four on 09-23 to 09-26), and three to six
  epics had a child started in any 24-hour window. That calibrates option 3
  (§3.3).

## 3. The options

### 3.1 Option 1: inherited priority floor — adopted, as an explicit field

**For.** It expresses the operator's intent directly: "this epic matters at
P1". It reaches the right tickets: 62% of tail children are liftable, against
19% of head children (§2.2). It reuses the one ordering axis everyone already
reads, and it is cheap, because the board already holds every `parent_of`
edge and every issue (`snapshot.ex:172-189`).

**Against.** A large floored epic can starve everything below it. A floor
also turns P4 polish into P1 work wholesale, so the card has to show it
(§6.3).

**How it's adopted:**

- A new nullable `floor_priority` field, set by a dedicated action, never
  reused from `priority` (§6.2).
- The floor's range is P1–P3. P0 is not allowed: an incident must always beat
  any epic.
- A lift cap, `slots_total − 1` lifted tickets in flight (§3.5).
- It decides order only (§6.4).

### 3.2 Option 2: finish-first tiebreak — adopted

**For.** It changes ranking only, so urgency is untouched. It needs no new
knob on any ticket. The score is **shortest remaining work**: among epics
already in progress, the one with the fewest open leaves goes first. That
minimises how many epics are open at once, which is exactly the "half-shipped
features pile up" cost. It also lifts a tail's blockers, which are usually
its siblings, so it attacks the Blocked share in §2.3 too.

**Against.** It reorders a band the operator may have ordered by hand. It
also pushes parentless tickets in the same band back. In the worked example
(§5.1), bd-avgph4 goes from 4th to 12th.

**Bounds:**

- The tiebreak acts only inside one effective band.
- A card that has waited 24h unblocked in Ready drops out of the tiebreak and
  sorts first in its band, by rank. 24h sits near today's p90 Ready wait at
  P2 (19.8h for epic children, 24.2h for parentless tickets; §2.1), so
  roughly the slowest tenth is affected.
- A card the operator dragged (pinned) keeps its place (§4).

**Why "fewest open leaves" and not "highest completion %".** Both rank
bd-cv1inp (2 of 22 open) and bd-4i9az1 (1 of 10 open) first, and both put
Reports (8 open) ahead of Codex parity (18 open). They differ on a small
epic against a large one: 1 of 2 open (50%) against 3 of 30 open (90%).
Completion % picks the large epic, which has three tickets left to finish;
fewest open leaves picks the small one, which finishes with one more ticket.
The cost being minimised is unfinished epics, so it uses the remaining count.

**Why "in progress" gates it.** An epic none of whose leaves has started has
sunk no cost. Ranking its children ahead of parentless work would let a new
epic with one child jump the band.

### 3.3 Option 3: epic WIP limit — opt-in, phase 3

**For.** It is the strongest fix for unfinished epics: at most N epics are
active, and the rest of the epic work waits. It turns "finish what you
started" into a rule rather than a tiebreak.

**Against.** It's a real policy change. With six to seven epics started and
unfinished on most days against 3 slots (§2.5), N = 3 would have held the
children of three to four epics on most days. If every active epic's ready
children are blocked, the limit idles epic work that could run.

**How starvation is bounded, when it's on** (specified in §8):

- Parentless tickets are never held.
- Own-P0 children are exempt.
- The hold is a card's own hold, so the queue skips over it and a slot never
  idles while anything else is eligible.
- An active epic with nothing in flight and nothing Ready for 24h releases
  its WIP place.

**Decision:** specify it now, build it in phase 3, ship it **off by
default**, and decide whether to turn it on from the phase 1 readout (ES7).
If floors plus the tiebreak bring tail Ready wait down to head levels, it
isn't needed.

### 3.4 Option 4: reserved finishing capacity — rejected

With 3 slots, reserving one is a third of the fleet. "Epic-tail work" needs a
threshold to qualify (≥80% done? last N leaves?). At the snapshot, the
Ready, unblocked children of epics at ≥80% numbered zero, so the reserved
slot would have idled. The lift cap (§3.5) is the same idea pointed the other
way: it reserves one slot for **unlifted** work, which always has candidates,
so it is just as predictable and never idles.

### 3.5 Starvation, and how it is bounded

| Risk | Bound |
|---|---|
| A floored epic preempts incidents | Floors are P1–P3. Own-P0 work is always strictly first |
| A large P1 floor takes every slot | **Lift cap.** At most `max_lifted_in_flight` (default `slots_total − 1`, minimum 1; 2 today) `:active` tickets may be ones whose own priority is worse than their floor. Past the cap, every other lifted card is ordered by its own priority until one finishes. Unlifted work always has at least one slot |
| The tiebreak buries parentless work in a band | It's band-local. 24h aging. Pinned cards first |
| A floor spends more quota or loosens a limit | It doesn't. The pace gate, R7's exemption, R5's time weight, model tiers and account eligibility all read own priority (§6.4) |
| A forgotten floor keeps lifting forever | The floor lives on the epic and stops mattering once its leaves close. An `auto_close` epic closes with its last child (`issue.ex:2205-2228`). An open epic shows its floor on its page and on its children's badges, and ES8's coordinator digest lists floored epics |
| Two floors compete | Inside the shared band, the tiebreak orders them by open leaves. The lift cap is shared, so two floors together still leave one slot for unlifted work |

## 4. The ordering key

For every card in Backlog, Blocked and Ready:

```
order_key(card) = {
  effective_priority,          # min(own, floors on parent_of ancestors), unless the lift is capped
  pinned? 0 : 1,               # an operator drag in this band (rank_pinned)
  finish_class,                # 0 aged, 1 child of an in-progress epic, 2 everything else
  open_leaves,                 # class 1 only: open leaf descendants of the nearest epic; else 0
  own_priority,                # among one epic's lifted children, the coordinator's own order
  rank,                        # today's manual order (promotion order)
  created_at                   # today's last tiebreak
}
```

With `finish_first: false`, `finish_class` and `open_leaves` are both 0 for
every card. With no floor anywhere, `effective_priority == own_priority`. So
a board with no floors and finish-first off sorts exactly as
`{priority, rank, created_at}` does today: the pinned flag is false
everywhere, because no drag has pinned anything before ES6 ships.

**Definitions:**

- **Ancestors.** Walk `parent_of` edges upward, breadth-first, with a
  visited set and a depth cap of 8. `parent_of` cycles are not prevented on
  insert (`add/4`'s cycle guard doesn't police `parent_of`;
  `apps/arbiter/lib/arbiter/tasks/dependencies.ex:276-281`), so the guard is
  required. Non-epic parents are walked through but carry no floor.
- **Floor.** `floor_priority` on an ancestor with `issue_type: :epic`, from
  1 to 3, or nil.
- **Effective priority.** `min(own, every non-nil floor on an ancestor)`.
  The strictest floor wins (§6.1). **Via** is the epic that supplies the
  winning floor; on a tie, the nearest one.
- **Lifted.** Effective priority is strictly better than own.
- **Lift cap.** Let `L` be the number of `:active` tickets that are lifted,
  computed from today's floors at plan time and never stored. When `L ≥
  max_lifted_in_flight`, every card that isn't in flight is ordered with
  `effective = own`, and its card says the lift is capped (§6.3).
- **Nearest epic.** The closest `:epic` ancestor. A ticket with none is
  class 2.
- **In progress.** At least one leaf descendant of the nearest epic is
  `:active`, `:merging` or `:verifying`, or closed `completed`.
- **Open leaves.** Leaf descendants of the nearest epic, through sub-epics,
  that are not `:closed`, in any column, Backlog included.
- **Aged.** The card has been Ready and unblocked for more than
  `finish_first_max_wait_hours` (default 24). Ready-since is `max(the last
  ticket_transitions row with to_state = queued, the latest closed_at among
  its gating blockers)`. Both are one indexed read per Ready card
  (`ticket_transitions` has `[:ticket_id, :at]`). Aged cards are class 0.
- **Pinned.** A drag within Backlog or Ready sets `rank_pinned` (§6.3). It
  is cleared by demote, close and reopen, and by `RankOnPromote` re-ranking.

**What doesn't change:**

- `Scheduler.plan/1`'s queue semantics: only the head carries the board-wide
  hold, own holds are skipped.
- One promotion per pass.
- Deferred resumes go first.
- `Lifecycle.dispatchable/2` and its hold list (§6.5).

## 5. Worked examples

The examples use the real Ready queue at the snapshot: the 18 unblocked
`bd` cards, with 3 slots and 1 free. The two tickets in flight, bd-1d1yaj
and bd-8suxac, are parentless P1s, so nothing is lifted in flight. No floor
exists today, so the floors in §5.2–5.4 are hypothetical settings an
operator might choose. The orders were computed mechanically from the
snapshot, not by hand.

### 5.1 Finish-first on, no floors

| # | Today: `{priority, rank}` | Proposed |
|---|---|---|
| 1 | bd-4h5ikn P1 Reports | bd-4h5ikn P1 Reports (8 open) |
| 2 | bd-89z02x P2 Codex | bd-7o4h44 P2 Reports (8 open) |
| 3 | bd-agsn2b P2 Codex | bd-836iuz P2 Reports |
| 4 | bd-avgph4 P2 *no parent* | bd-cl2rtd P2 Reports |
| 5 | bd-d89n5f P2 Codex | bd-tbimna P2 Reports |
| 6 | bd-dnut1o P2 Codex | bd-89z02x P2 Codex (18 open) |
| 7 | bd-yoiv39 P2 Codex | bd-agsn2b P2 Codex |
| 8 | bd-7o4h44 P2 Reports | bd-d89n5f P2 Codex |
| 9 | bd-836iuz P2 Reports | bd-dnut1o P2 Codex |
| 10 | bd-cl2rtd P2 Reports | bd-yoiv39 P2 Codex |
| 11 | bd-tbimna P2 Reports | bd-jk49nc P2 Guardrails (18 open) |
| 12 | bd-7nbwix P2 *no parent* | bd-avgph4 P2 *no parent* |
| 13 | bd-jk49nc P2 Guardrails | bd-7nbwix P2 *no parent* |
| 14 | bd-9q25ck P3 Codex | bd-59x0gb P3 Reports (8 open) |
| 15 | bd-48prlb P3 *no parent* | bd-9q25ck P3 Codex (18 open) |
| 16 | bd-59x0gb P3 Reports | bd-48prlb P3 *no parent* |
| 17 | bd-2xc0aa P3 *no parent* | bd-2xc0aa P3 *no parent* |
| 18 | bd-5kt9sk P4 Reports | bd-5kt9sk P4 Reports |

- **Reports moves ahead of Codex parity.** Reports has 8 open leaves and
  Codex parity has 18. Codex parity's P2s were promoted first, so today
  promotion order puts Codex parity first.
- **The cost:** bd-avgph4, a parentless P2 bug, drops from 4th to 12th. The
  Codex parity cards entered Ready at 17:39Z, so none is near the 24h aging
  line. If bd-avgph4 had waited 24h unblocked, it would sort 2nd: first in
  P2, as class 0.

### 5.2 Reports (bd-ibiwci) floored at P1

The P1 band becomes:

1. bd-4h5ikn, own P1
2. bd-7o4h44, P2 → **P1 via bd-ibiwci**
3. bd-836iuz, P2 → P1
4. bd-cl2rtd, P2 → P1
5. bd-tbimna, P2 → P1
6. bd-59x0gb, P3 → P1
7. bd-5kt9sk, P4 → P1

Then P2 continues as in §5.1 from bd-89z02x.

- **Own priority orders the epic's lifted children.** The coordinator's P2
  backfill (bd-7o4h44) goes before the P4 quota-history panel (bd-5kt9sk).
  Without that term, rank would have put bd-59x0gb (P3) and bd-5kt9sk (P4)
  at 2nd and 3rd.
- **The lift cap.** bd-4h5ikn isn't lifted. Once bd-7o4h44 and bd-836iuz
  are both `:active`, `L = 2 = max_lifted_in_flight`. The remaining four
  Reports cards fall back to their own bands: bd-cl2rtd and bd-tbimna to P2,
  where finish-first still puts them first, bd-59x0gb to P3 and bd-5kt9sk to
  P4. They say so on their cards. A new parentless P1 filed at that moment
  takes the third slot.

### 5.3 Codex parity (bd-de2g19) floored at P1 as well

With both floors, the P1 band is the seven Reports cards above (8 open
leaves), followed by the seven Codex parity cards: bd-89z02x, bd-agsn2b,
bd-d89n5f, bd-dnut1o, bd-yoiv39 (each P2 → P1), then bd-9q25ck (P3 → P1).
Reports goes first because it has fewer open leaves. The lift cap is
shared, so two floored epics still hold at most 2 slots between them. The
P2 band shrinks to bd-jk49nc, bd-avgph4 and bd-7nbwix.

### 5.4 Login relay (bd-dqvv90), nested under bd-9dr65f

- **bd-9dr65f floored at P1.** All six Login relay leaves and bd-gfob09's 16
  leaves (28 leaves under bd-9dr65f, 20 open) read **P1 via bd-9dr65f**.
  That includes Login relay's four open children, which are P2 and all in
  **Backlog**.
- **bd-dqvv90 floored at P2 as well.** Nothing changes. The strictest floor
  wins, and the card still says "via bd-9dr65f".
- **What happens in Ready:** nothing. None of these children is in Ready.
  bd-c99hys (Login relay 3/6) is unblocked, but it sits in Backlog. The
  floor moves it to the top of the Backlog column, sorted P1, which is where
  the operator will see it. Only a promotion moves it into the queue. That is
  the point of §7.

## 6. Decisions on the listed questions

### 6.1 Nested epics

**Floors compose by `min` over every epic ancestor: the strictest wins.** A
floor only ever raises, so a sub-epic can't lower its parent's floor. To
exempt a subtree, remove the parent's floor and set floors on the sub-epics
that should have one.

- **"Via"** names the epic that supplies the winning floor (the nearest, on a
  tie). It is what the card shows.
- **Finish-first** groups by the **nearest** epic (Login relay, not bd-9dr65f).
  The nearest epic is the unit that ships a feature, and the parent's open
  leaves would mix unrelated sub-epics. "Open leaves" recurses through
  sub-epics.
- **Non-epic parents** (9 today) are walked through to find an epic ancestor.
  They carry no floor and form no finish-first group.
- **Several parents.** Take `min` over all of them, and use the parent with
  the fewest open leaves as the nearest epic. This is legal but unused today.
- **Cycles.** The walk keeps a visited set and stops at depth 8, because
  `Dependencies.add/4` doesn't refuse `parent_of` cycles.
- **Workspaces.** Floors cross workspaces along `parent_of`, because the
  queue is one install-wide queue (§1).

### 6.2 An unset floor changes nothing

The epic's `priority` cannot mean "no floor": it is `allow_nil? false,
default 2` (`issue.ex:1174-1180`). All 40 epics have one, and §2.2 counts 88
historical children it would have lifted. So:

- **A new nullable `floor_priority` on `Issue`**, constrained to 1..3 and
  valid only on `issue_type: :epic`. Every existing row backfills to nil.
  `nil` means no floor and no lift, so the order is exactly today's.
- **Set only by a dedicated action** (`:set_floor`), through `arb epic floor
  <id> P1|none`, an MCP tool, the REST API and a control on the epic's page.
  An ordinary priority change on an epic (a board drag, `arb update <id>
  --priority N`) never sets a floor. The operator and the coordinator may set
  it. A worker token may not, consistent with workers not changing priority.
- **The epic's own `priority`** keeps its current meaning, which is the
  epic's place in the Backlog column the epic doesn't actually appear in. It
  is not an input to scheduling. ES2 shows it on the epic page as "epic
  priority (display only)" next to "floor", so the two are never confused.

### 6.3 How the card shows it

**On a lifted card:**

- **The badge** shows the effective priority with an up-arrow, `P1↑`, in the
  effective band's colour. Its `title` and `aria-label` read **"P1 via
  bd-ibiwci — own priority P3"**.
- **The parent chip.** When the floor comes from the chip's own parent, the
  chip gains a suffix: `↳ bd-ibiwci 6/14 · floor P1`. When it comes from a
  further ancestor, the chip doesn't change and the badge's title names the
  ancestor ("P1 via bd-9dr65f").
- **The task page** reads "Priority **P3** · scheduled as **P1 via
  bd-ibiwci** (Add reports)".

**On a capped card:**

- **The badge** shows the own priority, `P3`, with no arrow.
- **Its title** reads "floor P1 via bd-ibiwci waiting — 2 of 2 lifted slots in
  progress".
- **The Ready entry's reason line** is unchanged, because a capped lift
  isn't a hold.

**On the epic:**

- **The epic page** has a "Floor: none / P1 / P2 / P3" control.
- **The epic's mini-board** header shows "floor P1 · 3 lifted, 2 in progress".

**In the text and data surfaces** (`arb ticket show --json`, MCP
`ticket_show`, REST `GET /api/issues/:id`):

- `priority` stays the own priority, so nothing that reads it changes
  meaning.
- They add `effective_priority`, `priority_via` (epic id or null) and
  `priority_lift` (`"applied" | "capped" | null`).
- The listings that show dispatch order (`arb ready`, `arb prime`,
  `GET /api/issues/ready`, `GET /api/issues/lifecycle`) sort by the §4 key.

**Drag semantics:**

- **The board groups bands by effective priority.**
- **A drag within a band** pins the card (`rank_pinned`) and rewrites `rank`
  as today.
- **A drop into a different band** changes the card's own priority, as today.
- **A drop into a band worse than the card's floor is refused**, with the
  flash "bd-x is lifted to P1 by bd-ibiwci's floor — clear the floor or order
  it within P1". Otherwise the card would jump straight back.

### 6.4 Routing and the quota gate: own or effective

**The rule:** effective priority decides **when** a ticket runs. Own priority
decides **what it may cost** and **which limits loosen**. An epic floor says
"do this sooner", not "pay more for it".

| Consumer | Reads | Why |
|---|---|---|
| Ready, Backlog and Blocked order (`Scheduler.order/1`) | **Effective** | It's the purpose of the floor |
| `DispatchQueue` drain order (`dispatch_queue.ex:1163-1165`) | **Effective** | It orders held intents. `priority_of/1` calls the shared resolver at drain time |
| R10 defer-until-reset (bd-3jshn8; routing §4.3), `min_priority` test | **Effective** | Deferral only holds. Reading effective can only *reduce* holds, and deferring a lifted child would undo the floor. A P3 child lifted to P1 is never deferred under the default `min_priority: 2` |
| R7 P0 pace exemption (bd-6bxv7h; routing §4.2), including the priority-aware board hold | **Own** | The exemption loosens a quota line. Floors are P1–P3 anyway, so a floor can never reach P0. R7's board-wide variant checks Ready cards' own priority |
| R5 time weight `w(priority)` (routing §4.1) | **Own** | It trades scarce headroom for speed. A floored P4 must not price its time as a P1's |
| `Routing.ByPriority` model tiers (`by_priority.ex:44-62`) | **Own** | Model choice is spend |
| The pace gate itself (`Gate.pace/6`), and per-ticket quota holds (`ticket_quota_holds/3`) | Own (it reads no priority today) | Unchanged |
| MergeQueue order | Own | Unchanged. Merges take seconds and aren't where epics stall |

R7 and R10 need one line each in their ticket notes; see §9.
[`paced-quota-routing-signals.md`](paced-quota-routing-signals.md) §4.4 gains a
pointer to this table.

### 6.5 Slots, account caps and the Ready-queue holds

- **The slot cap is unchanged.** A floor changes which card is head, never
  how many run. Slots are still `:active` tickets (`snapshot.ex:224-225`).
- **The lift cap is computed on the same slot measure.** `L` counts `:active`
  lifted tickets, so it releases when a ticket moves to Merging, as a slot
  does.
- **Account caps are unchanged.** Routing runs after ordering. An account at
  `account_headroom` 0 is dropped as `at_capacity`
  (`apps/arbiter/lib/arbiter/agents/provider_routing.ex:693-696`) whatever
  the card's priority.
- **The hold list is unchanged in phases 1 and 2.** `Lifecycle.dispatchable/2`
  gets no new hold. A capped lift is a reorder, not a hold, so it never sits
  at the head of the queue holding a slot. The head rule still applies to
  the *effective* head: if a lifted card is head and the board-wide quota
  hold is on, it's the card that carries "held — …", exactly as an own-P1
  head would. Autopilot's `promote_or_hold/2` retry-at-head (`autopilot.ex:800-807`)
  is unchanged.
- **Phase 3 adds one card-own hold**, `{:epic_wip, active_epic_ids}`, at
  precedence 3½ (after file overlap, before paused). The queue skips over it
  (§8).

### 6.6 Config

The queue is install-wide (§1), so every key that shapes the order must be
comparable across every card. A per-workspace knob would make the key
inconsistent between two cards in the same queue. So the knobs are
installation settings, on `Arbiter.Settings.Installation` and in the
`Settings.Registry` schema (`apps/arbiter/lib/arbiter/settings/registry.ex:21-60`).
That makes them visible through MCP `installation_config_*`, `arb settings`
and the Global Settings page (#200).

| Key | Default | Meaning | Who sets it |
|---|---|---|---|
| `floor_priority` on an epic | nil (no floor) | A floor of P1–P3 | Operator or coordinator |
| `scheduling_epic_floors_enabled` | `true` | A kill switch: `false` ignores every floor. It is a no-op until a floor is set | Operator |
| `scheduling_max_lifted_in_flight` | nil, meaning `max(slots_total − 1, 1)` (2 today) | The lift cap | Operator |
| `scheduling_finish_first` | `false` at ship; flipped to `true` by ES9 after the readout | The finish-first tiebreak | Operator or coordinator |
| `scheduling_finish_first_max_wait_hours` | 24 | The aging escape | Operator or coordinator |
| `scheduling_epic_wip_limit` (phase 3) | nil (off) | At most N active epics | Operator |

The operator alone owns the kill switch, the lift cap and the WIP limit,
because they decide how much of the fleet a floor may take. The coordinator
may set floors and tune the tiebreak, the same split
[routing §4.4](paced-quota-routing-signals.md#44-all-the-priority-settings)
uses.

## 7. The backlog tail

Section 2 shows the two most stalled epics are stalled in **Backlog**:
bd-cv1inp's last two leaves for 16 days, and bd-4i9az1's last leaf. Right now
there are 20 unblocked epic children in Backlog. Autopilot never promotes:
the `:promote` transition carries the acceptance-criteria rule, and
promotion is an operator or coordinator decision
([ticket lifecycle](ticket-lifecycle.md) §2). No change to the Ready order
can reach these tickets.

**Decision:**

- **Surface the backlog tail. Don't auto-promote it.**
- **The epic rollup gains `ready_to_promote`**, the unblocked Backlog leaves.
  The epic's mini-board and the `↳` chip show it (`6/14 · 2 to promote`).
- **A once-a-day coordinator digest** (ES8) lists unblocked Backlog leaves
  older than 24h, for every epic that is floored or in progress. Floors make
  the list sort itself: with floors on, the Backlog column already orders
  those children by effective priority (§5.4).

## 8. Phase 3: the epic WIP limit (opt-in)

When `scheduling_epic_wip_limit = N`:

- **Active epics.** An epic is active when its nearest-epic group has a leaf
  `:active` or `:merging`, or when it was admitted and has had a leaf in
  flight or Ready within the last 24h. Admission is sticky until the epic
  closes, or until it goes 24h with nothing in flight and nothing Ready.
- **Admission.** When fewer than N epics are active, the epic of the first
  queued card (by §4's key) is admitted when that card is promoted. No
  separate admission queue exists.
- **The hold.** A Ready card whose nearest epic is not active, while N are,
  gets `{:epic_wip, ids}`, phrased "waiting for an epic slot — bd-a, bd-b,
  bd-c active". It is a card-own hold, so `Scheduler.plan/1` skips it and the
  slot goes to the next eligible card, often parentless work.
- **Exemptions.** Parentless tickets and own-P0 children are never held. A
  forced manual dispatch (`arb dispatch --force`) passes, as for every
  scheduler hold.
- **Starting value.** N = 3, given six to seven concurrently started epics
  today (§2.5). Turn it on only if ES7's readout shows tail Ready wait still
  far above head Ready wait with floors and finish-first on.

## 9. Phased ticket breakdown

| # | Title | D | Depends on | Phase |
|---|---|---|---|---|
| ES1 | `Arbiter.Tasks.EpicFloor`: a pure resolver from issues plus `parent_of` pairs to, per ticket, `{own, effective, via, lifted?}`, the nearest epic, open leaves and in-progress. Breadth-first ancestors, visited set, depth 8. Property tests: effective ≤ own; no floors means effective == own; order-invariant over edge order; a cycle terminates | 2 | — | 1 |
| ES2 | `floor_priority` on `Issue`: migration (nullable, nil backfill), constraint 1..3, epic-only validation, the `:set_floor` action (operator and coordinator; workers refused), paper trail, `arb epic floor`, the MCP tool, REST, and the epic page control with the "epic priority (display only)" label | 2 | — | 1 |
| ES3 | The order key: `Scheduler.order/1` takes the §4 key. `Snapshot` feeds `EpicFloor` from the issues and edges it already loads, plus Ready-since from `ticket_transitions`. `queue_card/1` carries `effective_priority`, `priority_via`, `priority_lift`, `finish_class` and `open_leaves`. The lift cap. The installation settings and registry keys (§6.6) with validation. Backlog and Blocked share the key. Tests: no floors plus finish-first off sorts identically to today on a fixture board; §5's examples as fixtures | 3 | ES1, ES2 | 1 |
| ES4 | Effective priority beyond the board: `DispatchQueue.priority_of/1` via `EpicFloor`; `effective_priority`, `priority_via` and `priority_lift` on MCP `ticket_show`, `arb ticket show --json` and REST `GET /api/issues/:id`; `arb ready`, `arb prime`, `GET /api/issues/ready` and `/lifecycle` sort by the §4 key | 2 | ES1, ES2 | 1 |
| ES5 | Board and task-page UI: the `P1↑` badge with its title and aria-label, the chip's `· floor P1` suffix, the capped wording, the task page's "scheduled as" line and the epic mini-board header. LiveView tests by element id | 2 | ES3 | 1 |
| ES6 | Manual order under the new key: `rank_pinned` (set by a drag, cleared by demote, close, reopen and promote), pinned-first in a band, and refusing a drop below the floor with the flash | 2 | ES3 | 1 |
| ES7 | The readout: port `measure_epic_waits.py` into Reports as an "epic Ready wait: head vs tail" panel. Fold it into bd-59x0gb (Reports: attention / wait time) if that is still open; otherwise make it a standalone `mix arbiter.epic_waits`. Re-run 14 days after ES3 is enabled, and include parentless P1/P2 p90 Ready wait as the guard metric | 2 | ES3 | 1 |
| ES8 | The backlog tail: `ready_to_promote` on the epic rollup and chip, plus a daily coordinator digest of unblocked Backlog leaves older than 24h for floored or in-progress epics. No auto-promotion | 2 | ES1 | 2 |
| ES9 | Turn finish-first on by default, if ES7 shows tail Ready wait fell and parentless P1/P2 p90 Ready wait rose by no more than 25% | 1 | ES7 | 2 |
| ES10 | The epic WIP limit (§8): `scheduling_epic_wip_limit`, the `{:epic_wip, ids}` hold in `Lifecycle.dispatchable/2`, admission and release, the P0 exemption, the phrase, off by default | 3 | ES3, ES7 | 3 |

**Notes for existing tickets (for the coordinator to add when filing):**

- **bd-6bxv7h (R7):** "the exemption and the priority-aware board hold read
  the ticket's *own* priority, never an epic floor (epic-aware-scheduling §6.4)."
- **bd-3jshn8 (R10):** "the `min_priority` test reads the *effective* priority
  (epic-aware-scheduling §6.4)."
- **R5 (scoring), when filed:** "`w(priority)` reads own priority."

**Order to turn things on:**

1. ES1–ES5 behind the defaults. Floors are nil, so nothing moves.
2. The operator sets floors on the epics they care about (Reports, Codex
   parity, bd-9dr65f).
3. Turn on `scheduling_finish_first`.
4. ES7's 14-day readout. Then ES9, and only then a decision on ES10.

## 10. Open questions

1. **O1. Should the lift cap be per epic, as well as shared?** A shared cap
   of 2 lets one floored epic take both lifted slots. That's acceptable
   while only a few epics are floored. Revisit if ES7 shows one floor
   crowding out another.
2. **O2. The 24h aging threshold** is set near today's p90 Ready wait at P2.
   ES7 should check how often aging fires. If it's more than about 10% of
   dispatches, the tiebreak is fighting the queue.
3. **O3. Should the floor reach the board's Blocked column's blockers**, so
   that a non-epic blocker of a floored child is lifted too? The floor
   follows `parent_of` only. A cross-epic blocker isn't lifted, and ES5's
   card shows the child as blocked by it. Measure before widening.

## Appendix A: method

- **Source.** A `sqlite3` `backup()` copy of `~/.arbiter/arbiter.sqlite3`,
  taken 2026-10-01T23:07:33Z and read with `mode=ro`. Reproduce with
  `python3 docs/design/epic-aware-scheduling/measure_epic_waits.py <db>
  --as-of 2026-10-01T23:07:33Z`. Against the live file, later numbers will
  drift as tickets move.
- **Ready vs Blocked.** `ticket_transitions` stores lifecycle states, so
  Ready and Blocked are both `queued`. A queued span counts as Ready only
  after every gating blocker (a `depends_on` target, or a `blocks` source) had
  closed. That uses **today's** edges and each blocker's latest `closed_at`.
  Edges added or removed later, and blockers reopened and re-closed, are not
  replayed, so Ready wait is an approximation. It is applied identically to
  head and tail.
- **Backfill.** 6,265 of 6,415 transition rows are `source = backfill`,
  rebuilt from `issues_versions` (bd-d8fi92). Only 150 are `live`. The
  backfill's timestamps are the versions' timestamps.
- **Head, middle, tail.** A child's index in its direct epic's close order,
  divided by (siblings − 1). Children of epics with fewer than 3 non-epic
  children are excluded. Only closed children whose last Ready span has
  ended are in §2.1–2.3.
- **Passed over.** For each Ready (unblocked) span of a child, this counts
  the `queued → active` starts during the span, by tickets whose Ready span
  began after the child's began. That includes higher-priority tickets, which
  today's order lets pass correctly. The point is the difference between
  head and tail.
- **Ready wait includes held time.** It includes time the head was held by
  quota, pause or a full slot cap, because the scheduler holds the whole
  queue then. Zero implement runs were live 25% of the time since 09-24; this
  analysis doesn't attribute that idle time to a cause.
- **Inflow and concurrency.** These come from `issues.created_at` and
  `closed_at` by ISO week, and from `worker_runs` with `kind = 'implement'`.
  They are not printed by the script; they come from the same snapshot.
