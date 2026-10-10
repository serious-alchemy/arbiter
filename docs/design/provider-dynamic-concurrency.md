# Provider-reported dynamic concurrency, and one layered admission model: decision

**Task:** bd-8qdviv (decision, GitHub #197) · **Epic:** bd-gfob09 (paced quota
routing signals) · **Builds on:** the paced gate (`Arbiter.Quota.Pace`,
`Arbiter.Quota.Gate`), account concurrency (`Arbiter.Accounts.Concurrency`,
`Arbiter.Accounts.Admission`; P8), node capacity (`Arbiter.Nodes.Capacity`,
`Arbiter.Nodes.Placement`, `Arbiter.Nodes.LocalCapacity`; RW8, RW14), the board
scheduler (`Arbiter.Board.Scheduler`, `Arbiter.Board.Autopilot`), and the quota
history and draw calibration (`Arbiter.Quota.History`,
`Arbiter.Loop.Scarcity.Draw`; R2, R3) · **Reconciles with:**
[paced quota routing signals](paced-quota-routing-signals.md) (R1–R16),
[epic-aware scheduling](epic-aware-scheduling.md) (ES3, ES7, ES9),
[remote workers](remote-workers.md) §13 (RW8, RW14) and
[provider accounts](../provider-account-design.md) §4 (P8) · **Scope:** the
filing, plus a scope addition the operator approved on 2026-10-10, after
filing (coordinator message to this ticket): one layered admission model
(node, provider, repo, workspace, ticket), and deleting `conductor.max_concurrent`
· **Status:** proposed 2026-10-10. It was filed before R6's shadow report reached
10–20 comparable decisions, with the operator's approval. Nothing here is
implemented. The ticket plan is in [§12](#12-phased-plan-and-ticket-breakdown).

## Decision

1. **Admission is one layered check, and each layer counts its own unit.** A
   fresh dispatch has to clear five layers:
   - **node:** machine capacity;
   - **provider:** the quota budget;
   - **repo:** optional;
   - **workspace:** optional fair share;
   - **ticket:** `conflicts_with` and file overlap.

   Each layer bounds one resource and counts what loads it. A card that fails
   a layer waits with that layer's reason. Nothing else waits for it. See
   [§2](#2-the-layered-admission-model).
2. **Each provider pool reports a concurrency budget.** The budget is an integer
   number of *seats* plus a reason. It comes from the pool's own quota state:
   - each window's usage;
   - the paced line now and one horizon ahead;
   - the time to reset;
   - the measured draw per seat-hour;
   - the seats in flight.

   The budget replaces both the static `max_concurrent`, as the primary
   control, and the gate's on/off pace hold. It still reads the line through
   `Gate.pace/6`, so there's one definition of pace. See
   [§3](#3-the-provider-budget).
3. **The budget doesn't over-commit, even near a reset.** Four things prevent
   it:
   - Seats count the work in flight from the registry, not from a snapshot.
   - The draw since the last capture is projected forward to now.
   - When a reset falls inside the horizon, the *fresh* window has to absorb
     what the seats will still draw after the reset.
   - A fit that can't tell a seat's draw from the background isn't used, and
     no draw per seat is taken below a floor. No fit can make a seat look
     free.

   See [§3.3](#33-the-capacity-function) and
   [§3.4](#34-measuring-the-draw-per-seat-hour).
4. **The budget is recomputed on every quota capture, at every window reset and
   every 60 seconds.** A fall is published at once. A rise is published only
   after it clears a quarter-seat margin on two recomputes in a row. A budget
   never stops running work. See [§3.6](#36-recompute-cadence) and
   [§3.7](#37-hysteresis).
5. **The scheduler matches cards to (pool, node) pairs.** It works in three
   steps:
   1. Collect the pools and machines with free capacity. A pool or machine at
      zero is never evaluated per card.
   2. Walk Ready in the ES3 order, and place each card on an eligible pair with
      room. Eligibility is the existing constraint, guardrail (G13),
      capability, floor and placement checks.
   3. If a card fits nowhere, skip it with its own reason and try the next.

   Head-of-line blocking goes away. See [§4](#4-the-scheduler-walk).
6. **An account's `max_concurrent` becomes an optional ceiling over the
   budget,** as RW14 did for the conductor cap. A workspace link's `share` stays
   an optional per-workspace ceiling. Existing values are kept, and the
   operator clears them when the shadow report says to. See
   [§6](#6-what-becomes-of-each-max_concurrent).
7. **`conductor.max_concurrent` is deleted.** Both the install setting and the
   workspace key go, with their doctor, board, settings, CLI and MCP surfaces.
   - Machine capacity is the sum of the node caps.
   - The primary's default cap becomes its own hardware suggestion, enforced
     like any node's.
   - A migration drops the setting and logs an advisory line.

   See [§5.1](#51-node-and-deleting-conductormax_concurrent) and
   [§10.6](#106-migration-notes).
8. **The repo and workspace layers are opt-in config.**
   - **Repo:** `worker.repos.<repo>.max_concurrent` bounds the implementer runs
     in one repo. Reviewers don't count.
   - **Workspace:** an account's `budget_split: fair` splits its budget by
     each link's `weight`, and isn't a hard cap. An idle workspace's share can
     be borrowed. A workspace under its share, with a card in the same band,
     goes first.

   See [§5.2](#52-repo) and [§5.3](#53-workspace-fair-share).
9. **The R-series is re-scoped, not raced.**
   - R7 folds in as the exempt budget, R11 as weighted seats, R9's reservations
     as seats, and R16's expiring headroom as a budget term.
   - R9's model choice stays.
   - R10, defer-until-reset, is dropped. A reset-aware budget already waits for
     the reset when a pool is full, and holding feasible work would fight it.

   See [§8](#8-the-r-series-keep-fold-in-or-drop).
10. **Shadow first, then enforce with the ceilings kept.** A new installation
    setting, `scheduler_admission: legacy | shadow | enforce`, chooses the mode.
    - **Shadow** records what the new walk would have done at every dispatch
      and every hold change.
    - **The report** has to show agreement, ahead-of-pace admissions,
      calibration error and flapping before anyone sets `enforce`.
    - **In `enforce`**, while an account keeps `max_concurrent`, the budget can
      only *lower* that account's concurrency.

    See [§10](#10-shadow-comparison-and-migration).
11. **The board and `arb scheduler status` show each pool's budget and why,**
    plus each machine's free slots. A held card's badge names the layer that
    holds it. See [§9](#9-observability).

## Why

Admission today is split across six mechanisms, and each answers "how many" in
a different unit (§1.2). On this install the static number that binds is a
hand-tuned integer: `claude:default`'s `max_concurrent`, raised from 2 to 3. It
doesn't know the quota.
- **When the week is quiet,** it leaves headroom unused.
- **When the week is tight,** the paced gate takes over and flips between
  "admit up to the cap" and "admit nothing".

Neither the cap nor the gate knows what a run costs.

Three more problems sit in the same path:

- **Head-of-line blocking, patched case by case.** The queue already skips
  three kinds of card:
  - a card whose provider constraint leaves no provider with room (bd-13pqcp);
  - every unconstrained card of a workspace whose pool can't take one *sample*
    ticket (bd-814vuy, `apps/arbiter/lib/arbiter/board/snapshot.ex:1103-1124`,
    `:1192-1205`);
  - a card whose dispatch was just refused, held for 15 s
    (`apps/arbiter/lib/arbiter/board/autopilot.ex:278-285`, `:1105-1113`).

  Anything else stops the queue. A board-wide hold on the head card ends the
  pass (`apps/arbiter/lib/arbiter/board/scheduler.ex:255-259`, `:313-315`), and
  a card's *own* quota verdict takes the same path (`ctx/3`, `:281`). One sample
  ticket can't speak for cards whose tier, repo or guardrails give them
  different pools. A held sample holds the whole workspace. A sample that's
  fine leaves a held card at the head, stopping every card behind it (§4.2).
- **Over-commit.** Three paths let more work start than the count or the
  quota reading allows:
  - **Reviews.** A cross-family review parks the implementer's worker, so the
    implementer's account stops counting that ticket
    (`apps/arbiter/lib/arbiter/accounts/concurrency.ex:352-363`). The scheduler
    can fill the seat, and the fix round then lands on top of it.
  - **Lag.** Snapshots lag dispatch by up to 20 minutes.
  - **Resets.** Right after a 5h reset, the stale window fails open: the gate
    drops rules 1 and 3 (`apps/arbiter/lib/arbiter/quota/gate.ex:1204-1218`).
- **The static cap does more than one job.** It also stands in for:
  - machine load;
  - CI runner contention;
  - merge churn;
  - fairness between workspaces.

  A quota budget alone would drop those jobs, so the operator's scope addition
  gives each one its own layer (§2).

## 1. What exists today

### 1.1 The admission path

| Step | Where | What it decides |
|---|---|---|
| Plan | `Scheduler.plan/1` (`apps/arbiter/lib/arbiter/board/scheduler.ex:164-198`), `step/3` (`:245-266`), `decide/3` (`:298-315`) | Orders Ready by the ES3 key (`order_key/1`). A card's own hold skips it. A board-wide hold (`:no_slot`, `{:quota, _}`) on the head **stops the queue**, and so does a card's own quota verdict. At most one `promote` |
| Skips | `ticket_constraint_holds/3` (`apps/arbiter/lib/arbiter/board/snapshot.ex:1103-1124`), `pool_holds/4` (`:1192-1205`), both through `ProviderConstraint.pick/3` | A constrained card with no allowed provider with room, and every unconstrained card of a workspace whose sample ticket has none, get card-own holds, so the plan passes them (bd-13pqcp, bd-814vuy) |
| Holds | `Lifecycle.dispatchable/2` (`apps/arbiter/lib/arbiter/tasks/lifecycle/dispatchable.ex:88`) | Column, mutex, overlap, provider constraint and guardrail are card-own holds. Paused, quota and no slot are board holds |
| Slots | `Snapshot.capacity_terms/3` (`apps/arbiter/lib/arbiter/board/snapshot.ex:793-848`), `SlotGate.slots_used/1` (`apps/arbiter/lib/arbiter/tasks/slot_gate.ex:202`) | `min(node sum, ceiling, workspace cap, placement cap)`, clamped by account headroom and placement free slots. A slot is a ticket `:active` |
| Quota hold | `Snapshot.quota_hold/2` (`snapshot.ex:979`), `ticket_quota_holds/3` (`:1034`) | Binary: `:ok` or `{:hold, phrase}`, board-wide and per card |
| Dispatch | `Autopilot` (`autopilot.ex:232`: 60 s tick; 300 ms debounce on lifecycle and worker events) | One dispatch at a time, with an immediate follow-up pass after a success. A self-clearing refusal becomes a 15 s card hold (`:278-285`, `:1176-1202`) |
| Route | `Dispatch.dispatch/2` (`apps/arbiter/lib/arbiter/worker/dispatch.ex:227-250`), `ProviderRouting.check/2` (`apps/arbiter/lib/arbiter/agents/provider_routing.ex:920`) | The account. The drop reasons run in order: guardrails, constraint, sandbox, account, adapter, guardrail floor, CLI, auth, circuit, capacity (`at_capacity`, `:1086`), confinement, capability, floor, quota (`:1135`) |
| Quota gate | `maybe_quota_gate` (`dispatch.ex:2102`), `apply_quota_gate/5` (`:2362`) | A hold enqueues the intent in `DispatchQueue` (`apps/arbiter/lib/arbiter/workflows/dispatch_queue.ex:224`), which drains on `quota_updated` (`:560`) and on a reset timer (`:1029-1054`) |
| Account cap | `ensure_account_capacity/2` (`dispatch.ex:2229`); `Admission.admit/3` (`apps/arbiter/lib/arbiter/accounts/admission.ex:107`), `decide/4` (`:183`) under `:global.trans` (`:176`) | Fresh admissions only (`fresh_admission?/2`, `dispatch.ex:2312`). Reserves a slot until the worker registers |
| Node cap | `ensure_node_capacity/2` (`dispatch.ex:2254`); `LocalCapacity.gate/2`; `Placement.place/2` (`apps/arbiter/lib/arbiter/nodes/placement.ex:193`) | Chosen **after** the account. `live + reserved < cap` per machine |
| Follow-ups | Routed by `ProviderRouting.implementer_provider/4`. A ReviewGate fix round goes through `ReviewGateFixRoundDispatcher.dispatch/1` to `Dispatch.resume/2` (`apps/arbiter/lib/arbiter/workflows/review_gate_fix_round_dispatcher.ex:217`, `:241`). CI fix and conflict passes go through `PassAdmission`, then `Worker.start_or_reap_terminal/1`. Reviewers go through `ReviewerRouting`'s `check_quota/2` (`apps/arbiter/lib/arbiter/agents/reviewer_routing.ex:868`) | Counted, never refused by a cap. The quota gate can hold a fix round (bd-6omte4) and drops a held reviewer pool to its fallback. CI fix and conflict passes don't pass the quota gate |

Autopilot's plan is the only thing that enforces the board's slot cap. A fresh
`arb dispatch`, or MCP `worker_dispatch`, checks only the account cap and the
node cap.

### 1.2 Six mechanisms that each answer "how many"

| Mechanism | Where | Default | Unit | Enforced by |
|---|---|---|---|---|
| Install `conductor_system_max_concurrent` | `Arbiter.Settings` (`apps/arbiter/lib/arbiter/settings.ex:50`); `Snapshot.concurrency_ceiling/0` (`snapshot.ex:657`) | Unset, meaning the node sum. `system_max_concurrent/0` fills in 16 (`snapshot.ex:105`) as the primary's default local cap, which isn't enforced | Tickets In progress | The board plan only |
| Workspace `conductor.max_concurrent` | `Workspace.max_concurrent/1` (`apps/arbiter/lib/arbiter/tasks/workspace.ex:723`) | Unset | Tickets In progress | The board plan only |
| Account `max_concurrent` | `ProviderAccount` (`apps/arbiter/lib/arbiter/accounts/provider_account.ex:146-150`) | `nil` from the migration; 3 on `claude:default` (the filing) | Live workers (registry) | `Admission`, and the board's clamp |
| Link `share` | `WorkspaceProviderAccount` (`apps/arbiter/lib/arbiter/accounts/workspace_provider_account.ex:77-82`) | `nil` | Live workers | As above |
| Node caps | `Nodes.Capacity.breakdown/1` (`apps/arbiter/lib/arbiter/nodes/capacity.ex:84`), `LocalCapacity.cap/0` (`apps/arbiter/lib/arbiter/nodes/local_capacity.ex:102-110`) | The node's suggestion. The primary is unenforced unless overridden | Live runs on the machine | `ensure_node_capacity/2` |
| The paced gate | `Gate.gating_window/3` (`gate.ex:1179`) | — | Binary | `apply_quota_gate/5` → `DispatchQueue` |

The board counts tickets. The account counts processes. The gate counts
nothing. `Concurrency.clamp/3` folds headroom measured in processes into a cap
measured in tickets (`snapshot.ex:825-827`).

### 1.3 Live state on 2026-10-10

Read through the worker's own MCP tools (`quota_get` at 01:40:27Z,
`workspace_show`). Worker-tier tokens can't read accounts or nodes
(`arb account list` and `arb node list` are refused), so the account cap comes
from the filing.

| Item | Value |
|---|---|
| `claude:default` (max_20x) | 5h: 0.19 used, resets 04:40Z, paced line now 0.4015. 7d: 0.49 used, resets 10-12 16:00Z, paced line now 0.629. Captured 01:38:49Z by `oauth_poll`. Floors 0.35 and 0.20. `max_concurrent` 3 (from the filing) |
| `antigravity:default` | Gemini pool: 5h 0.153, weekly 0.427 (resets 10-14 02:43Z). Claude/GPT pool: 0 and 0 |
| `codex:default` | Free plan, 30d window at 1.0, paused by the operator |
| `default` workspace | `routing.provider_selection: scored`, `scoring.mode: shadow`, `quota.threshold_mode: paced`, `worker.placement: prefer_remote`, **`conductor: {}`** |
| The primary | A worker container on it sees 12 CPUs and a `MemTotal` of 31.0 GiB, so `NodeAgent.Protocol.suggestion/2` gives `min(12/2, 0.8 × 31.0/4) = 6` (Appendix A) |

## 2. The layered admission model

### 2.1 Five layers

| # | Layer | Bounds | Counts | Default | Config |
|---|---|---|---|---|---|
| 1 | **Node** | Machine CPU and memory | Live runs on the machine, plus reservations | Each machine's cap. The primary's default becomes its hardware suggestion | `arb node set <node> --max-workers N` |
| 2 | **Provider pool** | Quota pace | Seats on the pool (§3.2) | The dynamic budget, under the account's optional ceiling | `max_concurrent` (ceiling), `quota_config` |
| 3 | **Repo** | CI runners, merge churn and conflict passes, shared test services | Implementer runs in the repo | Unset: no cap | `worker.repos.<repo>.max_concurrent` |
| 4 | **Workspace** | Fairness between workspaces on one account | The workspace's seats on the pool | Off: queue order decides | `budget_split: fair` on the account, `weight` on the link. `share` is an optional ceiling |
| 5 | **Ticket** | Semantic and file conflicts | `conflicts_with` edges and file overlap | As today | As today |

Admission is the conjunction of all five layers. There's no install-wide
integer above them, because every job that integer did now belongs to a layer.

### 2.2 Held or counted

Every layer follows the rule `LocalCapacity` already uses for nodes
(`local_capacity.ex:70-79`):

| Work | At a full layer |
|---|---|
| A fresh dispatch (a new ticket entering In progress) | Waits in Ready, with that layer's reason |
| A follow-up of in-flight work: a resume, a ReviewGate round, a CI fix pass or a conflict pass | Counted, and not held for being full. Stranding work costs more than overshooting (the no-deadlock rule `ResumeSlot` documents). The exceptions are the layer's own hard zeros: a machine whose cap is 0 still holds them, as `:zero_only` does today, and a pool holds them only on a hard rule (§3.5, §4.5) |

A layer that falls below its occupancy stops admitting new work. It never stops
work that's running.

### 2.3 Order of evaluation

Within one card, the walk (§4) checks the layers from cheapest to most
expensive:
1. The ticket's own holds.
2. Pools with a free seat (per-pool fair share applies here).
3. The repo.
4. Machines with a free slot that can run that pool.

A held card's reason names the first layer that failed. The card's popup lists
every layer that failed.

## 3. The provider budget

### 3.1 Pools

A budget belongs to an **(account, pool)** pair. The pool comes from
`ModelFamily.classify/2`
(`apps/arbiter/lib/arbiter/agents/model_family.ex:74-89`):
- `claude`, `codex` and `grok` are one pool per account;
- agy has `antigravity:gemini_models` and `antigravity:claude_and_gpt_models`.

The pool's windows come from `Snapshot.normalize(quota, model: m)`, which is
the same projection the gate uses.

A card whose predicted model is `nil` takes the lowest budget among the
account's pools. That's the same thing the gate does when it reads the worst
group. `ModelFamily` would name the Gemini pool instead, a mismatch the budget
doesn't inherit.

### 3.2 Seats: what occupies a pool

A **seat** is one unit of in-flight work on a pool:

| Holder | Takes a seat on | Today (`Concurrency.occupants/0`, `concurrency.ex:315-363`) |
|---|---|---|
| A ticket In progress (`SlotGate.holds_slot?/1`), in **every** phase, including between rounds, while its worker is parked on a cross-pool reviewer, and while it's released to wait for CI | Its implementer pin's pool | Counted while its primary worker is the ticket's only live process, or while a sub-worker on the same provider runs. It drops out while the primary is parked behind a sub-worker on another provider (bd-dp0p58), released to wait for CI (bd-cut6uv) or held for quota (bd-zkmvia) |
| A live run that doesn't belong to a ticket counted above on the same pool: a reviewer for a ticket pinned elsewhere, or a fix pass or conflict pass for a ticket in Merging | The pool it runs on | One per live worker |
| An admitted dispatch whose worker hasn't registered | Its pool | Yes (`Admission.pending/0`) |

So a ticket counts **once per pool**:
- on its pin pool for its whole In-progress life;
- on another pool only while a sub-worker runs there.

This is bd-dp0p58's "one ticket's agent counts once", made per pool. It also
closes the review-gap over-commit in the "Why" section: the seat a fix round
comes back to is still held.

This needs the registry to know each run's account and pool. Today
`put_dispatch/3` (`apps/arbiter/lib/arbiter/worker.ex:1206`) stamps only the
workspace and provider, and the account is inferred by (workspace, provider).
DC4 stamps `account_id`, `pool` and `node_id`.

### 3.3 The capacity function

These are the inputs for one window `w` of pool `π`. They're per (account,
workspace) policy, because the line composes `min(account, workspace)`:

| Symbol | Meaning | Source |
|---|---|---|
| `u` | Utilization at the capture | `Snapshot.normalize/2`, the trusted reading |
| `lag` | `now − captured_at` | The snapshot |
| `line(t)` | The paced line at time `t`: `max(floor, elapsed(t))`, or the flat ceiling | `Gate.pace/6` with a `now: t` what-if (E1). One definition of the line |
| `line′(x)` | The fresh window's line `x` hours after its reset | The same call, with `reset_at` advanced one window and `used = 0` |
| `t_r` | `reset_at − now` | The snapshot |
| `S` | Seats on `π` now | §3.2 |
| `ρ` | Draw per seat-hour, as a fraction of `w`. Never below its floor `ρ_min` | §3.4 |
| `b` | Background draw per hour (the coordinator, interactive sessions) | §3.4 |
| `H` | The commitment horizon: how long an admitted seat keeps drawing | §3.4. The measured median In-progress life of a seat on `π`, clamped to [1 h, 4 h]; 2 h until measured |

The function:

```
ρ     = max(ρ, ρ_min)                          # the floor (§3.4), whatever ρ it's given
u_now = u + (S · ρ + b) · lag                  # the draw the snapshot hasn't seen yet

if t_r ≥ H:                                    # no reset inside the horizon
    n_w = (line(now + H) − u_now − b·H) / (ρ·H)

else:                                          # 0 < t_r < H: the horizon crosses the reset
    n_before = (line(reset) − u_now − b·t_r) / (ρ·t_r)               # what can still be spent before the reset
    n_after  = (line′(H − t_r) − b·(H − t_r)) / (ρ·(H − t_r))        # what the fresh window absorbs afterwards
    n_w = min(n_before, n_after)

raw(π)    = min over trusted windows w of n_w      # continuous; the binding window is named
budget(π) = clamp(floor(raw), 0, ceiling)          # after hysteresis (§3.7); ceiling = max_concurrent and share
```

Here's why each piece is there:

- **`n` counts every seat, in flight or new.** The budget is a *concurrency
  target* for the next horizon. Admission compares it with seats counted live
  (`S < budget`), never with a snapshot. So a burst of dispatches in one tick
  can't herd onto a stale reading: each one takes a seat, and that seat counts
  straight away. That's the in-flight reservation R9 proposed (routing §2.5).
- **The horizon is the commitment.** An admitted seat keeps drawing until its
  ticket leaves In progress, and its follow-ups are never held (§2.2). So the
  constraint has to hold one *seat life* ahead, not one run ahead.

  A shorter horizon over-commits. With §3.8's live readings and prior rate
  (0.0667 per seat-hour), a 30-minute horizon admits 9 seats. They keep
  drawing for 90 minutes after that horizon ends: 9 × 0.0667 × 2 h = 1.2 of
  the window, which runs the 5h window from 0.19 to past 1.0.
- **The fresh-window term is the over-commit guard near a reset.** Just before
  a reset, `n_before` grows without bound, because there's no time left to
  spend. The seats then spill into a window whose line starts at its floor
  (0.35 for 5h). `n_after` caps them at what that floor absorbs over the rest
  of their life (§3.8, example B).
- **`ρ` has a floor, so every `n` is finite.** Every `n` divides by `ρ`.
  With `ρ` near 0, `n` would be unbounded, `n_after` included. The budget
  would then be held only by the ceiling, and by the machines once the
  ceiling is cleared (§10.5). §3.4 drops a fit that can't tell a seat's draw
  from `b`, and raises any other `ρ` below `ρ_min` to it. The function
  applies the floor again to whatever `ρ` it's given. The other divisors are
  positive by construction: `H` is at least 1 h, and the second branch runs
  only for `0 < t_r < H`. A window at or past its reset is evaluated as the
  fresh one (§3.5). So the budget is finite for any input (I11).
- **`u_now` covers the capture lag.** The gate trusts a polled row for up to
  1,200 s (`gate.ex:194-195`). The projection charges the seats' draw since
  the capture. A run that started after the capture isn't in `u` at all.
- **It's a proportional controller around the line.** With `u_now` exactly on
  the line, `n_w = (1/W − b)/ρ`, which is the steady state: seats that draw
  exactly as fast as the line rises. Behind pace, the budget opens to catch
  up within one horizon; that's quota that would otherwise expire. Ahead of
  pace by `ε`, the budget shrinks linearly, and it reaches 0 at
  `ε = H/W − b·H`.

  On a 7d window that tolerance is about 1.2 points (`H/W = 2/168`), so a
  weekly line acts as a hard line. Early in the week, where the line sits
  flat at its floor, the floor binds. On the 5h window it's 40 points of
  *transient* band, never a steady offset: at the end of the horizon the
  projected usage is back on the line. §3.9 and O1 cover how this differs from
  the gate.
- **Flat sides stay flat.** An account the operator keeps on `flat` has a
  constant line, so `n_w = (flat − u_now − b·H)/(ρ·H)`. Codex's `session` and
  agy's `used` labels, which have no window length, fall back to flat exactly
  as they do in `Gate.window_seconds/2`.
- **The exempt budget (R7).** For priorities the account exempts, the same
  function runs with each paced side replaced by its `{:paced_exempt, …}`
  side, `max(paced, min(cap, flat))`. The result, `exempt_budget(π) ≥
  budget(π)`, admits an own-priority-exempt card while `S < exempt_budget`.
  The ceiling still applies.

### 3.4 Measuring the draw per seat-hour

The input "measured cost per run" is `ρ`. A seat's cost over its life is
`c = ρ·H`, as a share of the window.

**The seat-hour fit (DC2).** For each (account, pool, window), fit

```
Δu = ρ · seat_hours + b · hours
```

over the intervals between consecutive `quota_snapshots` captures
(`Arbiter.Quota.History`, `apps/arbiter/lib/arbiter/quota/history.ex`, R2). It
uses non-negative least squares, the same `Scarcity.Calibration.fit/2`
(`apps/arbiter/lib/arbiter/loop/scarcity/calibration.ex:96`) that R3 uses.
- **Intervals** follow `Scarcity.Draw`'s rules: coalesce captures closer than
  30 minutes (5h) or 4 hours (others), and drop an interval that spans a reset
  or a polling gap longer than the window.
- **`seat_hours`** is the trapezoid of a new `seats` column, which DC2 writes
  on every capture. Until that column has history, it's reconstructed as run
  hours from `worker_runs`. That overstates `ρ` per seat, because idle pinned
  seats draw nothing, so the budget comes out low, which is the safe side.
- **The fit needs no token capture.** The token ledger has had
  provider-correlated bugs (routing §3.3), and this fit avoids it entirely. It
  works the same for Claude, agy, Codex and grok.

**The fallback ladder.** "Absence is never zero", as with R3:

| Rung | `ρ` | When |
|---|---|---|
| 0 | The seat-hour fit for this (account, pool, window) | At least 8 intervals over 30 days, at least 3 with seats > 0, and the fit measures a seat (below) |
| 1 | The fit for (provider, pool, window) across accounts | Another account on the same plan has a fit that measures a seat |
| 2 | The prior: `ρ = 1 / (W · k)`, where `k` is the account's `max_concurrent`, or 2 when that's unset. With no measurement, this assumes the operator's ceiling is the steady state | Always available |

**A fit has to measure a seat.** The fit splits each interval's draw between
the seats (`ρ`) and the background (`b`). When the seat count barely moves, as
on a pool held at its ceiling with work queued, `seat_hours` tracks `hours`
and the data can't tell the two apart. The fit can then give `b` most of the
draw and leave `ρ` near 0. That isn't a cheap seat, and dividing by it would
make every `n` in §3.3 unbounded. Such a fit predicts the past as well as the
true one, so the calibration report's bias (§10.3) can't catch it. It shows
only once more seats run. Two rules stop it:

- **A `ρ` the data doesn't pin down falls through to the next rung.**
  - `fit/2` already returns no coefficient when it puts one at 0
    (`:non_positive`), as it does when the seat count never moves (Appendix
    A), or when it can't separate a column from another (`:collinear`)
    (`calibration.ex:38-42`, `:190-195`). Rungs 0 and 1 count that as no fit.
  - A positive `ρ` must also be distinguishable from 0: its one-sided 95%
    lower confidence bound, `ρ − t₀.₉₅·se(ρ)`, has to be above 0. `se` is the
    least-squares standard error over the columns the fit didn't pin at 0,
    with its residual degrees of freedom. It's large when `seat_hours` moves
    with `hours`. DC2 adds it to `fit/2`'s coefficients.
- **No `ρ` is taken below the floor `ρ_min = prior / 4`.** A fit that passes
  but comes out lower is clamped to the floor, not dropped, so a seat measured
  cheaper never gets a smaller budget than one measured dearer. At the floor,
  `4k` seats track a line: 8 with `max_concurrent` unset (`k` = 2), and 12
  under a ceiling of 3, which caps them at 3 anyway. The prior is `4·ρ_min`,
  so rung 2 is never clamped.

On synthetic intervals (Appendix A), take a pool held at 2.9–3.0 seats that
draws exactly the prior's rate with no background, read to the poll's 1
point. On two seeds of eight, the fit puts `ρ` at about 0.015, under a quarter
of the truth, and `b` takes the rest.
- **Taken as is** in Example A's state, that's a 5h `n` of about 10 instead
  of the prior's 4.55. Once the ceiling no longer holds them at 3, 10 seats at
  the true rate would run the window from 0.19 past 1.0 in 1.2 hours.
- **The floor alone isn't enough.** Raised to it, they still give about 9.
- **The confidence bound catches them.** Both have `t = ρ/se` near 0.5,
  under the 95% cutoff of 1.86 at 8 degrees of freedom, so they fall through
  to the prior. The other six have `t` above 2 and are kept.

The rung, `n`, any rung passed over and why, and the floor when it binds go
into the reason (§3.8). A prior-based budget says so ("6.7%/seat-h prior; own
fit not distinguishable from 0"), and so does a floored one ("1.7%/seat-h
floor; fit 0.1%").

**The horizon `H`** is the median In-progress life of tickets pinned to the
pool over 30 days. That runs from the first `active` transition to leaving
`active` (`ticket_transitions`). It's clamped to [1 h, 4 h], and it's 2 h until
measured.

**Phase 2 (DC11, R11 folded in): weighted seats.** R3's per-model coefficients
(`Scarcity.Draw`, `draw_share/5`,
`apps/arbiter/lib/arbiter/loop/scarcity.ex:239`) give a draw rate per model:
`ρ_m = c_m × weighted tokens per seat-hour of m`. A seat then weighs
`ρ_m / ρ̄`, so a premium-model ticket takes more than one seat-equivalent, and
admission compares `Σ weights + w_new ≤ raw`. Phase 1 counts every seat as 1.
Each `ρ_m` has to pass the same confidence-bound test as `ρ`, or its seats
weigh 1 as in phase 1. It also takes the same floor, so no model's seat weighs
less than `ρ_min / ρ̄`, and none looks free.

### 3.5 Hard zeros, and missing readings

| Condition | Budget | Reason |
|---|---|---|
| The provider refuses requests (gate rules 1 and 2, `gate.ex:1220-1244`) | 0 | `:provider_refusing` |
| `weekly_warning_policy: hold` with the long window at `allowed_warning` (rule 5) | 0 | `:weekly_warning` |
| Operator pause (`arb provider pause`) | 0 | `:paused` |
| A quota-stop hold (bd-a6vh2x, `Pause.quota_hold/4`, `apps/arbiter/lib/arbiter/providers/pause.ex:184`) | 0 until it expires | `:quota_stop` |
| Auth expired, or the circuit is broken | 0 | `:unavailable`. These are routing drops already; the budget mirrors them so the board can explain them |
| A stale primary window (`Gate.stale?/2`) | The window is skipped, as the gate skips it. One exception: a window whose `reset_at` has passed is evaluated as the fresh window, with `u = 0` at the reset plus the projected draw since then | `:stale` on that window |
| No trusted reading at all | `min(last published, ceiling)` for up to 2 h, which covers the OAuth poll's longest 429 cooldown (`oauth_usage.ex:85-91`). After that, the ceiling, or 1, with the existing stale-snapshot alert (bd-2wnkoq) | `:no_reading` |
| A provider with no quota source at all (local LLMs) | The ceiling, or `:unlimited`; the node layer bounds it | `:unmetered` (routing O8) |

Hard zeros skip hysteresis in both directions. They're not noise.

### 3.6 Recompute cadence

| Input | Changes when | Recomputed |
|---|---|---|
| `u`, `reset_at` | Each capture: `CloudProbe` every 300 s (`apps/arbiter/lib/arbiter/quota/cloud_probe.ex:186`), broadcast as `{:quota_updated, …}` on `quota:<ws>` | On the broadcast |
| `line(t)` | Continuously; a 5h line rises 0.2 per hour | Every 60 s, and at each window's `reset_at` + 60 s |
| `S` (seats) | Each admission, worker start and worker exit | Not an input to the published budget. Admission reads it live |
| `ρ`, `b`, `H` | Slowly | At boot and daily, cached in `:persistent_term`; `mix arbiter.budget_calibration` on demand |

`Arbiter.Quota.Budget.Server` holds the published budget per (account, pool,
policy) in ETS. It subscribes to `quota_updated`, arms reset timers, and ticks
every 60 s. A change is broadcast as `{:budget_changed, pool, from, to,
reason}` on the `board` topic, and Autopilot treats a rise like a freed slot
and runs a pass. The board and `Admission` both read the published value, so
they can't disagree, except across one publish.

### 3.7 Hysteresis

The published budget `B` follows `raw`:

- **Falls at once:** if `floor(raw) < B`, then `B := max(floor(raw), 0)`. A
  scarcer pool should stop admitting straight away. A fall never stops running
  work.
- **Rises with a margin and a dwell:** if `raw ≥ B + 1 + θ` on two recomputes
  at least 60 s apart, then `B := floor(raw − θ)`. `θ` is 0.25.

So `B` holds steady while `raw` stays in `[B, B + 1.25)`. Here's what moves
`raw`:
- A 1-point utilization step, which is the OAuth poll's resolution, moves it
  by `0.01/(ρ·H)`. That's 0.08 seats with the §3.8 prior on 5h.
- A minute of line movement is smaller still.

Flapping therefore needs `raw` to swing by more than a quarter-seat. The shadow
report counts published changes per pool per day (§10.3), and the target is
fewer than one an hour.

Two further sources of churn are already damped:
- **Placement** keeps a ticket's follow-ups on its first pool (the pin,
  bd-40pzpj).
- **The walk** re-plans from the top of Ready on every pass (§4).

### 3.8 Output: an integer and a reason

```elixir
%Arbiter.Quota.Budget{
  account: "claude:default", pool: "claude", policy_workspace: nil,
  budget: 3,                        # published: hysteresis, then the ceiling
  raw: 4.55,                        # continuous, before floor and ceiling
  exempt_budget: nil,               # R7, when the account exempts a priority
  seats: 3, free: 0,
  binding: :ceiling,                # or {:window, "5h"} | :provider_refusing | :paused | :quota_stop | :no_reading | :unmetered
  reason: "ceiling max_concurrent 3 (quota allows 4: 5h binds, 0.19 used, line 0.40 now and 0.80 in 2h, 6.7%/seat-h prior)",
  windows: [%{window: "5h", used: 0.19, used_now: 0.195, line_now: 0.4015, line_at_h: 0.8015,
              reset_in_h: 3.0, rho: 0.0667, rho_source: :prior, rho_min: 0.0167, b: 0.0,
              horizon_h: 2.0, n: 4.55}, …],
  ceiling: %{max_concurrent: 3, share: nil},
  computed_at: ~U[2026-10-10 01:40:27Z], published_at: ~U[…], pending_rise: nil
}
```

`reason` is the one phrase every surface shows. `windows` carries every number
behind it, so an explanation is never re-derived.

**Example A: live readings, illustrative rate.** These are the `claude:default`
readings from §1.3, with `H` = 2 h, `b` = 0, 3 seats and a 98 s lag. The
rates aren't measured yet (that's DC2), so each row assumes one. The first row
is the §3.4 prior with `k = 3`.

| Assumed `ρ` (5h, 7d per seat-hour) | What it means | `n_5h` | `n_7d` | Budget | Published, with ceiling 3 |
|---|---|---|---|---|---|
| 0.0667, 0.00198 | The prior: 3 seats track each line | 4 (4.55) | 37 (37.99) | 4 | 3, ceiling binds |
| 0.0333, 0.00099 | A seat draws half that | 9 (9.13) | 76 (76.02) | 9 | 3, ceiling binds |
| 0.1333, 0.00397 | A seat draws twice that | 2 (2.25) | 18 (18.97) | 2 | **2, budget binds** |

The 5h window binds in every row. Its line will be at 0.80 two hours out, the
7d line at 0.64. The 5h is 0.21 behind its line now, so the budget opens one
seat above the prior's steady state to use quota that would otherwise expire.

The rows bracket what DC2 has to measure:
- If a seat draws more than about 1.5× the prior, the budget lowers concurrency
  below today's 3. That's the binary gate's job, done continuously.
- If a seat draws less, the ceiling, not the quota, is what holds the fleet at
  3. In that case the static cap is standing in for the machine, repo and
  review limits, which is why those get layers of their own (§2).

**Example B: near a reset (hypothetical state).** It's 04:10Z, the 5h window
resets at 04:40Z (`t_r` = 0.5 h), and 0.70 is used. Take the prior `ρ` (0.0667)
and `H` = 2 h:
- **Before the reset:** `n_before = (1.00 − 0.70)/(0.0667 × 0.5) = 9.0`.
- **After the reset:** `n_after = max(0.35, 1.5/5)/(0.0667 × 1.5) = 0.35/0.1 =
  3.5`.

So `n_5h` is 3. Without the fresh-window term the budget would be 9. Nine seats
would carry 9 × 0.0667 × 1.5 = 0.90 of draw into a window whose line sits at
0.35. That window would then hold for most of its 5 hours, and could exhaust
it.

### 3.9 How the budget differs from the gate

| Situation | Gate today | Budget |
|---|---|---|
| Behind the line | Allows, up to `max_concurrent` at once | Admits up to `budget`, which can be above or below the ceiling. The ceiling still applies |
| Slightly ahead of the line | Holds every fresh dispatch and a ReviewGate fix round (bd-6omte4) | Admits a few seats, so the projected usage is back on the line one horizon out. 7d tolerance is about 1 point. Follow-ups keep their seats (§4.5) |
| Far ahead (`ε > H/W`) | Holds | 0 |
| Provider refusing, pause, quota stop | Holds | 0 (§3.5) |
| Right after a reset with a stale window | Fails open until the next poll | Evaluates the fresh window from `u = 0` plus the projected draw |
| Several dispatches in one tick | Each sees the same snapshot | Each takes a seat, counted live |

The budget doesn't loosen a hard rule, and it never plans past a provider's own
limit. The change is at the line. A pool ahead of pace admits proportionally
less instead of flipping to zero. O1 asks the operator to confirm that, and
shadow mode measures it first (§10.3).

## 4. The scheduler walk

### 4.1 Capacity sets first

Each pass starts by building three sets. The walk skips a pool or machine at
zero without asking about it per card:

```
open_pools = {π : budget(π) − seats(π) > 0}           # plus, for exempt cards, exempt_budget(π) − seats(π) > 0
open_nodes = {n : cap(n) − live(n) − reserved(n) > 0}
open_repos = {(ws, repo) : unset, or cap − implementer runs > 0}
```

If `open_pools` or `open_nodes` is empty, the walk stops at once. Every card
reads "waiting for capacity" with one summary reason, and no per-card routing
evaluation runs.

Today the board runs `ProviderRouting.availability/3` for every Ready card
when routing is on (`snapshot.ex:1034-1050`). That's a database-bound call:
the routing design measured 10–15 ms for a whole selection. The walk
evaluates a card's eligibility only against open pools.

### 4.2 Walk Ready, place on a pair, skip what doesn't fit

```
for card in Ready, in the ES3 order:
  own holds (column, mutex, overlap, constraint, guardrail, the 15 s retry window)
      → held with that reason; next card
  pools = the card's eligible candidates (constraint, guardrails, capability, floor, pause, auth, circuit)
          that are in open_pools, after fair share (§5.3)
      → none: "waiting for <pool>: <budget reason>"; next card
  repo full → "repo <r>: N of N implementer runs"; next card
  pairs = for each pool, ranked by the workspace's provider_selection (failover | most_quota | scored),
          the open nodes that can run it (Placement.eligible/1 and the workspace's worker.placement),
          ranked by Placement's own rank (lowest load, then name)
      → none: "no machine slot for <pool> work: local 6 of 6"; next card
  place the card on the first pair; free_seats[π] −= 1; free_slots[n] −= 1; free_repo −= 1
  if open_pools or open_nodes became empty: every remaining card is "N ahead in queue"; stop
```

The walk is greedy and keeps the ES3 order. A card is placed only if nothing
before it could use the same capacity. A skipped card is first in line again on
the next pass, because every pass starts from the top. So a P0 bound to a full
pool gets that pool's next free seat, and other pools' work runs meanwhile. No
reservation is needed.

**Example, per the code (a hypothetical state).** Here's the setup:
- `claude:default` has 3 of 3 seats in use.
- agy's Gemini pool is over its weekly line, and its Claude/GPT pool has room.
- `default` routes D3 to `standard` and D5 to `flagship`. agy's built-in tier
  map (`apps/arbiter/lib/arbiter/agents/gemini/config.ex:45-50`) runs
  `standard` as `gemini-3.8-flash-medium` (the Gemini pool) and `flagship` as
  `claude-opus-4-6-thinking` (the Claude/GPT pool).

Two unconstrained Ready cards in `default`, in order:

| Card | Its candidates | Today | The walk |
|---|---|---|---|
| bd-a, P1, D3 | Claude: full. agy on the Gemini pool: held | If bd-a is the workspace's sample, `pool_holds/4` holds every unconstrained card in `default`, bd-b included. If it isn't, bd-a's own quota verdict stops the queue at the head. Either way, nothing dispatches | Skipped: "waiting for claude: 3 of 3; antigravity gemini: weekly over its line" |
| bd-b, P2, D5 | Claude: full. agy on the Claude/GPT pool: free | Held with bd-a, or queued behind it | Placed on (agy claude/gpt, local) |

With R9's model choice, a D3 card could reach the Claude/GPT pool too, when
its tier lists such a model.

### 4.3 One dispatch per pass, many placements per plan

The plan can place several cards. Each entry carries its pair. Autopilot still
dispatches one per pass, with the follow-up pass it already runs after a
success (`autopilot.ex:825-848`). Serializing dispatch keeps `Admission`'s
per-account lock simple. The board shows the first placement as "next" and the
rest as "starting".

### 4.4 Dispatch takes the planned pair

The planned pair rides into dispatch as `opts[:planned]`, holding
`account_id`, `pool` and `node`.
- `maybe_route` prefers the planned account when it's still available.
- `ensure_node_capacity/2` prefers the planned node.
- `ensure_account_capacity/2` checks `seats < budget` for the pool under the
  existing per-account `:global.trans`.

A race, such as a follow-up taking the seat first, still returns
`{:account_at_capacity, _}` or `{:no_node_capacity, _}`. Autopilot keeps its
15 s card hold for that, so the next pass re-plans. The hold becomes the
fallback for a race, not the mechanism.

### 4.5 Follow-ups

A follow-up of a ticket In progress already holds its pin seat (§3.2). In
`enforce`, follow-ups are held only by the hard rules (§3.5), not by the paced
line:
- **A ReviewGate fix round:** its `Dispatch.resume/2` runs the quota gate with
  `pace: false`, so rules 1, 2 and 5 still apply.
- **A reviewer:** `ReviewerRouting` drops a reviewer pool only on a hard rule,
  and prefers a pool with a free seat.
- **CI fix and conflict passes:** they skip the quota gate today, and still do.

Holding an in-flight ticket mid-review saves nothing the budget hasn't already
counted. It does strand a worktree and a context. #252, "A quota-held fix round
raises a false run_crashed attention", is one cost that's been paid. O2 asks
the operator to confirm this.

## 5. The other layers

### 5.1 Node, and deleting `conductor.max_concurrent`

The node layer exists: `Nodes.Capacity` sums the available machines' caps,
`Placement` picks a machine (`live + reserved < cap`, ranked by load), and
`LocalCapacity` gates the primary. Three changes follow.

**Delete `conductor.max_concurrent`, install and workspace.**
- **Why it can go.** With nodes, budgets, repo caps and fair share, it has no
  job left. The operator reports it's unset everywhere, and the live `default`
  workspace carries `conductor: {}` (§1.3).
- **What it costs to keep.** A third number on every capacity surface, the
  `ceiling_below_total` warning, and a "limiting now" line that names a knob
  nobody sets.
- **What it supersedes.** RW14's "optional ceiling" rule (remote-workers §13).

These surfaces go:

| Surface | Where |
|---|---|
| Setting | `Arbiter.Settings.conductor_system_max_concurrent/0` (`settings.ex:50-63`); `Settings.Installation` attribute (`apps/arbiter/lib/arbiter/settings/installation.ex:13-15`, `:68`, `:115`); `Settings.Registry` key (`apps/arbiter/lib/arbiter/settings/registry.ex:23`, `:280-281`, `:324`, `:351`); the `installation_settings` column (migration `20260703160000_create_installation_settings.exs`); app env `:conductor_system_max_concurrent` |
| Board | `Snapshot.default_system_max_concurrent/0`, `system_max_concurrent/0`, `concurrency_ceiling/0` (`snapshot.ex:632-663`), `@default_system_max 16` (`:105`), the `:ceiling` and `:workspace` terms in `capacity_terms/3` (`:793-848`) and `@binding_order` (`:858`), and the `system_max_concurrent()` fallbacks (`:470`, `:732`, `:745`) |
| Nodes | `Nodes.Capacity` ceiling (`capacity.ex:17-19`, `:87`, `:97`); `Nodes.Overview` ceiling, the `ceiling_below_total` warning and the local suggestion (`apps/arbiter/lib/arbiter/nodes/overview.ex:18-29`, `:206`) |
| Workspace | `Workspace.max_concurrent/1` (`workspace.ex:709-735`); `ValidateConfig.validate_conductor/2` (`apps/arbiter/lib/arbiter/tasks/workspace/changes/validate_config.ex:72-73`, `:160`, `:1256-1288`) |
| Explainer | `CapacityExplainer`'s `:ceiling` and `:workspace` limit keys and change hints (`apps/arbiter/lib/arbiter/board/capacity_explainer.ex:116-120`, `:236-241`) |
| Doctor | "node capacity vs conductor.max_concurrent" (`apps/arbiter_cli/lib/arbiter_cli/cmd/doctor/checks.ex:2000-2020`) |
| CLI | `arb node list`'s `ceiling_line` and the `ceiling_below_total` warning (`apps/arbiter_cli/lib/arbiter_cli/cmd/node.ex:455-475`) |
| Web | The `/nodes` ceiling warning and footer (`apps/arbiter_web/lib/arbiter_web/live/nodes_live.ex:605-608`); the Settings page's "Max concurrent workers" row (`apps/arbiter_web/lib/arbiter_web/live/settings_live.ex:39`, `:220-227`) |
| MCP | `installation_config_*`'s key and description (`apps/arbiter/lib/arbiter/mcp/catalog.ex:2280-2350`; `apps/arbiter/lib/arbiter/mcp/tools/workspace.ex:357`) |
| Docs | README.md:135; `docs/remote-workers-runbook.md:199`; `docs/pro-extension-seams.md:232`; `docs/design/workspace-config-reload.md:40`; remote-workers §13 (RW14 bullet); provider-account-design §4.1 |

`ResumeSlot` (`apps/arbiter/lib/arbiter/worker/resume_slot.ex`) reads
`effective_max_concurrent`. It moves to the pin pool's seat check (§7).

**The primary's default cap becomes its hardware suggestion, enforced.**
- **As built (DC1, bd-74mtmp).** `LocalCapacity.cap/0` is `%{cap:, source: :override | :suggestion}` and is always enforced; `LocalCapacity.suggestion/0` reads the hardware once per boot (`NodeAgent.Protocol.local_hardware/0`), and `config :arbiter, :local_hardware` pins it for tests. The `installation_settings` migration `20261010120000_drop_conductor_system_max_concurrent` keeps the advisory line in a new `local_cap_advisory` column, which `GET /api/nodes` returns and `arb server doctor` and `arb node list` show until the operator sets the local cap (`arb node set local`); the workspace migration is `20261010120100_remove_conductor_from_workspace_configs`.
- **Today.** `LocalCapacity.cap/0` defaults to `system_max_concurrent/0`, which
  is 16 and not enforced (`local_capacity.ex:102-110`).
- **After DC1.** It's `nodes.local_max_workers` when set. Otherwise it's
  `NodeAgent.Protocol.suggestion/2`
  (`apps/arbiter/lib/arbiter/node_agent/protocol.ex:91`), the formula every node
  already reports: `min(cpus/2, 0.8 × MemTotal / 4 GiB)`, at least 1. It's
  enforced like a node's cap.
- **On the primary,** as a worker container sees it, the suggestion is 6
  (§1.3), above today's binding 3.
- **The local row on `/nodes`** shows the suggestion as its source, as remote
  rows do.

**Stamp `node_id` on the registry entry.** `put_dispatch/3` passes no
`:node_id` (`worker.ex:1206-1210`). `LocalCapacity.holders/1` keeps the
occupants whose `node_id` is `nil` (`local_capacity.ex:118-124`), so a run
placed on a node also counts against the primary's cap. That's from reading the
code; it hasn't been reproduced at runtime. DC1 fixes it, because the node layer
becomes the only machine bound.

### 5.2 Repo

| | |
|---|---|
| Key | `worker.repos.<repo>.max_concurrent`: a positive integer, unset by default. It goes in the existing per-repo `worker` block, which `validate_worker_repos/2` already validates (`validate_config.ex:198-215`) |
| Counts | **Implementer runs** in that workspace's repo: the implementer (fresh, re-dispatched, resumed), a ReviewGate fix round, a CI fix pass and a conflict pass, plus admission reservations. Reviewers (ReviewGate reviewers, `review: true` dispatches) are excluded |
| Holds | A fresh dispatch whose repo is at its cap waits in Ready: "repo vstim: 2 of 2 implementer runs". The walk skips it |
| Never holds | Follow-ups (§2.2). They finish the tickets the cap already admitted, and finishing is what cuts merge churn |
| Enforced | In the walk, and in a new `ensure_repo_capacity/2` after `ensure_node_capacity/2`, with a reservation under the same `:global.trans` pattern |
| Who may set it | The operator or the coordinator. It only tightens |

**What it bounds.** The cap limits how many tickets in one repo are being
written at once, and that bounds:
- shared test services;
- the rate at which new branches reach CI and the merge queue;
- the conflicts that racing branches cause.

**What it doesn't bound.** A pipeline still running after its run ended
(Merging) isn't counted, so with vstim's roughly 30-minute GitLab CI the cap
limits new MRs, not live pipelines. O3 asks whether a Merging ticket with a
pipeline in flight should count.

### 5.3 Workspace fair share

| | |
|---|---|
| Switch | `budget_split` on the account: `queue` (the default; the ES3 order alone decides, as today) or `fair`. Set by the operator or the coordinator. It reorders, and never loosens a limit |
| Weight | `weight` on the workspace link (`workspace_provider_accounts`): a positive integer, default 1. `arb account attach <ws> <provider> <account> --weight N` |
| Entitlement | `e_w(π) = budget(π) × weight_w / Σ weight` over the workspaces with *demand* on `π`: seats on `π`, or an eligible Ready card that can use `π` this pass |
| Rule in the walk | A card from workspace `w` is skipped for pool `π` when all of these hold: `w` holds at least `e_w(π)` seats; another workspace `v` holds fewer than `e_v(π)`; and `v` has an eligible Ready card for `π` in the **same effective band**. The card may still be placed on another pool |
| Exempt | Own-P0 cards are never skipped for fair share |
| Work-conserving | With no such `v`, the card goes above its share. An idle share is borrowed, so it isn't a hard cap |
| Preemption | None. Running work keeps its seats, and fairness converges as tickets finish |

**What this guarantees.** A workspace with a P1 waiting gets its share of the
next free seats, however many P1s another workspace queued first. Ranks are
per workspace, so they don't order cards across workspaces anyway. Across bands,
priority still wins: a P1 is never skipped for another workspace's P3.

**What happens to `share`.** The existing link `share` stays, unchanged, as an
optional **hard** per-workspace ceiling ("vstim may use at most 2"), composed
`min(budget, max_concurrent, share)`. Re-purposing it as the fair weight would
silently change the meaning of a stored value (§13).

### 5.4 Ticket

`conflicts_with` edges and file-overlap holds are card-own holds in
`Lifecycle.dispatchable/2` today. They already skip rather than stop. Nothing
changes.

## 6. What becomes of each `max_concurrent`

| Number | Becomes | Migration |
|---|---|---|
| Account `max_concurrent` | An **optional ceiling** over the budget: `limit = min(budget, max_concurrent, share)`. Not the primary control. Label: "Concurrency ceiling (optional): the quota budget decides; this only caps it" | Kept as is, like RW14 kept the conductor value. `claude:default`'s 3 stays, so enforcing can only lower that account. The operator clears it with `arb account set <ref> --max-concurrent none` once the report earns it, and after setting node and repo caps, because the 3 was also guarding the machine and CI |
| Link `share` | An optional per-workspace hard ceiling, unchanged | Kept |
| Link `weight` (new) | The fair-share weight (§5.3) | New, default 1. Has no effect until `budget_split: fair` |
| Install `conductor_system_max_concurrent` | **Deleted** | §10.6 |
| Workspace `conductor.max_concurrent` | **Deleted** | §10.6 |
| `nodes.local_max_workers` | The primary's override, unchanged. The default becomes the hardware suggestion | Unchanged |
| `worker.repos.<repo>.max_concurrent` (new) | The repo cap (§5.2) | New, unset |

## 7. Interactions

| With | Today | Under this design |
|---|---|---|
| Node capacity (RW8, RW14) | Chosen after the account (`dispatch.ex:242-243`), so the machine can't influence which account is picked | The walk picks the pair. The pool comes first, then a node that can run it. Non-Claude providers stay local-only (`Placement.eligible/1`'s `non_claude_provider`). Machine capacity is `Nodes.Capacity`'s sum, with no ceiling |
| The scheduler cap (`slots_total`) | `min` of the terms, in tickets (`snapshot.ex:461-473`) | No independent number. The header shows per-pool seats and per-machine slots. Where a single number is still read (the lift cap and the header total), it's `min(Σ budget over pools any Ready card can use, Σ machine caps)`, computed at plan time |
| Finish-first and the ES3 order | A held head stops the queue, apart from the skips in §1.1 | The order key is unchanged and the walk keeps it. A skipped card is first in line on the next pass. Finish-first still ranks in-progress epics' children first, and when their pool is full, other work uses the capacity they can't |
| The ES lift cap (`max_lifted_in_flight`, default `slots_total − 1`) | Static between config changes | `QueueOrder.build/6` (`apps/arbiter/lib/arbiter/board/queue_order.ex:105`) gets the plan-time `slots_total` above, so the lift cap moves with the budgets. With 2 seats it's 1, and one seat still serves unlifted work |
| ES7's readout and ES9's switch | Ready wait measured from `ticket_transitions` | Switching to the walk changes Ready wait by itself: skipped cards stop blocking others. ES7's 14-day window must not straddle the `enforce` switch, or it must split at that date. The plan entry gains `wait_cause` (`:queued`, `{:capacity, layer}`, `:own_hold`) so the readout can attribute wait |
| R7's board hold (`exempt_card_holds`) | Per-card verdict at the exempt line | Replaced in `enforce` by the per-card exempt budget (§3.3) |
| G13 guardrails | `check_guardrails` first in both routers | Unchanged. A card's candidate pools are its eligible ones, so a card never falls back to an ineligible pool. A card with no eligible pool keeps `:no_eligible_model` |
| `ResumeSlot` (bd-92mx1m) | An automatic resume must fit under `effective_max_concurrent` | An automatic resume into `:active` needs a free seat on its pin pool and a machine slot. Otherwise it's deferred as today (`Autopilot.defer_resume`). An operator resume can force it |
| `DispatchQueue` | Holds quota-held fresh intents, and drains on `quota_updated` and resets | In `enforce`, fresh intents aren't quota-held: they wait in Ready with a layer reason. The queue keeps guardrail, pause, quota-stop and hard-rule follow-up holds. `slot_free?/2` (`dispatch_queue.ex:685`) becomes the seat check |
| R5 and R6 routing | Feasibility is `gate.check`; rank is headroom or `J` | Feasibility is a free seat. The rank among a card's open pools is unchanged (`failover`, `most_quota`, `scored`). A pool the budget admits while it's a little past its line has `h ≤ 0`, so it ranks after every priced pool, as an unknown headroom does today |
| Manual dispatch | `arb dispatch` checks the account and node caps only | Also checks seats (via `Admission`) and the repo cap. `--over-cap` overrides as today, and is recorded |

## 8. The R-series: keep, fold in, or drop

Status as of `3d12c3e5`:
- **Built:** R1–R8. R1 is bd-2aw8zg; R2 is `quota_snapshots` (bd-3qfc81); R5 is
  bd-adtnto; R7 is bd-6bxv7h; R8 is bd-c675ny.
- **Paused:** R9, R10 (bd-3jshn8), R11 and R16, per the filing.
- **No code yet:** R12–R15.

| R | What | Under this design | Verdict |
|---|---|---|---|
| R1 | `Loop.SubjectStats` | Unaffected | **Keep** |
| R2 | Quota history (`quota_snapshots`) | The budget's measurement source. It gains `seats` and `budget` columns (DC2) | **Keep**, extended |
| R3 | Draw calibration per (pool, window, model) | Still the per-model term. Its NNLS (`Calibration.fit/2`) also fits the seat-hour rate (§3.4) | **Keep** |
| R4 | Capability matrix | An eligibility drop before capacity | **Keep** |
| R5 | Scoring: `Headroom.windows/3`, `Price`, `Score` | Ranks a card's open pools. In `enforce`, feasibility moves from `gate.check` to a free seat (§7) | **Keep**, re-scoped: rank only |
| R6 | Hand competence matrix and its shadow report | Unaffected. Its shadow-and-report pattern is the model for §10 | **Keep** |
| R7 | P0 pace exemption | The exempt budget: the same `{:paced_exempt, …}` side through the same function. The config keys and their tighten-only rules are unchanged | **Fold in** |
| R9 | Within-provider model choice, plus in-flight reservations | The reservation half is seats (§3.2) plus the lag projection (§3.3). The model-choice half (`tier_models` lists, `entries/3`, `allow_upgrade`) is how a card reaches a pool with free seats (§4.2's closing note) | **Keep, re-scoped**: model choice only |
| R10 | Defer-until-reset (bd-3jshn8) | A full pool's budget rises at its reset by itself, so a card that only fits that pool already waits for the reset (§3.3). R10's distinct case is holding a card that *fits* another pool now because a cheaper pool resets soon. Under a budget, a free seat is one the pool can sustain on pace, so deferring it trades latency for nothing the budget doesn't already protect. Its one good idea, that near-reset quota is cheap, is the `n_before` term | **Drop** (close as superseded) |
| R11 | Window-share `δ` | The same per-model share drives weighted seats (DC11) and the price's `δ` (unchanged) | **Fold in** (DC11) |
| R12 | The difficulty feed | Unaffected | **Keep** |
| R13 | Learned competence | Unaffected | **Keep** |
| R14 | Blast-radius markers | Unaffected | **Keep** |
| R15 | Offline replay, inside expiring headroom | Reads `Budget.expiring/2` instead of its own formula (below) | **Keep**, re-scoped |
| R16 | Canary exploration, inside expiring headroom | A canary-arm dispatch is admitted only against `Budget.explore/2`. The canary mechanics are unchanged | **Keep**, re-scoped: its budget lives here |

**Expiring headroom, one definition.** This is what would reset unused at the
current seats:

```
expiring(w) = max(0, line(reset) − (u_now + (S·ρ + b)·t_r))
```

`explore(π) = floor(min over w of expiring(w) / (2·ρ·H))` is half of it, in
seats, with the same floored `ρ` as the budget (§3.3). Exploration seats count
against `budget(π)` like any other seat.

## 9. Observability

**Board header.** `#board-capacity` replaces the slot line in `#board-slots`
(`apps/arbiter_web/lib/arbiter_web/live/board_live.ex:1030`). It has:
- one chip per pool with seats or demand, `#pool-chip-<account>-<pool>`, for
  example "claude 3/3", "agy gemini 0/0", "agy claude-gpt 0/4";
- one chip per machine, `#node-chip-<name>`, for example "local 3/6".

A chip's state is one of free, full, held by pace or held by a hard rule.
Clicking a chip opens the existing `info_popup/1`, which `slot_cap/1` (`:1672`)
uses today. "Why claude's budget is 3" shows:
- the reason;
- the binding window with every number: used, used now, line now and line
  one horizon out, `ρ` with its rung and `n`, `b` and `H`;
- the ceiling, when it binds;
- a pending rise ("4 since 14:02Z");
- the exempt budget;
- who holds the seats;
- the command that changes the ceiling.

**Cards.** `hold_badge/1` (`:1622`) keeps the one "Waiting for capacity" badge.
Its detail names the layer:
- "claude: 3 of 3 seats (7d ahead of pace)";
- "local: 6 of 6";
- "repo vstim: 2 of 2 implementer runs";
- "fair share: default holds 3 of claude's 4; vstim has a P1 waiting".

Planned cards read "next" and "starting". `CapacityExplainer` gains the pool,
node, repo and fair-share lines, and loses `:ceiling` and `:workspace`.

**`arb scheduler status`.** `Drain.to_json/1`
(`apps/arbiter/lib/arbiter/board/drain.ex:275-289`) and the text renderer
(`apps/arbiter_cli/lib/arbiter_cli/cmd/scheduler.ex:95-110`) gain:
- `admission` (the mode, with the shadow agreement since the switch);
- `budgets`, one per pool, from `Budget.to_json/1`;
- `machines`;
- `repos`;
- `fair_share`.

MCP `scheduler_status` returns the same body, which keeps the two in parity.

Here's an illustrative layout. It isn't a capture: the Claude line reuses §3.8's
prior-rate example, and the other numbers only show the shape.

```
Board scheduler is running.
Admission: shadow (the new walk agrees on 47 of 52 dispatches since 2026-10-12)
Providers                          budget  seats  free  why
  claude:default                        3      3     0  ceiling max_concurrent 3 (quota allows 4: 5h binds ...)
  antigravity:default gemini            0      0     0  weekly 0.43 used ≥ line 0.42
  antigravity:default claude-gpt        4      0     4  5h: room for 4.6 (prior)
  codex:default                         0      0     0  paused by operator
Machines                              cap   live  free
  local                                 6      3     3
Repos                                 cap   implementer runs
  default/vstim                         2      1
Slots used: 3 (bd-…, bd-…, bd-…)
```

**Elsewhere.**
- `quota_get` and `arb quota` gain a `budget` block per account.
- A dispatch's `routing_decision` gains `budget: %{pool, budget, seats, binding,
  raw}` and the `planned` pair.
- `budget_changed` events keep a short per-pool ring buffer for the popup's
  "recent changes".
- `quota_snapshots` rows carry `seats` and `budget`, so Reports can chart budget
  against usage and the line later.

## 10. Shadow comparison and migration

### 10.1 Modes

The mode is the installation setting `scheduler_admission`. It's install-wide
because the Ready queue is (epic-aware §6.6).

| Mode | Dispatches by | Records |
|---|---|---|
| `legacy` (the default when DC6 ships) | Today's plan, gate and caps | Nothing new |
| `shadow` | Today's plan, gate and caps | The new walk's decision beside every dispatch and every hold change |
| `enforce` | The walk and the budgets | Today's decision beside every dispatch: the reverse shadow keeps running, as it did for R5 (bd-dde4l7) |

The operator may set any mode. The coordinator may set `legacy` or `shadow`:
the kill switch, and tightening only. A change takes effect on the next
Autopilot pass.

### 10.2 What shadow records

- **On every dispatch:** `routing_decision.admission_shadow`, holding
  `{policy, pick, pool, node, agrees, reason}`. In `shadow`, `pick` is the card
  the walk would have dispatched first. In `enforce`, it's the card today's plan
  would have dispatched. A pass is comparable when both sides had a candidate.
- **On every hold change:** one `admission_shadow_events` row when either side's
  outcome changes. Examples: today holds and the walk would place; or the
  walk's budget falls below today's cap. Each row records both decisions and
  every budget. It's throttled by change, not by tick.
- **On every capture:** `quota_snapshots` gets `seats` and `budget` (DC2).

**As built (DC6, bd-9ycsk4).**
- **The key.** `scheduler_admission` is an installation setting
  (`Settings.Registry`, so `arb settings`, `installation_config_*` and
  `/api/installation/config` carry it). Null means `legacy`. A coordinator may
  set `legacy` or `shadow`; `enforce` is operator-only (the registry's
  `operator_only_values`). Until DC8 wires it, `enforce` dispatches and records
  exactly as `shadow`: nothing may change a dispatch decision before DC8.
- **The walk** is `Scheduler.plan/1` handed a `:walk`. It takes the capacity
  sets (pools from `Budget.Server` with live `Quota.Seats`, the primary and
  every available node, and an optional `repos` set for DC9) and asks each
  card's candidates lazily from `Arbiter.Board.WalkInputs`. A routed workspace
  asks `ProviderRouting.availability/3` with `admission: :walk`, which answers
  eligibility only: no capacity drop and no paced drop, but the spend cap
  still drops. Any other workspace walks its agent pool in failover order.
  Entries carry `wait_cause`: `:queued`, `{:capacity, :provider | :node |
  :repo}`, `:own_hold`, and `:paused` for a paused scheduler. Placed entries
  carry their `pair`, and the plan carries `placements`.
- **Where it runs.** `Snapshot.load(admission: mode)` gathers the walk's
  inputs only under `shadow` or `enforce` and puts the plan at `board.walk`,
  beside today's plan. Today's fields are identical with or without it. Under
  `legacy` nothing in the budget path is called: `AdmissionLegacyTest` traces
  a board read and a whole Autopilot pass to pin I1 at runtime. I2 is a
  property at the board (`SnapshotWalkTest`) and at Autopilot
  (`AutopilotAdmissionTest`).
- **The records.** The dispatch record is
  `{policy, dispatched, pick, account_id, pool, pool_label, node, agrees,
  comparable, cause, reason, placements}`. An `AdmissionShadowEvent` row is
  written when `AdmissionShadow.signature/1` changes. The signature covers
  today's pick or the head it holds, the walk's first placement or the head it
  skips, and the pools below today's cap. `cause` is the walk's wait cause for
  today's pick (`capacity:provider`, `capacity:node`, `capacity:repo`,
  `queued`, `own_hold`, `paused`), or `legacy_hold` when today holds the card
  the walk places.
- **Deferred to DC8.**
  - E8's `budget_changed` subscription. In shadow the walk decides nothing, and
    the 60 s tick and today's triggers record a budget-driven change within a
    minute.
  - E21's plan-time lift cap. In shadow the walk keeps today's order, so I4
    holds and the report compares admission, not ordering.
  - The primary's at-cap rule for a resume (bd-b2iigy), which also covers a
    ReviewGate fix round re-dispatched through `Dispatch.resume/2`. I9 holds for
    every follow-up on the provider layer, and for the review-side passes on
    the node layer (`AdmissionFollowUpTest`). A resume on a full but non-zero
    primary is still deferred, as it is today. §2.2 says it shouldn't be;
    changing that would change a legacy decision (I1), so it waits for DC8's
    `ResumeSlot` seat check.

### 10.3 The report

`Arbiter.Release.admission_shadow_report/0` and `mix
arbiter.admission_shadow_report` report the following:

| Section | What it shows |
|---|---|
| Agreement | Comparable dispatches, the agreement rate, and every disagreement by cause: head-of-line skip, budget below the cap, budget above the cap (the ceiling binds, so no change), fair share, or repo cap |
| Throughput | Minutes with a free machine where today held and the walk would have placed a card, and the reverse |
| Pace safety | Per pool: the distribution of `u − line` at captures. Ahead-of-pace admissions, with count, largest `ε` and time back to the line. Projected exhaustion events (none allowed) |
| Calibration | Predicted draw (`Σ S·ρ·Δt + b·Δt`) against the actual `Δu` per interval: bias and mean absolute error, per rung. Each fit's `ρ`, `se` and `t`, and every fit the ladder passed over or floored, with why (§3.4) |
| Stability | Published budget changes per pool per day, and the median dwell |
| Near resets | Budget against seats in the last horizon before each reset, and usage in the first horizon after |

### 10.4 The gate to `enforce`

All of these, then an operator OK:
- 14 days in `shadow`;
- at least 2 weekly resets of the binding account;
- at least 50 comparable dispatches;
- every disagreement class reviewed;
- calibration bias within ±25% on the binding window;
- under one published change an hour per pool;
- no projected exhaustion.

The R6 report keeps running alongside. It compares *which account* a dispatch
picks, and this report compares *whether and which card* is admitted, so the
two don't confound each other.

### 10.5 Rollout order

1. **DC1**, any time. The deletion and the primary's hardware cap are
   independent of the rest.
2. **DC2–DC5:** measure, compute and show budgets everywhere, labelled
   "shadow".
3. **DC6 and DC7** in `shadow` until §10.4 is met.
4. **DC8, `enforce` with the ceilings kept.** `claude:default` stays at 3, so the
   budget can only lower concurrency. Run it for a week.
5. **The operator sets node and repo caps** where the static 3 was standing in
   for them. Then they clear or raise the account ceilings, one account at a
   time.
6. **DC9 and DC10**, as the operator opts in.
7. **DC11 and DC12.**

### 10.6 Migration notes

**Install `conductor_system_max_concurrent` (DC1).** A migration drops the
`installation_settings` column. Before it does, it checks the stored value:

- **Unset** (the live state, per the operator): nothing else happens.
- **Set to `K`, with no enrolled node and `nodes_local_max_workers` unset:** it
  copies `K` into `nodes_local_max_workers`. It's the same machine and the same
  number, now enforced at the node layer.
- **Set to `K`, in any case:** it logs one advisory line, which
  `arb server doctor` also shows once:

   > conductor_system_max_concurrent (K) was removed: the install's
   > concurrency is the sum of its machines' caps. To keep K on this machine:
   > `arb node set local --max-workers K`.

App env `:conductor_system_max_concurrent` is no longer read. If it's set, boot
logs a one-time warning.

**Workspace `conductor.max_concurrent` (DC1).** A data migration removes the
`conductor` key from every workspace config, including an empty `{}`, and logs
each value it removed. Afterwards the validator refuses `conductor` with:

> conductor.max_concurrent was removed (bd-8qdviv): bound a machine with
> `arb node set`, a provider with the account's `max_concurrent`, a workspace's
> use of an account with `--share`, or a repo with
> `worker.repos.<repo>.max_concurrent`.

The migration runs before the validator change, so a stored config never fails
an unrelated edit.

**Account `max_concurrent` and link `share`.** No migration. Their meaning
narrows to "ceiling", and the UI labels change.

**New keys:** `budget_split` (account), `weight` (link),
`worker.repos.<repo>.max_concurrent` (workspace) and `scheduler_admission`
(installation). All are absent by default. They go through the existing field
registries (`Arbiter.Accounts.Fields`, the workspace validator,
`Settings.Registry`), so the REST, CLI, MCP and UI surfaces get them together.

**Rollback.** Set `scheduler_admission: legacy`. The new keys are inert under
`legacy`. DC1 is the one step that doesn't roll back with the switch: its
rollback is a forward migration that restores the column, if it's ever needed.

## 11. Invariants and tests

| # | Invariant | How it's tested |
|---|---|---|
| I1 | **`legacy` means identical.** Every decision surface returns what it returns today: `Scheduler.plan/1`, `Snapshot`, `Admission`, `Gate`, `DispatchQueue` and `ResumeSlot`. Nothing new runs on the admission path | Existing suites unchanged (added cases only). A test pins that no admission path calls `Budget` under `legacy`, as R3's test does for `Scarcity.Draw` |
| I2 | **`shadow` dispatches identically.** It only adds records | Property: for any board, snapshot and occupancy, the dispatched card and the hold under `shadow` equal `legacy`'s |
| I3 | **The ceiling bounds the budget.** `budget ≤ min(max_concurrent, share)` when they're set | Property over generated snapshots, seats and ceilings |
| I4 | **The walk reproduces today's choice** when today's head is placeable and nothing is skipped | Property: one pool, one machine, no repo or fair config, budget = cap. The first placement equals today's `promote` |
| I5 | **Hard zeros are zero.** Provider refusing, pause, quota stop and warning-hold give budget 0 | Unit tests, one per rule |
| I6 | **One definition of the line.** `Budget` reaches `Pace` only through `Gate.pace/6` | A module-boundary test (no direct `Pace` call), plus fixtures that compare `line(now)` with the gate's `effective_policy` |
| I7 | **Hysteresis.** A monotone `raw` gives a monotone published budget, and oscillation inside `[B, B + 1.25)` publishes nothing | StreamData sequences |
| I8 | **No preemption.** Nothing that stops a run reads the budget | Structural: `Budget` is read only by `Admission`, the walk and the display |
| I9 | **Follow-ups are never held because a layer is full**, in any mode. A layer at a hard zero still holds them, as `:zero_only` does today. In `enforce`, they're not pace-held either | Dispatch tests per follow-up role |
| I10 | **The near-reset guard.** With a reset inside `H`, `budget ≤ n_after` | §3.8 example B as a fixture, plus a property over `t_r` |
| I11 | **The budget is finite for any fit.** Every `ρ` the function divides by is at least `ρ_min`, so the budget is at most its value with each window's `ρ` at the floor. A fit the data doesn't pin down falls through to the next rung | Property over generated snapshots with at least one trusted window, seats, `t_r` and `ρ ≥ 0`, 0 included: `raw` is finite, and the budget is at most the budget at `ρ_min`. Three fits as fixtures (Appendix A): seats that never move, so `b` takes the whole draw and `fit/2` returns `:non_positive`; seats that barely move, the two seeds with `t` near 0.5; and a noise-free `ρ` of 0.001, which passes the test and is clamped. The first two get the prior's budget, with the passed-over rung in the reason |

The fixtures are §3.8's two examples, flat mode, Codex `session`, both agy
pools with a `nil` model, a stale primary window before and after its reset,
the exempt budget, and I11's three fits.

## 12. Phased plan and ticket breakdown

| # | Title | D | Depends on | Phase |
|---|---|---|---|---|
| DC1 | Delete `conductor.max_concurrent` (install setting and workspace key) and every surface in §5.1. The primary's default cap becomes `NodeAgent.Protocol.suggestion/2`, enforced. Stamp `node_id` on the registry entry. The migrations and advisory lines (§10.6). Docs updated | 3 | — | 0 |
| DC2 | Seat-hour calibration: `seats` and `budget` columns on `quota_snapshots`; the NNLS fit `Δu = ρ·seat_hours + b·hours` per (account, pool, window), reusing `Scarcity.Calibration.fit/2`, which gains a standard error per coefficient; `H` from `ticket_transitions`; the fallback ladder, with its confidence-bound test and the `ρ` floor (§3.4); `mix arbiter.budget_calibration` and `Arbiter.Release.budget_calibration/0`. Shadow only | 3 | — | 0 |
| DC3 | `Arbiter.Quota.Budget`, the pure function (§3.3), with the `ρ` floor (I11), the hard zeros, the exempt budget and `expiring`/`explore`. The `now:` what-if on `Gate.pace/6`. `Budget.Server`: triggers, hysteresis, ETS, `budget_changed`. Nothing on an admission path reads it (a test pins that) | 3 | — (uses priors until DC2) | 1 |
| DC4 | Seats: per-pool occupancy (§3.2), with the pin seat for tickets In progress, cross-pool sub-workers and reservations. The registry stamps `account_id` and `pool`. Today's count is kept under `legacy` and `shadow` | 3 | — | 1 |
| DC5 | Observability: the capacity strip and popups, the per-card layer reasons, the `CapacityExplainer` lines, `arb scheduler status` and `scheduler_status` budgets, machines and repos, the `quota_get` budget. Labelled "shadow" until `enforce` | 3 | DC3 | 1 |
| DC6 | The walk: `Scheduler.plan/1` with capacity sets, pairs, skip-not-stop and multi-placement; `scheduler_admission` (legacy, shadow, enforce); `admission_shadow` on dispatch and on hold changes; `wait_cause` on plan entries. Ships at `legacy` | 4 | DC3, DC4 | 1 |
| DC7 | The admission shadow report (§10.3) | 2 | DC6 | 1 |
| DC8 | `enforce`: `Admission` checks `seats < min(budget, max_concurrent, share)` per pool; fresh dispatches skip the gate's pace rules; follow-ups use `pace: false`; `DispatchQueue` drops fresh quota holds; the planned pair rides into dispatch; the reverse shadow; `ResumeSlot` uses the seat check. Needs the operator's OK (§10.4) | 4 | DC6, DC7 | 2 |
| DC9 | The repo cap `worker.repos.<repo>.max_concurrent` (§5.2): validation, counting, the walk's skip, `ensure_repo_capacity/2` and the display | 3 | DC6 | 2 |
| DC10 | Workspace fair share (§5.3): `budget_split`, `weight`, the walk's skip rule, the P0 exemption and the display | 3 | DC6 | 2 |
| DC11 | Weighted seats from R3's per-model draw (folds R11) | 3 | DC8, R3 | 3 |
| DC12 | Retire legacy: the board-wide quota hold, `slots_total` as a stored number, the gate's pace rules on the fresh admission path, `legacy` and `shadow` modes. After at least 4 weeks in `enforce` | 3 | DC8 | 3 |

**Notes for existing tickets, for the coordinator to add:**
- **R9:** "the in-flight reservations move to bd-8qdviv DC3/DC4; R9 keeps model
  choice (pool reachability)."
- **R10 (bd-3jshn8):** close as superseded by bd-8qdviv §8, after the operator
  accepts this design.
- **R11:** "folded into DC11; the price `δ` is unchanged."
- **R15 and R16:** "expiring headroom is `Budget.expiring/2` (bd-8qdviv §8)."

## 13. Extension points

| # | Where | Today | Change | Ticket |
|---|---|---|---|---|
| E1 | `Gate.pace/6` (`gate.ex:621`) | Evaluates at `now` | The `now:` what-if was already there; DC3 added `Gate.fresh_pace/5` (`used = 0`, `reset_at` advanced one window) and `Gate.hard_stop/3` (the status rules alone, for the hard zeros). The routing design proposed the same what-if for R10 | DC3 |
| E2 | New `Arbiter.Quota.Budget` and `Budget.Server` | — | §3 | DC3 |
| E3 | `Concurrency.limit/2` (`concurrency.ex:236-239`), `occupants/0` (`:315-329`) | `min(max_concurrent, share)`; per-process count | `min(budget, max_concurrent, share)` per pool in `enforce`; seats (§3.2) | DC4, DC8 |
| E4 | `Admission.decide/4` (`admission.ex:183`) | Account headroom | The pool's seat headroom; the planned pool | DC8 |
| E5 | `put_dispatch/3` (`worker.ex:1206-1210`) | Workspace and provider | Plus `account_id`, `pool`, `node_id` | DC1, DC4 |
| E6 | `Scheduler.plan/1`, `step/3`, `decide/3` (`apps/arbiter/lib/arbiter/board/scheduler.ex:164-198`, `:245-315`) | Head-of-line | The walk (§4) | DC6 |
| E7 | `Snapshot.capacity_terms/3` (`snapshot.ex:793-848`), `capacity_and_slots/4` (`:461-473`), `quota_hold/2` (`:979`), `ticket_quota_holds/3` (`:1034`), `ticket_constraint_holds/3` (`:1103`), `pool_holds/4` (`:1192`) | One `slots_total`; binary holds; one sample ticket per workspace | Capacity sets per pool, machine and repo, and a per-card fit. The binary holds and the sample-based pool hold retire in `enforce`; a constraint stays a card-own hold | DC1, DC6, DC12 |
| E8 | `Autopilot` (`autopilot.ex:278-285`, `:1105-1113`) | The 15 s hold skips a card a dispatch just refused | The race fallback only; subscribe to `budget_changed` | DC6 |
| E9 | `Dispatch.dispatch/2` (`dispatch.ex:227-250`), `maybe_quota_gate` (`:2102`) | Gate, then account, then node | `opts[:planned]`; pace rules off for fresh admissions in `enforce`; `ensure_repo_capacity/2` after `:243` | DC8, DC9 |
| E10 | A follow-up's quota check: `Dispatch.resume/2`'s quota gate for a ReviewGate fix round (bd-6omte4); `ReviewerRouting.check_quota/2` (`reviewer_routing.ex:868`) | The full gate | `pace: false` in `enforce`: the hard rules only | DC8 |
| E11 | `DispatchQueue.slot_free?/2` (`dispatch_queue.ex:685`) | The cap | The seat check; no fresh quota holds in `enforce` | DC8 |
| E12 | `ProviderRouting.check_capacity/2` (`provider_routing.ex:1086`), `availability/3` (`:237`) | `account_headroom` | Seat headroom per pool; `capacity` is the sum of free seats | DC8 |
| E13 | `LocalCapacity.cap/0` (`local_capacity.ex:102-110`) | `system_max_concurrent/0`, not enforced | The hardware suggestion, enforced | DC1 |
| E14 | `Nodes.Capacity.breakdown/1` (`capacity.ex:84`), `Nodes.Overview` | A ceiling | No ceiling | DC1 |
| E15 | `CapacityExplainer` (`capacity_explainer.ex:116-120`, `:236-253`) | Six limit keys | Pools, machines, repos, fair share | DC1, DC5 |
| E16 | `Drain.to_json/1` (`drain.ex:275-289`), `apps/arbiter_cli/lib/arbiter_cli/cmd/scheduler.ex` (`:95-110`, `:200-207`) | Slots used | Budgets, machines, repos, admission mode | DC5 |
| E17 | `board_live.ex` `#board-slots` (`:1030`), `slot_cap/1` (`:1672`), `hold_badge/1` (`:1622`) | One slot line | The capacity strip and per-chip popups | DC5 |
| E18 | `validate_worker_repos/2` (`validate_config.ex:198-215`) | `seed_paths`, `prepush_check` | `max_concurrent` | DC9 |
| E19 | `Accounts.Fields`; `WorkspaceProviderAccount` | `max_concurrent`, `share` | `budget_split`; `weight` | DC10 |
| E20 | `History.record/2` (`history.ex`) | `utilization`, `ceiling` | `seats`, `budget` | DC2 |
| E21 | `QueueOrder.build/6` (`queue_order.ex:105`) | Stored `slots_total` | The plan-time capacity | DC6 |
| E22 | `Scarcity.Calibration.fit/2` (`calibration.ex:96`) | A coefficient per column, or `nil` with a reason | Plus each coefficient's standard error, for the ladder's test (§3.4) | DC2 |

**Unchanged:**
- `Pace.evaluate/4` and its verdicts;
- `gating_window/3`'s rules and their order;
- `Snapshot.normalize/2`;
- the pin and its fallback;
- the cross-family rule;
- `Placement`'s eligibility and rank;
- the ES3 order key;
- guardrail eligibility.

## 14. Alternatives considered

| Alternative | Why not |
|---|---|
| Auto-tune `max_concurrent`: a job writes the computed number into the static field | It churns an operator-owned field and its audit trail. The binary gate still sits on top, and it needs the same hysteresis anyway |
| Keep the gate, and add the budget only as a ceiling | The operator asked to replace the on/off gate. The gate also flaps at the line: seats admitted just under it all draw past it |
| Rate-limit starts (a token bucket of starts per hour) | Runs are long, so the draw is concurrent. Machines are bounded by concurrency too, so one unit across layers is simpler to explain |
| A short horizon (one run, 30–60 min) | It under-counts the commitment of a seat whose follow-ups are never held, and over-commits (§3.3, and §3.8's example B near a reset) |
| A budget in dollars | Dollars aren't the scarce unit on these plans (routing §2.4) |
| An optimal assignment of cards to pairs each pass | It breaks the ES3 order and can't be explained from its record. The greedy walk in order *is* the policy |
| Keep head-of-line blocking | It idles capacity a later card could use. The constraint hold, the per-workspace pool hold and the 15 s card hold are already workarounds for it, each covering one case |
| Preempt when a budget falls | Stranding work costs more than an overshoot that converges as tickets finish |
| Re-purpose `share` as the fair-share weight | It would silently change what a stored value means |
| Keep `conductor.max_concurrent` as an optional ceiling (RW14) | The operator ruled it out on 2026-10-10. No layer leaves it a job, and it adds a third number to every capacity surface |
| Publish a budget per window (5h, 7d) | Admission needs the minimum. The explanation still names the binding window and shows every window |

## 15. Open questions

1. **O1. Ahead-of-pace admissions.** The budget admits a few seats while a pool
   is a little past its line, so that usage is back on the line one horizon out
   (§3.3). The gate holds there. Should we accept that, or add a strict mode
   that zeroes the budget whenever any window is past its line? Shadow reports
   how often it happens and how far (§10.3).
2. **O2. Follow-ups and the paced line.** In `enforce`, follow-ups are held only
   by the hard rules (§4.5). Confirm.
3. **O3. Should the repo cap count Merging tickets with a pipeline in flight?**
   The spec counts runs. Counting pipelines would bound CI runners directly.
4. **O4. Fair-share defaults.** Opt-in per account, with weight 1 by default.
   Should it default on when two or more workspaces share an account?
5. **O5. Priority reservations.** For example, keep one seat for P0/P1 while
   P3/P4 run. This isn't designed. R7's exempt budget covers P0's pace, not
   seats.
6. **O6. The horizon `H`.** A measured median seat life clamped to [1 h, 4 h], or
   a fixed 2 h?
7. **O7. The seat unit.** A pin seat is held while a ticket waits for CI
   (bd-cut6uv's released hold). That's conservative. Should a long CI wait
   release the seat, and re-admit through `Admission` like a quota-held round
   does today?
8. **O8. A planning margin below 1.0.** `line(reset)` is 1.0 on a paced side, as
   the gate's is. Should the budget plan against `1 − m`, so that an estimation
   error doesn't hit the provider's own limit mid-run?
9. **O9. Claude per-model weekly limits as pools** (routing O12), when the OAuth
   endpoint reports them.
10. **O10. Remote pairs for other providers.** agy and Codex are local-only
    (`Placement.eligible/1`). Making them placeable is a remote-workers
    question, not this design's.
11. **O11. Install-wide or per-workspace `scheduler_admission`?** This design
    proposes install-wide, for the same reason as epic-aware §6.6: one queue,
    one key.

## Appendix A: how the numbers were produced

- **Live quota:** the worker MCP tool `quota_get` at 2026-10-10 01:40:27Z
  (capture 01:38:49Z, `oauth_poll`). The paced lines "now" are that response's
  `effective_policy`: 0.40152 (5h) and 0.62901 (7d). They match `max(floor,
  elapsed)` for 5h and 7d windows ending at 04:40Z and 10-12 16:00Z.
- **Workspace config:** `workspace_show` at the same session.
- **The primary's suggestion:** `nproc` (12) and `/proc/meminfo` `MemTotal`
  (32,555,316 kB) read inside this worker's container on the primary, put
  through `NodeAgent.Protocol.suggestion/2`: `min(div(12, 2), div(mem × 8, 10 ×
  4 GiB)) = min(6, 6) = 6`. A container may see fewer CPUs than the host, so the
  real figure is whatever the primary computes at boot.
- **Example A** (§3.8): `line(now + 2 h)` is 0.40152 + 2/5 = 0.80152 (5h) and
  0.62901 + 2/168 = 0.64092 (7d). `u_now` adds 3 seats × `ρ` × 98 s. With the
  prior row: 5h room = 0.80152 − 0.19544 = 0.60608, giving 0.60608 / (2 ×
  0.06667) = 4.55; 7d room = 0.64092 − 0.49016 = 0.15076, giving 0.15076 / (2 ×
  0.00198) = 37.99. The other rows scale `ρ` by 0.5 and 2.
- **The rates in Example A are assumptions, not measurements.** DC2 measures
  them. The account's `max_concurrent` of 3 comes from the filing; a worker
  token can't read accounts.
- **Example B** (§3.8): hypothetical state, the prior `ρ`, and `H` = 2 h.
- **The degenerate fits** (§3.4, I11) come from `Calibration.fit/2` on this
  branch, unchanged since `3d12c3e5`. They were run from a throwaway ExUnit
  probe, which isn't committed.
  - **Setup.** Ten intervals of 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 0.75, 1.25,
    1.75 and 2.25 h, in that order. `seat_hours` is a density times the
    hours, with the density uniform in [2.9, 3.0]. `Δu` is 0.0667 ×
    `seat_hours`, plus uniform noise of ±0.005, rounded to 0.01. The density
    is drawn before the noise in each interval. The seeds are
    `:rand.seed(:exsss, {s, 7, 9})` for `s` = 1..8. `t` is `ρ/se`, where `se`
    is the least-squares standard error over the columns the fit didn't pin
    at 0, with `n − 2` degrees of freedom, or `n − 1` when `b` is pinned.
  - **Seeds 4 and 7** fit `ρ` = 0.0147 and 0.0156, with `b` = 0.153 and 0.149
    per hour, and `t` = 0.54 and 0.45. Put into Example A's state, they give
    a 5h `n` of 10.2 and 9.9. Raised to Example A's floor of 0.0167, they
    give 9.0 and 9.2.
  - **The other six** fit `ρ` between 0.054 and 0.067, with `t` between 2.47
    and 321.
  - **The fit to the past.** The two degenerate fits' RMS errors, 0.0034 and
    0.0038, sit inside the other six's range of 0.0030–0.0042. They fit the
    past as well.
  - **The edge cases.** With 3.0 seats in every interval and `Δu` = 0.2 ×
    hours, `fit/2` returns `:non_positive` and `b` = 0.2. A noise-free `ρ` of
    0.001, with `b` = 0.197 and densities of 2.9–3.0, comes back
    `:calibrated` at 0.001.
- **Code citations** are against `3d12c3e5`.
