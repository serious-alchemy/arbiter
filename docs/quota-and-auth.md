# Quota & Auth Posture

**bd-2jgs2h, 2026-09-18.** Documents how the fleet detects and bounds a dead
credential — and, just as importantly, how it deliberately no longer tries to
predict one.

## Dispatch no longer pre-checks auth

Through 2026-06-05 → 2026-09-18, every real dispatch and every resume paid a
model turn to run a live CLI probe (`Arbiter.Worker.Dispatch.run_preflight/2`,
`Arbiter.Agents.Preflight.check/2`) before spawning the actual worker, purely
to ask "are you logged in?" ahead of time.

The operator retired that probe on 2026-09-18. The evidence, measured from the
live DB and the code on that date:

- **10 auth-failed worker runs in 90 days** (`worker_runs.failure_reason like
  '%authenticate%'`). Half of them died **mid-run**, a shape no pre-flight
  probe — which only ever runs before spawn — could ever have caught. Pre-flight
  had been live the whole 90 days.
- **~760 probes/day** against those 10 failures in 90 days: claude 374/day
  ($4.59/day), codex 319/day (cost not billed to us but still a real request),
  gemini 26/day. Over 7 days: claude 1,762 probes / **$23.27**, codex 1,544,
  gemini 1,257 — about 4,500 billed model turns a week spent asking a question
  a dead credential answers for free.
- **Failing fast is cheap.** Across the auth-failed runs, credentials dead at
  spawn made the CLI exit in **3-5s**; the mid-run deaths took 374-717s and,
  again, were never reachable by a pre-flight probe either way.
- **A rejected request bills nothing at the provider.** The probe does.

So the policy inverted: **dispatch, and react to the provider's own error
instead of paying to guess beforehand.** `Arbiter.Worker.Dispatch.dispatch/2`
still runs a guard ahead of every real-agent dispatch
(`Arbiter.Worker.Dispatch.maybe_preflight/2`), but that guard is now a plain,
free state lookup — `Arbiter.Agents.CredentialWatchdog.expired?/1` — never a
live CLI call. Opt out entirely with `preflight: false`; the guard is also
skipped whenever `start_claude: false` (no real agent about to spawn).

## What bounds a wave of identical failures

Without *something* refusing dispatch once a credential is known-dead, a
single expired token burns the queue at the fleet's normal dispatch rate:
each failed worker frees its slot, the next Ready card promotes, and it
fails again — each pass leaving a failed run and an escalation behind it.

Since bd-21bmdh that bound is an explicit **auth hold**
(`Arbiter.Agents.AuthHold`), and a single auth death is a *retry* rather than
a stranded task:

1. `Arbiter.Worker.fail_stopped/2` classifies a dying worker's stop reason. If
   it comes back `:auth_expired`, it records the death on the provider's
   `AuthHold` streak and escalates the stopped worker as before.
2. `Arbiter.Worker.AuthDeath` (called by the Driver) then **returns the task
   to Ready**: it removes the worktree and branch if the worker never
   committed (a dirty worktree or one with commits is kept), stops the
   `:failed` worker process (its `worker_runs` row stays `:failed`), and puts
   the ticket back in the queue (the `requeue` transition, `:active` or
   `:merging` → `:queued`). Not for review-only engagements or resume /
   fix-round workers, and not once a task has died on auth
   `max_task_reopens` times (default 3) — those keep the old stay-In-progress
   behaviour. Every other failure shape is unchanged.
3. **N consecutive auth deaths on a provider (default 2) open the hold.**
   "Consecutive" means no worker completed on that provider in between. The
   hold marks `CredentialWatchdog` expired for the adapter, which escalates
   once to every workspace and flips `credentials_expired` on the quota
   surfaces.
4. While the hold is open:
   - `Arbiter.Worker.Dispatch`'s guard refuses every agent dispatch and
     resume for the provider — before the task transitions, before a
     worktree is provisioned, before a worker registers. The guard's read is
     **fail-closed**: an unreadable hold refuses too.
   - The board shows `blocked — <provider> auth hold (N consecutive auth
     deaths)` as its board-wide hold (`Arbiter.Board.Snapshot.quota_hold/1`)
     for a workspace whose default provider is held, so
     `Arbiter.Board.Autopilot` does not even attempt the dispatch. The
     reopened tasks sit in Ready.
5. The refusal escalates to the coordinator (once — behind
   `Arbiter.CircuitBreaker`, not once per retry) with a re-authenticate
   remediation.

None of this requires a live probe. It is pure state held in the `AuthHold`
and `CredentialWatchdog` GenServers and served for free to every dispatch.

### Resetting the hold

Only a positive signal clears an open hold:

- **A free credential check passing.** `Arbiter.Quota.CloudProbe`'s usage
  polls (Claude `/api/oauth/usage`, Codex's usage GET, agy `/usage`) call
  `CredentialWatchdog.mark_recovered/2` + `AuthHold.recovered/2` on a
  passing check whenever the provider's hold is open.
- **The watchdog's recovery signal.** Any `CredentialWatchdog` recovery
  (its periodic probe passing, or `mark_recovered/2`) forwards to
  `AuthHold.recovered/2`.
- **An operator.** `arb breaker reset --auth-hold claude` (or MCP
  `breaker_reset` with `provider`, or `POST /api/breakers/reset` with
  `provider`). `arb breaker list` / `breaker_list` show every hold under
  `auth_holds`.

An automatic recovery leaves the provider on *probation*: the next auth
death re-opens the hold immediately rather than after another N. The free
checks read the operator's host credentials, which are not always the ones a
worker spawns with, so "free check passes" and "workers still die" can both
be true; probation bounds that case to one death per recovery signal, and
`max_task_reopens` bounds it per task. A completed worker on the provider
ends probation; an operator reset is a full reset.

Configuration: `config :arbiter, :auth_hold, threshold: 2, max_task_reopens: 3`.
State is in-memory; a restart clears it, costing at most N more fast deaths.

## The periodic probe is now optional, and "off" is a supported posture

`CredentialWatchdog` still *can* run its own periodic CLI probe
(`:adapters`, runtime-settable via `Arbiter.Settings`) to catch expiry that no
worker ever surfaced organically, and to auto-recover an adapter once
credentials are restored. That's a separate, much lower-frequency cost center
than the old per-dispatch probe — and it's fully independent of the
dispatch guard above, which works off held state regardless of whether
anything is probing to refresh it.

Setting `:adapters` to `[]` (the operator already did this for `gemini`,
cutting it from ~180 probes/day to 26) is a **supported, intentional
posture**, not an accident to route around:

- `expired?/1`, `mark_expired/2`, `mark_recovered/2` and the dispatch guard
  all keep working exactly as before — they're state operations, not probe
  operations.
- Nothing will *clear* an expiry mark on its own once nothing probes that
  adapter. Recovery then comes from an independent success signal instead —
  `Arbiter.Quota.CloudProbe`'s consecutive-401 tracking calls
  `mark_recovered/2` on a successful `/api/oauth/usage` poll for Claude — or
  an operator running `CredentialWatchdog.reset/1`.
- `quota_get.credentials_expired` (`Arbiter.Quota.serialize/1`) reflects the
  same held state either way, so the dashboard's expiry signal doesn't
  depend on probing being on.

See `Arbiter.Agents.CredentialWatchdog`'s moduledoc for the exact
configuration resolution order and the adapter-list semantics.

## The probe that survived is bounded (bd-svczq4)

**2026-09-18.** What the Watchdog still runs used to be unbounded, and it had
already refused a valid `--provider gemini` dispatch once, with a diagnosis
that was factually wrong: *"agent produced no output within the watchdog
window (possible hang)."* Nothing had hung. The probe authenticated, made 21
model calls and answered in 102s — against a hard-coded 30s watchdog, and with
the child left running for another 72s after Arbiter gave up on it. Two
earlier probes the same day finished in 16s and 17s. The gate was a coin flip.

The cause was that a one-word prompt is not a cheap round-trip to an agentic
CLI: the gemini probe ran a full turn, tools enabled, `toolPermission:
always-proceed`, rooted in whatever directory the BEAM was in (on this host,
the live checkout Phoenix hot-reloads from), carrying an Arbiter-worker
`GEMINI.md`. It read `ping` as a task.

The probe is now bounded on five axes:

| | before | now |
|---|---|---|
| agy's own turn budget | its 5-minute default | `--print-timeout` at 80% of the harness watchdog, so agy yields first and a real exit status is always observed |
| structured output | plain text (bd-481sz7 fixed this) | `--output-format stream-json`, parseable and ledgerable |
| working directory | the BEAM's cwd — the live checkout | `Arbiter.Agents.Preflight.probe_cwd/0`, an empty dir under the system temp dir |
| a timed-out child | survived; `Port.close/1` does not reap it | whole process tree SIGKILLed (`Arbiter.Worker.OsProcess.kill_tree/1`) |
| the watchdog itself | one hard-coded 30s module attribute | per adapter and configurable; gemini's built-in default is 120s, above its observed cold-start floor |

```elixir
config :arbiter, Arbiter.Agents.Preflight,
  timeout_ms: 30_000,                              # install-wide default
  timeout_ms_by_provider: %{"gemini" => 120_000},  # per adapter, wins over the above
  on_timeout: :proceed                             # :proceed (default) | :refuse
```

**A probe timeout is advisory, not a credential verdict.** It is the one
outcome that says nothing about the credentials, so `check/2` answers a
timeout with `{:warn, reason}` — distinct from `{:error, reason}` — and the
Watchdog logs it and leaves the adapter's state exactly as it was. A slow
probe neither marks an adapter expired (which would refuse every dispatch
fleet-wide) nor clears a mark a dying worker just set. `on_timeout: :refuse`
turns it back into a recorded `{:error, _}`; note that even then its category
is `:preflight_timeout`, not `:auth_expired`, so it is a logged non-auth probe
failure rather than a fleet-wide refusal.

That category also exists so the diagnosis stops lying. `:preflight_timeout`
reports the elapsed time, the watchdog that fired and whether any output had
arrived, and its remediation names the probe's own config instead of sending
the operator to a worker transcript that does not exist. The `:stalled`
category it used to borrow no longer claims "produced no output" when output
did in fact arrive — that branch keyed on `exit_status == nil` alone.

### The CLI's own result is the verdict

Bounding the probe surfaced a second, sharper defect. Measured live on
2026-09-18 with the bounded argv above: agy answered `ping` with a **14-step
agentic turn** — 7 `run_command` calls, ~71K input tokens, 31.9s — because the
Arbiter-worker `GEMINI.md` in its isolated `$HOME` tells it it is a worker with
a task. One of those commands was `arb prime`. The backlog it printed contained
a task titled *"Auth pre-flight P2: free expiry signals for codex and agy —
generalise the 401-shaped detection"*, and Arbiter's line-scraping classifier
read that text as proof its own credentials had expired. On a probe that
authenticated fine and exited 0.

From the `CredentialWatchdog` an `:auth_expired` verdict marks the adapter dead
and refuses **every** dispatch for it, fleet-wide, until an operator resets it.
So: a clean exit plus a successful structured result object is now conclusive,
and the surrounding lines are not re-scanned. They are the agent's work product,
not a diagnostic about our credentials. A CLI that reports its own failure
(Claude's `is_error`, agy's non-SUCCESS `status`), or that prints an auth error
and exits 0 with no result object, still falls through to the classifier.

What is *not* fixed: the probe is still an agentic turn. The neutral cwd means
it has no repo to wander into, and it no longer runs per dispatch, so what
remains is cost and noise on the Watchdog's poll rather than a correctness
problem. Making the probe non-agentic (a deny-all tool posture, or dropping the
model round-trip entirely) is follow-up work.

## Claude: auth status and usage over the control channel (bd-a2zrh0)

The Claude pre-flight used to be one billed `claude --print ping` turn, and the
quota poll rode `/api/oauth/usage` with whatever access token sat in a
`.credentials.json` — a token that only refreshes while an interactive `claude`
session runs. `Arbiter.Agents.Claude.ControlChannel` replaces both *when it can*
by driving the CLI in SDK mode:

    claude -p --input-format stream-json --output-format stream-json --verbose

and writing one JSON `control_request` per stdin line (`initialize`, then
`get_usage`). Neither request is a model turn, so neither spends quota.

| Consumer | Control channel | Used when |
|---|---|---|
| `Claude.auth_probe/1` (→ `Preflight`, `CredentialWatchdog`) | `initialize` → `account.tokenSource`, then `get_usage` | `tokenSource: "none"` → `:auth_expired`; `get_usage` succeeds → `:ok`; `get_usage` auth error → `:auth_expired` |
| `Quota.capture_oauth_usage/2` (→ `CloudProbe`) | `get_usage`, with `CLAUDE_CONFIG_DIR` = the quota grant's dir | the account has a quota grant (`:cli_credentials_path`) or falls back to the operator login |

**`initialize` alone is never an `:ok`.** It names the token's *source*, not its
validity — an expired OAuth token still reads as authenticated there. Only
`get_usage`, which exercises the token against the API, upgrades the verdict.

### Real response shapes (claude 2.1.317) and how to see which path ran

The first release of this surface assumed shapes the real CLI does not send.
A 2026-11-03 probe of claude 2.1.317 (operator login) showed:

* `initialize` succeeds but `account` has **no `tokenSource`** — only identity
  (`email`, `organization`, `subscriptionType`). `ControlChannel.auth_state/1`
  now reads `tokenSource: "none"` → `:unauthenticated`, a `tokenSource` string
  **or** any of those identity fields → `:authenticated`, anything else →
  `:unknown` (never "logged out").
* `get_usage` succeeds but the windows sit under **`rate_limits`**, not at the
  top level. `ControlChannel.normalize_usage/1` lifts them to the
  `/api/oauth/usage` shape and also accepts `used_percentage` for
  `utilization` and epoch-seconds `resets_at`. A success body that still has no
  `five_hour` / `seven_day` / `limits` is an error carrying its top-level keys.

The test fixtures in `apps/arbiter/test/fixtures/claude_control/` are
**reconstructed from that report, not a raw capture** (no `claude` binary was
available to the author); replace them with a captured response when one is at
hand.

`capture_source` reads `oauth_poll` whichever path answered, so look at the log
(`info`, visible in production):

* `Quota: usage read via control channel (get_usage)` — the channel answered.
* `Quota: control-channel usage unavailable, using HTTP: <reason>` — it did not
  (`info`: old / silent / erroring CLI).
* The same line at `warning`, `… answered with no usage windows (…top-level
  keys: […])` — the CLI answered with a shape we cannot read: a defect to fix,
  not an expected fallback.

### Stability, version floor, fallback

`get_usage` is an **experimental** control request, and the response shapes are
not a published, versioned contract. So nothing depends on it:

* **Minimum CLI version: `2.1.0`** (`ControlChannel.min_cli_version/0`;
  `config :arbiter, Arbiter.Agents.Claude.ControlChannel, min_cli_version: …`,
  `nil` disables the gate). It is a **conservative floor, not a measured
  one** — the CLI used to develop this was not available to the author, so the
  exact release that introduced `get_usage` is unverified. The floor only saves
  a spawn; the runtime fallback below is what actually protects callers.
* **Older CLIs** (`claude --version` below the floor): the channel is never
  spawned; the `ping` pre-flight and the HTTP quota poll run exactly as before.
* **Unsupported or silent CLIs** — an `error` `control_response`, a CLI that
  exits, no answer within 15s, a missing binary, a `get_usage` body with no
  usage windows — all collapse to `{:unsupported, reason}`. `auth_probe/1`
  returns `:skipped` (so `Preflight` runs `auth_probe_argv/1`, the `ping`) and
  the quota path falls through to `OAuthUsage.fetch/1`, whose 401/429 handling,
  cooldown and paging are unchanged.
* **A non-auth `get_usage` failure** is also a fallback, not a verdict. In
  particular a long-lived setup token (`CLAUDE_CODE_OAUTH_TOKEN`) is
  inference-only and `/api/oauth/usage` refuses it with a 429
  (bd-4ag0nj), so an install whose workers run *only* on setup tokens will
  mostly see the `ping` fallback. The saving applies to installs with a
  usage-capable login.
* Kill switch: `config :arbiter, Arbiter.Agents.Claude.ControlChannel, enabled: false`.
  It is off in `config/test.exs`; tests drive it against a stub CLI
  (`Arbiter.Test.ClaudeControlStub`).

The spawn runs in `Preflight.probe_cwd/0`, never the BEAM's cwd, in a process
that traps exits (a CLI that dies before reading stdin makes its port exit with
`:epipe`, which must not take the poller down), and the process tree is always
killed afterwards.

### Not done here

* **Interrupts.** Workers are one-shot `claude --print` runs, not
  stream-json input sessions, so there is no live control channel to send an
  `interrupt` on; stopping a worker is unchanged. Adopting the channel for
  worker sessions is a separate, larger change.
* **A live CLI check.** The wire format above follows the Claude Agent SDK
  control protocol as described in the t3code research; it is exercised here
  only against a stub. Verify on the arbiter host after deploy (see the PR's
  "Not verifiable pre-merge" note).

## Which providers the dashboard shows (bd-i2gwwn)

The status bar's quota chip and the `/usage` "Rate limits" panel show only the
providers this installation uses. Both read one list —
`ArbiterWeb.LiveHooks.load_quotas/0` → `Arbiter.Quota.Visibility` — so they
can't disagree. A provider is shown iff

    (detected OR forced on) AND NOT forced off AND NOT in Quota.hidden_providers/0

- **Detected** — named by `ProviderSettings.effective/2` for the implementer
  or reviewer role on any workspace: the attached accounts (counted only while
  the account is enabled, not soft-deleted and not merged away), else
  `agent.type` / `review_agent.type`, else the `claude` default an
  unconfigured workspace runs.
- **Not** detection signals: a quota snapshot row (the CloudProbe polls every
  logged-in CLI, used or not), a bare workspace↔account link with no role
  position (the probe's write path provisions one for every snapshot it
  stores), or whether a CLI is on the server's PATH.
- **The override** — two install-wide settings, both unset (auto-detect) by
  default, set with the `installation_config_set` MCP tool (coordinator) and
  read with `installation_config_get`:
  - `quota_providers_shown` — quota provider codes (`claude`, `codex`,
    `antigravity`) to show even if not detected;
  - `quota_providers_hidden` — codes to hide even if detected. Hidden wins
    over shown. `null` clears either.
  A change drops the cached top-bar quota, so it lands on the next page load.
- **Hidden pending parity** — `Arbiter.Quota.hidden_providers/0` (Codex)
  wins over everything, the override included. Showing Codex is deleting it
  from `@hidden_providers` in `apps/arbiter/lib/arbiter/quota.ex`.

A shown provider with no snapshot yet appears as "no data yet" (dashed rings,
a popover line) rather than disappearing. With nothing shown, the chip is
gone and `/usage` says "No providers configured" with a link to the default
workspace's Providers section.

`GET /api/quota`, `arb quota` and the `quota_get` MCP tool are the raw view:
none of this applies to them, and they still report every captured provider.

### The chip

One 36px chip; one 32px object per shown provider — the provider's logo in
the middle of two concentric rings, **inner = the 5h window, outer = the 7d
window** (Antigravity: 5h / weekly; Codex: session / weekly). The arc is
utilisation. The colour is the dispatch gate's pace verdict for that window
(`QuotaHelpers.quota_pace/3`, the same math the bars use): green
(`--arb-live`) on pace, amber (`--arb-attention`) approaching the ceiling, red
(`--arb-fail`) at or over it or in paid overage; neutral `--arb-done` while
sampling. A stale reading (one `agy` couldn't refresh) is neutral and muted;
no data is a dashed track with no arc. The provider hue isn't used — the logo
already names the provider. Each object's `aria-label`/`title` states both
windows' utilisation and status in words.

Antigravity's two bucket groups are both gated, so each of its rings shows the
tighter group for that window (worse verdict, then higher utilisation), named
in the label; the popover shows both groups.

The hairline across each ring is elapsed time, drawn only for fixed-window
providers (Claude, Antigravity). **Codex gets none until parity**: its "5h"
slot is a session reset, not a fixed-duration window, so there is no honest
elapsed fraction to draw — its colour comes from the gate's flat ceilings.

The chip is a disclosure: click, tap, Enter or Space toggles a popover with
each provider's windows as full bars (hairline, percentage, reset or burn-rate
note, and a line when near or over the ceiling); a second click, Escape or a
click/tap anywhere outside closes it. There is no hover-only content, so touch
behaves like a mouse. It shows from `sm` (640px) up — it fits beside the
wordmark, live badge, inbox trigger and theme toggle at `lg` and `xl` with
three providers — and hides below `sm`.
`ArbiterWeb.QuotaTopbarBrowserTest` (`--include browser`) checks the fit for
one, two and three providers and the popover interaction in Chromium.

## grok: a ledger-estimated rolling 24h cap (bd-cwq8b0)

grok's free tier allows about 500K tokens per **rolling 24h** window, cached
tokens counted, and has no safe pollable quota endpoint (calling the billing
endpoint with the session token directly is the ToS grey area bd-73uvlo
flagged). So grok's quota is an estimate, `Arbiter.Quota.GrokLedger`:

  * **Headroom** is the sum of grok `usage_events` (input + cache + output)
    over the trailing 24h against `config :arbiter, :grok_quota, cap_tokens:`
    (default 500_000), projected onto a `Quota.Gate.Snapshot` with window
    `"24h"`. `Quota.latest_for_provider(_, :grok)` serves it, so
    `Quota.Gate` holds grok dispatch (and `Quota.Headroom` ranks it) like any
    other provider. The cap is one xAI account's, so the ledger is not scoped
    per provider account.
  * **A free-usage 429** (`subscription:free-usage-exhausted ... tokens
    (actual/limit): N/M`, in `result.errors[]`) classifies as
    `:quota_exhausted` (`StopReason`, anchored to `grok error:` / `Error:` line
    heads) and the worker fails at once rather than parking 5h for a resume
    grok cannot do. The run's `failure_reason` keeps the `N/M` count; the next
    snapshot treats the part of `N` the ledger did not see (an interactive
    `grok` session) as usage stamped at the 429. The hold therefore lifts when
    the rolling window drains below the gate threshold, at the latest 24h after
    the 429 — never at a fixed time.
  * **Auth failures** (`Not signed in`, `RefreshTokenRejected`, `invalid_grant`)
    classify as `:auth_expired` and count toward the grok `AuthHold`, not a
    quota hold.
  * Each worker's `GROK_HOME/config.toml` sets `[models]
    rate_limit_retry_threshold` (default 2; `rate_limit_retry_threshold:` in the
    same config key) so grok does not spend 15 retries on a spent window.

## A run that stops on its provider's quota is held, not crashed (bd-a6vh2x)

A ticket's own run that ends because the provider says its allowance is spent
classifies as `:quota_exhausted` (`Arbiter.Worker.StopReason`): agy's
`RESOURCE_EXHAUSTED (code 429): Individual quota reached … Resets in 11m34s`,
Claude's session / weekly / model limit, grok's free Grok Build usage limit.
Before, agy's came out as `:rate_limited` and grok's as `:crashed`, both of which
left the ticket waiting on the coordinator. Now `Arbiter.Worker`:

1. **Holds the account** until the reset — the provider's stated reset time,
   else the quota probe's latest reset for the account, else 1 hour — as a timed
   `Arbiter.Providers.Pause` entry (`kind: quota`, `until`). Every router that
   honours a pause (`ProviderRouting`, `ReviewerRouting`, `ProviderPool`,
   `Dispatch`'s pause gate) routes round it with no further wiring; it lifts
   itself at `until`, and `arb provider resume` lifts it early. An operator pause
   on the same target is never displaced or shortened.
2. **Queues a held resume** in the workspace's `DispatchQueue` (`quota_resume:
   true`, `retry_not_before` = the reset). It shows in `arb quota` → Held
   dispatches and as "held — quota" on the board.
3. **Counts nothing and tells nobody**: no `worker_stopped` escalation, no
   `run_crashed` attention (the held item keeps the ticket's attention empty),
   no resume attempt, and the resumed run is not counted against
   `attention.run_crashed_max_resumes`.

The held resume leaves the queue in one of two ways. At the reset, `Dispatch`
turns `quota_resume: true` into `resume_session/2`: the same session continues in
the preserved worktree. Before the reset, if routing can already place the
ticket on another provider (not paused, not quota-gated, allowed by the ticket's
`provider_constraint`), the drain releases it early and the same resume runs
there, briefed from the worktree's git state rather than the foreign session id.
A run with no captured session gets the briefing resume outright.

A stop this cannot hold cleanly (a fix/conflict pass or reviewer, a ticket no
longer In progress, an unknown provider, a reset beyond 8 days, or no queue to
hold in) takes the older path unchanged.

## A dollar spend cap per provider account (bd-a6grlr)

The % quota thresholds bound *subscription* usage. For an account billed per
token there was nothing that said "no more than $20 a week". An account can now
carry a **dollar spend cap**, paced over its window the way the % thresholds
are.

```
arb account set claude:api --spend-cap 20 --spend-window week --spend-mode paced
arb account set claude:api --spend-cap none        # clear it
```

(`account_set` over MCP, `PATCH /api/accounts/:ref` and the Providers edit form
take the same four `quota_config` keys: `spend_cap`, `spend_window`,
`spend_mode`, `spend_metered`.)

**Windows are fixed UTC calendar windows**, not rolling: a day starts 00:00 UTC,
a week starts **Monday 00:00 UTC**, a month on the 1st. The spend counted is the
ledger's for the account since the window opened; the window "resets" when the
next one opens. Default window is `week`, default mode `flat`.

**Only real metered spend counts.** The usage ledger prices every run, but for a
Claude Max subscription that price is notional, and agy / Codex / Grok free tiers
carry none. An account's spend counts only when it is *metered*:
`spend_metered: true|false` says so explicitly; unset, it is metered exactly
when it has an active `api_key` credential. A NULL `cost_usd` never counts. A cap
on a non-metered account is accepted and reported as "no metered spend" - it
never holds anything.

**Paced like the percentages.** `flat` allows the whole cap at any time; `paced`
allows `cap x elapsed fraction of the window` by now. The dollar window goes
through `Gate.pace/6` (the `:spend` window, `utilization = spend / cap`), so there
is one definition of the line (`Arbiter.Quota.Pace`) for % and $ windows. The
planning margin (design O8) and the strict / look-ahead setting (design O1) are
design proposals that are not in the gate yet; when they land in `Gate.pace/6`
the spend window inherits them. Until then the line is strict: a fresh dispatch
is held the moment spend is at or past the line.

**Admission counts settled spend plus what is in flight.** Under the same
per-account lock as the concurrency cap (`Arbiter.Accounts.Admission`), a fresh
dispatch is checked against the settled ledger spend plus, for every worker or
admitted dispatch holding a slot on the account, the rest of its ticket's
estimated cost (`Usage.Estimate` median less what the ticket has already spent).
The admission reserves the slot, so a burst of fresh dispatches each sees the
earlier ones and cannot overshoot.

**In-flight tickets may finish (this is deliberately not a hard zero).** Reaching
the cap or the paced line holds only *fresh* dispatches - a ticket being started.
Follow-ups on a ticket already started still run: ReviewGate reviewers and fix
rounds, fix and conflict passes, resumes and re-dispatches of an In progress
ticket. This is the O2 reading in `docs/design/provider-dynamic-concurrency.md`:
follow-ups are held only by the hard rules (a provider refusing requests), and a
spend cap is a scheduling rule. The account can therefore end a window somewhat
past its cap, by at most the remaining cost of work already under way. An
operator's `force_quota` dispatch also goes past the cap, recorded as for any
quota bypass.

**What a hold looks like.** A held fresh dispatch is queued in the workspace's
`DispatchQueue` like a quota hold (`{:quota_held, id}` to every caller), with the
reason `spend cap $20.00/week reached ($21.40 spent), resets 2026-10-19 00:00 UTC`
or `spend pace: $12.00 of $10.00 allowed by now (...)`. It wakes at the window
reset (flat) or the moment the paced line reaches the spend (paced), and the
drain re-checks the cap before it replays. Routing treats a capped-out account
as `quota_held` for a fresh implementer, so a ticket goes to another account when
one has room. The same reason shows in `arb account show`, `arb quota` /
`quota_get` (`spend_caps`), `arb scheduler status` (the board-wide hold) and the
Providers page.

**Paging.** `Arbiter.Quota.SpendWatch` raises an operator system alert
(`spend_cap`) when metered spend (plus the in-flight estimate) reaches 80% of the
cap and another when the cap is reached; each clears itself when the window
resets or the cap is raised or removed.

When the dynamic-concurrency design lands (`provider-dynamic-concurrency.md`,
DC3), the spend cap becomes a window in `Quota.Budget` that holds fresh seats
only.

## Out of scope here

Two follow-ups were filed instead of folded in:

- Free (non-billed) expiry signals for codex/agy, so those adapters get the
  same organic detection Claude gets from the usage-poll 401 tracking.
- Whether an auth-shaped pre-flight hold (mirroring the existing
  `:quota_exhausted` hold in `Arbiter.Worker.PreflightHold`) is worth
  reintroducing now that pre-flight itself is gone. (Done in bd-21bmdh as
  `Arbiter.Agents.AuthHold` — see "What bounds a wave" above.)

A quota-exhausted live-probe signal (the other thing the old pre-flight probe
used to produce, consumed by `Arbiter.Worker.PreflightHold`,
`Arbiter.Board.Autopilot`'s retry hold and `Arbiter.Workflows.DispatchQueue`'s
held-intent backoff) no longer arrives from pre-flight either, for the same
reason: producing it required the same live probe this change removes. Those
call sites are unchanged and harmless — `PreflightHold.retry_not_before/3`
simply never receives a `:quota_exhausted` shape from this path anymore — but
a quota-exhausted dispatch will now be discovered the same way an auth
failure is: by the provider's own rejection once dispatched, not pre-guessed.

## Claude has no 5h window (5H C10, bd-138qku)

Anthropic retired the 5h window. A Claude snapshot now carries no primary
window (`Gate.Snapshot.window_label` is `nil`) and the **7d window is the
gate**. Primary-class keys (those that only govern a provider's 5h/session
window) are therefore inert for Claude accounts. They are still accepted and
stored exactly as before — no migration, existing configs validate unchanged —
and Codex and Antigravity, which keep a real primary window, still honour them.

On boot, `Arbiter.Quota.PrimaryKeyDeprecation` logs **one** warning listing any
primary-class key set on a Claude account's `quota_config`, in a workspace's
`config["quota"]`, or overridden in the `:quota` app env.

| Key | Window | Claude | Codex / Antigravity |
| --- | --- | --- | --- |
| `throttle_threshold` | primary (5h/session) | **inert** (warned) | flat ceiling |
| `paced_floor` | primary | **inert** (warned) | paced head start |
| `pace_exempt_threshold` | primary | **inert** (warned) | P0 exempt cap |
| `weekly_threshold` | 7d | **the gate** | 7d ceiling |
| `weekly_paced_floor` | 7d | paced head start | paced head start |
| `weekly_pace_exempt_threshold` | 7d | P0 exempt cap | P0 exempt cap |
| `weekly_warning_policy` | 7d | applies | applies |
| `threshold_mode`, `pace_curve`, `on_exhaustion`, `overage_alert_usd`, `pace_exempt_priority` | window-agnostic | applies | applies |

## Per-model weekly limits: nested windows of the `claude` pool (bd-e0b7so)

Anthropic's `limits[]` can carry `kind: "weekly_scoped"` entries, one per model
(`scope.model.display_name`, e.g. `Fable`). A scoped limit is a **subset** of
`weekly_all` (a Fable run draws on both), so it is a window nested in the one
`claude` pool and never a pool of its own: seats are counted once.

- **Stored** on `anthropic_quotas.scoped_limits`, replaced by every poll that
  reports `limits[]` and left alone by one that does not.
- **Projected per model.** `Gate.Snapshot.normalize(quota, model: m)` carries
  the scoped windows whose scope matches `m` (`ModelFamily.scope_matches?/2`:
  every word of the display name is a word of the model id, so `Fable` matches
  `claude-fable-5-1` and `fable`). `model: nil` carries all of them (the
  conservative reading, as for agy); with no `:model` option the snapshot carries
  none, which is the account-level view the board reads.
- **Evaluated like the base long window.** `Gate`, `Headroom` and `Budget` run
  the `weekly_*` keys and the account's `pace_curve` over each scoped window,
  labelled `7d (Fable)`. A card's budget is the `min` over its windows, and the
  first-seat rule's "below the line on every trusted window" includes its scoped
  window. A hold reads `7d (Fable) binds, ...`.
- **Holds only the matching model.** `Budget.Server` publishes a scoped variant
  beside the pool's budget (`Budget.scope`) and `SeatCheck` picks it by the
  card's model, so exhausting Fable holds Fable cards while the account serves
  other models. The dispatch gate resolves the card's model for an account that
  reports a scoped window; an unresolvable model reads the worst of all.
- **Unknown scopes.** A scope that matches no known Claude model is logged once
  and shown in `arb quota` (`scoped`, `matched: false`), and gated, on every
  model, only when Anthropic marks it `is_active`.

The scheduler walk (`Board.WalkInputs`) still plans against the pool-level
budget; a Fable card it promotes is held at admission by `SeatCheck`.

## The paced line and `pace_curve` (bd-bq0gi8)

In `threshold_mode: "paced"` a window's ceiling follows the clock. With
`elapsed` the fraction of the window gone (`0.0` at its reset, `1.0` at the
next), the **`pace_curve`** setting picks the line:

| `pace_curve` | Line | Behaviour |
| --- | --- | --- |
| `plateau` (default; also what an unset or unrecognised value reads as) | `max(floor, elapsed)` | Flat at the floor until `elapsed` overtakes it. A pool that reaches the floor early waits. |
| `ramp` | `floor + (1 - floor) * elapsed` | A straight line from the floor at the reset to 100% at the next one. No plateau. |

At floor `0.10` the `ramp` line on a 7d window is 10% at the reset, 23% at one
day, 55% at 3.5 days and 74% at five; on a 5h window 10%, 28% at one hour, 55%
at 2.5h and 82% at four. It is lower than the plateau line early in the window
(below the old 20% weekly line for about the first 19h of a week) and higher
late in it. At floor `0` the two curves are the same line, which is why the
dollar spend cap (always floor 0) is unaffected.

Set it per account (`arb account set <ref> --pace-curve ramp`, the account form
on the Providers page, or `account_set` with `quota_config.pace_curve`) or per
workspace (`arb config set quota.pace_curve ramp --workspace <ws>`). The account
and the workspace each carry their own curve and floors; the gate takes
`min(account, workspace)` of the two lines **at the moment of the check**, so
the side that binds can change through the window. A window with no known length
or reset still falls back to its flat ceiling under either curve.

The P0 pace exemption lifts whichever line is in force:
`exempt ceiling = max(line, min(exempt_cap, flat))`.

Roll back by unsetting the key (`arb account set <ref> --unset pace_curve`).

## The optional rolling-24h burn governor (`daily_burn_cap`, bd-cklotu)

With the 5h window gone, Claude has no short-horizon brake: the 7d line paces a
week, not a burst. `daily_burn_cap` is an **optional** one, **off unless set**, and
shadow-first. Decide whether to have it from data, after the 7d budget has run in
shadow for a couple of weeks.

**`burn_24h`** is the share of the 7d window used in the last 24 hours. Each OAuth
poll computes it from the `quota_snapshots` 7d samples (`Arbiter.Quota.Burn`) and
stores it on the account's quota row (`burn_24h`, `burn_24h_at`). A window reset
inside the 24 hours restarts the baseline at zero (a moved `resets_at`, or a fall in
utilization when there is none), so a rollover is not read as negative burn. A
history too sparse to say (it must reach back to within 2 h of the 24 h mark, end
within 1 h of now, and have no gap over 3 h) gives `nil`, and `nil` or an hour-old
reading never holds anything.

| Key | Where | Meaning |
|---|---|---|
| `daily_burn_cap` | account `quota_config`, workspace `quota` | fraction in (0, 1] of the 7d window allowed per rolling 24 h; unset = off. A workspace can only tighten: `min(account, workspace)` |
| `daily_burn_cap_mode` | same | `shadow` (default) or `enforce`; either side saying `enforce` enforces |

Set it per account (`arb account set <ref> --daily-burn-cap 0.25 --daily-burn-cap-mode
enforce`, the Providers page, `account_set` with `quota_config.daily_burn_cap*`) or per
workspace (`arb config set quota.daily_burn_cap 0.2 --workspace <ws>`, or the workspace
policy form). `arb account set <ref> --daily-burn-cap none` turns it off.

- **`shadow`** holds nothing. The "would have held" record is the **Burn governor**
  section of the admission shadow report (`mix arbiter.admission_shadow_report`),
  which appears once any account sets a cap: how many hourly readings reached it.
- **`enforce`** adds two things, both honouring the P0 pace exemption (an exempt
  priority is never held on the burn): a flat **Gate** rule, `burn_24h >= cap` holds the
  dispatch (`24h burn 30% ≥ cap 25% (daily_burn_cap)`), and, under `scheduler_admission:
  enforce`, where the Gate leaves utilization rules to the budget, a **Budget** `24h`
  window whose line is the cap and whose draw is the 7d window's `ρ`, so the seat count
  shrinks before the cap is reached.

### Picking the cap: `mix arbiter.burn_report`

    mix arbiter.burn_report                 # last 30 days, per account
    mix arbiter.burn_report --cap 0.25      # replay a cap no account has yet
    bin/arbiter eval 'Arbiter.Release.burn_report()'   # on a release

prints the p50 / p90 / p99 of the historical rolling-24h burn per account, and, with a
cap, how many readings it would have held and when the first was. A cap near p99
trims only the worst bursts; one near p50 would hold on an ordinary day. The report is
read-only. `arb quota --account <ref>` shows the cap, its mode and the current
`burn_24h`. Roll back by unsetting the key (`--unset daily_burn_cap`).
