# Grok credential broker (bd-9p4lx9)

grok's OIDC `refresh_token` **rotates on every refresh**, and grok **deletes
`auth.json`** when a refresh is permanently refused. Giving each worker a copy of
the operator's `auth.json` would therefore race: the first copy to refresh
invalidates the operator's token and every other copy (the bd-6umoh9 problem),
and each loser then deletes its own file. Arbiter never copies it.

## Shape

```
worker jail                              Arbiter server
-----------                              --------------
grok ── GROK_AUTH_PROVIDER_COMMAND ──►   POST /api/grok/token   (worker ARB_TOKEN)
        <GROK_HOME>/arbiter-grok-token         │
        └─ exec arb grok-token                 ▼
                                      Arbiter.Grok.CredentialBroker   ← the only
                                               │                        refresher
                                               ▼
                                      accounts/grok-<slug>/auth.json (canonical)
```

* **Canonical credential**: one `auth.json` per install, resolved by
  `Arbiter.Grok.CredentialStore.resolve/1` (bd-8rvkqd), the same way for the
  broker, the doctor and the login relay:
  1. `config :arbiter, :grok_broker, auth_path:` when set (an explicit pin);
  2. else the **grok provider account's** `<accounts_root>/grok-<slug>/auth.json`
     (`~/.arbiter/accounts/grok-default/auth.json`), which is where the dashboard
     login relay writes (`GROK_HOME=<that dir>`). With several grok accounts,
     the `default` slug wins, else the first with a file;
  3. else, **only when no grok account exists**, `~/.grok/auth.json`.

  The path is re-resolved on every request (a first dashboard login creates the
  account while the server runs) and logged at boot, when it changes and at the
  first refresh. The file is never copied between locations: the refresh token
  rotates, so two copies would race. Only the broker reads the refresh token or
  writes the file.
* **Per worker**: a generated wrapper script under the worker's own `GROK_HOME`
  (not `/tmp`: the jail mounts a private `--tmpfs /tmp`) that `exec`s
  `arb grok-token`. grok runs it for its first token, ~5 minutes before expiry
  and on a 401 (with `GROK_AUTH_EXPIRED=1`). The reply is exactly
  `{"access_token", "expires_in"}`. See `Arbiter.Grok.AuthProvider.spawn_env/2`.
* **A cold `GROK_HOME` is hydrated first** (bd-8rvkqd). Measured on grok 1.0.25:
  headless `grok -p` does **not** run `GROK_AUTH_PROVIDER_COMMAND` when its
  `GROK_HOME` has no `auth.json`; it answers "Not signed in" without asking (so
  the broker saw no request). The command is only consulted to *refresh* a
  credential grok already holds, and `grok login` is what creates one (an
  `auth.json` with `auth_mode: external` and no refresh token). So the adapter's
  launch script (`Arbiter.Agents.Grok`) runs `grok login` once per home, in the
  worker's env, before `exec`ing grok; that is the run's first token request.
  Once hydrated, an expired token makes grok run the command with
  `GROK_AUTH_EXPIRED=1`.
* **Every request is logged** by the broker: `token request task=<id> run=<id>
  force=<bool> outcome=ok|reauth_required|not_logged_in|unavailable`, never the
  token. A grok run with no such line never asked.
* **`XAI_API_KEY`** instead, when `api_key_ref` is configured (a
  `credentials_ref`: `env:XAI_API_KEY`, `secret:xai`). The key replaces the
  broker for that worker. A ref that does not resolve is an error, not a silent
  fall-back to the operator's login.
* **The jail hides `~/.grok`** (`Arbiter.Worker.Jail.Hide`) so a worker cannot
  read the canonical file under `--ro-bind / /`.

## Single writer

Every request is a call to the one broker process.

| Situation | Result |
|---|---|
| token has more than `refresh_margin_s` (600) left | served from the file, no network |
| token inside the margin, or `GROK_AUTH_EXPIRED=1` | **one** refresh; concurrent callers queue behind it and share the result |
| `GROK_AUTH_EXPIRED=1` within `min_force_interval_s` (60) of a refresh | the fresh token, no second refresh |
| refresh succeeded, file write failed | rotated pair kept in memory, served, write retried on each request |
| operator's own grok rotated the file mid-refresh | adopted / retried against it; no hold |
| `invalid_grant` / `invalid_client` / `unauthorized_client` / no file | **auth hold** (below) |
| network, 5xx, 429 | no hold; a still-valid token is served, else `grok_unavailable` (503) |

The file is rewritten atomically (temp file `0600` + rename) and only the three
token fields change. **Nothing here ever deletes it.**

## Permanent failure

The broker marks the provider expired in `Arbiter.Agents.CredentialWatchdog`:
the dispatch gate closes, coordinators are paged, quota surfaces report
`credentials_expired`. Every worker request then fails fast (503
`grok_reauth_required` / `grok_not_logged_in`, remedy in the message) without
calling the issuer again. While a hold is open the broker polls the canonical file
(`hold_check_ms`, 30 s), so the hold lifts itself, with no worker request
needed (dispatch is gated, so none would come), once the file
holds a different login (re-run the login from the dashboard, or
`grok login --device-code` on the host when no grok account exists), or with
`arb breaker reset --auth-hold grok`.

A grok worker that dies "Not signed in" at spawn opens the grok `AuthHold` on
its **first** death (other providers need two): the credential is one shared
login, so one death is conclusive. While it is open `routing.grok` stops
selecting grok (`Arbiter.Agents.GrokRouting.route?/3`), so the ticket
`AuthDeath` reopens goes to the next eligible provider. Clear it with
`arb breaker reset --auth-hold grok` after fixing the login.

The hold's identity is the module `Arbiter.Agents.adapters()[:grok]`, else
`Arbiter.Agents.Grok`; the adapter must register under that name.

## Not logged

Access and refresh tokens never reach a log line, error tuple or API error
body. Logs carry 12-hex-digit SHA-256 fingerprints, expiry times and OAuth
error codes.

## Enabling grok per workspace (bd-dpv4vt)

grok is registered as an agent type (`grok`) and a provider-account provider, but
it is **off by default**: free tier only, about 500K tokens per rolling 24 h
(cached tokens counted), so a small task costs roughly an eighth of a day.

    arb config set routing.grok.enabled true          # default false
    arb config set routing.grok.difficulties '[1]'    # default [1]

Under the `by_difficulty` routing policy an enabled workspace sends only D1
tickets to grok; every other difficulty keeps the workspace's own agent.
Override `routing.grok.difficulties` to widen the set, or pin `agent.type:
"grok"` to send everything. Other routing policies are unaffected.

- **Login relay.** The dashboard Providers page can run `grok login
  --device-code` (the login runs with `GROK_HOME` set to the account's dir; the
  device URL and code are shown on the page). That dir's `auth.json` is the
  canonical credential the broker refreshes (see above), so a relay login is
  all that is needed.
- **Doctor.** `arb server doctor` prints a `grok auth` line from
  `GET /api/server/grok_auth`: silent-ok when no workspace uses grok, else the
  file the broker reads and its access-token expiry, with `logged in`;
  `expired` (ok only because the broker's last refresh worked); or `[fail]` for
  `refresh unverified` (expired and no successful refresh: the doctor makes one
  attempt itself through the broker), `refresh failed`, `reauth required` and
  `not logged in`, each with the fix naming the path.
