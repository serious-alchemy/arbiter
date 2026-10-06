# Remote workers v2: join token + node agent (pull model) — design

**Status:** proposed (2026-10-05). Nothing here is implemented. Epic bd-9bk0af; design task bd-bw8a0m; committed by bd-dufrgb. Later children update the §17 assumptions table as spikes land. **The RW2 spike (bd-6tx1xv) landed 2026-10-06: per-criterion verdicts and evidence are in §17.1, and every amendment it caused is marked `[RW2]` inline.**

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
| §4.11 "no standing secret on a host" | **Narrowed:** the node credential is a standing secret (one per node, 0600). Provider tokens and `worker_env` values are still per run and never on the node's disk (delivery changed by RW2/U13: a tmpfs file mount, not `-e NAME`; §11). | |

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

**Agent role boot.** `Arbiter.Application.start/2` and `ArbiterWeb.Application.start/2` begin with a positive role check (`:agent` → start only `Arbiter.NodeAgent.Supervisor`; `:primary` → today's list). This is **fail-closed**: a child added to the primary list later does not run in agent mode, because the agent returns its own list. `config/runtime.exs` also gates on the role: today it `raise`s without `SECRET_KEY_BASE` (line 28) and configures the Repo, none of which an agent has. `Arbiter.Extensions.load!/0` (first line of `Arbiter.Application.start/2`) is skipped in agent mode. The agent loads the `:arbiter` application's modules but does not start its supervision tree **[U5, U6]**. **[RW2: U5 GO]** Prototyped on the published v0.2.18 release (a copy, in a private net namespace): with a `runtime.exs` gate (`ARB_ROLE=agent` → `config :arbiter, role: :agent`, skipping the `SECRET_KEY_BASE` raise and the Repo config) and a role check at the top of **both** `Arbiter.Application.start/2` and `ArbiterWeb.Application.start/2` (the second would otherwise start `ArbiterWeb.Endpoint` and bind the port), the release boots with no `SECRET_KEY_BASE`, no `DATABASE_PATH` and no `ARBITER_CLOAK_KEY`: **0.5–1.4 s** from `bin/arbiter start` to the stub supervisor reporting ready, **≈100 MB RSS** (the live primary is ≈930 MB), no Repo/Vault/Endpoint process, and `Container`, `PrivateClone`, `DepsCache`, `TestServices`, `PodmanReadiness`, `Image`, `Worker.Egress.Listener` and `Worker.Egress.Forward` all load. Without the `ARB_ROLE` env the same copy still dies at `runtime.exs` on `SECRET_KEY_BASE`, i.e. the primary's guard is unchanged. All ~68 OTP dependency applications still start (they are in the boot script), which is where the 100 MB comes from; that is acceptable. The role must reach `Application.start/2` through application config set in `runtime.exs` (an env read in `start/2` also works), and the agent's own modules must be compiled into the release: releases boot in `embedded` mode, so a module that is not in the `.app` file cannot be loaded at runtime. Measured sizes of the release today (`~/.arbiter/releases/v0.2.17-published`): 160 MB unpacked, 54 MB as `tar.gz`, of which `erts-16.4.0.2` is 76 MB and `lib/arbiter-0.2.17` 17 MB. Agent mode has no smaller artifact by design; the cost is one 54 MB download per node per version.

**[RW5: implemented]** (bd-3f9c4t). The gate is `Arbiter.NodeAgent.role/0` (reads `config :arbiter, role:`; anything but `:primary`/`:agent` is `{:error, {:unknown_role, _}}` and refuses to boot); `Arbiter.Application.supervisor_children/2` and `ArbiterWeb.Application.supervisor_children/2` match on it positively, and the agent branch never evaluates the primary list. `config/runtime.exs` writes the role from `ARB_ROLE` (`agent` | `primary` | unset; any other value raises) and skips the `SECRET_KEY_BASE` raise and the Repo for an agent. Booted from a `mix release` build of this branch (scratch `HOME`, **no** `SECRET_KEY_BASE`, `DATABASE_PATH` or `ARBITER_CLOAK_KEY`): `Arbiter.Supervisor` has the single child `Arbiter.NodeAgent.Supervisor`, `ArbiterWeb.Supervisor` has none, and `Arbiter.Repo`, `Arbiter.Vault` and `ArbiterWeb.Endpoint` are not running. **Measured memory is higher than the spike's ≈100 MB:** `:erlang.memory(:total)` ≈ 253 MB (code ≈ 103 MB: embedded mode loads all ≈4,800 modules) and VmRSS ≈ 630 MB six seconds after boot, so the K16 256 Mi/512 Mi budget needs the number re-checked on the real image. Agent-mode env: `ARB_NODE_URL` (https, or http only for loopback), `ARB_NODE_HOME` (default `~/.arbiter-node`), `ARB_NODE_CREDENTIAL_FILE` (default `~/.config/arbiter-node/credential`, must be 0600); `ReleaseEnv` scrubs all of them (and `ARB_ROLE`) from spawned children, so a `mix test` run by a worker on a node cannot boot as an agent.

**Contract the primary half (RW6) must meet.** The agent connects to `<ARB_NODE_URL>/node/socket/websocket?vsn=2.0.0&token=<credential>&proto=1&agent_version=<v>`, joins `node:<node_id>`, pushes `hello` and takes `hello_ok` as the push's reply **or** as a `hello_ok` push; it pushes `hb` every `hello_ok.hb_interval` seconds (default 10) and takes `hb_ack` as a reply **or** a push; with no ack for `hello_ok.fence_after` seconds (default 60) it logs `fenced`, drops the socket and reconnects (backoff 1 s doubling to 30 s, ±25 % jitter, reset only by a `hello_ok`). `hello` carries `agent_version`, `proto`, `kind`, `arch`, `caps`, `capacity`, `inventory.runs` and `readiness` (the `PodmanReadiness.diagnose/1` report, cached 10 min across reconnects). `hello_ok.upgrade = {version, sha256}` (or an `upgrade` push) starts a self-upgrade: `GET /nodes/agent/<version>.tar.gz` with the credential, sha256-verified, unpacked to `releases/<version>/`, then, once idle, `upgrade.pending` is written, `current` is flipped by a temp symlink renamed over it and the VM stops (systemd restarts it). The new agent writes `confirmed` after its first `hello_ok`; the unit's `ExecStartPre` (`arbiter-node pre-start`) rolls `current` back if `upgrade.pending` is older than 180 s. `arbiter-node leave` sends `DELETE /nodes/self` (node credential, via `curl -K -` on stdin) **before** stopping the unit; that route does not exist yet (RW6/RW7 own it), until then `leave --force` is the only way out. The wrapper and the unit ship in the release under `share/arbiter-node/`; the join script (child 4) installs them. Not in RW5: `assign`, `cancel`, `reap`, `drain`, `rotate` (logged and ignored), the `manual` upgrade policy and the prerequisite checks beyond `PodmanReadiness`.

**Why the same release, not a second one.** It is the only way "the agent always matches the server version" is true by construction, and it makes the hardening builders (`Container.argv/2`: read-only root, dropped caps, `no-new-privileges`, `label=disable` only with bridges) run **on the node** from the identical code, which the SSH design had to re-implement or remote-control. The cost: agent mode is a role in a big release, so the role gate (child 5) and the DB-free audit of reused modules (U6, child 9) are real work.

## 4. Transport and reachability

### 4.1 Channel vs long-poll: decided, channel

* **Needs:** server→node assignments and cancels with low latency; node→server heartbeats, stdout lines, outcomes; and per-run **byte streams** for the bridges (§8) which are many, small, bidirectional writes.
* **Phoenix channel over WebSocket (chosen):** one connection carries all of it; `Phoenix.Socket.id/1` + `Endpoint.broadcast(id, "disconnect", _)` closes a revoked node's live socket at once **[U14]**; `Phoenix.ChannelTest` tests it with no network; binary frames are already used in this repo (`SessionChannel` `stdout`/`stdin` as `{:binary, frame}`, `Sessions.Frame` `<<"ARB1", seq::64, payload>>`, `max_frame_size: 1_048_576` on `/session`). WebSockets already traverse `tailscale serve` here: LiveView (`/live`) and `/session` run through it today (`docs/remote-access.md`), though I have not exercised a **non-dashboard path** or a long-idle socket **[U1]**.
* **Long-poll (rejected as the transport):** Phoenix's longpoll transport exists in the endpoint for `/live`, so the *server* half is free, but the bridge needs a request per direction per write burst; cancel latency is bounded by the poll cycle; and binary pushes would be base64-wrapped. It would be the right fallback for a network that blocks WebSocket upgrades. The tailnet path does not, so **not built in v1**; the channel module is transport-agnostic, so it can be added later without protocol change.
* **Agent-side WebSocket client:** there is no WS client in `deps/` (only `websock`/`websock_adapter`, server side; `mint` is present via Finch/Req). Plan: add `mint_web_socket` (small, on top of `mint`) and a ~300-line Phoenix V2-serializer client with reconnect/backoff/jitter (1 s → 30 s) **[U2]**. Alternatives (`slipstream`, `phoenix_gen_socket_client`) pull their own HTTP stacks. **[RW2: U2 GO]** `mint_web_socket` 1.0.6 depends only on `mint` (already in the tree), and the prototype client (`apps/arbiter_web/test/support/spike/ws_client.ex`) is **222 non-blank non-comment lines** including JSON text frames, the three binary kinds, join/reply matching, ping/pong, close and the `phoenix` heartbeat; backoff is the agent's own loop and is not counted. It must connect with **`transport_opts: [nodelay: true]`**: Mint leaves Nagle on, and the request/response pattern of a bridged connection then stalls on delayed ACKs (median connection setup ≈46 ms instead of ≈5 ms on loopback; §17.1).

### 4.2 Wire protocol (sketch; proto version 1)

`NodeSocket.connect/3` takes params `token` (node credential), `proto`, `agent_version`; rejects on any credential failure; `id/1` = `"node_socket:<node_id>"`. Topic `node:<node_id>`; a node can only join its own. Control events are JSON; byte payloads are binary frames with the existing `ARB1` seq header (the seq domain is per stream).

| Direction | Event | Payload (essentials) |
|---|---|---|
| node→primary | `hello` | agent version, proto, arch, `caps` (`backend: podman`, `bundle`, `bridge_streams`, `image: build\|pull`), capacity facts (cpus, mem), node-set ceiling, **inventory**: live runs (id, container state, stdout offset), retained shadows, images, deps-cache keys, readiness report (`PodmanReadiness.diagnose/1` + prereq checks) |
| primary→node | `hello_ok` | primary `boot_epoch` (random per BEAM start), `fence_after`, `hb_interval`, effective `max_workers`, per-run "I know this run: yes/no" verdicts, optional `upgrade` |
| node→primary | `hb` (every 10 s) | per-run state + `stdout_seq`, load, free mem; reply `hb_ack` (cumulative acks) |
| primary→node | `assign` | the **run spec** (§7.1) incl. per-run secrets (never written to persistent storage on the node: tmpfs file, §11); `cancel{run, reason, collect?}`; `reap{live_set}`; `rotate`; `upgrade{version, sha256}`; `drain` |
| node→primary | `stdout` (binary) | `ARB1` frame of line records; primary `ack`s cumulative offsets |
| node→primary | `exit` | status, `oom?`, container id; `checkpoint{run, bundle_ref}`; `bridge.open{run, name, stream}` / `bridge.data` / `bridge.close` / `bridge.credit` (both directions) |

**Cluster-node additions *(A1, A3, A4; K§3.2, K§14)*.** `hello.kind ∈ {machine, cluster}` and `caps` as K§3.2 lists them (`backend: podman|k8s`, `image: build|pull|registry`, `limits: cgroup|pod`, `upgrade: tarball|image`); skew rules unchanged. Per-run states are `pending | starting | running | terminating`, and the node may answer an `assign` with `refuse{reason ∈ no_capacity, unschedulable, image_unavailable, bad_spec}`. New node→primary event `capacity` and a `capacity{ceiling, running, pending, headroom, constrained}` field on `hb`; `hello_ok.limits.prepare_timeout_s`. The stdout cursor and its `ack` are an **opaque backend-defined string** (podman: decimal offset, as above; cluster: RFC 3339 nano timestamp); the primary stores and echoes it without interpreting it.

Backpressure: Phoenix channels have none, so streams use a credit window (256 KiB per stream, 16 KiB frames, max 64 streams per run and 256 per node, total in-flight per node capped at **256 KiB [RW2: was 1 MiB; U4]**). The sender must schedule streams **fairly** (round-robin over streams with credit): under a small node cap a bulk push that is served first starves the SSE streams of other runs (a spike run with a 64 KiB cap lost one SSE client to a 60 s receive timeout; the cause was not captured and starvation is the suspect). Stdout replay after a blip uses the offset+ack scheme `Sessions.Stream` already uses.

**Single socket vs two [RW2: U4 GO, U3 GO-WITH-FALLBACK]:** one socket with credits. The risk was bridge traffic starving the heartbeat; fence/lost thresholds (60/90 s) leave 30 s of slack. Measured: a 5 MiB push in either direction moves the heartbeat round trip by at most 2.3 s on any link of 2 Mbit/s or more (4.1 s at 1 Mbit/s), and the worst combined case (5 MiB up + 5 MiB down + 8 SSE runs) stays under the 5 s threshold with the 256 KiB cap (§17.1). The queue that delays a heartbeat is the link's own (everything in flight is ahead of it), so **a second socket for bridge data does not help** and is no longer the fallback; what helps is the smaller in-flight cap above. The fallback for a *lossy* link (one TCP stall delays every run on the socket; U3) is **sharding runs over K sockets by run id**, hello advertising `caps.bridge_sockets`, same credential, no protocol change; the spike measured it (§17.1) but v1 ships one socket.

### 4.3 Reachability

* Arbiter binds `127.0.0.1:4848`; `ArbiterWeb.Boot.BindAddressCheck` warns at boot on `ARB_BIND_ADDRESS` off-loopback, and `arb server doctor`'s `check_bind_address` (`arbiter_cli/.../doctor/checks.ex`, via `GET /api/server/bind_address`) reports a non-loopback bind as `:fail` (non-fatal, informational). That invariant is kept. **Nodes do not need an off-loopback listener.**
* **Required of a node (the expected path):** it is a member of the same tailnet as the primary (tailscaled up, MagicDNS resolving `<primary>.<tailnet>.ts.net`) and can open outbound HTTPS/443 to it. `tailscale serve` terminates TLS with a publicly trusted certificate, so the node needs only the system CA store. The primary must run `tailscale serve --https=443 http://127.0.0.1:4848` (already the dashboard setup, `docs/remote-access.md`). Nothing inbound is needed on the node. Beyond the primary, the node needs outbound access for image builds/pulls (registries, distro mirrors) and nothing else: **no forge access** (checkouts arrive as bundles; pushes go through the primary's egress proxy).
* **Recommended hardening:** tailnet ACL tags (`tag:arbiter-node` → `tag:arbiter-primary:443` only). Optional: `tailscale serve --set-path` to expose only `/nodes` and `/node/socket` rather than the whole app **[U1; RW2: verified, §17.1: the mapping must carry the path in its target, `--set-path /node/socket http://127.0.0.1:4848/node/socket`, and everything else on that port (`/`, `/live`, `/other/…`) answers 404]**; today `serve` proxies *every* route to the tailnet (dashboard and `/api` stay protected by their own auth; `ApiAuth` answers 401 to anything without a valid token). A new doctor check, `nodes.public_url reachable`, does an anonymous `GET /nodes/ping` against the configured URL (new setting `nodes.public_url`, an `Arbiter.Settings.Installation` field).
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

**Prerequisite checks (all before the token is exchanged, so a failing machine does not burn it):** Linux, `uname -m` equals the release arch (x86_64 today **[U11]**), glibc ≥ 2.28 (the ubi8 baseline `scripts/check-release-glibc.sh` enforces), `curl`/`tar`/`sha256sum`/`git`, `podman` ≥ 4 with `podman info` reporting rootless, `/etc/subuid`+`subgid` ranges ≥ 65 536 (same thresholds as `PodmanReadiness`), **cgroup v2** (`stat -fc %T /sys/fs/cgroup` = `cgroup2fs`) **with the `memory` controller delegated to the user** (needed for `--memory`; **[U10; RW2]**: read `/sys/fs/cgroup/user.slice/user-<uid>.slice/user@<uid>.service/cgroup.controllers` **and** `cgroup.subtree_control` and require the controller in both: a login-session scope or `user-<uid>.slice` is not the delegation point, so `/proc/self/cgroup` alone misleads; cross-check with `podman info --format '{{.Host.CgroupControllers}}'`; and make a **functional probe** the authority, `podman run --rm --memory=64m --memory-swap=64m <image-on-node> true`, because a missing controller is a hard OCI error, not a silent no-op; prototype: `apps/arbiter/test/spike/remote_workers/prereq_checks.sh`), **linger** enabled (`loginctl show-user`), a reachable user systemd (`systemctl --user`, `XDG_RUNTIME_DIR`), free disk ≥ N GB under the node root. The agent re-runs `PodmanReadiness.diagnose/1` plus these at start and reports them in `hello`.

**Refuse versus sudo-install: refuse is right.** (1) `curl | bash` is already a maximal-trust action; adding privilege escalation multiplies the blast radius of a compromised or truncated script. (2) Package names, repos and cgroup delegation differ per distro; an installer that guesses wrong leaves a half-configured host. (3) Unattended sudo prompts break in a pipe and in cloud-init. (4) The operator already owns the host and can run the printed remediation. The script prints a copy-pasteable remediation list (for example `sudo dnf install podman`, `sudo loginctl enable-linger $USER`, a `systemd` `Delegate=` drop-in for `user@.service`) and exits non-zero. **One exception, user-level and no sudo:** if linger is off it tries `loginctl enable-linger "$USER"` (the same call `Systemctl.enable_linger/0` makes in `arb install-service`) and refuses with instructions only if that is denied **[U9; RW2: use `loginctl --no-ask-password enable-linger "$USER"`; on Fedora 44 / systemd 259 it succeeded for self with no sudo, no tty and no session id even though the polkit action is `auth_admin_keep`; other distros: needs operator, §17.1]**.

**Install steps:** enroll → store credential → `GET /nodes/agent/<version>.tar.gz` with the credential (sha256 checked against the enroll response) → unpack to `~/.arbiter-node/releases/<version>/`, atomic `current` symlink (the same symlink-then-rename `ReleaseFiles` uses) → write `~/.config/arbiter-node/agent.env` and `~/.config/systemd/user/arbiter-node.service` (`Restart=always`, `ExecStart=%h/.arbiter-node/current/bin/arbiter start`, `Environment=ARB_ROLE=agent`) → `systemctl --user enable --now` → wait for the first `hello` (poll `~/.arbiter-node/bin/arbiter-node status`) and print the result. The data dir is `~/.arbiter-node/`, deliberately not `~/.arbiter/` (the primary's default data home), so a test node on the primary's machine cannot collide. The wrapper `arbiter-node` has `status | logs | leave` (`leave` asks the primary to remove the node, then stops and disables the unit).

### 5.6 CLI equivalent

`arb node add [--name N] [--label k=v …] [--max-workers N] [--ttl 15m]` (operator-proof) prints the one-liner and the token (token to stdout only on a TTY, otherwise `--token-file`); `arb node list|show|drain|undrain|revoke|remove|set <name>`; `arb node events <name>`. On the node: `arbiter-node status|logs|leave`. `arb` has no `node` command today; `Cmd.Server` dispatch and `Main`'s alias table are where it lands.

**As built (RW4, bd-6kquah).** The server side of §5.2, §5.5 and §6 is in: `ArbiterWeb.NodeController` (`GET /nodes/join`, `GET /nodes/ping`, `POST /nodes/enroll`, `GET /nodes/agent/<version>.tar.gz`, `GET /nodes/files/<sha256>`), `Arbiter.Nodes.JoinScript` (+ `join_script.sh.eex`), `Arbiter.Nodes.Agent` (artifact), `/api/nodes*` and `arb node add|list|show|set|events`. Where it differs from, or fills in, the text above:

* **Enroll response format.** JSON by default; `Accept: text/plain` returns `KEY=value` lines (`node_id`, `name`, `credential`, `ws_url`, `agent_version`, `tarball_sha256`) because the script has no JSON parser (`jq`/`python` are not prerequisites). The script reads them without `eval` and validates each against a character set. `fence_after` is not sent yet (RW6 owns it).
* **The token is read from the request body only** (`conn.body_params`); a `?token=` query string is ignored, so it never reaches an access log. The agent artifact is checked **before** the token is redeemed: a primary with nothing to serve answers `503` and the token is not spent. A name clash is `409` and does not spend it either (`Nodes.redeem_join_token/3` hands it back).
* **`ARB_JOIN_TOKEN` is removed from the environment first thing in `main`**, so no child process (podman, curl, systemctl) is ever started with it.
* **`ARB_JOIN_CHECK_ONLY=1` does not change the machine**: it reports linger as "the real run enables it" instead of running `loginctl enable-linger`. A real run does enable it (the one fix), before the token is read.
* **`/nodes/files/<sha256>`** is content-addressed access to the same artifact (credential-gated); only the served agent tarball is addressable today. Later bundle kinds (checkout sync) add to it.
* **Artifact source.** `arb server deploy` retains `<data-home>/releases/<tag>.tar.gz` + `.sha256` (GitHub and `--local <tarball>`); pruning removes them with their release and sweeps orphans. A `--local <dir>` deploy has none, so `Nodes.Agent` packs the allowlist on first request into `<data-home>/nodes/agent-cache/<tag>.tar.gz` (outside `releases/`). The reported sha256 is always computed from the bytes served, never from the sidecar.
* **`arbiter-node leave`** stops and disables the unit and tells the operator to `arb node revoke`; asking the primary to remove the node needs an endpoint that RW7 adds. The unit starts `bin/arbiter start` with `ARB_ROLE=agent`, which a release without the role gate (RW5) treats as a primary: until RW5 lands the unit will not stay up, and the script ends with a warning rather than an error.
* **`ARB_JOIN_FS_ROOT`** prefixes the `/etc` and `/sys` reads, a test seam. Tests run the real script against the real endpoint with stubs for the host-inspecting tools only.
* **`arb node add`** refuses to print the token to anything but a terminal (`--token-file` writes it mode 0600, never overwriting); that decision is made before a token is minted.

## 6. Agent packaging, versioning and upgrade

**Artifact.** The agent is the release tarball the primary is running. The primary serves it: `GET /nodes/agent/<version>.tar.gz` (node credential; the enroll response carries the expected sha256).
* **Source of the bytes.** Today `ArbiterCli.Cmd.ReleaseDeploy` holds the downloaded tarball in memory (`Github.download_binary/1`, `release_deploy.ex:208`), verifies the `.sha256`, and unpacks it (`ReleaseFiles.unpack!/2`); it keeps no tarball. Change (child 4): retain `<data-home>/releases/<tag>.tar.gz` + `.sha256` next to the unpacked tree and prune with it (`ReleaseFiles.prune_old_releases/3`). Serving the **pristine** published bytes means the checksum equals the published `.sha256`. For `arb server deploy --local <dir>` (no tarball exists) the primary packs the tree on first request with an **allowlist** (`bin/`, `erts-*`, `lib/`, `releases/<vsn>/` minus `COOKIE`/`tmp`), never a denylist, and caches by sha. Rejected: nodes downloading from GitHub Releases (a private repo needs `GITHUB_TOKEN` on every node; a local build is not published).
* **Upgrade path *(A1)*.** `hello_ok.upgrade` is `tarball` (machine nodes, above) or `image` (cluster nodes: the operator rolls the controller Deployment to the new image; the primary never pushes bytes to it). `caps.upgrade` declares which a node supports; version-skew rules are unchanged.
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

* `image` (content-hash tag), `name`/labels (`arbiter.install`, `arbiter.node`, `arbiter.run`, `arbiter.task`), mounts as **kinds** (`worktree`, `run_home`, `config_dir`, `cli`, `objects_overlay`, `prompt`, `bridge:<name>`), container-side paths **equal to the primary's** (path transparency, bd-aowisc §4.2, unchanged: `claude --resume` keys its session store on the cwd slug, `Usage.ClaudeSessionFile.project_slug/1`), env names + non-secret values, **secrets as a separate `secrets` map delivered through a tmpfs file mount, never as container env [RW2: U13]**, resource limits, bridge list, test-services definition, the command (`claude` argv incl. prompt).
* **Why spec, not argv:** the agent can refuse what it does not build. Its allowlist: mounts only under its own root, no `--privileged`, `--cap-add`, `--device`, `--userns=host`, `--pid=host`, `--network=host`. A compromised or mistaken primary then cannot turn the node into an arbitrary-container host, and the hardening (read-only root, dropped caps, `no-new-privileges`, `label=disable` only with bridges) is the *same code* as local.
* `ContainerSpawn.prepare/1` splits into a primary half (secret resolution, worker-tier token mint, `Egress.JailRun.start/1`, spec assembly) and a node half (shadow clone, image/CLI/deps, run dirs, listeners). The existing request map's `inherit_env` (names whose values ride the client's environment so they never hit argv) is exactly the secret list. **[RW2: U13]** For a remote run that list is **not** passed to podman as `-e NAME`: podman writes the resolved value into the container's OCI `config.json` and its state DB under the persistent graph root (§17.1). The node half instead writes the values to `$XDG_RUNTIME_DIR/arbiter-node/<run>/secrets.env` (dir 0700, file 0600, tmpfs), bind-mounts it read-only at `/run/arbiter/secrets.env`, and the container command is wrapped as `sh -c '. /run/arbiter/secrets.env; exec "$@"' -- <command…>`; the agent unlinks the file when the container exits (or earlier, once the wrapper has sourced it, if a FIFO is used instead of a file). The toolchain image has `sh`; the allowlist in the bullet above gains "the secrets file is the only mount allowed outside the run's own dirs".

* **Registry image reference *(A2)*.** When the node's `caps.image = "registry"`, `assign.image` is `{tag, ref}` where `ref` is a **digest-pinned** reference the primary has already pushed (new primary-side `Image.Publisher`, settings `nodes.registry.*`); the node never receives a build plan and refuses with `image_unavailable` if it cannot pull `ref`.

### 7.2 Port-shaped handle in `Arbiter.Worker`

`Worker` is Port-owned. The surface a remote run must satisfy is small and grep-verified: the three `handle_info({port, …})` clauses (`worker.ex:2844` eol, `:2848` noeol, `:2852` exit_status, all `when is_port(port)`), and the port-specific sites: private `terminate_session_port/2` (`safe_port_os_pid/1` at `:3605`, `OsProcess.kill_tree/1`, `Port.close/1` at `:3593`) and private `session_live?/1` (`:8232`, `is_port(port) and Port.info(port) != nil`). `ClaudeSession.open_scoped_port/2` (`claude_session.ex:1995`) is the single open point. Design: `Executor.Node.open/1` returns a **remote handle** (a `{:remote, ref}` tuple) and the `Nodes.Session` process sends `{handle, {:data, {:eol, line}}}`, `{handle, {:data, {:noeol, partial}}}` and `{handle, {:exit_status, n}}` with the same shapes (the line framing is `{:line, 65_536}` today, `open_port/1`). The guards relax to `is_port(p) or match?({:remote, _}, p)`; those two functions branch. **Rejected:** a local shim OS process that echoes channel data into a real Port (the Port owner is the Worker, so the relay cannot `Port.command`; needs FIFOs and exit-status gymnastics for no benefit).

### 7.3 Images, CLI binaries, deps cache (replaces bd-aowisc's warm repo)

* **Images.** Tags are content hashes of a digest-pinned Containerfile plus build args (`Image.plan/3`, `Image.Builder.ensure/3`; empty build context). The primary ships the **plan** (pinned Containerfile text, args, tag), and the node builds it with its own podman and verifies the resulting tag name. Measured sizes on this host: toolchain image 843 MB, of which the base is 464 MB. `podman save | load` through the primary would move 0.5–1 GB per toolchain per node and again whenever the weekly base refresh moves the tag. Chosen: **build from plan** (public upstream images only, deterministic inputs); `save`/`load` over HTTPS as an opt-in fallback for air-gapped nodes. Cost: first dispatch to a fresh node waits for a build **[U12]**; `ensure_ready` is synchronous with a bounded timeout and then `prefer_remote` falls back to local, `remote_only` holds the card.
* **Registry nodes *(A2)*.** For `caps.image = "registry"` the build-from-plan bullet above does not apply: the primary builds/pushes via `Image.Publisher` and sends `{tag, ref}` (§7.1); `image_unavailable` is the refusal.
* **CLI binaries.** `claude` and `arb` are mounted read-only at `/opt/arbiter/cli` today (private `ContainerSpawn.cli_mounts/1`). The primary exposes them content-addressed: `GET /nodes/files/<sha256>`; the node caches under `root/files/<sha12>/` and verifies the hash. Same-arch constraint as §6.
* **Deps cache.** `DepsCache` (`key/4`: `<root>/<lock12>-<image12>`; `ensure/4` runs a seed job inside the image; `install/3` does `cp -a --reflink`) is a *node-local* concern now: the agent runs it against its own root and podman. Inputs it needs from the primary (it must not read the primary's DB; `DepsCache` aliases `Arbiter.Mergers`, **[U6]**): the default-branch `mix.lock` hash, `seed_paths` resolved by `Worker.SeedPaths.resolve/2`, and the default-branch tree as a bundle (below). **The "warm repo" is gone**; what remains is a per-node bare **object store** `root/repos/<slug>.git` that bundles fetch into and shadow clones borrow from (alternates + `:O` overlay), exactly as `PrivateClone.mounts/1` already guards for the local main repo.
* **Thin home clone for remote placement.** For a remote-placed run the primary provisions the home clone **without** `seed_compiled_deps/3` and `ensure_deps_fetched/1` (`PrivateClone.provision/1` calls both at `private_clone.ex:231-232`), via a `seed: false` option threaded through `Worktree.create/4`. Otherwise the primary pays the cost remote exists to avoid.

### 7.4 Teardown and memory cap (bd-aowisc §4.2 carries over)

`podman run --memory=<cap> --memory-swap=<cap>` (plus optional `--cpus`) replaces `MemoryScope`, which is a local systemd-scope construct and does not cover a container (`ClaudeSession.open_scoped_port/2` skips it for podman). `Container.argv/2` gains four **additive, pure** options (child 8a, also usable locally): mount mapping, `--memory/--memory-swap/--cpus`, `--label` pairs, omit `--rm` (so `.State.OOMKilled` survives; `StopReason.classify/3` and the private `Worker.mark_memory_cap/2` (`worker.ex:2706`) already consume an OOM outcome). The `exit` event carries `oom?` and the container exit code. Teardown by name (`Container.stop/2`, `TestServices.teardown/2`) now runs **locally on the node**, driven by `cancel`; the primary no longer needs a control channel to do it. The node-side cap default is a percentage of the node's `MemTotal` (e.g. 40 %), reported by `hello`. A node that cannot enforce `--memory` (no memory controller delegated) reports `degraded: :uncapped` and is excluded from placement unless the operator sets `allow_uncapped` (fail-closed, as in bd-aowisc: the cap protects the node's owner). **[RW2: U8 GO]** Verified rootless on Fedora 44 (podman 5.8.7, crun, cgroup v2, systemd manager): a 300 MB allocation under `--memory=64m --memory-swap=64m` exits 137 with `.State.OOMKilled=true` and the flag is readable after exit **because `--rm` is absent** (with `--rm` the container, and the flag, are gone before anyone can read it); an in-cap run reports `OOMKilled=false`. `--cpus` works where `cpu` is delegated; a limit whose controller is *not* delegated (`--cpuset-cpus` here: `cpuset` is not in the default delegation) fails the `run` with ``crun: controller `cpuset` is not available``, so the agent must only emit limits for controllers it found delegated (memory, pids, cpu) and never `--cpuset-cpus`/blkio unless probed.

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

**Cost (first paragraph = original estimates; measured numbers from RW2 follow, §17.1 has the full matrix):**
* Latency: each new proxied connection pays one node↔primary RTT for the `CONNECT` answer, and each TLS handshake round trip (the handshake is end to end through the tunnel) pays RTT_np in addition to RTT_primary↔API. Over a tailnet RTT_np is roughly 1–30 ms direct, 50–150 ms via a DERP relay. The CLI holds long-lived connections to the model API, so the per-turn overhead is about one RTT_np on time-to-first-token against model latency measured in seconds. `arb`/MCP calls are small JSON, tens of ms.
* Throughput: model SSE is KB/s; the heavy case is a `git push` through the proxy (MBs) and anything a worker pulls through the allowlist. A tailnet link sustains far more than these; the 1 MiB per-node in-flight cap bounds memory on the primary.
* Primary CPU: one extra relay hop and frame codec per stream. Acceptance criteria for the spike (§18, child 2): added p99 latency ≤ 250 ms at 10 concurrent runs over a replay of a recorded SSE stream, and heartbeat jitter < 5 s during a 5 MB push.
* **[RW2 measured]** 10 concurrent runs, one 20 s SSE trace each (8,290 events, 40 events/s/run, 120–420 B), through `client → node unix listener → WebSocket (Bandit, real TCP, `tc netem`) → channel → primary unix listener → fake upstream`: added p99 is **3 ms** on loopback, **4 ms** at 2 ms RTT, **12 ms** at 20 ms RTT, **42 ms** at 80 ms RTT, and about **one half RTT plus a few ms** in general; it breaks 250 ms only on a lossy long path (150 ms RTT with ≥ 0.5 % loss: 1.39 s at 20 Mbit/s, one retransmission stall delays every run on the socket) or a saturated uplink (2 Mbit/s). A *new* connection through the tunnel costs one to two node↔primary round trips (p50 ≈ 1.06 × RTT) on top of its own CONNECT/TLS round trips, which the CLI pays once per connection (it keeps them alive). BEAM CPU for the whole spike (both ends, client generator included) rose by 2.4–6.4 s per 20 s of 10-run streaming (about 0.1–0.3 of a core; 0.6 on the saturated 2 Mbit/s link), of which the primary's share is a fraction.
* Failure: if the socket drops, every bridge stream for the node is cut; the Claude CLI's own retry rides through a drop shorter than the fence (§10.2) if it retries a refused local socket **[U19]**.

## 9. Checkout sync (replaces `git fetch` over ssh)

The home/shadow model (bd-aowisc §4.4) is unchanged: while a container runs the shadow clone on the node is the sole writer; at every other moment the home clone is authoritative and no host-side code reads the shadow. Only the transport changes, to **bundles over HTTPS**.

**Seed (primary → node).** On `assign` the node reports `have: [sha…]` (tips in its object store). The primary builds a thin bundle: `git bundle create - <tips> ^<have…>` from the home clone/main repo (full bundle when `have` is empty or contains unknown shas), and the node `GET /nodes/runs/:run/seed.bundle` and `git fetch`es it into `root/repos/<slug>.git` under `refs/arbiter/in/<run>/*`, then builds the shadow with the existing `PrivateClone.build/1` locally. Measured on this repo: the pack is 29.6 MB, a full bundle of five weeks of history is 15.6 MB, so the first dispatch to a node is a one-time tens of MB.

**Pull-back (node → primary) at port exit, at every checkpoint (default 5 min), and in recovery.** On the node, inside the shadow: write the snapshot commit with a temporary index (`GIT_INDEX_FILE=<tmp> git add -A && git write-tree && git commit-tree -p HEAD`) to `refs/arbiter/snapshot/<run>`, honouring `.git/info/exclude`, then `git bundle create` of the branch, the snapshot ref and the clone's remote-tracking branch with prerequisites `^<known>` where `known` is what the primary told it at seed. `PUT /nodes/runs/:run/checkout` with `Content-Length` (cap, default 256 MiB; snapshot untracked payload cap stays 50 MB with a placement veto from bd-aowisc §4.4).

**Ingest on the primary (`Nodes.Checkout`, new): a quarantine, in this order:**
1. Stream the body to a private scratch file; enforce the size cap; verify the run is assigned to the caller and live.
2. `git bundle verify`, then fetch into a **throwaway bare repo** (`git init --bare`, `fetch.fsckObjects=true`, `transfer.fsckObjects=true`, `core.hooksPath=/dev/null`), refspec limited to the **ref allowlist**: `refs/heads/<run branch>`, `refs/arbiter/snapshot/<run>`, `refs/remotes/origin/<branch>`. Any other ref, or a ref pointing outside the expected namespace, rejects the whole bundle **[U7: fsck on bundle fetch]**. **[RW2: U7 GO]** Three facts from the prototype matter here: (a) `git bundle verify` checks prerequisites and connectivity, **not content**: a bundle whose tree contains `.git/config` verifies fine, and with `fetch.fsckObjects=false` it is accepted into the quarantine; with `fetch.fsckObjects=true` the fetch dies (`error: object …: hasDotgit: contains '.git'` / `fatal: fsck error in packed object`) and no ref lands, so **fsckObjects on the quarantine is the gate**, not `verify`; (b) the fetch must pass **`--no-tags`**, because git's tag auto-following imports `refs/tags/*` from the bundle even with a refspec naming only one branch, so the ref allowlist is `bundle list-heads` (reject if any head is outside the allowlist) **plus** `--no-tags` plus explicit refspecs; (c) an empty directory is not representable in a tree, so the snapshot drops it (harmless; noted as a known gap).
3. Object-count/size bounds via `rev-list --objects`.
4. **Primary-side path filter (authoritative):** the snapshot tree is checked against the primary's own deny list: the `@ignored_artifact_paths` set in `Worktree` (`.mcp.json`, `.gemini/`, `.codex/`, `.arbiter/`, `deps`, `_build`, …) plus the run's recorded seeded paths (`Worktree`'s private seed record reader `seeded_paths/1`). Matching paths are removed from the index before any checkout. The node-side exclude file is only a bandwidth optimisation: it lives in the shadow's `.git`, which the container can write, so a compromised agent run could hide or add files by editing it.
5. Only then: fetch from the quarantine repo into the home clone and apply the existing handoff (force the branch to the fetched tip, `git read-tree -u --reset <snapshot>` + `git reset --mixed <tip>` so changes read as uncommitted to `Worktree.has_uncommitted?/1`; record `{head_sha, status_hash}`), and proceed with `commit_gate/1`, `Worktree.sync_back/1`, ReviewGate, MergeQueue unchanged.

**This is stricter than local.** A bundle carries objects and refs only: **no config, hooks, `info/`, alternates or any other `.git` file** ever reaches the primary, and the primary's git never reads the container-writable `.git` of the shadow. Locally today the host git reads the private clone directly under the `PrivateClone.mounts/1` guards.

**Rejected:** *smart-HTTP receive-pack* (a git credential on the node's disk or argv, an `http-backend`/`receive-pack` process to run and sandbox, ref negotiation we do not need for a one-way snapshot); *fetching from the node's `.git` over any channel* (touches untrusted repo state); *rsync/tar of the tree* (loses commits/rename detection, no fsck).

## 10. Liveness, restart and reconciliation

### 10.1 Heartbeat, fence and lost (replaces the lease file)

* `hb` every 10 s with per-run state and `stdout_seq`; `hb_ack` carries cumulative acks. The primary marks a node **suspect** after 30 s of silence.
* **Agent self-fence:** if the agent has not received a `hb_ack` for `fence_after` (60 s, set by the primary in `hello_ok`, bounded **30–90 s** [RW2: was 30–300 s; U19, §10.2]), it stops its containers (`Container.stop/2`), keeps the shadow clone and transcripts on disk, and keeps trying to reconnect.
* **Primary declares the node lost at 90 s** (`lost_after = fence_after + 30`). **Invariant: `fence_after < lost_after`**, with slack for clock skew, so by the time the primary re-dispatches elsewhere the old container is already stopped. Each side uses its own monotonic clock; neither depends on a shared clock. A node that is dead (not partitioned) has no container to worry about.
* `fence_after`, `lost_after` and `hb_interval` are install settings (`nodes.fence_after_s`, …) validated for the invariant.

### 10.2 Channel blip (survives) versus restart (does not)

A socket drop shorter than `fence_after` with an unchanged primary `boot_epoch` is a **blip**: the primary's `Worker` process is alive (its remote handle is held by `Nodes.Session`, whose state is the run table), the container keeps running (stalled only for bridged network), and on reconnect the node resends unacked stdout from the last acked offset and re-listens bridges. No state is lost. Worker output lines are never dropped and never duplicated (offset+ack, the `Sessions.Stream` scheme). **[RW2: U19 GO]** What the in-container CLI sees during a blip was measured against the real Claude CLI (2.1.291, `HTTPS_PROXY` through a CONNECT relay and TLS, a fake API, no real credential; §17.1): it rides through a proxy that **stalls** new connections for at least 120 s, **refuses** them for at least 180 s, or **resets** them for at least 90 s (it gives up at about 177 s of resets), and resumes 0.2–0.3 s after a stall releases but only after its own backoff (0–36 s later) after a refuse or reset. So while the channel is down the agent's per-run listeners should **accept and hold** (not read) new connections up to `fence_after`, and reset them when the fence fires; **`nodes.fence_after_s` is capped at 90 s** (the design's 30–300 s range is narrowed). The stdout replay cursor is the opaque string of §4.2 *(A4)*: the node resends everything after the last acked cursor whatever its form. A drop **mid-response** is not resumed: the CLI re-sends the whole request (two POSTs seen), so the partial answer is discarded and the request is billed again.

### 10.3 Node lost

`Nodes.Session` gives up (`lost_after`) → every run on it is stamped **interrupted** ("node lost: <name>"), **not failed**, and **no resume attempt is consumed** (the policy `Reconciler` applies to "server shutdown" runs, `reconcile_shutdown_casualties/1`). New classification `:node_lost` in `StopReason.classify/3` (`stop_reason.ex:456`) distinguishes it from an ordinary agent failure. **`pod_disrupted` *(A5)*:** a second new cause for cluster nodes (pod evicted, preempted, or deleted externally) with the same policy as `node_lost`: interrupted, no resume attempt consumed. The node is marked offline; auto-resume re-dispatches via `Placement` (another node or local per mode); the new spawn builds a fresh shadow from the home clone and `claude --resume` finds the mirrored transcript at the same cwd slug (bd-aowisc §6.2). Work since the last checkpoint is lost unless the node returns (below). One coordinator escalation per outage over 15 min, not per tick (`Messages.Escalation`).

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
| Provider token (`CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`), `worker_env` values (including forge tokens used by in-container `git push`) | **memory and tmpfs only**, delivered per run inside `assign`, written by the agent to a 0600 file under `$XDG_RUNTIME_DIR/arbiter-node/<run>/` (tmpfs), bind-mounted read-only into the container and sourced by the command wrapper (§7.1); **not** passed as `-e NAME` | Never on argv, never in a file on persistent storage. **[RW2: U13 GO-WITH-FALLBACK]** The original plan (`-e NAME` with the value in the `podman` client's environment) does **not** keep secrets off disk: podman stores the resolved value in the container's OCI `config.json` under `~/.local/share/containers/storage/overlay-containers/<id>/userdata/` and in its state DB `…/storage/db.sql`, both on the persistent graph root (btrfs here), not under `$XDG_RUNTIME_DIR`; both are cleaned by `podman rm` (no copy found afterwards in either file), but a crashed agent leaves them until the reaper runs. The file-mount path leaves no copy anywhere podman writes, not in `podman inspect`, and the process still has the value in its environment. tmpfs can be swapped out like any process memory. The same on-disk exposure exists today for **local** podman workers using `-e NAME`; it is out of scope here but worth a follow-up |
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
* **Candidates:** enabled ∧ `online` ∧ not `draining`/`revoked` ∧ health `ready` (not `outdated`/`incompatible`/`ahead`/`degraded: :uncapped`/`degraded: netpol_unenforced` *(A7)*, the latter overridable per node by `allow_unenforced_network`) ∧ not `hb.capacity.constrained` *(A3; a constrained node is skipped, or ranked last when it is the only candidate)* ∧ label match ∧ provider-account filter ∧ `live < effective_max`; rank by lowest `live/effective_max`, then reported free memory, then name.
* **Capacity sources:**
  * **Node-reported** (`hello`): cpus, `MemTotal`, a **suggestion** = `min(floor(cpus / cpus_per_worker), floor(0.8 × MemTotal / worker_mem_cap))`, and an optional **node-owner ceiling** from the node's own config (`ARB_NODE_MAX_WORKERS` in `agent.env`; the machine's owner says "never more than N here").
  * **Operator-set** `max_workers` on the node row (nullable).
  * **Effective** = `min(operator, node ceiling)` over whichever are set; if neither, the suggestion. So the operator can lower below the ceiling but never raise above what the node's owner allows. A drain sets effective to 0 for new work.
* **`conductor.max_concurrent`** (`Board.Snapshot.system_max_concurrent/0`, `Arbiter.Settings.Installation` field `conductor_system_max_concurrent`) stays the install-wide ceiling on workers anywhere (local plus all nodes) and stays **operator-owned**: it is also the quota/billing valve, so auto-raising it on join would raise spend without the operator asking. The node list shows `local + Σ effective = M` against `conductor.max_concurrent = K` and warns when K < M (nodes idle) or K much greater (over-planned). A later child adds a placement-headroom term to `effective_max_concurrent/3` so the board stops promising slots no node can serve (board planning cannot know which Ready card is remote-eligible, so a plan can exceed capacity and a brief `{:no_node_capacity, _}` hold results).
* **Cluster capacity *(A3)*.** The primary counts a run as started only when the node reports it `running` (not at `assign`); `Executor.prepare` returns at *container running*, not at "agent finished image/CLI/deps/shadow". `hb.capacity{ceiling, running, pending, headroom, constrained}` feeds the effective-max calculation above, and `hello_ok.limits.prepare_timeout_s` bounds the wait.
* Memory-weighted capacity is out of scope; load is advisory.

## 14. Operator surface

* **Nodes page** `/nodes` (**new** `ArbiterWeb.NodesLive`, in the `live_session :default` block of `router.ex` so it inherits the `:dashboard_auth` on_mount gate and the nav). One row per node (`#node-<id>` in a `#nodes-table`): name, state chip (`online | offline | draining | revoked`), health chip (`ready | degraded | outdated | incompatible | ahead`), **live/max** (live from the registry; max shown as effective with its sources on hover: operator, node ceiling, suggestion), agent version against server version, arch, labels, last seen, readiness summary. Row actions: Drain/Undrain, Upgrade (when `outdated`), Revoke (confirm), Remove (only revoked/offline with no live runs), Set max/labels. Footer line: `local N + nodes Σ effective = M` against `conductor.max_concurrent = K` with the §13 warning. Before editing list headers, check which `index_header` component the page actually renders: two exist with the same name (`Domain.index_header` is the rendered one).
* **Add node** (`#add-node-button` → `#add-node-modal`): a **kind selector** (machine | cluster, *A7*), name, labels, max workers, TTL → mints a `JoinToken` → shows the one-liner (`#join-command`, copy button), the token separately (`#join-token`, shown once, copy button), a countdown (`#join-countdown`) and a "Waiting for node…" state that flips to "Connected" when the node enrolls (PubSub on a `nodes` topic, no polling). Closing the modal after redemption or expiry discards the secret. Requires the dashboard grant (`ArbiterWeb.DashboardAuth`): the dashboard is operator-only, so this is the "authenticated user" of the brief.
* **Cluster nodes *(A7)*.** The node row and `NodeEvent` carry `kind`; cluster rows show `k8s_version`, the `degraded: netpol_unenforced` chip, and `hb.capacity.constrained` (A3).
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
| run transfer token `arbr_` (§16; *not used by cluster nodes, A6*) | 401 | 401 | none | 401 | that one run's `/nodes/runs/:run/*` only |
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

## 16. Kubernetes in-cluster agent (bd-1nfuq5; replaces the earlier "what it needs" stub)

> Committed by bd-dkwn9e. Status: **proposed**. Section numbers `§N` *inside* this section (headings `### 0.` … `### 17.`) are local to it and are cited as **K§N** from outside; a bare `bd-bw8a0m §N` is a section of this document's other parts. Its amendments A1–A7 (K§14) have been applied to §4.2, §6, §7.1, §7.3, §10.2, §10.3, §13 and §14 above and below; each is marked *(A#)*.
>
> **Operator rulings, 2026-10-06 (epic bd-2dvh9q):** (1) the existing k3s (mesanna/aginor) is a **test bed only**: the K1 spike runs on a disposable kind/k3d cluster, and the operator's k3s is touched only with an explicit go-ahead (the kubeconfig is cluster-admin and the cluster hosts vstim prod and CI). (2) The operator's spare laptop starts as a machine node and joins a cluster later. (3) P3: nothing is promoted until RW1 (bd-dufrgb) and the RW2 spike (bd-6tx1xv) land; then K0 and K1 are promoted.

> **K1 spike, 2026-10-06 (bd-6zl538):** the §15 assumptions **K1, K2, K3, K4, K5, K6, K8, K10 and K11** were run against a real Kubernetes API server (k3s v1.36.5+k3s1, Pod Security `restricted` on the namespace, in a disposable QEMU/KVM VM on the operator's laptop; all testing ran there, with **one exception that is recorded in §15.1: a single stray `kubectl delete` reached the operator's k3s, with no operator approval and no effect**). Verdicts are in the last column of the §15 table; evidence, commands and the design changes are in **§15.1**; the amendments **K1-A1 … K1-A10** are applied to the sections below and marked *(K1-A#)*. **Gate result: no NO-GO; K3–K9 may proceed.** K2 and K6 carry fallbacks that are now part of the design (the seed gate, K1-A3; checkpoint-only recovery on eviction, K1-A7), and K2 on the operator's own kube-router still needs the operator to run one script (§15.1, *Needs operator*).

Research (the original design pass, written with no code and no cluster contact; the K1 spike above did run clusters, §15.1). It reuses bd-bw8a0m's node protocol, enrollment and auth tier; every change it needs from them is listed in K§14 as a numbered amendment (A1–A7), now applied to the sections of this document marked *(A#)*.

Sources: bd-bw8a0m `notes` (read in full), bd-aowisc `notes` §7 (the eight "what k8s still needs" items; §5 below maps each), bd-2jerqw (seed paths, shipped), the repo at `9b5fb0733` (names verified, §17), and the admiral memory `reference-mesaana-cluster-survey-2026-10-04` plus `reference-k3s-cluster-node-ip-is-load-bearing` / `reference-vstim-k8s-cluster`. **In that design pass I ran no `kubectl` and touched nothing in any cluster** (the K1 spike's own cluster contact is recorded in §15.1); every cluster fact below is from that 2026-10-04 survey and may have drifted. Anything relied on but not observed is **[K#]**, indexed in §15.

### 0. Decisions in one screen

| # | Decision | Losing option(s) |
|---|---|---|
| 1 | **The controller is the Arbiter release in `ARB_ROLE=agent` with `ARB_AGENT_BACKEND=k8s`**: one `Deployment` (1 replica, `Recreate`, plus a `Lease` guard) in a dedicated namespace. To the primary it is an ordinary node (`kind: cluster`), same socket, same credential, same `hello`/`hb`/`assign`. | A separate Go/Rust controller (second build, skew, re-implements the hardening builder); a CRD + operator (cluster-scoped install, nothing a single config object needs). |
| 2 | **One bare `Pod` per run, `restartPolicy: Never`**, not a `Job`. | `Job` (§3.1). |
| 3 | **Install = primary-rendered plain manifests** (two documents: admin bootstrap, node), join token supplied separately as a Secret. | Helm chart (separately versioned, needs hosting, `genCA` pitfalls); Kustomize. |
| 4 | **Config = a ConfigMap with a closed schema**, mounted as a file; operator knobs only, security fields are not configurable. | CRD-lite; a raw `PodTemplate` (would let the operator bypass the hardening builder). |
| 5 | **Capacity = the in-cluster ceiling** (`max_concurrent`) reported as the node ceiling; the controller is a second admission gate that sees `ResourceQuota`; a pod that is not scheduled is `pending`, never `running`. | Reporting node CPU/RAM sums (the controller cannot even read `nodes`). |
| 6 | **Bridges: controller-hosted mTLS listener, no per-pod sidecar.** Pods connect to the controller's `Service`; the controller relays each connection into the existing `bridge.open` stream. Policy, audit and `BridgeIdentity` stay on the primary, unchanged. | Per-pod relay sidecar (same TLS client, plus a container per pod on a CPU-tight cluster); reaching into pods with `pods/exec`/`portforward`; plain TCP (cleartext on the pod network). |
| 7 | **Checkout: init container pulls a git bundle from the controller into an `emptyDir`; a native sidecar (`snapshotter`) pushes checkpoint and final bundles back through the controller.** No `pods/exec`, no PVC for the tree. | PVC (RWO node pinning on local-path); the controller running `git` on the pod's tree; `kubectl cp`/exec. |
| 8 | **Warm deps/`_build` seed = an image layer** built on the primary from `DepsCache` output and pushed to the registry; `bd-2jerqw` `seed_paths` outside `deps`/`_build` ride in the same layer. | PVC cache (node-pinned, RWX absent); fetching per run (minutes + needs egress); in-cluster seed Job. |
| 9 | **Images: the primary builds and pushes to an operator registry** (`nodes.registry`), the pod pins a digest. Controller image is built from the retained release tarball and pushed the same way. | Node/in-cluster builds (kaniko/buildah need privilege); `save | load`; CI-published GHCR images (private-repo auth, `--local` deploys have none). |
| 10 | **Test services = native sidecars in the run pod** (`restartPolicy: Always` init containers with a `startupProbe` running the existing `ready` argv), translated from the existing `TestServices` service specs. | A per-run service pod (separate network namespace: `127.0.0.1` stops working). |
| 11 | **Secrets: nothing per-run is stored in etcd.** The pod carries only a single-use boot nonce; the init container redeems it from the controller over TLS into a memory `emptyDir`. The cluster holds long-term only the node credential, the CA key and (optionally) a tailscale auth key. | Per-run Kubernetes `Secret`s (readable by anyone with `get secrets`, at rest in etcd/sqlite); secrets as pod-spec env (visible in `kubectl describe`). |
| 12 | **Hardening: a pure pod-spec builder with a one-to-one mapping from `Container.argv/2`** (§8), enforced server-side by Pod Security `restricted` on the namespace and, optionally, a `ValidatingAdmissionPolicy` that bounds the controller's service account. `label=disable` is **not** carried over. | Trusting the builder alone. |
| 13 | **`--network=none` has no Kubernetes equal; it is replaced by NetworkPolicy plus a controller-run canary that fails closed** (`degraded: netpol_unenforced` excludes the node from placement). | Assuming the CNI enforces. |
| 14 | **First target: the existing k3s is a test bed, not yet a production target** (§13). Ceiling 2 pods. | — |
| 15 | **Breakdown: 14 children (K0–K13), none above D3** (§16). | — |

### 1. What the protocol already gives, and what a cluster is not

bd-bw8a0m §16 already reserved the shape: `hello.kind = "cluster"`, `caps.backend = "k8s"`, `caps.image = "registry"`, `caps.limits = "pod"`, capacity = the controller's own ceiling (§13 there), a declarative run spec with mount **kinds** (§7.1 there), no podman argv. This design takes that literally. The agent polymorphism sits in an agent-internal behaviour, `Arbiter.NodeAgent.Backend` (**new**, K2: `inventory/0, start_run/1, signal/2, stop/1, outcome/1, collect/2, list_owned/0, reap/1, capacity/0, readiness/0`); the podman run supervisor of bd-bw8a0m child 9 is the first implementation, `Backend.K8s` the second. The primary's `Executor.Node` is untouched.

Differences a cluster forces (each is a section below):

| Machine node | Cluster node | Where |
|---|---|---|
| agent installed as a user systemd unit by a script | a `Deployment` applied by an admin | §2 |
| ceiling = `ARB_NODE_MAX_WORKERS` + suggestion from cpus/mem | ceiling = ConfigMap `max_concurrent`; the cluster scheduler decides placement | §4 |
| `--network=none` is a kernel guarantee | NetworkPolicy, enforcement depends on the CNI | §8, §9 |
| bridges are unix sockets bind-mounted into the container | bridges are mTLS TCP to the controller `Service` | §9 |
| shadow clone on the node's disk, retained after exit | `emptyDir` dies with the pod, so the final snapshot must leave *before* the pod does | §10 |
| image built on the node from a plan | image pulled from a registry, pushed by the primary | §11 |
| node credential in `~/.config` | node credential in a Secret, rotated in place | §2, §12 |
| agent self-upgrades its tarball | agent image is immutable; upgrade = patch own Deployment's image | §2.4 |
| node may not be on the tailnet by definition | **a cluster usually is not on the tailnet** | §2.3 |

### 2. Installation

#### 2.1 What "Add node" emits

The modal gains a kind selector, **Machine | Kubernetes cluster**. The machine flow (bd-bw8a0m §5.5/§14) is unchanged. For a cluster it asks for: node name, namespace (default `arbiter-workers`), max concurrent pods, per-pod CPU/memory, optional node selector, optional `imagePullSecrets` name, join-token TTL. It **refuses to continue** when `nodes.registry` is unset (§11) and shows the doctor hint, because a cluster node cannot take a run without an image it can pull.

It mints the same `JoinToken` (single-use, hashed, 15 min, shown once), with `kind: cluster` and the form values pre-bound to the future node row, and shows three things:

1. **Manifests**: a **Download** button and a copy-able command, `kubectl apply -f <(curl -fsSL "<public_url>/nodes/join/k8s.yaml?name=…&max=2")`. The route is anonymous like `/nodes/join` and renders from query parameters; **it contains no secret** (no token, no credential, no CA key), so it can be cached, diffed and committed. Download exists because the machine running `kubectl` may not be on the tailnet.
2. **The join Secret command**, token read from the terminal, never in history or argv: `read -rs T && printf %s "$T" | kubectl -n arbiter-workers create secret generic arbiter-join --from-file=token=/dev/stdin`.
3. The same "Waiting for node…" → "Connected" countdown, and a **cluster readiness line** fed by the controller's first `hello` (netpol canary, quota, registry pull test, PSA, §9).

`arb node add --kind cluster [--name N --namespace NS --max-workers N …] -o manifests.yaml` is the CLI equivalent (operator-proof token, as for machines); the token goes to `--token-file` or a TTY.

**Why plain manifests rather than Helm.** The server already knows its version, `public_url`, registry and the exact image digests, and renders them in; a chart is a second versioned artifact with its own hosting and skew, and `genCA` regenerates on upgrade unless fought. Helm can be layered on the same manifests later; nothing here precludes it.

#### 2.2 The manifests

One rendered file, two parts, applied in order (separate files via `?part=bootstrap|node`):

* **bootstrap (needs cluster-admin once):** `Namespace arbiter-workers` with `pod-security.kubernetes.io/enforce: restricted` (+ `enforce-version: latest`, `audit`/`warn: restricted`); `PriorityClass arbiter-worker` (value `-100`, `preemptionPolicy: Never`, so prod workloads and CI win every contention); `ResourceQuota`; `LimitRange` (defaults so a pod missing limits cannot slip in); the NetworkPolicies of §9; optionally the `ValidatingAdmissionPolicy` of §7.
* **node (namespace-scoped):** ServiceAccounts `arbiter-controller` and `arbiter-worker`, `Role` + `RoleBinding` (§7), placeholder Secrets `arbiter-node-credential` and `arbiter-controller-ca` (empty; the controller fills them, so the Role needs only `get`/`update` on those names), ConfigMap `arbiter-controller-config` and `arbiter-ca`, `Lease arbiter-controller`, `Service arbiter-controller` (ClusterIP, ports 9443 bridge / 9444 boot+checkout), and `Deployment arbiter-controller`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: arbiter-controller, namespace: arbiter-workers}
spec:
  replicas: 1
  strategy: {type: Recreate}              # never two controllers with one credential
  selector: {matchLabels: {app.kubernetes.io/name: arbiter-controller}}
  template:
    metadata: {labels: {app.kubernetes.io/name: arbiter-controller, app.kubernetes.io/component: controller}}
    spec:
      serviceAccountName: arbiter-controller
      priorityClassName: arbiter-worker
      securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: controller
        image: <registry>/arbiter-agent@sha256:<digest>    # = server version, pinned by the renderer
        env:
        - {name: ARB_ROLE, value: agent}
        - {name: ARB_AGENT_BACKEND, value: k8s}
        - {name: ARB_PRIMARY_URL, value: https://<primary>.<tailnet>.ts.net}
        - {name: ARB_NODE_NAME, value: mesaana-k3s}
        securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
        resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {cpu: "1", memory: 512Mi}}
        volumeMounts: [{name: join, mountPath: /etc/arb/join, readOnly: true},
                       {name: config, mountPath: /etc/arb/config, readOnly: true},
                       {name: tmp, mountPath: /tmp}]
      volumes:
      - {name: join,   secret: {secretName: arbiter-join, optional: true}}
      - {name: config, configMap: {name: arbiter-controller-config}}
      - {name: tmp,    emptyDir: {sizeLimit: 512Mi}}
```

The controller runs under the same hardening as a worker; it has a service-account token (it needs the API) and it does not run untrusted code.

#### 2.3 Reaching the primary (the part a machine does not have)

The controller needs the same thing a machine needs: outbound HTTPS to `nodes.public_url` (bd-bw8a0m §4.3). **A cluster is generally not on the tailnet** (vstim's workers reach the tailnet through their own tailscale sidecar, per `reference-vstim-k8s-cluster`). Two supported paths, the second being the "private overlay with TLS in front of loopback" path 2 of bd-bw8a0m §4.3:

* **A (recommended, matches existing practice): a tailscale sidecar in the controller pod, userspace networking** (`TS_USERSPACE=true`, no `NET_ADMIN`, no `/dev/net/tun`), exposing an outbound HTTP proxy on `127.0.0.1:1055`. The agent's WebSocket client connects through it (Mint's `proxy:` option carries a Phoenix WebSocket through it, **[K11]** verified for 30 minutes, §15.1). *(K1-A10)* The client reads `HTTPS_PROXY`/`ALL_PROXY` itself and passes `proxy: {:http, host, port, []}`, because Mint does not read the environment; CA trust goes in the *target's* `transport_opts`; and it tells `econnrefused` on the proxy (sidecar not up: retry with backoff) from `{:proxy, {:unexpected_status, 500}}` (the tailnet is down or an ACL refuses: report `unreachable`). The tailscale variant's readiness is `tailscale status` = Running, **not** "the proxy port is open": a logged-out `tailscaled` listens on the proxy port and answers every CONNECT with 500. The auth key is an **ephemeral, pre-authorised, tagged** key (`tag:arbiter-node`, ACL to `tag:arbiter-primary:443` only) in a Secret `arbiter-tailscale`; this is the one standing secret the cluster holds besides the node credential (§12). The manifests include the sidecar only when `?reach=tailscale` is chosen.
* **B: a reachable HTTPS endpoint** for the primary (a reverse proxy with a valid certificate on a private overlay or LAN) given as `nodes.public_url`. The controller accepts only `https` with a verified chain; plain `http` is refused (the loopback-only exception of bd-bw8a0m does not apply in a pod).

Public-internet exposure stays refused by default (bd-bw8a0m §4.3 item 4). A cluster-egress NetworkPolicy for the controller (§9) limits *where* this traffic may go, which is a second reason to prefer A: the controller then needs egress to the tailscale control/DERP endpoints, not to the primary's LAN address.

#### 2.4 First boot, credential, upgrade

1. The controller reads `/etc/arb/join/token`; if `arbiter-node-credential` is empty it `POST /nodes/enroll` (token in the body, as bd-bw8a0m §5.2; body adds `kind: cluster`, `k8s_version`, `proto`, `agent_version`). It gets the node credential back and writes it to the Secret `arbiter-node-credential` (RBAC `update` on that one name). Subsequent starts read the Secret and skip enroll. The join Secret is then spent; the admin may delete it (the controller deliberately has no verb for that).
2. On first boot it also generates the CA (§9.2) into `arbiter-controller-ca` and publishes the public certificate to ConfigMap `arbiter-ca` (mounted into worker pods).
3. **Upgrade.** The image is immutable, so bd-bw8a0m's tarball self-upgrade (§6 there) does not apply. `hello_ok` carries `upgrade{version, sha256, image}` (A1) for `caps.upgrade = "image"`; with `rbac.selfUpgrade` on (the default in the rendered manifests) the controller patches **its own Deployment's** image (`get`/`patch` on `deployments/arbiter-controller` only) when idle (`auto_upgrade: when_idle`, as for machines), and `Recreate` restarts it. Because worker pods **survive a controller restart and are re-adopted** (§3.5), an upgrade does not even need to wait for idle in principle; `when_idle` is kept as the conservative default. Without the verb the node shows `outdated` plus the exact `kubectl set image …` command, and the skew rules of bd-bw8a0m §6 keep new work off it. The primary publishes the controller image of its own version to the registry at deploy time (§11), so the target always exists.
   *Why default-on:* the server is redeployed often (this repo is dogfooded); a cluster node that stalls after every deploy until a human acts would be unusable. *Why it adds no blast radius:* the controller can already create arbitrary pods in its namespace (and §7's admission policy bounds even that); patching its own image grants nothing beyond that.

### 3. The controller

#### 3.1 Job vs bare Pod: **bare Pod**

| | Bare Pod | Job |
|---|---|---|
| Retry | none; Arbiter owns resume | `backoffLimit: 0` plus `podFailurePolicy` is needed just to neuter the default; any default retry would start a **second run on an empty `emptyDir`**, racing Arbiter's own resume of the same task |
| Deadline | `spec.activeDeadlineSeconds` (native) | the same, on the Job |
| TTL cleanup | none: the controller deletes after it has the outcome | `ttlSecondsAfterFinished` |
| Status | the Pod carries everything we read (`OOMKilled`, `DisruptionTarget`, `Unschedulable`) | the same Pod, plus a second object and a second watch |
| RBAC | `pods` verbs | `jobs` verbs **and** `pods` verbs (logs, watch) |
| Kueue | plain-Pod integration (**[K18]**) | the most mature integration |

Decided: Pod. A Job is an indirection whose one real benefit (TTL GC that survives a controller outage) is replaced by `activeDeadlineSeconds` (kills the process) plus owner-reference GC and the sweeper (§3.6); the lingering terminated Pod object is a few KB. **What would change this:** adopting Kueue before its plain-Pod integration is acceptable, or an operator who wants `kubectl get jobs` as the audit view.

#### 3.2 Mapping the node protocol

| Protocol (bd-bw8a0m §4.2) | Cluster behaviour |
|---|---|
| `hello` | `kind: cluster`, `caps{backend: k8s, image: registry, limits: pod, bridge_streams, bundle, upgrade: image}`; **inventory** = the pods carrying this install/node labels (run id, phase, log cursor) from a list; readiness report (§9.4); `ceiling` = `max_concurrent`; no cpu/mem facts |
| `hello_ok` | effective `max_workers`, per-run "known: yes/no", `fence_after`, `upgrade` |
| `hb` (10 s) | per-run state with the vocabulary `pending | starting | running | terminating`, plus `capacity{ceiling, running, pending, headroom, constrained}` (A3) |
| `assign` | admission (§4.2), build the pod (§8), create it, reply `ready` at **container `Running`** or `refuse{reason}` |
| `cancel{run, reason, collect?}` | `collect` → delete with the pod's grace period (the snapshotter finalises on SIGTERM, §10.3); otherwise `gracePeriodSeconds: 0` |
| `signal(:term \| :kill)` | delete with grace / delete with `gracePeriodSeconds: 0` (no `exec` anywhere) |
| `stdout` (binary, `ARB1`) | `pods/log` follow of the `worker` container (§3.4) |
| `exit{status, oom?}` | from `containerStatuses[worker].state.terminated` (`exitCode`, `reason == "OOMKilled"`), sent **after** the final checkpoint has been forwarded or timed out |
| `checkpoint` | forwarded from the in-pod snapshotter (§10.3) |
| `bridge.*` | relayed from the TLS listener (§9.3) |
| `reap{live_set}` | §3.6 |
| `drain` / `rotate` / `upgrade` | `drain`: no new pods, in-flight finish. `rotate`: rewrite the credential Secret **before** acking (bd-bw8a0m §5.2). `upgrade`: §2.4 |

#### 3.3 Watch-based status

One informer over `pods` in the namespace, selector `arbiter.dev/install=<id>,arbiter.dev/node=<node>` (list, then watch from `resourceVersion` with bookmarks; 410 Gone → relist; a relist diff produces the same transitions as the watch). The state function is pure (and is K3's test target):

| Pod observation | Run state reported |
|---|---|
| `Pending`, `PodScheduled=False`, `reason: Unschedulable` (message kept verbatim) | **`pending`** (`reason: unschedulable`) |
| `PodScheduled=False`, `reason: SchedulingGated` (Kueue) | `pending` (`reason: queued`) |
| scheduled, `Init:*`, `ContainerCreating`, `PodInitializing` | `starting` (phase detail: `pulling | seeding | services`) |
| waiting `ImagePullBackOff`/`ErrImagePull`/`InvalidImageName`/`CreateContainerConfigError` for longer than `pull_timeout_s` | `refuse{image_unavailable, detail}` (pod deleted) |
| `containerStatuses[worker].state.running` | `running` |
| `worker` terminated | `exit`; `reason == OOMKilled` → `oom?: true` |
| `DisruptionTarget` condition, `status.reason == Evicted`, `Preempting`, or the pod object deleted by someone else | **interrupted** with new cause `pod_disrupted` (A5): same policy as `node_lost`, **no resume attempt consumed** |
| `phase: Failed`, `status.reason: DeadlineExceeded` | `exit` with `reason: deadline` (the run exceeded `activeDeadlineSeconds`; the primary classifies it like its own wall-clock stop) |

* *(K1-A7)* **A pod's `phase` ignores native sidecars.** Observed: with the worker exited, a pod whose snapshotter was SIGKILLed at the grace limit still ends `Succeeded`; an evicted pod ends `Failed`/`Evicted` with the worker in `ContainerStatusUnknown`; an OOM-killed or non-zero worker ends `Failed`. The state function therefore reads `initContainerStatuses[snapshotter]` itself and reports `snapshot: complete | killed | absent` with `exit`, and `exit` is not sent before the checkpoint forward is acked or `grace_s` has passed (§10.3). A **service sidecar that crash-loops leaves the pod `Pending`** (`CrashLoopBackOff` in `initContainerStatuses`, observed with a mis-rendered Postgres): it maps to `starting(services)` and, after `ready_timeout_s`, to `refuse{service_not_ready}`.

The pending/starting/running split is the point: **the primary only treats a run as started at `running`** (A3). Until then the `Worker` stays in its starting state and a node slot stays reserved (so effective capacity is honest), but no `stdout` or `exit` exists and nothing about the run is counted as usage.

#### 3.4 Log streaming as the agent stream

`GET /api/v1/namespaces/<ns>/pods/<pod>/log?container=worker&follow=true&timestamps=true[&sinceTime=<cursor>]`. The controller strips the timestamp, re-frames lines the way `Worker` expects (`{:line, 65_536}`: a longer line becomes `noeol` chunks followed by an `eol`), and emits `stdout` frames. The stream **cursor is the RFC 3339 nano timestamp** of the last acked line (A4: cursors become opaque strings, decimal offsets for podman); after a reconnect or a controller restart it resumes from `sinceTime = cursor`, de-duplicating lines with the identical `(timestamp, line hash)`. After the container terminates, one non-follow read from the cursor to EOF drains the tail before `exit` is sent. Backpressure is TCP's: if the primary stops acking, the controller stops reading and the kubelet stops being drained.

*Why logs and not `attach`:* the worker's stdin is `/dev/null` (`ClaudeSession` wraps the command in `exec "$@" < /dev/null`), so nothing flows the other way; `attach` is not resumable and needs another privileged verb. *Known weakness:* output lives in kubelet's rotated log files (default 10 MiB × 5); a controller outage that straddles a rotation loses lines **[K5]**. *(K1-A6)* **K5 measured it, and three things change:**

1. **`sinceTime` is second-granular.** A nanosecond value is truncated to the whole second by the API machinery, so a resume re-sends up to a full second of lines (about 770 duplicates per resume at 2,000 lines/s). The de-duplication set must cover the **last 2 s** of accepted `(timestamp, line hash)` pairs, not just the boundary timestamp. Timestamps were unique per line in all 165,013 lines measured, but nothing promises it, so lines with an equal timestamp and different content are kept.
2. **`pods/log` serves the current log file only.** `10 MiB × 5` is the *disk* retention; of a 158 MiB run only the last 12 MiB (8 %) came back, so after a rotation the head is gone for any reader that was not attached. A **continuous** follow loses nothing across rotation (165,013 of 165,013 lines over about 15 rotations). At the output rate Claude workers actually produce (transcript growth over 111 sessions longer than five minutes: median 0.7 KiB/s, p99 2.7 KiB/s) the file rotates every 1–4 hours, so an outage straddling a rotation is rare, not impossible.
3. **Loss must be detectable, not just unlikely.** The entry wrapper pipes the CLI's stdout through a numbering filter (`awk '{print NR, $0; fflush()}'`, one extra process, the CLI is unchanged); the controller strips the number and keeps it as the cursor next to the timestamp. After a resume, a first line whose number is not `last + 1` is a **gap**: the controller reports `stream_gap{from, to}` and the primary decides (transcript sync, §10.3, recovers the content; `arb done` and result handling are tool-call based and unaffected). The `tee`-file fallback stays unbuilt unless gaps are seen in practice.

#### 3.5 Cancel, teardown, restart

* **Cancel/teardown** is one `DELETE` of the Pod (grace 120 s when `collect`, else 0). Test-service sidecars, the snapshotter and the `emptyDir`s die with it; there is no separate service pod to reap (`TestServices.teardown/2` has no cluster analogue).
* **Controller restart does not kill runs.** On start the controller lists its pods, reports them in `hello.inventory`, re-attaches log follows at the primary's cursor, and the primary treats it as a *blip* if it returns within `fence_after` with the same `boot_epoch` (bd-bw8a0m §10.2). Bridges are reconnect-on-next-connection (each in-pod `socat` dials fresh per connection), so a restart costs the run a few seconds of stalled network.
* **Why this satisfies the fence invariant** (`fence_after < lost_after`, bd-bw8a0m §10.1) without a self-fence: a live controller that loses the primary deletes its pods at `fence_after`, as a machine agent stops its containers. A **dead** controller cannot, but a pod with no controller has **no exit**: it has no forge credential, no route to the primary, and its only network path is the controller's bridge listener. It stalls until `activeDeadlineSeconds`. When the controller returns and the primary no longer knows the run, the verdict is "quiesce" (§3.6). **[K21]**.
* **One active controller:** a `Lease` (`coordination.k8s.io`, `get`/`update` on the single pre-created name) is renewed every 10 s; a controller that cannot renew steps down (stops assigning and reaping, drops the primary socket) so a node partition cannot leave two controllers sharing one credential. `Recreate` handles the ordinary case; the Lease handles the partition.

#### 3.6 Reaping leftovers

Four layers, cheapest first:

1. **`activeDeadlineSeconds`** = the run's wall-clock cap + 30 min, kills runaway pods with no controller.
2. **Owner reference** from each pod to the controller **Deployment** (not its ReplicaSet or Pod: those change on every restart and would GC every run), `blockOwnerDeletion: false`. `kubectl delete deploy arbiter-controller` / uninstall removes every worker pod.
3. **The sweeper**, on `hello_ok` and every 60 s: pods with this install's and this node's labels whose run is **not** in the primary's `live_set` (bd-bw8a0m §10.6) are quiesced (SIGTERM path, so the snapshotter uploads a *salvage* checkpoint if the primary will take it) and deleted; terminated pods are deleted once their outcome is acked (`retain_failed_s`, default 300, `0` for succeeded: a retained pod keeps its `emptyDir` and kubelet log for `kubectl describe`/`logs`). The sweeper **never deletes a pod without all three labels** (RBAC cannot scope `delete` by label, which is the main reason the namespace is dedicated, §7), and never its own pod.
4. **Primary-gated:** like bd-bw8a0m, `reap` only arrives when `SingleInstance.primary?/1` is true.

### 4. Capacity and configuration

#### 4.1 Where it lives: ConfigMap `arbiter-controller-config`

Mounted at `/etc/arb/config/controller.yaml`, re-read every 30 s (kubelet propagates ConfigMap volume edits within roughly a minute; no API verb needed, so no RBAC). **Closed schema**; unknown keys fail validation; an invalid file keeps the last good config and reports `degraded: bad_config` in `hb`.

```yaml
max_concurrent: 2                  # the node ceiling reported to the primary
namespace: arbiter-workers
worker:
  requests: {cpu: "1", memory: 2Gi, ephemeral-storage: 4Gi}
  limits:   {cpu: "2", memory: 4Gi}
  work_size_limit: 8Gi             # emptyDir "work"
  tmp_size_limit: 1Gi              # memory emptyDir, counted against the memory limit
services_resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 512Mi}}
placement:
  node_selector: {kubernetes.io/hostname: mesanna}
  tolerations: []
  priority_class: arbiter-worker
  runtime_class: ""                # set to gvisor/kata where it exists; empty on runc-only
  queue: ""                        # Kueue LocalQueue name, later (§4.4)
image_pull_secrets: [gitlab-registry]
timeouts: {schedule_s: 120, pull_s: 600, boot_s: 120, grace_s: 120, retain_failed_s: 300}
snapshot_interval_s: 300
```

Only these are operator-settable. **Not settable, ever:** anything in the security context, volumes, service account, network, host namespaces, image. The builder owns them (§8). *Why not a CRD:* it needs cluster-scoped install and RBAC, and one object per node does not need a schema server. *Why not `PodTemplate`:* it would let the operator write fields the builder is supposed to own. A CRD for named worker **classes** (several profiles on one cluster) is the future shape; it would be a later amendment, not a rewrite.

The run spec's own resource hints (bd-bw8a0m §7.4's per-run memory cap) are advisory for cluster nodes: the effective limit is `min(spec, config)`, the in-cluster config is authoritative. A spec field the builder cannot represent (`network: pasta`, an unknown mount kind) is refused with `refuse{bad_spec}`; the pasta network is only ever used by the primary's own deps-seed job.

#### 4.2 How capacity is reported and enforced

* **Reported:** `hello.ceiling = max_concurrent`; the operator may only lower it (bd-bw8a0m §13: `min(operator, node ceiling)`). `hb.capacity = {ceiling, running, pending, headroom, constrained}`; a `capacity` event is pushed when the ConfigMap changes (A3). `headroom` is how many more pods **fit the namespace's ResourceQuota** right now: `min over resources of floor((hard - used) / per-pod request)` read from `resourcequotas` (`get/list/watch`, namespaced, read-only). The controller **cannot read `nodes`** (cluster-scoped, deliberately not granted), so there is no CPU/RAM-sum suggestion for a cluster; that is the design, not a gap: the cluster's schedulable room is the scheduler's business.
* **Second admission gate.** The primary's `Placement` reserves a slot against effective max (gate 2 of bd-bw8a0m §13). The controller re-checks on `assign`: `running + pending < max_concurrent` **and** `headroom ≥ 1`, else `refuse{no_capacity}`, which the primary maps to `{:no_node_capacity, _}` (a hold, the card is not failed, the reserved slot is released), exactly the existing account-capacity treatment. Quota is also enforced by the API server: a `POST pods` over quota fails synchronously with 403 `exceeded quota` and is mapped to the same refusal; quota counts **Pending** pods' requests too.
* **Pending-unschedulable never looks like running.** After creation the controller waits up to `schedule_s` for `PodScheduled=True`. `Unschedulable` appears within about a second and persists while the scheduler retries; at the timeout the pod is deleted and the assign is refused as `refuse{unschedulable, message}` (A3), no resume attempt consumed. While pending, the node's `hb.capacity.pending` shows it, `constrained: true` is set, and `Placement` ranks a constrained node last and skips it when another node or local capacity can take the run. The primary's startup/stall watchdogs must not run during `pending|starting` (`hello_ok.limits.prepare_timeout_s`, A3; **[K17]** verifies what `Worker` does today).
* **Interaction with `conductor.max_concurrent`:** unchanged and operator-owned (bd-bw8a0m §13); the nodes page shows `local + Σ effective`. A cluster's effective figure is `min(operator, max_concurrent)`.

#### 4.3 The quota that backs it (bootstrap manifest)

```yaml
apiVersion: v1
kind: ResourceQuota
metadata: {name: arbiter-workers, namespace: arbiter-workers}
spec:
  hard:
    pods: "4"                         # max_concurrent + controller + 1 spare
    requests.cpu: "3"                 # 2 x (1 + 0.1 + 0.05) + controller (and tailscale), rounded up
    requests.memory: 6Gi
    limits.cpu: "6"
    limits.memory: 10Gi
    requests.ephemeral-storage: 12Gi
```
The renderer derives these numbers from `max_concurrent` and the per-pod figures, so the two cannot disagree at install time; a later edit of one without the other is what the headroom number makes visible.

#### 4.4 Kueue (a later option)

Add `placement.queue`: the builder labels the pod `kueue.x-k8s.io/queue-name`; Kueue's pod integration gates it (`SchedulingGated`), which the state function already maps to `pending{queued}`, with a separate `queue_timeout_s` instead of `schedule_s`. `headroom` would then come from the ClusterQueue's quota instead of the namespace quota. Nothing else changes, which is the reason to keep bare Pods **[K18]**.

### 5. Checklist: bd-aowisc §7's eight "what k8s still needs" items

| # | bd-aowisc §7 item | Decision | Where |
|---|---|---|---|
| 1 | Bridge transport with its own authentication | controller-hosted mTLS listener, per-run per-bridge client certificates, `bridge.open` relay; policy/audit/`BridgeIdentity` stay on the primary | §9 |
| 2 | Image distribution via a registry; base/toolchain built elsewhere | the primary builds and pushes; digest-pinned `ref` in `assign` | §11 |
| 3 | Checkout transport; PVC vs `emptyDir` | `seed` init container fetches a bundle from the controller; `emptyDir`; snapshotter sidecar pushes back | §10 |
| 4 | Secrets as Kubernetes Secrets, RBAC, rotation | per-run values never stored in the cluster; single-use boot nonce; long-term holdings enumerated | §12 |
| 5 | Lifecycle and reaping: owner refs, `activeDeadlineSeconds`, TTL, native limits | bare Pod, owner reference to the Deployment, deadline, controller-driven delete, sweeper | §3 |
| 6 | Capacity: scheduling is the cluster's; `Placement` becomes advisory | ceiling + quota-aware second gate, `pending` state, Kueue later | §4 |
| 7 | Hardening mapping and the `label=disable` review | one-to-one builder table; `label=disable` dropped with reasons; NetworkPolicy + canary | §8, §9 |
| 8 | Output streaming; test services as sidecars | `pods/log` follow with timestamp cursors; native sidecars | §3.4, §6 |

### 6. Test services

`TestServices` today builds a podman **pod** (`--network none`, `--userns keep-id`) so the worker and its services share `lo`, starts each service with `--read-only --cap-drop=all no-new-privileges` and tmpfs mounts, and polls the service's `ready` argv with `podman exec`. A Kubernetes pod already is a shared-network-namespace group, so the translation is direct and reuses the **service specs** (`TestServices.resolve/1`, the `postgres/1` and `s3/1` presets), not the podman argv:

| Service spec field | Pod field |
|---|---|
| `name`, `image` | native sidecar (init container with `restartPolicy: Always`) `svc-<name>`; `imagePullPolicy: IfNotPresent` |
| `env` | `env:` (non-secret literals by construction; the presets use fixed dev credentials) |
| `command` | **`args`** *(K1-A9)*. A preset's `command` is what podman appends to the image's entrypoint (`postgres -c fsync=off …` after `docker-entrypoint.sh`), so it is Kubernetes `args:`; rendering it as `command:` replaces the entrypoint and Postgres never initialises (observed: `could not access directory "/var/lib/postgresql/data/pgdata"`, `CrashLoopBackOff`). `command:` is used only for a spec that names its own entrypoint |
| `tmpfs` entries (`/var/lib/postgresql/data`, `/var/run/postgresql`, `/data`) | `emptyDir{medium: Memory, sizeLimit}` mounted at that path; the sidecar still has `readOnlyRootFilesystem: true` |
| `ready` argv | `startupProbe.exec.command` (`periodSeconds: 1`); the next init container, and so the worker, does not start until it passes, replacing the readiness loop |
| `worker_env` (`DATABASE_URL=postgres://…@127.0.0.1:5432/…`, `S3_ENDPOINT=http://127.0.0.1:9000`) | the worker container's `env:` unchanged: `127.0.0.1` works because the pod shares `lo` |
| hardening | same container `securityContext` as the worker, **but the uid comes from a new optional spec field `uid`** (Postgres alpine: 70, `silo`: its image user) because the podman path relies on `--userns keep-id` plus an injected passwd entry that Kubernetes does not give; PSA `restricted` requires `runAsNonRoot` **[K10]**. *(K1-A9)* Observed: Postgres 16-alpine as uid 70 on a read-only root with memory `emptyDir`s on the data and socket directories and `PGDATA=…/pgdata` (its entrypoint's `chmod` of the socket directory prints `Operation not permitted`, harmless); `silo` as an **arbitrary uid with no passwd entry** (10002, `HOME=/tmp`, memory `emptyDir`s on `/data` and `/tmp`). So `uid` is required for Postgres only; the default 10001 works for `silo` |

Resource requests for services come from `services_resources` in the config (§4.1) and count towards the pod's request; teardown is the pod's deletion; there is nothing to reap separately (the `TestServices.Reaper`/`reap_orphans/1` machinery has no cluster analogue). The services' images are public (`docker.io/library/postgres`), so the namespace's `ValidatingAdmissionPolicy` allowlist (§7) admits `docker.io/library/` and the operator's registry only; a service with another image needs an explicit allowlist entry in the config (`service_image_allowlist`).

### 7. RBAC

**Namespaced only.** The controller needs no `ClusterRole`. Worker pods run as `arbiter-worker`, a ServiceAccount with **no bindings and `automountServiceAccountToken: false` on both the account and every pod**, so even a builder bug that mounted a token would mount a powerless one. The namespace's `default` account is likewise unbound.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: arbiter-controller, namespace: arbiter-workers}
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [create, get, list, watch, delete]       # no update/patch: pod specs are immutable to us
- apiGroups: [""]
  resources: [pods/log]
  verbs: [get]
- apiGroups: [""]
  resources: [resourcequotas]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [services]
  resourceNames: [arbiter-controller]             # to learn its own stable ClusterIP
  verbs: [get]
- apiGroups: [""]
  resources: [secrets]
  resourceNames: [arbiter-node-credential, arbiter-controller-ca]
  verbs: [get, update]
- apiGroups: [""]
  resources: [configmaps]
  resourceNames: [arbiter-ca]
  verbs: [get, update]
- apiGroups: [coordination.k8s.io]
  resources: [leases]
  resourceNames: [arbiter-controller]
  verbs: [get, update]
- apiGroups: [apps]
  resources: [deployments]
  resourceNames: [arbiter-controller]
  verbs: [get]                                    # owner-reference UID
  # + patch only when rbac.selfUpgrade is on (§2.4)
```

**Deliberately absent:** `pods/exec`, `pods/attach`, `pods/portforward`, `pods/eviction`, `secrets` create/list/watch/delete, `configmaps` list/watch, `events`, `nodes`, `namespaces`, `tokenreviews`, anything cluster-scoped. Notes:

* `create pods` with no field restriction **is** a broad grant (a pod can mount any Secret in its namespace, including the node credential). RBAC cannot narrow it, so two server-side backstops bound it: **Pod Security `restricted`** on the namespace (the builder's output must pass it, which is also a conformance test, K4) and, optionally, a `ValidatingAdmissionPolicy` that applies only to requests from the controller's service account:

  ```yaml
  apiVersion: admissionregistration.k8s.io/v1
  kind: ValidatingAdmissionPolicy
  metadata: {name: arbiter-worker-pods}
  spec:
    failurePolicy: Fail
    matchConstraints: {resourceRules: [{apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [pods]}]}
    variables:
    - {name: all, expression: "object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])"}
    matchConditions:
    - name: from-controller
      expression: request.userInfo.username == 'system:serviceaccount:arbiter-workers:arbiter-controller'
    validations:
    - expression: object.spec.serviceAccountName == 'arbiter-worker' && object.spec.automountServiceAccountToken == false
    - expression: "!has(object.spec.hostNetwork) && !has(object.spec.hostPID) && !has(object.spec.hostIPC)"
    - expression: object.spec.volumes.all(v, has(v.emptyDir) || (has(v.configMap) && v.configMap.name == 'arbiter-ca'))   # no Secret, hostPath, PVC
    - expression: (object.spec.containers + object.spec.initContainers).all(c, has(c.securityContext) && c.securityContext.allowPrivilegeEscalation == false && c.securityContext.capabilities.drop == ['ALL'] && c.securityContext.readOnlyRootFilesystem == true)
    - expression: (object.spec.containers + object.spec.initContainers).all(c, c.image.startsWith('<registry>/') || c.image.startsWith('docker.io/library/'))
    - expression: has(object.spec.hostUsers) && object.spec.hostUsers == false                       # (K1-A1)
    - expression: >-                                                                                  # (K1-A1) PSA stops checking this once hostUsers is false
        has(object.spec.securityContext) && has(object.spec.securityContext.runAsNonRoot) && object.spec.securityContext.runAsNonRoot &&
        (!has(object.spec.securityContext.runAsUser) || object.spec.securityContext.runAsUser != 0) &&
        variables.all.all(c, !has(c.securityContext) || ((!has(c.securityContext.runAsUser) || c.securityContext.runAsUser != 0) && (!has(c.securityContext.runAsNonRoot) || c.securityContext.runAsNonRoot)))
  ```
  *(K1-A1)* **Why the last two rules exist.** With `hostUsers: false`, Pod Security `restricted` **no longer enforces non-root**: a pod with pod-level `runAsUser: 0` and `runAsNonRoot: false` was *admitted* by the `restricted` namespace (observed on v1.36.5), because uid 0 in a user namespace is no longer host root. The §8 guarantee "every container runs as 10001" is therefore not something the namespace label gives; it is the builder (tested by the K4 conformance checker, which asserts it itself) and this policy (verified: pod-level uid 0, container-level uid 0, and `runAsNonRoot: false` are each denied). K1 also ran the other validations above **exactly as written** (minus the service-account `matchCondition`; the spike creates pods as admin): they compile, admit the §8.2 pod, and deny a Secret or `hostPath` volume, another service account, an off-list image and a missing hardening field; a pod with no `volumes` or `initContainers` field makes the expression error and is **denied** (fail closed; the worker builder always emits both, which is why the `variables` stanza above guards only the new rules).
  With it, a **compromised controller can only create pods shaped like worker pods**; without it, the Pod Security level still blocks the worst fields but not Secret mounts. It is optional because it needs a cluster-admin object and Kubernetes ≥ 1.30; the manifest renderer includes it when `?admission=policy` is chosen and the doctor reports whether it is present.
* **`delete` and `list` on pods cannot be restricted by label.** A compromised or buggy controller could delete other pods in its namespace. Hence the dedicated namespace and the controller's own all-three-labels guard (§3.6); neither is a security boundary, both are blast-radius reducers.
* Reading the quota needs `resourcequotas` read; that is the whole of its cluster visibility.

### 8. Hardening: the pod-spec builder, one line per `Container.argv/2` guarantee

`Arbiter.NodeAgent.K8s.PodSpec.build/2` is **pure** (run spec + config → a map), like `Container.argv/2`, and is table-tested exactly the way the argv builder is. Mapping:

| `Container.argv/2` | Pod field |
|---|---|
| `--read-only` | `securityContext.readOnlyRootFilesystem: true` on **every** container (init, services, snapshotter, worker) |
| `--cap-drop=all` | `capabilities.drop: [ALL]`, no `add` |
| `--security-opt no-new-privileges` | `allowPrivilegeEscalation: false`; `privileged: false`; `procMount: Default` |
| `--userns=keep-id` (in-container uid = host uid; no chown) | `runAsNonRoot: true`, `runAsUser/Group: 10001`, `fsGroup: 10001`, `fsGroupChangePolicy: OnRootMismatch`, **and `hostUsers: false`** (a user namespace on top; **[K1] verified on v1.36.5**: `uid_map 0 1524826112 65536`, files written by `seed` are readable by the worker and the snapshotter through `emptyDir` and `subPath`). *(K1-A1)* PSA `restricted` relaxes its non-root checks for `hostUsers: false` pods (§7), so non-root is enforced by the builder tests and the admission policy, not by the namespace label |
| podman's default seccomp | `seccompProfile: {type: RuntimeDefault}` (Kubernetes' default is **Unconfined**, so this must be set; PSA `restricted` denies a pod that omits it, observed). **No `appArmorProfile`** *(K1-A2)*: containerd applies its own default profile on any host that has AppArmor (observed with the field omitted: `cri-containerd.apparmor.d (enforce)`), whereas a pod that *names* a profile is **rejected by the kubelet** on a host without AppArmor (`Cannot enforce AppArmor: AppArmor is not enabled on the host`; pod `Failed`, reason `AppArmor`; observed on the same VM booted with `apparmor=0`). Naming it buys nothing on AppArmor hosts and makes every RHEL/Fedora/SUSE-family node unusable, so the builder never emits it |
| `--network=none` | no equal; §9 (NetworkPolicy, `dnsPolicy: None` with `127.0.0.1`, no service links, canary) |
| `-v <worktree>:<worktree>:rw,Z` at the primary's **own absolute path** (path transparency) | `emptyDir` `work` (`sizeLimit`) mounted at that path via `subPath: wt` |
| `.git` guards: `config`, `hooks`, `commondir`, `objects/info/alternates` read-only bind mounts (`PrivateClone.mounts/1`) | the same four paths as **`readOnly: true` `subPath` mounts of the same `work` volume** over the writable mount; the seed script creates the files first. **[K8] verified**: `mv` and `rm` of each guard fail `EBUSY`, writes fail `EROFS`, `git add`/`commit` in the tree still work, and kubelet accepts files created by the init container as `subPath` sources. *(K1-A8)* **Plus `.git` itself as a `subPath` mount of the same volume, listed before the guards.** The four guards are mount points but their *parent* is not: with only the guards, `mv .git .git2` **succeeds**, after which the worker can create a `.git` with its own `config` and `hooks`. With `.git` mounted, `mv .git .git2` fails `EBUSY` (observed). The same gap exists in the podman layout today (`PrivateClone.mounts/1` has no mount for `.git` itself; reproduced with the same bind layout, §15.1 K8) |
| `-v <objects>:O` overlay of the main repo's objects | not applicable: the clone is **self-contained** (full object store from the bundle, §10.1) |
| per-run `HOME`, `CLAUDE_CONFIG_DIR` | `emptyDir` paths at the primary's paths (path transparency: `claude --resume` keys on the cwd slug) |
| `--tmpfs /tmp:rw,nosuid,nodev`, `/dev/shm … noexec 64m` | `emptyDir{medium: Memory, sizeLimit}` for `/tmp` (counted against the memory limit, like tmpfs); `/dev/shm` left at the runtime default (64 MiB, `noexec,nosuid,nodev` on containerd). `noexec` cannot be set on an `emptyDir`, but `/tmp` has no `noexec` in the podman argv either |
| `-e NAME` (inherit; value never on argv) | values live only in a memory `emptyDir` file sourced and deleted by the entry wrapper (§12); never in the spec |
| `-e NAME=value` (literals) | `env:` entries (non-secret only) |
| `-v <cli>:/opt/arbiter/cli:ro` | an image layer (§11), read-only by the root filesystem |
| `--memory/--memory-swap/--cpus` | `resources.limits.memory/cpu` (+ requests); swap is off on k3s by default **[K22]** |
| `--pull=never` | `imagePullPolicy: IfNotPresent` with a **digest-pinned** reference |
| `--init` | PID-1 reaper: `tini` as the container entrypoint. **The base image does not have it today** (`Image` base installs `bc build-essential ca-certificates curl git … procps socat sqlite3`); K7 adds `tini` and a `arbiter:10001` passwd entry (openssh-client, used for the git-over-bridge `ProxyCommand`, fails for a uid with no passwd entry; podman's keep-id injects one, Kubernetes does not). **[K9]** |
| `--security-opt label=disable` **only when bridges exist** | **not carried over**; see below |
| — | `automountServiceAccountToken: false`, `serviceAccountName: arbiter-worker`, `enableServiceLinks: false`, `hostNetwork/hostPID/hostIPC: false`, `shareProcessNamespace: false`, no `hostPath`/`hostPort`, no `subPath` from a Secret; `priorityClassName`, `activeDeadlineSeconds`, `terminationGracePeriodSeconds` |

#### 8.1 Review of the `label=disable` reasoning

`Container`'s moduledoc gives the reason: a confined SELinux `container_t` cannot `connect()` to an **unconfined host listener socket**, and bridges are host unix sockets bind-mounted in. Every premise is absent here. Nothing in a pod connects to a host socket: the bridge is **TCP to a Service**, and `container_t` may `name_connect` to unreserved ports. The init container, snapshotter and worker are in **one pod**, so the runtime gives them one MCS pair and they share `emptyDir`s with no relabelling. Shared state between pods does not exist. Conclusion: **there is never a reason to relax SELinux, so the builder emits no `seLinuxOptions` at all and treats a spec asking for one (or for `spc_t`) as `bad_spec`**; the admission policy and PSA (which forbids `spc_t`) back that up. The k3s survey node (Pop!_OS) has no SELinux, so on that cluster this is simply moot; on an RHEL/Rocky cluster the default container policy applies unmodified **[K23]**. The `:Z` private-relabel option disappears for the same reason.

#### 8.2 The pod, concretely

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: arb-<run12>
  namespace: arbiter-workers
  labels: {app.kubernetes.io/name: arbiter-worker, app.kubernetes.io/component: worker,
           arbiter.dev/install: <install-id>, arbiter.dev/node: <node-id>,
           arbiter.dev/run: <run-id>, arbiter.dev/task: bd-1nfuq5}
  ownerReferences: [{apiVersion: apps/v1, kind: Deployment, name: arbiter-controller, uid: <uid>}]
spec:
  restartPolicy: Never
  activeDeadlineSeconds: <spec.max_wall_s + 1800>
  terminationGracePeriodSeconds: 120
  serviceAccountName: arbiter-worker
  automountServiceAccountToken: false
  enableServiceLinks: false
  hostUsers: false
  dnsPolicy: None
  dnsConfig: {nameservers: ["127.0.0.1"]}          # nothing listens: name resolution fails closed
  priorityClassName: arbiter-worker
  imagePullSecrets: [{name: gitlab-registry}]
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile: {type: RuntimeDefault}           # no appArmorProfile (K1-A2)
  initContainers:                                    # run in order
  - name: seed                                       # regular init: redeem nonce, fetch bundle, copy seed layer
    image: <run image @digest>
    env: [{name: ARB_BOOT_NONCE, value: <256-bit, single use>}, {name: ARB_BRIDGE_ADDR, value: 10.43.x.y}]
    command: [sh, -c, "<seed script: step 0 is the netpol gate (K1-A3)>"]
  - name: svc-postgres                               # native sidecar (K10)
    image: docker.io/library/postgres:16-alpine
    restartPolicy: Always
    args: [postgres, -c, fsync=off, -c, listen_addresses=127.0.0.1]   # args, not command (K1-A9)
    securityContext: {runAsUser: 70, runAsGroup: 70, allowPrivilegeEscalation: false,
                      readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
    startupProbe: {exec: {command: [pg_isready, -h, 127.0.0.1, -p, "5432", -U, postgres, -d, app_test]},
                   periodSeconds: 1, failureThreshold: 120}
  - name: snapshotter                                # native sidecar (§10.3)
    image: <run image @digest>
    restartPolicy: Always
    command: [tini, --, /opt/arbiter/bin/snapshotter]
  containers:
  - name: worker
    image: <run image @digest>
    command: [tini, --, sh, -c, "<entry wrapper: source+rm /run/arb/env; socat bridges (Jail's @network_script, OPENSSL targets); exec \"$@\">", sh, claude, ...]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true,
                      capabilities: {drop: [ALL]}, privileged: false}
    resources: {requests: {cpu: "1", memory: 2Gi, ephemeral-storage: 4Gi}, limits: {cpu: "2", memory: 4Gi}}
    volumeMounts:
    - {name: work, mountPath: <wt>, subPath: wt}
    - {name: work, mountPath: <wt>/.git, subPath: wt/.git}                    # (K1-A8) a mount point cannot be renamed
    - {name: work, mountPath: <wt>/.git/config, subPath: wt/.git/config, readOnly: true}
    - {name: work, mountPath: <wt>/.git/hooks, subPath: wt/.git/hooks, readOnly: true}
    - {name: work, mountPath: <wt>/.git/commondir, subPath: wt/.git/commondir, readOnly: true}
    - {name: work, mountPath: <wt>/.git/objects/info/alternates, subPath: wt/.git/objects/info/alternates, readOnly: true}
    - {name: work, mountPath: <home>, subPath: home}
    - {name: work, mountPath: <config_dir>, subPath: claude-config}
    - {name: tmp,  mountPath: /tmp}
    - {name: run,  mountPath: /run/arb}
    - {name: ca,   mountPath: /etc/arb/ca, readOnly: true}
  volumes:
  - {name: work, emptyDir: {sizeLimit: 8Gi}}
  - {name: tmp,  emptyDir: {medium: Memory, sizeLimit: 1Gi}}
  - {name: run,  emptyDir: {medium: Memory, sizeLimit: 64Mi}}
  - {name: ca,   configMap: {name: arbiter-ca}}
```
The init pass is deliberately sequential: `seed` finishes (secrets and tree in place) → services start and report ready (replacing the `TestServices` readiness loop) → the snapshotter starts → `worker` starts. Native sidecars (Kubernetes ≥ 1.29 beta, GA since 1.33) are the reason a service or the snapshotter does not hold a pod open after the worker exits **[K1] verified on v1.36.5+k3s1**: the pod ended as soon as the worker did and the sidecars were stopped after it (§10.3). The snapshotter needs the same `.git` and guard mounts as the worker (it has them in the spike).

### 9. Network isolation and the bridges

#### 9.1 Deny-all, except the bridge path (bootstrap manifest)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: arbiter-workers}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
---
kind: NetworkPolicy
metadata: {name: worker-to-controller, namespace: arbiter-workers}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/component: worker}}
  policyTypes: [Egress]
  egress:
  - to: [{podSelector: {matchLabels: {app.kubernetes.io/component: controller}}}]
    ports: [{protocol: TCP, port: 9443}, {protocol: TCP, port: 9444}]      # no DNS rule on purpose
---
kind: NetworkPolicy
metadata: {name: controller-ingress-from-workers, namespace: arbiter-workers}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/component: controller}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {app.kubernetes.io/component: worker}}}]
    ports: [{protocol: TCP, port: 9443}, {protocol: TCP, port: 9444}]
---
kind: NetworkPolicy
metadata: {name: controller-egress, namespace: arbiter-workers}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/component: controller}}
  policyTypes: [Egress]
  egress:
  - to: [{ipBlock: {cidr: <API server node IP>/32}}, {ipBlock: {cidr: 10.43.0.1/32}}]   # API: node IP:6443 and the kubernetes ClusterIP
    ports: [{protocol: TCP, port: 6443}, {protocol: TCP, port: 443}]
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}},
          podSelector: {matchLabels: {k8s-app: kube-dns}}}]
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
  - to: [{ipBlock: {cidr: 0.0.0.0/0, except: [10.42.0.0/16, 10.43.0.0/16]}}]           # primary / tailscale control; never the pod or service CIDR
    ports: [{protocol: TCP, port: 443}, {protocol: UDP, port: 41641}, {protocol: UDP, port: 3478}]
```
Workers get **no** DNS and no other destination; they address the controller by the `Service` ClusterIP injected as `ARB_BRIDGE_ADDR` (the controller reads its own Service at start). NetworkPolicy semantics for ClusterIP targets and API-server egress differ by CNI **[K2, K19]**; the two policies above are what the canary exercises.

*(K1-A3)* **K2 verified these policies on k3s v1.36.5's kube-router, with one gap that is now designed around.** Every case behaved as designed: the worker reaches the controller on 9443/9444 only, by Service ClusterIP (after DNAT) and by pod IP alike, and **nothing else**: not the `kubernetes` ClusterIP, not the node IP (API server 6443, kubelet 10250, sshd, the CNI gateway), not the DNS ClusterIP or the CoreDNS pod, not a pod in another namespace, not another worker, not the controller on a non-bridge port, not the internet. Pods in other namespaces and other workers cannot reach a worker or the controller. The controller reaches the API server through **both** `10.43.0.1:443` and `<node IP>:6443` (K19), DNS and public 443, and not the pod network. A new policy took effect 1.2 s after `kubectl apply` returned (no probe connected after the apply), and enforcement held for a 360-s watch that spans kube-router's default 5-minute resync, for 70 consecutive ingress probes, and in six repeated passes. Denied traffic is answered with an immediate ICMP reject (`Connection refused`), not a timeout, so probes need a 1-s connect timeout, not 10 s.

**The gap: a fresh pod is unfiltered until kube-router programs its chain, 0.13–0.18 s after its first instruction.** A loop started as the first instruction of five fresh `worker`-labelled pods connected to the API server ClusterIP, the node's API port and 1.1.1.1:443 in all five, then was rejected for good. Only `seed` (our own script) runs in that window; third-party service images and the worker start seconds later, so nothing untrusted runs unfiltered **if** the window really closes before then, and on a loaded node or a slow policy sync it might not. So **the seed script's step 0 is a gate**: loop on a connect to a destination no worker may reach, the `kubernetes` Service address (injected as `ARB_GATE_ADDR`, read by the controller from its own `KUBERNETES_SERVICE_HOST`/`PORT`, since worker pods have service links off), until it is refused, and exit non-zero after `gate_timeout_s` (default 30) as `refuse{netpol_unenforced}`: a CNI that never enforces, or enforces late, fails closed **per pod**. Measured: the gate released 0.37–0.55 s after pod start and the probes after it saw no open connection (5 of 5). The service sidecars start after `seed`, so they inherit the gate. The gate is per pod; §9.4's canary is per node and proves the policies exist. The operator's own cluster is checked with `docs/design/k8s-spike/k2-operator-check.sh` (§15.1, *Needs operator*).

#### 9.2 Identity: a per-install CA and per-bridge client certificates

The controller creates an EC P-256 CA on first boot (`arbiter-controller-ca`; public cert in `arbiter-ca`). For each run it mints, in memory, **one leaf certificate per bridge** with `CN = <run id>`, `OU = <bridge name>` (`proxy`, `arb`, `git`, …), valid until the run's deadline, and a server certificate with SANs `arbiter-controller` and the Service ClusterIP. The cert identifies *run and bridge*, which is the same granularity the podman design gets from the per-run socket path. *(K1-A5)* **Minting needs no dependency.** OTP's `:public_key` builds and signs the CA, the server certificate and every leaf (`pkix_sign` over an `OTPTBSCertificate`): about 110 lines, **0.13 ms per leaf**, and every certificate verified under OpenSSL (chain, basicConstraints, key usage, EKU, SANs, CN/OU, validity). **[K4]** verified; the `x509` package is not added. Gotchas found: an `iPAddress` SAN is a **list of four integers**, not a tuple or a binary (`{:iPAddress, [10, 43, 98, 199]}`); `:ssl` on the 9443 listener enforced `verify_peer` with `fail_if_no_peer_cert`, expiry, an unknown CA **and the extended key usage** (a `serverAuth`-only leaf offered as a client certificate is rejected with `invalid_ext_keyusage`), so server certificates carry `serverAuth` only and bridge leaves `clientAuth` only; CN and OU are read with `:ssl.peercert/1` and `:public_key.pkix_decode_cert(der, :otp)`.

#### 9.3 Controller-hosted relay (chosen) vs per-pod sidecar

* **Chosen: controller-hosted.** Two listeners on the controller: **9443** raw TLS (`verify_peer`, `fail_if_no_peer_cert`) for bridge connections; **9444** HTTPS for `/boot` (server-auth only, nonce in body), `/seed.bundle`, `/checkpoint`, `/transcripts`, `/commands` (client cert required). Inside the worker the existing in-container `socat` start-up (`Jail.network_command/2`'s `@network_script`: `TCP-LISTEN:<port>,bind=127.0.0.1,fork` per bridge) is kept, with each `UNIX-CONNECT:<sock>` target replaced by `OPENSSL:$ARB_BRIDGE_ADDR:9443,cert=/run/arb/tls/<name>.crt,key=…,cafile=/etc/arb/ca/ca.crt,commonname=arbiter-controller,verify=1`. `HTTPS_PROXY`, `ARB_HOST`, the ssh `ProxyCommand` env are byte-identical to the podman container's. *(K1-A4)* **[K3] verified** with the base image's socat 1.8.0.3: `OPENSSL:` with `cert`, `key`, `cafile`, `commonname` and `verify` works against an OTP `:ssl` listener; a handshake costs 7–16 ms per connection (fork per connection included) and a 200 MiB stream crossed the fork chain at 180–340 MiB/s; 100 MiB checksums matched three times through socat on both ends. Three things the script must do or know: **(1) every `TCP-LISTEN` in `@network_script` gets `backlog=1024`**: socat's default accept backlog of 5 left a quarter of a 100-connection burst unanswered (369–389 of 500 answered, the rest hit 8-s timeouts) where `backlog=1024` answered 500 of 500 in 1.3 s. **(2) Under TLS 1.3 the client's handshake completes before the server has checked the client certificate**, so a rejected leaf shows up in the pod as an immediate EOF, not as a failing `socat` exit status; tests and the canary assert on the listener's verdict, never on the client's exit code. **(3)** A client that closes its socket with unread inbound bytes (a one-way `socat -u` that never reads the server's first line) makes the kernel send RST and **truncates its own tail** (about 1.5 MB of 100 MiB; reproduced, traced to the client, and absent for bidirectional clients: 3 of 3 exact): bridge clients read their replies.

The controller reads CN/OU from the peer certificate and calls the **same** `bridge.open{run, name, stream}` the machine agent calls; `Nodes.Bridge` on the primary dials its own `Egress` listener. **Egress policy, `egress_events` audit and `BridgeIdentity` are untouched**, which is the property the ticket asks to keep. Checks: the controller verifies the run is one it assigned and is live, and that `OU` is a bridge name in that run's spec.
* **Rejected: a per-pod relay sidecar** (unix sockets in a shared `emptyDir`, a relay process dialling the controller). It needs the same TLS client and the same certificates, adds a container per pod on a CPU-tight cluster, and only moves the key out of the worker container, where it buys nothing: the worker can already use the bridge it was given, and an impersonated bridge is still only *its own run's* bridge. The sidecar variant becomes worthwhile only if a future bridge must be unreachable by the worker itself; nothing in today's list is.
* **Rejected: the controller reaching into pods** (`pods/portforward`/`exec`): needs powerful verbs, one API-server stream per connection, and the connections originate inside the pod anyway.
* **Rejected: plain TCP** (cleartext: the `arb`/MCP bridge carries the worker-tier bearer across an unencrypted overlay).

Cost, as an estimate for the spike (**[K24]**): one extra TLS handshake per bridged connection (about a millisecond of CPU, one LAN RTT), then the same relay hop the machine agent already pays (bd-bw8a0m §8); node → primary RTT dominates exactly as there.

#### 9.4 `--network=none` has no equal: the canary

A pod always has `eth0`. The kernel guarantee of the podman path becomes "the CNI enforces the policies above", which on k3s depends on the bundled kube-router controller actually being active for this CNI and kernel. The survey says the controller is on and **zero policies exist today**, so enforcement has never been exercised. So the controller **proves it**: at start, on every config change and every 10 minutes it creates a short-lived canary pod using the **worker pod's own labels and spec builder** (so it is subject to the real policies) running a hardened `sh -c` that attempts (a) the `kubernetes.default` ClusterIP, (b) the controller Service on a **non-bridge** port, (c) a pod IP in another namespace, (d) `1.1.1.1:443`, (e) the node IP. All must fail while the bridge port connects. *(K1-A3)* The canary pod runs the same gate as any worker pod (§9.1) before its probes, so its probes measure the steady state, not the start-up window; and because kube-router answers denied traffic with an immediate reject, each probe uses a 1-s connect timeout. Any success sets **`degraded: netpol_unenforced`** in `hello`/`hb`; like `degraded: uncapped` for a machine, `Placement` excludes the node unless the operator sets `allow_unenforced_network` per node (an explicit, audited override). The same readiness block reports: PSA `restricted` enforced on the namespace (a server-side dry-run of the builder's own pod), quota present, `priorityClass` exists, registry pull works (a `pause`-style dry pull), admission policy present (informational), clock/skew. **[K2]**

### 10. Checkout: getting the tree in and the snapshot out

#### 10.1 In: `seed` init container, bundle from the controller, `emptyDir`

* **Transport.** The pod never talks to the primary. `seed` redeems the boot nonce and then `GET https://$ARB_BRIDGE_ADDR:9444/seed.bundle` (mTLS with the client cert it just received). The controller streams `GET /nodes/runs/:run/seed.bundle` from the primary with the node credential (bd-bw8a0m §9; no temp file, back-pressure end to end). v1 sends a **full** bundle (`have: []`; measured on this repo: 15.6 MB of history since 2026-09-01, 29.6 MB full pack), which is a few seconds on a LAN; a thin bundle against a per-node object store would need persistence that `emptyDir` does not have (§10.4).
* **The run's `arbr_` token is not needed.** bd-bw8a0m §16 proposed a per-run transfer token so an init container could fetch from the primary. Here the pod never reaches the primary, so the controller's node credential does that job and the **mTLS leg replaces the token**. Recommend bd-bw8a0m not build `arbr_` for this purpose (A6); if it builds it for another reason it stays unused here.
* **The script** (rendered into the init container's `command`, so no image change; shell + `git` + `curl` + `tar`, all in the base image): **step 0 is the netpol gate** (§9.1, *K1-A3*); then redeem (`/boot` returns a **tar**, so no `jq` is needed) into `/run/arb` (memory); `git init`, `git fetch <bundle> 'refs/*:refs/*'`, check out the run branch, write the same `.git` layout `PrivateClone` builds by hand (a private `.git` directory, a `commondir` guard file containing `.\n`, an `objects/info/alternates` file, an empty `hooks` directory, `config` from a fixed template: **the config never comes from the bundle**); the one deliberate difference is that the object store is the clone's own, so `alternates` is created empty instead of naming the main repo's objects; copy `/opt/arbiter/seed/.` from the image layer into the tree (§11.3); write seed files delivered by `/boot` (`.mcp.json` with the worker-tier bearer, the per-run `settings.json`/`CLAUDE.md` into `config_dir`, the prompt file). Exec bits and symlinks follow bd-bw8a0m **[U7]**.
* **A second implementation of the shadow-clone layout** (shell here, Elixir in `PrivateClone`) can drift. K7 adds a **contract test**: build the layout both ways from one fixture and compare `git ls-files -s`, `.git/config` (modulo the object-store line), the four guard files and `git fsck`. Note for bd-bw8a0m: it says the machine agent runs `PrivateClone`'s builder unmodified, but `build/1` is **private** (`defp build(plan)`, `private_clone.ex:247`) and its plan names the main repo's `objects` for `alternates`; the public entry points are `create/4` and `attach/4`. Reusing it on a node needs a small public, plan-parameterised seam (bw#9 should list it); for the cluster it would not apply anyway (no main repo to borrow from).
* **Rejected: the controller builds the tree with `PrivateClone` (after the seam above) and streams a tar.** One implementation, but the controller pays CPU, disk and 100+ MB of tar per run and needs scratch space it otherwise does not have. Acceptable as the fallback if the contract test keeps failing.
* **Rejected: PVC for the tree.** `local-path` is RWO and node-bound (every pod is pinned to the node holding the volume), there is no RWX, and a PVC survives what should die with the run.

#### 10.2 `emptyDir` vs PVC for the tree

`emptyDir` (disk-backed, `sizeLimit: 8Gi`, `requests.ephemeral-storage: 4Gi`) for `work`; memory-backed for `/tmp` and `/run/arb`. The disk limit is enforced by the kubelet's periodic eviction, not as a hard quota, so a runaway write can trigger an eviction (which the state function reports as `pod_disrupted`, and the snapshotter has until the end of the grace period to save) **[K7]**. Node ephemeral-storage headroom on the survey nodes is unknown **[K25]**.

#### 10.3 Out: the `snapshotter` native sidecar

The tree is **untrusted**, and the primary already treats every bundle as such (quarantine repo, fsck, ref allowlist, primary-side path filter, no config or hooks crossing: bd-bw8a0m §9). The only new question is *which component runs `git` against the container-writable `.git`*. Chosen: **a sidecar in the pod, with exactly the worker's hardening and credentials, never the controller.** A compromise of git by the tree then lands in a container with no more power than the worker already has; the controller (which holds the node credential and CA key) never touches pod state.

* The snapshotter shares the `work` volume (`.git/config`, `hooks`, `commondir`, `alternates` are read-only for it too), every `checkpoint_interval` (300 s) and on a `checkpoint now` pushed through `/commands`, it writes the snapshot commit with a temporary index (`GIT_INDEX_FILE=<tmp>`, `git add -A`, `git write-tree`, `git commit-tree -p HEAD`, honouring `.git/info/exclude`, `-c core.hooksPath=/dev/null -c core.fsmonitor=false`) to `refs/arbiter/snapshot/<run>`, makes a bundle of the branch, the snapshot ref and the tracking branch with prerequisites `^<known>`, and `PUT`s it to `https://$ARB_BRIDGE_ADDR:9444/checkpoint`; likewise `tar` of `projects/**` to `/transcripts`. The controller streams both to `PUT /nodes/runs/:run/checkout` and `…/transcripts` with the node credential. **The controller never parses either.**
* **Final snapshot without `exec`.** When the `worker` container ends (success, failure, OOM-kill, eviction, deletion), the kubelet stops native sidecars **after** all regular containers have terminated and sends them SIGTERM with the pod's grace period. The snapshotter's SIGTERM handler *is* the "main is done" signal: it takes the final snapshot, uploads it, and exits 0. The controller therefore holds `exit` until the checkpoint forward completes (or `grace_s` passes), then deletes the pod. **[K6] verified, with one exception** *(K1-A7)*. The sidecar got SIGTERM 0.4–0.6 s after the worker exited naturally (exit 0), with a non-zero status (3) and OOM-killed (137), and its 5-s handler ran to completion (exit 0) inside the pod's grace period; a handler longer than `terminationGracePeriodSeconds` is SIGKILLed at exactly that limit (3-s grace, 10-s handler: exit 137 at 3.3 s) and the pod still ends `Succeeded`, hence §3.3's `snapshot:` field. On **deletion** (cancel) the worker is stopped first, with its own grace, and the sidecar only after it exited (SIGTERM 0.06 s after the worker's exit, 9 s end to end). **On `emptyDir` `sizeLimit` eviction the sidecar gets about 2 s, not the pod's 30 s**: SIGTERM, one tick of the handler, SIGKILL; the volume is gone with the pod. A final snapshot therefore **cannot be promised for eviction** (the same kubelet eviction path is used for node-pressure eviction, which was not tested). Consequences: a `pod_disrupted` run resumes from its **last periodic checkpoint** (at most `checkpoint_interval`, the loss model below, already what a lost node costs); the snapshotter polls the usage of the `work` volume and takes an **early snapshot at 80 % of `sizeLimit`**, so the common eviction cause (a runaway write) is checkpointed before it triggers (the spike's eviction fired 40–50 s after the limit was crossed); and `exit` carries `snapshot: complete | killed | absent` so the primary knows which it got.
* **Loss model.** Node death or a hard `emptyDir` loss loses at most one `snapshot_interval_s` of work, the same as a machine node lost (bd-bw8a0m §10.3). An un-acked pod whose primary no longer knows the run is quiesced and its final checkpoint offered as a **salvage** ref (the optional hardening child of bd-bw8a0m §10.3) rather than discarded.
* **Rejected: `kubectl cp`/`pods/exec`** (a broad verb, SPDY streams, runs a binary in a pod the controller does not control). **Rejected: the worker's own entry wrapper taking the final snapshot** (it does not run when the process is OOM-killed or SIGKILLed, which are exactly the runs whose work matters most).

#### 10.4 Warm deps/`_build`: **image layer**, given bd-2jerqw

What exists on `main`: `DepsCache` (`<root>/<lock12>-<image12>`) seeds `deps/` and `_build/` **inside the worker image** on the primary (`ContainerSpawn.prepare/1` calls `DepsCache.seed_worktree/3`), and `worker.repos.<repo>.seed_paths` (`SeedPaths.resolve/2`, bd-2jerqw, shipped) lists the repo-relative paths `Worktree.seed_compiled_deps/3` copies in for host-style seeding. bd-bw8a0m already makes the primary's thin home clone for a remote run skip seeding (`seed: false`).

| Option | Verdict |
|---|---|
| **Seed layer in the image** | **Chosen.** Node-agnostic; the kubelet already caches layers per node (so "per-node cache" is free); immutable; the key `(lock12, image12)` already exists. Size here: `deps` 51 MB + `_build` 293 MB uncompressed (the host's own checkout; a container build is the same order). Cost: registry storage per lock change (a retention rule is the operator's), a copy into the `emptyDir` at start (seconds; no reflink on `emptyDir`). |
| PVC cache + copy | RWO `local-path` pins every run to one node; no RWX; a second copy hop. |
| In-cluster seed Job | needs network egress (Hex) that the deny-all policy removes, a PVC to hold the result, and a second build path. |
| Fetch per run | minutes of compile and an open egress path per run. |

**How the layer is built.** On the primary, after `DepsCache.ensure/4` has produced the cache directory for `(lock, image)`: `podman build` of `FROM <run image base> / COPY seed/ /opt/arbiter/seed/` with the cache directory as the build context (build time only; the cache directory is still never mounted into a container), tagged `<image12>-cli<sha8>-seed<lock12>-<seedpaths8>`, pushed (§11). The seed script copies `/opt/arbiter/seed/.` into the tree.

**What `seed_paths` means for a cluster.** The resolved list is intersected with what the layer builder can legitimately ship: entries equal to or under `deps` and `_build` are satisfied by `DepsCache` (so a container-ABI build, not the host's); **other entries** (for example `priv/plts` in the example in `SeedPaths`' moduledoc) are copied verbatim from the primary's checkout into the same layer, subject to a per-entry size cap (default 500 MB) with a doctor warning when skipped. Honest limit: a toolchain-bound artifact built on the host (a dialyzer PLT from the host's OTP) can be wrong for the image's OTP, which is the very reason `DepsCache` exists; the layer builder cannot know which `seed_paths` entries are toolchain-bound, so the recommendation is to leave them out for cluster-placed workspaces until a `seed_commands` mechanism (run inside the image, like `DepsCache.ensure/4`) exists **[K26]**.

### 11. Images and where they are built

* **Worker image.** Built where it is today: `Image.Builder.ensure/3` on the primary (content-hash tag; digest-pinned `FROM`s). New primary-side `Image.Publisher` (**new**, K8) pushes it to `nodes.registry` (`podman push`/`skopeo copy`; credential in the Cloak-encrypted settings, never on argv) and returns a **digest-pinned reference**; `assign.image.ref` carries it (A2). Because `assign` is refused with `image_unavailable` rather than building, `ensure_ready` on the primary is "published or publish now, bounded timeout, then `prefer_remote` falls back to local, `remote_only` holds the card".
* **Layers pushed:** base+toolchain (843 MB on this host, 464 MB of it base; pushed once per tag, deduplicated by layer), a **CLI layer** (`claude` and `arb` copied to `/opt/arbiter/cli`, replacing the host bind mount; keyed by the sha256 of both so a Claude update pushes one layer), the **seed layer** (§10.4). The run image is the last of these; the kubelet pulls only layers it lacks.
* **Controller image.** Built by the primary from the retained release tarball (bd-bw8a0m child 4 keeps it): `FROM <public glibc-≥2.28 base>`, unpack to `/opt/arbiter`, `USER 10001`, `ENTRYPOINT [/opt/arbiter/bin/arbiter, start]`, tag = server version. Pushed at `arb server deploy` so the upgrade target exists before any node is told to move.
* **Base image changes needed (K7):** `tini`; user `arbiter` uid/gid 10001 with a passwd entry and home; confirm `socat` has `OPENSSL` support **[K3]**. The base tag changes with its Containerfile, so every dependent image rebuilds once.
* **Service images** (`postgres:16-alpine`, `pgsty/silo`) are pulled by the kubelet from their registries (or mirrored into `nodes.registry`; the renderer rewrites the reference when a mirror is configured). The `TestServices.ensure_images` pre-pull step has no counterpart; `imagePullPolicy: IfNotPresent` replaces it.
* **Rejected:** building in-cluster (kaniko/buildah need either privileges or user namespaces + fuse the hardened namespace forbids; a push credential would live in the cluster); `podman save | load` (impossible, and 0.5–1 GB per toolchain per node); CI-published GHCR images (a private repo needs pull credentials in every cluster, and a `--local` deploy has no published image). Pushing real `claude` binaries belongs only in the operator's **private** registry; the setting's help text says so.

### 12. Secrets

| Material | Where it lives | Notes |
|---|---|---|
| Node credential `arbn_…` | Secret `arbiter-node-credential` (controller-only RBAC) | Rotated in place over the channel; revoked on the primary closes the socket at once |
| CA private key | Secret `arbiter-controller-ca` (controller-only) | 5-year CA, per-run leaves expire with the run; only the public certificate is in a ConfigMap |
| Tailscale auth key (path A only) | Secret `arbiter-tailscale` | ephemeral, tagged, pre-authorised; the one extra standing secret |
| Registry pull secret | operator-created `kubernetes.io/dockerconfigjson` referenced by `imagePullSecrets` | read-only credentials |
| Join token | Secret `arbiter-join` | spent after first boot; delete it |
| **Provider token, `worker_env` values (incl. forge tokens for in-container `git push`), `.mcp.json` bearer, prompt** | **never a Kubernetes object** | delivered per run: the primary's `assign` → controller memory → pod `seed` container via `/boot` over TLS → a memory `emptyDir` file → sourced and **deleted** by the entry wrapper, so the values exist only in the `worker` process's environment, as they do under podman |
| Session transcripts | in the pod's `emptyDir`, then uploaded | gone when the pod is deleted |

**The boot nonce.** The pod spec carries `ARB_BOOT_NONCE`, 256 bits, **single-use**, expiring at `boot_s` (120 s), bound by the controller to the pod's `status.podIP` (the informer gives it) and the run. It is visible via `kubectl get pod` for that window, but a spent or expired nonce is worthless, and the reachable surface is a TLS endpoint that only worker pods may connect to (§9.1). This is the same single-use pattern as the join token. *Rejected: per-run Secrets*: readable by any `get secrets` in the namespace for the run's whole life, at rest in etcd/sqlite (k3s secrets encryption is opt-in), and they would force `secrets create/delete` onto the controller, which RBAC cannot restrict by name. *Rejected: a projected service-account token with `TokenReview`*: needs a `ClusterRole` and contradicts "worker pods get no token".

**Where the guarantee is weaker than podman (state it, do not hide it):** (1) memory `emptyDir` is node RAM-backed tmpfs, not "never touches storage" (swap is off on k3s by default; **[K22]**); (2) **the agent stream is written to the kubelet's container log files on the node's disk** and is readable by anyone with `pods/log` or node access until the pod is deleted (podman `--rm` and a Port leave no such file); anything the CLI prints, including a tool's accidental secret echo, lands there, so pods are deleted promptly (§3.6) and the doctor states the exposure; (3) a cluster admin can read pod memory; as with a machine node, per-run delivery bounds *persistence*, not *exposure* (bd-bw8a0m §11), and the mitigation is the same: a dedicated provider account for the cluster node.

### 13. A real target: the existing k3s cluster

**Facts used (admiral memory, 2026-10-04; not re-checked):** plain k3s v1.36.5, one server (`mesanna`, 8 CPU / 32 GiB, about 68% of CPU already requested) + a worker (`aginor`, 4 CPU / 7.7 GiB, on Wi-Fi, about 53% requested), room for roughly two 2-CPU pods; **runc only**; `hostUsers: false` works; **no PSA enforcement configured, zero NetworkPolicies though the built-in controller is on**; `local-path` storage only; images from the GitLab registry via a `gitlab-registry` pull secret; API LAN-only (`192.168.1.169:6443`; certificate SANs `10.43.0.1`, `127.0.0.1`, `192.168.1.169`, `::1`); the cluster also hosts the vstim prod workers and the GitLab CI runner, whose loss on `mesanna` takes vstim CI with it.

| Design need | On this cluster |
|---|---|
| Native sidecars, `hostUsers`, `ValidatingAdmissionPolicy`, PSA | all available at v1.36 (labels per namespace turn PSA on; the survey's "none" means unlabelled) **[K1, K12]** |
| NetworkPolicy deny-all | the controller exists; **never exercised**, and a Wi-Fi-latched flannel (memory: interface-name latching) is exactly the kind of setup where it should be proven, not assumed: the §9.4 canary is the gate **[K2]** |
| Strong isolation for untrusted LLM code | runc only: no gVisor/Kata `runtimeClass`; the isolation is userns + seccomp + dropped caps + netpol, a notch below the podman path |
| Reaching the primary | the cluster is **not on the tailnet** (vstim uses a per-pod tailscale sidecar): path A of §2.3, which adds a tagged tailscale auth key to the cluster |
| Registry | GitLab registry exists; the primary pushes to it (LAN) **[K20]** |
| CPU | tight: `max_concurrent` **2** at requests 1 CPU / 2 GiB each is the honest ceiling; Elixir test suites want more |
| Image pulls | the 843 MB toolchain image to `aginor` over Wi-Fi; pin to `mesanna` with `node_selector` and pre-pull **[K14]** |
| Shared tenancy | prod workers and CI share the nodes; ResourceQuota + `PriorityClass` (value `-100`, no preemption of others) + dedicated namespace ring-fence it, they do not remove the shared-kernel risk |

**Verdict: a sensible *test bed*; not yet a production target for sensitive workspaces.** It is the right place to prove the controller, RBAC, pod builder, bridge relay, canary and quota behaviour on real Kubernetes, and a ceiling of 2 is enough for that. It should take real task runs only after (1) the canary shows NetworkPolicy enforcement end to end, (2) the namespace has quota, low priority and PSA `restricted` applied by the operator, (3) the operator accepts that untrusted code shares a kernel with vstim prod and CI, with the `worker.placement` default (`local_only`) left on for sensitive workspaces, and (4) a `node_selector` pins pods to `mesanna`. A dedicated spare machine running k3s with a tainted `arbiter-workers` pool would remove (3) and is the better first *production* cluster; the design does not change for it.

**Nothing in the cluster was changed or contacted by this ticket.** The spike (K1) should use a **disposable** cluster (kind/k3d under rootless podman on the dev host); a throwaway namespace on the operator's k3s only with an explicit go-ahead, since the operator's kubeconfig there is cluster-admin and the cluster hosts production.

### 14. Proposed amendments to bd-bw8a0m (each is a change, not an assumption)

| # | Amends | Change |
|---|---|---|
| **A1** | §4.2 `hello`/`hello_ok`, §6 | `kind` and `caps` as listed in §3.2; `caps.upgrade ∈ {tarball, image}` and `hello_ok.upgrade` gains `image` for cluster nodes. Skew rules unchanged. |
| **A2** | §7.1, §7.3 | For `caps.image = "registry"`, `assign.image` is `{tag, ref}` with a **digest-pinned `ref`** the primary has already pushed; the node never receives a build plan. New primary-side `Image.Publisher` and settings `nodes.registry.*`. A node refuses with `image_unavailable`. |
| **A3** | §4.2 table, §13 | Per-run states `pending | starting | running | terminating`; `refuse{reason ∈ no_capacity, unschedulable, image_unavailable, bad_spec}`; node→primary `capacity` event and `hb.capacity{ceiling, running, pending, headroom, constrained}`; `hello_ok.limits.prepare_timeout_s`. The primary counts a run as started only at `running`; `Placement` skips/ranks-last a `constrained` node. `Executor.prepare` returns at *container running* rather than "agent finished image/CLI/deps/shadow". |
| **A4** | §4.2, §10.2 | Stdout frame cursor and ack become an **opaque backend-defined string** (podman: decimal offset; cluster: RFC 3339 nano timestamp). |
| **A5** | §10.3, `StopReason.classify/3` | New interruption cause **`pod_disrupted`** (evicted, preempted, pod deleted externally) with the `node_lost` policy: interrupted, no resume attempt consumed. |
| **A6** | §16 | The run transfer token `arbr_` is **not used** by cluster nodes (the pod never reaches the primary); build it only if another consumer exists. |
| **A7** | §13, §3, §14 | Node `degraded: netpol_unenforced` (excluded like `uncapped`), per-node `allow_unenforced_network` override, node row/`NodeEvent` carry `kind` and show `k8s_version`; the join modal gains the kind selector; `hb.capacity.constrained` surfaces on the nodes page. |

Not amendments but worth a flag for bd-bw8a0m's own children: the podman agent runs `git` on the container-writable shadow `.git` from the node's trusted side. `PrivateClone.mounts/1`'s read-only `config`, `hooks`, `commondir` and `alternates` make that safe **today**; child 11 should keep that guard explicit (and pass `-c core.hooksPath=/dev/null -c core.fsmonitor=false`) rather than rely on it implicitly, because the agent runs as the same host user as the container's keep-id mapping.

### 15. Unverified assumptions (K-series; bd-bw8a0m's U1–U20 still apply)

The last column is the K1 spike's verdict (bd-6zl538, 2026-10-06); §15.1 below has the evidence and the design changes (K1-A1 … K1-A10). Earlier columns are the pre-spike wording and are kept as written.

| ID | Assumption | If it fails | K1 verdict (bd-6zl538) |
|---|---|---|---|
| K1 | k3s v1.36.5 supports native sidecars, `hostUsers: false` **with `emptyDir`/`subPath` mounts under runc** (id-mapped mounts), `ValidatingAdmissionPolicy`, `appArmorProfile`, and honours `terminationGracePeriodSeconds` for sidecars | drop `hostUsers` (keep the rest); fall back to a regular `snapshotter` container + `flock` main-exited detection | **GO** (k3s v1.36.5, kernel 6.12, runc 1.4.2) §15.1. Two amendments: non-root is no longer PSA-enforced under `hostUsers: false` (K1-A1); no `appArmorProfile` (K1-A2). Operator: kernel ≥ 6.3 for memory `emptyDir`s with user namespaces (Kubernetes docs; not tested here) |
| K2 | The bundled kube-router NetworkPolicy controller enforces deny-all egress **including to ClusterIPs and pod IPs**, and the allow rule to the controller Service works after DNAT | `degraded: netpol_unenforced`: the cluster is test-bed only; or install a CNI with enforcement | **GO-WITH-FALLBACK** §15.1. kube-router enforces deny-all incl. ClusterIPs and pod IPs, ingress and egress, stably; **a fresh pod is unfiltered ≈ 0.15 s (5/5)** → seed gate (K1-A3). Operator: run `k2-operator-check.sh` on their kube-router |
| K3 | The base image's `socat` has `OPENSSL:` with `cert/key/cafile/commonname/verify`, and sustains fork-per-connection for the `arb`/proxy/git bridges | add `openssl` s_client wrapper or a different relay in the base image | **GO** §15.1. `backlog=1024` required on every listener (K1-A4) |
| K4 | `x509` (or OTP `:public_key`) can mint the CA and per-run leaves; OTP `:ssl` extracts CN/OU and enforces `verify_peer` on the listener | hand-rolled minimal DER builder, or HMAC bearer + `socat` `EXEC` preamble | **GO** §15.1. OTP `:public_key` alone, no `x509` dependency (K1-A5) |
| K5 | `pods/log?follow&timestamps&sinceTime` resumes without loss/duplication, including 16 KiB partial-line boundaries, and typical run output stays under the kubelet rotation window during a controller outage | `tee` file served by the snapshotter; raise `containerLogMaxSize` | **GO** §15.1. Resume lossless; three amendments: 2-s dedupe window, current-file-only retention, `seq` gap detection (K1-A6) |
| K6 | A native sidecar receives SIGTERM and the pod's grace period after the only regular container exits (naturally, OOM-killed, or evicted), enough to bundle and upload | regular sidecar + `flock` detector; larger grace | **GO-WITH-FALLBACK** §15.1. SIGTERM + full grace after natural/non-zero/OOM exit and on deletion; **eviction gives ≈ 2 s** → checkpoint-only recovery + early snapshot (K1-A7) |
| K7 | `emptyDir` `sizeLimit` eviction behaves acceptably; the snapshotter survives the eviction long enough; `tini` and the `arbiter:10001` user are added to the base image without breaking local podman workers | per-run disk quota; base image variant for clusters | not in K1 scope; datum: `sizeLimit` eviction fired 40–50 s after the limit was crossed and left the sidecar ≈ 2 s (K1-A7) |
| K8 | Read-only `subPath` file mounts over a writable mount of the same `emptyDir` behave as bind guards (`mv` fails) and kubelet accepts files created by the init container as `subPath` sources | mount the guard files from a separate read-only `emptyDir` populated by init | **GO** §15.1. Guards behave as binds; **`mv .git .git2` still succeeds** unless `.git` is itself a mount (K1-A8); same gap in today's podman layout |
| K9 | A fixed uid 10001 with a passwd entry is enough for `git`, `ssh` (ProxyCommand), `mix`, `claude` | per-image uid override in the spec | not in K1 scope; datum: `git add`/`commit` ran as uid 10001 with no passwd entry; `ssh` untested |
| K10 | Test-service sidecars: Postgres runs as uid 70 on `readOnlyRootFilesystem` with memory `emptyDir`s and the `pg_isready` `startupProbe`; `silo` likewise (`ServiceSpec` gains an optional `uid`) | per-service passwd shim volume | **GO** §15.1. `command` → `args`; uid for Postgres only (K1-A9) |
| K11 | Mint `connect(proxy: …)` carries a Phoenix WebSocket through tailscale's userspace HTTP proxy for 30 min of quiet heartbeats | reverse-proxy path B; or a `tailscale serve`-style sidecar listener | **GO** §15.1. Mint `proxy:` through the userspace proxy held a Phoenix WebSocket for 30 min (180/180 and 36/36 heartbeats acked, max 6 ms) on a disposable tailnet; the client takes `proxy:` from `HTTPS_PROXY` itself (K1-A10). Operator: the real-tailnet leg |
| K12 | PSA `restricted` admits the pod as built (native sidecars, `hostUsers:false`, `subPath`) | adjust the builder, not the namespace level | not a K1 row; datum: **GO**, PSA `restricted` admitted the §8.2 pod as built (§15.1) |
| K13 | `watch` with `resourceVersion`+bookmarks and `resourceNames`-scoped verbs behave as assumed under RBAC | relist-only informer | not in K1 scope |
| K14 | Pulling the 843 MB toolchain layer and the seed layer to `mesanna`/`aginor` takes an acceptable time (Wi-Fi on `aginor`) | pre-pull job; pin to `mesanna` | not in K1 scope |
| K15 | Namespace quota counts Pending pods' requests and rejects over-quota creates synchronously with 403 | derive `headroom` from the informer instead | not in K1 scope |
| K16 | The `ARB_ROLE=agent` release (bd-bw8a0m U5) fits the controller's 256 Mi/512 Mi budget and starts without a database | raise limits; a thinner release | not in K1 scope |
| K17 | The primary's `Worker` startup/stall watchdogs do not count `pending\|starting` time (A3 needs them not to) | add a `prepare_timeout_s` aware stage | not in K1 scope |
| K18 | Kueue's plain-Pod integration is acceptable (A `Job` would otherwise be the mature path) | revisit Job-vs-Pod | not in K1 scope |
| K19 | The controller's egress to the API server works under the §9.1 `controller-egress` policy on k3s (node IP:6443 and `10.43.0.1:443`) | broaden to the node CIDR | not a K1 row; datum: **GO** on kube-router, the controller reached the API at `10.43.0.1:443` and `<node IP>:6443` under the §9.1 policy |
| K20 | The GitLab registry accepts 300–800 MB layers and the primary can push over the LAN at acceptable speed | smaller layers; mirror | not in K1 scope |
| K21 | A pod whose controller is gone makes no external effect (no forge credential, no route except the controller) | add an in-pod deadman (snapshotter-driven) | not in K1 scope |
| K22 | k3s nodes have swap off and the kubelet's memory-backed `emptyDir`s are not swapped | document, or require swap off in readiness | not in K1 scope |
| K23 | On an SELinux cluster the default container policy admits the pod unmodified (no relabelling needed because nothing is shared across pods) | per-distro notes | not in K1 scope |
| K24 | The bridge relay's added latency and CPU are acceptable (bd-bw8a0m U3 thresholds) | second data socket, as there | not a K1 row; datum: 7–16 ms per bridged connection incl. TLS handshake, 180–340 MiB/s through the socat fork chain (K3) |
| K25 | The survey nodes have enough ephemeral storage for 2 × 4 GiB working sets plus image layers | smaller `work_size_limit` | not in K1 scope |
| K26 | `seed_paths` entries outside `deps`/`_build` (for example `priv/plts`) are safe to ship verbatim | leave them out of cluster seed layers until `seed_commands` exists | not in K1 scope |

#### 15.1 K1 spike findings (bd-6zl538, 2026-10-06)

**Verdicts.** None of the nine rows is a NO-GO, so **K3–K9 proceed**. Two are GO-WITH-FALLBACK and the fallback is already folded into the design above; the others are GO with a small amendment each.

| ID | Verdict | Evidence (one line) | Design change | Needs operator |
|---|---|---|---|---|
| K1 | **GO** | PSA `restricted` admitted the §8.2 pod (native sidecars, `hostUsers: false`, `emptyDir`/`subPath`); the user namespace was active (`uid_map 0 1524826112 65536`); files written by `seed` were readable by worker and snapshotter; read-only root, no caps, `NoNewPrivs`, seccomp 2; the sidecar honoured `terminationGracePeriodSeconds`; the §7 policy ran as written | **K1-A1** non-root is no longer PSA-enforced under `hostUsers: false` → policy + builder; **K1-A2** no `appArmorProfile` (the kubelet rejects it on a host without AppArmor) | `k1-operator-userns-check.sh` (kernel ≥ 6.3 is the Kubernetes requirement for memory `emptyDir`s with user namespaces; not tested here) |
| K2 | **GO-WITH-FALLBACK** | deny-all enforced for 13 of 13 targets from a worker and 6 of 6 from the controller, ClusterIPs and pod IPs alike, ingress and egress, with the allow rule working after DNAT; **a fresh pod is unfiltered for ≈ 0.15 s (5 of 5)** | **K1-A3** step 0 of the seed script is a gate (`refuse{netpol_unenforced}` per pod) | `k2-operator-check.sh` on the operator's kube-router |
| K3 | **GO** | `OPENSSL:` with all five options; every negative case rejected by the listener; 500 of 500 under a 100-way burst with `backlog=1024` | **K1-A4** `backlog=1024`; assert on the listener's verdict, not socat's exit code | none |
| K4 | **GO** | CA, server cert and leaves minted with OTP `:public_key` alone, 0.13 ms per leaf, OpenSSL-verified; `:ssl` enforces `verify_peer`, expiry, unknown CA and EKU | **K1-A5** no `x509` dependency | none |
| K5 | **GO** | follow + 7 forced resumes: 0 of 30,007 lines missing, 0 duplicates accepted, six 40,000-byte lines intact; continuous follow across ≈ 15 rotations: 0 of 165,013 missing | **K1-A6** 2-s dedupe window; retention is the current file only; `seq` gap detection | none |
| K6 | **GO-WITH-FALLBACK** | SIGTERM + the full grace after exit 0, exit 3, OOM-kill and on deletion (worker first); **after `sizeLimit` eviction the sidecar had ≈ 2 s**, not 30 s | **K1-A7** recovery from the last periodic checkpoint on eviction + early snapshot at 80 % + `snapshot:` field | none |
| K8 | **GO** | `mv`/`rm` of each guard `EBUSY`, writes `EROFS`; **`mv .git .git2` succeeded** until `.git` was itself a mount | **K1-A8** `.git` as a `subPath` mount | none (the podman layout has the same gap: follow-up) |
| K10 | **GO** | Postgres (uid 70) and `silo` (uid 10002, no passwd entry) as native sidecars on read-only roots with memory `emptyDir`s; real SQL over `127.0.0.1:5432`; S3 PUT/GET, including the SSE-S3 header, over `127.0.0.1:9000` | **K1-A9** `command` → `args`; a crash-looping sidecar leaves the pod `Pending` | none |
| K11 | **GO** | Mint `proxy:` + tailscaled's userspace HTTP proxy + WireGuard + `tailscale serve --tcp` carried a Phoenix V2 WebSocket over TLS: join 47 ms, 1 MB echo byte-exact, **30-minute soak: 180 of 180 and 36 of 36 heartbeats acked, max RTT 6 ms**; on a disposable headscale tailnet | **K1-A10** the client builds `proxy:` from `HTTPS_PROXY` itself; readiness is `tailscale status` Running, not the port | the real-tailnet leg (DERP path, `serve` with a public certificate) |

**Amendments, where each is applied.** *K1-A1* non-root is enforced by the builder and the §7 policy, not by PSA (§7, §8). *K1-A2* the builder never emits `appArmorProfile` (§8 table, §8.2). *K1-A3* the seed script's step 0 is the netpol gate; the canary runs it too (§9.1, §9.4, §10.1). *K1-A4* `backlog=1024` on every bridge listener; assert on the listener's verdict (§9.3). *K1-A5* minting uses OTP `:public_key` only (§9.2). *K1-A6* 2-s dedupe window, current-file-only retention, `seq` gap detection (§3.4). *K1-A7* `snapshot:` status, eviction recovers from the last checkpoint, early snapshot at 80 % (§3.3, §10.3). *K1-A8* `.git` is itself a `subPath` mount (§8). *K1-A9* a service's `command` is `args`, `uid` for Postgres (§6, §8.2). *K1-A10* the client builds `proxy:` from `HTTPS_PROXY`; readiness is the daemon's state (§2.3).

**The cluster, and why it is a VM.** One node of **k3s v1.36.5+k3s1** (the operator's cluster runs the same release; same bundled kube-router, flannel, containerd 2.3.4, runc 1.4.2, CoreDNS) in a throwaway QEMU/KVM VM (4 vCPU, 2.5 GiB, Debian 13, kernel 6.12.111) on this laptop, booted by `docs/design/k8s-spike/00-vm.sh` under `systemd-run --user --scope -p MemoryMax=3G`, user-mode networking, no sudo, nothing on the host changed (traefik, servicelb and metrics-server off). The brief asked for kind or k3d under rootless podman; **neither could answer the questions on this host**. k3s in a rootless podman container refused to start (`failed to find cpuset cgroup (v2)`: the user slice delegates only `cpu io memory pids`; a faked controllers file got past that and then broke the kubelet, `openat2 … invalid cross-device link`), and `br_netfilter` is not loaded, so even a started cluster would not have filtered same-node pod traffic and K2 would have measured nothing. A VM has real cgroups and a real kernel. Pod Security `restricted` was enforced on `arbiter-workers` (`01-namespace.yaml`). **Contact with the operator's k3s: one stray request, no approval, no effect.** At about 07:25 local on 2026-10-06 a bare `kubectl delete -f 31-netpol.yaml` ran in a shell where `KUBECONFIG` was unset, so it used the default `~/.kube/config`, whose context is `mesaana` (`https://192.168.1.169:6443`). It sent four NetworkPolicy DELETEs (`default-deny`, `worker-to-controller`, `controller-ingress-from-workers`, `controller-egress`) in namespace `arbiter-workers`; all four returned `NotFound`, so nothing there was created, changed or deleted. No operator approval for any contact existed, and none is claimed; the coordinator was told at the time, and an API audit log on mesaana, if enabled, will show those four requests. Every other cluster command either sourced `lib.sh`, which forces `KUBECONFIG` to the VM's file and exits unless the server is `https://127.0.0.1:16443`, or set `KUBECONFIG`/`--kubeconfig` explicitly, so the rest of the testing ran on the disposable VM; I could not prove from logs that this was the only contact. The kubeconfig's contents were never read or printed (only the context name and server URL). Two disposable pieces beyond the cluster: a local headscale (rootless podman) with two userspace `tailscaled` nodes for K11, and an OTP `:ssl` listener for K3. Differences from the operator's cluster that bound these verdicts: one node (cross-node pod traffic over flannel was not exercised), single-stack IPv4, Debian's nftables-based `iptables`, kernel 6.12, AppArmor on (and off, K1), no SELinux.

**Where the evidence is.** Manifests, scripts and **raw outputs** are in `docs/design/k8s-spike/` (`results/*.txt` are the unedited outputs the numbers below come from; scripts take `SPIKE_KUBECONFIG` and `SPIKE_VSSH`). Test-only code: `apps/arbiter_web/test/spike/k11_proxy_ws_test.exs` (tag `:spike_k8s`, excluded by default) and a `proxy:` pass-through in the spike `WsClient`. No `lib/` file changed and no dependency was added.

**K1: native sidecars, `hostUsers: false`, PSA, VAP, AppArmor.** `k1-pod.yaml.tpl` is the §8.2 pod (the spike's scripts come from a ConfigMap instead of being rendered in). `results/k1-hostusers-false-gitdir-mount.txt`: admitted by the `restricted` namespace; `seed` (uid 10001) wrote `.git/{config,commondir,hooks,objects/info/alternates}` into the `work` `emptyDir`, the worker and the snapshotter saw them as 10001 through `subPath`; `touch /rootfs-probe` fails `EROFS`; `CapEff 0`, `NoNewPrivs 1`, `Seccomp: 2`, AppArmor `cri-containerd.apparmor.d (enforce)`. `results/k1-control-hostusers-true.txt` is the control (a host-user pod shows `uid_map 0 0 4294967295`). Admission (`k1-admission.sh`, `results/k1-psa-vap-admission.txt`): PSA denied a missing or `Unconfined` seccomp profile, a `hostPath` volume and a privileged container; the 20-vap policy denied an off-list image, `hostUsers: true`, a writable root and uid 0. **Finding (K1-A1):** with `hostUsers: false` PSA `restricted` *admitted* pod-level `runAsUser: 0, runAsNonRoot: false` (`results/k1-psa-negative-controls.txt`); the same pod is denied by the extra VAP rule. `results/k1-design-vap-cel-verbatim.txt`: the §7 CEL as written compiles and enforces. **Finding (K1-A2):** `results/k1-no-apparmor-node.txt`: on the same VM booted with `apparmor=0`, the pod with `appArmorProfile: RuntimeDefault` was rejected by the kubelet (`Cannot enforce AppArmor: AppArmor is not enabled on the host`, phase `Failed`); the pod without the field ran, and on the AppArmor boot the omitted field still got containerd's default profile.

**K2: NetworkPolicy deny-all** (`k2-run.sh` → `results/k2-run.txt`; fixtures `30-k2-pods.yaml`, policies `31-netpol.yaml` = §9.1 with this VM's addresses). *Baseline first:* with no policy all 16 worker targets connected, so every later block is a policy effect. *With the policies:* the worker connected to exactly the controller Service on 9443 and 9444 and the controller pod IP on 9443, and was **rejected** (immediately) at the controller on 8080 (Service and pod IP), the `kubernetes` ClusterIP, the node IP on 6443/22/10250, the CNI gateway, another namespace's pod, another worker, the CoreDNS Service and pod IPs, 1.1.1.1:443 and 8.8.8.8:53. The controller reached the API through the ClusterIP and the node IP (K19), CoreDNS (Service and pod IP) and 1.1.1.1:443, and was rejected at 8.8.8.8:53, the node's 22 and 10250, a pod in another namespace, a worker, and the DNS metrics port. Ingress: another namespace's pod could not reach the controller (pod IP or Service) or a worker; a worker could not reach another worker; the node's own traffic always got through (the NetworkPolicy contract). Six repeated passes were identical; enforcement held over a 360-s watch (`results/k2-stability-360s.txt`, which spans kube-router's default 5-minute resync) and for 70 consecutive 1-s ingress probes (`results/k2-ingress-loop-70s.txt`); a new policy took effect 1.2 s after `kubectl apply` returned (`results/k2-policy-apply-to-enforcement-lag.txt`). **Finding (K1-A3):** `results/k2-startup-window.txt`: five fresh pods looping from their first instruction connected to the API ClusterIP, the node API port and 1.1.1.1:443 for 0.13–0.18 s before kube-router programmed them; `results/k2-startup-window-with-gate.txt`: with the gate the canary was rejected 0.37–0.55 s after start and **0 of the probes that followed connected**, in all five. Probe pitfall worth keeping: `exec 3<>/dev/tcp/H/P; echo ok` prints `ok` even when the connect fails (bash continues after a failed `exec` redirection); an early ingress run reported false "CONNECTED" lines this way, which is why the kept scripts use `&&`.

**K3: socat `OPENSSL:`** (`40-k3-socat-mtls.sh`, `41-k3-socat-fork-load.sh`; `results/k3-*.txt`). Server: the OTP listener of `k4_mint.exs serve`. A leaf with `OU=proxy` and `OU=arb` was accepted and its CN/OU read; no client certificate → `certificate_required`; an expired leaf → `certificate_expired`; a leaf from another CA → `unknown_ca`; a `serverAuth`-only leaf → `unsupported_certificate {invalid_ext_keyusage}`; a wrong `commonname=` made the client abort; `verify=0` accepted the wrong name, as it should. Load, on socat 1.8.0.3 from the base image: 300 sequential connections at 7–16 ms each (handshake included); a 100-way burst ×5: **369–389 of 500 answered with the default listen backlog, 500 of 500 in 1.3 s with `backlog=1024`**; 200 MiB through the fork chain at 180–340 MiB/s; 100 MiB sent three times socat-to-socat with matching sha256. An initial 1.5 MB shortfall at the OTP end was traced to the *test client* (one-way `socat -u` closing with an unread greeting → RST) and disappeared with a bidirectional client (3 of 3 exact, `results/k3-halfclose-artifact-resolved.txt`); TLS 1.2 vs 1.3 made no difference.

**K4: minting.** `k4_mint.exs`: EC P-256 CA (`CA:TRUE, pathlen:0`, `keyCertSign`), server certificate (SAN DNS `arbiter-controller` + the Service IP, `serverAuth`), and leaves with `CN = run id`, `OU = bridge`, `clientAuth`, valid until the run deadline; 200 leaves in 24–29 ms; `openssl verify` accepted the good chain and rejected the expired and foreign-CA leaves. The only trap was the `iPAddress` SAN encoding (a four-integer list).

**K5: `pods/log`** (`k5_logs.py`, `k5_since_probe.py`, `results/k5-*.txt`). A producer pod wrote numbered lines (2,000/s) and a 40,000-byte line every 25th burst, so lines cross the 16 KiB CRI chunk boundary. The client followed, dropped the connection every 2 s, resumed with `sinceTime` = the last timestamp seen, de-duplicated by `(timestamp, sha1)` and drained with one non-follow read: 7 resumes, 35,418 lines received, 5,411 duplicates dropped, **30,007 accepted, none missing, no duplicate sequence number, all six long lines intact**. `k5_since_probe.py`: a nanosecond `sinceTime` returned 601 lines from the *same second but before* it (`sinceTime` is second-granular) and the second-truncated value returned exactly the same 15,605 lines; all 30,007 timestamps were distinct. Rotation: 158 MiB at 1.6 MB/s with no reader → only the last 12,501 lines (≈ 12 MiB, 8 %) were readable afterwards; a continuous follower over the same kind of run (≈ 15 rotations) received **165,014 lines (165,013 numbered plus the `END` line), none missing**. Rates: 111 Claude transcripts longer than five minutes on this host grew at a median 0.7 KiB/s, p90 1.4, p99 2.7 (transcript growth stands in for stdout; stdout itself was not measured).

**K6: sidecar termination** (`results/k6-*.txt`; `pod-scripts/snapshotter.sh` logs its SIGTERM and a 5-s "upload", optionally to a TCP sink so evidence survives the pod). *Worker exits 0 / 3 / OOM-killed (`OOMKilled`, 137):* the snapshotter got SIGTERM 0.4–0.6 s later and finished its handler (exit 0). *Handler longer than the pod's grace (3-s grace, 10-s handler):* SIGKILL at 3.3 s, exit 137, pod phase still `Succeeded`. *`kubectl delete` with a worker that takes 3 s to stop:* worker TERM at +0.07 s, snapshotter TERM 0.06 s after the worker exited, gone at +9 s. *`emptyDir` `sizeLimit` eviction (100 Mi limit, 400 MB written):* `Evicted` after 40–50 s; the sidecar's SIGTERM, one tick of its handler, then SIGKILL about 2 s later (`results/k6-evict-sidecar-sink.txt`), despite `terminationGracePeriodSeconds: 30`. So the §10.3 claim holds for every exit **except eviction**.

**K8: guard mounts** (same pod; `results/k1-hostusers-false-gitdir-mount.txt`). With the four guards: `mv`/`rm` of each → `Device or resource busy`, writes → `Read-only file system`; controls (HEAD write, a tree write, `git add && git commit`) succeed; kubelet accepted `seed`-created files as `subPath` sources. `mv .git .git2` **succeeded** (`results/k1-control-hostusers-true.txt`), and the same happens under podman with the bind layout `PrivateClone.mounts/1` builds (`results/k1-podman-parity-mv-gitdir.txt`: `mv .git .git2` succeeds, the host then sees `.git2`). With `.git` mounted as a `subPath` of the same volume, `mv .git .git2` fails `EBUSY`. **Not investigated and flagged for the coordinator:** whether the primary's host-side `git` in a podman shadow clone would trust a worker-replaced `.git/config` or `hooks` after such a rename. If it does, the existing podman path has a hole the cluster design closes with one mount; a follow-up ticket should check `PrivateClone` and `Container.mounts`.

**K10: service sidecars** (`50-k10-services-pod.yaml`, `results/k10-*.txt`). Order: `svc-postgres` → `svc-s3` (both native sidecars with the presets' `startupProbe`s) → `pgcheck` (a regular init container that ran `create table`, `insert … generate_series(1,1000)`, `select count(*)` → 1000 over `127.0.0.1:5432`) → `worker` (S3 bucket create, PUT, GET and an `x-amz-server-side-encryption: AES256` PUT all 200 over `127.0.0.1:9000`, and a PostgreSQL `SSLRequest` answered `N`). Both sidecars exited 0 within about a second of the worker, the pod ended `Succeeded`. Negative control: the same Postgres with the preset's `command` rendered as `command:` → `CrashLoopBackOff`, pod `Pending`.

**K11: Mint through tailscale's userspace HTTP proxy** (`60-k11-tailnet.sh`, `apps/arbiter_web/test/spike/k11_proxy_ws_test.exs`, `results/k11-mint-via-userspace-proxy-30min.txt`). A worker has no tailnet of its own to use (and the operator's was off limits), so the test builds a **disposable** one: a local headscale v0.29.4 in rootless podman and two `tailscaled --tun=userspace-networking` nodes joined with a throwaway pre-auth key. Node A (the agent side) runs `--outbound-http-proxy-listen=127.0.0.1:18055`; node B (the primary side) fronts the test endpoint with `tailscale serve --tcp 8443 tcp://127.0.0.1:19443`. The endpoint is RW2's spike Phoenix endpoint (Bandit, V2 serializer) over TLS with a certificate from `k4_mint.exs` (SAN = B's tailnet IP). The client is RW2's `WsClient` plus a pass-through of `proxy: {:http, "127.0.0.1", 18055, []}` to `Mint.HTTP.connect`; TLS options go in `transport_opts` and apply to the target, not the proxy. Path: Mint → proxy (`CONNECT 100.64.0.2:8443`) → WireGuard (a direct path, ≈ 1 ms; both nodes are on this host) → `serve` → endpoint. **Results:** connect and join 46–47 ms; a 1,000,000-byte binary frame echoed byte-exact in 32–38 ms; the **30-minute soak** (two sockets, 10-s and 50-s heartbeats, plus the 30-s Phoenix heartbeat) kept both open for 1,800 s with **180 of 180 and 36 of 36 heartbeats acked, p99 RTT 5 ms and 3 ms, max 6 ms**. The client can tell two failures apart: proxy not listening → `{:connect_failed, %Mint.TransportError{reason: :econnrefused}}`; proxy up, target unreachable → `{:connect_failed, %Mint.HTTPError{reason: {:proxy, {:unexpected_status, 500}}, module: Mint.TunnelProxy}}` (the proxy's `Tailscale-Connect-Error` header is not surfaced by Mint). Two proxy behaviours worth knowing: a **logged-out** `tailscaled` still listens on the proxy port but answers every CONNECT with 500 (`operation was canceled`), so readiness is the daemon's state, not the port; and a raw client that sends `CONNECT` and then half-closes gets the same 500 (Mint does not). **Not covered:** a DERP-relayed or high-RTT path; `tailscale serve` terminating TLS with a public certificate (the TCP forward used here passes TLS through; RW2's U1 covers the HTTPS `serve` leg on the real tailnet); the sidecar restarting under a live socket (the agent's reconnect loop, K11 child); and `HTTPS_PROXY` handling, which Mint does not do.

**Needs operator.** (1) **K2 on the operator's kube-router.** The K2 matrix was **not** run on their cluster (apart from the one stray request recorded above, which tested nothing). `docs/design/k8s-spike/k2-operator-check.sh` is the whole check: it discovers every address, creates two namespaces (`arb-k2-check`, `arb-k2-other`), runs the baseline-then-policies matrix above plus the fail-open probe, prints `PASS`/`FAIL` per target, and deletes both namespaces on exit; it creates no cluster-scoped object and does not touch `kube-system`. It refuses to run unless `K2_CONFIRM_SERVER` equals the context's API server URL (read the printed URL first): `K2_CONFIRM_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" docs/design/k8s-spike/k2-operator-check.sh`. A working cluster ends with `RESULT: PASS`, and the `NOTE` line says whether the start-up window exists there (it did on the VM, and the seed gate covers it either way). I validated the script itself on the disposable cluster (24 of 24 `PASS`, `results/k2-operator-script-validated-on-disposable.txt`). (2) **K1 on their nodes:** `K1_CONFIRM_SERVER=… docs/design/k8s-spike/k1-operator-userns-check.sh` (one namespace, one pod; validated on the VM) answers whether `hostUsers: false` works with their kernel, runc and volume types; the Kubernetes documentation requires kernel ≥ 6.3 for memory-backed volumes with user namespaces, and `uname -r` per node is the quick look. (3) **K11 on the real tailnet.** The disposable tailnet cannot show a relayed path or `serve` with a public certificate. From any tailnet device running a userspace proxy (`tailscaled --tun=userspace-networking --outbound-http-proxy-listen=127.0.0.1:1055`, joined with an ephemeral tagged key) while RW2's `serve_soak.sh` is staging its `:8444` mapping on the primary: `curl -sS -x http://127.0.0.1:1055 https://<primary>.<tailnet>.ts.net:8444/nodes/ping` must print `pong`, and RW2's `remote_peer_check.mjs` run through that proxy's host for 30 minutes covers the socket itself.

**What K1 did not settle.** More than one node (flannel's cross-node path and kube-router together); IPv6; node-pressure eviction (the same kubelet path as `sizeLimit` eviction, not triggered); an SELinux node (K23); `ssh` as uid 10001 (K9 beyond `git`); registry pulls and layer sizes (K14, K20); Kueue (K18); controller restart, adoption and the informer (K3 child); the real snapshotter, entry wrapper and `tini` (K7); the stdout rate of a real Claude run (transcript growth was used); a kernel other than 6.12. **Rerun:** `00-vm.sh` (needs the Debian 13 genericcloud image), `lib.sh`-based scripts with `SPIKE_KUBECONFIG` and `SPIKE_VSSH` set, then `run-pod.sh`/`wait-pod.sh` (K1, K6, K8), `k1-admission.sh`, `k2-run.sh`, `40-`/`41-k3-*.sh`, `k5_logs.py`, `50-k10-services-pod.yaml`, and `mix test --include spike_k8s apps/arbiter_web/test/spike/k11_proxy_ws_test.exs` for K11.

### 16. Implementation breakdown (the coordinator files these; none above D3)

Numbering is this ticket's; "bw#N" means bd-bw8a0m's child N (its §18). The spike gates K3–K9.

| # | Title | Diff. | depends_on | Notes |
|---|---|---|---|---|
| K0 | Commit this section into `docs/design/remote-workers.md` (replacing §16 there) and apply amendments A1–A7 to the document | D1 | bw#1 | status "proposed" |
| K1 | **Spike: go/no-go** on a disposable cluster (kind/k3d under rootless podman) | D3 | K0, bw#2 | covers K1, K2 (also on the operator's k3s **only with explicit go-ahead**), K3, K4, K5, K6, K8, K10, K11; real API server, PSA `restricted`, native sidecars, `socat` mTLS, log resume, sidecar SIGTERM; **GO / NO-GO / GO-WITH-FALLBACK per K-row**; amends §15 |
| K2 | `Arbiter.NodeAgent.Backend` behaviour and the `ARB_AGENT_BACKEND` switch | D2 | bw#5 | extract the podman run supervisor's seam; no behaviour change; guard-test inventory entries |
| K3 | Kubernetes API client on `Req` + pod informer + the pure pod-state function | D3 | K2 | in-cluster auth, list/watch/create/delete/log-follow, relist, a fake API server (Plug under Bandit in ExUnit); state-table tests for every §3.3 row; **K1-A6/A7**: `sinceTime` is second-granular (2-s dedupe window), `pods/log` serves the current file only, `seq` gap detection, `snapshot:` from `initContainerStatuses`; a crash-looping sidecar leaves the pod `Pending` |
| K4 | `K8s.PodSpec` builder + conformance tests | D3 | K1 | pure; one test per §8 row; a table-driven PSA-`restricted` checker; golden pod YAML; refuses `network: pasta`, `seLinuxOptions`, unknown mount kinds; admission-policy CEL tests where possible; **K1-A1/A2/A8/A9**: the checker asserts non-root itself (PSA does not under `hostUsers: false`), never emits `appArmorProfile`, mounts `.git` itself, renders a service's `command` as `args`; the §7 CEL (with the two new rules) is verified verbatim |
| K5 | Controller core: config loader, admission/capacity, run lifecycle, cancel/teardown, adoption, reaper, Lease | D3 | K3, K4, bw#9 | §3, §4; restart-survival and `pending`-never-`running` tests; `hb.capacity`; ConfigMap closed schema |
| K6 | Pod channel: per-install CA, leaf minting, TLS listeners 9443/9444, `/boot` nonce, bridge relay into `bridge.open`, seed/checkpoint/transcript streaming | D3 | K1, bw#10, bw#11 | §9.2/§9.3, §10; end-to-end test that `BridgeIdentity`, policy decisions and `egress_events` are unchanged; **K1-A4/A5**: OTP `:public_key` minting (no `x509` dependency), `backlog=1024`, assert on the listener's verdict (TLS 1.3 hides a rejected client cert from socat) |
| K7 | Pod runtime: seed script, entry wrapper, snapshotter, base-image changes (`tini`, uid 10001, passwd), layout contract test vs `PrivateClone`'s builder | D3 | K1, K4 | shellcheck + podman-run harness; guard-file read-only checks; **K1-A3/A6/A7/A8**: seed step 0 is the netpol gate, stdout numbering filter in the entry wrapper, snapshotter polls `work` usage and snapshots at 80 % of `sizeLimit`, `.git` mount |
| K8 | Image publication on the primary: `Image.Publisher`, `nodes.registry` settings (Cloak), CLI layer, seed layer from `DepsCache` + `seed_paths` handling, controller image | D3 | bw#4 | §10.4, §11; `ensure_ready` timeout + fallback; doctor row |
| K9 | Install and "Add node": kind selector, manifest renderer (bootstrap/node, tailscale and admission-policy variants), `arb node add --kind cluster`, enroll `kind: cluster`, self-upgrade, join Secret flow | D3 | bw#4, bw#7, K5 | §2; manifests golden-tested; no-secret-in-render test |
| K10 | Test services as native sidecars (`ServiceSpec` → container, `uid`, `startupProbe` from `ready`) | D2 | K4 | §8.2; **K1-A9**: `args`, `uid` for Postgres only (silo runs as any uid) |
| K11 | Reachability: tailscale-sidecar variant and Mint HTTP-proxy support in the agent WebSocket client | D2 | bw#5 | §2.3; **K1-A10**: the client builds `proxy: {:http, host, port, []}` from `HTTPS_PROXY`/`ALL_PROXY` itself (Mint does not read the environment), puts CA trust in the target's `transport_opts`, and tells `econnrefused` on the proxy from `{:proxy, {:unexpected_status, 500}}`; the pod's readiness for the tailscale variant is `tailscale status` Running |
| K12 | Primary-side protocol amendments: `pending`/`refuse`/`capacity`/cursors/`pod_disrupted`, `Placement` constrained handling, `Worker` startup-watchdog stage | D3 | bw#6, bw#8, K0 | A3–A5, A7; **[K17]** first |
| K13 | Readiness canary + `arb server doctor` cluster section + end-to-end verification + `docs/remote-workers-k8s-runbook.md` + the k3s test-bed rollout checklist | D3 | K5, K6, K9, K12 | §9.4, §13; `:k8s`-tagged tests excluded by default; **K1-A3**: the canary runs the gate first; `k2-operator-check.sh` is the k3s test-bed rollout's first step |

Order: K0 → K1 → {K2, K11} → {K3, K4} → {K5, K6, K7, K8} → {K9, K10, K12} → K13. The spike's verdict on K2/K6 (NetworkPolicy and sidecar SIGTERM) decides whether the later children are worth starting at all on any given cluster.

### 17. How names in this document were checked

Read at `9b5fb0733`: `Arbiter.Worker.Container` (`argv/2` :145, `placement/1`, `mounts/2`, `mount_opts/2`, moduledoc label policy), `Container.wrap/2` option set, `PrivateClone.mounts/1` and `@readonly_in_git_dir ~w(config hooks commondir objects/info/alternates)`, `ContainerSpawn.prepare/1` (request map: `name`, `image`, `mounts`, `home`, `config_dir`, `writable_paths`, `cli_mounts`, `prompt_paths`, `network`, `env`, `pod`, `deps_cache`), `ContainerSpawn.run_dirs/2`, `Jail.network_command/2` and its `@network_script` (per-listener `TCP-LISTEN:…,bind=127.0.0.1,fork` → `UNIX-CONNECT`), `Jail.network_env/1`, `TestServices` service shape (`name`, `image`, `env`, `command`, `tmpfs`, `ready`, `worker_env`; `postgres/1` and `s3/1` presets; `service_run_argv/4` with `--read-only --cap-drop=all no-new-privileges`), `DepsCache` moduledoc (key `<lock12>-<image12>`, seed job, never mounted), `SeedPaths` (`resolve/2`, `effective/2`), `Worktree.seed_compiled_deps/3`, `Image` base Containerfile (`debian:trixie-slim`, `bc build-essential ca-certificates curl git libncurses6 libsctp1 libssl3t64 openssh-client procps socat sqlite3`; no `tini`, no named user), `ClaudeSession` stdin handling (`exec "$@" < /dev/null`). Measured on this host: `deps` 51 MB, `_build` 293 MB (main checkout), toolchain image 843 MB / base 464 MB (`podman images`); bundle sizes from bd-bw8a0m. Cluster facts: the three admiral memory files named at the top, **not re-verified**. Names that do not exist yet are marked **new**: `Arbiter.NodeAgent.Backend`/`Backend.K8s`, `Arbiter.NodeAgent.K8s.PodSpec`, `Image.Publisher`, settings `nodes.registry.*`, `allow_unenforced_network`, the `arbiter.dev/*` labels, routes `/nodes/join/k8s.yaml`, the controller's `:9443`/`:9444` endpoints, `ARB_AGENT_BACKEND`, `ARB_BRIDGE_ADDR`, `ARB_BOOT_NONCE`.

## 17. Unverified assumptions (replaces bd-aowisc §10)

Each is checked by the spike (child 2, §18) unless noted. **No-go consequence** says what changes if it fails. **RW2 (bd-6tx1xv) ran U1–U5, U7–U10, U13 and U19; the last column is its verdict, §17.1 the evidence and the design changes.** A row's earlier columns are the pre-spike wording and are kept as written.

| ID | Assumption | Why it matters | Check | If it fails | RW2 verdict |
|---|---|---|---|---|---|
| U1 | `tailscale serve` carries a WebSocket upgrade on a non-dashboard path and does not kill a quiet socket (10 s heartbeats); `--set-path` can expose only `/nodes` + `/node/socket` | the whole reachability story | real `serve`, 30-min soak | add a second `serve` port mapping to the same loopback, or fall back to path 3 of §4.3 (`ssh -L`) | **GO** (this host; cross-device leg: needs operator) §17.1 |
| U2 | `mint_web_socket` (not currently in `deps/`) speaks Phoenix's V2 serializer incl. binary frames, and a ~300-line client is enough | agent transport | prototype client against `Phoenix.ChannelTest` + a Bandit-served endpoint | `slipstream`/`phoenix_gen_socket_client`, or a raw `WebSock` data path | **GO** §17.1 |
| U3 | Bridge mux adds p99 ≤ 250 ms at 10 concurrent runs and acceptable CPU on the primary | bridge decision (§8) | replay a recorded SSE stream through proxy→mux→proxy; vary RTT with `tc netem` | second data socket; if still failing, reconsider agent-side proxy | **GO-WITH-FALLBACK** §17.1 |
| U4 | Heartbeat jitter < 5 s on the same socket during a 5 MB bridged push | single-socket decision (§4.2) | measure | second socket for bridge data | **GO** (node cap 1 MiB → 256 KiB) §17.1 |
| U5 | The release boots in `ARB_ROLE=agent` without `SECRET_KEY_BASE`, DB or cloak key; start time and RSS are acceptable | agent packaging | boot a release with the role set | a second release definition (`applications: [arbiter: :load, …]`) in the same `mix release` config | **GO** §17.1 |
| U6 | The modules the agent reuses are DB-free or can be fed their inputs: `Container`, `PrivateClone`, `Worktree` helpers, `DepsCache` (aliases `Arbiter.Mergers`), `TestServices`, `PodmanReadiness`, `Egress.Listener` | "run the same builders on the node" | grep + load each in a role-agent VM with `Repo` absent | thin extraction modules; adds to child 9 | not in RW2 scope (modules load, §17.1 U5) |
| U7 | `git bundle` round trip keeps exec bits, symlinks, deletions and rename detection; `fetch.fsckObjects` applies to bundle fetch; thin `^have` bundles work; submodule/LFS veto scan of registered repos | checkout sync | fixture repos incl. submodule/LFS | fsck with an explicit `git fsck` pass after fetch; veto list grows | **GO** §17.1 |
| U8 | Rootless `--memory`/`--memory-swap` are enforced and `.State.OOMKilled` is reported **without** `--rm`; `--cpus` needs `cpu` delegation | memory cap | per distro (carried from bd-aowisc §10.3) | `degraded: :uncapped` (excluded by default) | **GO** (this host; other distros: needs operator) §17.1 |
| U9 | `loginctl enable-linger` for self works without sudo (polkit) and is enough for rootless containers/user units to outlive the session | install | ubi8, ubi9, debian 12, Ubuntu 24.04 via podman recipes | script refuses with instructions (already the fallback) | **GO** (this host; other distros: needs operator) §17.1 |
| U10 | Reliable detection of memory-controller delegation to the user slice across those distros | join-script prereq | script test matrix | refuse more often; document the `Delegate=` drop-in | **GO** (this host + fixtures; other distros: needs operator) §17.1 |
| U11 | Only x86_64 Linux is published today (`release.yml`: one `ubuntu-latest` job in `redhat/ubi8`) | arch refusal | read the workflow's matrix and release assets | arm64 nodes wait for a second release job | not in RW2 scope |
| U12 | Build-from-plan on a node finishes in an acceptable time and needs only public registries/mirrors; the tag the node computes equals the plan's | images (§7.3) | build the 843 MB toolchain image on a clean node; time it vs `save \| load` | `save/load` fallback becomes default | not in RW2 scope |
| U13 | Secret env values never reach persistent storage on the node (OCI spec on tmpfs; no log lines) | §11 claim | inspect `$XDG_RUNTIME_DIR/containers`, `journalctl`, agent logs | document, or deliver secrets by a tmpfs file mount | **GO-WITH-FALLBACK** (`-e NAME` is NO-GO; tmpfs file mount) §17.1 |
| U14 | `Socket.id` + `Endpoint.broadcast(id, "disconnect", _)` closes a live node socket immediately under Bandit | instant revoke | test | `Nodes.Session` self-stops on its own revoke check each heartbeat | not in RW2 scope |
| U15 | Single-use token redemption is atomic via a conditional update through Ash/Ecto on SQLite | token lifecycle | concurrent-redeem test (two processes) | raw `Repo.query` update | not in RW2 scope |
| U16 | The retained deploy tarball and the allowlist-packed tree both boot as agents and match the published sha for published releases | packaging | compare against a published asset | serve only retained tarballs; `--local` nodes unsupported | not in RW2 scope |
| U17 | A reconnect storm after a primary restart (N nodes) is absorbed and the 90 s recovery budget covers boot-to-endpoint-up on this host | boot ordering | restart the dev instance with simulated agents; read boot timing | longer budget / staggered reconnect | not in RW2 scope |
| U18 | The three `Worker` port clauses plus `terminate_session_port/2` and `session_live?/1` are the complete port surface | remote handle (§7.2) | grep + `mix test` of `Worker` with a fake handle | widen child 9 | not in RW2 scope |
| U19 | The Claude CLI rides through a stalled/refused proxy socket for up to `fence_after` (retries instead of failing the turn) | blip survival (§10.2) | kill the mux for 30 s mid-turn | blips become restarts: set `fence_after` low, drop the claim | **GO** (CLI retry budget caps `fence_after_s` at 90) §17.1 |
| U20 | Tailscale identity headers on node requests are usable as an audit hint; the public-endpoint heuristic has acceptable false-positive rate | exposure doctor check | inspect headers via `serve` | drop the hint, keep the heuristic as a warning | not in RW2 scope (headers observed, §17.1 U1) |

### 17.1 RW2 spike findings (bd-6tx1xv, 2026-10-06)

**Host.** The operator's laptop, shared with live workers: Fedora 44, kernel 7.2.8, systemd 259.9, rootless podman 5.8.7 (crun, cgroup v2, systemd cgroup manager), git 2.55.0, tailscale 1.102.4, Elixir 1.19.4 / OTP 26 for the test build, the published `v0.2.18` release for U5, Claude CLI 2.1.291. The tailnet is the real one, with `tailscale serve` already fronting the dashboard on :443. Anything that could allocate ran under `systemd-run --user --scope -p MemoryMax=3G`; netem runs inside a private user+net namespace (`unshare --user --map-root-user --net`, no sudo, no effect outside it); the release boot ran on a copy with distribution off and a scratch `HOME`.

**What the prototypes are.** Test code and scripts, excluded by default (`mix test --include spike_rw <file>`, and `--include spike_serve` for U1), under `apps/arbiter_web/test/support/spike/` (V2 client, mux, endpoint, channel, agent mux, load) with drivers in `apps/arbiter_web/test/spike/`, and under `apps/arbiter/test/spike/remote_workers/` (bundles, podman, prereqs, release boot, Claude CLI scenarios). One dependency was added, test-only: `{:mint_web_socket, "~> 1.0", only: :test, runtime: false}`. No `lib/` file changed. The SSE trace is **synthesised** (Anthropic-shaped `content_block_delta` events, 120–420 B, seeded exponential gaps at 40 events/s per run), not recorded from the live API; no real credential was used anywhere (the CLI talked to a local fake API inside a loopback-only namespace).

| ID | Verdict | Evidence | Design change | Needs operator |
|---|---|---|---|---|
| U1 | **GO** | WS upgrade, 1 MB binary echo and a quiet-socket soak through the real `serve` on a non-dashboard path, whole-app and `--set-path` mappings (below) | `--set-path` target must carry the path | the cross-device leg: `remote_peer_check.mjs` from another tailnet device |
| U2 | **GO** | V2 JSON + binary both ways, 0 B – 1 MB frames byte-exact, 222-line client | `nodelay: true` | none |
| U3 | **GO-WITH-FALLBACK** | added p99 ≤ 42 ms to 80 ms RTT, ≤ 218 ms at 150 ms RTT with ≤ 0.1 % loss; fails at 150 ms + 0.5 % loss (1.1–1.4 s); sharded sockets restore 225 ms | link-quality note; shard-by-run is the fallback | none |
| U4 | **GO** | 5 MiB push moves heartbeat RTT ≤ 2.3 s at ≥ 2 Mbit/s; worst combined case 7.1 s with the 1 MiB cap, 3.2 s with 256 KiB | node in-flight cap 1 MiB → 256 KiB; fair scheduling | none |
| U5 | **GO** | release boots as an agent in 0.5–1.4 s, ≈100 MB RSS, no key/DB; both Application modules must be gated | none | none |
| U7 | **GO** | exec bits, symlinks, deletions, renames, uncommitted + untracked files survive; fsck on fetch rejects a `.git` tree | `--no-tags`; fsck, not `bundle verify`, is the gate | none |
| U8 | **GO** | 64 MiB cap enforced, `OOMKilled=true` readable without `--rm` | emit limits only for delegated controllers; functional probe | other distros and the negative (no memory delegation) case |
| U9 | **GO** | self `enable-linger`/`disable-linger` with no sudo, no tty, no session | `--no-ask-password` | other distros; survive-logout |
| U10 | **GO** | detection against fixtures and the live host agrees with podman | read `user@<uid>.service`, not the session; functional probe is the authority | other distros |
| U13 | **GO-WITH-FALLBACK** | `-e NAME` puts the secret in `config.json` and `db.sql` on persistent storage (**NO-GO as designed**); a tmpfs file mount leaves no copy | secrets delivered by tmpfs file mount + command wrapper | none |
| U19 | **GO** | real CLI survives stall ≥ 120 s, refuse ≥ 180 s, reset ≥ 90 s (gives up at ≈177 s) | `fence_after_s` ≤ 90; listeners hold, then reset at the fence | none |

#### U1 `tailscale serve` carries the node socket — GO

* **Method.** `apps/arbiter_web/test/spike/serve_soak.sh` adds two throwaway HTTPS ports to this node's serve config (`:8443` whole app → the spike endpoint on loopback; `:8444` with `--set-path /node/socket http://127.0.0.1:P/node/socket` and `--set-path /nodes http://127.0.0.1:P/nodes`), never touches the existing :443 mapping, removes both on exit and diffs the final serve config against the starting one (it printed `serve config restored: identical to the starting config` every run). The test (`serve_soak_test.exs`) is a mint_web_socket client over TLS with the system CA store.
* **Evidence.** A Phoenix socket on `/node/socket/websocket` upgrades through both mappings, joins, answers `hb` with `hb_ack`, and echoes **1,000,000 bytes of binary** through `serve`. A second, unrelated client (Node 22's built-in `WebSocket`, `remote_peer_check.mjs`) joined the same endpoint through `:8444`. On the `--set-path` port `/nodes/ping` → `pong`, while `/` → 404, `/live` → 404 and an upgrade to `/other/socket/websocket` → 404: only the two named paths are exposed. **`--set-path` keeps the path**: mapping `--set-path /nodes http://127.0.0.1:P/nodes` delivers `/nodes/headers` to the backend as `/nodes/headers`, so the target URL **must include the path** (a bare `http://127.0.0.1:P` target would deliver `/headers`).
* **Soak.** **1,800 s (30 min) soak, three sockets at once**: a 10 s-heartbeat socket on the `--set-path` port (180 of 180 `hb` acked, heartbeat RTT max 14 ms), a 50 s-heartbeat socket on the same port (36 of 36 acked; 50 s is just under the 60 s idle timeout Phoenix's socket transport enforces on the server side, so any shorter idle kill by `serve` would show here), and a 10 s-heartbeat socket on the whole-app port (180 of 180, max 11 ms); none was closed. `tailscale serve` did not time out a socket that is quiet except for heartbeats.
* **Headers (U20 input).** `serve` adds `Tailscale-User-Login`, `Tailscale-User-Name`, `Tailscale-User-Profile-Pic`, `Tailscale-Headers-Info`, `X-Forwarded-For` (the caller's tailnet IP), `X-Forwarded-Host` and `X-Forwarded-Proto`; the backend peer is `127.0.0.1`. That confirms §5.4's rate-limit key (`X-Forwarded-For` only when the peer is loopback) and that the user headers are available for user-owned devices; they were not observed for a tagged device (none was reachable here), so they stay a hint.
* **Limits.** This host connected to its own serve endpoint (own-IP traffic is delivered locally and then handled by serve), which exercises TLS termination, the reverse proxy and WebSocket upgrade/keep-alive but **not the WireGuard leg** (direct or DERP) nor a tailnet ACL. **Needs operator:** with `serve_soak.sh` running on the primary, run on a *different* tailnet device `node apps/arbiter_web/test/spike/remote_peer_check.mjs 'wss://<primary>.<tailnet>.ts.net:8444/node/socket/websocket?vsn=2.0.0&token=spike-token' 1800 10` (exit 0 = the socket stayed open for 30 min with every heartbeat acked) and `curl -sS https://<primary>.<tailnet>.ts.net:8444/nodes/ping` (expect `pong`), `curl -sS -o /dev/null -w '%{http_code}\n' https://<primary>.<tailnet>.ts.net:8444/` (expect `404`). If a DERP-relayed device kills the quiet socket, the table's fallback applies (a second `serve` port mapping, or §4.3 path 3).
* **Design change.** §4.3: the `--set-path` mapping form above is now the documented one.

#### U2 `mint_web_socket` speaks Phoenix V2 — GO

* **Evidence** (`ws_transport_test.exs`, real Bandit, real TCP; 6 tests pass). JSON push, reply, server push, the `phoenix` heartbeat; binary frames both ways at 0, 1, 255, 16,384, 65,535, 65,536, 262,144 and 1,000,000 bytes, byte-exact (the endpoint's `max_frame_size` is 1 MiB); a 1.1 MB frame **closes** the socket (`{:deserializing, :max_frame_size_exceeded}` server side) instead of being truncated; a wrong token is refused at the upgrade with HTTP 403 and no channel ever opens; a fresh client joins after the endpoint restarts. The client is **222 non-blank non-comment lines** (budget ~300) with ping/pong and close handling. `mint_web_socket` 1.0.6 adds no transitive dependency beyond `mint`.
* **Finding: TCP_NODELAY.** Mint's default leaves Nagle on. With it, the median time-to-first-byte of a new bridged connection was **46 ms** on loopback; with `transport_opts: [nodelay: true]` it is **≈5 ms** (delayed-ACK interaction on request/response traffic). Bandit's side already sets it. **Design change:** §4.1 requires `nodelay: true`.
* **Not covered.** Fragmented-frame reassembly and permessage-deflate (Bandit does not fragment; Phoenix leaves compression off), HTTP/2 WebSockets, and the agent's reconnect/backoff loop (the agent's own code).

#### U3 bridge mux latency at 10 runs — GO-WITH-FALLBACK

* **Method** (`bridge_mux_test.exs`, `run_netem.sh`, `run_matrix*.sh`). 10 concurrent runs each replay the same 20 s SSE trace (8,290 events) through `client → per-run unix listener on the node → one WebSocket (real TCP over a netem'd loopback, MTU 1500, optional `tbf` rate cap) → channel process → per-run unix listener on the primary → fake upstream`, versus directly `client → primary listener` as the control; latency is write time to client-parse time on one BEAM clock. The mux has the design's credits (256 KiB/stream, 16 KiB frames) and one node cap. The real egress proxy is not in the loop (it is unchanged by design).
* **Added latency per SSE event** (mux minus direct), 10 runs:

| Link (RTT / rate / loss) | added p50 | added p99 | threshold 250 ms |
|---|---|---|---|
| loopback | 0.5 ms | 3.1 ms | ok |
| 2 ms / – / 0 | 1.4 ms | 3.7 ms | ok |
| 20 ms / 100 Mbit / 0 | 10.4 ms | 12.3 ms | ok |
| 80 ms / 20 Mbit / 0 | 40.4 ms | 42.0 ms | ok |
| 150 ms / 20 Mbit / 0 | 75.3 ms | 96.4 ms | ok |
| 150 ms / 20 Mbit / 0.1 % | 75.4 ms | 217.5 ms | ok (barely) |
| 80 ms / 20 Mbit / 0.5 % | 52.7 ms | 207.8 ms | ok (barely) |
| 150 ms / 10 Mbit / 0.5 % | 95.5 ms | **727.8 ms** | **fails** |
| 150 ms / 20 Mbit / 0.5 % | 146.7 ms | **1,390.6 ms** (1,137 ms in a repeat) | **fails** |
| 150 ms / 2 Mbit / 0 | 178.2 ms | **380.9 ms** | **fails** (the streams alone load the link by an estimated 60–70 %) |
| 250 ms / 1 Mbit / 1 % | 7.4 s | 17.2 s | saturated: 10 runs need ≈1.1 Mbit/s |

* **Why the lossy rows fail:** one retransmission timeout on the single TCP connection stalls every run on that socket at once (probably because a trickle of small events gives fast retransmit too few duplicate ACKs, so recovery waits for the timer; not separately measured). **Fallback, measured:** shard runs over K sockets by run id (`SPIKE_SOCKETS=K`; hb stays on socket 0): at 150 ms RTT / 0.5 % loss the added p99 falls from **1,137 ms (1 socket) to 230 ms (5) and 225 ms (10)**; at 150 ms / 0.1 % from 222 ms to 184 ms (5) and 114 ms (10); at 80 ms / 0.5 % from 253 ms to 123 ms (5) and 129 ms (10). BEAM CPU rose by 1–3 s per 20 s run for sharding (more sockets, same bytes). The design's earlier fallback, "a second socket for bridge data only", would **not** have helped (the stall is per TCP connection, and the heartbeat's delay is the link queue, see U4).
* **New-connection cost** (20 sequential connections × 10 runs, time to first byte of a 1 KiB reply): median ≈ 1.06 × RTT (loopback 4.3 ms, 20 ms RTT 21.7 ms, 80 ms RTT 84.7 ms), p99 up to ≈ 2 × RTT (167 ms added at 80 ms RTT, 451 ms at 150 ms RTT with loss). A new TLS connection to the model API through the tunnel therefore adds its CONNECT and handshake round trips at node↔primary RTT each (≈ 2–3 RTT: ≈ 160–240 ms at 80 ms, ≈ 300–450 ms at 150 ms), once per connection; the CLI keeps connections alive.
* **CPU.** BEAM CPU (both ends and the load generator in one VM) over the 20 s, 10-run replay: 2.7–4.9 s direct versus 5.1–9.8 s through the mux (15 s on the saturated 2 Mbit/s link), i.e. +2.4 to +6.4 s (≈ 0.1–0.3 of a core; 0.6 on the saturated link), of which the primary's share is a fraction. Acceptable.
* **Envelope the design should state:** node↔primary RTT ≤ 150 ms with ≤ 0.1 % loss, or ≤ 80 ms with ≤ 0.5 %, and ≥ 10 Mbit/s uplink for 10 concurrent runs. Outside it the agent should use more sockets or the operator should expect streaming hitches (never failures: nothing is lost, §10.2).
* **Design changes.** §4.2 and §8 now carry these numbers; the lossy-link fallback is sharding by run id with `caps.bridge_sockets` in `hello` (no protocol change; **not built in v1**). `hb` RTT (already measured) is the cheap link-quality signal for a readiness hint. Open item for child 10: the prototype's sender drains the stream that just got credit first; a fair (round-robin) scheduler is required, see U4.

#### U4 heartbeat under a 5 MiB push — GO

* **Method.** Same rig. A heartbeat (`hb` → `hb_ack`) every 200 ms (accelerated from 10 s to get samples) shares the socket with (a) a 5 MiB push node→primary, (b) a 5 MiB pull primary→node (the `hb_ack` direction), (c) the worst case: both at once plus 8 SSE runs. Reported: heartbeat round trip (RTT) during the transfer, and the largest gap between consecutive acks, which is what the 60/90 s fence and lost timers actually see.

| Link | push up: hb RTT max | pull down: hb RTT max | worst case: hb RTT p99 / max, max ack gap |
|---|---|---|---|
| loopback | 8 ms | 6 ms | 10 / 12 ms, 217 ms |
| 20 ms / 100 Mbit | 41 ms | 100 ms | 44 / 47 ms, 209 ms |
| 80 ms / 20 Mbit | 240 ms | 405 ms | 350 / 356 ms, 476 ms |
| 150 ms / 10 Mbit / 0.5 % | 616 ms | 1.9 s | 4.4 / 4.6 s, 2.1 s |
| 150 ms / 2 Mbit | 2.0 s | 2.2 s | 6.8 / **7.0 s**, 3.2 s (1 MiB cap) |
| 250 ms / 1 Mbit / 1 % | 3.7 s | 4.1 s | 14.9 / 15.1 s, 9.9 s (saturated) |

* **Reading it.** The 5 MiB push alone never moves the heartbeat past 2.3 s at ≥ 2 Mbit/s (4.1 s at 1 Mbit/s), so "jitter < 5 s during a 5 MB push" **holds**; and the largest ack gap anywhere short of a saturated 1 Mbit/s link is 4.1 s against 30 s of fence slack. The one violation on a link that can carry the load is the combined worst case at 2 Mbit/s with the design's **1 MiB** per-node in-flight cap (heartbeat RTT up to 7.1 s): the heartbeat queues behind everything in flight, and the in-flight cap is what bounds that queue (1 MiB at 2 Mbit/s is 4.2 s of wire time).
* **Cap sweep** (150 ms RTT, 2 Mbit/s, worst case, both ends capped): 1 MiB → hb RTT max 7.1 s (ack gap 4.1 s); **256 KiB → 3.2 s (1.9 s)**; 64 KiB → 1.5 s (a rerun: the batch run of this case crashed, see below) but throughput at 10 Mbit/s falls to 0.4 MiB/s (window ÷ RTT), where 256 KiB still moves 0.8 MiB/s (the 10 Mbit/s link's own limit). At 10 Mbit/s the cap makes no measurable difference above 256 KiB.
* **Two sockets would not help.** The delay is the bottleneck queue, shared by both sockets; only fewer bytes in flight shortens it. A 64 KiB-capped run once lost one SSE client to a 60 s receive timeout (a `CaseClauseError` in the test process; the load client's `recv` has no clause for `{:error, :timeout}`, which is the suspect, but the value was not captured, and starvation by the first-served bulk stream is the likely reason it timed out), hence the fairness requirement.
* **Design changes.** §4.2: node in-flight cap **256 KiB** (was 1 MiB), fair scheduling across streams, the single-socket decision stands and "second socket for bridge data" is dropped as the fallback.

#### U5 the release boots as an agent — GO

* **Method** (`u5_agent_boot.sh`): copy of the published v0.2.18 release, private net namespace, distribution off, scratch `HOME`, **no** `SECRET_KEY_BASE`, `DATABASE_PATH` or `ARBITER_CLOAK_KEY`. Control: unpatched, `ARB_ROLE=agent` → dies in `runtime.exs:29` (`SECRET_KEY_BASE is missing`). Patched copy: `runtime.exs` gated on `ARB_ROLE=agent` (sets `config :arbiter, role: :agent`, skips the rest) and `Arbiter.Application.start/2` + `ArbiterWeb.Application.start/2` recompiled from the `v0.2.18` source with a role check at the top (compiled with the release's own Elixir via `bin/arbiter eval`), plus a stub `Arbiter.NodeAgent.Supervisor`.
* **Evidence.** Ready in **0.5 s warm / 1.4 s cold** from `bin/arbiter start`; VmRSS **≈ 100 MB** (the live primary's is ≈ 930 MB); `Arbiter.Repo`, `Arbiter.Vault` and `ArbiterWeb.Endpoint` are not running; `secret_key_base` is unset; the reused modules (`Container`, `PrivateClone`, `DepsCache`, `TestServices`, `PodmanReadiness`, `Image`, `Worker.Egress.Listener`, `Worker.Egress.Forward`) load and `Container.name_for/1` runs. The patched copy **without** `ARB_ROLE` still dies on `SECRET_KEY_BASE`: the primary's guard is untouched, the gate is opt-in and fail-closed.
* **Findings.** (1) Both Application modules need the gate, or the second would start the Endpoint and bind the port. (2) ~68 OTP dependency applications still start (they are in the boot script): that is the 100 MB, and it is fine. (3) Releases boot in `embedded` mode: a module not listed in the `.app` file cannot be loaded at runtime, so the agent's modules must be compiled into the release (the spike had to use `RELEASE_MODE=interactive` for its stub). (4) The fallback in the table (a second release definition) is not needed. Names: `Egress.Listener` is `Arbiter.Worker.Egress.Listener` (§19).
* **Design change.** §3 records the measurements and the two-module gate. **Not covered:** a published-asset boot of the 54 MB tarball (U16) and the `ReleaseEnvGuardTest @inventory` interplay (child 5).

#### U7 git bundle round trip — GO

* **Evidence** (`bundle_roundtrip_test.exs`, plain `git` 2.55, 5 tests pass). A shadow with an executable file, a relative, an absolute (`/etc/passwd`) and a dangling symlink, a unicode+space name, a deleted file, a renamed-and-edited file, a chmod +x and a chmod -x, and a typed-in-but-uncommitted edit plus an untracked executable: snapshot with a temporary index → thin bundle (`^base`) → `bundle verify` → `list-heads` allowlist → fetch into a quarantine bare repo with `fetch.fsckObjects`/`transfer.fsckObjects` and `core.hooksPath=/dev/null` → `read-tree -u --reset` + `reset --mixed`: every mode bit, symlink target and deletion matches, the rename is detected (`R096`), and `git status` reads the edit and the untracked file as uncommitted. `git fsck --strict` on the quarantine is clean.
* **fsck applies to bundle fetch.** A bundle whose tree contains `.git/config` passes `git bundle verify`, is **accepted** with `fetch.fsckObjects=false`, and is **rejected** with it on (`error: object …: hasDotgit: contains '.git'`, `fatal: fsck error in packed object`, `error: index-pack died`) with no ref created.
* **Thin bundles** fail to `verify`/fetch without their prerequisites (`Repository lacks these prerequisite commits`), which is how the primary detects "the node's `have` is stale" and falls back to a full bundle; with the base present the same bundle fetches.
* **Ref allowlist.** `bundle list-heads` shows every ref the bundle carries (use it to reject). A refspec-limited fetch **still imports `refs/tags/*`** via tag auto-following unless `--no-tags` is passed.
* **Submodule/LFS veto** is detectable in the quarantine without a checkout: `ls-tree -r` shows mode `160000`, `.gitattributes` shows `filter=lfs`, and the pointer blob starts `version https://git-lfs.github.com/spec/v1`.
* **Known gap:** empty directories are not carried.
* **Design change.** §9 step 2: `--no-tags`, `list-heads` check, and "fsck, not verify, is the gate". **Not covered:** a repo with a real submodule checkout or real LFS objects (only the detection signals), and bundle size/time on a large monorepo (the design's measured 15.6 MB / 29.6 MB figures stand).

#### U8 rootless memory cap — GO (this host)

* **Evidence** (`podman_limits_test.exs`, `u8_oom_probe.sh`). `podman run --memory=64m --memory-swap=64m --cpus=1` with a 300 MB allocation exits **137**, `.State.OOMKilled=true`, and `HostConfig.Memory/MemorySwap/NanoCpus` read back as 67,108,864 / 67,108,864 / 1,000,000,000 **because `--rm` is absent**; with `--rm` the container is gone and nothing can be inspected; an in-cap run exits 0 with `OOMKilled=false`; inside the container `memory.max` is 67,108,864 and `memory.swap.max` is 0. `--cpus` works with `cpu` delegated. A limit whose controller is not delegated **fails the run**: `--cpuset-cpus=0` → ``crun: controller `cpuset` is not available`` (exit 126). One of 12 runs of the OOM test failed once (output not captured) and did not reproduce in the 11 runs after it.
* **Design change.** §7.4 and §5.5: limits only for delegated controllers; the functional probe `podman run --rm --memory=64m … true` is the authority for `degraded: :uncapped`.
* **Needs operator** (other distros; and the negative case, which this host cannot produce because it delegates `memory`): on an ubi8, ubi9, Debian 12 and Ubuntu 24.04 host, run `apps/arbiter/test/spike/remote_workers/u8_oom_probe.sh <image-with-perl>` (all lines `PASS`), and on a host where `memory` is **not** delegated (for example RHEL 8's defaults) confirm `podman run --rm --memory=64m <image> true` fails with a `controller … not available` error rather than silently ignoring the limit. If it silently ignores it, the probe must also read the container's `memory.max`.

#### U9 linger without sudo — GO (this host)

* **Evidence** (`u9_linger_toggle.sh`, restores state by trap). `loginctl --no-ask-password disable-linger "$USER"` then `enable-linger` both returned 0 and flipped `Linger` no → yes, from a non-tty process with no `XDG_SESSION_ID`, with no sudo and no prompt, although the polkit action `org.freedesktop.login1.set-user-linger` defaults to `auth_admin_keep` (logind evidently allows the caller's own user). Linger was `yes` before and after.
* **Not shown here, needs operator:** (a) the same call on RHEL 8 (systemd 239) / ubi8-based, ubi9, Debian 12 and Ubuntu 24.04 hosts, run as an unprivileged user over ssh: `bash apps/arbiter/test/spike/remote_workers/u9_linger_toggle.sh` (needs `Linger=yes` first, or it only enables); (b) that linger is *enough* for user units and rootless containers to outlive the session: `systemd-run --user --unit=rw2-linger-probe sleep 3600; podman run -d --name rw2-linger docker.io/library/debian:12 sleep 3600`, log out of every session for 2 minutes, log back in, and expect `systemctl --user is-active rw2-linger-probe` = `active` and `podman ps` listing `rw2-linger`.
* **Design change.** §5.5: use `--no-ask-password` (a denied call must fail, never wait for an agent).

#### U10 delegation detection — GO (this host and fixtures)

* **Evidence** (`host_prereqs_test.exs`, `prereq_checks.sh`, 11 tests). On this host the user manager's cgroup (`user.slice/user-1000.slice/user@1000.service`) lists and enables `cpu io memory pids`; `cpuset` is absent. The probe requires the controller in `cgroup.controllers` **and** `cgroup.subtree_control` of that cgroup and agrees with `podman info` (`[cpu io memory pids]`) and with the functional probe. Fixtures: delegated memory passes; listed-but-not-enabled fails; a pids-only delegation (older systemd default) fails `memory` and `cpu`; a missing user manager cgroup (a container, no `systemctl --user`) fails closed; cgroup v1 (no unified `cgroup.controllers`) is refused; a controller whose name merely contains `memory` does not match. The first draft of the design read `user-<uid>.slice`; a worker's own cgroup here is `…/user@1000.service/app.slice/arb-run-….scope`, and a login session would be a `session-N.scope` under `user-1000.slice`, which shows why a `/proc/self/cgroup` read is not the right test.
* **Design change.** §5.5: the exact paths above, podman cross-check, functional probe. **Needs operator:** `bash apps/arbiter/test/spike/remote_workers/prereq_checks.sh all` on each of ubi8, ubi9, Debian 12 and Ubuntu 24.04 hosts, to confirm the same `user@<uid>.service` layout (ubi8 hosts commonly run cgroup v1, which the script refuses by design).

#### U13 secrets never reach disk — GO-WITH-FALLBACK (the design as written is NO-GO)

* **Evidence** (`podman_limits_test.exs`, `u13_secret_scan.sh`; a random marker, scanned under `~/.local/share/containers`, `$XDG_RUNTIME_DIR/containers`, `…/libpod`, `~/.config/containers`). With `podman run -e SPIKE_TOKEN` and the value in the client's environment (the design's `inherit_env` path) the marker is found in **`~/.local/share/containers/storage/overlay-containers/<id>/userdata/config.json`** and in **`~/.local/share/containers/storage/db.sql`** while the container exists; after `podman rm` neither file holds it. `$XDG_RUNTIME_DIR` is tmpfs but those paths are on the **persistent graph root** (btrfs here), so the §11 claim ("the OCI spec lives under `$XDG_RUNTIME_DIR`") was wrong. `podman inspect` shows it too (`Config.Env`; checked).
* **Fallback, verified.** The value is written to a 0600 file under `$XDG_RUNTIME_DIR` (tmpfs), bind-mounted read-only (`:ro,Z`), and the command is `sh -c '. /run/arbiter/secrets.env; exec …'`: the process has `SPIKE_TOKEN` in its environment, and the marker appears **nowhere** podman writes, nor in `podman inspect`, while running or after `podman rm`. (Host-side unreadable subuid volume trees were not scannable; secrets never go through volumes.) Not checked: filesystem-level remnants of the removed `db.sql` pages on btrfs (the file is clean, the blocks are not inspectable), swap, and journald/agent logs (the spike's agent does not exist yet; child 9 must not log run specs).
* **Also true locally today:** podman workers on the primary pass env with `-e NAME` and leave the same copies in `~/.local/share/containers`; out of scope for RW2, worth a follow-up ticket.
* **Design change.** §7.1, §11, §4.2 (`assign` row), §2, §18 child 9: secrets travel as a separate map and are delivered by tmpfs file mount + command wrapper, never as container env; the reaper must also remove `$XDG_RUNTIME_DIR/arbiter-node/<run>/` for dead runs.

#### U19 the Claude CLI rides through a stalled proxy socket — GO

* **Method** (`u19/`). The real Claude CLI 2.1.291 in a loopback-only namespace, fake API key, `HTTPS_PROXY` pointing at a Python relay that stands in for the node listener + mux, and a local TLS "api.anthropic.com" (`NODE_EXTRA_CA_CERTS`): the same topology as the jail (`CONNECT`, then TLS). Relay faults, each starting when the CLI starts: `refuse` (nothing listening), `reset` (accept then close: what `socat` does when its unix peer is dead), `stall` (accept and hold silent, then forward), `stall_then_drop`, and `cut` (kill established connections 5 s in, mid-response). The success criterion is `is_error=false` with the fake answer.
* **Evidence** (direct `ANTHROPIC_BASE_URL` run / CONNECT-proxy run): refuse 30, 60, 90 s ✓ (34, 74, 113 s / 36, –, 90 s); refuse 180 s ✓ (180.3 s), refuse 300 s ✗ (gives up at 191 s, `Connection refused`); reset 30, 60, 90 s ✓ (36, 75, 105 s / 36, –, 126 s); reset 180 s ✗ (gives up at 177 s, `API Error: Connection dropped (ECONNRESET)`); stall 30, 60, 120 s ✓ direct (30.3, 60.3, 120.3 s) and 30, 60, 90 s ✓ through the CONNECT relay (30.4, 60.2, 90.2 s), i.e. it resumes **0.2–0.4 s** after the held connection is released; stall-then-drop 30, 60 s ✓; `cut` mid-response ✓ in 14.7 s with **two POSTs** at the API (the CLI re-sent the whole request; the partial answer was discarded).
* **Reading it.** The default `fence_after` (60 s) is well inside the CLI's retry budget (≈ 177–190 s for refuse/reset, > 120 s for a held connection), so the blip claim in §10.2 stands. After a refuse/reset the CLI resumes only on its own backoff, up to ~36 s after the channel returns; a held connection resumes at once.
* **Design change.** §10.2: listeners **hold** new connections while the channel is down (up to the fence) and reset them at the fence; **`nodes.fence_after_s` is bounded to 90 s** (the earlier 30–300 s range would let a long fence outlast the CLI's patience); a mid-response drop costs a re-billed request, so a long channel instability shows up as spend. **Not covered:** other CLIs (Codex/Gemini are local-only), the exact CLI retry settings (they may change between releases: the scenario script is the regression check), and a stall longer than 120 s.

#### What RW2 did not settle

U6 (DB-free reuse beyond "the modules load"), U11, U12, U14–U18 and U20 (only the header observation above) are untouched; the measurements are one laptop plus netem, not a fleet; the SSE trace is synthesised; U1's cross-device leg, U8/U9/U10 on other distros and the "linger survives logout" check are **needs operator**, with the exact commands above.

## 18. Implementation breakdown (the coordinator files the children)

The whole is D4-class and is split; **no child is above D3**. The spike gates children 5–13; children 3 and 8a are useful under any spike outcome and may start in parallel with it.

| # | Title | Diff. | depends_on | Notes |
|---|---|---|---|---|
| 1 | Commit this design as `docs/design/remote-workers.md` | D1 | none | status "proposed"; reviewed alongside the first code; update the §17 table as spikes land; one pointer from `docs/remote-access.md` |
| 2 | **Spike: go/no-go** for transport, bridge mux, bundle sync, agent role boot, memory cap, prereq checks (**done: bd-6tx1xv, verdicts in §17.1**) | D3 | 1 | covers U1–U5, U7–U10, U13, U19; real endpoint under Bandit in ExUnit (WebSockets included) plus the operator's real `tailscale serve` if available; podman recipes for ubi8/debian; **explicit GO / NO-GO / GO-WITH-FALLBACK per criterion** (U3 and U4 thresholds in §8/§4.2); amends §17 |
| 3 | Nodes domain and the new auth tier | D3 | 1 | `Node`, `JoinToken`, `NodeEvent` Ash resources + migration (version after `20261005140000`), `Nodes.Credentials`, `Nodes.RateLimit`, `NodeAuth` plug, `ApiPolicy :operator`, `Actor :node`, `nodes.*` settings, cross-tier guard tests |
| 4 | Join flow, server side | D3 | 3 | `/nodes/join` script template (shellcheck + no-`sudo` test), `/nodes/enroll`, `/nodes/ping`, `/nodes/agent/:v.tar.gz` (deploy retains the tarball; allowlist pack for `--local`), `/nodes/files/:sha`; `arb node add\|list\|show\|set\|events` |
| 5 | Agent role and client | D3 | 2, 3 | role gate in both Application modules and `runtime.exs` (RW2: both, or the Endpoint binds the port); `Arbiter.NodeAgent.Supervisor`; WS V2 client with backoff (RW2: `nodelay: true`; the spike client is the starting point); `hello`/`hb`; readiness report; self-upgrade; `arbiter-node` wrapper and unit; `ReleaseEnvGuardTest @inventory` entries |
| 6 | Primary node session | D3 | 3 | `NodeSocket`, `NodeChannel`, `Nodes.Registry`/`Session`; heartbeat → suspect → fence/lost; `hello_ok` verdicts; drain; skew states; `disconnect` on revoke; `NodeEvent` writes; `Phoenix.ChannelTest` coverage |
| 7 | Operator surface | D3 | 6 | `NodesLive` (list, Add node, detail), doctor section + `GET /api/nodes`, `arb node drain\|revoke\|remove\|upgrade`, run-page node field |
| 8a | `Container.argv/2` additive options | D2 | 1 | mount mapping, `--memory/--memory-swap/--cpus`, labels, optional no `--rm`; pure; usable to cap local containers later |
| 8 | Placement and capacity | D3 | 6 | `Nodes.Placement`, `ensure_node_capacity/2` after `ensure_account_capacity/2`, `worker_runs.node_id` migration, effective capacity (§13), modes, `{:no_node_capacity, _}`; returns only local until child 9 |
| 9 | Remote run | D3 | 5, 6, 8, 8a | `Worker.Executor` + `Executor.Node`; run spec; remote handle in `Worker` (3 clauses, `terminate_session_port/2`, `session_live?/1`); agent run supervisor (argv from spec, build-from-plan images, CLI files, node-local `DepsCache`, test services, stdout ring/ack/replay, exit/OOM); secrets via the tmpfs file mount + command wrapper, never `-e` (RW2: U13); limits only for delegated controllers (RW2: U8); spawn-site guard tests; behind `worker.placement`, default off |
| 10 | Bridge mux | D3 | 9 | `Nodes.Bridge`, agent listeners (hold while the channel is down, reset at the fence; RW2: U19), credits with a **256 KiB** node cap and fair scheduling (RW2: U4); end-to-end test that `BridgeIdentity`, policy decisions and `egress_events` are unchanged |
| 11 | Checkout sync | D3 | 9 | seed bundle, shadow clone, snapshot, upload, quarantine ingest (`fetch.fsckObjects` + `--no-tags` + `list-heads` allowlist; RW2: U7), **primary-side path filter**, checkpoint, sanitising transcript extractor, `seed: false` thin home clone |
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
* **Name check (RW2):** the `Egress.*` modules named above live under `Arbiter.Worker.Egress.*` (for example `Arbiter.Worker.Egress.Listener`, `Arbiter.Worker.Egress.Forward`); an `Arbiter.Egress.Listener` does not exist. Read the shorthand in this document accordingly.
* **Measured on this host:** release tarball 54 153 326 bytes / 160 MB unpacked (`v0.2.17-published`); toolchain image 843 MB, base 464 MB (`podman images`); repo pack 29.6 MB, bundle of history since 2026-09-01 15.6 MB (`git bundle create -`).

**New in this design (do not exist at `9b5fb0733`):** `Arbiter.Nodes` and its modules (`Node`, `JoinToken`, `NodeEvent`, `Registry`, `Session`, `Placement`, `Bridge`, `Checkout`, `Recovery`, `RateLimit`, `Credentials`); `Arbiter.NodeAgent` and its modules; `Arbiter.Worker.Executor` and `Executor.Node`; `ArbiterWeb.NodeSocket`/`NodeChannel`/`NodeController`/`NodesLive`, `Plugs.NodeAuth`; `ApiPolicy` policy `:operator`; `Actor` kind `:node`; routes `/nodes/*`, `/node/socket`, `/api/nodes`; settings `nodes.public_url`, `nodes.allow_skew`, `nodes.allow_public_endpoint`, `nodes.fence_after_s` and friends; `worker_runs.node_id`; the install id; `worker.placement` / node label keys; `{:no_node_capacity, _}`; `:node_lost`; `arb node …` and `arbiter-node`; `ARB_ROLE`, `ARB_JOIN_TOKEN`, `ARB_JOIN_TOKEN_FILE`, `ARB_JOIN_CHECK_ONLY`, `ARB_NODE_MAX_WORKERS`; token prefixes `arbj_`/`arbn_`/`arbr_`; the `mint_web_socket` dependency; `Container.argv/2` options (mount mapping, memory/cpus, labels, no `--rm`) and `seed: false` on `Worktree.create/4`.
