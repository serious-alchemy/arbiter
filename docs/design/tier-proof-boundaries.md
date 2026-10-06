# Tier / proof boundaries (P-28)

Decision record for parity item P-28 (audit bd-ws8nmk; operator ruling on
bd-37d191, 2026-10-06). Scope: REST + CLI. Node-tier endpoints (`/node/*`,
`/api/nodes*`) are unchanged.

**Threat model.** Every worker and every coordinator *session* (an LLM) runs on
the server host as the operator's Unix user. Loopback therefore proves only
"same host". What separates the operator from a session is **operator proof**:
a coordinator token minted over `Arbiter.MCP.OperatorSocket`, which checks the
peer's kernel credentials and refuses any process Arbiter spawned
(`Scope.operator?/1`; see `docs/worker-security.md`). A plain coordinator token
(`ARB_TOKEN`, a session's own) is *not* operator proof.

## Decisions

| Surface | Decision |
|---|---|
| `POST /api/dashboard/login_tokens` (D-A-18) | **Operator proof required** (`ApiPolicy` `:operator`). A dashboard login is an operator grant; a coordinator session must not be able to mint one. `arb dashboard login` mints a 5-minute coordinator token over the operator socket and sends *that* (never `ARB_TOKEN`); if the socket is unreachable it fails rather than fall back. Remote `ARB_HOST`: run it over `ssh <host> arb dashboard login`. |
| `POST /api/grok/token` (grok-token note) | Coordinator tokens unchanged. A **worker** token is honoured only while its task exists and lies in the workspace the token names (403 otherwise). It remains an installation-wide credential, as the grok login is one per installation. |
| `POST /api/mcp/tokens/verify` (D-M-14/15) | A coordinator may decode any token; every other tier only **its own** (the presented token must equal the caller's bearer; 403 otherwise). No decoding of another principal's token. Minting is unchanged: REST when the caller holds a token (capped at the caller's authority), the operator socket otherwise. |
| `?token=` (D-M-22) | Accepted **only on `/mcp`** (MCP clients that cannot set headers; the SSE stream). `/api/*` and `/events` take `Authorization: Bearer` only. Phoenix's `:filter_parameters` (`token`) keeps the value out of request logs; `plug_test.exs` pins that. |
| Secrets on argv (D-C-36) | `workspace secret set <key> --file PATH \| -`, `account rotate --secret-file PATH \| -`, `mcp token verify --file PATH \| -` read the value without exposing it to `ps`/shell history. The argv forms (`set <key> <value>`, `--secret VALUE`, `verify <token>`) still work and print a warning on stderr (never the value). |

## Not changed (and why)

* `arb mcp token mint`'s dual route (REST vs socket by environment) keeps its
  documented behaviour; the REST route already caps the minted token at the
  caller's authority (`McpController.mint_token/2`).
* The dashboard UI's own login-start path (the browser flow in D-A-18) is not
  touched by this change; only the REST mint route gained the proof requirement.

## Tests

`dashboard_auth_test.exs` (operator / coordinator / worker / anonymous),
`grok_token_controller_test.exs` (workspace mismatch, missing task),
`mcp_controller_test.exs` (own-token verify), `mcp/plug_test.exs` (`?token=`
not logged), and the CLI tests for `dashboard`, `workspace`, `mcp`, `account`.
