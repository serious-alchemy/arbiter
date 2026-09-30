# /api/oauth/usage Rate-Limit Behaviour

**Measured in bd-3x0na3.** This documents undocumented upstream behavior discovered
during quota polling integration.

## Key observations

- **Rate limit is per account, not per token.** A second distinct OAuth token on
  the same account is rate-limited identically to the first. Workspace-scoped
  tokens are scope/rate-limited and will not work against this endpoint; only
  the operator's credentials-file token succeeds (confirmed in PR #1607).
  bd-4ag0nj re-checked the `claude setup-token` grant (`sk-ant-oat01`, the
  account's `:oauth_token` credential) with the account bucket refilled:
  `429 rate_limit_error` with `Retry-After: 3600` counting down across
  requests (a per-token lockout), while the credentials-file token on the
  same account got `200` twelve seconds later.

- **The credentials-file token lapses without an interactive session.** Its
  access token lasts about 8h and only refreshes while a `claude` process
  runs against it (see "Dedicated quota grant" below for what refreshes it
  and how Arbiter now keeps its own grant alive). When it expires (401) or the file disappears,
  `Arbiter.Quota.CloudProbe` escalates once, after 3 failed cycles, naming
  the lapsed interactive login and the fix (run `claude` on the host) — when
  workers run on their own token. With no worker token anywhere, workers are
  seeded that same file, so a 401 is treated as a worker-credential expiry
  (`CredentialWatchdog`) plus the generic poll-failure escalation instead.

- **Small burst bucket refilling at ~1 request / 5 minutes.** The rate limit
  horizon is account-wide. A second request ~1 second after a success responds
  with 429.

- **`retry-after: 0` header is uninformative.** Do not trust it for cooldown
  timing. `Arbiter.Quota.OAuthUsage` never lets a `Retry-After` shorten its
  cooldown below the default (one CloudProbe cycle plus 30 s, `cooldown_ms/0`);
  a longer delay-seconds value does lengthen it, up to one hour
  (`max_cooldown_ms/0`) — see "Implications" below.

## Dedicated quota grant (bd-b632tz)

The poll can authenticate with a Claude grant of its own instead of the
operator's interactive login: the operator logs in once into a separate config
dir, the account references that dir by **path** (a `cli_credentials_path`
credential), `Arbiter.Quota` re-reads the access token from the file on every
poll, and `Arbiter.Quota.GrantRefresher` has the `claude` CLI refresh it before
it expires. Arbiter never calls the OAuth token endpoint and never stores the
grant's tokens.

Setup, on the Arbiter host:

```sh
cd /tmp   # a neutral dir: never the admiral dir or a repo
CLAUDE_CONFIG_DIR=~/.arbiter/quota-claude claude auth login
arb account rotate claude:default --kind cli_credentials_path --secret ~/.arbiter/quota-claude
```

The refresher then pages once, naming that login command, if a refresh
fails, the file becomes unreadable, or the grant's `refreshTokenExpiresAt` is
within 7 days.

### Measured on 2026-09-27/28 (claude 2.1.283)

- **The CLI refreshes only inside the last 5 minutes.** The bundled JS
  checks `now + 300000 >= expiresAt` before refreshing the access token
  (read from the installed binary). The operator's stopgap timer confirms it
  live: `claude -p "Reply with just: ok" --model haiku` at 19:48Z, with
  `expiresAt` at 20:32:04Z (44 min away), left `expiresAt` unchanged, and so
  did every hourly run before and after it. The grant was refreshed at
  20:30:39Z, 85 s before expiry, by another `claude` process on that grant.
  The new `expiresAt` (04:30:39.391Z) is exactly 8h after that refresh. So a
  refresher that runs the CLI "under 60 min before expiry" would do nothing.
  `GrantRefresher` runs it when `expiresAt` is under 4 minutes away, and
  counts a refresh only if the re-read `expiresAt` moved later.
- **The invocation.** Only a real request goes through the refresh check.
  The static read shows `claude auth status` reports whether a token is
  present without calling the refresh function. So the refresher uses the
  cheapest request turn: `claude -p "Reply with just: ok" --model haiku
  --no-session-persistence --strict-mcp-config --tools ""`, run with
  `CLAUDE_CONFIG_DIR` set, from a neutral cwd, and with
  `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` stripped so the CLI
  authenticates off the file. Against a config dir with no grant, that
  exact argv exits `1` with `Not logged in · Please run /login` (measured),
  and the refresher reports that as a refresh failure. It costs one Haiku
  turn per grant every ~8h. **NOT YET MEASURED: that this argv actually
  renews a grant.** The only live refresh observed so far came from a
  different `claude` process. Procedure P1 below settles it after deploy
  (AC5).
- **The refresh token does not slide.** After the 20:30:39Z refresh,
  `refreshTokenExpiresAt` was 2026-10-27T11:16:35.391Z. It has the same
  millisecond stamp as the new `expiresAt`, so that refresh wrote it too, but
  it is 29.6 days out rather than a round lifetime from the refresh. That
  points to an absolute expiry fixed at login, which would need a fresh login
  roughly monthly. This is an inference from one refresh; the next refresh
  will confirm it if the value stays put. Either way, the refresher's 7-day
  warning is how the operator hears about it in time.
- **The setup token is refused on every request — a lockout, not a rate.**
  bd-b632tz sent one request with the account's `claude setup-token` grant at
  01:42:29Z, about 10h after bd-4ag0nj's last probes. It got `429
  rate_limit_error` with a fresh `Retry-After: 3600`. A second request at
  02:43:29Z, 60 s after that `Retry-After` had lapsed, got the same `429` and
  another fresh `Retry-After: 3600`. A rate limit would have admitted the
  first request after a long idle, and the second after the stated wait.
  This one re-arms on every request, so it behaves like a scope refusal
  dressed as a 429. The setup token cannot poll this endpoint. The
  coordinator's own poll on the same account still landed after each probe
  (01:46:31Z and 02:46:31Z), so the probes did not spend the account's
  bucket.
- **NOT YET MEASURED: separate grants don't rotate each other.** Measuring it
  needs the operator's interactive browser login of the dedicated grant, and a
  headless worker cannot complete one. The expectation comes from bd-6umoh9:
  its rotation incident was two refreshers sharing one refresh token (a
  *copied* `.credentials.json`), while `claude auth login` into a separate
  `CLAUDE_CONFIG_DIR` mints its own refresh token. Procedure P2 below settles
  it after deploy (AC6).

### Not yet measured: post-deploy procedures

Both procedures need the dedicated grant to exist:

```sh
cd /tmp   # neutral: never the admiral dir or a repo
CLAUDE_CONFIG_DIR=~/.arbiter/quota-claude claude auth login
arb account rotate claude:default --kind cli_credentials_path --secret ~/.arbiter/quota-claude
```

Observe both grants with this helper. It prints metadata and a short hash of
each refresh token, never a token itself:

```sh
grant() { python3 - "$1" <<'PY'
import datetime as d, hashlib, json, sys
o = json.load(open(sys.argv[1]))["claudeAiOauth"]
t = lambda ms: ms and d.datetime.fromtimestamp(ms / 1000, d.timezone.utc).isoformat()
print(sys.argv[1], "expiresAt", t(o.get("expiresAt")),
      "refreshTokenExpiresAt", t(o.get("refreshTokenExpiresAt")),
      "refreshToken#", hashlib.sha256(o["refreshToken"].encode()).hexdigest()[:12])
PY
}
grant ~/.arbiter/quota-claude/.credentials.json
grant ~/.claude/.credentials.json
```

- **P1: does the refresher's argv renew?** Right after the dedicated grant's
  `expiresAt` passes (it is ~8h after login), look for the server log line
  `Arbiter.Quota.GrantRefresher: renewed ~/.arbiter/quota-claude/.credentials.json`,
  and run `grant` on the file. The expected result is that `expiresAt` jumped
  about 8h later and `refreshToken#` changed. A failure shows up as the
  escalation "Anthropic quota grant needs re-login — …" instead. Record the
  before and after values and timestamps here, then replace the P1 caveat
  above.
- **P2: separate grants don't rotate each other.** Run `grant` on both files
  at login, then at least once per refresh of either grant over 48h. Keep the
  `claude-keepalive.timer` stopgap disabled for this window (AC5), so the
  operator's `~/.claude` refreshes only through its own sessions. Each
  grant's `refreshToken#` should change only when that grant's own
  `expiresAt` moves. The operator's interactive `claude` should stay logged
  in, and `claude auth status` in `~/.claude` should still report
  `loggedIn: true` at 48h (AC6). Record the observed sequence here, then
  replace the P2 caveat above.

## Response shape and mapping

The endpoint returns quota data as JSON with these keys. They map to the
`anthropic-ratelimit-unified-*` headers that appear on worker responses:

### 5-hour window

- `five_hour_utilization_percentage` → `anthropic-ratelimit-unified-5h-utilization`
- `five_hour_quota_reset_at` → `anthropic-ratelimit-unified-5h-reset`
- `five_hour_status` → `anthropic-ratelimit-unified-5h-status`

### 7-day window

- `seven_day_utilization_percentage` → `anthropic-ratelimit-unified-7d-utilization`
- `seven_day_quota_reset_at` → `anthropic-ratelimit-unified-7d-reset`
- `seven_day_status` → `anthropic-ratelimit-unified-7d-status`

### Per-model breakdown (7-day)

- `usage_by_model`: map of model name to `{tokens_used, tokens_requested}`
  - Maps to stream items like `seven_day_sonnet`, `seven_day_opus`, etc.

### Account overage

- `representative_claim` → `anthropic-ratelimit-unified-representative-claim`
- `overage_status` → `anthropic-ratelimit-unified-overage-status`
- `extra_usage`: map with billing details for out-of-quota usage

## Implications

Because this endpoint rate-limits per account and refills slowly (~1 req/5min),
it is the primary constraint on quota polling. `Arbiter.Quota.CloudProbe` runs
once per cycle per provider account (not per-workspace), authenticating with
the account's dedicated quota grant when it has one, and otherwise with the
operator's credentials-file token. Only these interactive-login grants work.

When a 429 occurs, `Arbiter.Quota.OAuthUsage.fetch/1` cools down so that the
next scheduled CloudProbe poll is skipped rather than sent into the same empty
bucket (#1876 — the old fixed 180s cooldown lapsed before the 300s poll and
never skipped anything):

- by default for one poll cycle plus 30s (`cooldown_ms/0`, 330s at the default
  cadence) — the poll after the skipped one goes out as normal;
- for a delay-seconds `Retry-After` longer than that, for the header's delay,
  capped at one hour (`max_cooldown_ms/0`, the longest wait this endpoint has
  been seen to ask for — the setup token's `Retry-After: 3600`).

A 429 therefore costs two polls, and the next successful poll can land about
900s after the last one. The gate's staleness margin for a polled row
(1200s, `Arbiter.Quota.Gate.staleness_threshold_seconds/1`) absorbs that
without failing the 5h window open. A longer blackout — a second 429 in a row,
a long `Retry-After`, a lapsed credential — ages the snapshot past that
margin; once it is older than 30 minutes, `Arbiter.Quota.StalenessWatch`
raises an operator alert that quota accounting is blind.

The header-capture source (`anthropic-ratelimit-unified-*` from worker responses)
continues unaffected by endpoint 429s, but only provides aggregate figures and
only updates when the fleet is actively making requests. The polling source
is the only way to maintain quota visibility for an idle or quota-held fleet.
