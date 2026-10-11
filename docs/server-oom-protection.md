# Protecting arbiter.service from the OOM killer (bd-66anxj, GitHub #720)

Incident 2026-10-10: ~680 concurrent `arb` processes flooded the server, which
grew to 6.5 GB (DB pool checkouts > 15 s) and was SIGKILLed by the kernel OOM
killer as the largest process, interrupting four live runs. Two changes:

## 1. The unit prefers other victims

`arb install service` writes, in `[Service]`:

| Scope | Directives |
|-------|------------|
| system (`sudo arb install service --system`) | `OOMScoreAdjust=-500`, `ManagedOOMPreference=avoid` |
| user (default) | `ManagedOOMPreference=avoid` |

`OOMScoreAdjust` is not written for user units: lowering `oom_score_adj` below
its starting value needs `CAP_SYS_RESOURCE`, which a user manager does not have,
so the unit would fail to start. A user install therefore relies on
`ManagedOOMPreference=avoid` (steers systemd-oomd away) and on the bounded request
concurrency below. If you want the kernel-level bias on a user install, grant it
once as root with a drop-in on the system manager instead of the user unit.
Workers run in their own `arb-run` scopes and are unaffected.

**Existing installs:** re-run `arb install service` (it rewrites the unit and
reloads), or add a one-time drop-in with `systemctl --user edit arbiter.service`:

```ini
[Service]
ManagedOOMPreference=avoid
```

(system install: `sudo systemctl edit arbiter.service` and also add `OOMScoreAdjust=-500`), then restart.

## 2. `/api` concurrency is bounded

`ArbiterWeb.Plugs.ApiConcurrencyLimit` caps in-flight `/api` requests (the
`GET /api/events` SSE stream is exempt). Over the cap a request gets an immediate
`503 busy` with `Retry-After: 1` rather than queuing and growing the heap.

- Default 128; set `ARBITER_API_MAX_CONCURRENCY=N` in `arbiter.env` (`0` disables).
- The `arb` CLI retries 429/503-with-`Retry-After` up to 3 times (exponential
  backoff from the server's `Retry-After`), then fails with
  "server is busy … gave up after 4 attempts".
