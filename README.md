# Arbiter

**Arbiter** is an AI-driven ticket tracker and autonomous coding agent harness. It coordinates work across your projects through a CLI (`arb`), MCP tools for a coordinator agent, and a LiveView dashboard. Tasks are tracked as **tickets**, dispatched to **worker** agents for autonomous execution in isolated git worktrees, and merged through a **ReviewGate** and **merge queue** for code quality and safety.

## Prerequisites

- **Elixir 1.19+ / Erlang 28+** — [mise](https://mise.jdx.dev/) is the
  recommended way to install. With mise installed:

      mise install

  (The `.tool-versions` file in this repo pins the exact versions.)

Arbiter's datastore is **SQLite** — no database server or Docker is required.

## Install (development)

```sh
# 1. Clone
git clone <repo-url> arbiter
cd arbiter

# 2. Install dependencies, run migrations, seed the default workspace
mix setup

# 3. Build and install the arb CLI onto your PATH
arb install cli
```

`arb install cli` builds the CLI escript from `apps/arbiter_cli` and installs
it to `~/.local/bin/arb`. If `~/.local/bin` isn't in your PATH yet, add this
to your shell profile (`.bashrc`, `.zshrc`, etc.) and restart your terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Since `arb install cli` itself depends on `arb` already being on your PATH the
very first time, bootstrap it once by hand:

```sh
cd apps/arbiter_cli && mix escript.build && cd ../..
mkdir -p ~/.local/bin && cp apps/arbiter_cli/arb ~/.local/bin/
```

Re-run `arb install cli` any time you pull changes to `apps/arbiter_cli`.

## Architecture

**Workspaces** — isolated coordination scopes. A workspace holds a set of tickets, dispatch policies, and tooling configuration. An installation can run multiple workspaces side by side, each with its own repos, tracker, and merge settings.

**Repos** — registered git repositories. Workers check out code on repos to work on tickets.

**Tickets** — tasks to be worked (formerly *issues*; `arb issue` and the `task_*` MCP tools remain as deprecated aliases for one release). Can be tracked in an external system (Jira, GitHub, Linear) or managed locally. A ticket moves through one lifecycle state: backlog → queued (Ready) → active (In progress) → merging → verifying → closed.

**Workers** — autonomous agents spawned via Claude Code (or future adapters) to work a ticket. Each worker receives a ticket, works it in an isolated git worktree, and reports completion with a PR or notes. Their full transcript is retained for audit and learning.

**ReviewGate** — optional quality checkpoint. A second Claude agent reviews the worker's work before merging. Can be disabled per-ticket.

**Merge queue** — batches approved changes and applies them to the repo in sequence. Handles merge conflicts, CI status checks, and rollback on failure.

**PRPatrol** — polls open PRs per repo and dispatches follow-up workers when a review needs a response (changes requested, unresolved review threads, or failing required checks).

**Watchdog** — polls a merge request's fate for a worker parked at `:awaiting_review` and drives the worker to its terminal state (merged, closed/rejected, or auto-merged).

**Escalation mailbox** — the coordinator's inbox for anything that needs a human or coordinator ruling (e.g. a ReviewGate escalation, a worker failure). Read it via `arb message inbox` or the `inbox_check` / `notify_list` MCP tools.

**`/events`** — a server-push event stream (`GET /events`) for the coordinator: newline-delimited JSON, one event per line, for topics like `inbox`, `review_gate`, `worker_failed`, `worker_done`, and (opt-in) `task_state` / `external_review`. Every event carries a `"cursor"`; pass `since=<cursor|timestamp>` to replay what was missed since a disconnect before rejoining the live stream (see `ArbiterWeb.Api.EventController` moduledoc).

## Coordinating via MCP

The primary integration path for a coordinator agent (e.g. a dedicated Claude Code session) is the `arbiter` MCP server, which exposes tools like `ticket_show`, `ticket_create`, `ticket_list`, `worker_dispatch`, `worker_resume`, `worker_review`, `worker_list`, `worker_log`, `inbox_check`, `message_send`, `notify_list`, `workspace_show`, `workspace_config_get/set`, `quota_get`, `run_log_list`, `transcript_capture_stats`, and `usage_summarize`, plus whole tool categories beyond one-off ticket dispatch:

- **Skills** — `skill_list`/`skill_get`/`skill_create`/`skill_update`/`skill_delete` for managing reusable skill content.
- **Dependencies + scheduler** — `dep_add`/`dep_remove`/`dep_list` to wire tickets together with `depends_on`/`blocks`/`conflicts_with` edges, and `scheduler_pause`/`scheduler_resume`/`scheduler_status` to control the board scheduler (Autopilot) that auto-dispatches Ready cards in edge order. A pause stops new board dispatches only — fix passes, conflict resolvers and review rounds already under way keep running — so `scheduler_status` reports a drain state (`running` / `draining` with what is in flight / `quiescent`, the only safe restart point); `arb scheduler pause && arb scheduler wait` blocks until it is safe to restart. Chains of tickets run by declaring the edges, not by building a separate graph object.
- **Gate escalations** — `review_gate_rounds_list` shows a ticket's ReviewGate rounds, plus the coordinator's recorded answer and an `outcome` (`converged` / `resolved` / `not_converged`); `review_gate_resolve` (CLI: `arb review resolve <ticket> --amend "<reasoning>"`) records that answer — `accept_as_is` / `amend` / `send_back` / `reject`, with reasoning, actor and timestamp — when a gate escalates on its round or send-back cap, so an override of a reviewer's standing finding is on record rather than only in a commit message. The merge path reads it: a PR whose latest reviewer verdict is not APPROVE merges only when an `accept_as_is` / `amend` covers its head; `send_back` means another review round follows the implementer's completion and never permits a merge by itself. Cap hits and resolutions are the opt-in `gate_cap_hit` / `gate_resolved` event topics.
- **ExternalReview** — `external_review_list`, `external_review_show`, `external_review_transcript`, `review_greenlight` for inspecting and unblocking worktree-backed external code review. `external_review_transcript` is `worker_log`'s counterpart for a review: the prompt it was given, the raw transcript its reviewer emitted, and every tool call paired with its result — keyed on the review record id, since an external review is not ticket-linked.

See `apps/arbiter/lib/arbiter/mcp/catalog.ex` for the full, current catalog and which tier (worker vs. coordinator) can call each tool.

To mint a token for a coordinator to use, run this on the server host from
your own shell:

```sh
arb mcp token mint --tier coordinator
```

It proves you are the operator over the server's local operator socket. The
server refuses anonymous `POST /api/mcp/tokens`, and it refuses any process
it spawned itself (workers, reviewers, sessions). See
[docs/worker-security.md](docs/worker-security.md#operator-proof-for-token-minting-bd-8381tk).

The server speaks MCP over **Streamable HTTP** at `http://127.0.0.1:4848/mcp`,
so configure a client with `"type": "http"` (Claude Code), `httpUrl` (Gemini
CLI) or a plain `url` (Codex CLI), and pass the token as
`Authorization: Bearer <token>`:

```json
{
  "mcpServers": {
    "arbiter": {
      "type": "http",
      "url": "http://127.0.0.1:4848/mcp",
      "headers": { "Authorization": "Bearer <coordinator-token>" }
    }
  }
}
```

Streamable HTTP is the **only** transport `/mcp` serves. The deprecated HTTP+SSE
transport (2024-11-05, Claude Code's `"type": "sse"`) is not served: a client
configured that way POSTs `initialize` and then waits for the reply on the SSE
stream, which never arrives, so it times out and reports the server as down. Use
`"type": "http"` — which is what `arb init` and worker dispatch write. The
`GET /mcp` SSE stream still exists, but only as Streamable HTTP's server →
client channel (server-initiated messages and keepalives); it requires a
coordinator token.

## Quick-start

### 1. Start the server

```sh
arb server start
```

The dashboard is at **http://127.0.0.1:4848**.

### 2. Configure a workspace

Visit the dashboard's **Workspace** page and configure:
- **Repos** (projects to work in)
- Worker/agent settings — model tier map, per-thinking-level args, provider overrides, and credentials (`agent.config.*`)
- Security policy (`agent.security.*`)
- Rate-limit throttling (`quota.*`). Worker concurrency is bounded per machine (`arb node set`), per provider account (`max_concurrent`) and, optionally, per repo (`worker.repos.<repo>.max_concurrent`); `conductor.max_concurrent` was removed
- Optionally a **tracker** (Jira, GitHub, Linear) and merge strategy

Or edit `config/dev.exs` directly and restart the server, or use `arb config set`.

### 3. Dispatch your first ticket

Create and dispatch a ticket via the dashboard or CLI:

```sh
arb ticket create "Fix typo in README"
arb ticket dispatch <id> my-project
```

Watch the worker in the dashboard, or tail the transcript:

```sh
arb worker log <task-id>
```

Once complete, the merge queue picks it up (if configured) or you can merge manually via the dashboard.

### Running as a systemd service

To run Arbiter as a self-contained OTP release under a systemd user unit, install and enable it with:

```sh
arb install service
```

This writes `~/.config/systemd/user/arbiter.service` (`ExecStart=~/.arbiter/current/bin/arbiter start`), enables it via `loginctl enable-linger` for machine-boot startup, and starts the release. Manage it with `systemctl --user status arbiter.service` and view logs with `journalctl --user -u arbiter.service -f`. Pass `--system` to install a system-wide unit instead (needs root). Secrets and PATH configuration live in `~/.arbiter/arbiter.env`. Uninstall with `arb install service --uninstall`. The unit sets `OOMPolicy=continue` and each worker runs in its own memory-capped scope (`ARBITER_WORKER_MEMORY_MAX`, default 40% of RAM), so one runaway worker process cannot stop the server — see [docs/worker-memory-cap.md](docs/worker-memory-cap.md), including the drop-in for a unit installed before this.

`arb install service` only writes the release-shaped unit above. There is no
CLI command yet for a dev-mode unit (one whose `ExecStart` runs
`mix phx.server` instead of a release binary) — on a source checkout you hand-write
that unit file yourself; see [Deploying: pick the path for your install
shape](#deploying-pick-the-path-for-your-install-shape) below.

### Deploying: pick the path for your install shape

Arbiter supports two install shapes, and the deploy command differs between
them:

- **Source checkout (dev mode)** — a git clone with `mix phx.server` run
  directly (by hand, or supervised by a systemd user unit that points
  `ExecStart` at `mix phx.server` rather than a release binary). This is how
  the "Install (development)" section above sets things up, and how this
  repo's own coordinator instance runs today — the releases strategy is
  scoped but not yet built. A source checkout deploys with an explicit
  `arb server deploy --git-pull`; a bare `arb server deploy` is always the
  release path and never falls back to it.
- **OTP release install** — a built release artifact unpacked under
  `~/.arbiter/releases/<tag>/`, installed via `arb install service`. No
  source checkout or Elixir/Mix toolchain on the box.

If you're on a source checkout, use the sequence below. If you have a release
artifact installed, skip to [OTP-release installs](#production-deploys-otp-release-installs).

#### Source checkout (dev mode)

```sh
git fetch origin main
git diff --name-only HEAD origin/main -- mix.lock   # non-empty → deps changed; see note below
arb server deploy --git-pull
arb server doctor     # confirm CLI and server report the same version
```

`arb server deploy --git-pull` does the pull → rebuild → restart → migrate
sequence for you: `git pull --ff-only` on `main`, rebuild and install the CLI
escript if `apps/arbiter_cli` changed, then restart Phoenix — via
`systemctl --user restart arbiter` when the systemd unit is present, a plain
process bounce otherwise. The restart's boot sequence (`Boot.Migrator`)
applies any pending migrations before the endpoint opens, so migrations are
never run against the live server. **Do not `git pull` by hand first** — the
command diffs `before_sha`/`after_sha` itself and treats an already-current
tree as "nothing to deploy," skipping the restart and escript rebuild
entirely.

It also does **not** run `mix deps.get` for you. If the pre-check above
printed a `mix.lock` line, the pulled tree needs new deps that the restart
will not have — running `mix deps.get` *before* the pull is a no-op, since
`git fetch` doesn't move `HEAD` and the old lockfile is still checked out.
Instead, either run `mix deps.get && arb server restart` immediately *after*
the deploy, or skip `--git-pull` and do the whole thing manually: `git pull
--ff-only origin main` → `mix deps.get` → `(cd apps/arbiter_cli && mix
escript.build && cp arb ~/.local/bin/arb)` if `apps/arbiter_cli` changed →
`arb server restart` → `arb server doctor`. The manual form is the safer
choice when deps changed, since it never restarts against unfetched deps.

`--git-pull` is the only way to reach this path. A bare `arb server deploy` is
always the release path (below) and never falls back to a `git pull`, whatever
the environment says.

#### Production deploys: OTP-release installs

This subsection only applies once you have a built release artifact
installed (`arb install service`, or manually under
`~/.arbiter/releases/<tag>/`) — **not** to a source checkout; use
[the sequence above](#source-checkout-dev-mode) for that. `~/.arbiter/current`
is symlinked atomically to the active release. Deploy a specific version (or
`latest`) with:

```sh
arb server deploy --version v1.2.3
```

This is the primary path, and the **"Update to vX.Y.Z"** button in the dashboard's update banner runs the same command. The full runbook is [docs/self-update.md](docs/self-update.md).

It resolves the release repo (`ARB_RELEASE_REPO`, else the running server's own release metadata, else the repo your `arb` was built from — and says which), downloads the release tarball + checksum from GitHub Releases, verifies the SHA-256, unpacks it, takes an **integrity-checked online backup of the database** into `~/.arbiter/snapshots/` (aborting if that fails), atomically swaps `current`, restarts the service, and health-checks it. If it doesn't come back green it rolls back to the last-known-good release — and when the new release had migrations, **restores the backup first**. After a green deploy it installs the matching `arb` escript. `arb doctor` reports the last deploy (tag, time, outcome, backup path).

#### Migration ordering, and rollback across a migration

**The deploy does not run migrations.** SQLite allows exactly one writer, so a
`bin/arbiter eval Arbiter.Release.migrate` from the new release while the old
server is still serving would be a second writer racing the live one. Instead
the new release migrates during its **own boot**: `Arbiter.Boot.Migrator` is a
synchronous supervision-tree child that brings the schema to head before
`ArbiterWeb.Endpoint` binds its port, gated on the single-instance advisory
lock so only one node ever migrates. The real ordering is therefore:

    stop the old server  →  new release boots  →  migrate  →  serve

— one writer at every instant, and the same path `arb server restart`,
`arb server migrate` and dev `mix phx.server` already take. The dev-mode
fallback (`arb server deploy --git-pull`) obeys the same ordering: with the
server up it pulls and restarts, and the pulled migrations are applied by that
boot; it only migrates standalone when the server is already down.

**Auto-rollback stops at a schema change.** Re-pointing `current` back at the
prior release after the new one has migrated would run old code against a
schema it has never seen. Before swapping the symlink, the deploy compares the
migrations packaged into the new release tree
(`lib/<app>-<vsn>/priv/repo/migrations`) against those in the release it would
roll back to — a pure filesystem comparison, no database connection. If the new
release adds any:

- it says so up-front, naming them, and notes that automatic rollback is disabled;
- on a health-check failure it **refuses** to roll back, leaves `current` on the
  new release, names the crossed migrations, and exits non-zero with the
  operator's options (fix forward, or roll the schema back first with
  `bin/arbiter eval "Arbiter.Release.rollback(Arbiter.Repo, <version>)"` and then
  `arb server deploy --version <prior> --force`);
- `--allow-cross-migration-rollback` overrides the refusal, rolling back anyway
  with a loud warning that the prior release is now on a newer schema.

A deploy that adds no migrations keeps the automatic rollback unchanged — but
only when detection actually worked. Because an arbiter release always ships
migrations, an *empty* migration set from the new release tree means the globs
no longer match the packaging layout, not that the deploy is migration-free.
That case fails closed: the deploy warns up-front, refuses the automatic
rollback the same way a crossed migration does, and reports
`migrations_detected: false` in `--json` so the empty `crossed_migrations` list
can't be mistaken for "safe". `--allow-cross-migration-rollback` overrides it.

When the refusal comes from a **failed swap** (`/api/version` still reports the
old release) rather than a green-wait timeout, the message says the new
release's migrations *may* have been applied rather than claiming they were —
a release that never booted never ran its boot migrator.

### Server bind address (`ARB_BIND_ADDRESS`)

The dashboard's auth model is "a loopback peer is trusted; there is no login" —
LiveView pages, including a terminal into every worker session, have no
credential check beyond "did this request come from the same box". Because of
that, **the server binds to `127.0.0.1:4848` by default** in both dev and
prod/release, in dev and runtime config alike.

**Upgrade note:** before this change, the default was `0.0.0.0`
(dev)/`[::]` (prod) — reachable from the LAN, or the internet on a cloud host
with a permissive security group. An install that relied on that for remote
access will stop being reachable after upgrading. Use an SSH port-forward
instead (`ssh -L 4848:127.0.0.1:4848 <host>`), which needs no server-side
change; or, if off-loopback really is required, set `ARB_BIND_ADDRESS`
explicitly (below) — `arb server doctor` will keep warning about it every time
as a reminder of the exposure.

To bind elsewhere, set `ARB_BIND_ADDRESS` to any address `:inet.parse_address/1`
accepts (e.g. `0.0.0.0`, `::`, a specific interface IP):

```sh
echo "ARB_BIND_ADDRESS=0.0.0.0" >> ~/.arbiter/arbiter.env
```

Any non-loopback value logs a boot `WARNING` naming the exposure, and
`arb server doctor` reports a `[warn]` check pointing back here.

### Reading `arb server doctor`

Every check has one of four severities:

| Severity | Meaning | Exit code |
|---|---|---|
| `ok` | healthy | 0 |
| `warn` | should be fixed, nothing is broken: a policy advisory (account/workspace quota policy), a scheduler that is not at a safe restart point, a failed last deploy, an off-loopback bind, a deprecated setting, **or a check that could not run** (`could not check: <reason>` — an unreachable, erroring or older server is never read as healthy) | 0 |
| `fail` | broken now: server unreachable, migrations pending, CLI/server version mismatch, no workspace or repo, an enabled provider's credential unusable, an open `/api`, a `:strict` workspace the host cannot jail, a podman backend the host cannot run | **1** |
| `n/a` | does not apply to this install, so it is not probed: a provider no workspace uses (or that is paused), podman when no workspace uses it, the egress jail when no workspace enforces an allowlist, no nodes enrolled | 0 |

`arb server doctor --json` lists **every** check (n/a included) with `id`, `group`
and `severity`, plus `result` (`ok`/`warn`/`fail`), `exit_code` and `summary`;
`ok` is false exactly when the exit code is 1, so a script can use either. The
default output is the header, the summary line and the warn/fail checks only;
`--all` (alias `-v`) groups everything under core, auth & providers, sandboxes
(the agy jail's six sub-checks collapse to one line while they pass) and
security posture. Which providers and sandbox backends an install uses comes
from `GET /api/server/doctor_scope`; when that cannot be read, nothing is hidden.

#### The spawn canary (`arb server doctor --spawn`)

The static checks cannot prove the thing that matters after a deploy: that a
worker can actually spawn and reach its agent (on 2026-10-04 a release deployed
with the doctor all-ok while every spawn raised in `RunTmp.create`, and every agy
reviewer exited 125 on the jail's `sun_path` limit). The `spawn` check asks the
server (`POST /api/server/spawn_canary`) to run a **canary spawn** per enabled,
unpaused provider through the real spawn pipeline: the per-run temp dir, the
adapter's own argv (agy's jail wrapper, config isolation, Claude's MCP config), the
workspace env and provider-account credential handoff, `SpawnEnv`, the memory
scope and the same `Port` open. The only difference is that the CLI is asked for
`--version`, so **no model tokens are spent**. It creates no ticket, run record,
board card or `usage_events` row, occupies no scheduler slot and counts against no
quota, and it removes its temp dirs, scope, agent process and isolated agent home.

Each provider row says whether it spawned and reached the agent, with the exit
code and duration; a failure prints the first line the spawn printed
(`exit 125: bwrap: …`, or `FunctionClauseError: …`) and, being a `fail`, makes the
doctor exit 1. A provider no workspace uses, or that is paused, is `n/a` and is not
spawned; one whose workspace uses the podman backend is `n/a` too (a canary has no
worktree to mount: see the podman readiness check).

- `arb server doctor --spawn` runs a fresh canary and prints its rows.
- A plain `arb server doctor` runs it **automatically the first time after the
  server boots** (so the first doctor after a deploy proves the new build spawns),
  keeps that result for the rest of the boot, and re-runs it while it is failing so
  a fix shows up at once. `arb server deploy`'s final report does the same.
- The readiness polls (`arb start`, `restart`, `server deploy`'s green-wait) do not
  spawn agents; a spawn failure is a `fail` in the report but does not trigger the
  deploy's auto-rollback.
- One canary runs at a time: a concurrent call is a 409 (reported as a `warn`). The
  endpoint is coordinator tier; a worker token is refused.

### Remote `arb` — access Arbiter over VPN

By default, `arb` talks to a local server on `http://127.0.0.1:4848` (loopback). To point `arb` at a remote Arbiter server:

1. **Set `ARB_HOST`** to your server's URL over VPN:

   ```sh
   export ARB_HOST="http://arbiter.internal.example.com"
   # or export ARB_HOST="https://arbiter.example.com" for HTTPS
   ```

2. **Mint a token** on the server, in a shell on the server host (for
   example `ssh <host> arb mcp token mint --tier coordinator`):

   ```sh
   arb mcp token mint --tier coordinator
   ```

3. **Export the token** on the client:

   ```sh
   export ARB_TOKEN="<token-from-step-2>"
   ```

4. **Verify the connection**:

   ```sh
   arb prime
   ```

- **Local loopback** (`ARB_HOST` unset or `http://127.0.0.1:4848`) needs no `ARB_TOKEN` from your own shell: `arb` mints a short-lived token over the operator socket for each invocation (bd-asawcq). The server itself no longer exempts localhost; a bare `curl` to `/api` gets 401.
- **Remote access** requires both `ARB_HOST` and `ARB_TOKEN`, *and* the server
  must be reachable at that address in the first place — since the server now
  binds loopback-only by default (above), that means either `ARB_BIND_ADDRESS`
  set server-side, or reaching it through an SSH port-forward / VPN tunnel that
  terminates on `127.0.0.1` locally. The API's own token check is unaffected
  either way; only the dashboard's login-free LiveView pages are the reason to
  prefer a tunnel over a raw `ARB_BIND_ADDRESS` override.

### Encryption key (`ARBITER_CLOAK_KEY`) — required

Arbiter encrypts workspace secrets (tracker / merger credentials) at rest using
AES-256-GCM via [`ash_cloak`](https://hex.pm/packages/ash_cloak). **The server
refuses to start without an encryption key.** Generate a 32-byte Base64 key and
add it to your environment before deploying:

```sh
echo "ARBITER_CLOAK_KEY=$(openssl rand -base64 32)" >> ~/.arbiter/arbiter.env
# (for a non-service run, put it in the project-root .arbiter.env or export it)
```

`arb install service` forwards `ARBITER_CLOAK_KEY` from the installing shell
into `~/.arbiter/arbiter.env` automatically if it is set. Treat this key like a
database password: back it up and keep it stable — rotating it (re-encrypting
existing secrets) is a separate runbook and is not yet automated. Losing it
makes existing encrypted secrets unrecoverable.

### Claude CLI authentication (`CLAUDE_CODE_OAUTH_TOKEN`) — required

Real worker spawns and the `CredentialWatchdog`'s health probe both authenticate
the `claude` CLI via `Arbiter.Agents.Claude.spawn_env/1`, and a Claude worker
needs a credential of its own: a setup token (`claude setup-token`) or an
`ANTHROPIC_API_KEY`. Arbiter **never** copies your own
`~/.claude/.credentials.json` into a worker — Claude rotates that login's refresh
token on every refresh, so a second holder locks one of you out. A Claude
dispatch for a workspace with no credential is refused and held (its tickets stay
Ready), the coordinator gets one escalation naming the fix, and
`arb server doctor`'s "claude worker credentials" check lists every such
workspace. The supported path is
**provider accounts** — a `provider_accounts` row, joined to a workspace via
`workspace_provider_accounts`, holding an active `provider_credentials` row for
`CLAUDE_CODE_OAUTH_TOKEN` (`docs/provider-account-design.md`) — and since the
P13 flip it is the only one. A spawn with a workspace takes its account's
credential; a workspace-less spawn such as the Watchdog probe takes the
install's single enabled Claude account credential. A token in a workspace's
`worker_env` or in the server's own environment (`.arbiter.env`) is **not**
read. `spawn_env/1` exports the token under its own literal name (never
remapped to `ANTHROPIC_API_KEY` — the two are not interchangeable to the CLI),
and emits an explicit unset when there is none, so a server-env value can
never leak into a worker.

**Migrating an install that still keeps its token in `worker_env` or
`.arbiter.env`:** `mix arbiter.accounts.census` only ever sees credentials
already stored in a workspace's `worker_env` (`docs/provider-account-design.md`
§7.1) — it has no visibility into the arbiter server's own process
environment, so a token that has only ever lived in `.arbiter.env` will not
appear in the census output at all. Migrate **before** upgrading to the P13
release, which requires provider accounts:

1. Set the token as a `worker_env` value (`CLAUDE_CODE_OAUTH_TOKEN`) on at
   least one workspace via the dashboard's workspace environment editor, so
   `mix arbiter.accounts.census` has something to fingerprint.
2. Run `mix arbiter.accounts.census` (optionally with
   `--operator-credential ~/.claude/.credentials.json`), edit the resulting
   plan to merge/name the candidate account, then apply it with
   `mix arbiter.accounts.migrate --plan accounts.json`, and restart.
3. Remove `CLAUDE_CODE_OAUTH_TOKEN` (and any `ARBITER_PROVIDER_ACCOUNTS` line)
   from `.arbiter.env` / the service unit — nothing reads them, and a stale
   credential lying around in a secrets file is its own risk.

On a **release install** (no Mix), the same census, migrate and rollback steps
run as `bin/arbiter eval 'Arbiter.Release.accounts_census(...)'`,
`accounts_migrate/1` and `accounts_rollback/1`.
[`docs/provider-accounts-release-runbook.md`](docs/provider-accounts-release-runbook.md)
is the step-by-step procedure (census, dry run, migrate, restart, verify), the
P13 release notes, and the rollback.

#### Account-model path

You can also manage provider accounts directly via the `arb account` CLI
instead of (or alongside) the census/migrate flow above:

```sh
# Create or reference a provider account
arb account create claude my_account

# Attach it to a workspace
arb account attach <workspace> claude my_account

# Install or rotate the credential
arb account rotate claude:my_account --kind oauth_token --env-var CLAUDE_CODE_OAUTH_TOKEN --secret <your-long-ttl-token>
```

This path is particularly useful if you have **multiple Claude credentials**
(e.g., for different Anthropic accounts or organizations) and want to route
different workspaces to different accounts — the account model lets each
workspace reference its own account identity directly, without duplicating
tokens across workspaces or relying on install-wide environment fallbacks.

**Precedence when both are set:** a spawn can end up with both
`CLAUDE_CODE_OAUTH_TOKEN` (the account's) and `ANTHROPIC_API_KEY` (workspace
`credentials_ref`/`api_keys` rotation) in its environment at once. Which one
the `claude` CLI honours is decided by the CLI itself, not by Arbiter — if it
prefers the OAuth token, a workspace that deliberately configured its own key
would silently authenticate against the account credential instead. If a
workspace's `ANTHROPIC_API_KEY` must win, verify the CLI's actual precedence
before relying on it, or leave that workspace's Claude account without a
setup token.

**Redaction:** `Arbiter.Worker.ClaudeSession.start/1` adds
`CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` values to the session's
redaction list alongside the workspace's secret-flagged `worker_env` values —
both the values carried in the spawn's explicit `:env` (the Dispatch/
ReviewGate path) and, for the `start/1` callers that pass no `:env` at all
(the conflict-resolver and CI fix-pass workers, which still inherit the
install-wide OS environment via `Port.open`'s `{:env, …}` extension
semantics), the value read directly from the OS environment. So the token is
scrubbed from worker output (`worker_runs.output_lines`, the live dashboard
stream, the durable output log) across all `ClaudeSession.start/1` callers,
even after the per-workspace `worker_env` copies are removed.

### Storing tracker / merger credentials in the database

Instead of pointing `credentials_ref` at an environment variable
(`credentials_ref: "env:SHORTCUT_API_TOKEN"`), you can store the token directly
on the workspace, encrypted at rest, and reference it with a `secret:` ref. This
needs no server-side env var and no restart:

```sh
# 1. store the encrypted secret on the workspace
arb workspace secret set tracker_token sct_rw_...

# 2. point the tracker config at it
arb config set tracker.config.credentials_ref secret:tracker_token

# inspect / remove (values are never shown — only key names)
arb workspace secret ls
arb workspace secret rm tracker_token
```

Existing `env:` refs keep working unchanged, so you can migrate one workspace at
a time. Secret **values** are never returned by the API or CLI — only the key
names are listed.

Env vars injected into every worker's subprocess are managed the same way
(`arb workspace env ls|set|rm`; `--secret` encrypts and redacts the value, and
the value comes from `-` (stdin) or `--file` so it stays off `ps`). `ls` shows
names and secret flags only; revealing a value is browser-only.

## Initialize your coordinator session

A **coordinator** is a dedicated Claude Code session that directs work across
a workspace — creating and dispatching tickets, reviewing worker output, and
resolving escalations — typically via the MCP tools above. It has its own
working directory with persistent memory and a notes folder.

```sh
mkdir ~/coordinator && cd ~/coordinator
arb init         # initializes the current directory
```

Or pass a path to initialize elsewhere:

```sh
arb init ~/my-coordinator
cd ~/my-coordinator
```

Then open Claude Code:

```sh
claude
```

The coordinator session will check whether the server is running, start it if
needed, orient itself with `arb prime`, and be ready to coordinate your work.

## Adding repos (projects)

A **repo** is a local git repository that workers check out and work in. Register your projects via the dashboard (Workspace → Repos), or directly in `config/dev.exs`:

```elixir
config :arbiter, :repo_paths, %{
  "my-project" => Path.expand("~/dev/my-project"),
  "another-project" => Path.expand("~/dev/another-project")
}
```

After editing `config/dev.exs`, restart the server for changes to take effect.

## CLI Reference

The CLI uses an `arb <resource> <verb>` grammar: `arb [resource] verb [args]`.
Run `arb help` (or `arb --help`) for the exhaustive, always-current usage text
(`apps/arbiter_cli/lib/arbiter_cli/main.ex`); the table below covers the
commands you'll reach for most.

### Key commands

| Command | Purpose |
|---------|---------|
| `arb prime` | Mission briefing — run at session start to check workspace status |
| `arb ticket list` | List tickets in the workspace |
| `arb ticket show <id>` | View a ticket's details and history |
| `arb ticket create <title>` | Create a new ticket |
| `arb ticket dispatch <id> [repo]` | Dispatch a worker to work on a ticket |
| `arb worker list` | List running and completed workers |
| `arb worker log <task-id>` | Read a worker's full transcript (durable) |
| `arb worker review <task-id>` | Dispatch a review-only worker against a ticket |
| `arb message inbox` | Read (and mark read) the coordinator's escalation mailbox |
| `arb server start` | Boot the stack (no-op if already up) |
| `arb server deploy [--version vX.Y.Z]` | Deploy an OTP release from GitHub Releases: pre-swap DB backup, auto-rollback on failure (restoring the backup when it migrated), then installs the matching `arb` — see [docs/self-update.md](docs/self-update.md) |
| `arb server deploy --git-pull` | Source-checkout deploy: `git pull --ff-only`, rebuild the CLI if changed, restart (see [Deploying](#deploying-pick-the-path-for-your-install-shape)) |
| `arb server doctor [--all\|-v] [--spawn] [--json]` | Health-check the install: a header, one summary line (`27 ok · 1 warn · 0 fail`) and only the `warn`/`fail` checks with their hints. `--all` lists every check grouped (core, auth & providers, sandboxes, security posture), with `n/a` for the ones that do not apply here. `--spawn` runs the end-to-end canary spawn per enabled provider (also run automatically once per server boot). Exit 1 only on `fail`; `--json` carries every check with its severity — see [Reading `arb server doctor`](#reading-arb-server-doctor) |
| `arb config get/set [workspace]` | Read/edit workspace configuration (tracker, merger, etc.) |
| `arb mcp token mint --tier coordinator` | Mint an MCP token for a coordinator session |

All commands accept `--help` and `--json` for structured output. Pre-`<resource> <verb>`
flat commands from earlier CLI versions (`arb list`, `arb start`, `arb doctor`, …) still
run — they print a one-line note pointing at the new form. (`arb dispatch <id>` is a
permanent top-level shortcut for `arb ticket dispatch <id>`, not a legacy alias.)

## Documentation

Architecture and design decision records live in [`docs/`](docs/):

- [Licensing Model & Open-Core Architecture](docs/licensing-model.md) — Core vs. Pro distribution, license choices, CLA requirements, and extension seams.
- [Core/Pro Extension Seams](docs/pro-extension-seams.md) — Inventory and gap analysis of core/Pro extension seams.
- [Pluggable Agent Harness Design](docs/agent-harness-design.md) — Pluggable agent adapters and routing policies.
- [MCP Server Design](docs/mcp-server-design.md) — Streamable HTTP MCP server architecture.
- [Quota and Auth Posture](docs/quota-and-auth.md) — Provider quota management and credential lifecycle.
- [Worker Security Policy](docs/worker-security.md) — Execution sandbox and security isolation for agent workers.
- [Remote Access](docs/remote-access.md) — Connecting to dashboard and sessions over SSH tunnels.
- [Remote Workers Runbook](docs/remote-workers-runbook.md) — Joining, operating and debugging remote worker nodes.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for local
development commands and contribution guidelines. Before a pull request can be
merged, it must be signed off under the [Contributor License Agreement
(CLA.md)](CLA.md). Found a security issue? See [`SECURITY.md`](SECURITY.md)
for how to report it privately.

## License

Arbiter is licensed under the [Apache License, Version 2.0](LICENSE). Third-party
dependencies and their licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Arbiter follows an open-core model: future commercially-licensed components ship
as separate packages and are not covered by this repository's license. See
[Licensing Model & Open-Core Architecture](docs/licensing-model.md) for details.

