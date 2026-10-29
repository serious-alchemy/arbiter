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
