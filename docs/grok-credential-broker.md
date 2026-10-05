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
                                      ~/.grok/auth.json (canonical)
```

* **Canonical credential**: one `auth.json` (default `~/.grok/auth.json`,
  `config :arbiter, :grok_broker, auth_path:`). Only the broker reads the refresh
  token or writes the file.
* **Per worker**: a generated wrapper script under the worker's own `GROK_HOME`
  (not `/tmp`: the jail mounts a private `--tmpfs /tmp`) that `exec`s
  `arb grok-token`. grok runs it for its first token, ~5 minutes before expiry
  and on a 401 (with `GROK_AUTH_EXPIRED=1`). The reply is exactly
  `{"access_token", "expires_in"}`. See `Arbiter.Grok.AuthProvider.spawn_env/2`.
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
calling the issuer again. The hold lifts itself on the next request after the
canonical file holds a different login (`grok login --device-code` on the
Arbiter host), or with `arb breaker reset --auth-hold grok`.

The hold's identity is the module `Arbiter.Agents.adapters()[:grok]`, else
`Arbiter.Agents.Grok`; the adapter must register under that name.

## Not logged

Access and refresh tokens never reach a log line, error tuple or API error
body. Logs carry 12-hex-digit SHA-256 fingerprints, expiry times and OAuth
error codes.
