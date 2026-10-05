# Augmenting the paced quota strategy with price, competence, failure cost and priority: decision

**Task:** bd-9ck2a7 (decision, GitHub #17) · **Epic:** bd-9dr65f · **Builds
on:** the paced gate (`Arbiter.Quota.Pace`, `Arbiter.Quota.Gate`; bd-2daof2,
bd-clzkvp), most-quota routing (`Arbiter.Quota.Headroom`,
`Arbiter.Agents.ProviderRouting`; bd-40pzpj), cross-family review
(`Arbiter.Agents.ReviewerRouting`; bd-a1ke2c), the Loop's Stage 3 canary
(`Arbiter.Loop.Canary`; bd-6edc0u) and its unit of scarcity
(`Arbiter.Loop.Scarcity`; bd-69gk52, [loop-scarcity-unit](../loop-scarcity-unit.md))
· **Reconciles with:** [guardrail profiles](guardrail-profiles.md) (bd-8apkz6,
epic bd-1e80nw) · **Status:** proposed 2026-10-01. Nothing here is
implemented. The ticket plan is in [§11](#11-phased-plan-and-ticket-breakdown).

## Decision

1. **The paced gate stays the base layer and the only feasibility test.** A
   pool is feasible for a dispatch exactly when `Arbiter.Quota.Gate` would let
   that dispatch through today. Every new quantity reads the paced line through
   `Gate.pace/6`, and so through `Pace.evaluate/4`. Nothing re-derives a
   ceiling. There is no second router: every addition is one more step in the
   drop-reason pipeline or the rank step that `ProviderRouting` and
   `ReviewerRouting` already have. See [§1](#1-the-base-layer).
2. **Headroom becomes a price.** For each window a candidate would draw on,
   the price is the fraction of the remaining paced headroom the work is
   expected to use: `δ / h`, where `h = ceiling_now − used` is exactly
   `Headroom`'s number. The price rises without bound as `h` falls to 0, and
   `h ≤ 0` is infeasible, which is the gate's own `:holding` boundary. With no
   draw estimate the price is `1/h`, a monotone transform of today's ranking,
   so the price on its own changes no decision. See [§2](#2-the-objective).
3. **The objective** is `J(c) = Σ over pools of max over windows (δ/h) +
   w(priority) × E[time to merge]`. `δ` is the expected draw *including
   failure*: every attempt, fix pass and review round the choice is expected to
   cause, each priced on the pool that will actually serve it. The router
   dispatches the feasible candidate with the lowest `J`, and it blocks only
   when no candidate is feasible, which is today's paced hold. Dollars are not
   in the objective. See [§2](#2-the-objective).
4. **Competence is a measured matrix keyed by (provider, model, difficulty at
   dispatch, issue type).** It holds round-1 approve rate, review rounds, fix
   passes and attempts per task, and time to merge, all read from
   `worker_runs`, `review_gate_rounds`, `usage_events` and `issues`. **v1 is a
   hand-maintained matrix** seeded from those measurements. The cells that
   decide a cross-provider choice are thin (6 tasks for agy's D2 model), the
   token data has had provider-correlated bugs, and difficulty routing
   confounds model with difficulty. Phase 3 replaces hand entry with
   `Loop.SubjectStats`, and new numbers are adopted only through a canary. See
   [§3](#3-competence-and-expected-cost-including-failure).
5. **Priority acts in two places.** In the router, `w(priority)` prices time:
   heavy at P0, moderate at P1, zero at P2–P4. In the gate there are two opt-in
   policies. The **P0 pace exemption** lifts an exempt dispatch's paced line to
   a dedicated per-window exempt cap, never above the same side's flat ceiling
   (O2, resolved); the account grants it and the workspace may only narrow it. **Defer-until-reset** holds a feasible P2–P4
   dispatch until a pool resets, when the post-reset price plus the wait is
   cheaper. See [§4](#4-priority).
6. **Multi-pool providers are priced per pool.** A candidate becomes an
   (account, model) pair. `ModelFamily.classify/2` names its pool, and
   `Snapshot.normalize/2` already reads that pool's windows. A tier may list
   several models, and the router may pick any listed model at or above the
   policy's tier, never below. See [§5](#5-multi-pool-providers).
7. **Hard gates run before any weighting.** They are the existing drops, a new
   functional capability matrix (`capability_missing`), the guardrail profiles'
   `check_guardrails` (bd-1e80nw G13), and a floor. The floor clamps the tier
   to at least the policy's tier and at least an operator-owned blast-radius
   floor that the Loop can never lower. See [§6](#6-hard-constraints-before-any-weighting).
8. **The live router never explores implicitly.** Exploration happens only
   through the Loop canary and offline replay of closed tasks, both restricted
   to quota that would otherwise expire. This design recommends replay as the
   first step for any new model. See [§7](#7-exploration).
9. **No regression.** With every switch at its default, every decision is
   identical to today's. With one eligible candidate, the router layers can't
   change the choice or the hold. The two priority policies are gate policies
   and change holds only when an operator turns them on. This is tested with
   equivalence properties, a shadow mode, and a replay of recorded decisions.
   See [§9](#9-the-no-regression-invariant).
10. **Overrides survive every phase.** Dispatch-time provider and model
    overrides, the pins, pauses, the quota-gate bypass and `routing.rules` keep
    their current meaning. See [§10](#10-overrides-survive-every-phase).

## Why

Routing today decides with one quota number. `ProviderRouting` ranks the
workspace's attached implementer accounts by `Headroom.binding/3`, the binding
window's `ceiling_now − used`, and the gate holds a pool at its paced line.
There are three things it can't see:

- **The failure cost.** A choice that needs six review rounds isn't cheap, and
  its review rounds land on another family's pool (§3.5).
- **Priority.** A P0 and a P4 are ranked and held the same way.
- **The pools behind one provider.** agy's Gemini and Claude/GPT pools are
  separately scarce. The tier decides which one is spent, and the router never
  asks (§5.3).

This design adds those signals on top of the existing layer. Per the
operator's ruling on 2026-10-01, it does not build a parallel router or a cost
model that competes with the gate.

## 1. The base layer

### 1.1 What exists, and what this design adds to each piece

| Mechanism | Where | What it decides | What this design adds |
|---|---|---|---|
| Pace verdict | `Pace.evaluate/4` (`apps/arbiter/lib/arbiter/quota/pace.ex:72-87`), `side_ceiling/2` (`:123-128`) | Per window: the ceiling now (paced `max(floor, elapsed)` or flat, composed `min(account, workspace)`) and the verdict `:ok` / `:approaching` / `:holding` / `:sampling` | One side shape for the P0 exemption (§4.2) |
| Gate | `Gate.pace/6` (`apps/arbiter/lib/arbiter/quota/gate.ex:582-595`), `pace_thresholds/2` (`:626-635`), `side/2` (`:637-650`), `gating_window/3` (`:1010-1022`) with its rules (`:1032-1045`), `Throttle.check/4` (`apps/arbiter/lib/arbiter/quota/gate/throttle.ex:31`) | Allow or hold | A `:priority` option (§4.2) |
| Headroom | `Headroom.binding/3` (`apps/arbiter/lib/arbiter/quota/headroom.ex:60-76`) | The binding window's `ceiling − used` | `windows/3`, every trusted window's headroom (§2.3) |
| Implementer routing | `ProviderRouting` (`apps/arbiter/lib/arbiter/agents/provider_routing.ex`): `check/2` (`:615-633`), `check_quota/2` (`:718-729`), `rank/1` (`:734-741`), pin and fallback (`:379-428`) | Candidates, drop reasons, rank by headroom, the pin | Capability and floor checks; ranking by score (§8) |
| Reviewer routing | `ReviewerRouting` (`apps/arbiter/lib/arbiter/agents/reviewer_routing.ex`): `check/2` (`:457-476`), `check_quota/2` (`:536-547`), `rank/1` (`:554-561`), the family rule (`:184-231`) | The reviewer, cross-family | A capability check; ranking by price; a projection the implementer's score reads (§3.4) |
| Routing policy | `Routing.choose/3` (`apps/arbiter/lib/arbiter/agents/routing.ex:50-53`); `ByDifficulty.choose/3` (`apps/arbiter/lib/arbiter/agents/routing/by_difficulty.ex:132-138`) and its canary overlay (`:145-152`) | Model tier and thinking | The policy floor and the blast-radius clamp (§6.4) |
| Dispatch | `Dispatch.maybe_route/3` (`apps/arbiter/lib/arbiter/worker/dispatch.ex:1271-1294`), `unroute/1` (`:1305-1312`), `apply_quota_gate/5` (`:1523-1566`), the spawn's model override (`:2724-2729`) | Where routing and the gate run | Carry the chosen model; the deferred hold |
| Hold queue | `DispatchQueue.hold/5` (`apps/arbiter/lib/arbiter/workflows/dispatch_queue.ex:203-212`); drains on `quota_updated` and the 5h reset timer (`:505-511`) | Held intents, drained priority-first | `not_before` on an item (§4.3) |
| Board | `Board.Snapshot.quota_hold/2` (`apps/arbiter/lib/arbiter/board/snapshot.ex:631-641`), per-ticket holds (`:686-708`) | The Autopilot hold | A priority-aware hold for exempt work (§4.2) |
| Stage 3 canary | `Loop.Canary` (`apps/arbiter/lib/arbiter/loop/canary.ex`): `arm/2` (`:303-310`), `overlay/3` (`:322-330`); `Loop.Canary.Metrics.collect/2` (`apps/arbiter/lib/arbiter/loop/canary/metrics.ex:51`) | 50/50 arms by task-id hash, first-pass convergence, auto-revert | Canaries on matrix rows (R13) |
| Unit of scarcity | `Loop.Scarcity`: `weights/0` (`apps/arbiter/lib/arbiter/loop/scarcity.ex:143`), `calibrate/3` (`:181`), `window_share/2` (`:220`) | A run's share of the Claude 5h window | Calibration per pool, window and model (R3) |
| Cost estimator | `Usage.Estimate` (`apps/arbiter/lib/arbiter/usage/estimate.ex`): n ≥ 10 per rung (`:77`), 30-day half-life (`:76`) | A cost range per task | The fallback-ladder discipline for competence (§3.2) |

### 1.2 One definition of the line

A paced side turns into a number in exactly one place, `Pace.side_ceiling/2`
(bd-c7ll4t made it public for that reason). The gate holds through it, the
quota bars colour through it (bd-clzkvp), and `Headroom` reads it through
`Gate.pace/6`. This design keeps that rule. Every new quantity is a function of
`Headroom`'s output or of a what-if `Gate.pace/6` call (§4.3). That has two
consequences:

- An account's `threshold_mode`, floors and `window_seconds`, and the
  workspace's tightening, apply to the price exactly as they apply to the hold.
  An account the operator keeps on `flat` gets a flat price with no time
  signal, because that is what the operator asked the gate to do.
- The router can't call a pool feasible that the gate would hold, or the other
  way round. The feasibility check *is* `gate.check/4`, called exactly as
  `ProviderRouting.check_quota/2` calls it today.

### 1.3 Live state, read from the install DB on 2026-10-01

| Item | Value |
|---|---|
| Workspaces | `default`: `routing.policy: by_difficulty`, `provider_selection: most_quota`, `quota.threshold_mode: paced`, `review_agent.cross_family: true`, `agent.type: [claude, gemini]`. `emricare` and `vstim`: `by_difficulty`, paced, Claude only |
| Accounts | `claude/default`: enabled, `quota_config {threshold_mode: paced, weekly_threshold: 0.99}`, `max_concurrent 2`. `antigravity/default`: **disabled**, `max_concurrent 0` (the operator keeps agy paused, bd-1e80nw). `codex/default`: enabled, attached for metering only, with no role position |
| Implementer candidates | One in every workspace, Claude. In `default` that's because agy is disabled and Codex has no role position; in `emricare` and `vstim`, because `agent.type` is Claude only |
| Loop | A Stage 3 canary is running in `default` at D3 (`standard/high` against `premium/high`, started 2026-09-29, `canary_auto_promote: false`) |
| Claude snapshot, 13:56Z | 5h: 0.05 used, ceiling 0.35, headroom 0.30. 7d: 0.38 used against a paced line of 0.416, headroom **0.036**, `:approaching` |

The invariant's "one eligible account" case (§9) is therefore the live
condition in every workspace. None of the router layers would change a
dispatch until a second implementer account is eligible.

## 2. The objective

### 2.1 Definition

For a task `t` and a candidate `c = (account a, model m)`, served by the pool
`π(c) = ModelFamily.classify(a.provider, m).pool`:

```
J(c) =   Σ over pools π that choosing c draws on:
             max over trusted windows w of π:  δ(π, w, c) / h(π, w)
       + w(priority(t)) × E[T(c)]
```

- `h(π, w)` is the window's paced headroom, `ceiling_now − used`, from
  `Headroom` (§2.3).
- `δ(π, w, c)` is the expected draw on window `w` of pool `π` if `c` is
  chosen, including failure (§3). Attempts and fix passes land on the
  implementer's pool; review rounds land on the reviewer's. Runs that land on
  the same pool add up before pricing.
- `E[T(c)]` is the expected time from dispatch to merge for `c`'s competence
  cell (§3).
- `w(priority)` converts hours to price units (§4.1).

The router picks the feasible candidate with the lowest `J`. Ties go to
configured order, which is today's tiebreak. A candidate with no trusted
reading ranks after every priced one, which is today's rule for unknown
headroom.

### 2.2 Feasibility is the gate, unchanged

A candidate is feasible exactly when
`gate.check(task, quota, ws, account: a, model: m, now: now)` doesn't hold.
`ProviderRouting.check_quota/2` already makes that call. It covers:

- the provider refusing requests (the status rules);
- staleness (a stale 5h reading fails open; a 7d hold is sticky but bounded);
- each window's paced or flat ceiling;
- the `weekly_warning_policy`.

**At or over the line, a pool is infeasible.** The price never needs an
infinite value, because the gate removes the candidate before any price is
computed.

When no candidate is feasible the router blocks, exactly as it does today.
`select/4` returns `{:legacy, decision}`, the dispatch goes ahead on the
pre-routing provider, and `apply_quota_gate/5` holds it in the `DispatchQueue`.
The queue drains on `quota_updated` and on the reset timer.

### 2.3 Headroom as a price

For each trusted window `w` of a pool:

```
h(w)    = ceiling_now(w) − used(w)          # Headroom's number; > 0 for every feasible candidate
price   = δ(w) / h(w)                       # the share of the remaining paced headroom this work would use
P(π, c) = max over w of δ(π, w, c) / h(π, w)   # the window this draw strains most binds
```

Each property below is deliberate:

| Property | Why it matters |
|---|---|
| Continuous, and strictly decreasing in `h` | There is no threshold below the line for a queue to oscillate around (one of the filing's open questions) |
| Unbounded as `h` falls to 0; `h ≤ 0` is never priced, because it's infeasible | The price meets the gate at the gate's own boundary: `used ≥ ceiling` exactly when the verdict is `:holding` |
| Dimensionless: `δ` and `h` are both fractions of the same window | Pools with incommensurable units compare without converting units. Claude reports utilization fractions, agy reports 1,000-unit buckets, Codex reports a session percentage (filing Insight 1) |
| Reads `ceiling_now` from `Pace` | In paced mode the line rises with elapsed time, so the same `used` is cheaper late in a window, and a pool ahead of pace is dear (Insight 2: scarcity is a rate). Quota about to reset unused sits under a line close to 1.0 and is cheap |
| Takes the `max` over a pool's windows | The binding window moves with the draw (Insight 2's corollary: Claude's 5h at 0.12 while its 7d sat at 0.90) |
| Flat mode stays flat | An account kept on `flat` gets a price with no time signal. That is the gate's choice, inherited |
| Finite for every feasible candidate, including `δ ≥ h` | A draw expected to finish past the line is allowed, just as the gate allows a dispatch that will push past it (the gate checks only when a worker starts). The decision record flags `price ≥ 1` as "expected to cross the line". A barrier that went infinite there, such as `−ln(1 − δ/h)`, would hold work the gate lets through (§13) |

**Without a draw estimate**, because the competence layer is off or has no
row, the price falls back to `1/h` on every window with a unit draw, which is
`1/h` on the binding window. Ranking by `1/h_binding` ascending is ranking by
`Headroom.binding/3` descending, which is today's `rank/1`. The price on its
own therefore reproduces today's order exactly. It changes a decision only when
it's combined with the competence, reviewer or time terms (§9, I2).

**The units of `δ` change by phase:**

- **Phase 1: run-equivalents.** `δ` counts the runs a choice is expected to
  cause on each pool (§3.4), times a relative weight per (provider, model) from
  the hand matrix, defaulting to 1.0. Run counts and review verdicts don't
  depend on token capture, so the provider-correlated token bugs recorded in
  this ticket's notes (bd-28t80i, bd-96mn8i) can't bias phase 1. The cost is
  crudeness: one run is assumed to take a similar share of any pool's window.
- **Phase 2: window share.** Each run's expected draw is expressed in its
  pool's own window units, from a calibration per (pool, window, model) (R3).
  That calibration extends `Loop.Scarcity` beyond Claude's 5h window.

### 2.4 Where dollars appear

Dollars aren't a term in `J` (operator, 2026-09-24). Claude's dollar figure is
an imputed API price under a flat subscription, and agy and Gemini have no
price at all. Dollars appear in three places only:

- **As a hard limit, where money changes hands.** That means paid overage
  (`Gate.Continue`, `Quota.Overage`), API-key accounts and metered plans. The
  proposal (O9) is to express a metered account's budget as a synthetic paced
  window, with `used = spend / budget` and `reset_at` at the period boundary.
  The same `Pace` line then holds it, and the same price applies.
- **As the Claude draw proxy, until the R3 calibration lands.** This happens
  only in this document's measurements (§3.5), and they are labelled as such.
- **In reports**, as `Loop.Scarcity`'s secondary unit.

### 2.5 In-flight reservations

A quota snapshot lags dispatch by minutes: a polled row is trusted for 1,200
seconds. Several dispatches in one Autopilot tick would all see the same
headroom and herd onto the cheapest pool. Phase 2 subtracts the expected draw
of every run started on a pool *after the snapshot's `captured_at`* from `h`
before pricing (R9). Runs started before the capture are already in `used`.

## 3. Competence, and expected cost including failure

### 3.1 What is measured, and from which records

All of it exists today. Phase 1 adds no instrumentation.

| Measure | Definition | Records |
|---|---|---|
| Round-1 approve rate (`q`) | Among tasks with a ReviewGate round, the share whose first `role = 'review'` round has `converged = 1`. This is the **same definition** `Loop.Canary.Metrics` uses (`apps/arbiter/lib/arbiter/loop/canary/metrics.ex:124-144`) and the guardrail design's "clean run" uses (guardrail-profiles §6.2) | `review_gate_rounds` |
| Review rounds per task (`R`) | The number of `role = 'review'` rounds, across all attempts | `review_gate_rounds` |
| Fix passes per task (`F`) | The number of `role = 'impl'` rounds, the ReviewGate implementer rounds. CI fix passes (`worker_runs.kind = 'fix_pass'`) are counted separately | `review_gate_rounds`, `worker_runs` |
| Attempts per task (`A`) | Base implement runs (`kind = 'implement'`, `role = 'base'`): 1 plus the re-dispatches | `worker_runs` |
| Difficulty raised | The current `issues.difficulty` is above the first attempt's `difficulty_at_dispatch`, as with vs-cozecw's D2 → D3 correction | `worker_runs`, `issues` |
| Time to merge (`T`) | `issues.closed_at` (with `close_reason = completed`) minus the first attempt's `started_at`. Both the median and the mean are recorded | `issues`, `worker_runs` |
| Runs per pool and side | Every run of the task, by the pool its model draws on (`ModelFamily.classify/2`) and by side: **author** (implement, fix pass, conflict) or **review** | `worker_runs` |
| Draw per run | Weighted tokens (`Scarcity.weighted_tokens/1`) by model and role, and the window share once calibrated | `usage_events` |

Every task-level figure is attributed to the task's **first** routing choice.
That's the question the router asks: "if I choose `c` now, what will this task
cost by the time it merges?" The figure includes whatever the first choice led
to, such as re-dispatches, a coordinator escalation, a difficulty correction,
or a stronger model's later attempt.

### 3.2 Keying, and the fallback ladder

The key is `(provider, model, difficulty_at_dispatch, issue_type)`. It follows
the `Usage.Estimate` discipline: at least 10 tasks per rung, a 60-day window, a
30-day half-life for recency weighting, closed tasks only, and synthetic ids
folded to the base task.

| Rung | Key | Notes |
|---|---|---|
| 0 | (provider, model, D, type) | |
| 1 | (provider, model, D) | |
| 2 | (family, tier, D) | From `ModelFamily.classify/2` and the tier the model serves |
| 3 | The hand prior for (family, tier) | The matrix's own row, always present |

The decision record names the rung and `n` behind every candidate's score, so
a coarse estimate is visible as coarse.

**The key uses the difficulty at dispatch, not the corrected difficulty.**
Ratings on this install have run about one tier low (filing Insight 6). The
router has to predict from what it sees when it dispatches, so it keys on
`difficulty_at_dispatch`, and the bias is absorbed rather than amplified. If
D2-rated tasks are often really D3, the D2 cell's round-1 approve rate for a
weak model is low, and the router stops sending D2 work to it. Repairing the
rubric itself is the other direction of the loop. That belongs to the Loop's
existing `:difficulty_override` proposals, fed by the "difficulty raised" rate
per cell (R12).

### 3.3 Why v1 is a hand-maintained matrix

A learned model is the wrong v1, for five reasons:

1. **The cells that decide a cross-provider choice are thin.** agy's D2 model
   has 6 tasks (§3.6), its D1 model 13, and Codex has none. A learned estimate
   there is noise, with a confidence interval wider than the difference it's
   meant to detect.
2. **The data has had provider-correlated errors.** This ticket's notes
   (2026-09-21) record Codex rows at zero tokens, agy cumulative rows summed
   twice, and Gemini rows dropped. Those errors don't average out with more
   data. A hand matrix makes every number reviewable, and phase 1 uses run
   counts, which don't depend on token capture at all.
3. **Model is confounded with difficulty.** `by_difficulty` sends each tier to
   one model, so the logs rarely compare two models at the same difficulty.
   Causal comparisons need the canary's randomised arms (phase 3).
4. **Models change under the same tier.** Moving from opus-5 to opus-5-5 took
   D3's round-1 approve rate from 45% to 84% (§3.6). A matrix keyed by model id
   says which model each number belongs to.
5. **A routing decision must be explainable from its record.** The decision
   names the matrix row and rung behind each candidate's score.

The matrix is still *seeded* by measurement. A generator (R6) runs the
Appendix A queries and proposes rows with their `n`, rung and measurement date,
and the operator commits them. The matrix lives in installation settings,
operator-owned and versioned like other installation config, with code
defaults for families that have no data. Phase 3 replaces hand entry with
`Loop.SubjectStats`, which is shared with guardrails G18. New numbers are
adopted only through a canary (§7).

### 3.4 From measurements to `δ`: sides first, then pools

The matrix stores run counts by **side**, not by pool, because which pool a
side lands on depends on settings that change:

```
author runs per task = A + F   (plus CI fix passes and conflict resolvers)
review runs per task = R
```

At decision time the router maps each side to a pool:

- **The author side goes to the candidate's own pool.** Every implementer role
  after the first reuses the pin (bd-40pzpj), so later attempts and fix passes
  land where the first choice did.
- **The review side goes to the reviewer's pool.** Under cross-family review
  (bd-a1ke2c) the implementer's family decides which families may review. The
  router asks `ReviewerRouting` for a projection, meaning the reviewer it would
  pick for that implementer family with `pin: false`, and prices the review
  runs on that reviewer's pool.

```
δ(implementer pool, c) = (A_k + F_k) × weight(m)
δ(reviewer pool, c)    = R_k × weight(the projected reviewer's model)
where k = cell(c), in run-equivalents (phase 1)
```

This mapping is what makes the failure cost visible: a weak implementer's
extra review rounds land on *another family's* pool.

The decomposition is the filing's formula, `E[total] = P(converge) × cost_impl
+ P(fail) × (cost_impl + Σ review rounds + cost_redispatch + operator_time)`.
Measuring per task already sums every branch of it. `A` carries the
re-dispatches and any escalated attempt, `R` and `F` carry the failure rounds,
and "difficulty raised" is the escalation rate. Operator time isn't a pool. It
enters through `T`, because escalations are slow, and through the coordinator's
own session draw, which is metered in `usage_events` (O13).

### 3.5 Worked example: vs-cozecw

This is what happened, from the ledger (`worker_runs`, `review_gate_rounds` and
`usage_events`):

| Attempt | Implementer | Review rounds | Fix passes | Outcome | Claude-imputed $ (draw proxy) |
|---|---|---|---|---|---|
| 1: 09-19 21:21, rated D2 | agy `gemini-3.8-flash-medium` (Gemini pool), 28 min | 3 × `claude-opus-5` premium: $0.56, $0.90, $1.08. Criteria unmet: 6/6, then 6/6, then 4/6 | 2 × `claude-sonnet-5`: $1.14, $0.64 | `:review_gate_rejected` | $4.33 |
| 2: 09-19 21:49, rated D2 | The same, 14 min | 3 × opus-5: $1.08, $1.18, $1.14. Unmet: 5/6, 1/6, 1/6 | 2 × sonnet-5: $0.95, $0.34 | `:review_gate_rejected` | $4.69 |
| 3: 09-21 02:34, re-rated D3 | `claude-opus-5` premium/high, 36 min, $1.30 | 1 × opus-5, approved: $1.88 | 0 | Approved in round 1; the run ended `{:awaiting_review_timeout, 30}` | $3.17 |
| 4: 09-21 03:10, D3 | `claude-opus-5`, 28 min, $1.80 | 1 × opus-5, approved: $1.24 | 0 | Approved in round 1, merged | $3.03 |

In total that's 16 runs (2 on agy, 14 on Claude), $15.22 of Claude draw, and
36.6 hours from filing to close. On top of that came a coordinator
intervention: a difficulty correction, a `max_fix_rounds` raise and a resume.
The D2 route that looked cheap at dispatch drew **$9.02 on the Claude pool**,
because its reviews and fix passes ran there, and it merged nothing. The
attempt that succeeded drew $3.03. The agy runs recorded 3.10M input tokens,
0.06M output tokens and 57.7M cache-read tokens on the Gemini pool, which is
unpriced.

A router that minimises dispatch cost sees only attempt 1's first run, which
drew nothing on Claude. The failure branch is invisible to the metric that made
the decision.

This is what the matrix says. The figures are per task, keyed by the first
attempt, over tasks whose first attempt started between 2026-08-24 and
2026-10-01 12:00Z, counting only events before that cutoff. Runs are counted
by pool and side:

| First choice | n | Round-1 approve | Review rounds | Fix passes | Attempts | agy author runs | agy review runs | Claude author runs | Claude review runs | Time to close, median / mean (h) |
|---|---|---|---|---|---|---|---|---|---|---|
| agy flash-medium, D2 | 6 | 33% | 2.83 | 1.50 | 2.67 | 2.17 | 1.17 | 2.00 | 2.83 | 1.8 / 9.1 |
| Claude sonnet-5, D2 | 258 | 32% | 2.36 | 1.07 | 1.46 | 0 | 0.10 | 2.99 | 2.76 | 1.2 / 6.2 |
| Claude sonnet-5-5, D2 | 38 | 58% | 1.66 | 0.58 | 1.24 | 0 | 0 | 1.95 | 2.26 | 1.1 / 1.6 |
| agy flash-low, D1 | 13 | 50% | 1.69 | 0.46 | 2.23 | 2.54 | 0 | 0.54 | 2.23 | 1.1 / 11.0 |
| Claude haiku, D1 | 80 | 41% | 2.27 | 0.78 | 1.68 | 0 | 0.04 | 2.98 | 2.62 | 0.7 / 1.4 |

Two notes on that table:

- A run with no model recorded is assigned to a pool by the provider on its
  `usage_events` rows. The 1.17 agy review runs per task for flash-medium are
  review passes that ran on agy.
- Nearly all of these rows predate the implementer pin and cross-family
  review. Fix passes ran on Claude, and most reviews were Claude reviews.

Here is the 09-19 choice priced in run-equivalents, where `h_G` is the headroom
of agy's Gemini pool and `h_C` is Claude's:

- **In the regime the choice was made in** (no pin, mostly Claude reviewers),
  the measured runs price the agy route at `J = 3.34/h_G + 4.83/h_C` and the
  sonnet-5 route at `J = 0.10/h_G + 5.75/h_C`. agy wins only when
  `3.24/h_G < 0.92/h_C`, which means only when the Gemini pool has more than
  3.5 times Claude's headroom. At filing time the Gemini weekly window was
  *over* its paced line (0.762 used against 0.719; §5.3). With the paced gate
  on, agy would have been dropped as `quota_held` before any price was
  computed.
- **In today's regime** (the pin and cross-family review), the agy route's
  attempts and fix passes stay on agy, and its reviews go to a non-Google
  reviewer, which is Claude. That gives `J = 4.17/h_G + 2.83/h_C`, with
  `A + F = 2.67 + 1.50` on the author side. A sonnet-5-5 route puts its
  reviews on agy's premium Gemini reviewer (`gemini-3.1-pro-high`, the Google
  reviewer floor), so it costs `J = 1.82/h_C + 1.66/h_G`. The difference is
  `2.51/h_G + 1.01/h_C`. With unit run weights that's positive for **every**
  headroom state: with these cell numbers, the cheap pick uses more of *both*
  pools. Each term stays positive as long as a premium Gemini review draws
  less than 2.5 flash-medium authoring runs' worth of the Gemini pool, and a
  Claude premium review at least 0.64 of a sonnet-5-5 authoring run's worth of
  Claude. The hand matrix has to state those weights, and the R3 calibration
  has to measure them.
- **The P1 term.** vs-cozecw was P1. With `w(P1) > 0`, the 36.6-hour tail and
  the 9.1-hour mean time to close weigh against the agy route even where its
  pool price wins.

The D1 rows show why the matrix is keyed per cell, not per provider. At D1,
routing to agy flash-low **did** take Claude draw off the table: 2.77 Claude
runs per task, against 5.60 for haiku, for 2.54 agy runs. A per-provider
verdict such as "agy is bad" would throw that away.

Every agy cell is small (6 and 13 tasks). That's the first reason in §3.3, and
the reason the D2 conclusion ships as a hand-matrix row the operator can read,
not as a learned weight.

### 3.6 The measured baseline

The generator (R6) would seed the matrix from figures like these. They come
from the same window and keying as §3.5, for cells with at least 5 tasks. The
dollar column is Claude-imputed: agy rows carry no price, so it is the
Claude-pool draw proxy, not money.

| First choice | n | Round-1 approve (reviewed tasks) | Review rounds | Fix passes | Attempts | Difficulty raised | Time to close, mean / median (h) | Claude-imputed $ per task, mean / median |
|---|---|---|---|---|---|---|---|---|
| agy flash-low, D0 | 11 | 100% (4) | 0.36 | 0.00 | 1.36 | 0% | 5.1 / 0.4 | 0.04 / 0.00 |
| haiku, D0 | 14 | 80% (10) | 1.07 | 0.21 | 1.14 | 14% | 0.3 / 0.2 | 0.93 / 0.46 |
| agy flash-low, D1 | 13 | 50% (8) | 1.69 | 0.46 | 2.23 | 15% | 11.0 / 1.1 | 2.00 / 0.37 |
| haiku, D1 | 80 | 41% (79) | 2.27 | 0.78 | 1.68 | 18% | 1.4 / 0.7 | 2.68 / 1.77 |
| agy flash-medium, D2 | 6 | 33% (6) | 2.83 | 1.50 | 2.67 | 17% | 9.1 / 1.8 | 6.93 / 6.34 |
| sonnet-5, D2 | 258 | 32% (240) | 2.36 | 1.07 | 1.46 | 5% | 6.2 / 1.2 | 10.57 / 7.84 |
| sonnet-5-5, D2 | 38 | 58% (36) | 1.66 | 0.58 | 1.24 | 0% | 1.6 / 1.1 | 2.75 / 2.20 |
| opus-5, D3 | 159 | 45% (143) | 1.87 | 0.57 | 1.55 | 3% | 8.8 / 2.0 | 20.82 / 16.81 |
| opus-5-5, D3 | 100 | 84% (96) | 1.32 | 0.10 | 1.51 | 0% | 9.0 / 2.4 | 10.66 / 8.76 |
| sonnet-5-5, D3 | 8 | 88% (8) | 1.50 | 0.00 | 1.88 | 0% | 1.8 / 1.7 | 5.08 / 4.72 |
| opus-5, D4 | 9 | 78% (9) | 1.44 | 0.11 | 1.33 | 0% | 24.1 / 2.2 | 33.15 / 24.72 |
| opus-5-5, D4 | 6 | 83% (6) | 1.17 | 0.17 | 1.17 | 0% | 22.2 / 6.4 | 55.30 / 31.51 |

Caveats the generator must carry into every row it proposes:

- **Keying.** These figures differ from the 2026-09-24 baseline in this
  ticket's notes, which used a different window and keying.
- **Mean time to close is dominated by a few parked tasks.** The matrix records
  the median and the mean, and the generator winsorises at the 90th percentile
  so one parked task can't decide a cell.
- **Selection.** Each cell is whatever difficulty routing sent there, and the
  regime changed during the window (the pin, cross-family review, model
  versions). These are associations, not effects (§3.3, reason 3).

## 4. Priority

### 4.1 The time term

`w(priority)` converts expected hours into price units. These defaults are a
proposal only; the operator sets them after shadow mode shows the score
distribution (O3).

| Priority | `w` (price units per hour) | How to read it |
|---|---|---|
| P0 | 10 | An hour of delay is worth one run-equivalent on a pool with 0.10 headroom left |
| P1 | 2 | An hour is worth one run on a pool with 0.5 headroom left |
| P2–P4 | 0 | Time never decides |

With P0's weight, a candidate whose cell merges hours sooner beats a cheaper
pool. That is "P0/P1 may trade headroom for speed", inside the router. It never
makes an infeasible pool feasible; that is the exemption's job (§4.2).

It's set in workspace config as `routing.scoring.time_weight`. There is no
account side, because the weight doesn't loosen any limit.

### 4.2 The P0 pace exemption, a gate policy

**What it does.** For a dispatch whose task priority is exempt, each side's
*paced* ceiling becomes the larger of the paced line and a dedicated per-window
**exempt cap**, which is never above that side's *flat* ceiling:

```
exempt ceiling = max(max(floor, elapsed), min(exempt_cap, flat))
  exempt_cap = the side's dedicated pace-exempt cap for that window
               (5h and 7d set separately); unset → flat
  flat       = the side's own throttle_threshold or weekly_threshold,
               else the window's flat default (0.85 for 5h, 0.90 for 7d,
               or the app env)
```

The sides still compose `min(account, workspace)`. Concretely:

- Early and mid-window, the paced line is below the cap, so it lifts to the
  cap. A P0 may pass the paced line, but never the cap.
- Late in a window, the paced line is already above the cap and doesn't move.
  The exemption only ever raises a ceiling, and never above the cap, which is
  never above the flat ceiling. So a P0 is never held more strictly than a P2,
  and the exemption alone never takes it past the cap. A cap can only *lower*
  where the exemption stops; it never lowers the paced line.
- With the cap unset, `exempt_cap` is `flat`, which is this section's original
  proposal.
- A flat side doesn't change, because its ceiling is already the hard one.
- Only the two utilization rules move: rules 3 and 4 of `gating_window/3`. The
  provider refusing requests (status rules 1 and 2), the `allowed_warning`
  hold (rule 5) and staleness don't move. The exemption never touches
  eligibility, as guardrail-profiles §5.7 already says.

**Why a dedicated cap (O2, resolved 2026-10-05).** Today's flats are 0.99 on
the `default` workspace and the Claude account (§1.3), so an exemption capped
only by the flat ceiling would let a P0 run Claude's 7d window to 0.99 early in
the week. The dedicated cap stops P0s from waiting for the pacing line without
letting them use up the week. The operator's starting values are 0.95 for 5h
and 0.90 for 7d.

**It lives in `Pace`, so there is still one definition of the line.**

- `Pace.side_ceiling/2` gains one side shape,
  `{:paced_exempt, floor, flat, cap}`, where `cap` is `min(exempt_cap, flat)`,
  already resolved by the gate. It resolves to
  `{max(max(floor, elapsed), cap), :exempt}`, or to `{max(floor, elapsed),
  :paced}` when the line is already at or above the cap (the exemption lifted
  nothing, so it doesn't claim to). When `elapsed` is unknown it falls back to
  `{flat, :flat}`, which is the existing paced fallback.
- `Gate.pace_thresholds/3` emits that shape for each *paced* side when the
  dispatch is exempt (`Gate.pace_exempt?/2`). The cap is composed
  `min(account, workspace)` across the sides, then clamped to each side's flat.
- `Gate.pace/6`, `gating_window/3` and `Headroom.binding/3` /
  `Headroom.windows/3` take a `:priority` option. `Throttle.check/4` passes
  `task.priority`; it already receives the task and ignores it. The priority
  is the ticket's **own**, never an epic floor's (§4.4).
- The router then reads the lifted line through `Headroom` with no code of its
  own.
- `Pace.t()`'s `mode` gains `:exempt`, so the quota bar and the hold phrase can
  say "P0 exempt". A binding held at the lifted ceiling carries
  `mode: :exempt` and `priority`, and its phrase reads
  `7d 91% ≥ P0 exempt 90% (30% elapsed)`.

**Config surface:**

| Setting | Where | Who may loosen it | Who may tighten it |
|---|---|---|---|
| `pace_exempt_priority`: 0–4, the lowest-urgency priority that is exempt. Absent means none | Account `quota_config` | The operator | The operator or the coordinator |
| `pace_exempt_threshold` and `weekly_pace_exempt_threshold`: a fraction in (0, 1], the dedicated exempt cap for the 5h and 7d windows. Absent means the side's flat ceiling | Account `quota_config` | The operator | The operator or the coordinator |
| `quota.pace_exempt_priority`: 0–4, or `"none"` | Workspace config | Nobody: it can only narrow the account's value | The operator or the coordinator |
| `quota.pace_exempt_threshold` and `quota.weekly_pace_exempt_threshold`: a fraction in (0, 1] | Workspace config | Nobody: it can only lower the account's cap | The operator or the coordinator |

The cap keys follow the existing `throttle_threshold` / `weekly_threshold`
naming: the unprefixed key is the 5h window and the `weekly_` key is the 7d one.
Each cap composes `min(account, workspace)`, with an absent side meaning "the
other side's", so a workspace that sets one only ever lowers where the account's
exemption stops; it is then clamped to each paced side's flat ceiling.

The effective value is `min(account, workspace)`, where an absent workspace
value means "the account's" and `"none"` means no exemption. That's the P7
tighten-only rule, with one deliberate difference from `Gate.strictest/2`
(`apps/arbiter/lib/arbiter/quota/gate.ex:682-685`). There, a workspace value
applies when the account sets none. Here, the account must grant the
exemption: an account without the setting exempts nothing, whatever the
workspace says. The account values are validated in
`Gate.validate_quota_config/1` (`pace_exempt_priority` an integer 0–4; the caps
fractions in (0, 1]), and the workspace values in the workspace config
validator. Both reject an out-of-range value outright. All three account keys
are settable through `PATCH /api/accounts/:ref`, which goes through that
validator.

**Audit.** An exempt dispatch that is past the paced line but under the cap
records `pace_exempt: {window, used, paced, cap}` on the run's
`routing_decision`, where `paced` is the ceiling the same dispatch would have
held at without the exemption and `cap` the exempt ceiling in force. The key is
absent when the exemption didn't decide the dispatch, so a decision with the
layer off is unchanged. It also broadcasts a `quota_pace_exempt` event
(`task_id`, `priority`, `provider`, `account`, `pace_exempt`), alongside the
existing `quota_gate_bypass` event. The record comes from
`Gate.pace_exemption/3`, which compares the paced and exempt verdicts for each
trusted window.

**The board.** Per-ticket holds (`ticket_quota_holds/3`,
`apps/arbiter/lib/arbiter/board/snapshot.ex:686-708`) evaluate each card with its
own task, so a P0 card reads as dispatchable. The board-wide `quota_hold/2`
(`:631-641`) evaluates with no task, so it would keep Autopilot from promoting
that card. R7 makes it priority-aware per card: with routing on, each card's
own candidates already evaluate with its task, so its priority reaches the gate;
with routing off, a card whose own priority is exempt gets its own verdict at
the lifted ceiling, so it is held only when the exempt cap is reached too (the
phrase then says "P0 exempt"). Cards that aren't exempt keep the board-wide
hold. A held intent in the dispatch queue is re-checked with its ticket, so a P0
held at the cap drains as soon as it is back under it. The quota bar's tooltip
adds "P0 exempt up to 90%" when the account grants the exemption.

### 4.3 Defer until reset, for low priority

At P2–P4, waiting can be the cheapest route: a pool close to its line that
resets in twenty minutes is about to be fresh.

**When it triggers.** All of these must hold:

1. The workspace enables it (`routing.defer_to_reset.enabled`; off by default).
2. The task's priority is within `min_priority` (default: P2–P4).
3. It's a fresh `:main` dispatch, never a resume, fix pass, conflict resolver
   or review. Those continue work already in flight.
4. Some candidate pool `π*` resets within `max_wait` for that window. The
   default is 60 minutes for 5h windows; weekly windows are off by default.
5. The post-reset price plus the wait beats the best feasible price now by a
   margin: `J_after(π*) + w(priority) × wait < (1 − m) × min J_now`, with
   `m = 0.25`.
6. The task hasn't already been deferred for this reset.

**The post-reset price comes from `Pace` too.** `J_after` is the same `J`, with
the resetting window evaluated as a what-if: `Gate.pace/6` at
`now = reset_at` with `used = 0`. That gives `h = floor` in paced mode, or the
flat ceiling in flat mode. The pool's other windows keep their current
readings, because a 5h reset doesn't reset the 7d window. There is no second
formula.

**The mechanism:**

- The router returns a third outcome, `{:defer, until, decision}`.
- Dispatch holds the intent with `DispatchQueue.hold/5`
  (`apps/arbiter/lib/arbiter/workflows/dispatch_queue.ex:203-212`). The reason
  is `%{kind: :deferred, until: reset_at, pool: π*, phrase: "deferred until
  claude 5h resets at 17:40Z (P3)"}`.
- The queue stores `not_before` on the item and arms a timer for it, as it
  already does for the 5h reset (`:509`).
- On release, the intent replays unrouted (`unroute/1`) with deferral turned
  off. It routes afresh and can't be deferred twice (condition 6). That's the
  hysteresis.

**It can't starve work.** The wait is bounded by `max_wait`. A task is
deferred at most once per reset. P0 and P1 never defer by default. A dispatch
that bypasses the quota gate (`skip_quota_gate`, or MCP `force_quota`) skips
deferral too, so the operator and the coordinator can always send a task now.
And if every candidate is infeasible, nothing is deferred: that's the gate's
ordinary hold, which drains on `quota_updated` and the reset timer as it does
today.

**Config** is workspace-only:
`routing.defer_to_reset: {enabled, min_priority, max_wait_minutes: {"5h": 60}}`.
Deferral only ever holds more work, so it can only tighten, and the coordinator
may set it.

**A note on the filing's wording.** The filing says to defer "when a pool is
behind pace and resets soon". In `Pace`'s vocabulary (bd-clzkvp, the one
definition of "ahead of pace"), the condition that makes waiting cheap is a
pool **ahead** of pace that resets soon, meaning its usage is close to or past
its line. A pool *behind* pace that resets soon is the opposite case: its
quota is about to expire unused, its line is close to 1.0 and its price is low,
so the router spends it. Both cases fall out of `J` with no special handling.

### 4.4 All the priority settings

| Setting | Where | Default | Can it loosen a limit? | Who sets it |
|---|---|---|---|---|
| `routing.scoring.time_weight` | Workspace | P0 10, P1 2, P2–P4 0 (proposed) | No: it reorders feasible candidates | Operator or coordinator |
| `pace_exempt_priority` | Account `quota_config` | Absent (no exemption) | **Yes**: it lifts the paced line up to the exempt cap | Operator |
| `pace_exempt_threshold`, `weekly_pace_exempt_threshold` | Account `quota_config` | Absent (the flat ceiling) | No: it can only lower where the exemption stops, never above the flat ceiling | Operator |
| `quota.pace_exempt_priority` | Workspace | Absent (inherits the account's) | No: it can only narrow the account's value | Operator or coordinator |
| `quota.pace_exempt_threshold`, `quota.weekly_pace_exempt_threshold` | Workspace | Absent (inherits the account's) | No: it can only lower the account's cap | Operator or coordinator |
| `routing.defer_to_reset` | Workspace | Off | No: it only holds | Operator or coordinator |

**Own or effective priority (bd-1d1yaj).** An epic floor gives a ticket an
*effective* priority above its own ([epic-aware scheduling §6.4](epic-aware-scheduling.md#64-routing-and-the-quota-gate-own-or-effective)).
`w(priority)` (§4.1) and the P0 pace exemption with its board hold (§4.2) read
the ticket's **own** priority, because they spend headroom or loosen a line.
Defer-until-reset (§4.3) reads the **effective** priority, because it only
holds.

## 5. Multi-pool providers

### 5.1 A pool, and its headroom

A pool is an (account, bucket group) pair. agy has two pools,
`antigravity:gemini_models` and `antigravity:claude_and_gpt_models`. Each has a
5h and a weekly window, which makes four readings, all read from
`GoogleQuota.snapshot["models"]`.

Both pieces needed to price a pool already exist:

- `Snapshot.normalize(quota, model: m)`
  (`apps/arbiter/lib/arbiter/quota/gate/snapshot.ex:111`) projects the group
  that model `m` draws on onto the gate's primary and secondary windows.
- `ModelFamily.classify/2` (`apps/arbiter/lib/arbiter/agents/model_family.ex:75-88`)
  names the same pool for routing, using the same prefix rule: `claude-*` and
  `gpt-*` are the Claude/GPT pool, and anything else is the Gemini pool.

So per-pool headroom exists today, as `Headroom.binding(quota, policy, model: m)`.
What's missing is a candidate for each pool.

### 5.2 Candidates become (account, model) pairs

- **The model set.** Today `agent.config.<adapter>.tier_models.<tier>` maps a
  tier to one model id. It may also be an **ordered list**. The first entry is
  the default, and a one-element list behaves exactly like today's string. A
  new `ModelFamily.models_for_tier/3` returns the list, and `model_for_tier/3`
  keeps returning the first entry.
- **Expansion.** `ProviderRouting.entry/3`
  (`apps/arbiter/lib/arbiter/agents/provider_routing.ex:586-598`) becomes
  `entries/3`, with one entry per listed model for the policy's tier. With
  `routing.scoring.allow_upgrade: n`, it also adds the models of up to `n`
  tiers above the policy's. It **never goes below the policy's tier** (§6.4).
- **Everything is per entry, and so per pool:** the drop reasons (`check/2`),
  feasibility (`gate.check` with `model:`), headroom (`Headroom` with
  `model:`), and the competence cell (provider, model).
- **Carrying the choice.** The selection gains `:model`. `Dispatch.maybe_route/3`
  (`apps/arbiter/lib/arbiter/worker/dispatch.ex:1271-1294`) puts it in
  `opts[:model]`, which the spawn already applies last (`apply_model_override`,
  `:2729`). `unroute/1` (`:1305-1312`) strips it when routing set it, as it
  strips `:routed_agent_type`, so a held intent routes afresh on replay.
- **The pin** stays (account, family). For agy the family already separates
  the pools (`:google` is Gemini; `:anthropic` and `:openai` are Claude/GPT),
  so later roles stay in the pool the first choice drew on.

With one model per tier, which is every workspace's config today, expansion
yields today's single entry per account (§9, I2).

### 5.3 Worked example: agy

At filing time (2026-09-21 03:27Z), with the paced weekly floor of 0.20:

| Pool | Used | Resets | Elapsed | Paced line | Headroom | Verdict |
|---|---|---|---|---|---|---|
| agy Gemini, weekly | 0.762 | 09-23 02:43Z | 0.719 | 0.719 | −0.043 | `:holding` |
| agy Claude/GPT, weekly | 0.122 | 09-24 01:27Z | 0.583 | 0.583 | 0.461 | `:ok` |

A D1 ticket routes to `economy`, which agy's built-in map
(`apps/arbiter/lib/arbiter/agents/gemini/config.ex:46-51`) resolves to
`gemini-3.8-flash-low`. That's the Gemini pool, which was 4.3 points *ahead*
of pace, while the Claude/GPT pool sat 46 points under its line. This is the
filing's Insight 2 in `Pace` terms: 23.8% left with two days to go was the
scarcer pool, and the paced gate says so.

Live on 2026-10-01 at 13:56Z, under `default`'s paced policy, the pools read as
follows. agy is disabled, so this is what routing would see if it weren't.

| Pool | Window | Used | Line | Headroom | Verdict |
|---|---|---|---|---|---|
| Claude | 5h | 0.05 | 0.35 | 0.30 | `:ok` |
| Claude | 7d | 0.38 | 0.416 | **0.036** | `:approaching` |
| agy Gemini | 5h | 0.001 | 0.35 | 0.349 | `:ok` |
| agy Gemini | weekly | 0.260 | 0.210 | −0.050 | `:holding` |
| agy Claude/GPT | 5h | 0.000 | 0.35 | 0.35 | `:ok` |
| agy Claude/GPT | weekly | 0.000 | 0.20 | **0.20** | `:ok` |

Here's how each layer would route a D1 (`economy`) dispatch in `default` if
agy were enabled and attached for the implementer:

- **Today (`most_quota`).** agy's predicted model is `gemini-3.8-flash-low`.
  Its Gemini weekly window is over the line, so agy drops as `quota_held`.
  Claude is the only candidate, so the work goes to haiku, on a 7d window with
  0.036 headroom left.
- **With model choice.** Say `tier_models.economy` lists a Claude/GPT-pool
  model after `gemini-3.8-flash-low`, or `allow_upgrade` reaches agy's
  `flagship`, `claude-opus-4-6-thinking`. Then the agy Claude/GPT entry is
  feasible with 0.20 headroom. With no draw estimate, its price is
  `1/0.20 = 5` against Claude's `1/0.036 ≈ 28`, so the router picks the
  Claude/GPT pool. That is the pool the D1 dispatch on 09-21 should have drawn
  on.
- **With competence and reviewer coupling.** The agy Claude/GPT model is
  `:anthropic`-family, so cross-family review needs a non-Anthropic reviewer.
  agy's Gemini reviewer is held (its weekly window is over the line), and Codex
  isn't a reviewer in `default`. So `ReviewerRouting` falls back to a
  same-family Claude reviewer, and records it. The projection prices those
  review runs on Claude's 0.036. It does the same for a haiku implementer,
  whose Gemini reviewer is held too. The review term lands on Claude either
  way, so the comparison turns on the author side and on each cell's expected
  review count. Without the projection, the router would believe the agy route
  moved all the draw off Claude.

The upgrade case needs watching: `flagship` costs more pool per run than a D1
needs. `allow_upgrade` is off by default, and when it's on, the run weights in
the matrix are what stop an upgrade from looking free.

### 5.4 Other pool shapes

| Shape | Treatment |
|---|---|
| Claude per-model weekly limits | `AnthropicQuota.per_model_utilization` captures `seven_day_<model>` keys from the OAuth usage endpoint (`apps/arbiter/lib/arbiter/quota/oauth_usage.ex:357`). The field was empty on this install on 2026-10-01. When it's reported, each key is a third window for the models it covers, added through `Snapshot.normalize(model:)` the way agy's groups are (O12) |
| Codex `session` | The window has no fixed length (`Gate.window_seconds/2`), so a paced side falls back to flat and the price carries no time signal, unless the account sets `quota_config.window_seconds.session` |
| Local LLMs (`:local` family; no adapter yet) | There's no quota window; the scarce resource is slots. `Concurrency.account_headroom/3` already drops a candidate at zero slots (`at_capacity`), and the price is `1 / free slots` (O8) |
| Metered or API-key accounts | A budget window (§2.4, O9) |

## 6. Hard constraints before any weighting

### 6.1 Order

`ProviderRouting.check/2` (`apps/arbiter/lib/arbiter/agents/provider_routing.ex:615-633`)
and `ReviewerRouting.check/2` (`apps/arbiter/lib/arbiter/agents/reviewer_routing.ex:457-476`)
run their drop reasons in order and stop at the first. The new checks go after
the existing availability checks and **before** `check_quota`. Quota is never
evaluated for an ineligible candidate, and nothing is weighed until the
candidate set is final:

```
account → adapter → cli → auth → circuit → capacity → confinement   (today)
  → capability  (new, §6.2; drop reason capability_missing)
  → guardrails  (bd-1e80nw G13; guardrail_ineligible)
  → floor       (new, §6.4; below_floor; implementer roles only)
  → quota       (today; quota_held, the feasibility test)
then price, competence and time, over the survivors only
```

Each new drop is recorded in `routing_decision.dropped`, like every other drop.
`capability_missing` joins `ReviewerRouting`'s `@fallback_triggers`
(`reviewer_routing.ex:106-107`), the same way G13 adds `guardrail_ineligible`.
The floor is implementer-only: the reviewer's tier already has its own floor,
the ReviewGate's tier bump plus `ModelFamily.reviewer_tier/2`.

### 6.2 The capability matrix

Functional capability is a separate question from trust; guardrail-profiles
§3.4 and §8 assign it to this design. Rows match (provider, model glob), most
specific first, and carry their evidence. These are the proposed initial rows:

```elixir
# Code defaults; an installation override is operator-owned.
[
  %{match: %{provider: "antigravity"}, resume: true, async_verification: :unreliable,
    evidence: ["bd-b7e33c: splice_prompt/2", "bd-40h2to: turn ends while run_command is backgrounded"]},
  %{match: %{provider: "claude"}, resume: true, async_verification: :reliable},
  %{match: %{provider: "codex"}, resume: true, async_verification: :unknown}
]
```

| Capability | Values | Required by |
|---|---|---|
| `resume` | `true` or `false` | The `:resume` role and reconciler resumes |
| `async_verification` | `:reliable`, `:unreliable` or `:unknown` | Repos (and later tickets) that declare `requires: [async_verification]`, such as this repo, whose suite takes 5–10 minutes |

Two things are deliberately not in the matrix, because they already have a
home:

- **`:strict` eligibility** is the adapter's per-host `write_confinement/1`
  answer (bd-1abj7u) and the existing `write_confinement_none` drop. A matrix
  row can't contradict what the host can enforce.
- **Trust, reach, data classes and `max_difficulty`** are guardrail profiles
  (bd-1e80nw).

Requirements come from the role (resume roles need `resume`), from repo config
(`repos.<repo>.routing.requires`), and later from ticket markers (§6.4). A
missing capability drops the candidate as `capability_missing`, with detail
such as "needs async_verification; antigravity/gemini-3.8-flash-low:
unreliable (bd-40h2to)". `:unknown` fails closed for a required capability and
open otherwise. The whole check sits behind `routing.capability_gates: true`
(off by default), and it works under `most_quota` as well as `scored`.

When every candidate is dropped, today's `no_candidate` path dispatches on the
pre-routing provider. That path must apply the same check, as G13 specifies for
guardrails, or the gate is only advisory (E17).

### 6.3 Guardrails

This design consumes the guardrail checks; it doesn't duplicate them. G13 adds
`check_guardrails` to the same pipeline, covering trust tier, ticket
permissions, data classes, scope and the subject's `max_difficulty`. This
design adds nothing to it and reads nothing from it except the drop. When no
permitted candidate has quota, the ticket holds and never falls back to an
unpermitted one (guardrail-profiles §5.7). That's the same statement as "block
only when every eligible pool is over its line", with "eligible" now including
guardrails.

### 6.4 Floors

There are two floors. Both clamp the tier the router may choose.

1. **The policy floor.** The router never chooses a model below the tier the
   routing policy (`Routing.choose/3`) assigns. Scoring can move work across
   pools and *up* tiers, but it can't buy quota with quality. Lowering a tier
   is a policy change, and policy changes go through `routing.rules`: by the
   operator, or by the Loop's Stage 3 canary, which measures the change and
   reverts it automatically (bd-6edc0u). The canary running in `default` today
   is exactly such a change, at D3.
2. **The blast-radius floor.** This is a minimum tier for work whose failure is
   expensive whatever its predicted competence (filing Insight 8): the control
   plane, security boundaries such as the `SandboxNodePool` sandbox, and bulk
   changes to production data. It's **operator-owned and outside the Loop's
   reach**. No canary, proposal or matrix update may lower it.
   `ByDifficulty.merged_rule/3`
   (`apps/arbiter/lib/arbiter/agents/routing/by_difficulty.ex:145-152`) applies
   it after `Canary.overlay/3`, so a canaried rule is clamped too. Such a
   dispatch didn't get the canaried rule, so it's recorded as clamped and
   `Canary.Metrics` leaves it out of the canary arm (R8).

The blast-radius floor is declared in two stages:

- **Phase 1: per repo.** `routing.floors.repos.<repo>.min_model_tier`. Only the
  operator may lower it; the coordinator may raise it. It's coarse, but every
  task has a repo today.
- **Phase 2: per ticket, as blast-radius markers.** The guardrail design's
  `issues.permissions` (G12) is the natural home, with entries such as
  `blast:control_plane`, `blast:security_boundary` and `blast:prod_data`. Each
  is a data-class-like entry with no reach: anyone may add one, and only the
  operator may remove one. Each binding carries a `min_model_tier`. If G12
  hasn't landed by then, a dedicated field is the fallback (O11).

The guardrail design already supplies the *trust* half of a blast-radius
floor: a subject's tier and `max_difficulty`, and permissions for prod reach.
This floor is the *capability* half: how strong the model must be, not how far
it's trusted.

**As built (R8, bd-c675ny).** `Arbiter.Agents.Floors` holds both floors.

- The repo floor is `routing.floors.repos.<repo>.min_model_tier`, on the ladder
  `economy < standard < premium < flagship`. `Routing.choose/3` clamps the
  chosen `model_tier` to it for every policy, and `ByDifficulty` does so after
  `Canary.overlay/3`. A raised choice carries `floor: %{tier:, from:, repo:}`;
  `Dispatch` records it as `worker_runs.floor_clamped`, and `Canary.Metrics`
  leaves a clamped dispatch out of **both** arms (a clamped baseline rule did
  not run either) and reports how many it left out as `clamped`.
- The policy floor is `routing.floors.policy_floor: true`. It is a switch, not
  always-on, because with today's single tier per dispatch it can only change a
  decision when a model is pinned below the tier the policy chose, and §9 I1
  needs off to mean identical.
- `below_floor` is a drop in `ProviderRouting.check/2`, after `capability` and
  before `quota`. `Dispatch.ensure_floor/2` repeats the check on the legacy
  path (E17), refusing `{:error, {:below_floor, provider, phrase}}`. An
  operator's explicit `model:` is an override, not routing (§10), and is not
  checked.
- A model, or a tier, with no rank on the ladder is never below a floor: a
  floor is only enforced where both sides are known.
- Not built: the coordinator-may-raise / operator-may-lower authority split on
  `routing.floors` (config writes carry no such distinction today), and the
  phase 2 per-ticket markers (R14). Both Loop paths — the canary and
  `Canary.eligible/1`'s `routing.rules`-only patch — already cannot reach it.

### 6.5 When nothing survives

| Situation | Outcome |
|---|---|
| Every candidate is dropped before the quota check (capability, guardrails or floor) | This isn't a quota problem, so waiting can't fix it. The card gets a specific hold with the reasons. Where guardrails are the cause, their `:no_eligible_model` attention cause applies (guardrail-profiles §5.7) |
| Candidates are eligible but none is feasible: every pool is over its line, or held | Today's quota hold in the `DispatchQueue`, drained on `quota_updated` and the reset timer |
| A candidate is feasible and the deferral conditions hold (§4.3) | A deferred hold with `not_before` |

## 7. Exploration

### 7.1 The options

| Option | Verdict |
|---|---|
| Implicit exploration in the live router (UCB, Thompson sampling) | **Rejected.** Every pull is a real dispatch. It burns a window, and when the model is worse its failure lands on the reviewer's pool too (§3.5). It makes routing non-deterministic and the decision record unexplainable. And it explores on whatever work arrives, D4 included |
| An optimistic cold start, giving an unmeasured model the benefit of the doubt | **Rejected**, for the same reason: optimism is exploration. A new model gets its family-and-tier prior from the matrix (rung 3), read pessimistically at the low end of the prior's range |
| The live canary (Loop Stage 3) | **Accepted, with constraints.** It already splits by task-id hash, measures first-pass convergence on both arms, reverts automatically and expires. It's extended to matrix rows (R13), within eligibility, at D0–D2, for tickets with no blast-radius marker or permissions, and only in quota that would otherwise expire (§7.3) |
| Offline replay of closed tasks | **Accepted, as the first step for any new model** (§7.2) |
| Shadow scoring | Accepted, but it isn't exploration. It shows what the scorer would choose; it never observes an outcome the fleet didn't produce |

### 7.2 Offline replay, evaluated

Replay re-runs a closed task on the candidate model, in a worktree at the
task's original base commit, with no PR and no merge, and scores the result.

- **Scoring.** The main score is the ReviewGate reviewer's round-1 verdict
  against the ticket's acceptance criteria: the same `converged` signal live
  competence uses. The repo's tests also count, and diff overlap with the
  merged change is a weak secondary signal.
- **Costs.** The replay itself draws on the explored pool, and the scoring
  review draws on a reviewer pool. Setting up the environment (dependencies at
  an old commit) costs wall-clock time and slots.
- **Risks:**
  - Selection: closed tasks are the ones that got solved.
  - Staleness: the base commit predates later fixes.
  - Coupling: tasks tied to external state (prod, the network, tracker writes)
    can't be replayed. Replay runs under the subject's guardrail profile like
    any dispatch, and anything with permissions is excluded.
  - Leakage: the merged code isn't in the replay worktree, but a model's
    training data may still have seen a public repo.
- **Verdict.** Replay is the preferred way to give a new model its first
  matrix row. It has no production exposure and no merge, and it controls the
  mix of difficulty and type. Replay evidence is recorded as its own source,
  with its own weight, and it never reaches the live matrix without a canary.

### 7.3 Spend only quota that would expire

All exploration, replay jobs and canary-arm dispatches alike, runs only in a
pool's **expiring headroom**: the quota that will reset unused at the current
burn rate.

```
expiring(w) = max(0, ceiling_at_reset(w) − (used(w) + burn_rate(w) × time_to_reset(w)))
```

`ceiling_at_reset` comes from `Gate.pace/6` evaluated at the reset: 1.0 for a
paced side, or the flat ceiling for a flat one. The burn rate comes from the
quota sample history (R2). Exploration may spend at most half of the expiring
headroom. Quota near its line is never spent on learning, and the quota that
is spent was going to expire anyway. That's the cheapest learning available:
the price of expiring quota is close to zero by construction.

## 8. Extension points

| # | Where | Today | Change | Switch |
|---|---|---|---|---|
| E1 | `Pace.side_ceiling/2` (`apps/arbiter/lib/arbiter/quota/pace.ex:123-128`); `t:side/0` (`:47`); `t:t/0`'s `mode` (`:58`) | Paced and flat sides | `{:paced_exempt, floor, flat, cap}` resolves to `{max(max(floor, elapsed), cap), :exempt}`, with `cap = min(exempt_cap, flat)` | Exemption (§4.2) |
| E2 | `Gate.side/2` (`apps/arbiter/lib/arbiter/quota/gate.ex:637-650`), `pace_thresholds/2` (`:626-635`), `pace/6` (`:582-595`), `gating_window/3` (`:1010-1022`) | No priority | A `:priority` option; an exempt side when the resolved `pace_exempt_priority` covers the task | Exemption |
| E3 | `Gate.validate_quota_config/1` (`gate.ex:361-370`), and the workspace config validator | — | Validate `pace_exempt_priority` and the per-window exempt caps | Exemption |
| E4 | `Throttle.check/4` (`apps/arbiter/lib/arbiter/quota/gate/throttle.ex:31`) | Ignores the task | Passes `task.priority` | Exemption |
| E5 | `Headroom` (`apps/arbiter/lib/arbiter/quota/headroom.ex:60-102`) | `binding/3` | Add `windows/3`: every trusted window, through the same `Gate.pace/6` path. A `:priority` option | Price |
| E6 | New `Arbiter.Quota.Price` | — | Pure: the price from `Headroom.windows/3` and a draw, and the what-if reset price for deferral | Price, defer |
| E7 | `ProviderRouting.entry/3` and `predicted_model/3` (`apps/arbiter/lib/arbiter/agents/provider_routing.ex:586-613`) | One model per account | `entries/3`, over `models_for_tier` and `allow_upgrade` | Model choice |
| E8 | `ProviderRouting.check/2` (`:615-633`) | Eight checks | `check_capability` and `check_floor` before `check_quota`, with G13's `check_guardrails` beside them | Capability gates, floors |
| E9 | `ProviderRouting.rank/1` (`:734-741`) | Sort by headroom | `rank/2`, calling `Arbiter.Agents.Routing.Score.rank/2` under `scored` with `enforce`; today's sort otherwise | Scoring |
| E10 | `ProviderRouting.context/3` (`:556-574`) | Tier, quota function, gate | Add the priority, scoring config, matrix and reviewer projection | Scoring |
| E11 | `ProviderRouting.candidate_record/1` (`:765-782`), `put_chosen/3` (`:502-519`) | Headroom fields | Add `price`, `expected_runs`, `cell` (key, rung, n), `time_h`, `score`, `shadow`, `pace_exempt` and `deferred_until` | Additive only |
| E12 | `ProviderRouting.select/4` (`:244-256`), `choose/5` (`:379-390`) | `{:ok, _}` or `{:legacy, _}` | A third outcome, `{:defer, until, decision}`, for fresh `:main` dispatches only. The selection gains `:model` | Defer, model choice |
| E13 | `ReviewerRouting.check/2` (`apps/arbiter/lib/arbiter/agents/reviewer_routing.ex:457-476`), `rank/1` (`:554-561`), `context/3` (`:365-383`) | Rank by headroom | `check_capability`; `rank/2` by price; an `:implementer_family` option for a no-pin projection | Scoring |
| E14 | `ReviewerRouting`'s `@fallback_triggers` (`:106-107`) | — | Add `capability_missing` | Capability gates |
| E15 | `ByDifficulty.merged_rule/3` (`apps/arbiter/lib/arbiter/agents/routing/by_difficulty.ex:145-152`) | Applies the canary overlay | Clamps to the blast-radius floor after the overlay | Floors |
| E16 | `Dispatch.maybe_route/3` (`apps/arbiter/lib/arbiter/worker/dispatch.ex:1271-1294`), `unroute/1` (`:1305-1312`) | Sets `:agent_type` | Also sets `:model`; turns `:defer` into `DispatchQueue.hold/5`; `unroute/1` strips routing's `:model` | Model choice, defer |
| E17 | `Dispatch`'s legacy path (`no_candidate`) | Dispatches on the pre-routing provider | Applies the capability check, and G13's, on the legacy and explicit paths | Capability gates |
| E18 | `DispatchQueue` (`apps/arbiter/lib/arbiter/workflows/dispatch_queue.ex:203-212`, `:505-511`) | Drains on quota updates and resets | `not_before` on items, and a timer per deferral | Defer |
| E19 | `Board.Snapshot.quota_hold/2` (`apps/arbiter/lib/arbiter/board/snapshot.ex:631-641`) | Task-less | Priority-aware for exempt work | Exemption |
| E20 | `ModelFamily.model_for_tier/3` (`apps/arbiter/lib/arbiter/agents/model_family.ex:105`) | One model id | Add `models_for_tier/3` for list values | Model choice |
| E21 | New `Arbiter.Agents.Routing.Score`, `Arbiter.Agents.Routing.Competence` and `Arbiter.Agents.CapabilityMatrix` | — | The pure scorer; the cell lookup with the ladder; the matrix of competence and capability rows | Scoring, capability gates |
| E22 | `ProviderRouting.valid_selections/0` (`:137`) | `failover`, `most_quota` | Add `scored` | Scoring |

These don't change: `Pace.evaluate/4`'s composition and verdicts;
`gating_window/3`'s rules and their order; staleness; `Snapshot.normalize/2`;
the pin and its fallback (bd-40pzpj); the cross-family rule (bd-a1ke2c); the
`Routing.Policy` callback and `ByBudget`'s dollar seam; `ProviderPool`
failover; and `availability/3`'s capacity sum.

The new configuration, with each key's proposed default. Nothing in it acts
until a workspace opts in: the `routing.scoring.*` keys act only under
`provider_selection: scored`, which no workspace sets by default, and every
other key defaults to off or absent.

```
workspace config
  routing.provider_selection          "failover" | "most_quota" | "scored" (new); unset means failover
  routing.scoring.mode                "shadow" (default) | "enforce"
  routing.scoring.competence          true: expected runs including failure, from the matrix
  routing.scoring.reviewer_coupling   true: price review runs on the projected reviewer's pool
  routing.scoring.time_weight         {"P0": 10, "P1": 2}; every other priority 0
  routing.scoring.model_choice        false (phase 2): honour tier_models lists
  routing.scoring.allow_upgrade       0 (phase 2): consider n tiers above the policy's
  routing.capability_gates            false; valid under most_quota too
  routing.floors.repos.<repo>         absent; e.g. {"min_model_tier": "premium"}
  routing.defer_to_reset              {"enabled": false, "min_priority": 2, "max_wait_minutes": {"5h": 60}}
  quota.pace_exempt_priority          absent; 0–4 or "none", and may only narrow the account's
  quota.pace_exempt_threshold         absent; (0, 1], the 5h exempt cap; may only lower the account's
  quota.weekly_pace_exempt_threshold  absent; (0, 1], the 7d exempt cap; may only lower the account's
account quota_config
  pace_exempt_priority                absent, meaning no exemption; 0–4
  pace_exempt_threshold               absent, meaning the flat ceiling; (0, 1], the 5h exempt cap
  weekly_pace_exempt_threshold        absent, meaning the flat ceiling; (0, 1], the 7d exempt cap
installation settings (operator-owned)
  routing matrix                      competence rows and capability rows
```

## 9. The no-regression invariant

### 9.1 Statement

- **I1: off means identical.** With every new switch at its default, every
  decision surface returns exactly what it returns today, for every input. The
  surfaces are `Pace.evaluate/4`, `Gate.check/4`, `gating_window/3`,
  `Gate.pace/6`, `Headroom.binding/3`, `ProviderRouting.availability/3`,
  `select/4` and `implementer_provider/4`, `ReviewerRouting.select/3`, the
  board's holds, and `Dispatch`'s hold-or-allow. Records change only
  additively.
- **I2: one candidate means identical.** Turn on the router layers: `scored` in
  either mode, competence, reviewer coupling, the time weight. If exactly one
  candidate survives the hard gates — one eligible account, with one model for
  its tier, which is every workspace's config today — the selection, the
  recorded account and model, the outcome and the hold are all what
  `most_quota` returns. Scoring can only *reorder* survivors; it can't drop a
  candidate or hold. Model choice is the one router layer that adds
  candidates, and only where a tier lists more than one model, which no
  workspace does today.
- **I3: the gate policies change holds only when they're on.** The P0
  exemption and defer-until-reset exist to change the hold decision, on every
  path, a single account included. So "one eligible account means identical"
  can't hold for them *while they're on*. It holds while they're off, which is
  I1. Each policy's tests pin exactly what it changes (the ceiling of an exempt
  dispatch's utilization rules; a deferred fresh dispatch at P2–P4) and that
  nothing else moves. This reading of the operator's invariant is O1.
- **The hard gates** (capability, floors) are new drops. They're off by default
  (I1). When they're on, they can only remove candidates or hold; they can
  never add a candidate or loosen a limit.

### 9.2 How it's tested

1. **Equivalence properties.** StreamData generates workspaces, accounts,
   snapshots, tasks and clocks. The generators cover utilization around each
   line, stale and fresh readings, agy bucket sets, every priority and
   difficulty, pins and overrides. The properties:
   - `scored` in `shadow` mode, or with every sub-layer off, returns the same
     selection and the same core record as `most_quota`. That's I2 at its
     strongest, and I1 for the router.
   - With no exempt side, `Pace.evaluate/4`'s output is identical to the
     pre-change function, kept in the test module as a frozen reference copy
     for one release.
   - Without a draw estimate, the score order is the headroom order, since
     `1/h` is monotone.
   - With exactly one survivor, every combination of sub-layers gives the same
     choice and outcome as `most_quota`.
   - Under `scored`, "no feasible candidate" holds exactly when every
     candidate's `gate.check` holds, which is the block condition.
2. **The existing suites as an oracle.** The phase 1 PRs may add cases to the
   Pace, Gate, Headroom, ProviderRouting, ReviewerRouting, board snapshot and
   dispatch quota tests, but they may not edit or delete existing ones.
3. **Shadow mode on the live install.** With `scoring.mode: shadow`, the
   scorer computes and records its choice (`routing_decision.shadow`) while
   `most_quota` dispatches. A report (part of R5) lists the agreement rate and
   every disagreement with its reason, before anyone sets `enforce`.
4. **A replay of recorded decisions.** `worker_runs.routing_decision` already
   stores each evaluation's candidates and headroom. A mix task re-scores them
   offline. With the layers off it must reproduce 100% of the recorded
   choices; with the layers on, it reports the differences.

## 10. Overrides survive every phase

| Override | Today | Under this design |
|---|---|---|
| A dispatch-time provider (`arb dispatch --provider`, or a caller's `agent_type`) | Wins, and is recorded as `override` (`ProviderRouting.override/4`) | Unchanged. The score is recorded alongside, as headroom is today |
| An explicit model (`--model`, or `opts[:model]`) | Applied last at spawn (`dispatch.ex:2729`) | Unchanged. It beats a routed model, and routing doesn't expand candidates for it |
| The implementer pin and the reviewer-family pin | Reused while available | Unchanged. Scoring applies only to a first choice and to a fallback |
| A pause (`arb provider pause`) | Drops the candidate as `paused` | Unchanged, and checked ahead of every new check |
| The quota-gate bypass (`skip_quota_gate`, MCP `force_quota`) | Skips the gate, and is audited | Unchanged. It skips deferral too |
| `routing.rules` | The policy | Unchanged. It is the policy floor |
| `routing.provider_selection` | The switch | `most_quota` (or `failover`) is the kill switch, and takes effect on the next dispatch |
| The Loop's authority | Canaries on `routing.rules` | Canaries on matrix rows too, but never on floors, exemptions or capability rows |
| The coordinator's authority | Config edits | May tighten: narrow an exemption, raise a floor, enable deferral, turn scoring off. May not loosen: grant an exemption, lower a floor, or permit a capability |

## 11. Phased plan and ticket breakdown

Phase 0 runs alongside phase 1. It measures; it doesn't route.

| # | Title | D | Depends on | Phase |
|---|---|---|---|---|
| R1 | `Loop.SubjectStats`: per (provider, model, difficulty_at_dispatch, issue_type) task-level `q`, `R`, `F`, `A`, difficulty raised, time to merge, and runs by pool and side, with the ladder. Shared with guardrails G18: one module, two consumers | 3 | — | 0 |
| R2 | `quota_samples`: an append-only history of every capture (account, bucket, window, used, reset, captured_at), with retention. The quota tables are latest-only caches, so no burn rate or calibration is possible without it | 2 | — | 0 |
| R3 | Draw calibration: the window share per weighted token for each (pool, window, model), by non-negative least squares over `quota_samples` deltas against `usage_events`. Extends `Loop.Scarcity` beyond Claude's 5h window; "absence is never zero" | 3 | R2 | 0 |
| R4 | The capability matrix and `check_capability` in both routers, repo `requires`, the legacy-path check, and the `capability_missing` drop reason | 3 | — | 1 |
| R5 | Scoring: `Quota.Headroom.windows/3`, `Quota.Price`, `Routing.Score`, `provider_selection: scored` with `shadow` and `enforce`, the decision fields, the I1 and I2 properties, and the shadow report | 3 | — | 1 |
| R6 | The hand competence matrix: installation storage, a seeding generator (the Appendix A queries), run-equivalent `δ` by side, and the reviewer projection | 3 | R5 | 1 |
| R7 | The P0 pace exemption: the `Pace` side, gate config and validation, threading `:priority`, the priority-aware board hold, the audit event, and the quota-bar label | 3 | — | 1 |
| R8 | Floors: the policy floor and the per-repo blast-radius floor, the canary clamp, and `Canary.Metrics` excluding clamped dispatches | 2 | — | 1 |
| R9 | Within-provider model choice: `tier_models` lists, `entries/3`, `allow_upgrade`, `:model` through Dispatch and `unroute`. In-flight reservations | 3 | R5 | 2 |
| R10 | Defer-until-reset: the `{:defer, …}` outcome, the what-if reset price, the `DispatchQueue`'s `not_before`, once per reset, and the card label | 3 | R5 | 2 |
| R11 | Window-share `δ`: switch `δ` from run-equivalents to calibrated shares, and the time term to measured `T` | 2 | R3, R6 | 2 |
| R12 | The difficulty feed: the "difficulty raised" rate per cell into the Loop's `:difficulty_override` proposals | 2 | R1 | 2 |
| R13 | Learned competence: matrix proposals from `SubjectStats` as a Loop `PendingWrite` kind, and Stage 3 canaries on matrix rows (arms by task-id hash, first-pass convergence plus pool draw, auto-revert, expiry) | 3 | R1, R6 | 3 |
| R14 | Ticket blast-radius markers, through G12's `issues.permissions` or a dedicated field | 2 | R8 | 3 |
| R15 | An offline replay harness (§7.2), restricted to expiring headroom | 4 | R1, R2 | 4 |
| R16 | Canary-arm exploration within eligibility, budgeted to expiring headroom | 3 | R13, R15 | 4 |

- **R5 as built (bd-adtnto).** `Headroom.windows/3`, `Quota.Price` (`δ / h`,
  `:infeasible` at or past the line), `Agents.Routing.Score` (`J = price +
  w(priority) × time_h`, ties to larger headroom then configured order) and
  `provider_selection: scored`. `routing.scoring.mode` is `shadow` (default:
  `most_quota` dispatches, `routing_decision.shadow` records the scorer's
  ranking, pick, agreement and reason) or `enforce`. `routing.scoring.time_weight`
  is read by the ticket's own priority. `draw` and `time_h` are `nil` until R6's
  matrix supplies them through `ProviderRouting`'s `:estimate_fun` seam, so today
  the price is `1/h` and the order is `most_quota`'s. Reviewer routing is
  untouched (a price-only reorder there changes nothing until R6's projection).
  The report: `mix arbiter.routing_shadow_report`, or
  `bin/arbiter eval 'Arbiter.Release.shadow_report()'` on a release.
- **Phase 1 delivers value with no learned model.** R4, R5, R6, R7 and R8 add
  the capability matrix and floors as hard gates, the headroom price, and the
  hand competence matrix, all on top of the unchanged paced gate.
- **Later phases reuse bd-6edc0u.** R13 and R16 are Stage 3 canaries with a
  wider patch type. They need no new canary machinery.
- **The recommended order for turning things on:** R4 and R8 first, as hard
  gates. Then R5 and R6 in `shadow` mode for at least two weeks. Then
  `enforce`, per workspace, after the shadow report. R7 waits until the
  operator sets an exemption.
- **`enforce` needs a second eligible implementer account to matter.** On
  today's config (§1.3), `scored` changes nothing (I2).

## 12. Reconciliation with guardrail profiles

| Concern (guardrail-profiles §8) | Owner | In this document |
|---|---|---|
| Hard eligibility for security and trust | Guardrails G13 | Consumed (§6.3) |
| Hard eligibility for functional capability | This design | `check_capability`, in the same pipeline, from its own data (§6.2) |
| Ranking among eligible accounts | bd-40pzpj, then this design | The price and score, over survivors only (§2) |
| The blast-radius floor | Both | The trust half is guardrails'; the capability half is §6.4 |
| Exploration and offline replay | This design and the Loop canary | Within eligibility only (§7) |
| "Block when every eligible pool is over its line" | The quota gate and `DispatchQueue` | §2.2 and §6.5 |
| Round-1 approve rate per subject | One `Loop.SubjectStats` | R1 is G18's module |
| The P0 exemption | This design | Quota lines only, never eligibility (§4.2) |

## 13. Alternatives considered

| Alternative | Why not |
|---|---|
| A parallel cost-based router, in dollars | The operator's ruling. Dollars don't exist for agy or Gemini, and imputed Claude dollars aren't money |
| Replacing `most_quota` with a learned bandit | See §7.1 |
| A log barrier, `−ln(1 − δ/h)` | It goes infinite once `δ ≥ h`, so it would hold dispatches the gate allows. That breaks "block only when every pool is over its line" |
| A step price at the `:approaching` band | A discontinuity below the line makes queues flip at the band edge, which is the filing's oscillation question |
| Summing over a pool's windows instead of taking the max | The gate holds on the first window that crosses its line, so the window that binds is the one a draw strains most. A sum would rank a pool with two moderately used windows below a pool whose one window is nearly exhausted (headrooms 0.2 and 0.2 against 0.12 and 1.0, for a draw of 0.1 on each) |
| The exemption as a gate bypass for P0 (`skip_quota_gate`) | That removes the flat ceiling and the provider-refusal rules too |
| Deferral as a priority band, with P3 and P4 holding some points below the line | It holds low-priority work whenever a pool is near its line, for days on a weekly window. Deferral waits only when a reset is near |
| Keying competence on the corrected difficulty | The router doesn't know the corrected difficulty when it dispatches (§3.2) |
| Per-provider competence | It hides the cell structure: agy saves Claude draw at D1 and costs Claude draw at D2 (§3.5) |

## 14. Open questions

These are open. Each needs an operator decision or evidence this design
doesn't have.

1. **O1. Invariant scope for the gate policies.** This design reads the
   operator's "with one eligible account, behaviour is exactly today's" as
   binding on the router layers (I2). The P0 exemption and deferral then
   change holds when turned on, single account included (I3). The alternative
   is to make both policies require two or more eligible accounts, which would
   make them useless on every workspace today.
2. **O2. The exemption's cap. Resolved (operator ruling, 2026-10-05).** The
   cap is a dedicated per-window number, not the flat ceiling: the exempt
   ceiling is `max(max(floor, elapsed), min(exempt_cap, flat))`, with the 5h and
   7d caps set separately on the account and only lowered by the workspace, and
   `exempt_cap` unset meaning `flat`. Today's flats are 0.99, which would have
   made a flat-only cap nominal. Starting values for the Claude account are
   0.95 (5h) and 0.90 (7d). See [§4.2](#42-the-p0-pace-exemption-a-gate-policy).
3. **O3. `w(priority)`'s defaults and units.** They should be set after shadow
   mode shows the score distribution.
4. **O4. An anticipatory price.** When a run will straddle a reset, its draw
   could be split between the current window and the next one, which would
   make near-reset quota cheaper still. Is that worth the complexity?
5. **O5. Reviewer competence.** v1 has no reviewer-quality signal, such as a
   false-approve rate measured against later CI or post-merge failures.
6. **O6. Features beyond difficulty and type.** File fan-out, prod-touching
   work and verifiability could become keys once they're recorded at dispatch.
7. **O7. Oscillation at higher concurrency.** Are reservations, pins and a
   continuous price enough, or does the scorer also need a per-tick admission
   limit per pool?
8. **O8. Local LLM pools.** Price is proposed as `1 / free slots`, but no
   adapter exists to test it against.
9. **O9. Metered budgets as paced windows.** Confirm the synthetic window
   shape, and decide whether paid overage gets one too.
10. **O10. The exploration budget.** Is half the expiring headroom right? And
    may replay evidence alone ever change the live matrix?
11. **O11. Where blast-radius markers live.** In G12's permissions list, or a
    dedicated field?
12. **O12. Claude's per-model weekly limits.** Should they be treated as pools
    whenever the OAuth endpoint reports them?
13. **O13. Operator time.** Is it enough to count it through `T` and the
    coordinator's metered draw, or should it carry its own term?

The filing's own open questions, and where they stand:

| Filing question | Status |
|---|---|
| What is the objective: dollars, wall-clock, or throughput under a ceiling? | Decided (§2): pool scarcity including failure, plus priority-weighted time. The paced line is the throughput ceiling. Dollars are hard limits only where money changes hands |
| How do operator overrides and `by_difficulty` coexist? | Decided: the policy is the floor (§6.4), and the overrides are unchanged (§10) |
| How is oscillation avoided? | Position: a continuous price, pins, reservations, and deferral hysteresis (§2.3, §2.5, §4.3). The higher-concurrency case is O7 |
| Cold start | Position: a pessimistic prior, replay first, then a canary (§7) |
| Key on difficulty or on observable features? | v1 uses difficulty at dispatch plus type (§3.2). Features are O6 |

## Appendix A: how the numbers were produced

The queries read the install database read-only, opening
`~/.arbiter/arbiter.sqlite3` with `mode=ro` on 2026-10-01. The window is
fixed, so a re-run gives the same figures: tasks whose first attempt started
in `[2026-08-24T00:00Z, 2026-10-01T12:00Z)`, and only events before the
cutoff. The one exception is "difficulty raised", which reads the current
`issues.difficulty`. R6's generator automates these queries.

```sql
-- The first base attempt per task (the first row per task_id by started_at)
SELECT task_id, model, difficulty_at_dispatch, started_at
FROM worker_runs
WHERE kind = 'implement' AND COALESCE(role, 'base') = 'base' AND model IS NOT NULL
  AND started_at >= '2026-08-24T00:00:00Z' AND started_at < '2026-10-01T12:00:00Z'
ORDER BY started_at;

-- Review rounds (role = 'review') and fix passes (role = 'impl').
-- The base task is task_id up to the first '#'.
SELECT task_id, role, converged, inserted_at
FROM review_gate_rounds
WHERE inserted_at >= '2026-08-24T00:00:00Z' AND inserted_at < '2026-10-01T12:00:00Z';

-- Runs by pool and side. The pool comes from the model prefix (gemini-*: agy;
-- claude-*: Claude on this install), or, for a run with no model recorded,
-- from the provider on its usage_events rows. The side is review when kind = 'review'.
SELECT id, base_task_id, task_id, model, kind
FROM worker_runs
WHERE started_at >= '2026-08-24T00:00:00Z' AND started_at < '2026-10-01T12:00:00Z';

-- Claude-imputed draw per task; agy rows carry no price
SELECT base_task_id, SUM(cost_usd)
FROM usage_events
WHERE source = 'task'
  AND occurred_at >= '2026-08-24T00:00:00Z' AND occurred_at < '2026-10-01T12:00:00Z'
GROUP BY base_task_id;

-- Time to close: issues.closed_at (close_reason = 'completed', before the cutoff)
-- minus the first attempt's started_at.
-- Difficulty raised: issues.difficulty > the first attempt's difficulty_at_dispatch.
```

The vs-cozecw ledger in §3.5 is the same three tables filtered to
`base_task_id = 'vs-cozecw'`. The pace figures in §1.3 and §5.3 are
`Pace.evaluate/4`'s arithmetic, `max(floor, elapsed)` against each window's
`reset_at`, applied to the stored snapshot rows (`anthropic_quotas`,
`cloud_code_quotas`) and to the figures the filing quoted.
