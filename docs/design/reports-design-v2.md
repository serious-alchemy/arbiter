# Reports design v2 — refreshing the bd-4o5c29 survey against the ticket lifecycle: decision

**Task:** bd-3rqhi5 (decision, GitHub #90) · **Epic:** bd-ibiwci ("Add reports") ·
**Refreshes:** bd-4o5c29 (survey of 2026-09-27) · **Builds on:**
[ticket-lifecycle](ticket-lifecycle.md) (bd-9yqspm, shipped v0.2.1) ·
**Status:** proposed 2026-10-01. Nothing here is implemented; the PR is docs
only. The ticket plan is in [§9](#9-proposed-child-tickets).

All counts below were read **read-only** from the live install DB
(`~/.arbiter/arbiter.sqlite3`, schema through migration `20260930130000`) on
2026-10-01, and the source claims were checked against `main` at `80fad014`.
The history-replay numbers in §3 come from a **throw-away prototype** (a
scratch Python script over a `mode=ro` connection, not committed). It proves
the mapping against this one install; the implementation ticket must re-prove
it in ExUnit against fixtures and with a dry run on a copy of the live DB (§3.5).

## Decision

1. **Add an append-only `ticket_transitions` table, written by the Lifecycle,
   and backfill it once from `issues_versions` with a pure replay module.**
   Do not map legacy statuses at query time. The paper trail *does* record
   every transition today, but only in `issues_versions.changes`, a 25 MB JSON
   blob column that has no index on ticket or action and whose legacy half
   needs a stateful fold (§3.4). One mapping, in one module, run once.
2. **The mapping is "the old backfill rule, replayed"**: `status`, `refined`,
   `pr_ref` and `pending_merge` folded per ticket, with one correction the
   v1 survey missed — before `refined` existed (2026-08-24) `open` meant
   *ready*, not *backlog* (§3.2). Prototype result: all four legacy status
   values map, **0 of 1,443 tickets** end in a state that disagrees with
   `issues.state`, and the CFD invariant (bands sum to tickets created) holds
   on every day tested.
3. **Capture is not a blocker for the first slice, but it should ship first.**
   Throughput, lead time and cost need only columns that exist. The capture
   ticket should still be filed *before* the first report because attention
   history only accrues forward and CFD, stage dwell and burn-up depend on it.
4. **Seven reports** (§5): cumulative flow, cycle/lead time by stage,
   throughput weighted by difficulty, ReviewGate health, attention/wait time,
   cost per ticket, epic burn-up.
5. **First slice** (§7): the `/reports` shell + SVG chart components,
   **Throughput & lead time**, and **Cost per ticket** (by difficulty and
   provider). ReviewGate health is the optional third. None of them waits on
   the capture or the backfill, except a small `base_task_id` backfill that
   Cost wants.
6. **Charts: server-rendered inline SVG function components, no new
   dependency** (§7.2).
7. **No materialised rollup yet** (§6). Every report is one bounded SQL
   aggregate; the thresholds that would change that are listed.

---

## 1. What bd-4o5c29 got right, and what is stale

### Still holds

| bd-4o5c29 claim | Today |
|---|---|
| `issues_versions` is the load-bearing history | Still true, and now it is the *only* history (events are pruned, see §4.1). 15,147 versions over 1,443 tickets; every ticket has at least one. |
| `created_at` / `closed_at` are complete and exact | 0 closed tickets with a null `closed_at`, 0 non-closed tickets with one. `closed_at` is within 16 s (median 1 s) of the last `close` version on all 1,355 closed tickets. |
| `usage_events` grouping belongs in SQL (the `Usage.summarize/1` fix) | Unchanged, and now more important (12,654 rows, three providers). |
| No chart library in the app | Still none (`mix.lock`, `assets/vendor`: daisyui, heroicons, topbar, xterm). |
| `/reports` belongs in the "Analysis" nav group | Still right: `ArbiterWeb.Nav` has Usage `/usage`, Reviews `/reviews`, Audit `/audit` there. |
| Epic burn-up, not burn-down | Still right (epics have no fixed scope). `dependencies.created_at` is still the "added to epic" event. |
| `flake_events` too sparse for a report | Now 20 rows (was 12). Still an annotation, not a report. |
| A shared version-replay helper is needed | Yes, and it is now a *one-off backfill* rather than a runtime helper (§3.4). |

### Stale or wrong

| bd-4o5c29 claim | Why it is stale |
|---|---|
| Status is `issues.status` with values `open / in_progress / awaiting_verification / closed`, plus `refined`, `review_park_reason`, `review_parked_at` | Dropped in migration `20260929193617` (applied on the live DB 2026-09-29T23:24Z). The stored column is `state` (`backlog / queued / active / merging / verifying / closed`) and `Lifecycle.legacy_state/1` is gone. |
| Version action histogram (`promote_to_ready` 504, `park_review` 27 …) | Now 24 distinct action names and 15,147 rows; `start`, `open_pr`, `return_to_work`, `record_review_gate`, `raise_attention`, `set_attention_owner` etc. are new (§3.1). |
| "Only 504 of 1,263 issues have `promote_to_ready`; fall back to `created_at` and footnote the bias" | Misread. `refined` was introduced 2026-08-24 and its migration set every existing row to `true` ("created *was* ready"). Pre-cutover tickets were never in a backlog. The right fallback is the mapping rule in §3.2, not a footnote. |
| "No `merged_at`; infer from the `close` version" | Now a first-class transition: `merging → closed` (or `→ verifying`). |
| "Time in review isn't a state" | Still not a state, but `worker_runs` now has `kind = review` and `review_gate_rounds.role = review` (1,754 review rows). |
| `worker_runs.status` / `worker_type`; `role` null for 2,001 rows | Replaced by the run vocabulary (`kind`, `state`, `outcome`; migration `20260928131352`). `role` has no nulls now; `usage_events.role` is null on 2,112 task rows. |
| `review_gate_rounds` verdict "null 566 (in-flight/legacy)" and "2.99 rounds/task" | Wrong. The 630 null-verdict rows are the **`impl` (fix-round) rows**, not missing reviews; all 1,754 `review` rows have a verdict. The "rounds per task" average mixed the two. |
| False-park rate "approximable from `park_review` → `clear_review_park`" | Replaced by an explicit signal: `gate_resolutions` (the coordinator's recorded decision) and `Resolutions.outcome/2`. |
| Cost per task: group by `task_id` | Must fold synthetic ids (`<id>#review`, `#impl2`, `:fixpass`) to the base ticket; `base_task_id` is null on 2,112 task rows (all written before 2026-08-28), 1,155 of which fold to a ticket only via the suffix rule. |
| Total spend $13,728 | $15,310.68 of priced Claude rows, of which **$12,520.38 is worker spend** and **$2,763.86 is coordinator-session** overhead that no ticket owns. Gemini and Codex rows carry no dollars at all (§5.6). |
| Recommended order: cost, then cycle time, then throughput | Still sensible, but cycle time's "version-scan per ticket" half is now the transition table's job. |

---

## 2. Data inventory (live DB, 2026-10-01)

Counts are rows; "complete" says whether the column a report needs is
populated. Earlier-survey figures in parentheses.

| Table | Rows | Range | Completeness for reporting |
|---|---|---|---|
| `issues` | 1,443 (1,263) | 2026-06-08 → now | `state`: closed 1,355, backlog 63, queued 19, verifying 3, active 2, merging 1. `close_reason`: all 1,355 are `completed` (every legacy close was recorded as such; `wont_do`/`duplicate` only appear from now on). `difficulty` null on 84 rows (5.8%; 5.7% of closed; 10% of June, 7% of September). `rank` populated. No secondary indexes beyond the PK (fine at this size). |
| `issues_versions` | 15,147 (11,464) | 2026-06-08 → now | `changes` is a JSON diff (`changes_only`) with `store_action_name`; 1,645 B average, 24.9 MB total, of which only 4.9 MB is state/status-bearing (the rest is `notes`, `pr_body`). No index on `version_source_id` or action name; one on `version_inserted_at`. No ties on `(source, inserted_at)`. |
| `worker_runs` | 5,791 (5,190) | 2026-06-09 → now | `started_at` never null; `completed_at` null on the 2 live runs. `kind`/`state`/`outcome` complete (implement 2,846, review 2,658, fix_pass 239, conflict 48). **`provider` null on 4,292 rows (74%) — populated only from 2026-09-20**; `provider_account_id` set on 46 rows. `difficulty_at_dispatch` null on 1,450. |
| `usage_events` | 12,654 (11,541) | 2026-06-09 → now | `provider` never null (claude 9,452 / gemini 1,545 / codex 1,627 / arbiter 30). **`cost_usd` is null on every Gemini and Codex row**; Gemini task rows: 287, only 117 with tokens; Codex task rows: 7, none with tokens. `provider_account_id` set on 6,852 (54%): **all but 1 of the 5,945 task rows** (account was backfilled onto history); the nulls are preflight/coordinator-session rows. `source`: task 5,945, preflight 4,722, coordinator_session 1,848, probe 108, maintenance 31. `raw` set on 12,651 (never select it). |
| `review_gate_rounds` | 2,384 (2,080) | 2026-07-29 → now | 1,754 `review` rows (831 tickets) + 630 `impl` rows. Round-1 review verdicts: approve 553, request_changes 607, timed_out 7 (1,167 gate cycles — a ticket can run several). `converged` is true on 921 of 955 approvals (34 approvals admitted an unmet criterion). `reviewer_provider` null on 1,770 (74%); `cost_usd` null on 129 (116 review rows). `reviewer_family` / `same_family_fallback` exist from 2026-09-30 only (33 rows). |
| `gate_resolutions` (new, #78) | 5 | 2026-09-30 | Complete but tiny. `decision` ∈ amend / send_back / …, `actor`, `round`, `fix_round_attempt`. |
| `events` | 6,819 | last 7 days | **Pruned at `retention_days: 7`** (`Events.Retention`). `task_state` is emitted on *every* ticket update (4,260 of 4,931 are `updated`, mostly not state changes). Not a history source. `gate_resolved` 5 / `gate_cap_hit` 3 rows. |
| `messages` | 6,026 | 2026-06-09 → now | 1,790 escalations: 1,724 `legacy`, **66 typed** (`escalation_kind`, `task_ref`, `inserted_at` → `resolved_at`) since 2026-09-28. |
| `dependencies` | 1,015 (835) | 2026-06-15 → now | `parent_of` 396 (355 from epics; 47 distinct parents), `depends_on` 478, `conflicts_with` 62, `blocks` 22, `relates_to` 37, `discovered_from` 20. Each row has `created_at`. `dependencies_versions` (486) only exists from 2026-09-15 and records 4 destroys: edge *removal* is invisible before then. |
| `anthropic_quotas` / `codex_quotas` / `cloud_code_quotas` | 1 each | latest | **One current snapshot per account, no history.** The 5h/7d utilization and pace verdict (`Quota.Pace`) are live computations; there is nothing to chart over time. |
| `provider_accounts` | 3 | | One default account per provider; `deleted_at` exists. |
| `flake_events` | 20 | 2026-09-26 → now | Sparse. Annotation only. |
| `worker_run_steps` | 166,403 | 2026-08-20 → now | Per-step detail. **Never load per row in a report.** |
| `sessions` / `system_alerts` / `workspaces` | 37 / 6 / 3 | | Filter dimensions only. Three workspaces. |

Not present anywhere: a per-transition table, an attention history table, a
quota-utilization history, a `ready_at` / `merged_at` column.

---

## 3. History continuity across the schema change

### 3.1 Three eras in one table

`issues_versions.changes` is `changes_only`, so each row carries only the
attributes the action changed. Counting versions by which of `status` / `state`
they carry:

| era | `version_inserted_at` | versions | carries | notes |
|---|---|---|---|---|
| **A: legacy** | 2026-06-08 → 2026-09-27T19:38Z | 3,832 | `status` only | state is implied by `status` + `refined` + `pr_ref` + `pending_merge`. |
| **B: dual-write** | 2026-09-27T19:41Z → 2026-09-29T23:05Z | 348 | `status` **and** `state` | state migration applied 19:41:30Z; legacy columns still written until the drop. |
| **C: lifecycle** | 2026-09-27T20:30Z → now | 520 | `state` only | the named transitions; legacy columns dropped 2026-09-29T23:24Z. |

(B and C overlap in time because the live server kept running the dual-write
build for a while after the first state-only writes; the carried keys, not the
clock, define the era.) The other 10,447 versions carry neither key — notes,
PR refs, review stamps — and are irrelevant to state.

Legacy status values found in `issues_versions.changes.status`, with their
frequencies: **`open` 1,426, `in_progress` 1,242, `closed` 1,365,
`awaiting_verification` 147.** No other value occurs (`null`/absent on the
10,967 versions that did not touch status). Lifecycle `state` values found in
`changes.state`: backlog 177, queued 157, active 169, merging 144, verifying 28,
closed 193.

A ticket's first `state`-bearing version is rarely its creation: the
`20260927184052` migration wrote `state` onto every existing row (1,287 in the
design doc's rehearsal) with a raw `UPDATE` and **no version row**. Those tickets' history up to their first post-migration
transition exists only in legacy form.

### 3.2 The mapping

Replay each ticket's versions in `version_inserted_at` order, keeping a running
copy of `status`, `refined`, `pr_ref`, `pending_merge`. After each version, emit
a transition when the derived state changes.

| precedence | rule |
|---|---|
| 1 | If the version carries `changes.state`, that is the new state (eras B and C; authoritative). |
| 2 | Else, if the ticket has **not yet shown a `state`** and the version changed `status`, `refined`, `pr_ref` or `pending_merge`, derive it with the rule below. |
| 3 | Else no change. |

Derivation (the migration's backfill rule, which `legacy_state/1` implemented):

| running `status` | other inputs | state |
|---|---|---|
| `open` | `refined` = true | `queued` |
| `open` | `refined` false/absent | `backlog` |
| `in_progress` | `pr_ref` non-blank **or** `pending_merge` non-empty | `merging` |
| `in_progress` | otherwise | `active` |
| `awaiting_verification` | | `verifying` |
| `closed` | | `closed` (`close_reason = completed`) |

**The correction to the obvious mapping — the `refined` cutover.** The
`refined` column came with migration `20260824170000` (live apply time
2026-08-24T17:16:09Z), which set it `true` on every existing row because "created
*was* ready". A ticket created *before* the cutover has no `refined` key in any
version, so a naïve replay starts it at "refined absent" ⇒ `backlog`. That is
wrong: it makes 646 tickets look like they jumped `backlog → active` and shows
a fictional June–August backlog. The replay must **seed `refined = true` for
tickets whose `create` version predates that migration**. With the seed the
count of `backlog → active` falls from 646 to 86 (the real manual
force-dispatches) and `(none) → queued` becomes 587 creations. The cutover
time is **per install** (read `schema_migrations.inserted_at` for version
`20260824170000`; an install created after it has no pre-cutover tickets and the
seed never fires).

Semantic residue a report must disclose rather than hide:

- Before 2026-08-24 `queued` means "open", i.e. created and not yet dispatched,
  including tickets blocked by dependencies. It is the same meaning the board's
  Ready+Blocked columns have now, but there was no backlog to promote from.
- In era A `merging` begins at the first non-blank `pr_ref` (or `pending_merge`),
  not at an `open_pr` call. They are seconds apart; lead and stage numbers are
  comparable across the seam to that precision.
- `close_reason` is `completed` for every era-A close (nothing could say
  otherwise). Throughput filters on `close_reason = 'completed'`.
- Legacy `reopen` kept `refined`; the new one lands in `queued`. Of the
  59 reopens in the data the replay gives `closed → queued` 47, `verifying →
  queued` 10 and `closed → backlog` 2 (a legacy reopen of a ticket whose
  `refined` was still false).

### 3.3 Evidence that it covers the data (prototype, live DB)

| check | result |
|---|---|
| every legacy `status` value in `issues_versions` maps | 4 of 4 (`open`, `in_progress`, `awaiting_verification`, `closed`); 0 versions fall through |
| replayed final state vs stored `issues.state` | **0 mismatches over 1,443 tickets** |
| each `state`-carrying transition is legal under `Lifecycle.rule/1` | 0 violations across eras B and C |
| CFD invariant: Σ band counts = tickets created by day *d* | equal on all 6 days tested (07-01: 164, 08-01: 420, 08-24: 601, 09-15: 950, 09-27: 1,292, 09-30: 1,442) |
| repeats survive replay | 39 tickets enter `active` more than once; 29 close more than once (reopens) |

Resulting transition counts (6,175 rows): `queued→active` 1,199, `active→merging`
1,121, `merging→closed` 943, `backlog→queued` 649 (= the 649 `promote_to_ready`
versions), `active→closed` 173, `merging→verifying` 155, `verifying→closed` 142,
`closed→queued` 47, `merging→active` 24, `queued→backlog` 20, `verifying→queued` 10,
`active→queued` 9, `active→backlog` 4, `queued→merging` 2, `closed→backlog` 2,
`queued→closed` 62, `backlog→closed` 84, `backlog→active` 86, plus 856
`(none)→backlog` and 587 `(none)→queued` creations.

Sanity of the downstream numbers (closed non-epic tickets, hours, prototype):

| window | n | created→closed P50 / P90 | `active` dwell P50 / P90 | `merging` dwell P50 / P90 |
|---|---|---|---|---|
| before 08-24 (no backlog) | 565 | 1.0 / 19.6 | 0.25 / 0.95 | 0.13 / 2.04 |
| 08-24 → 09-27 19:41 | 603 | 6.9 / 80.0 | 0.45 / 1.28 | 0.41 / 3.96 |
| since 09-27 19:41 | 158 | 15.2 / 182.0 | 0.86 / 1.93 | 0.13 / 0.98 |

The lead-time growth is real (work now waits behind a backlog and a scheduler),
not a seam artefact; authoring and merge dwell are stable across eras. Reports
should default their window past 2026-08-24 and annotate the cutover on any
time-series.

### 3.4 Where the mapping lives, and why a backfill beats query-time mapping

**Recommendation: a pure module `Arbiter.Tasks.Lifecycle.History` (beside
`Lifecycle`) with `replay(versions, opts) :: [transition]`, called by a
one-off, idempotent backfill; reports read only `ticket_transitions`.**

| | Query-time mapping | One-off backfill (recommended) |
|---|---|---|
| Expressible in SQL? | The fold carries four running attributes across rows. Window functions can do "last non-null" only with per-column tricks, and each report would repeat the era split. | Elixir fold, ~50 lines, unit-testable against fixtures. |
| Cost per request | Scans `issues_versions.changes` (25 MB). Measured 40–76 ms for just the state key *today*; grows with note size, not ticket count. | None; indexed ~6 K-row table. |
| One definition | Copy-pasted into every report (CFD, burn-up, stage dwell). A drift is a wrong chart. | One module, one test, then frozen. |
| Era B/C | Needs the same `LAG` plumbing anyway to get *from* state (versions store only `to`). | Writer stores `from_state`. |
| Cost of being wrong | Silent, per query. | Dry-run diff against `issues.state` before apply; re-runnable. |
| Other installs | Works unchanged. | Must run on every install (below). |

**How it runs on every install.** `Release.backfill/2` is manual and dry-run by
default (`bin/arbiter eval 'Arbiter.Release.backfill(:ticket_transitions, apply?: true)'`),
which is right for the operator but not for an installed product that a
reports page must work on. Follow `Boot.ProviderAccounts`: a one-shot,
synchronous, primary-instance-only boot worker placed **after** the schema
migrator and **before** the board/scheduler start. The same entry point is
`Release.backfill(:ticket_transitions)`. It processes only tickets with **no
`ticket_transitions` rows**, in a single transaction per ticket, and never
overwrites. Because it runs before the Lifecycle can write live rows, live and
backfilled rows can never overlap, so no fuzzy de-duplication is needed. It
must also be a *check*: it compares the replayed final state to
`issues.state` and logs (does not abort the boot on) any mismatch, then inserts
a synthetic reconciling transition (`source: "backfill_reconcile"`) so the table's
last row for a ticket always equals its stored state.

**Why not a plain SQL migration?** The hand-written lifecycle migrations used
SQL because the rule fit one `CASE`. This rule is a fold over history; keeping it
in Elixir (tested, with the `Lifecycle` table next to it) beats a second copy in
SQL. A migration that calls application modules is the pattern this repo
avoids.

> **As built (bd-d8fi92):** `Arbiter.Tasks.Lifecycle.History.replay/2` (pure)
> and `Arbiter.Tasks.TicketTransitionBackfill`, applied on every primary boot
> by `Arbiter.Boot.TicketTransitions` (after `Boot.ProviderAccounts`, before
> the queues) and by hand via `Release.backfill(:ticket_transitions)` (dry run
> by default) or `mix arbiter.backfill_ticket_transitions`. Three refinements:
>
> - **Tickets the triggers already cover.** The bd-5gkqdr triggers can ship
>   (and write live rows) before this backfill runs, so "no rows" is not the
>   test. A ticket is done once its history has a start — a `create` row or a
>   backfilled row. A ticket with only live rows gets the replay of the
>   versions *before* its first live row, which must end in that row's
>   `from_state`; the trigger's `at` precedes the paper trail's version for the
>   same write, so the cut is exact.
> - **A second per-install cutover.** Versions at or after the `state`
>   migration (`20260927184052`) that carry no `state` derive nothing: from
>   then on `state` is the stored truth, so a `record_pr` on an `active` ticket
>   is not an `open_pr`.
> - **The reconcile row** is named `reconcile`, stamped at the replay's last
>   transition (or `created_at` for a ticket with no paper trail, so it still
>   enters the history at its creation). The creation row is stamped
>   `min(create version, created_at)`, as the live trigger stamps `created_at`.
>
> Against a backup-API snapshot of the live DB on 2026-10-01 (1,460 tickets,
> 7,057 state-relevant versions): 0 mismatches, 0 unmapped values, 0 illegal
> era-B/C transitions; 6,230 rows; the CFD invariant held on 07-01 (164),
> 08-01 (420), 08-24 (601), 09-15 (950), 09-27 (1,292), 09-30 (1,442) and
> 10-01 (1,460); a second run planned and inserted 0.

### 3.5 What the implementation ticket must prove

1. ExUnit fixtures for each era and for the cutover seed: one ticket per
   (legacy status value × refined seed × pr_ref/pending_merge) combination,
   the reopen variants, and a ticket whose first state-bearing version is a
   `close`.
2. A dry-run on a snapshot of the live DB (the `sqlite3` backup API; see the
   repo notes on verifying migrations against a live copy) that reproduces the
   §3.3 table: 0 mismatches, 0 unmapped values, 0 illegal era-B/C transitions.
3. Idempotency: a second run inserts 0 rows.

---

## 4. Transition timestamps: what exists, what must be added

### 4.1 Finding

**Per-transition timestamps exist today, but only in the paper trail, and only
usably from 2026-09-27.** Each Lifecycle transition is an Ash action, the
`Issue` resource has `paper_trail` with `store_action_name?(true)`, and
`Changes.Transition` force-writes `state`, so each transition produces one
`issues_versions` row with `version_action_name` (e.g. `start`, `open_pr`,
`return_to_work`, `close`), `changes.state` (the new state), and
`version_inserted_at` (UTC, microseconds, written in the same transaction as the
state). Repeats are separate rows. Observed action counts since the lifecycle
shipped: `start` 134, `open_pr` 144, `return_to_work` 24, `await_verification`
157 (all eras), `close` 1,421, `reopen` 59, `promote_to_ready` 649,
`return_to_backlog` 23. The transitions `promote`, `demote`, `requeue` and
`pr_closed` exist as actions but have **0 versions** — nothing has called them
yet (the UI and CLI still enter via the legacy doors `promote_to_ready` /
`return_to_backlog`, which wrap the same transition).

Gaps that make the paper trail unsuitable as the reporting source:

| gap | consequence |
|---|---|
| `from` state is not stored (`changes_only`) | A report must `LAG` over each ticket's state-bearing versions. |
| Era A is not state at all (§3) | Needs the fold; not SQL-friendly. |
| Every ticket's state at the 09-27 migration has **no version** | Their first post-migration version has no predecessor. |
| `issues_versions.changes` is 25 MB of mostly unrelated JSON, unindexed on source/action | Every query is a table scan (measured 40–76 ms now; scales with note growth). |
| `events` (`task_state`) is not a substitute | Pruned at 7 days, fires on every update, and its `attention` field mixes stored and derived causes. |
| `ReviewGate` / dispatch state changes with no transition (`record_review_gate`, `set_pending_merge`, `record_pr`) | Fine: not state. They remain readable from versions. |

### 4.2 Minimal capture spec

**Table `ticket_transitions`** (append-only, never updated):

| column | type | notes |
|---|---|---|
| `id` | uuid v7 | PK |
| `ticket_id` | text | FK-ish to `issues.id` (no cascade; keep history after a hard delete) |
| `workspace_id`, `repo` | | denormalised so a filter needs no join; repo may be null |
| `from_state` | text null | null for the creation row |
| `to_state` | text | one of `Lifecycle.states/0` |
| `transition` | text | `create`, `promote`, `start`, … (`Lifecycle.transitions/0`); backfilled era-A rows use `legacy:<action>` |
| `close_reason` | text null | set when `to_state = closed` |
| `at` | utc_datetime_usec | the clock reading in the same transaction as the state write |
| `source` | text | `live` \| `backfill` \| `backfill_reconcile` |
| `origin` | text null | the paper trail's `change_origin` input, when given (loop proposals etc.) |

Indexes: `(ticket_id, at)`, `(to_state, at)`, `(workspace_id, at)`. Unique
`(ticket_id, at, to_state)`.

**Writer.** One place: an `after_action` inside `Changes.Transition.write/2`
(the single door for named transitions) inserts the row in the caller's
transaction, using `changeset.data.state` for `from_state`. Plus `:create`
(`nil → backlog`) and the rows written around Ash: the Dolt importer
(`DoltImport.Mapper`) and any future raw writer. A grep-able invariant
(test): for every ticket, the last `ticket_transitions` row's `to_state` equals
`issues.state`, asserted at the end of the lifecycle test matrix.
Idempotent no-op transitions (`promote_to_ready` on an already-queued ticket)
write nothing, because `state` did not change.

> **As built (bd-5gkqdr):** the writer is two SQLite triggers on `issues`
> (`AFTER INSERT`, `AFTER UPDATE OF state WHEN OLD.state IS NOT NEW.state`),
> not an `after_action`. AshSqlite opens no transaction around an action
> (`can?(_, :transact)` is false), so an `after_action` insert would be a
> separate write: a failing insert could not roll the transition back, and
> wrapping the action in `Repo.transaction` would hold SQLite's write lock
> across `StopWorker`, the tracker HTTP sync and the pre-commit broadcasts. A
> trigger runs inside the state write's own statement. It names the transition
> by its `(from, to)` pair — unique in the lifecycle table, so the legacy doors
> record the transition they apply (`promote_to_ready` → `promote`, `pr_closed`
> → `return_to_work`); an off-table pair from a raw write is `unnamed`. `at` is
> `created_at` / `updated_at` (else the DB clock), clamped to be no earlier than
> the ticket's previous row; ties order by `rowid`. The Dolt importer and any
> raw writer are covered with no code of their own. `origin` stays null on live
> rows — no transition action takes `change_origin` today.

**Backfill.** Feasible and cheap: §3 — the whole replay is ~0.1 s for 15 K
versions. It produces rows with `source: "backfill"`, `at = version_inserted_at`,
and an unknown `origin`. Era-A transitions that the paper trail stamped with
no distinct action name carry `legacy:update`.

**Before any report?** No for the first slice (§7), yes for everything built
on stage dwell, CFD and burn-up. But it is the **first ticket to file**,
because the next gap cannot be backfilled.

### 4.3 Attention history is thinner and needs its own capture

Attention (`attention_cause`, `attention_detail`, `attention_since`, owner
fields) is a stored overlay, written by `Attention.raise_cause/3`
(`:raise_attention`), `ReviewPark`, `await_verification`, and cleared by every
transition (`Changes.ClearAttention`). What survives:

| source | what it gives | span |
|---|---|---|
| `issues_versions` where `changes` has `attention_cause` | raise (`raise_attention`, `park_review`, `await_verification`) and clear (`clear_attention`, `clear_review_park`, any transition, `close`) of **stored** causes; owner moves (`set_attention_owner`, 18) | 2026-09-28T22:18Z → now; ~70 rows |
| `review_park_reason` / `review_parked_at` in versions (91 rows; 34 `park_review`) | the pre-attention ReviewGate park, 12 reason strings | 2026-09-15 → 2026-09-29 |
| `messages` typed escalations (`inserted_at` → `resolved_at`) | 66 rows, 20 kinds | 2026-09-28 → now |
| `state = verifying` dwell | "waiting on a restart-and-observe" for the whole of its life (the cause is implied by the state) | all eras (via transitions) |

**Not recorded anywhere:** a *derived* attention (`merge_blocked` from a dead
Watchdog or PR status, `run_crashed`, `run_asked_question` — the cause `View`
computes when none is stored). `AttentionSweep` already tracks a first-seen
clock for them in memory and forgets it on restart. So "how long did a ticket
sit blocked on the coordinator" is knowable for stored causes only.

**Spec: `ticket_attention_spans`** (`ticket_id`, `workspace_id`, `cause`,
`owner` at open, `owner_changed_at` / `owner_at_close`, `opened_at`,
`cleared_at`, `cleared_by` ∈ {`transition`, `clear`, `resume`, `sweep_gone`},
`derived` boolean). Written by `Attention.raise_cause/3` and
`ClearAttention`, by `Attention.promote/hand_off`, and by `AttentionSweep` when
it first sees a derived item (open) and when the item disappears (close).
Smaller than `ticket_transitions` and independent of it. Backfill: from the
versions + escalation rows above for 2026-09-15 → now (a few hundred rows at
most); anything earlier does not exist.

---

## 5. The report set

Conventions for all: default scope is the install's workspaces, **epics
excluded** (`issue_type != 'epic'`) unless the report is about epics; closed
means `state = 'closed'`; time is UTC; every chart states its window and its
exclusion rules on-screen. "Filters" lists the common set plus what is specific.
Filter columns: **WS** workspace, **repo**, **epic** (child of via `parent_of`),
**type**, **diff** difficulty, **prov** provider/model/account, **range** date.

### 5.1 Cumulative flow (CFD)

| | |
|---|---|
| Question | Where is work piling up — backlog growing, queue not draining, verification backing up? |
| Source & query shape | `ticket_transitions` turned into intervals `[at, next_at)` per ticket (one `LEAD(at)` window in a CTE), joined to a recursive day series: `SELECT day, to_state, COUNT(*) … WHERE at <= day_end AND (next_at IS NULL OR next_at > day_end) GROUP BY day, to_state`. Output rows ≤ days × 6. |
| Chart | Stacked area, one band per state, `closed` at the base. Vertical annotation at 2026-08-24 (refined cutover; before it, `queued` means "open"). |
| Filters | WS, repo, epic, type, diff, range. Epic filter joins `dependencies` once, outside the series. |
| Blockers | `ticket_transitions` + backfill. Weighted-by-difficulty variant needs only a join to `issues.difficulty`. |

### 5.2 Cycle and lead time by stage

| | |
|---|---|
| Question | How long does a ticket take end to end, and where does the time go: waiting in the queue, being authored, merging, awaiting verification? |
| Source & query shape | **Lead** = `closed_at − created_at` from `issues` (no transitions). **Stage dwell** per ticket per state = Σ of that state's intervals (repeats summed: a requeue or `return_to_work` adds, it does not overwrite). Definitions: *queue wait* = Σ `queued`; *authoring* = Σ `active`; *merge* = Σ `merging`; *verify* = Σ `verifying`; **`queued→closed`** = first entry to `queued` → `closed_at`; **time to first PR** = first `start` → first `open_pr`. P50/P90 in SQL with `ROW_NUMBER()`/`COUNT()` over the per-ticket totals (SQLite has no `percentile_cont`). |
| Chart | Histogram with P50/P90 markers (lead); stacked horizontal bar of median stage dwell per difficulty; optional box per type. |
| Filters | WS, repo, epic, type, diff, range (by `closed_at`), plus **provider/model** via `worker_runs.model` of the primary implement run (run-level, only populated for provider from 2026-09-20; model is populated earlier). |
| Blockers | Lead time: none. Stage dwell: transitions + backfill. Disclose the era-A `merging` boundary (§3.2) and the 8-24 queue seam. |

### 5.3 Throughput, weighted by difficulty

| | |
|---|---|
| Question | How many tickets (and how much "size") close per week, and is it trending? |
| Source & query shape | `issues` only: `WHERE state='closed' AND close_reason='completed' AND issue_type != 'epic'`, `GROUP BY week(closed_at), difficulty` with the week bucketed Monday-UTC (`date(closed_at, 'weekday 0', '-6 days')`). Weighted size = `Σ weight(difficulty)` with a single named constant table: D0 0.5, D1…D4 = 1…4, **unrated = 2** (the `unrated_as_d2` rule `Estimate` already uses, so the page and `ticket_show.estimate` agree). Reopened tickets count in the week they last closed. |
| Chart | Bars per week stacked by difficulty (count); a second line for weighted size and a 4-week moving average. Unrated drawn as its own hatched band, not hidden. |
| Filters | WS, repo, epic, type, diff, range. **Provider** via the ticket's `usage_events` rows (`implementer_family` on `issues` exists but is set on only 26 tickets, from 2026-09-30) — optional. |
| Blockers | None. Difficulty null 5.8% (document the weighting). |

### 5.4 ReviewGate health

| | |
|---|---|
| Question | Does the gate converge fast, how often does the first review pass, and how often does the coordinator have to overrule it? |
| Source & query shape | `review_gate_rounds WHERE role='review'`, grouped by gate cycle (`task_id`, `fix_round_attempt`): rounds per cycle (`MAX(round)`: today 1→426, 2→321, 3→83, 4→1 tickets); **first-pass approve rate** = round-1 `approve` / round-1 rows (553 / 1,167 = 47%); `converged` vs approve-with-unmet-criteria (34 of 955); `timed_out` rate (14); review cost (`cost_usd`, null on 116 review rows) by `reviewer_provider`/`reviewer_model`/`reviewer_family`; same-family fallback rate (30 of 33 rows since 09-30). **Outcome** (converged / resolved / not_converged) = a SQL port of `Resolutions.outcome/2`: last review round `approve` ⇒ converged, `gate_resolutions` newer than the last row ⇒ resolved (group by `decision`: amend, send_back, …, and `actor`), else not_converged. `gate_cap_hit` is derivable as a cycle with `max(round) ≥ cap`; do not read the pruned `events` row. |
| Chart | Histogram of rounds per cycle; line of weekly first-pass approve rate; stacked bar of outcomes per week; small table of resolution decisions (5 rows today — a table, not a chart, until volume grows). |
| Filters | WS, repo, type, diff, range, reviewer provider/model/family. |
| Blockers | The SQL outcome must be parity-tested against `Resolutions.outcome/2` (fixtures covering all four values). `reviewer_provider` is null on 74% before 2026-09-20: provider charts start there. The old false-park rate is dropped (replaced by resolutions). |

### 5.5 Attention / wait time (new)

| | |
|---|---|
| Question | How long do tickets sit waiting on the coordinator, and on the operator, and for what cause? How often does the coordinator's limit expire and push an item to the operator? |
| Source & query shape | `ticket_attention_spans` (§4.3): `SELECT cause, owner, week, COUNT(*), SUM(cleared_at − opened_at), P50, P90`. Open spans use `now()` as the end and are flagged "still waiting". `verifying` dwell comes from `ticket_transitions` and is shown as its own cause (`awaiting_verification`, owner coordinator), because it is the dominant wait and its attention is stored only since 2026-09-29. Owner at open comes from the Attention owner table; hand-offs and sweep promotions (`set_attention_owner`, `AttentionSweep`) split a span at `owner_changed_at` so "time with the operator" is separable. Causes today: ReviewGate park reasons, `pr_closed`, `merge_blocked` (coordinator, or operator for approval), `awaiting_manual_merge` (operator), `run_crashed`, `run_asked_question`, `awaiting_verification`, `tracker_sync_failed`. |
| Chart | Stacked bar of wait-hours per week by cause, coloured by owner; P50/P90 per cause table; a "currently waiting" strip of open spans. |
| Filters | WS, repo, cause, owner, range, type, diff. |
| Blockers | **Capture-gated.** The spans table and its writer do not exist; derived causes are unrecorded (§4.3). The stored-cause backfill covers ~3 weeks of thin data (≈70 version rows + 66 escalations). Do not build the report until the capture has run ~2–4 weeks; ship it as the last of the set. |

### 5.6 Cost per ticket (by difficulty and by provider)

| | |
|---|---|
| Question | What does a ticket cost, how does cost scale with declared difficulty, and what does each provider/model/account contribute? |
| Source & query shape | `usage_events WHERE source='task'`, folded to the ticket: `COALESCE(base_task_id, <fold(task_id)>)`, joined to `issues` (difficulty, type, `closed_at`). **Fold in SQL**, never in Elixir over rows: `substr(task_id, 1, instr(task_id || '#', '#') - 1)` then strip `:fixpass`/`:conflict`, i.e. the `Estimate.fold_task_id/1` rule; best done once by the `base_task_id` backfill (§9, ticket 3) so the report only reads `base_task_id`. Aggregates: `SUM(cost_usd)`, `SUM(tokens_in+tokens_out)`, `COUNT(*)` per (ticket, provider, model, account, role), then P25/median/P75/P90 per difficulty. `ticket_show.estimate` already reports P25–P75/median/P90 over a 60-day window; **reuse its window and statistics** so the page and the ticket card agree. |
| Per-provider honesty | **Dollars exist only for Claude.** Gemini task rows (287) and Codex task rows (7) have `cost_usd` null, and only 117 and 0 of them respectively have tokens. Show Claude in dollars, Gemini in tokens where present, and render the rest as an explicit "unmetered" count — do **not** coerce null to $0 and do not sum across providers. `ext:*` task ids (external review, no ticket) and `coordinator_session` / `preflight` / `probe` / `maintenance` rows are not ticket spend: report coordinator overhead ($2,763.86, 18% of priced Claude spend) as a separate tile. |
| Chart | Bar of median cost per difficulty with a P25–P75 whisker, stacked by provider (tokens axis for non-Claude); scatter of cost vs review rounds per ticket (rounds from `review_gate_rounds`); a spend-by-account table. |
| Filters | WS, repo, type, diff, **provider / model / account**, role (implement / review / fix_pass / conflict), range (by ticket `closed_at` for the cohort view, by `occurred_at` for the series). |
| Blockers | `base_task_id` backfill for the 2,112 rows written before 2026-08-28. `role` is also null on those rows; derivable from the id suffix (`#review` → review). `provider_account_id` is set on all but one task row (it was backfilled), so grouping by account works over the full history; the unattributed rows are preflight/coordinator overhead. |

### 5.7 Epic burn-up

| | |
|---|---|
| Question | For an epic: how much has been added, how much is done, is the done line converging on scope? |
| Source & query shape | Children = `dependencies WHERE type='parent_of' AND from_issue_id = :epic`. **Scope** line = cumulative `COUNT(*)` of those edges by `dependencies.created_at` (weighted variant: Σ weight). **Done** line = per child, intervals where `state = 'closed'` from `ticket_transitions`; at each day count children whose latest transition ≤ day is `closed` (so a reopen steps the line down). Both series are ≤ days rows. Direct children only in v1 (41 of 396 `parent_of` edges come from non-epic parents; recursion is a later option; `Issue`'s `epic_rollup` is the live equivalent). |
| Chart | Two step lines (scope, done) with the open-remainder shaded; today's marker. A burn-up, not a burn-down: scope moves. |
| Filters | **Epic (required)**, date range (defaults to the epic's `created_at` → now), diff weighting on/off. |
| Blockers | `ticket_transitions` + backfill. Edge *removals* are invisible before 2026-09-15 (4 destroys since); acceptable. |

### Considered and set aside

- **Quota / spend-vs-pace over time (7d/5h windows per account).** The quota
  tables are one latest snapshot per account; `Quota.Pace` is computed live.
  There is no utilization history to chart. If the operator wants it, add an
  append-only `quota_snapshots` (account, window, utilization, captured_at)
  written by the existing poll — candidate ticket 12; spend per account is
  already covered by report 5.6.
- **Flake report** — 20 rows; keep as an annotation on throughput.
- **Per-run reports** (`worker_runs`, `worker_run_steps`) — belong on the
  existing Run history / Usage pages, not Reports.

---

## 6. Performance

Principle: **a report is one bounded SQL aggregate returning chart points, never
rows.** No report loads `issues_versions.changes`, `usage_events.raw`,
`worker_run_steps`, or whole `Issue` structs. Use `Ecto.Query` over the
`LedgerRow`-style slim schemas the `Usage` module already uses (the
`Usage.summarize/1` and `Board.Snapshot` slimming is the precedent), with the
board's perf lessons applied (bd-81vbzg debounced lifecycle refreshes; #96
slimmed `Board.Snapshot.load`): results are held in LiveView assigns, filter
changes re-query via `start_async`, and nothing runs on every PubSub tick.

Measured on the live DB (prototype, read-only):

| query | rows out | time |
|---|---|---|
| state key from `issues_versions` (JSON scan) | 868 | 72 ms (40 ms with a `LIKE` prefilter) — not on the request path |
| `usage_events` by folded ticket, `source='task'` | 2,192 | 28 ms |
| `usage_events` by day × provider | 160 | 34 ms |
| `review_gate_rounds` per task | 831 | 2 ms |
| full replay of all 15,147 versions (Python) | 6,175 transitions | 0.1 s (one-off) |

Needs and non-needs:

- **Required:** `ticket_transitions` and `ticket_attention_spans` with the
  indexes in §4.2 — the data is ~6 K rows and a few hundred rows, so CFD/dwell/burn-up
  aggregates stay in single-digit milliseconds.
- **Required:** the `base_task_id` backfill, so cost never folds ids per request.
- **Optional, small:** an index `issues (state, closed_at)` and
  `issues (workspace_id, state)` — `issues` has only its PK now; irrelevant at
  1.4 K rows, worth adding if the table passes ~50 K.
- **No materialised rollup in v1.** Thresholds to revisit: `usage_events`
  beyond ~1 M rows (the by-day aggregate then needs a daily table keyed
  `(day, provider, account, workspace, role)`), or `ticket_transitions` beyond
  ~100 K rows or a CFD window over a year (then a nightly
  `ticket_state_daily (day, workspace, repo, state, count)` snapshot). Both are
  append-only and recomputable, so they can be added later without redesign.
- **Cache:** a short-TTL per-(report, filters) cache on the model of
  `Usage.EstimateCache` / `Quota.SpendCache` for the default window; no PubSub
  invalidation (reports tolerate staleness; the page shows its "as of").
- Beware the SQLite expression-tree limit: do not pass an unbounded `id IN (…)`
  list (the existing code chunks at 200). An epic filter or a difficulty filter
  must be a join or subquery, not a literal list.

---

## 7. First slice

### 7.1 What ships first

| order | item | why it goes first |
|---|---|---|
| 1 | **`/reports` shell + chart components + filter bar** | everything reuses it |
| 2 | **Throughput & lead time** (5.3 + lead half of 5.2) | one SQL aggregate over `issues`; the question operators ask most; no capture needed |
| 3 | **Cost per ticket** (5.6) | highest signal per effort; reuses the `Usage` grouping pattern; needs only the small `base_task_id` backfill |
| optional | **ReviewGate health** (5.4) | complete data; the one fiddly part is the SQL port of `outcome/2` |

In parallel, not blocking: **`ticket_transitions` capture + `History` replay +
boot backfill** (tickets 1–2) and **attention-spans capture** (ticket 10). They
unlock the second slice (CFD, stage dwell, epic burn-up) and, after ~2–4 weeks,
the attention report.

### 7.2 Where and with what

- **Location:** a `ReportsLive` at `/reports` (router near
  `live("/usage", UsageLive)`), nav entry **Reports** in the **Analysis** group
  of `ArbiterWeb.Nav` beside Usage / Reviews / Audit, icon `hero-chart-bar-square`.
  Sub-views are tabs (`?tab=throughput|cost|…`) with filters in the query string
  so a view is linkable, following `UsageLive`'s `range` and `tab` events.
  Pages begin with `<Layouts.app flash={@flash} …>` and use `to_form/2` for the
  filter form, per the repo's Phoenix guidelines.
- **Chart tooling that already exists:** none. `UsageLive` is tables and stat
  tiles; the quota meters are hand-rolled bars; the only SVG is the brandmark.
  `assets/vendor` is daisyui, heroicons, topbar and xterm, and the repo rules
  forbid external `<script src>` and inline `<script>`.
- **Recommendation: server-rendered inline SVG function components**
  (`ArbiterWeb.Charts`: `bar`, `stacked_bar`, `area`, `step_line`, `histogram`,
  `stat_tile`, shared axes/legend), **no new dependency, no JS** for slice 1.
  Reasons: charts have ≤ ~200 points; LiveViewTest can assert real elements
  (`has_element?(view, "#throughput-chart rect[data-week='…']")`) which a canvas
  library would not allow; no supply-chain addition in a repo with an active worker-security workstream; theme colours come from the existing CSS
  variables so light/dark follow the theme. Tooltips are SVG `<title>` plus a
  CSS hover state. If a later report wants zoom/brush, vendor a small library
  (uPlot) behind a colocated `phx-hook` then; the data contract (a list of
  points per series) does not change. Colour and chart-form choices should
  follow the project's dataviz guidance (validated categorical palette,
  colour-blind-safe, direct labels).
- **Prerequisites for slice 1:** the `base_task_id` backfill only (cost). No
  schema change, no `ticket_transitions`.
- **Testing:** LiveView tests with seeded tickets and ledger rows asserting
  element ids/`data-*` values, and a golden test per report that compares the
  SQL result with a straightforward Elixir computation over the same fixtures.
  A browser check is possible only with the asset binaries in `_build`; do not
  boot a server from a worktree.

---

## 8. Risks and open questions

1. **Mapping portability.** The refined-cutover seed is per install; an install
   whose migrations ran on a different day gets a different cutover, and an
   install that skipped to ≥ v0.2.1 has no era A. The replay reads
   `schema_migrations`, but a manually rewritten `schema_migrations` would
   mis-seed. Mitigation: the reconcile step (§3.4) makes the final state always
   right even when the middle is wrong, and logs the count.
2. **Weighting policy** (D0 = 0.5, unrated = 2) is a judgement the operator
   should confirm; it lives in one constant.
3. **Provider cost parity.** Until Gemini and Codex report prices, cost reports
   are Claude-in-dollars and others-in-tokens/unmetered. That is a data
   limitation, not a design choice; the report must say so on the page.
4. **Attention report is capture-gated** and may be thin for weeks.
5. **`Lifecycle` writer coupling.** The `ticket_transitions` writer sits in
   `Changes.Transition`, a hot path. Its failure must fail the transition
   (same transaction) — a silent drop would corrupt every downstream report —
   so it needs the invariant test in §4.2.
6. **No transitions yet for `promote`/`demote`/`requeue`/`pr_closed`.** The
   table will contain them as callers migrate off `promote_to_ready` /
   `return_to_backlog`; reports key on `to_state`, not on action name, so
   this is invisible to them.

---

## 9. Proposed child tickets

Not filed — the coordinator files them under bd-ibiwci. P = priority
(1 highest), D = difficulty.

| # | Title | P / D | Scope | Acceptance sketch | Depends on |
|---|---|---|---|---|---|
| 1 | Reports: `ticket_transitions` table and Lifecycle writer | P1 / D3 | Migration + Ash resource per §4.2; insert in `Changes.Transition`'s `after_action`, in `:create`, and in `DoltImport.Mapper`; indexes; `verify_after_deploy` because the first real transitions run in the live server. | Every named transition writes one row with correct `from`/`to`/`at`; creation writes `nil → backlog`; an idempotent no-op writes nothing; a failing insert rolls the transition back; invariant test: last row's `to_state == issues.state` across the lifecycle test matrix. | — |
| 2 | Reports: `Lifecycle.History` replay + boot-time `Release.backfill(:ticket_transitions)` | P1 / D3 | Pure replay module (§3.2, incl. per-install refined-cutover seed); `Release.backfill/2` entry (dry-run default); one-shot primary-only boot worker after the migrator, before the queues; reconcile row on mismatch. | Fixture matrix per era; dry-run on a live-DB snapshot gives 0 mismatches, 0 unmapped values, 0 illegal transitions, CFD invariant on sample days; second run inserts 0 rows. | 1 |
| 3 | Reports: backfill `usage_events.base_task_id` and `role` | P2 / D1 | `Release.backfill(:usage_base_task)` applying `Estimate.fold_task_id/1` and the suffix → role rule to the 2,112 rows with null `base_task_id` (all ≤ 2026-08-28); `ext:*` left null. | Dry-run reports the count; after apply 0 task rows with null `base_task_id` except `ext:`; per-ticket totals equal `Budget.spend_so_far/2` for 5 sampled tickets. | — |
| 4 | Reports: `/reports` shell, nav entry, SVG chart components, filter bar | P1 / D2 | `ReportsLive` + `Nav` item; `ArbiterWeb.Charts` function components (bar, stacked bar, area, step line, histogram, stat tile); shared filter form (workspace, repo, type, difficulty, range); short-TTL result cache; empty/loading states. | Page renders at `/reports` under Analysis; each component has a LiveViewTest asserting its elements; passes `mix precommit` and `mix audit`; no new dependency. | — |
| 5 | Reports: throughput & lead time | P1 / D2 | §5.3 and the lead half of §5.2: weekly counts by difficulty, weighted size with the named weight table, lead-time histogram with P50/P90; era annotation at 2026-08-24. | Weekly bars match a manual `GROUP BY` for 3 sample weeks; lead P50/P90 match a hand computation on 5 tickets; weighting constant documented on the page. | 4 |
| 6 | Reports: cost per ticket by difficulty and provider | P1 / D2 | §5.6: median + P25–P75 per difficulty, provider/model/account split, unmetered rendering for Gemini/Codex, coordinator-overhead tile, windowed like `ticket_show.estimate`. | Totals match a manual `usage_events` sum for one workspace; no row-level load or `raw` select (query-count/shape test); null cost never rendered as $0; matches the `estimate` P25/median/P90 for a sample difficulty. | 3, 4 |
| 7 | Reports: ReviewGate health | P2 / D3 | §5.4 including a SQL port of `Resolutions.outcome/2`; same-family fallback; resolutions table. | Outcome parity test against `outcome/2` on fixtures for converged/resolved/not_converged/none; first-pass approve rate matches 20 hand-counted cycles; provider charts start at 2026-09-20 with a note. | 4 |
| 8 | Reports: cumulative flow and stage dwell | P2 / D3 | §5.1 and the stage half of §5.2 over `ticket_transitions` intervals; epic/difficulty filters. | Σ bands = tickets created on 6 sampled days; stage dwell for 5 hand-traced tickets (incl. one with a `return_to_work` repeat and one reopen) matches. | 2, 4 |
| 9 | Reports: epic burn-up | P2 / D2 | §5.7: scope from `dependencies.created_at`, done from transitions; weighted variant. | Real epic with > 5 children traced by hand; a reopened child steps the done line down. | 2, 4 |
| 10 | Reports: `ticket_attention_spans` capture | P1 / D3 | Table per §4.3; writers in `Attention.raise_cause/3`, `ClearAttention`, owner moves, and `AttentionSweep` (derived items: open on first sight, close on disappearance); one-off backfill from versions + typed escalations (2026-09-15 →). `verify_after_deploy`. | Raise/clear/hand-off/sweep promotion each produce the expected span; a derived `merge_blocked` produces a `derived: true` span that closes when it clears; backfill is idempotent. | — |
| 11 | Reports: attention / wait time | P3 / D2 | §5.5 over the spans plus `verifying` dwell; cause × owner × week. Ship after ≥ 2–4 weeks of capture. | Per-cause P50/P90 matches a hand computation over 5 spans; open spans flagged "still waiting"; operator vs coordinator time separable. | 10, 2, 4 |
| 12 | (Candidate, only if wanted) Reports: quota snapshot history | P4 / D2 | Append-only `quota_snapshots` written by the existing poll; pacing chart per account and window. | Rows written once per poll; chart shows 5h/7d utilization against the pace ceiling. | 4 |

Suggested order: file **1, 2, 10** first (history only accrues forward), then
**4, 3**, then **5, 6** (slice 1), then **7, 8, 9**, then **11**.
