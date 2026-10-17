# Deterministic visual-baseline refresh

(bd-9obzu9, GitHub #936.)

Several UI branches change the same pages, so every merge to main makes the other open
branches' Playwright reference images stale and their `visual` job fails. Fixing it is
mechanical — download the job's `*-actual.png` files, copy them over the baselines,
commit, push — and used to cost an agent round each time. With
`worker.repos.<repo>.visual_baselines` set, Arbiter does it itself, in the case where
that is provably safe, and in no other.

## What happens

The Watchdog (`Arbiter.Worker.Watchdog`) polls an approved PR it is auto-merging. When
the head's CI is red (`:ci_failed`) it calls `Arbiter.Worker.VisualBaselines.refresh/1`
**before** it dispatches a fix pass, once per head:

1. **Only the visual job failed.** `ci_job_artifacts/3` (a `Mergers.Merger` callback;
   GitLab and GitHub implement it) returns the failed jobs of the head's latest pipeline
   and the visual job's artifacts archive. Any other failed job → no refresh. A pipeline
   for a different commit than the PR head → no refresh.
2. **It is main's drift, not the branch's own work** (`VisualBaselines.Drift`). The last
   commit on the branch whose visual job passed (`last_green_job_sha/3`) is compared with
   the head. The branch's *own contribution* — its diff from the merge base with the
   target branch — must be unchanged between the two, for every file that is neither a
   baseline image nor matched by `ignore_paths`. That holds whether main was merged in or
   the branch was rebased (history rewritten, the green commit no longer an ancestor).
   Refused, with the normal fix path running instead: no green run on record, the green
   commit unreachable, the head having the green commit's tree (a flake, not drift), the
   head already being an auto-refresh commit, and **any** own change to a rendering file
   since the green run. A file both the branch and main edited near each other counts as
   the branch's change: the heuristic errs towards "do not refresh".
3. **Every actual image maps to exactly one existing baseline** (`VisualBaselines.Archive`).
   A snapshot with no baseline (a new test), two baselines of the same name, two actuals
   for one snapshot, more than `max_snapshots`, or nothing that differs → no refresh.
4. In a throwaway checkout of the branch (never the shared checkout) Arbiter overwrites
   **only those baseline files**, verifies git staged exactly that set, commits
   `Refresh visual baselines after syncing main (auto)` and pushes — a plain,
   non-forced push with the repo's host credential (`HostCredential`). A branch that moved
   meanwhile rejects the push; nothing is overwritten.

## Review is not skipped

The push is recorded as an *authored push* exactly like a CI fix pass's
(`Watchdog.note_authored_push/1`): the approved baseline stays pinned, so the new head —
which carries an image diff — is judged on content and routed back through the ReviewGate
(`resolve_stale_reviewed_head/3`), and is never stamped reviewed. The Watchdog waits up to
20 polls for the forge to report the new head rather than reading the lag as a failed
refresh. A refresh that does not turn the head green is not repeated: the next red head
carries the auto-refresh commit, which the heuristic refuses, so the normal fix path runs.

## Config

`worker.repos.<repo>.visual_baselines`, merged over `worker.visual_baselines`
(repo keys win). Validated on write. Unset: off, with no behaviour change.

| key | meaning |
| --- | --- |
| `job` (required) | CI job that takes the screenshots |
| `baseline_dir` (required) | repo-relative directory holding the baselines; searched recursively |
| `artifact` | GitHub only: name of the Actions artifact the job uploads (GitLab reads the job's own artifacts) |
| `artifact_path` | directory inside the archive holding the actual images (default: the root) |
| `actual_suffix` | actual images end in this (default `-actual.png`); the rest of the name is the snapshot name |
| `baseline_suffix` | the baseline is `<baseline_dir>/**/<name><baseline_suffix>` (default `.png`) |
| `layout` | `default`, or `playwright`: actual `<results-dir>/<arg>-actual.png` maps to `<baseline_dir>/**/<arg>-<project>-<platform>.png`, `<project>` being the longest project (from existing baseline names for that `<arg>`) the results dir name ends in, after stripping `-retryN`; retry dirs of one snapshot are one snapshot (last retry wins), unmatched/ambiguous refuses |
| `platform` | playwright layout only: the platform in the baseline name (default `linux`) |
| `ignore_paths` | globs (`*`, `**`, `?`) of files that never render a page; other own changes block the refresh |
| `max_snapshots` | refuse to refresh more than this many at once (default 50) |

### Example: tonic (GitLab)

```json
{
  "worker": {
    "repos": {
      "tonic": {
        "visual_baselines": {
          "job": "visual",
          "artifact_path": "test/visual/test-results",
          "actual_suffix": "-actual.png",
          "baseline_dir": "test/visual/tests/__screenshots__",
          "layout": "playwright",
          "platform": "linux",
          "ignore_paths": ["docs/**", "**/*.md", ".gitlab-ci.yml"]
        }
      }
    }
  }
}
```

The baseline directory follows Playwright's default `snapshotPathTemplate`
(`{arg}-{projectName}-{platform}{ext}`, e.g. `app.visual.spec.ts/patient-summary-mobile-dark-linux.png`);
actuals are `test/visual/test-results/<test>-<project>[-retryN]/<arg>-actual.png`. The `playwright`
layout reads the project from the results directory name. `artifact_path` must be the
directory the repo's `visual` job lists under `artifacts:paths` (tonic: `test/visual/test-results/`,
with `when: on_failure`, which satisfies the upload-on-failure requirement below). For GitHub add
`"artifact": "<name the workflow uploads>"`; Actions artifacts belong to a workflow run,
not a job.

The visual job must upload the actual images as artifacts **on failure**
(`artifacts: when: always` / `if: always()` on the upload step).

## Limits

- Only the Watchdog's `:ci_failed` path tries it. A red head that is still on its way to
  its first review (`ReviewGate`'s own CI wait) takes the existing fix round.
- The pipeline's artifacts must still exist (they expire) and the head's pipeline must be
  for the PR head commit itself — a GitLab merged-results pipeline (a different sha) is
  refused.
- The GitHub adapter reads check runs, workflow runs and artifacts with the endpoints
  above; it is covered by stubbed-HTTP tests, not yet run against a live repository.
