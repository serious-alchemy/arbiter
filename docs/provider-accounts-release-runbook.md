# Migrating a release install to provider accounts

**Audience:** an operator running Arbiter as an OTP release
(`~/.arbiter/current/bin/arbiter`, managed by `arbiter.service`), which has no
Mix toolchain. On a source checkout, the `mix arbiter.accounts.*` tasks do the
same things. They are thin wrappers over the functions used here.

## Release notes: provider accounts are required (the P13 flip, bd-9gqj8e)

> **Irreversible. This release requires provider accounts to be enabled —
> migrate every install before upgrading to it.**

- **The `:provider_accounts_enabled` flag is gone.** Provider accounts are
  always on. The `ARBITER_PROVIDER_ACCOUNTS` variable is no longer read; if
  the server's environment still sets it, the boot logs a warning saying so.
  Remove it from `~/.arbiter/arbiter.env`.
- **The legacy credential chain is deleted.** A spawn's provider credential
  comes from its workspace's provider account and nowhere else. That covers
  every spawn path: workers, the `CredentialWatchdog` probe, the quota poll,
  and code-review checks. None of these is a credential source any more:
  - a workspace's own `worker_env` token;
  - `CLAUDE_CODE_OAUTH_TOKEN` in the server's environment;
  - the install-wide "single unambiguous workspace token".

  A spawn with no workspace in hand (the watchdog probe, a workspace-less
  review) takes the install's single enabled Claude account credential, and
  carries none if there is not exactly one.
- **There is no switch back.** Before this release, `ARBITER_PROVIDER_ACCOUNTS=0`
  returned workers to the legacy chain. Now nothing does. A workspace whose
  credential is still only in `worker_env` raises
  `Arbiter.Accounts.MissingCredentialError` on every spawn. The dispatch guard
  holds that workspace's Claude tickets and escalates once. The only way back
  to the legacy chain is to run the previous release binary.
- **`arb install service` no longer copies `CLAUDE_CODE_OAUTH_TOKEN`** from the
  installing shell into `arbiter.env`. Nothing would read it.
- **`/providers` is never read-only.** The "Accounts not enabled on this
  install" banner is gone.
- **No schema migrations.**

### Upgrade order

1. **On the release you run now (v0.2.x),** make sure `arb server doctor`
   reports `[ ok ] provider accounts` with `on (...)`. If it reports `[fail]`,
   or `off (ARBITER_PROVIDER_ACCOUNTS=0)`, migrate first with the procedure
   below and restart.
2. **Upgrade to this release.**
3. **Run `arb server doctor` again.** Expect `[ ok ] provider accounts` and
   `[ ok ] claude worker credentials`.

If you upgrade an install that was not migrated, its workspaces cannot spawn
until they are. The procedure below still works on this release, run the same
way, with the server stopped for step 5.

## What the boot reports

At every boot the server classifies the install
(`Arbiter.Accounts.Enablement`). Accounts are on in every case; the
classification decides only what is auto-joined and what doctor reports:

| Install | Result |
| ------- | ------ |
| **Fresh**: no workspace `worker_env` carries a provider credential, and there is no `CLAUDE_CODE_OAUTH_TOKEN` in the server's environment | Every workspace, and each one created later, is joined to `<provider>:default`. Add the credential with `arb account rotate claude:default ...`; `arb server doctor` names the exact command. |
| **Already migrated**: at least one migration backup row that has not been rolled back | Nothing is joined automatically. Doctor reports `on (migrated)`. |
| **Legacy credentials, not migrated**: a workspace `worker_env` or the server environment still carries a provider credential, and there is no migration record | The boot logs a warning naming them, and `arb server doctor` reports `[fail] provider accounts`. Nothing reads those credentials: the named workspaces cannot spawn. Follow this page to migrate. |

To move such an install onto accounts, move each workspace's credential into
a provider account. This is the P2 migration in
[`provider-account-design.md`](provider-account-design.md) §7.

Every step below is either read-only or has a written undo. Read the whole
page before starting.

## What the operations print

The census, migrate and rollback operations print, log and return only
workspace names, env var **names**, counts and sha256 fingerprints. They never
print a credential value. The plan file they read and write is mode `0600` and
holds fingerprints, not values.

## Before you start

1. **Run a release that has `Arbiter.Release.accounts_census/1`.** Check
   which release is live with `readlink ~/.arbiter/current`.
2. **Rotate first if you need to** (§7.6). If `ARBITER_CLOAK_KEY` or the
   credential itself is considered exposed, rotate the key
   ([`cloak-key-rotation.md`](cloak-key-rotation.md)) and re-issue the
   credential **before** migrating. Otherwise the migration writes fresh
   ciphertext under a key you are about to retire.
3. **Put server-env-only tokens into a workspace.** The census only sees
   credentials stored in a workspace's `worker_env`. A
   `CLAUDE_CODE_OAUTH_TOKEN` that only lives in `~/.arbiter/arbiter.env` is
   invisible to it. Set it on at least one workspace first, in the dashboard's
   workspace environment editor.
4. **Load the server's environment in the shell you run `eval` from.**
   `bin/arbiter eval` starts a separate VM, not the service. It needs the
   same `ARBITER_CLOAK_KEY` (to decrypt `worker_env`), `SECRET_KEY_BASE`
   (`config/runtime.exs` refuses to load without it) and, if you set one,
   `DATABASE_PATH`:

   ```sh
   set -a; . ~/.arbiter/arbiter.env; set +a
   ARB=~/.arbiter/current/bin/arbiter
   PLAN=~/.arbiter/accounts.json      # any absolute path, or one starting with ~
   ```

Each `eval` starts only config, Ash, the Ecto repo and the Cloak vault
(`Arbiter.Release.start_release_vault!/0`). It never starts the endpoint,
Autopilot, patrols or the worker fleet, so it cannot collide with a running
server's port or advisory lock. A refusal prints `** (Arbiter.Release.Refused)
<reason>` and exits non-zero.

## Procedure

### 1. Census (read-only, safe with the server running)

```sh
$ARB eval "Arbiter.Release.accounts_census(plan: \"$PLAN\")"
# optionally fingerprint the operator's own Claude login as a suggestion:
$ARB eval "Arbiter.Release.accounts_census(plan: \"$PLAN\", operator_credential: \"$HOME/.claude/.credentials.json\")"
```

The census prints every workspace, which provider-credential keys it holds, and
the candidate accounts, grouped by `(provider, sha256)`. It then writes a
**candidate** plan to `$PLAN` and writes nothing to the database. It will not
overwrite an existing plan unless you add `force?: true`, because an edited
plan is the record of your decisions.

### 2. Edit the plan

Rename the slugs, and merge any candidates you know to be one account. Two
different tokens can belong to one Anthropic plan (§2.2). Fingerprints alone
cannot tell you that. If every workspace in a candidate group is already joined
to a single existing account, the census will have proposed that account's
slug and label automatically, marked with "→ existing" in the report — no
rename is needed in that case.

### 3. Dry run (writes nothing, safe with the server running)

```sh
$ARB eval "Arbiter.Release.accounts_migrate(plan: \"$PLAN\", dry_run?: true)"
```

The dry run runs every validation the real run does. It reports the accounts,
credentials and workspace attachments it would create, and the keys it would
move out of each `worker_env`. If it refuses, fix the plan, or re-run the
census with `force?: true`, and repeat. Nothing has been written.

### 4. Stop the server and back up the database

```sh
systemctl --user stop arbiter.service
mkdir -p ~/.arbiter/pre-accounts-backup
cp -p ~/.arbiter/arbiter.sqlite3* ~/.arbiter/pre-accounts-backup/   # or your DATABASE_PATH
```

Stop the server because the migration removes the key from `worker_env`, and
a worker spawned mid-migration could see a workspace half-way through. With
the server stopped, the migration is also the only writer on the SQLite file,
and the copy is consistent. The glob also picks up any `-wal` / `-shm` files
next to the database.

### 5. Migrate

```sh
$ARB eval "Arbiter.Release.accounts_migrate(plan: \"$PLAN\")"
```

For each affected workspace, the migration:

1. creates the account, credential and workspace-join rows;
2. writes a **Vault-encrypted backup** of the workspace's `worker_env`
   (`provider_account_migration_backups`) **before** touching it;
3. removes only the allowlisted provider-credential keys from that `worker_env`.

Every check runs before the first write, so a refusal writes nothing. The
output ends with the **migration id** and the exact rollback command. Keep
both. Add `delete_plan?: true` if you want the plan file removed after a
successful apply.

### 6. Clean up the server environment

There is nothing to switch on. The migration wrote backup rows, and those are
the migration record the boot looks for. Remove from `~/.arbiter/arbiter.env`:

- any `ARBITER_PROVIDER_ACCOUNTS` line. It is no longer read, and the boot
  warns while it is there;
- `CLAUDE_CODE_OAUTH_TOKEN`, once step 1's census has fingerprinted it. It is
  read by nothing, it makes doctor note it, and a stale credential in a
  secrets file is a risk of its own.

### 7. Start the server

```sh
systemctl --user start arbiter.service
```

### 8. Verify

- **The install is migrated.** `arb server doctor` reports
  `[ ok ] provider accounts` with `on (migrated)`. The boot log has a
  `Provider accounts: migrated` line and no warning naming a workspace.
  The dashboard's `/providers` page lists the migrated accounts with their
  credential health.

  `arb server doctor` also runs the `account/workspace quota policy` check.
  `Arbiter.Quota.Gate` binds `min(account, workspace)` — the account's quota
  policy is a ceiling that a workspace can tighten, never loosen. If a
  workspace's configured quota is overridden by a stricter account setting,
  adjust the account side using
  `arb account set <ref> --threshold-mode … / --weekly-threshold …`.
- **The rows are there.** `arb account list` shows each account from the
  plan.
- **Workers get their credential from the account.** Dispatch a task in each
  migrated workspace. It should run normally, and the log should show no
  `MissingCredentialError`:

  ```sh
  journalctl --user-unit arbiter.service --since "10 min ago" | grep -i MissingCredentialError
  ```

  A hit names the workspace. Either migrate its credential (census, then
  migrate again) or roll back as described below.
- **The undo is still available.**
  `$ARB eval 'Arbiter.Release.accounts_rollback(list?: true)'` lists the backup
  rows as `pending`.

## Rolling back

Since the P13 flip there is **no switch back to the legacy credential chain**
on this release. Two undos remain.

**Put the credentials back into `worker_env`.** This is only useful together
with running the previous release binary, since nothing on this release
reads `worker_env` credentials. Stop the server and dry-run the restore first:

```sh
systemctl --user stop arbiter.service
$ARB eval 'Arbiter.Release.accounts_rollback(list?: true)'
$ARB eval 'Arbiter.Release.accounts_rollback(migration_id: "<id from step 5>", dry_run?: true)'
$ARB eval 'Arbiter.Release.accounts_rollback(migration_id: "<id from step 5>")'
```

The restore re-merges each backup through the same `MergeWorkerEnv` change the
migration used, including each key's secret flag. By default it restores
**only the keys that migration removed**, so later edits to other keys are
kept. Pass `all_keys?: true` to re-merge the entire snapshot instead. The
selectors are:

- `migration_id: ID`: every backup from one migrate run.
- `backup_id: UUID`: one backup row.
- `workspace: NAME`: that workspace's latest un-restored backup.
- `all: true`: every un-restored backup.

The rollback leaves the `provider_accounts` / `provider_credentials` rows in
place. Once every backup is restored the install has no migration record, and
the boot reports it as carrying legacy credentials again.

**Run the previous release.** Point `~/.arbiter/current` back at the previous
release, set `ARBITER_PROVIDER_ACCOUNTS=0` in `~/.arbiter/arbiter.env` (on
that release an unset value means `auto`, which resolves a migrated install
on), and start the server. This release adds no schema migrations, so the
binary rollback does not need a database restore. The last resort is the
database copy from step 4, restored with the server stopped.

## Source-checkout equivalents

| Release (`bin/arbiter eval`)                                   | Source checkout                                        |
| -------------------------------------------------------------- | ------------------------------------------------------ |
| `Arbiter.Release.accounts_census(plan: P)`                     | `mix arbiter.accounts.census --plan P`                 |
| `…accounts_census(plan: P, force?: true, operator_credential: C)` | `… --force --operator-credential C`                  |
| `Arbiter.Release.accounts_migrate(plan: P, dry_run?: true)`    | `mix arbiter.accounts.migrate --plan P --dry-run`      |
| `…accounts_migrate(plan: P, delete_plan?: true)`               | `… --plan P --delete-plan`                             |
| `Arbiter.Release.accounts_rollback(list?: true)`               | `mix arbiter.accounts.rollback --list`                 |
| `…accounts_rollback(migration_id: ID, dry_run?: true)`         | `… --migration-id ID --dry-run`                        |
| `…accounts_rollback(all: true, all_keys?: true)`               | `… --all --all-keys`                                   |

The Mix tasks also start only config, Ash, the repo and the vault, never the
full application.
