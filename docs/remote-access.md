# Remote access to the Arbiter dashboard and browser sessions

The Arbiter dashboard and browser-based session terminal are **loopback-only** by design — they bind to `127.0.0.1:4848` and do not accept off-network connections. To use the dashboard and terminal from another device (e.g., accessing an Arbiter instance on an AWS dev box from a laptop), forward the port over SSH.


> Looking to run workers on other machines rather than reach the dashboard remotely? See the proposed [remote workers design](design/remote-workers.md).
SSH provides both authentication (implicit) and encryption, and the forwarded connection appears to Arbiter as loopback traffic, so all existing security properties hold.

## Quick start: one-off SSH tunnel

Forward port 4848 from the remote machine to your local machine:

```sh
ssh -L 4848:127.0.0.1:4848 user@remote-host
```

Then visit `http://127.0.0.1:4848` on your local machine. The tunnel stays open while the SSH session is active.

## Persistent SSH configuration

To avoid typing the tunnel command every time, add a `LocalForward` directive to your SSH config (`~/.ssh/config`):

```
Host arbiter-dev
  HostName remote-host
  User user
  LocalForward 4848 127.0.0.1:4848
```

Then connect with:

```sh
ssh arbiter-dev
```

The port forward is set up automatically each time you connect.

## Automatic reconnection with autossh

If your SSH session disconnects frequently, use `autossh` to maintain the tunnel automatically:

```sh
autossh -M 20000 -L 4848:127.0.0.1:4848 user@remote-host
```

Replace `20000` with an unused port for health checks. `autossh` monitors the connection and reconnects if it drops.

## VS Code Remote-SSH

If you use [VS Code Remote-SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh), port forwarding is set up automatically when you open a remote folder. Once connected, you can access `http://127.0.0.1:4848` from your local browser.

## Closing the port after tunneling

Once you're done accessing the dashboard and terminal, close port 4848 on the remote machine's firewall or security group to prevent unintended access:

- **Cloud security group (AWS, GCP, etc.):** Remove or disable the ingress rule for port 4848
- **Host firewall (ufw, firewalld, etc.):** Ensure `iptables` rules or firewall rules do not expose 4848
- By default, Arbiter binds to loopback only, so it is not exposed without explicit firewall configuration

## Alternative: Remote Control (mode B)

For persistent, multi-session access with full browser support and auditing, consider [Remote Control mode](/docs/browser-hosted-coordinator-sessions.md#8-remote-control-sessions-research-task-4) (launched with `--remote-control`). The session appears in claude.ai / the Claude app titled `<name> · <short id>` (or the full session id if unnamed) — see the RFC for details. SSH tunneling is simpler for temporary or single-machine access.

## Trust assumption: loopback means the same Unix user (bd-5b5hq7, bd-8381tk)

"Loopback" is **not an identity**. Every process that can reach `127.0.0.1:4848` runs as the **same Unix user**: the operator's own shell, `arb`, every worker and every Arbiter session. Since bd-asawcq, `ArbiterWeb.Plugs.ApiAuth` lets a request with no bearer token reach only `GET /api/version` and `GET /api/server/migrations`, on loopback as off it. Every other `/api` route answers 401 without a token and checks the token's tier and scope (`ArbiterWeb.ApiPolicy`). The local `arb` still needs no setup: with no `ARB_TOKEN` it mints a short-lived coordinator token over the operator socket below, in memory, once per invocation. The browser dashboard is gated separately, by the login described in the next section.

**Token minting is no longer part of that trust (bd-8381tk).** An anonymous `POST /api/mcp/tokens` is refused (401 since bd-asawcq; 403 before) and gets no token of any tier. That removes the one route by which any worker could turn loopback into a coordinator token for `/mcp`. The operator mints with `arb mcp token mint` (and `arb init`) on the server host. Those commands prove operator identity over a local Unix socket that checks the caller's kernel-attested peer credentials and refuses any process the server itself started. From another machine, run `ssh <host> arb mcp token mint`. The mechanism, why a 0600 credential file wouldn't have been a boundary, and what it does and doesn't stop are in [worker-security.md](worker-security.md#operator-proof-for-token-minting-bd-8381tk).

Still in place from bd-5b5hq7:

  * a request that presents a bearer token, including a session's own `arb` calling over loopback with its own token, can never mint a token more powerful than itself (`ArbiterWeb.Api.McpController.mint_token/2` inherits the caller's `session_id`, workspace binding and `can_dispatch` ceiling);
  * inside a session, `arb` always authenticates with the session's own token, never the operator socket (`ArbiterCli.Client`, env var `ARB_SESSION_ID`);
  * the session's generated `settings.json` denies `Bash(arb mcp token mint:*)` outright.

**Closed by bd-asawcq:** the rest of the `/api` REST surface (dispatch, workspace config writes, issue close, loop apply) used to be reachable without a token by any same-user process. It no longer is. Workers' own `arb` authenticates with the worker-tier token their dispatch minted (`ARB_TOKEN`), which can act only on its own task. The details are in [worker-security.md](worker-security.md#bearer-tokens-on-every-api-route-bd-asawcq). The same-UID limits there still apply: if Arbiter sessions ever run as a separate Unix user from the operator, this assumption should be revisited.

## Dashboard login (bd-3gycsz)

The dashboard is no longer open to whoever can reach the port. `tailscale serve` proxies the tailnet to `http://127.0.0.1:4848`, so a proxied request arrives **from 127.0.0.1**; loopback therefore grants nothing. Every `:browser` route, and every LiveView mount (the websocket's gate: `Phoenix.LiveView.Socket` has no overridable `connect/3`, so the router's `live_session` runs the `:dashboard_auth` `on_mount` hook first), needs a grant from the configured `ArbiterWeb.DashboardAuth` implementation. `/api` and `/mcp` keep their bearer-token rules unchanged. The `/session` terminal socket no longer trusts loopback: it needs the dashboard grant (the session cookie the browser dock already carries) or a signed `Arbiter.MCP.Scope` token.

**Default implementation (`ArbiterWeb.DashboardAuth.Default`)**

  * **Token login (always on).** `arb dashboard login` mints a one-time link (120 s, single use, in memory) over the authenticated API and prints it. Open it in the browser and confirm; the session lasts 7 days. `GET /login?token=` only renders the confirmation, so a link previewer cannot burn the token. Chosen as the baseline because it needs no network identity, works over plain `http://127.0.0.1:4848`, and minting one requires a coordinator token. That is the operator, as with `arb mcp token mint`.
  * **Tailscale identity allowlist (opt-in).** Set `ARB_DASHBOARD_TAILSCALE_LOGINS=ryan@example.com,...` (or `config :arbiter_web, :dashboard_tailscale_logins`). A request carrying `Tailscale-User-Login` is accepted only if that login is listed **and** it came through `tailscale serve` (peer is loopback and serve's `X-Forwarded-For` is present). The same headers from a non-loopback peer, or from loopback with no forwarding header, are ignored, so a tailnet client hitting a non-loopback bind directly cannot spoof an identity. The login is re-checked on every request and mount, so removing it revokes live sessions. *Residual risk:* a process on this host can forge serve's headers on 127.0.0.1. That is no wider than the same-Unix-user boundary above (such a process can already mint a login token); leave the allowlist empty to avoid it.

  * **Direct loopback (opt-in, off by default).** Set `ARB_DASHBOARD_TRUST_LOOPBACK=true` (or `config :arbiter_web, :dashboard_trust_loopback, true`) to let a browser on the host itself in without `arb dashboard login`. A request qualifies only if **all** hold: the peer is loopback (127.0.0.0/8, `::1`); it carries **no** `X-Forwarded-For`/`-Host`/`-Proto`, `Forwarded` or `Tailscale-*` header (so nothing arriving through `tailscale serve` ever qualifies); and its `Host` is exactly `127.0.0.1`, `localhost` or `[::1]`, optionally with a port (DNS-rebinding defence: a page that points its own domain at 127.0.0.1 sends its own Host). For the LiveView websocket the peer, the `x-*` headers and the host are re-checked on the upgrade, on top of the existing Origin check, and the session must carry a marker stamped by a clean page request. Nothing long-lived is minted: it is re-evaluated on every request and mount, so turning the flag off revokes at once. `/api`, `/mcp` and `/session` keep their bearer-token rules. `GET /api/server/dashboard_auth` and `arb doctor` report the mode (e.g. `token+tailscale+loopback`); doctor then reports "loopback trusted (opt-in)" and still checks that a request carrying `X-Forwarded-For` is redirected. *Residual risk:* any local process or other Unix user on the host, and anyone with an `ssh -L` tunnel to the port, arrives as direct loopback and is trusted. Enable it only on a single-user machine where that is acceptable.

**Replacing it.** Implement `ArbiterWeb.DashboardAuth` (`authenticate/1`, `authenticate_session/1`, `mode/0`, optional `login_path/0`) and set `config :arbiter_web, :dashboard_auth, MyPackage.SsoAuth`. The router, plug and LiveView hook do not change. `arb server doctor` reports `dashboard requires login` (an anonymous `GET /` must redirect) with the active mode.
