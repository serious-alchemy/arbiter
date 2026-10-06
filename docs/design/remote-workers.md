# Remote workers v2: join token + node agent (pull model) — design

**Status:** proposed (2026-10-05). Nothing here is implemented. Epic bd-9bk0af; design task bd-bw8a0m; committed by bd-dufrgb. Later children update the §17 assumptions table as spikes land.

Task bd-bw8a0m, research. Revises and **replaces** bd-aowisc's notes (SSH push). Written against `main` at `9b5fb0733` (bd-aowisc was `99a27ed9`; 41 commits later). No code or config changed. Every existing module/function named here was found in the repo at that commit (§19 lists how; names that do not exist yet are marked **(new)**). Anything I relied on but did not observe is marked **[U#]** and indexed in §17.

The document is meant to stand alone. §1 is the one-screen summary, §2 says which bd-aowisc sections carry over, §18 is the child breakdown (first child commits this as `docs/design/remote-workers.md`).

## 0. What changed on main since bd-aowisc (affects the design)

* `Arbiter.Worker.SeedPaths` + `Worktree.seed_compiled_deps/3` (bd-2jerqw shipped): `worker.repos.<repo>.seed_paths` now exists. bd-aowisc treated it as unshipped.
* `Arbiter.Worker.DepsCache` (bd-1wm14e, new file): an image-keyed deps cache for **container** workers, `<root>/<lock12>-<image12>`, seeded by a job *inside the worker image*, copied per worker with `cp -a --reflink`. It replaces "seed the clone from the host's `_build`" for podman runs (`ContainerSpawn.prepare/1` calls `DepsCache.seed_worktree/3` before starting egress). This removes bd-aowisc's "warm repo" idea (§7.3).
* `Workers.Reconciler.sweep_worker_scopes/1`, `MemoryScope.stop/2`, `list/1`, `sweep/2` (bd-6zm33r): orphaned `arb-run-*.scope` sweep, primary-gated.
* `Arbiter.Actor` + `versions.actor` (#352): attribution labels on audit writes; kinds are `:operator | :coordinator | :worker | :autopilot | :system | :refine`. A `:node` kind is a natural, tiny extension.
* Still true and re-verified: `Container` has **no** memory cap and uses `--rm`; `ContainerSpawn.prepare/1` is the single container prepare; `Worker` has exactly three port message clauses (`{port,{:data,{:eol|:noeol,_}}}`, `{port,{:exit_status,_}}` at `worker.ex:2844/2848/2852`) and the port-specific sites in `terminate_session_port/2` (`worker.ex:~3560-3600`: `safe_port_os_pid/1`, `OsProcess.kill_tree/1`, `Port.close/1`) and `session_live?/1` (`:8232`); `Egress` listeners are unix sockets under `Egress.socket_dir/0`.
* bd-aowisc's only child was bd-2jerqw (closed). **No SSH-model implementation children were filed**, so nothing needs closing or re-linking. bd-1nfuq5 (k8s in-cluster agent) depends on this ticket.

## 1. Decisions in one screen

| # | Decision | Loser(s), one line |
|---|---|---|
| 1 | **Scope unchanged:** only the podman-backed Claude task worker goes remote (bd-aowisc §5 carries over verbatim). | — |
| 2 | **Node agent = the Arbiter release run in an "agent" role** (`ARB_ROLE=agent`, same tarball, same version), installed as a user systemd unit by a join script. It runs the same pure builders locally on the node (`Container.argv/2`, `PrivateClone`, `DepsCache`, `TestServices`, `PodmanReadiness`). | SSH exec (operator direction); a separate Go/Rust agent (second build, version skew, re-implements the hardening builders); a second release definition (two artifacts to publish). |
| 3 | **Transport: one outbound WebSocket per node, as a Phoenix channel** (`/node/socket`, topic `node:<id>`), JSON control + binary frames (precedent: `SessionSocket`/`Sessions.Frame`). Bulk bytes (bundles, binaries, tarballs) go over plain HTTPS GETs/PUTs on the same origin, not the socket. | HTTP long-poll: wrong shape for the bridge and cancel latency, needs per-message POSTs; kept only as the framework's built-in fallback, not built. A raw `WebSock` handler: loses topics/serializer/ChannelTest for no gain. |
| 4 | **Reachability: the existing `tailscale serve` HTTPS endpoint.** Node must be on the tailnet (or an equivalent private overlay terminating TLS in front of loopback). Plain `http://` only to loopback. Public-internet exposure is refused by default. | Binding Arbiter off-loopback (breaks the loopback invariant `check_bind_address` guards); `tailscale funnel`/public tunnels (§4). |
| 5 | **Join token** `arbj_…`: single-use, 15 min default TTL, 256-bit, stored hashed; exchanged at `POST /nodes/enroll` for a **node credential** `arbn_<id>.<secret>`: long-lived, hashed at rest, revocable, rotatable, never accepted by any `/api` or `/mcp` route. | Reusing `Arbiter.MCP.Scope` signed tokens with a new tier (a signed blob cannot be revoked per node without a table, and every existing plug would parse it). |
| 6 | **Token never on argv, never in the pasted one-liner.** The one-liner carries no secret; the script reads the token from `/dev/tty` (or `ARB_JOIN_TOKEN` / `ARB_JOIN_TOKEN_FILE` for unattended use). | Token in the one-liner env prefix (lands in shell history); token in URL (server logs, history). |
| 7 | **The script checks prerequisites and refuses; it never sudo-installs.** It may do user-level fixes only (`loginctl enable-linger` for self). | Auto-installing packages with sudo (§5.5). |
| 8 | **Bridges: tunnel each per-run socket over the node channel** as multiplexed, credit-controlled streams. The agent listens on identically named unix sockets; the primary dials its own existing `Egress` listener for each stream. Egress policy, audit rows and `BridgeIdentity` do not change. | Per-run second WebSocket; agent-side proxy with uploaded audit (policy would leave the primary); direct TCP over the tailnet (needs an off-loopback listener). |
| 9 | **Checkout sync: agent pushes a git bundle** over HTTPS (`PUT /nodes/runs/:run/checkout`); the primary unbundles into a **quarantine bare repo** (fsck, ref allowlist, **primary-side** path filter) before touching the home clone. Seeding goes the other way as a thin bundle `GET`. | Smart-HTTP receive-pack (needs a git credential on the node, an http-backend process, and runs hooks surface); `git fetch` from the node's `.git` (touches untrusted repo state). |
| 10 | **A remote run does NOT survive a primary restart (v1).** It survives a *channel blip* up to a fence of 60 s. On any restart the agent quiesces the run and the primary **recovers** it (checkpoint pull) *before* `Reconciler` marks it interrupted and `ResumeGate` opens. | Survive-and-reattach (§10.4: needs worker adoption; and gains almost nothing because all network egress is on the primary). |
| 11 | **Liveness: 10 s heartbeat; agent self-fences at 60 s without an ack; primary declares the node lost at 90 s.** The invariant `fence < lost` replaces bd-aowisc's lease file. | Lease file touched over ssh. |
| 12 | **Capacity: effective `max_workers` = min(operator value, node's own ceiling); if neither is set, the node's suggestion.** `conductor.max_concurrent` stays operator-owned and is *not* auto-derived. | Auto-summing node capacity into `conductor.max_concurrent` (it is also the quota/billing valve). |
| 13 | **Executor boundary** (`Arbiter.Worker.Executor`, **new**) shrinks to eight callbacks and has **one** implementation, `Executor.Node`. A k8s controller pod is just another *agent* speaking the same protocol, so it needs no new Executor. | An Executor per backend. |
| 14 | **Breakdown: 15 children (numbered 1–14 plus 8a), none above D3**; child 1 commits this doc, child 2 is the go/no-go spike (§18). | — |

## 2. What carries over from bd-aowisc, and what does not

| bd-aowisc | Status | Note |
|---|---|---|
| §5 Runs that stay local (podman-only Claude implementer; local-only list; structural enforcement via `GitLayout.for_policy/1`, `Sandbox.module/2`; guard tests) | **Unchanged.** Read it as is. | Only the guard-test target changes: the spawn-site guard now covers `apps/arbiter/lib/arbiter/node_agent/**` (new) and the `Executor.Node` file; `NoPtyHandleTest`-style rule: nothing under `sessions/` may reference `Arbiter.Nodes` / `Executor`. |
| §4.4 Checkout of record: home clone / shadow clone, handoff rules, checkpoint, vetoes (submodules, LFS, 50 MB untracked cap) | **Unchanged model.** Transport replaced by bundles (§9); the exclude-file filtering is now enforced twice, with the primary authoritative. | |
| §4.9 Placement + per-node capacity after `Accounts.Admission` (two gates; eligibility first; modes `local_only/prefer_remote/remote_only`; `{:no_host_capacity, _}`) | **Unchanged**, `Host` → `Node`, `host` → `node`, plus node-reported capacity (§13). | |
| §6 Failure policy: lost node = `interrupted`, not `failed`, **no resume attempt consumed**; `:host_lost` classification | **Unchanged policy**; detection is heartbeat not ssh exit 255; renamed `:node_lost` (§10.3). | |
| §4.8 Install-scoped reaping (label `arbiter.install`, gated on `SingleInstance.primary?/1`, longer retention for remote leaves, `TestServices.reap_orphans/1` must not use `os_alive?/1` remotely) | **Unchanged in rule; mechanism moves** into the agent, driven by the primary's live set (§10.6). | |
| §7 `Executor` behaviour boundary | **Kept, reshaped** (§12). | |
| §4.2 path transparency; §4.2 memory cap via `podman run --memory/--memory-swap`, `OOMKilled` outcome without `--rm` | **Unchanged.** | The agent runs it locally instead of over ssh. |
| §2 executor shape (ssh exec), §3 `Host`+SSH config, §4.1 ssh wrapper/deadman, §4.6 `ssh -R`, §4.8 ssh recovery, §8 `arb hosts`, §9 children, §10 assumptions | **Replaced** by this document. | |
| §4.3 shadow clone via a `Host` interface (`cmd/read_file/write_file/lstat`) | **Dropped as a need.** The agent is local to the node, so `PrivateClone.build/1`, `PrivateClone.mounts/1`, `Container.argv/2` run unmodified there. | Removes bd-aowisc's largest refactor (parameterising `PrivateClone`/`Worktree` over a Host). |
| §4.5 warm repo + warm job + `warm_key` | **Replaced** by `DepsCache` on the node plus a bundle-fed object store (§7.3). | `DepsCache` now exists; the warm job is its `ensure/4`. |
| §4.11 "no standing secret on a host" | **Narrowed:** the node credential is a standing secret (one per node, 0600). Provider tokens and `worker_env` values are still per run, in memory (§11). | |

## 3. Roles and shape

```
 operator ──dashboard/CLI──► PRIMARY (Arbiter, loopback bind, unchanged)
                               │  tailscale serve  https://<host>.<tailnet>.ts.net  → 127.0.0.1:4848
        outbound only          ▼
 NODE: arbiter-node.service  ◄──── one WSS  /node/socket  (control + bridge streams)
   = Arbiter release, ARB_ROLE=agent          HTTPS /nodes/*  (enroll, tarball, bundles, files)
   podman (rootless) · git · shadow clones · deps cache · bridge listeners
```

New primary-side namespace **`Arbiter.Nodes`** (Ash domain, **new**): `Node`, `JoinToken`, `NodeEvent` resources; `Nodes.Registry`, `Nodes.Session` (one process per connected node), `Nodes.Placement`, `Nodes.Bridge`, `Nodes.Checkout`, `Nodes.Recovery`, `Nodes.RateLimit`, `Nodes.Credentials`. New web: `ArbiterWeb.NodeSocket`, `ArbiterWeb.NodeChannel`, `ArbiterWeb.NodeController`, `ArbiterWeb.Plugs.NodeAuth`, `ArbiterWeb.NodesLive`. New agent namespace **`Arbiter.NodeAgent`** (not `Arbiter.Agents`, which is the existing provider-adapter namespace: `agents/claude.ex`, `agents/codex.ex`, …; reusing the name would be a trap).

**Agent role boot.** `Arbiter.Application.start/2` and `ArbiterWeb.Application.start/2` begin with a positive role check (`:agent` → start only `Arbiter.NodeAgent.Supervisor`; `:primary` → today's list). This is **fail-closed**: a child added to the primary list later does not run in agent mode, because the agent returns its own list. `config/runtime.exs` also gates on the role: today it `raise`s without `SECRET_KEY_BASE` (line 28) and configures the Repo, none of which an agent has. `Arbiter.Extensions.load!/0` (first line of `Arbiter.Application.start/2`) is skipped in agent mode. The agent loads the `:arbiter` application's modules but does not start its supervision tree **[U5, U6]**. Measured sizes of the release today (`~/.arbiter/releases/v0.2.17-published`): 160 MB unpacked, 54 MB as `tar.gz`, of which `erts-16.4.0.2` is 76 MB and `lib/arbiter-0.2.17` 17 MB. Agent mode has no smaller artifact by design; the cost is one 54 MB download per node per version.

**Why the same release, not a second one.** It is the only way "the agent always matches the server version" is true by construction, and it makes the hardening builders (`Container.argv/2`: read-only root, dropped caps, `no-new-privileges`, `label=disable` only with bridges) run **on the node** from the identical code, which the SSH design had to re-implement or remote-control. The cost: agent mode is a role in a big release, so the role gate (child 5) and the DB-free audit of reused modules (U6, child 9) are real work.

## 4. Transport and reachability

### 4.1 Channel vs long-poll: decided, channel

* **Needs:** server→node assignments and cancels with low latency; node→server heartbeats, stdout lines, outcomes; and per-run **byte streams** for the bridges (§8) which are many, small, bidirectional writes.
* **Phoenix channel over WebSocket (chosen):** one connection carries all of it; `Phoenix.Socket.id/1` + `Endpoint.broadcast(id, "disconnect", _)` closes a revoked node's live socket at once **[U14]**; `Phoenix.ChannelTest` tests it with no network; binary frames are already used in this repo (`SessionChannel` `stdout`/`stdin` as `{:binary, frame}`, `Sessions.Frame` `<<"ARB1", seq::64, payload>>`, `max_frame_size: 1_048_576` on `/session`). WebSockets already traverse `tailscale serve` here: LiveView (`/live`) and `/session` run through it today (`docs/remote-access.md`), though I have not exercised a **non-dashboard path** or a long-idle socket **[U1]**.
* **Long-poll (rejected as the transport):** Phoenix's longpoll transport exists in the endpoint for `/live`, so the *server* half is free, but the bridge needs a request per direction per write burst; cancel latency is bounded by the poll cycle; and binary pushes would be base64-wrapped. It would be the right fallback for a network that blocks WebSocket upgrades. The tailnet path does not, so **not built in v1**; the channel module is transport-agnostic, so it can be added later without protocol change.
* **Agent-side WebSocket client:** there is no WS client in `deps/` (only `websock`/`websock_adapter`, server side; `mint` is present via Finch/Req). Plan: add `mint_web_socket` (small, on top of `mint`) and a ~300-line Phoenix V2-serializer client with reconnect/backoff/jitter (1 s → 30 s) **[U2]**. Alternatives (`slipstream`, `phoenix_gen_socket_client`) pull their own HTTP stacks.

### 4.2 Wire protocol (sketch; proto version 1)

`NodeSocket.connect/3` takes params `token` (node credential), `proto`, `agent_version`; rejects on any credential failure; `id/1` = `"node_socket:<node_id>"`. Topic `node:<node_id>`; a node can only join its own. Control events are JSON; byte payloads are binary frames with the existing `ARB1` seq header (the seq domain is per stream).

| Direction | Event | Payload (essentials) |
|---|---|---|
| node→primary | `hello` | agent version, proto, arch, `caps` (`backend: podman`, `bundle`, `bridge_streams`, `image: build\|pull`), capacity facts (cpus, mem), node-set ceiling, **inventory**: live runs (id, container state, stdout offset), retained shadows, images, deps-cache keys, readiness report (`PodmanReadiness.diagnose/1` + prereq checks) |
| primary→node | `hello_ok` | primary `boot_epoch` (random per BEAM start), `fence_after`, `hb_interval`, effective `max_workers`, per-run "I know this run: yes/no" verdicts, optional `upgrade` |
| node→primary | `hb` (every 10 s) | per-run state + `stdout_seq`, load, free mem; reply `hb_ack` (cumulative acks) |
| primary→node | `assign` | the **run spec** (§7.1) incl. per-run secrets (in memory only); `cancel{run, reason, collect?}`; `reap{live_set}`; `rotate`; `upgrade{version, sha256}`; `drain` |
| node→primary | `stdout` (binary) | `ARB1` frame of line records; primary `ack`s cumulative offsets |
| node→primary | `exit` | status, `oom?`, container id; `checkpoint{run, bundle_ref}`; `bridge.open{run, name, stream}` / `bridge.data` / `bridge.close` / `bridge.credit` (both directions) |

Backpressure: Phoenix channels have none, so streams use a credit window (256 KiB per stream, 16 KiB frames, max 64 streams per run and 256 per node, total in-flight per node capped at 1 MiB). Stdout replay after a blip uses the offset+ack scheme `Sessions.Stream` already uses.

**Single socket vs two:** one socket with credits. The risk is bridge traffic starving the heartbeat; fence/lost thresholds (60/90 s) leave 30 s of slack and the spike measures jitter under a 5 MB push **[U4]**. Fallback if it fails: a second socket for bridge data only (same credential, no protocol change).

### 4.3 Reachability

* Arbiter binds `127.0.0.1:4848`; `ArbiterWeb.Boot.BindAddressCheck` warns at boot on `ARB_BIND_ADDRESS` off-loopback, and `arb server doctor`'s `check_bind_address` (`arbiter_cli/.../doctor/checks.ex`, via `GET /api/server/bind_address`) reports a non-loopback bind as `:fail` (non-fatal, informational). That invariant is kept. **Nodes do not need an off-loopback listener.**
* **Required of a node (the expected path):** it is a member of the same tailnet as the primary (tailscaled up, MagicDNS resolving `<primary>.<tailnet>.ts.net`) and can open outbound HTTPS/443 to it. `tailscale serve` terminates TLS with a publicly trusted certificate, so the node needs only the system CA store. The primary must run `tailscale serve --https=443 http://127.0.0.1:4848` (already the dashboard setup, `docs/remote-access.md`). Nothing inbound is needed on the node. Beyond the primary, the node needs outbound access for image builds/pulls (registries, distro mirrors) and nothing else: **no forge access** (checkouts arrive as bundles; pushes go through the primary's egress proxy).
* **Recommended hardening:** tailnet ACL tags (`tag:arbiter-node` → `tag:arbiter-primary:443` only). Optional: `tailscale serve --set-path` to expose only `/nodes` and `/node/socket` rather than the whole app **[U1]**; today `serve` proxies *every* route to the tailnet (dashboard and `/api` stay protected by their own auth; `ApiAuth` answers 401 to anything without a valid token). A new doctor check, `nodes.public_url reachable`, does an anonymous `GET /nodes/ping` against the configured URL (new setting `nodes.public_url`, an `Arbiter.Settings.Installation` field).
* **Is a non-tailnet path ever acceptable? Yes, three, and one no:**
  1. **Loopback**, for a same-host agent (dev, CI, and "the primary also runs a node" test rig). The agent accepts `http://` **only** for loopback hosts.
  2. **Any private overlay with TLS in front of loopback** (Headscale, a WireGuard mesh behind a reverse proxy with a valid certificate, Nebula/ZeroTier + proxy). Equivalent security; the agent only requires `https` with a verified chain (system CAs, or a pinned CA bundle path/fingerprint passed at install).
  3. **A node-owner-managed `ssh -L 4848:127.0.0.1:4848 primary`**, giving the node `http://127.0.0.1:4848`. Acceptable (ssh provides auth and encryption); the node credential still gates everything. It is the SSH-bastion fallback without any SSH code in Arbiter.
  4. **Public internet exposure (`tailscale funnel`, a public tunnel, a port-forward): refused by default.** The whole app's surface (login page, `/api/version`, the `/live` socket) would be internet-reachable and node enrollment would be internet-facing. Allowed only with `nodes.allow_public_endpoint: true`, which adds a permanent doctor warning and requires the rate limiter keyed on the forwarded client address. Doctor detects it heuristically (URL host not `*.ts.net`, not RFC 1918/CGNAT/ULA/loopback) **[U20]**.

## 5. Enrollment, identity and the join script

### 5.1 Join token lifecycle

1. Operator clicks **Add node** (dashboard, behind `DashboardAuth`) or runs `arb node add` (operator-proof token, §5.4). The primary creates a `JoinToken` row (**new**): `id`, `sha256(secret)`, `expires_at` (default 15 min; `--ttl` max 24 h), optional pre-bound `name`/`labels`/`max_workers`, `created_by` actor label, `used_at`, `used_by_node`. The secret is `arbj_` + 52 base32 chars (256 bits) and is shown **once**. Persisted (not in-memory like `DashboardAuth.LoginTokens`' 120 s ETS) because the audit trail must show minted/expired/used and a 15-minute window should survive a restart.
2. Redemption is a **single atomic conditional update** on SQLite (`UPDATE … SET used_at = now WHERE hash = ? AND used_at IS NULL AND expires_at > now`, checking rows affected), not read-then-write: SQLite's single writer makes it atomic, but note that `Ash.transact` does not roll back under the test sandbox, so the guard must be the conditional update itself **[U15]**.
3. Wrong/expired/used token → one generic `401` (no oracle distinguishing the three), counted by the rate limiter, audited as `join_failed`.

### 5.2 Node credential

* `POST /nodes/enroll` (anonymous route, token in the JSON **body**, never a header or URL) returns `{node_id, credential, ws_url, agent_version, tarball_sha256, fence_after, …}`. The credential is `arbn_<node_id>.<secret>`; the DB stores only `sha256(secret)` and a short display prefix; lookup is by the embedded id, compare with `Plug.Crypto.secure_compare/2`. 256-bit random makes a fast hash appropriate.
* **Lifecycle:** soft rotation every 30 days over the channel (`rotate` → new secret; old valid for a 10-minute overlap; the agent persists the new one *before* acking); **revoke** = state `revoked`, hash cleared, `Endpoint.broadcast("node_socket:<id>", "disconnect", %{})`; **remove** = delete row (only when revoked/offline and no live runs; history stays in `NodeEvent`).
* The agent stores it at `~/.config/arbiter-node/credential` (0600, dir 0700). It is the **only secret at rest** on a node.

### 5.3 A new auth tier, structurally separate

* Node credentials are **not** `Arbiter.MCP.Scope` tokens. `Scope.from_token/1` (`mcp/scope.ex:253`) verifies a signed blob (`MCP.verify/1`); an `arbn_…` string fails verification, so `ArbiterWeb.Plugs.ApiAuth` answers 401 "Invalid Bearer token" on every `/api` route and `ArbiterWeb.MCP.Plug` on `/mcp`, with no code change. There is no path from a node credential to the `:coordinator`/`:worker`/`:refine` tiers.
* Node routes live **outside `/api`** (`/nodes/*`, `/node/socket`), under their own pipeline with `ArbiterWeb.Plugs.NodeAuth` (**new**). `ArbiterWeb.ApiPolicyTest` iterates the router and fails on an unclassified `/api` route, so keeping them out of `/api` avoids a bogus policy entry and keeps the two tables disjoint.
* **Run-scoped authorization:** every `/nodes/runs/:run/*` request and every `bridge.open` checks that the run is **assigned to the calling node** and live. A compromised node cannot touch another node's run or a run it was never given.
* `ArbiterWeb.Plugs.WorkerBridge` only admits `/api` and `/mcp` (`@allowed_prefixes`) for a jailed worker's bridge, so **a worker cannot reach `/nodes/*`** through its bridge either.
* **Guard tests (child 3):** (a) every `/api` and `/mcp` route with a node credential → 401; (b) every `/nodes/*` route and the socket with each `Scope` tier's token → 401; (c) a join token cannot open the socket, a node credential cannot enroll.
* New `ApiPolicy` policy **`:operator`** (**new**; `Scope.operator?/1` at `scope.ex:233` exists, no policy uses it yet) for node administration over REST (`POST /api/nodes/join-tokens`, drain, revoke, remove): the operator-proof coordinator token only, so a coordinator *session* (an LLM) cannot enroll machines that will receive provider tokens. Read routes (`GET /api/nodes`) are `:coordinator`.

### 5.4 Rate limiting and audit

* No limiter exists in the repo (`Arbiter.GitHub.Limiter` budgets GitHub calls only; no Hammer/PlugAttack dep). **New** `Nodes.RateLimit`: an ETS token bucket, no dependency. `POST /nodes/enroll`: 10 attempts/min globally and 5 *failures*/10 min per source key; behind `tailscale serve` every peer is 127.0.0.1, so the key is serve's `X-Forwarded-For` only when the peer is loopback (the same condition `DashboardAuth.Default` uses for Tailscale headers), else the peer address. Excess → `429` + `Retry-After`. Minting: 20/hour per actor. Socket `connect/3` failures: 30/min global. 256-bit tokens make brute force infeasible; the limiter is for resource exhaustion and log noise.
* **Audit:** a dedicated append-only `NodeEvent` table (**new**): `token_minted`, `join_failed`, `enrolled`, `connected`, `disconnected`, `rotated`, `drained`, `revoked`, `removed`, `upgraded`, `fenced`, `node_lost`; columns `node_id?`, `kind`, `actor` (`Arbiter.Actor.label/1`, with a new `:node` kind: `node:<name>`), `detail` map, `remote_addr_hint`, `at`. Chosen over PaperTrail on `Node` because versions would snapshot credential-hash columns and `AuditLogLive` reads only `Arbiter.Tasks.Issue.Version` (`audit_log_live.ex:77,258`), so a PaperTrail resource would not show on `/audit` anyway. Surfacing `NodeEvent` on `/audit` is a follow-up; v1 shows it on the node detail page.

### 5.5 The join script

`curl --proto '=https' --tlsv1.2 -fsSL <public_url>/nodes/join | bash` (the dashboard shows exactly this, with a copy button and the token separately, below).

**Token handling (off argv, out of history):**
1. The one-liner contains **no secret**. The script reads the token with `read -rs </dev/tty` (stdin is the pipe), so it is neither in history nor argv nor the environment of a long-lived process.
2. Unattended installs (cloud-init, Ansible): `ARB_JOIN_TOKEN_FILE=/path` (0600) or `ARB_JOIN_TOKEN` in the environment; documented as history-visible when typed interactively.
3. The token is sent only in the enroll **request body**, from stdin (`curl --data-binary @-`), and any header-bearing call uses `curl -K -` (config on stdin), so nothing secret appears in `/proc/<pid>/cmdline`. After enrollment the script uses the node credential, never the join token again.

**Script hygiene:** whole body inside `main() { … }` invoked on the **last line** (a truncated pipe executes nothing); `set -euo pipefail`; `umask 077`; `mktemp -d` under `$XDG_RUNTIME_DIR`, `trap` cleanup; `https` only; prints the plan before acting; idempotent (a re-run with a *new* token re-enrolls and repairs); `ARB_JOIN_CHECK_ONLY=1` runs the checks and exits without consuming a token; refuses to run as root (rootless podman requires an unprivileged user). The template is rendered server-side from config (URL, expected arch, min podman major, proto) and tested with `shellcheck` plus a test that asserts no executed `sudo`.

**Prerequisite checks (all before the token is exchanged, so a failing machine does not burn it):** Linux, `uname -m` equals the release arch (x86_64 today **[U11]**), glibc ≥ 2.28 (the ubi8 baseline `scripts/check-release-glibc.sh` enforces), `curl`/`tar`/`sha256sum`/`git`, `podman` ≥ 4 with `podman info` reporting rootless, `/etc/subuid`+`subgid` ranges ≥ 65 536 (same thresholds as `PodmanReadiness`), **cgroup v2** (`stat -fc %T /sys/fs/cgroup` = `cgroup2fs`) **with the `memory` controller delegated to the user** (read the user slice's `cgroup.controllers`; needed for `--memory`; **[U10]**), **linger** enabled (`loginctl show-user`), a reachable user systemd (`systemctl --user`, `XDG_RUNTIME_DIR`), free disk ≥ N GB under the node root. The agent re-runs `PodmanReadiness.diagnose/1` plus these at start and reports them in `hello`.

**Refuse versus sudo-install: refuse is right.** (1) `curl | bash` is already a maximal-trust action; adding privilege escalation multiplies the blast radius of a compromised or truncated script. (2) Package names, repos and cgroup delegation differ per distro; an installer that guesses wrong leaves a half-configured host. (3) Unattended sudo prompts break in a pipe and in cloud-init. (4) The operator already owns the host and can run the printed remediation. The script prints a copy-pasteable remediation list (for example `sudo dnf install podman`, `sudo loginctl enable-linger $USER`, a `systemd` `Delegate=` drop-in for `user@.service`) and exits non-zero. **One exception, user-level and no sudo:** if linger is off it tries `loginctl enable-linger "$USER"` (the same call `Systemctl.enable_linger/0` makes in `arb install-service`) and refuses with instructions only if that is denied **[U9]**.

**Install steps:** enroll → store credential → `GET /nodes/agent/<version>.tar.gz` with the credential (sha256 checked against the enroll response) → unpack to `~/.arbiter-node/releases/<version>/`, atomic `current` symlink (the same symlink-then-rename `ReleaseFiles` uses) → write `~/.config/arbiter-node/agent.env` and `~/.config/systemd/user/arbiter-node.service` (`Restart=always`, `ExecStart=%h/.arbiter-node/current/bin/arbiter start`, `Environment=ARB_ROLE=agent`) → `systemctl --user enable --now` → wait for the first `hello` (poll `~/.arbiter-node/bin/arbiter-node status`) and print the result. The data dir is `~/.arbiter-node/`, deliberately not `~/.arbiter/` (the primary's default data home), so a test node on the primary's machine cannot collide. The wrapper `arbiter-node` has `status | logs | leave` (`leave` asks the primary to remove the node, then stops and disables the unit).

### 5.6 CLI equivalent

`arb node add [--name N] [--label k=v …] [--max-workers N] [--ttl 15m]` (operator-proof) prints the one-liner and the token (token to stdout only on a TTY, otherwise `--token-file`); `arb node list|show|drain|undrain|revoke|remove|set <name>`; `arb node events <name>`. On the node: `arbiter-node status|logs|leave`. `arb` has no `node` command today; `Cmd.Server` dispatch and `Main`'s alias table are where it lands.

## 6. Agent packaging, versioning and upgrade

**Artifact.** The agent is the release tarball the primary is running. The primary serves it: `GET /nodes/agent/<version>.tar.gz` (node credential; the enroll response carries the expected sha256).
* **Source of the bytes.** Today `ArbiterCli.Cmd.ReleaseDeploy` holds the downloaded tarball in memory (`Github.download_binary/1`, `release_deploy.ex:208`), verifies the `.sha256`, and unpacks it (`ReleaseFiles.unpack!/2`); it keeps no tarball. Change (child 4): retain `<data-home>/releases/<tag>.tar.gz` + `.sha256` next to the unpacked tree and prune with it (`ReleaseFiles.prune_old_releases/3`). Serving the **pristine** published bytes means the checksum equals the published `.sha256`. For `arb server deploy --local <dir>` (no tarball exists) the primary packs the tree on first request with an **allowlist** (`bin/`, `erts-*`, `lib/`, `releases/<vsn>/` minus `COOKIE`/`tmp`), never a denylist, and caches by sha. Rejected: nodes downloading from GitHub Releases (a private repo needs `GITHUB_TOKEN` on every node; a local build is not published).
* **Platform.** `.github/workflows/release.yml` builds one `arbiter-<tag>-linux.tar.gz` on `ubuntu-latest` inside `redhat/ubi8` (glibc 2.28 baseline, enforced by `scripts/check-release-glibc.sh`); I found no arm64 job **[U11]**. So v1 nodes are x86_64 Linux and the join script refuses anything else. A second release job is a separate ticket.
* **Integrity.** Trust root is TLS to the primary; the sha256 detects corruption/truncation, not a malicious primary. No code signing in v1 (a compromised primary can already do anything to its nodes; §15).

**Version identity.** `hello` carries `agent_version` (`Arbiter.Version.app_version/0`) and an integer `proto`. The **bootstrap subset** of the protocol (`hello`, `hello_ok`, `hb`, `hb_ack`, `upgrade`, `drain`, `rotate`) is frozen across all versions, so any agent can always be told to move to any version, including an *older* one after `arb server deploy` auto-rolls back. Everything else (assign, bridge, checkout) is gated by `proto`.

**Skew rules** (the primary decides on `hello`; node health in the UI is one of `ready | outdated | incompatible | ahead`):

| Agent vs primary | Health | New assignments | In-flight runs | Action |
|---|---|---|---|---|
| same version | `ready` | yes | yes | none |
| same `proto`, different version | `outdated` | **no** unless `nodes.allow_skew` (default off) | continue | auto-upgrade when idle |
| agent `proto` < primary's `min_proto` | `incompatible` | no | continue until idle, then refused | bootstrap `upgrade` still works; else "re-run the join script" |
| agent newer than primary (after a rollback) | `ahead` | no | continue | primary sends `upgrade` to its own version (downgrade) |

Why exact-match by default: the agent embeds `Container`, `PrivateClone`, `DepsCache` and the run-spec decoder; a skewed agent would build a different container than the primary's tests assume. `allow_skew` exists for an operator who needs to keep working through a bad deploy.

**Upgrade flow when the server is redeployed.**
1. `arb server deploy` swaps the primary; agents see the socket drop and reconnect (backoff 1 s → 30 s with jitter).
2. `hello` shows the old version; `hello_ok` carries `upgrade{version, sha256}` and the node becomes `outdated`, so no new runs land on it. It therefore drains by itself.
3. The agent downloads the tarball to `~/.arbiter-node/releases/<v>/`, verifies sha256 (refuses on mismatch), **waits until it has no live runs** (policy `auto_upgrade: when_idle`, default; `manual` shows an **Upgrade** button / `arb node upgrade <name>`), writes `upgrade.pending` (prior target + time), atomically flips `current`, and exits; systemd (`Restart=always`) starts the new release.
4. The new agent writes `confirmed` after its first `hello_ok`. The unit's `ExecStartPre` restores the previous `current` if `upgrade.pending` is older than 3 minutes with no `confirmed`. Two releases are retained.
5. A `NodeEvent` `upgraded{from,to}` is recorded.

A deploy that crosses a primary migration needs nothing special on nodes (they hold no database).

## 7. The run on a node (what changes in spawn, teardown, memory, services)

### 7.1 The agent builds the container from a **spec**, not an argv

The primary never sends a `podman` argv. Today `ContainerSpawn.prepare/1` returns a request map (`name`, `image`, `mounts`, `home`, `config_dir`, `network`, `env`, `pod`, `deps_cache`) consumed by `wrap_port/1` → `Container.wrap/2` → `Container.argv/2`. For a remote run the primary sends the **declarative spec** and the agent calls `Container.argv/2` itself, with host paths it resolves from its own layout:

* `image` (content-hash tag), `name`/labels (`arbiter.install`, `arbiter.node`, `arbiter.run`, `arbiter.task`), mounts as **kinds** (`worktree`, `run_home`, `config_dir`, `cli`, `objects_overlay`, `prompt`, `bridge:<name>`), container-side paths **equal to the primary's** (path transparency, bd-aowisc §4.2, unchanged: `claude --resume` keys its session store on the cwd slug, `Usage.ClaudeSessionFile.project_slug/1`), env names + values (secrets flagged), resource limits, bridge list, test-services definition, the command (`claude` argv incl. prompt).
* **Why spec, not argv:** the agent can refuse what it does not build. Its allowlist: mounts only under its own root, no `--privileged`, `--cap-add`, `--device`, `--userns=host`, `--pid=host`, `--network=host`. A compromised or mistaken primary then cannot turn the node into an arbitrary-container host, and the hardening (read-only root, dropped caps, `no-new-privileges`, `label=disable` only with bridges) is the *same code* as local.
* `ContainerSpawn.prepare/1` splits into a primary half (secret resolution, worker-tier token mint, `Egress.JailRun.start/1`, spec assembly) and a node half (shadow clone, image/CLI/deps, run dirs, listeners). The existing request map's `inherit_env` (names whose values ride the client's environment so they never hit argv) is exactly the secret list.

### 7.2 Port-shaped handle in `Arbiter.Worker`

`Worker` is Port-owned. The surface a remote run must satisfy is small and grep-verified: the three `handle_info({port, …})` clauses (`worker.ex:2844` eol, `:2848` noeol, `:2852` exit_status, all `when is_port(port)`), and the port-specific sites: private `terminate_session_port/2` (`safe_port_os_pid/1` at `:3605`, `OsProcess.kill_tree/1`, `Port.close/1` at `:3593`) and private `session_live?/1` (`:8232`, `is_port(port) and Port.info(port) != nil`). `ClaudeSession.open_scoped_port/2` (`claude_session.ex:1995`) is the single open point. Design: `Executor.Node.open/1` returns a **remote handle** (a `{:remote, ref}` tuple) and the `Nodes.Session` process sends `{handle, {:data, {:eol, line}}}`, `{handle, {:data, {:noeol, partial}}}` and `{handle, {:exit_status, n}}` with the same shapes (the line framing is `{:line, 65_536}` today, `open_port/1`). The guards relax to `is_port(p) or match?({:remote, _}, p)`; those two functions branch. **Rejected:** a local shim OS process that echoes channel data into a real Port (the Port owner is the Worker, so the relay cannot `Port.command`; needs FIFOs and exit-status gymnastics for no benefit).

### 7.3 Images, CLI binaries, deps cache (replaces bd-aowisc's warm repo)

* **Images.** Tags are content hashes of a digest-pinned Containerfile plus build args (`Image.plan/3`, `Image.Builder.ensure/3`; empty build context). The primary ships the **plan** (pinned Containerfile text, args, tag), and the node builds it with its own podman and verifies the resulting tag name. Measured sizes on this host: toolchain image 843 MB, of which the base is 464 MB. `podman save | load` through the primary would move 0.5–1 GB per toolchain per node and again whenever the weekly base refresh moves the tag. Chosen: **build from plan** (public upstream images only, deterministic inputs); `save`/`load` over HTTPS as an opt-in fallback for air-gapped nodes. Cost: first dispatch to a fresh node waits for a build **[U12]**; `ensure_ready` is synchronous with a bounded timeout and then `prefer_remote` falls back to local, `remote_only` holds the card.
* **CLI binaries.** `claude` and `arb` are mounted read-only at `/opt/arbiter/cli` today (private `ContainerSpawn.cli_mounts/1`). The primary exposes them content-addressed: `GET /nodes/files/<sha256>`; the node caches under `root/files/<sha12>/` and verifies the hash. Same-arch constraint as §6.
* **Deps cache.** `DepsCache` (`key/4`: `<root>/<lock12>-<image12>`; `ensure/4` runs a seed job inside the image; `install/3` does `cp -a --reflink`) is a *node-local* concern now: the agent runs it against its own root and podman. Inputs it needs from the primary (it must not read the primary's DB; `DepsCache` aliases `Arbiter.Mergers`, **[U6]**): the default-branch `mix.lock` hash, `seed_paths` resolved by `Worker.SeedPaths.resolve/2`, and the default-branch tree as a bundle (below). **The "warm repo" is gone**; what remains is a per-node bare **object store** `root/repos/<slug>.git` that bundles fetch into and shadow clones borrow from (alternates + `:O` overlay), exactly as `PrivateClone.mounts/1` already guards for the local main repo.
* **Thin home clone for remote placement.** For a remote-placed run the primary provisions the home clone **without** `seed_compiled_deps/3` and `ensure_deps_fetched/1` (`PrivateClone.provision/1` calls both at `private_clone.ex:231-232`), via a `seed: false` option threaded through `Worktree.create/4`. Otherwise the primary pays the cost remote exists to avoid.

### 7.4 Teardown and memory cap (bd-aowisc §4.2 carries over)

`podman run --memory=<cap> --memory-swap=<cap>` (plus optional `--cpus`) replaces `MemoryScope`, which is a local systemd-scope construct and does not cover a container (`ClaudeSession.open_scoped_port/2` skips it for podman). `Container.argv/2` gains four **additive, pure** options (child 8a, also usable locally): mount mapping, `--memory/--memory-swap/--cpus`, `--label` pairs, omit `--rm` (so `.State.OOMKilled` survives; `StopReason.classify/3` and the private `Worker.mark_memory_cap/2` (`worker.ex:2706`) already consume an OOM outcome). The `exit` event carries `oom?` and the container exit code. Teardown by name (`Container.stop/2`, `TestServices.teardown/2`) now runs **locally on the node**, driven by `cancel`; the primary no longer needs a control channel to do it. The node-side cap default is a percentage of the node's `MemTotal` (e.g. 40 %), reported by `hello`. A node that cannot enforce `--memory` (no memory controller delegated) reports `degraded: :uncapped` and is excluded from placement unless the operator sets `allow_uncapped` (fail-closed, as in bd-aowisc: the cap protects the node's owner).

### 7.5 Test-services pods

Same host as the worker container (shared network namespace), so the agent starts them locally with `TestServices.start/1` and tears them down with `teardown/2`. The pod label gains the run id and node id (today it carries only the server's OS pid; `TestServices.reap_orphans/1` decides orphan-ness with `os_alive?/1` against `/proc`, which is meaningless for a different host). The agent only reaps pods whose `arbiter.node` is its own and whose run the primary's live set (§10.6) does not list.

### 7.6 Streams, transcripts, logs

* `OutputLog`/`PromptLog` stay primary-side, written from the stdout frames. `stdout` is retained on the node in an offset-addressed file per run until acked (cap 64 MiB; when full the agent stops reading the container's stdout, which blocks the container: that is a stall, not a loss).
* **Session JSONL lives on the node** in the per-run config dir. At exit and each checkpoint the agent uploads `projects/**` as a tar (`PUT /nodes/runs/:run/transcripts`); the primary extracts into `run.config_dir` (same path, so `Usage.ClaudeSessionFile.locate/2`, `SessionArchive.archive_run/2`, `Workers.StepBackfill`, `Usage.LiveSpend` need no change) with a **sanitising extractor**: regular files only, no absolute or `..` paths, no links, `*.jsonl` under `projects/` and `subagents/` only, byte cap. Live spend while a remote run is in flight comes from the stdout stream the Worker already parses.

## 8. Bridges (replaces `ssh -R`)

**Today:** `Egress.JailRun.start/1` starts, per worker, a filtering proxy plus fixed-target bridges as unix listeners under `Egress.socket_dir/0` (`<run>.proxy.sock`, `<run>.<name>.sock`); the container reaches them through bind-mounted sockets and in-container `socat` (`Jail.network_command/2`). `Egress.Forward.run/4` dials the target and registers its own upstream connection with `Egress.BridgeIdentity` so `ArbiterWeb.Plugs.WorkerBridge` can pin a request to the run. Identity depends on the primary-opened connection, not on who holds the unix socket (bd-aowisc §1).

**Chosen: tunnel each per-run socket over the node channel as multiplexed streams.**
* On the node the agent creates the **same-named** unix listeners in the per-run dir (0700) and bind-mounts them at the **primary's** socket paths in the container, so `Jail.network_spec/1`/`network_env/1`/`network_command/2` output is byte-identical (path transparency; path length ≤ 100 bytes is validated at enroll time from `root`).
* Each accepted connection opens a logical stream: `bridge.open{run, name, stream}`. The primary's `Nodes.Bridge` (**new**) checks the run is assigned to this node, then **dials the primary's own existing unix listener** `Egress.socket_path(run_id)`/`Egress.bridge_path(run_id, name)` and relays frames. From there nothing is new: the proxy decides, `Egress.Audit`/`egress_events` record, and `Forward.run/4` registers the identity for the Arbiter bridge. **The egress code, policy, audit and `BridgeIdentity` are untouched.**
* Flow control: credits per stream (256 KiB window, 16 KiB frames, §4.2); half-close and reset are explicit events; a stream dies with its run or its socket; the node's streams die and are not resumed on a socket drop (the in-container client reconnects).

**Rejected:**
* *Second WebSocket per run*: more sockets and a second authentication surface for identical cost.
* *Egress proxy running on the node, audit uploaded*: policy and learn-mode state would leave the primary, and a compromised node could rewrite them.
* *Direct TCP from the node to a primary listener*: needs an off-loopback listener (§4.3).
* *Keep `ssh -R`*: operator direction.

**Cost (estimates, not measurements; [U3] measures them):**
* Latency: each new proxied connection pays one node↔primary RTT for the `CONNECT` answer, and each TLS handshake round trip (the handshake is end to end through the tunnel) pays RTT_np in addition to RTT_primary↔API. Over a tailnet RTT_np is roughly 1–30 ms direct, 50–150 ms via a DERP relay. The CLI holds long-lived connections to the model API, so the per-turn overhead is about one RTT_np on time-to-first-token against model latency measured in seconds. `arb`/MCP calls are small JSON, tens of ms.
* Throughput: model SSE is KB/s; the heavy case is a `git push` through the proxy (MBs) and anything a worker pulls through the allowlist. A tailnet link sustains far more than these; the 1 MiB per-node in-flight cap bounds memory on the primary.
* Primary CPU: one extra relay hop and frame codec per stream. Acceptance criteria for the spike (§18, child 2): added p99 latency ≤ 250 ms at 10 concurrent runs over a replay of a recorded SSE stream, and heartbeat jitter < 5 s during a 5 MB push.
* Failure: if the socket drops, every bridge stream for the node is cut; the Claude CLI's own retry rides through a drop shorter than the fence (§10.2) if it retries a refused local socket **[U19]**.

## 9. Checkout sync (replaces `git fetch` over ssh)

The home/shadow model (bd-aowisc §4.4) is unchanged: while a container runs the shadow clone on the node is the sole writer; at every other moment the home clone is authoritative and no host-side code reads the shadow. Only the transport changes, to **bundles over HTTPS**.

**Seed (primary → node).** On `assign` the node reports `have: [sha…]` (tips in its object store). The primary builds a thin bundle: `git bundle create - <tips> ^<have…>` from the home clone/main repo (full bundle when `have` is empty or contains unknown shas), and the node `GET /nodes/runs/:run/seed.bundle` and `git fetch`es it into `root/repos/<slug>.git` under `refs/arbiter/in/<run>/*`, then builds the shadow with the existing `PrivateClone.build/1` locally. Measured on this repo: the pack is 29.6 MB, a full bundle of five weeks of history is 15.6 MB, so the first dispatch to a node is a one-time tens of MB.

**Pull-back (node → primary) at port exit, at every checkpoint (default 5 min), and in recovery.** On the node, inside the shadow: write the snapshot commit with a temporary index (`GIT_INDEX_FILE=<tmp> git add -A && git write-tree && git commit-tree -p HEAD`) to `refs/arbiter/snapshot/<run>`, honouring `.git/info/exclude`, then `git bundle create` of the branch, the snapshot ref and the clone's remote-tracking branch with prerequisites `^<known>` where `known` is what the primary told it at seed. `PUT /nodes/runs/:run/checkout` with `Content-Length` (cap, default 256 MiB; snapshot untracked payload cap stays 50 MB with a placement veto from bd-aowisc §4.4).

**Ingest on the primary (`Nodes.Checkout`, new): a quarantine, in this order:**
1. Stream the body to a private scratch file; enforce the size cap; verify the run is assigned to the caller and live.
2. `git bundle verify`, then fetch into a **throwaway bare repo** (`git init --bare`, `fetch.fsckObjects=true`, `transfer.fsckObjects=true`, `core.hooksPath=/dev/null`), refspec limited to the **ref allowlist**: `refs/heads/<run branch>`, `refs/arbiter/snapshot/<run>`, `refs/remotes/origin/<branch>`. Any other ref, or a ref pointing outside the expected namespace, rejects the whole bundle **[U7: fsck on bundle fetch]**.
3. Object-count/size bounds via `rev-list --objects`.
4. **Primary-side path filter (authoritative):** the snapshot tree is checked against the primary's own deny list: the `@ignored_artifact_paths` set in `Worktree` (`.mcp.json`, `.gemini/`, `.codex/`, `.arbiter/`, `deps`, `_build`, …) plus the run's recorded seeded paths (`Worktree`'s private seed record reader `seeded_paths/1`). Matching paths are removed from the index before any checkout. The node-side exclude file is only a bandwidth optimisation: it lives in the shadow's `.git`, which the container can write, so a compromised agent run could hide or add files by editing it.
5. Only then: fetch from the quarantine repo into the home clone and apply the existing handoff (force the branch to the fetched tip, `git read-tree -u --reset <snapshot>` + `git reset --mixed <tip>` so changes read as uncommitted to `Worktree.has_uncommitted?/1`; record `{head_sha, status_hash}`), and proceed with `commit_gate/1`, `Worktree.sync_back/1`, ReviewGate, MergeQueue unchanged.

**This is stricter than local.** A bundle carries objects and refs only: **no config, hooks, `info/`, alternates or any other `.git` file** ever reaches the primary, and the primary's git never reads the container-writable `.git` of the shadow. Locally today the host git reads the private clone directly under the `PrivateClone.mounts/1` guards.

**Rejected:** *smart-HTTP receive-pack* (a git credential on the node's disk or argv, an `http-backend`/`receive-pack` process to run and sandbox, ref negotiation we do not need for a one-way snapshot); *fetching from the node's `.git` over any channel* (touches untrusted repo state); *rsync/tar of the tree* (loses commits/rename detection, no fsck).

## 10. Liveness, restart and reconciliation

### 10.1 Heartbeat, fence and lost (replaces the lease file)

* `hb` every 10 s with per-run state and `stdout_seq`; `hb_ack` carries cumulative acks. The primary marks a node **suspect** after 30 s of silence.
* **Agent self-fence:** if the agent has not received a `hb_ack` for `fence_after` (60 s, set by the primary in `hello_ok`, bounded 30–300 s), it stops its containers (`Container.stop/2`), keeps the shadow clone and transcripts on disk, and keeps trying to reconnect.
* **Primary declares the node lost at 90 s** (`lost_after = fence_after + 30`). **Invariant: `fence_after < lost_after`**, with slack for clock skew, so by the time the primary re-dispatches elsewhere the old container is already stopped. Each side uses its own monotonic clock; neither depends on a shared clock. A node that is dead (not partitioned) has no container to worry about.
* `fence_after`, `lost_after` and `hb_interval` are install settings (`nodes.fence_after_s`, …) validated for the invariant.

### 10.2 Channel blip (survives) versus restart (does not)

A socket drop shorter than `fence_after` with an unchanged primary `boot_epoch` is a **blip**: the primary's `Worker` process is alive (its remote handle is held by `Nodes.Session`, whose state is the run table), the container keeps running (stalled only for bridged network), and on reconnect the node resends unacked stdout from the last acked offset and re-listens bridges. No state is lost. Worker output lines are never dropped and never duplicated (offset+ack, the `Sessions.Stream` scheme).

### 10.3 Node lost

`Nodes.Session` gives up (`lost_after`) → every run on it is stamped **interrupted** ("node lost: <name>"), **not failed**, and **no resume attempt is consumed** (the policy `Reconciler` applies to "server shutdown" runs, `reconcile_shutdown_casualties/1`). New classification `:node_lost` in `StopReason.classify/3` (`stop_reason.ex:456`) distinguishes it from an ordinary agent failure. The node is marked offline; auto-resume re-dispatches via `Placement` (another node or local per mode); the new spawn builds a fresh shadow from the home clone and `claude --resume` finds the mirrored transcript at the same cwd slug (bd-aowisc §6.2). Work since the last checkpoint is lost unless the node returns (below). One coordinator escalation per outage over 15 min, not per tick (`Messages.Escalation`).

**Improvement over SSH:** a returning node reports its **retained** shadows/transcripts in `hello`; the primary may pull them as a *salvage* ref (`refs/arbiter/salvage/<run>` in the main repo) instead of leaving them for a human. Optional hardening child.

### 10.4 Does a remote run survive a primary restart? **Decided: no (v1).**

Reasons, in order of weight:
1. **The run is stalled for the whole outage anyway.** All of a run's network (model API, `git push`, `arb`/MCP) goes through bridges whose far end is the primary. A restart takes the model API away from the container for its duration. Surviving would preserve only the CLI's in-memory conversation, which `claude --resume` rebuilds from the mirrored transcript, at the cost of a prompt-cache miss: the same cost local workers pay on every restart today (they die with the service, `MemoryScope`'s `BindsTo=`, and `Reconciler` resumes them).
2. **Reattach needs worker adoption.** `Arbiter.Worker` is an 8,989-line GenServer whose state (usage accumulators, step/phase tracking, completion-sentinel detection, OutputLog continuity, the egress run's `BridgeIdentity` entry and token, the learn-mode policy state, the minted worker-tier token) lives in memory and is rebuilt only by `Dispatch.resume/2`. A `Worker.adopt/…` is a new D4-class path with its own failure modes (adopt versus a concurrent resume, the same class as "a resumed worker races a live prior worker").
3. Local parity is the goal; better-than-local is not required for v1.

**Revisit when:** deploys are frequent enough that long remote runs are repeatedly interrupted *and* resumption cost (not outage) dominates. The design leaves the door open: stdout is offset-addressed and acked, the run table is on the node, `hello` already reports live runs.

**What a restart does instead (one path for graceful and hard):**
* Graceful stop: `Worker.terminate/2` (`worker.ex:8049`) sends `cancel{reason: "server shutdown", collect: false}` and stamps the run interrupted ("server shutdown") exactly as today. No upload is attempted inside the terminate budget.
* Hard kill or crash: nothing is sent; the sockets die with the BEAM.
* In both, the agent sees the socket drop, **stays quiet for no new work**, and reconnects. On `hello_ok` the `boot_epoch` has changed and the verdicts say "I do not know run X": the agent quiesces X (stops the container, takes the snapshot+bundle and transcript tar *locally*, retains them), and reports `retained`. Independently, `fence_after` stops the container at 60 s if the primary stays away that long.

### 10.5 Boot ordering (bd-aowisc §6.3's hazard) and `Workers.Reconciler` / `Boot.ResumeGate`

The hazard is unchanged: `Reconciler.reconcile_orphaned_runs/1` flips live-state rows with no live worker to interrupted, then `reconcile_resumable_tasks/1` re-dispatches; if a remote run's work has not been recovered into the home clone first, the resume provisions from a stale clone and can race a still-running container.

* `worker_runs.node_id` (**new**, nullable; migration version must sort after `20261005140000`, the latest in `priv/repo/migrations`) records where a run lives.
* The boot sweep Task (private `Arbiter.Application.boot_tasks/1`, the `:reconcile_boot_task` child at `application.ex:~380`, which runs inside `Boot.ResumeGate.sweep/1`) gains one first step: **`Nodes.Recovery.await/1` (new)**. For every run in a live state (`:starting | :working | :waiting`) with a `node_id` it waits, in parallel across nodes and bounded (default 60 s per node, 90 s total), for that node to reconnect and deliver recovery: the agent's `retained` report followed by a checkpoint bundle and transcript tar (pulled by the primary through the §9 ingest). Outcome per run: `:collected` or `:unreachable` (then it degrades to the last checkpoint, the §10.3 path, and the node's reaper removes leftovers later).
* Only after `await` returns do `reconcile_orphaned_runs/1`, `reconcile_shutdown_casualties/1` and `reconcile_resumable_tasks/1` run. `ResumeGate` already holds Autopilot closed for the whole sweep (`@max_closed_ms` 10 min, far above the 90 s budget), and account `max_concurrent` stays honest because the registry is still empty.
* **No deadlock:** the sweep Task is an async supervised child that runs while `ArbiterWeb.Endpoint` starts (separate OTP application), so nodes can connect while `await` is waiting. Reconnect storm after a restart is bounded by the backoff jitter **[U17]**.
* Two guard tests: (1) a remote run's resume never provisions before `await` returns; (2) `await` returning `:unreachable` still lets the sweep complete within the budget.

### 10.6 Install-scoped reaping (bd-aowisc §4.8 carries over in rule)

The agent reaps only what carries **its own** `arbiter.node` label **and** this install's `arbiter.install` label (a node enrolled to two installs cannot sweep the other's containers; install id is **new**, a random id persisted next to `arbiter.pid`). It does so only against a **live set** the primary sends (`reap{live_set}`), computed from `worker_runs` rows in live states plus `Worker.Registry`; the primary sends it periodically and on every `hello`. Gate: the primary sends `reap` only when `SingleInstance.primary?/1` is true (a second instance, e.g. a worker running `mix phx.server`, shares a database copy but holds no node credentials, so it cannot reach nodes anyway; the gate is belt and braces for the reason `Workers.Reconciler`'s moduledoc gives). Shadow clones and run dirs get a longer minimum age than local (default 24 h versus `WorktreeSweeper`'s 1 h): they may hold the only copy of un-checkpointed work. Pods/containers for runs not in the live set are removed at once. `TestServices.reap_orphans/1` is called with an `:alive?` option fed by the live set, never `os_alive?/1`.

## 11. Credentials on the node

| Secret | Where it lives | Notes |
|---|---|---|
| **Node credential** `arbn_…` | `~/.config/arbiter-node/credential` (0600), the **only secret at rest** | rotated every 30 days; revoke closes the socket at once; opens only the node socket and `/nodes/*`; reaches nothing else (§5.3, §15) |
| Provider token (`CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`), `worker_env` values (including forge tokens used by in-container `git push`) | **memory only**, delivered per run inside `assign`, passed to the container through `-e NAME` with the value in the `podman` client's environment (`Container.argv/2`'s `inherit_env`) | Never on argv, never in a file the agent writes. Honest caveat: podman's OCI runtime spec for a rootless container lives under `$XDG_RUNTIME_DIR` (tmpfs) and `podman inspect` shows env to the same user, as on the primary today **[U13]** |
| Per-spawn worker-tier bearer in `.mcp.json` | in the shadow for the run's life; excluded from pull-back by the primary-side path filter | identity is also enforced by `BridgeIdentity`, which overrides a presented token on a bridged request |
| Forge credential | **none on the node** | pushes leave the container through the primary's egress proxy; checkouts arrive as bundles |

Per-run delivery bounds *persistence*, not *exposure*: a compromised node can use a provider token it was handed beyond the run. Mitigations: bind remote nodes to a dedicated provider account (per-node `provider_account` filter in placement) and rotate at the provider on compromise (§15).

## 12. The `Executor` boundary (bd-aowisc §7 reshaped) and how an agent plugs in

`Arbiter.Worker.Executor` (**new** behaviour). The local path is **not** routed through it in v1 (`node: nil` takes today's code unchanged, so zero regression surface for runs that stay local). Eight callbacks, with their meaning for `Executor.Node`:

| Callback | `Executor.Node` |
|---|---|
| `prepare(node, run_spec)` | send `assign`; the agent does image/CLI/deps/shadow/run dir/listeners and replies ready (or refuses) |
| `open(prepared)` | returns the remote handle (§7.2); stdout/exit become Port-shaped messages |
| `signal(handle, :term \| :kill)` | channel `signal` event |
| `stop(run_ref)` | idempotent stop-and-remove by name (agent local `Container.stop/2`) |
| `outcome(run_ref)` | `%{oom?, exit_code}` (delivered in `exit`) |
| `collect(run_ref, :checkout \| :transcripts)` | request a checkpoint upload; ingest §9 |
| `recover(node, run_ref)` | restart path §10.4/10.5 |
| `reap(node, live_set)` | §10.6 |

Everything above the Executor is backend-agnostic: `Node` state, `Placement`, the home/shadow handoff points, heartbeat/fence, the `node_lost` classification, the reaper's liveness rule. The polymorphism is in the **agent**, not in the Executor, which is the point of the next section.

## 13. Placement and capacity

* **Two gates, in order** (bd-aowisc §4.9 unchanged): (1) today's board plan (`Board.Snapshot.effective_max_concurrent/3`) and `Accounts.Admission.admit/3` (reservation under `:global.trans/3` with `[node()]`, registry-derived `Accounts.Concurrency.live_count/2`); (2) new `Nodes.Placement.place/2`, called from a new `ensure_node_capacity/2` step in `Worker.Dispatch.dispatch/2`'s `with` chain **right after `ensure_account_capacity/2` and before `transition_to_active/2`** (`dispatch.ex:~205-210`), so a refused placement leaves the ticket untouched, as `{:account_at_capacity, info}` does; it reserves a per-node slot the same way and the chosen node rides in `opts` to the private `maybe_provision_worktree/2` (`dispatch.ex:2096`). Eligibility first (`Placement.eligible/1`, pure; §5 of bd-aowisc). Mode from `worker.placement` (`local_only` default, `prefer_remote`, `remote_only` → `{:no_node_capacity, info}` and the card is held, not failed, same treatment as `{:account_at_capacity, info}`).
* **Candidates:** enabled ∧ `online` ∧ not `draining`/`revoked` ∧ health `ready` (not `outdated`/`incompatible`/`ahead`/`degraded: :uncapped`) ∧ label match ∧ provider-account filter ∧ `live < effective_max`; rank by lowest `live/effective_max`, then reported free memory, then name.
* **Capacity sources:**
  * **Node-reported** (`hello`): cpus, `MemTotal`, a **suggestion** = `min(floor(cpus / cpus_per_worker), floor(0.8 × MemTotal / worker_mem_cap))`, and an optional **node-owner ceiling** from the node's own config (`ARB_NODE_MAX_WORKERS` in `agent.env`; the machine's owner says "never more than N here").
  * **Operator-set** `max_workers` on the node row (nullable).
  * **Effective** = `min(operator, node ceiling)` over whichever are set; if neither, the suggestion. So the operator can lower below the ceiling but never raise above what the node's owner allows. A drain sets effective to 0 for new work.
* **`conductor.max_concurrent`** (`Board.Snapshot.system_max_concurrent/0`, `Arbiter.Settings.Installation` field `conductor_system_max_concurrent`) stays the install-wide ceiling on workers anywhere (local plus all nodes) and stays **operator-owned**: it is also the quota/billing valve, so auto-raising it on join would raise spend without the operator asking. The node list shows `local + Σ effective = M` against `conductor.max_concurrent = K` and warns when K < M (nodes idle) or K much greater (over-planned). A later child adds a placement-headroom term to `effective_max_concurrent/3` so the board stops promising slots no node can serve (board planning cannot know which Ready card is remote-eligible, so a plan can exceed capacity and a brief `{:no_node_capacity, _}` hold results).
* Memory-weighted capacity is out of scope; load is advisory.

## 14. Operator surface

* **Nodes page** `/nodes` (**new** `ArbiterWeb.NodesLive`, in the `live_session :default` block of `router.ex` so it inherits the `:dashboard_auth` on_mount gate and the nav). One row per node (`#node-<id>` in a `#nodes-table`): name, state chip (`online | offline | draining | revoked`), health chip (`ready | degraded | outdated | incompatible | ahead`), **live/max** (live from the registry; max shown as effective with its sources on hover: operator, node ceiling, suggestion), agent version against server version, arch, labels, last seen, readiness summary. Row actions: Drain/Undrain, Upgrade (when `outdated`), Revoke (confirm), Remove (only revoked/offline with no live runs), Set max/labels. Footer line: `local N + nodes Σ effective = M` against `conductor.max_concurrent = K` with the §13 warning. Before editing list headers, check which `index_header` component the page actually renders: two exist with the same name (`Domain.index_header` is the rendered one).
* **Add node** (`#add-node-button` → `#add-node-modal`): name, labels, max workers, TTL → mints a `JoinToken` → shows the one-liner (`#join-command`, copy button), the token separately (`#join-token`, shown once, copy button), a countdown (`#join-countdown`) and a "Waiting for node…" state that flips to "Connected" when the node enrolls (PubSub on a `nodes` topic, no polling). Closing the modal after redemption or expiry discards the secret. Requires the dashboard grant (`ArbiterWeb.DashboardAuth`): the dashboard is operator-only, so this is the "authenticated user" of the brief.
* **Node detail** `/nodes/:id`: `NodeEvent` timeline (join, connect, upgrade, drain, revoke, fence, lost), live runs, the agent's readiness checks with hints (the `PodmanReadiness.diagnose/1` report plus the join-script prereqs), capacity breakdown, version/proto.
* **`arb server doctor`** (`ArbiterCli.Cmd.Doctor`, checks in `doctor/checks.ex`) gains a "nodes" section fed by a new `GET /api/nodes` (`:coordinator`): `nodes.public_url set and reachable` (anonymous `GET /nodes/ping`), per node `online` and last-seen age, version vs server, readiness (`fail` on `degraded`), effective capacity, and the exposure heuristic of §4.3. The existing `bind address is loopback` check is unchanged and still the invariant.
* **CLI** (§5.6) for every page action; **run page** shows the node; a `{:no_node_capacity, _}` hold shows as a board chip like the account-capacity hold.

## 15. Security model

### 15.1 Credentials and what each one can reach

| Presented | `/api/*` | `/mcp`, `/events` | dashboard, `/live`, `/session` | `POST /nodes/enroll` | `/nodes/runs/:run/*`, `/nodes/files`, `/nodes/agent`, `/node/socket` |
|---|---|---|---|---|---|
| nothing | `version`, `migrations` only | 401 | login only | 401 (no token) | 401 |
| join token `arbj_` | 401 | 401 | none | **yes, once** | 401 |
| node credential `arbn_` | **401** | **401** | none | 401 | own node and its assigned runs only |
| run transfer token `arbr_` (§16) | 401 | 401 | none | 401 | that one run's `/nodes/runs/:run/*` only |
| worker token (`Scope`) | own task | own task | none | 401 | 401 |
| coordinator token | per `ApiPolicy` | yes | none | 401 | 401 |
| operator-proof token | `:operator` node admin | yes | none | 401 | 401 |

### 15.2 Join token
Single-use, 256-bit, 15-minute default TTL (24 h max), hashed at rest, redeemed by one atomic conditional update, generic 401 on any failure, rate-limited (§5.4), every outcome audited (`token_minted`, `enrolled`, `join_failed`). It cannot open the socket, call any API, or be used twice. Never on argv, never in a URL, not in the one-liner (§5.5). Minting needs the dashboard grant or an operator-proof token; a coordinator *session* cannot mint.

### 15.3 Node credential: scope and revocation
Scope is exactly the node socket plus run-scoped `/nodes/*` routes for runs **assigned to that node**. Revocation is immediate on every surface: the row's hash is cleared (HTTP routes fail the next request), `Endpoint.broadcast("node_socket:<id>", "disconnect", %{})` closes the live socket, `Nodes.Session` stops, the node's runs are stamped interrupted ("node revoked", no attempt consumed), and `NodeEvent revoked` records actor and time. Rotation every 30 days bounds a stolen-credential window. The credential never leaves the node's agent process: containers have no mount that includes it.

### 15.4 The new auth tier
Structural, not a flag: a distinct token format with its own plug (`NodeAuth`), disjoint route namespace (`/nodes`, `/node`), and no overlap with `Scope` verification. Cross-tier guard tests (§5.3) fail the build if any route ever accepts the wrong tier. `WorkerBridge` keeps a jailed worker off `/nodes`.

### 15.5 What a compromised node can and cannot do
**Can:** read the code and `worker_env` of every run placed on it; use the provider tokens and forge tokens it was handed (also after the run, until they are rotated at the provider; §11); present arbitrary stdout/exit status and arbitrary checkout contents for its own runs (treated as untrusted exactly like any worker output: quarantine, fsck, ref allowlist, path filter, then the normal ReviewGate/MergeQueue); open bridge streams for its own runs, which hit the same egress policy and audit; exhaust its own slots; flood the primary within caps (rate limits, stream and byte caps, bundle size caps); call the primary's `/api` with a **worker-tier token** it was given for a run, which can act on that one task only and expires with it.
**Cannot:** reach any `/api` or `/mcp` route with its credential; mint, escalate or read another tier's tokens; touch another node's runs, sockets or bundles; read the database, other workspaces' secrets (it only receives secrets for runs placed there), or the cloak key; alter egress policy or its audit rows; make the primary execute anything from the checkout (no hooks or config cross the bundle boundary; `core.hooksPath=/dev/null` in quarantine); write outside `~/.arbiter-node/` on its own host via the agent (the agent builds containers from a spec and refuses unsafe flags, §7.1).
**Containment levers:** per-workspace `worker.placement` (default `local_only`) keeps sensitive workspaces off nodes; node↔workspace pinning (allowlist on the node row); a dedicated provider account for nodes; node labels; revoke.

### 15.6 Other parties
* **Network attacker:** TLS 1.2+ to a publicly trusted certificate (tailnet) or loopback only; plaintext to a non-loopback host is refused by the agent.
* **Compromised primary:** can instruct nodes (as with any orchestrator, and as with SSH). The spec-not-argv boundary (§7.1) limits it to what `Container.argv/2` will build. No code signing in v1.
* **A tailnet peer without credentials:** reaches the app's public routes (`/nodes/join` script, `/nodes/ping`, `/api/version`) and can burn limiter budget, but cannot enroll without a token, nor download the 54 MB tarball (credential required). The tailnet ACL (§4.3) shrinks this further.
* **Same-UID process on the primary:** unchanged from today's trust assumption (`docs/remote-access.md`). A same-UID process on a **node** can read the credential file and the agent's memory; nodes are single-owner machines by assumption.

## 16. Kubernetes in-cluster agent: what it needs from this design (bd-1nfuq5 depends on this)

An in-cluster **controller pod** is one node that speaks the same protocol, presenting its own concurrency config as capacity. The design leaves it room, and the Executor needs no new implementation (§12):
* **Identity/enrollment:** same join token → node credential; the credential lives in a Kubernetes Secret instead of `~/.config`. `hello` carries `kind: "cluster"` and `caps` (`backend: "k8s"`, `image: "registry"`, `limits: "pod"`, `bridge_streams`, `bundle`).
* **Capacity:** the controller's own configured concurrency is its node ceiling (§13); the operator may only lower it.
* **Run spec:** declarative (§7.1), no podman argv, mount *kinds* map to volumes/`emptyDir`, resource limits to pod resources; the controller does what `Container.argv/2` does locally (a pod-spec builder with the equivalent hardening: read-only root, dropped capabilities, no service-account token, deny-all `NetworkPolicy`; the `label=disable` bridge reasoning is SELinux-specific and needs its own review).
* **Pods never hold the node credential.** `assign` includes a **run transfer token** `arbr_…` (**new**: per run, in memory on the primary, expires at run end) that authorises only `/nodes/runs/:run/*` (seed bundle, checkpoint upload, transcript upload), so an init container can fetch the seed bundle and a sidecar can push a checkpoint with no standing secret. The same token path is available to podman nodes but unused there.
* **Bridges:** the stream protocol is independent of how the agent got the bytes. The controller exposes a per-run in-cluster endpoint to the pod and relays into `bridge.open`; that endpoint needs per-run mTLS or a bearer (the unix-socket permissions the podman path gets for free), which is the k8s agent's own work.
* **Not in this design:** image distribution via a registry (`caps.image: registry`), Secrets with their own RBAC/rotation instead of in-memory `assign` secrets, owner-reference/TTL reaping in place of the label sweep, log streaming as `stdout` frames, test services as sidecars. All are agent-internal; none changes the primary.

## 17. Unverified assumptions (replaces bd-aowisc §10)

Each is checked by the spike (child 2, §18) unless noted. **No-go consequence** says what changes if it fails.

| ID | Assumption | Why it matters | Check | If it fails |
|---|---|---|---|---|
| U1 | `tailscale serve` carries a WebSocket upgrade on a non-dashboard path and does not kill a quiet socket (10 s heartbeats); `--set-path` can expose only `/nodes` + `/node/socket` | the whole reachability story | real `serve`, 30-min soak | add a second `serve` port mapping to the same loopback, or fall back to path 3 of §4.3 (`ssh -L`) |
| U2 | `mint_web_socket` (not currently in `deps/`) speaks Phoenix's V2 serializer incl. binary frames, and a ~300-line client is enough | agent transport | prototype client against `Phoenix.ChannelTest` + a Bandit-served endpoint | `slipstream`/`phoenix_gen_socket_client`, or a raw `WebSock` data path |
| U3 | Bridge mux adds p99 ≤ 250 ms at 10 concurrent runs and acceptable CPU on the primary | bridge decision (§8) | replay a recorded SSE stream through proxy→mux→proxy; vary RTT with `tc netem` | second data socket; if still failing, reconsider agent-side proxy |
| U4 | Heartbeat jitter < 5 s on the same socket during a 5 MB bridged push | single-socket decision (§4.2) | measure | second socket for bridge data |
| U5 | The release boots in `ARB_ROLE=agent` without `SECRET_KEY_BASE`, DB or cloak key; start time and RSS are acceptable | agent packaging | boot a release with the role set | a second release definition (`applications: [arbiter: :load, …]`) in the same `mix release` config |
| U6 | The modules the agent reuses are DB-free or can be fed their inputs: `Container`, `PrivateClone`, `Worktree` helpers, `DepsCache` (aliases `Arbiter.Mergers`), `TestServices`, `PodmanReadiness`, `Egress.Listener` | "run the same builders on the node" | grep + load each in a role-agent VM with `Repo` absent | thin extraction modules; adds to child 9 |
| U7 | `git bundle` round trip keeps exec bits, symlinks, deletions and rename detection; `fetch.fsckObjects` applies to bundle fetch; thin `^have` bundles work; submodule/LFS veto scan of registered repos | checkout sync | fixture repos incl. submodule/LFS | fsck with an explicit `git fsck` pass after fetch; veto list grows |
| U8 | Rootless `--memory`/`--memory-swap` are enforced and `.State.OOMKilled` is reported **without** `--rm`; `--cpus` needs `cpu` delegation | memory cap | per distro (carried from bd-aowisc §10.3) | `degraded: :uncapped` (excluded by default) |
| U9 | `loginctl enable-linger` for self works without sudo (polkit) and is enough for rootless containers/user units to outlive the session | install | ubi8, ubi9, debian 12, Ubuntu 24.04 via podman recipes | script refuses with instructions (already the fallback) |
| U10 | Reliable detection of memory-controller delegation to the user slice across those distros | join-script prereq | script test matrix | refuse more often; document the `Delegate=` drop-in |
| U11 | Only x86_64 Linux is published today (`release.yml`: one `ubuntu-latest` job in `redhat/ubi8`) | arch refusal | read the workflow's matrix and release assets | arm64 nodes wait for a second release job |
| U12 | Build-from-plan on a node finishes in an acceptable time and needs only public registries/mirrors; the tag the node computes equals the plan's | images (§7.3) | build the 843 MB toolchain image on a clean node; time it vs `save | load` | `save/load` fallback becomes default |
| U13 | Secret env values never reach persistent storage on the node (OCI spec on tmpfs; no log lines) | §11 claim | inspect `$XDG_RUNTIME_DIR/containers`, `journalctl`, agent logs | document, or deliver secrets by a tmpfs file mount |
| U14 | `Socket.id` + `Endpoint.broadcast(id, "disconnect", _)` closes a live node socket immediately under Bandit | instant revoke | test | `Nodes.Session` self-stops on its own revoke check each heartbeat |
| U15 | Single-use token redemption is atomic via a conditional update through Ash/Ecto on SQLite | token lifecycle | concurrent-redeem test (two processes) | raw `Repo.query` update |
| U16 | The retained deploy tarball and the allowlist-packed tree both boot as agents and match the published sha for published releases | packaging | compare against a published asset | serve only retained tarballs; `--local` nodes unsupported |
| U17 | A reconnect storm after a primary restart (N nodes) is absorbed and the 90 s recovery budget covers boot-to-endpoint-up on this host | boot ordering | restart the dev instance with simulated agents; read boot timing | longer budget / staggered reconnect |
| U18 | The three `Worker` port clauses plus `terminate_session_port/2` and `session_live?/1` are the complete port surface | remote handle (§7.2) | grep + `mix test` of `Worker` with a fake handle | widen child 9 |
| U19 | The Claude CLI rides through a stalled/refused proxy socket for up to `fence_after` (retries instead of failing the turn) | blip survival (§10.2) | kill the mux for 30 s mid-turn | blips become restarts: set `fence_after` low, drop the claim |
| U20 | Tailscale identity headers on node requests are usable as an audit hint; the public-endpoint heuristic has acceptable false-positive rate | exposure doctor check | inspect headers via `serve` | drop the hint, keep the heuristic as a warning |

## 18. Implementation breakdown (the coordinator files the children)

The whole is D4-class and is split; **no child is above D3**. The spike gates children 5–13; children 3 and 8a are useful under any spike outcome and may start in parallel with it.

| # | Title | Diff. | depends_on | Notes |
|---|---|---|---|---|
| 1 | Commit this design as `docs/design/remote-workers.md` | D1 | none | status "proposed"; reviewed alongside the first code; update the §17 table as spikes land; one pointer from `docs/remote-access.md` |
| 2 | **Spike: go/no-go** for transport, bridge mux, bundle sync, agent role boot, memory cap, prereq checks | D3 | 1 | covers U1–U5, U7–U10, U13, U19; real endpoint under Bandit in ExUnit (WebSockets included) plus the operator's real `tailscale serve` if available; podman recipes for ubi8/debian; **explicit GO / NO-GO / GO-WITH-FALLBACK per criterion** (U3 and U4 thresholds in §8/§4.2); amends §17 |
| 3 | Nodes domain and the new auth tier | D3 | 1 | `Node`, `JoinToken`, `NodeEvent` Ash resources + migration (version after `20261005140000`), `Nodes.Credentials`, `Nodes.RateLimit`, `NodeAuth` plug, `ApiPolicy :operator`, `Actor :node`, `nodes.*` settings, cross-tier guard tests |
| 4 | Join flow, server side | D3 | 3 | `/nodes/join` script template (shellcheck + no-`sudo` test), `/nodes/enroll`, `/nodes/ping`, `/nodes/agent/:v.tar.gz` (deploy retains the tarball; allowlist pack for `--local`), `/nodes/files/:sha`; `arb node add\|list\|show\|set\|events` |
| 5 | Agent role and client | D3 | 2, 3 | role gate in both Application modules and `runtime.exs`; `Arbiter.NodeAgent.Supervisor`; WS V2 client with backoff; `hello`/`hb`; readiness report; self-upgrade; `arbiter-node` wrapper and unit; `ReleaseEnvGuardTest @inventory` entries |
| 6 | Primary node session | D3 | 3 | `NodeSocket`, `NodeChannel`, `Nodes.Registry`/`Session`; heartbeat → suspect → fence/lost; `hello_ok` verdicts; drain; skew states; `disconnect` on revoke; `NodeEvent` writes; `Phoenix.ChannelTest` coverage |
| 7 | Operator surface | D3 | 6 | `NodesLive` (list, Add node, detail), doctor section + `GET /api/nodes`, `arb node drain\|revoke\|remove\|upgrade`, run-page node field |
| 8a | `Container.argv/2` additive options | D2 | 1 | mount mapping, `--memory/--memory-swap/--cpus`, labels, optional no `--rm`; pure; usable to cap local containers later |
| 8 | Placement and capacity | D3 | 6 | `Nodes.Placement`, `ensure_node_capacity/2` after `ensure_account_capacity/2`, `worker_runs.node_id` migration, effective capacity (§13), modes, `{:no_node_capacity, _}`; returns only local until child 9 |
| 9 | Remote run | D3 | 5, 6, 8, 8a | `Worker.Executor` + `Executor.Node`; run spec; remote handle in `Worker` (3 clauses, `terminate_session_port/2`, `session_live?/1`); agent run supervisor (argv from spec, build-from-plan images, CLI files, node-local `DepsCache`, test services, stdout ring/ack/replay, exit/OOM); secrets in memory; spawn-site guard tests; behind `worker.placement`, default off |
| 10 | Bridge mux | D3 | 9 | `Nodes.Bridge`, agent listeners, credits; end-to-end test that `BridgeIdentity`, policy decisions and `egress_events` are unchanged |
| 11 | Checkout sync | D3 | 9 | seed bundle, shadow clone, snapshot, upload, quarantine ingest, **primary-side path filter**, checkpoint, sanitising transcript extractor, `seed: false` thin home clone |
| 12 | Restart and recovery | D3 | 9, 11 | `Nodes.Recovery.await/1` in the boot sweep, agent `retained` + quiesce, `:node_lost`, `reap{live_set}` + node-side reaper, `TestServices` liveness via live set, remote retention, ordering race tests |
| 13 | End-to-end verification and runbook | D3 | 10, 11, 12 | `:node_agent`-tagged tests (excluded by default) with a real agent and podman against a Bandit-served endpoint; `docs/remote-workers-runbook.md` (tailnet/ACL tags, prereqs, cgroup delegation per distro) |
| 14 | Board placement-headroom term | D2 | 8, 12 | `effective_max_concurrent/3` stops over-planning slots no node can serve |

Order: 1 → 2 → {3, 8a} → {4, 5, 6} → {7, 8} → 9 → {10, 11} → 12 → 13; 14 after 12. Not filed (optional, later): salvage of a returning node's retained shadow, `NodeEvent` on `/audit`, long-poll fallback transport, arm64 release job, the k8s agent (bd-1nfuq5).

## 19. How names in this document were checked

Read at `9b5fb0733` (functions are public unless marked private):

* **Worker/spawn:** `Arbiter.Worker.ContainerSpawn` (`prepare/1` :156, `podman?/1` :137, `wrap_port/1` :477, `teardown/1` :534; private `cli_mounts/1`, `run_dirs/2`, `start_egress/3`, `start_services/2`), `Container` (`argv/2` :145, `wrap/2` :236, `stop/2` :445, `name_for/1` :136, `teardown/1` :425), `ClaudeSession` (`open_scoped_port/2` :1995, `open_port/1` :2014), `Worker` (`init/1` :1108, `terminate/2` :8049, `whereis/1` :696, port `handle_info` :2844/2848/2852; private `terminate_session_port/2`, `safe_port_os_pid/1` :3605, `session_live?/1` :8232, `mark_memory_cap/2` :2706, `commit_gate/1` :4382, `sync_back_after_run/1` :4606), `OsProcess.kill_tree/1`, `MemoryScope` (`wrap/3`, `stop/2`, `list/1`, `sweep/2`), `Sandbox.module/2`, `GitLayout.for_policy/1`/`for_workspace/3`, `PrivateClone` (`create/4`, `attach/4`, `mounts/1` :606, `sync_back/1` :435), `Worktree.seed_compiled_deps/3`, `Worktree.has_uncommitted?/1`, `SeedPaths.resolve/2`, `DepsCache` (`seed_worktree/3`, `ensure/4`, `install/3`, `key/4`), `Image.plan/3`, `Image.Builder.ensure/3`, `PodmanReadiness.diagnose/1`, `TestServices` (`start/1`, `teardown/2`, `reap_orphans/1`), `Jail.network_spec/1`/`network_env/1`/`network_command/2`, `Egress` (`start_run/2`, `socket_dir/0`, `socket_path`, `bridge_path`), `Egress.JailRun.start/1`, `Egress.Forward.run/4`, `Egress.BridgeIdentity` (`put_run/3`, `resolve/2`), `Egress.Listener`, `Worker.Dispatch` (`dispatch/2` :173, `resume/2` :379; private `ensure_account_capacity/2`, `transition_to_active/2`, `maybe_provision_worktree/2` :2096), `Worker.ReleaseEnv.cmd/3`, `ReleaseEnvGuardTest` (`@inventory`), `NoPtyHandleTest`.
* **Recovery/capacity:** `Workers.Reconciler` (`reconcile_orphaned_runs/1` :104, `reconcile_shutdown_casualties/1` :201, `sweep_worker_scopes/1` :125, `reconcile_resumable_tasks/1` :649), `Boot.ResumeGate` (`sweep/1`, `open?/0`), `SingleInstance.primary?/1`, `Arbiter.Application` (`children/1`; private `boot_tasks/1`), `Workers.Run` (`worker_runs`, `cgroup_scopes`), `StopReason.classify/3` :456, `Accounts.Admission.admit/3`, `Accounts.Concurrency.live_count/2`, `Board.Snapshot.system_max_concurrent/0` :574 and `effective_max_concurrent/3` :619, `Arbiter.Settings.Installation` (`conductor_system_max_concurrent`), `Usage.ClaudeSessionFile` (`project_slug/1`, `locate/2`), `Worker.SessionArchive.archive_run/2`, `Messages.Escalation`, `Events.broadcast/3`, `Actor` (kinds), `CircuitBreaker`.
* **Web/auth:** `ArbiterWeb.Plugs.ApiAuth`, `ApiPolicy` (policy table), `Plugs.WorkerBridge` (`@allowed_prefixes`), `Loopback`, `Endpoint` (`socket "/live"`, `"/session"`), `SessionSocket`, `SessionChannel`, `Arbiter.Sessions.Frame` (`ARB1`), `Arbiter.MCP.Scope` (`tier`s, `from_token/1`, `operator?/1` :233, `mint_*`), `MCP.Plug` (401 on bad token), `DashboardAuth` and `DashboardAuth.LoginTokens`, `Boot.BindAddressCheck`, `ServerController.bind_address` (`GET /api/server/bind_address`), `AuditLogLive` (reads `Arbiter.Tasks.Issue.Version`), `OperatorSocket`.
* **CLI/release:** `ArbiterCli.Cmd.ReleaseDeploy` (download at :208), `ReleaseDeploy.ReleaseFiles` (`unpack!/2`, `install_dir!/2`, `prune_old_releases/3`), `Cmd.InstallService` + `Systemctl.enable_linger/0`, `Cmd.Doctor` + `check_bind_address`, `mix.exs releases/0`, `rel/env.sh.eex`, `.github/workflows/release.yml`, `scripts/check-release-glibc.sh`, `docs/remote-access.md`, `docs/design/podman-worker-containers.md`.
* **Measured on this host:** release tarball 54 153 326 bytes / 160 MB unpacked (`v0.2.17-published`); toolchain image 843 MB, base 464 MB (`podman images`); repo pack 29.6 MB, bundle of history since 2026-09-01 15.6 MB (`git bundle create -`).

**New in this design (do not exist at `9b5fb0733`):** `Arbiter.Nodes` and its modules (`Node`, `JoinToken`, `NodeEvent`, `Registry`, `Session`, `Placement`, `Bridge`, `Checkout`, `Recovery`, `RateLimit`, `Credentials`); `Arbiter.NodeAgent` and its modules; `Arbiter.Worker.Executor` and `Executor.Node`; `ArbiterWeb.NodeSocket`/`NodeChannel`/`NodeController`/`NodesLive`, `Plugs.NodeAuth`; `ApiPolicy` policy `:operator`; `Actor` kind `:node`; routes `/nodes/*`, `/node/socket`, `/api/nodes`; settings `nodes.public_url`, `nodes.allow_skew`, `nodes.allow_public_endpoint`, `nodes.fence_after_s` and friends; `worker_runs.node_id`; the install id; `worker.placement` / node label keys; `{:no_node_capacity, _}`; `:node_lost`; `arb node …` and `arbiter-node`; `ARB_ROLE`, `ARB_JOIN_TOKEN`, `ARB_JOIN_TOKEN_FILE`, `ARB_JOIN_CHECK_ONLY`, `ARB_NODE_MAX_WORKERS`; token prefixes `arbj_`/`arbn_`/`arbr_`; the `mint_web_socket` dependency; `Container.argv/2` options (mount mapping, memory/cpus, labels, no `--rm`) and `seed: false` on `Worktree.create/4`.
