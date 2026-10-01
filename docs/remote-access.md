# Remote access to the Arbiter dashboard and browser sessions

The Arbiter dashboard and browser-based session terminal are **loopback-only** by design — they bind to `127.0.0.1:4848` and do not accept off-network connections. To use the dashboard and terminal from another device (e.g., accessing an Arbiter instance on an AWS dev box from a laptop), forward the port over SSH.

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

"Loopback" is **not an identity**. Every process that can reach `127.0.0.1:4848` runs as the **same Unix user**: the operator's own shell, `arb`, every worker and every Arbiter session. Since bd-asawcq, `ArbiterWeb.Plugs.ApiAuth` lets a request with no bearer token reach only `GET /api/version` and `GET /api/server/migrations`, on loopback as off it. Every other `/api` route answers 401 without a token and checks the token's tier and scope (`ArbiterWeb.ApiPolicy`). The local `arb` still needs no setup: with no `ARB_TOKEN` it mints a short-lived coordinator token over the operator socket below, in memory, once per invocation. The browser dashboard is unaffected, because it is not served through `/api`.

**Token minting is no longer part of that trust (bd-8381tk).** An anonymous `POST /api/mcp/tokens` is refused (401 since bd-asawcq; 403 before) and gets no token of any tier. That removes the one route by which any worker could turn loopback into a coordinator token for `/mcp`. The operator mints with `arb mcp token mint` (and `arb init`) on the server host. Those commands prove operator identity over a local Unix socket that checks the caller's kernel-attested peer credentials and refuses any process the server itself started. From another machine, run `ssh <host> arb mcp token mint`. The mechanism, why a 0600 credential file wouldn't have been a boundary, and what it does and doesn't stop are in [worker-security.md](worker-security.md#operator-proof-for-token-minting-bd-8381tk).

Still in place from bd-5b5hq7:

  * a request that presents a bearer token, including a session's own `arb` calling over loopback with its own token, can never mint a token more powerful than itself (`ArbiterWeb.Api.McpController.mint_token/2` inherits the caller's `session_id`, workspace binding and `can_dispatch` ceiling);
  * inside a session, `arb` always authenticates with the session's own token, never the operator socket (`ArbiterCli.Client`, env var `ARB_SESSION_ID`);
  * the session's generated `settings.json` denies `Bash(arb mcp token mint:*)` outright.

**Closed by bd-asawcq:** the rest of the `/api` REST surface (dispatch, workspace config writes, issue close, loop apply) used to be reachable without a token by any same-user process. It no longer is. Workers' own `arb` authenticates with the worker-tier token their dispatch minted (`ARB_TOKEN`), which can act only on its own task. The details are in [worker-security.md](worker-security.md#bearer-tokens-on-every-api-route-bd-asawcq). The same-UID limits there still apply: if Arbiter sessions ever run as a separate Unix user from the operator, this assumption should be revisited.
