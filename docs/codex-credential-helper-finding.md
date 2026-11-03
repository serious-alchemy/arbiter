# Codex credential helper (`model_providers.<id>.auth`): finding (bd-691g3h, #1094)

**Decision: not built. The ticket's own gate failed, so this closes with the finding.**
The ticket said to confirm two things before building and to close with the finding if either
failed. The version check passes. The "use our ChatGPT login this way" check does not.

## 1. Does the pinned Codex CLI support the helper? Yes.

- Container `codex` binary (`/opt/arbiter/cli/codex`, `codex-package.json` `version: 0.166.0`):
  `codex --version` prints `codex-cli 0.166.0`. The repo's earlier probes cite 0.153.4.
- Upstream added command-backed bearer tokens for custom providers in openai/codex PRs
  #16286 / #16287 / #16288, merged to `main` on 2026-03-31
  (<https://github.com/openai/codex/pull/16288>). Both versions above are later.
- Documented in the advanced config reference
  (<https://learn.chatgpt.com/docs/config-file/config-advanced.md>, formerly
  developers.openai.com/codex/config-advanced): `[model_providers.<id>.auth]` takes `command`,
  `args`, `timeout_ms` and `refresh_interval_ms`. The command gets no stdin and prints the token
  to stdout. Codex trims it, treats an empty token as an error, and refreshes on the interval
  (`0` means only after an auth retry).
- **Probed live on 0.166.0** against a local mock Responses server (no quota used). A custom
  provider with `[model_providers.arb.auth] command = <script>` made Codex run the script and send
  `authorization: Bearer <script output>` on `GET /v1/models` and `POST /v1/responses`. No
  `auth.json` was written to `CODEX_HOME`. The helper's environment included the run's
  `ARB_TOKEN`, so an `arb` helper verb could authenticate the same way `arb grok-token` does.

## 2. Can the helper carry our ChatGPT login? No.

- **The helper cannot be combined with ChatGPT-login auth.** The docs say "Don't combine
  `[model_providers.<id>.auth]` with `env_key`, `experimental_bearer_token`, or
  `requires_openai_auth`". Probed on 0.166.0: adding `requires_openai_auth = true` makes Codex
  refuse to start with
  `Error loading config.toml: model_providers.arb: provider auth cannot be combined with requires_openai_auth`.
  Arbiter's Codex fleet runs on the ChatGPT login (`auth_mode: "chatgpt"`), which is the
  `requires_openai_auth` path. The helper is only for a *custom* provider that takes a plain
  bearer token (an API-key gateway, Azure, Vault-fetched keys).
- **Making it carry a ChatGPT token means working around Codex's own login path.** A custom
  provider pointed at the ChatGPT backend with a hand-extracted OAuth access token would be a
  generic OAuth client outside Codex. OpenAI's CI/CD auth guide
  (<https://learn.chatgpt.com/docs/auth/ci-cd-auth.md>) says its workflow does not apply to
  "generic OAuth clients outside Codex". It also says to use one `auth.json` per runner or
  serialized workflow stream and "Do not share the same file across concurrent jobs or multiple
  machines", and not to use it for public repositories. The auth overview
  (<https://learn.chatgpt.com/docs/auth>) says API keys are the recommended default for
  automation and that access tokens are for "trusted scripts, schedulers, and private CI
  runners".
- **Terms of Use.** The OpenAI Terms of Use account section says "You may not share your account
  credentials or make your account available to anyone else" (via search snippets of
  <https://openai.com/policies/terms-of-use/>, the January 2026 version). I could not fetch the
  page itself (HTTP 403 from this environment) and could not find wording that permits
  re-presenting a ChatGPT subscription token through a custom provider. I did not find wording
  that forbids it either. The conclusion is therefore not "allowed". The documented, supported
  paths are Codex-managed `auth.json` on trusted private infrastructure or an API key.
- **The API-key variant is not what the ticket asked for.** A helper serving a static platform
  API key (`OPENAI_API_KEY`) works technically. But it is not short-lived and bills per token
  against the API org rather than the ChatGPT plan. It also changes the cost model, which is a
  product decision and not a transport tweak. The ticket's motivation (short-lived ChatGPT
  credentials per run) is not met by it.

## What stays as it is

The existing path stays: per-run `CODEX_HOME` with a copy of `auth.json` for podman and remote
runs, kept in step by `Arbiter.Agents.Codex.AuthSync` and its reaper. Grok's
`GROK_AUTH_PROVIDER_COMMAND` broker (`docs/grok-credential-broker.md`) is the template if OpenAI
later ships a helper-style hook for ChatGPT-managed auth, or if the operator chooses an API-key
fleet.

## Acceptance criteria

| AC | Status |
|---|---|
| PR states Codex version checked and ToS conclusion with sources | Met (this doc and the PR body) |
| Test: run config uses the helper, no token literal | Not built: gate failed for ChatGPT login |
| Test: helper refuses finished or unknown runs | Not built |
| Test: no `auth.json` on the helper path | Not built (a manual probe on 0.166.0 showed none is written for a custom provider) |
