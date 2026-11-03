# Syncing an MR branch with its target (`merge.sync_strategy`)

When a GitLab MR is behind its target — the forge reports `behind_base`, or the
pre-merge freshness check (`merge.require_up_to_date`) finds the head lacks the
target tip — Arbiter syncs the branch once and waits for CI on the new head.
`merge.sync_strategy` picks how.

| value | what happens | head SHAs |
|---|---|---|
| `merge` (default) | In the ticket worktree: fetch, `git merge origin/<target>`, then a plain (non-force) `git push origin HEAD:<branch>`. | The previously reviewed head is an ancestor of the new head. Nothing is rewritten. |
| `rebase` | `PUT /merge_requests/:iid/rebase`: the forge rewrites the branch and force-pushes it. | Every commit gets a new SHA; reviewed/ruled heads stop being ancestors. |

GitHub's update-branch already merges the base in, so the setting only applies
to GitLab.

```
arb config set merge.sync_strategy rebase                 # workspace-wide
arb config set merge.repos.<repo>.sync_strategy rebase    # one repo
```

## Who gets synced

In the merge queue, only the front of each target branch's queue is synced
(bd-d4m8qf): the PR the queue will merge next. The approved PRs behind it wait
for it, unsynced; each is synced once, onto everything merged ahead of it, when
it reaches the front. The queue view (`MergeQueue.queue_view/2`) marks the
front PR (`queue_head`) and the one each other PR waits for
(`waiting_for_head`). A front PR that cannot progress hands its place to the
next: its CI failed or never finishes, its sync keeps failing or is never
applied, the PR was closed, or the freshness gate parked it. One the merge
guards refuse keeps only its place in queue order.

On the **auto-merge lane** (`merge.auto_merge=true`) there is no queue process:
each ticket's Watchdog syncs its own approved MR. The same rule is applied
through `Arbiter.Worker.MergeTrain` (bd-1754qj), a registry the Watchdogs share
that uses the same head election as the queue (`Arbiter.Workflows.MergeHead`).
Per (workspace, repo, target branch) one MR at a time is in a sync or
CI-after-sync state, the head, chosen by priority and then by when it first
asked. Every other MR that needs a sync (the merge-time freshness sync, a
forge-reported `:behind_base`, a CI-remediation sync) waits without syncing,
logs `waiting for merge head <task>`, and spends no sync, no
`max_freshness_syncs` budget and no auto-resolve attempt; a red non-head MR
re-runs its failed jobs once per head instead of syncing. An MR within
`up_to_date_tolerance` merges without a sync whatever its place, one merge at a
time per target so the next freshness check sees the new target. The head hands
its place on on the same bounds as the queue's; a Watchdog that exits releases
it. After a server restart the train forms for `merge_train_settle_ms` (default
30s) so every Watchdog re-registers before a head is chosen. A train that
cannot be reached fails open: the MR syncs as it did before.

Hardening (bd-az0dcu): a head that reports itself ready to merge for
`merge.train_ready_ticks` polls (default 10) without merging, or that parks on
an undecidable coverage or a review round, hands its place on. The CI-wait
bound is `merge.train_ci_wait_ms` (default 2h) and counts only *running* CI, not
time queued; a head with no running pipeline (queued, or none at all) is capped
separately by `merge.train_ci_pending_max_ms` (default twice the CI-wait bound).
The sync marker is cleared when a head's place is handed on and whenever its
Watchdog stops deliberately; a restarted Watchdog is seated again only if its
sync was applied and its pipeline is running. The time an MR first asked and the head its sync started from are
recorded on the ticket's lane, so a restarted Watchdog keeps its order and a
head whose Watchdog crashed (or whose server restarted) keeps its place while
its synced pipeline runs: no second MR syncs beside it until it settles or the
CI-wait bound passes. At equal priority a green stale MR is elected ahead of
one in CI remediation.

## Phase 2: probe while waiting, CI only for the head (bd-4y9dno)

The train's waiting MRs used to find out they conflict only when their turn came,
and every commit pushed for one of them started a pipeline that was thrown away
when the head merged and moved the target. Phase 2 spends nothing on the waiters
until they are the head:

1. **Conflict probe.** A waiting approved MR (not the head) is probed on every
   poll: its branch and the target are fetched into the repo's own object store
   and `git merge-tree` judges them in memory (`Arbiter.Worker.MergeProbe`: no
   commit, no ref, no push). It is judged again only when the target or the
   branch moved. Clean, or anything git cannot answer, does nothing. A conflict
   is handled exactly as the forge's own `conflicting` flag would be: the
   conflict-resolution pass is dispatched now (bounded and escalated by the
   existing `max_conflict_attempts` rules), the resolution hunks void the
   approval carry as usual, and the MR is re-reviewed while it waits.
   `merge.train_conflict_probe=false` turns it off.
2. **Pushes without CI.** The pass dispatched for a waiting MR pushes with the
   forge's CI-skip mechanism (`Arbiter.Mergers.CiSkip`, the optional
   `ci_skip_mechanism/1` and `trigger_pipeline/2` adapter callbacks): GitLab
   `git push -o ci.skip`; GitHub a `[skip ci]` marker on the unpushed tip commit
   (only when `merge.train_ci_workflow` names a `workflow_dispatch` workflow, so
   the head can be started again). The pass reports the head it pushed
   (`Watchdog.note_ci_skipped_push/2`, recorded on the ticket's lane as
   `ci_skipped_head`). `merge.train_ci_skip=false` turns it off.
3. **CI for the head.** When a CI-skipped MR is current and is the merge head,
   Arbiter triggers its pipeline (GitLab: a merge request pipeline through the
   API; GitHub: a `workflow_dispatch` of `merge.train_ci_workflow` on the head
   branch) and merges only once that pipeline reports success. A skipped, neutral
   or missing pipeline never merges; a trigger the forge refuses is retried up to
   three times, then the MR is parked and the coordinator paged. "Pipelines must
   succeed" on the forge is the second line. A head that moves on (a sync, a new
   push) is no longer skipped.

An MR alone in its queue is the head: it is never probed, never pushed with a
skip, and merges as before.

## Merge path details

* The sync runs in the ticket's own worktree (attached if needed) under the
  layout the ticket's runs use. It needs a `repo_paths` entry for the repo; with
  none, the sync fails (it does not fall back to the rebase endpoint).
* A branch that diverged from `origin/<branch>`, a worktree with uncommitted
  changes, or one on another branch is refused rather than touched.
* **A conflict never force-pushes.** The merge is aborted, nothing is pushed,
  and the sync reports a conflict. The callers treat that like any failed sync:
  the MR is parked as `:conflict`, and the forge's `conflicting` flag on the
  next poll hands it to the existing conflict resolver.

## Fast-forward and semi-linear projects need `rebase`

A GitLab project whose merge method is *fast-forward* or *semi-linear* refuses
merge commits in the MR branch. Set `merge.sync_strategy: rebase` for those
(repos). A project on `merge_method: merge` takes merge commits and can use the
default.

## CI-failure remediation syncs first (bd-5owt7w)

The same `sync_strategy` (and the `require_up_to_date` / `up_to_date_tolerance`
/ `max_freshness_syncs` knobs) applies *before a CI failure is remediated*, not
only before merging. When an approved MR's CI is red and its head lacks target
commits, the Watchdog syncs the branch **instead of** dispatching a fix pass or
re-running the old head, then lets CI run on the synced head. A synced head that
passes needs no agent; one that still fails is current with the target, so it
earns a fix pass as before. The sync is booked against the freshness budget, not
`max_auto_resolve_attempts`. `ci_rerun` (MCP / REST / CLI) does the same: a stale
head is synced and the result says `action: synced`.

While the **target branch's own latest settled pipeline is failed**, MR CI
failures are *held* ("target branch red: <pipeline>"): no sync, no re-run, no
fix pass, no attempt spent, and the held polls do not count toward the poll
ceiling. The hold lifts when the target's pipeline is green, and remediation
resumes (syncing first). Both checks fail open when the forge or the local
checkout cannot answer.

An exhausted `:ci_failed` park also stamps the durable pending merge, so if the
Watchdog is lost the `PendingMergeSweeper` restarts it and a later green pipeline
merges without operator action.

## The speculative merge train (`merge.train.depth`, bd-6dyva0)

The serial train syncs and tests one MR per target at a time, so a busy target
with long pipelines drains one MR per pipeline while runners idle. With

```
arb config set merge.train.depth 3                    # workspace-wide
arb config set merge.repos.<repo>.train.depth 3       # one repo
```

up to K approved, green MRs that are behind the target are tested **at once**,
each in a *car*: `T1 = target + A`, `T2 = T1 + B`, `T3 = T2 + C`. Depth 1 (the
default) is the serial train above, unchanged. The train decides freshness, so it
runs where the merge-time freshness check does (`merge.require_up_to_date`,
on by default) and needs the repo in `repo_paths`.

**Where cars live.** A car is a merge commit Arbiter builds with git plumbing
(`merge-tree --write-tree` + `commit-tree`) in the repo's `repo_paths` checkout
and pushes to an Arbiter-owned branch, `arbiter/train/<task>`
(`merge.train.ref_prefix`). No MR branch and no worktree is touched. GitLab's
own merge trains are Premium-only; these refs work on any tier and on GitHub.
CI runs on the car ref: GitLab — the ref is pushed with `-o ci.skip` and the
train creates exactly one pipeline for it with `ARBITER_TRAIN_CAR=true`, which
the project's `workflow:rules` must admit (`- if: $ARBITER_TRAIN_CAR`); GitHub
— the push runs the repo's `on: push` workflows for `arbiter/train/**`, or
`merge.train.workflow` names a workflow to dispatch on the ref. A forge that
refuses car pipelines, or a pipeline that ran no jobs (skipped), sends the MR
back to the serial path rather than merging untested.

**How a car authorises a merge.** The MR is still merged by the forge, through
the Watchdog's usual guarded merge: coverage is decided on the MR's own head
(W1) and the merge is pinned to it (W7, `expected_sha`). The car only answers
the freshness half. It authorises the merge when all of these hold:

* the car's pipeline (on the car's own commit) is green — a red job in a
  `deploy`/`release` stage or a `deploy_watch` job does not count, as for the
  target-red hold (bd-dtbsgx);
* every car ahead of it has merged — it is at the front;
* the car is a proven non-authored merge (`TrainCar.verify/2`: its parents are
  exactly the commit it stands on and the MR head, and its tree is exactly
  `merge-tree` of the two);
* the forge's merge commit of the target *as it is now* and that MR head would
  carry exactly the car's tree (`TrainCar.landing_tree/3`), checked under the
  target's merge slot. When car 1's MR merges, the target tip becomes the
  forge's merge commit of the same two parents car 1 had, so car 2's prediction
  still holds and its pipeline stays valid; anything else that moved the target
  makes them differ, and the car is rebuilt on the new tip instead of merged.

After the merge the Watchdog checks the target's history carries the car's tree
(logged; a miss is logged as an error). Because the car never becomes an MR
head and never lands itself, the unreviewed-head and stale-reviewed-SHA guards
judge exactly what they judged before: the MR's own reviewed head. An
authored push after the car was built is caught by them on the next poll (a
review round), and the car — built from the old head — is never used. Were a
front car ever reported as an MR head, `SyncProof` already proves it to be the
reviewed head merged with the target and nothing else; a car on another car is
not proven, since it carries the other MR's commits. Registered as guard W23 in
`docs/review-coverage-and-guard-policy.md` §2.2.

**Red cars.** A red car is its MR's own fault only when every car ahead of it
is green (or merged); behind a car still running or red it holds. An MR whose
own car is red leaves the train for that head (ejected) and goes back to the
serial path: it is synced with the target and its own CI decides, so CI
triage, triage re-runs and fix passes apply exactly as before. The car's
pipeline is the evidence: noted on the ticket and included in the fix pass's
briefing. Every car behind it re-bases: its Watchdog cancels the superseded
pipeline (`cancel_ref_pipeline`) and rebuilds the car on the new base. A car
whose pipeline was cancelled by something else is started again once.

**Bounds.** A car is rebuilt at most `@car_builds_per_head` (6) times on one
head (a target that keeps moving under it), then the MR takes the serial path,
whose freshness budget parks and pages. A conflict with the target or the cars
ahead, or a car that cannot be built three times running, does the same.
Waiting on the train is a held poll: it never runs into the review-timeout
ceiling. A seated MR that stops reaching a merge decision (its own CI
re-running, a review round, a block) gives its seat up after a few polls.

**Interactions.**

* `up_to_date_tolerance` — an MR at the front that is current with the target
  within the tolerance merges on its own green pipeline, exactly as without the
  train; a car-authorised merge needs the exact tree, never a tolerance.
* Hold-on-red-target (bd-5owt7w) — while the target's own latest pipeline is
  red, no car is built and no red car is ejected; when the target is green
  again a car that failed meanwhile is rebuilt on it rather than blamed.
* CI backpressure (#1126) — while `worker.repos.<repo>.ci_backpressure` holds,
  only the front car is built (the train behaves like depth 1); cars already
  running are left to finish.
* Merge train phase 2 (bd-4y9dno, above) — the conflict probe and CI-skipped
  pushes are for an MR waiting on the *serial* train (an ejected MR waiting for
  the serial head, say). A car's MR, and an MR waiting for a seat, is neither
  probed nor pushed without CI: a conflict with the target or the cars ahead
  shows when its car is built, and ejects it to the serial path, where both
  apply. A head a CI-skipped push left boards no car. A car tests that head
  merged into the target, but only a pipeline of the head's own satisfies the
  forge's "pipelines must succeed", and triggering one while the car waited at
  the front would idle the car out of its seat and rebuild every car behind
  it. So it takes phase 2's way — synced if it is behind (a push with CI), its
  pipeline triggered as the serial merge head if it is current — and boards
  once a head of its own has CI again.
* Restarts — each car is recorded on its ticket's lane (`train_car`: ref,
  commit, tree, base, the task whose car it stands on, MR head, pipeline). A
  restarted train forms for `merge_train_settle_ms` and puts each car that comes
  back behind the car it stands on, keeping a seat for a car not back yet; while
  it forms, cars only report. Nothing merges twice (a merged MR's Watchdog sees
  it merged first) and no car is skipped (a car merges only when the target
  already carries every car ahead of it — the landing-tree check). A crashed
  Watchdog's car keeps its seat while its restart is awaited.
