# Post-merge deploy watch

Arbiter used to stop caring at merge. On a deploy-on-merge repo a broken CD was
invisible: on 2026-10-18 three tonic `main` pipelines (after !367) reported
SUCCESS while `build` and `deploy` were SKIPPED, and nothing noticed for ~2.5h.

`merge.repos.<repo>.deploy_watch` turns the watch on for one repo. **Unset means
off.**

```json
{
  "merge": {
    "strategy": "gitlab",
    "repos": {
      "tonic": { "deploy_watch": { "job": "deploy", "timeout_minutes": 90 } },
      "vstim": { "deploy_watch": { "jobs": ["deploy-web", "deploy-worker"] } }
    }
  }
}
```

| key | meaning |
|---|---|
| `job` / `jobs` | the deploy job name(s). With several, **all** must succeed. |
| `timeout_minutes` | how long after the merge a commit may stay undeployed (default 90). |

The branch watched is the repo's `merge.base` (default `main`). Works with the
GitLab and GitHub adapters (`deploy_pipelines/3`); GitHub "jobs" are workflow
jobs of push-event runs.

## Behaviour

`MergedPRFinalizer` runs the sweep every tick for the repo (`Arbiter.Workflows.DeployWatch`):

* Merged tickets (closed or `:verifying`, within 7 days) get a `deploy_watch`
  record in their `merger_status` holding the merge commit (`merge_sha`).
* The commit's own `main` pipeline, **or any later pipeline whose commit
  contains it**, is checked. All watched jobs `success` → the record becomes
  `state: "deployed"` with `deployed_at`, `pipeline_id`, `pipeline_url`. No alert.
* A pipeline auto-canceled by a newer merge, or a failed/skipped one while a
  later pipeline is still running, waits: supersession is not an alert.
* Alert (`deploy_failing`, coordinator-owned, visible in `alert_list` / the
  inbox) when the commit's own pipeline settled with the watched job(s)
  `skipped` / `failed` / `canceled` / `manual` / `missing` and no later pipeline
  is in flight, or nothing deployed it within `timeout_minutes`. The alert names
  the repo, pipeline, job statuses and merge SHA.
* One alert per repo outage: key `<workspace_id>:<repo>`, every affected merge
  listed in its detail. It clears when no undeployed merge remains.
