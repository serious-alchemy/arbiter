# Self-update runbook: `arb server deploy` and the dashboard button

This is the primary way to move a release install to a new version. Two entry
points, one implementation:

- **`arb server deploy`** — from a shell.
- **"Update to vX.Y.Z"** — a button in the dashboard's update banner, for the
  operator's own dashboard session. It launches the same command.

Both end up running `arb server deploy --version <tag> --json`.

## What a deploy does

1. **Resolve the release source.** `ARB_RELEASE_REPO` if exported; otherwise the
   running server's own release metadata (`release_repo` on `GET /api/version`);
   otherwise the repo this `arb` was built from. The output names which
   (`Release source: acme/arbiter (from the running server's release metadata).`).
   There is **no silent fallback** to anything else: if none of the three
   answers, the deploy stops and says so. The legacy `git pull` deploy of a source
   checkout runs only with an explicit `--git-pull`.
2. **Download, verify, unpack.** Tarball + `.sha256` from the GitHub Release
   (`GITHUB_TOKEN` authenticates a private repo); a checksum mismatch aborts
   before anything on disk changes. Only a published, tagged release is ever
   deployed — never an untagged build. (`--local <tarball|dir>` deploys a local
   build under a synthetic `local-<timestamp>` tag and is unchanged.)
3. **Back up the database** (see below). A failed backup or integrity check
   **aborts the deploy before the swap**.
4. **Swap `current`, restart, health-check.** The new release migrates the
   database during its own boot (`Arbiter.Boot.Migrator`), before the endpoint
   opens.
5. **Roll back if it does not come back green** (see below).
6. **Install the matching CLI.** After a green deploy the `arb` escript is
   updated to the same tag, so `arb doctor`'s `version` check reports
   `CLI and server match`. A failing CLI update does not fail the deploy (the
   server is already healthy): it is reported, and `arb self-update` finishes the
   job. `--no-self-update` skips it; `--local` deploys never touch the CLI.
7. **Prune** to the current release plus 3 prior ones, and to the newest 5
   database backups.

## The database backup

Before the swap, the deploy takes an **online** SQLite backup into

    <data-home>/snapshots/arbiter-pre-<tag>-<utc>.sqlite3

It is made by the release being deployed (`bin/arbiter eval
Arbiter.Release.Backup.eval_from_env`) with `VACUUM INTO` on a normal connection —
a consistent snapshot of the live WAL-mode database, **not** a file copy of the
`.sqlite3`/`-wal`/`-shm` trio. `PRAGMA integrity_check` runs on the copy, which
only gets its final name if it passes. The path is in the deploy's text and
`--json` output (`backup.path`, `backup.bytes`) and in the status file.

- No database file yet (a fresh host) → the backup is skipped, and the output
  says so.
- The database path is `DATABASE_PATH`, else the one in `<data-home>/arbiter.env`,
  else `<data-home>/arbiter.sqlite3`.
- `ARB_DEPLOY_BACKUP_RETAIN` (default `5`) is how many snapshots to keep.
- No `sqlite3` CLI is needed anywhere.

## Rollback, and restoring the backup

If the new release does not come back green within `--timeout` (default 60 s):

| The new release… | What happens |
|---|---|
| adds **no** migrations | `current` is re-pointed at the prior release and the service restarted. The database is **not** touched — restoring would discard writes for no schema benefit. |
| adds migrations **and booted** (so they ran) | The service is **stopped**, the database is replaced by the pre-deploy backup, then `current` is re-pointed and the service restarted. The previous release comes back on the schema it knows. |
| adds migrations, but the swap did not take (`/api/version` still reports the old version) | The old release is still serving and writing, so nothing is restored. The rollback is refused as before (`--allow-cross-migration-rollback` overrides). |
| adds migrations and the service cannot be stopped | Nothing is changed (a database must never be replaced under a running server); the rollback is refused and says why. |

Restoring never deletes anything: the database the failed release left behind
(and its `-wal`) is **moved aside** to
`<data-home>/snapshots/arbiter-failed-<tag>-<utc>.sqlite3[-wal]`, and the snapshot
itself is kept, so a restore can be repeated by hand.

What a restore costs: writes the *old* release made between the snapshot and the
stop. The snapshot is taken immediately before the swap, so that window is the
swap-to-restart gap — seconds.

`--json` on a rollback reports `rolled_back`, `rolled_back_to`,
`restored_database`, `backup_path` and `failed_database_path`.

## The dashboard button

When the update check has found a newer release, the banner shows **Update to
vX.Y.Z** next to the release-notes link. Clicking it asks first, naming the
version and whether the update has **pending migrations** (the release workflow
publishes `arbiter-<tag>-migrations.txt`; the server compares it with its own
`schema_migrations`; for a release without the file the prompt says it could not
be determined).

- **Who sees it.** Only a dashboard session — the operator's own browser login
  (`arb dashboard login`). The page that renders the banner is behind that login,
  and the button posts to `POST /release/deploy`, which is behind it too. A
  coordinator-tier bearer token, a worker or MCP has no dashboard session and is
  redirected to the login page. The route never takes the version from the form:
  it deploys the release the update check offered.
- **What it does.** Launches the deploy **outside the server's own BEAM**:

      systemd-run --user --unit=arbiter-deploy-<tag> --collect \
        --property=EnvironmentFile=-<data-home>/arbiter.env \
        --setenv=ARB_DATA_HOME=<data-home> \
        ~/.local/bin/arb server deploy --version <tag> --json

  because the deploy restarts `arbiter.service`. The transient unit belongs to the
  user manager, not to the service, so the restart cannot kill it. Secrets (the
  `GITHUB_TOKEN`) reach it through the environment file, never argv.
- **One at a time.** A second trigger is refused (409 / a notice) while any
  `arbiter-deploy-*` unit is active or the status file records a live deploy. A
  record whose process died does not block future deploys.
- **Progress and outcome.** The CLI writes `<data-home>/deploy-status.json` as it
  goes (`running` + phase → `succeeded`, `rolled_back`, `refused`, `failed`),
  which survives the restart. The banner reads it: *Updating to vX…* while it
  runs, then the result once the server is back — success, or the rollback with
  whether the database was restored and where the backup is. A success is shown
  for a day; a failure stays until the next deploy.

### Operator API

`POST /api/release/deploy` (`{"version": "vX.Y.Z"}`, or empty for the latest when
an update is available) and `GET /api/release/deploy` are `:operator` in
`ArbiterWeb.ApiPolicy`: an operator-proof token only. A coordinator session, a
worker and an anonymous caller are refused (403 / 401) and launch nothing. `202`
returns the unit; `409` means a deploy is already running (or nothing is newer, or
systemd cannot be reached); `422` is a version that is not a plain `vX.Y.Z` tag.

## `arb doctor`

`last deploy` reports the last recorded deploy — tag, time, outcome, and the
database backup path:

    [ ok ] last deploy
           last deploy v1.4.0 succeeded at 2026-10-06T12:00:00Z backup /home/me/.arbiter/snapshots/arbiter-pre-v1.4.0-20261006T115955Z.sqlite3

A rolled-back, refused, failed or interrupted deploy shows as `[fail]` with a
hint, but never blocks readiness or fails `arb doctor`.

## Configuration

| Variable | Meaning |
|---|---|
| `ARB_RELEASE_REPO` | `owner/repo` to take releases from (optional; see above). |
| `GITHUB_TOKEN` | Authenticates the Releases API / asset downloads (private repos). Never printed or logged. |
| `ARB_DATA_HOME` | Deploy root (default `~/.arbiter`). |
| `DATABASE_PATH` | The SQLite database to back up (default from `arbiter.env`, else `<data-home>/arbiter.sqlite3`). |
| `ARB_DEPLOY_BACKUP_RETAIN` | Backups to keep (default `5`). |
| `ARB_INSTALL_BIN` | Where the `arb` escript is installed (default `~/.local/bin/arb`); the button runs this one. |

## Manual recovery

If a rollback could not restore the database (or you want to do it by hand):

```sh
systemctl --user stop arbiter.service
# keep what is there, then put the snapshot back
mv ~/.arbiter/arbiter.sqlite3{,-wal,-shm} ~/.arbiter/snapshots/ 2>/dev/null
cp ~/.arbiter/snapshots/arbiter-pre-<tag>-<utc>.sqlite3 ~/.arbiter/arbiter.sqlite3
arb server deploy --version <prior-tag> --force
```
