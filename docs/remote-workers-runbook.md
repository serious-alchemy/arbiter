# Remote workers runbook

How to add a second machine to an Arbiter install so it runs workers, and how to
operate and debug it. The design is [`design/remote-workers.md`](design/remote-workers.md)
(section numbers below refer to it); this page is the procedure.

**What a node is.** The same Arbiter release the primary runs, started with
`ARB_ROLE=agent` as a *user* systemd unit by a join script. It holds one secret (a
node credential), no database, and no forge access. It dials **out** to the primary
over one WebSocket, builds hardened rootless `podman` containers from run specs the
primary sends, and tunnels each container's egress proxy, MCP and `arb` sockets back
over that WebSocket. Checkouts travel as git bundles; the primary ingests them
through a quarantine repo. Only the podman-backed Claude task worker runs remotely.

**What stays off until you turn it on.** Enrolling a node places nothing on it. A
workspace's `worker.placement` defaults to `local_only`; no run goes to a node until
you change that (see [Turn placement on](#turn-placement-on)).

## 1. The network: tailnet, `serve` and ACL tags

The expected path is a tailnet. The primary keeps its loopback bind (`127.0.0.1:4848`);
nothing inbound is opened on either machine.

1. **Both machines on the same tailnet** (`tailscale up`; MagicDNS resolves
   `<primary>.<tailnet>.ts.net`).
2. **The primary publishes itself with `tailscale serve`**, which terminates TLS with a
   publicly trusted certificate, so the node needs only its system CA store:

   ```sh
   tailscale serve --bg --https=443 http://127.0.0.1:4848
   ```

   To expose only the node endpoints instead of the whole app (§4.3, verified in §17.1;
   note each mapping carries its path in the target):

   ```sh
   tailscale serve --bg --https=443 --set-path /nodes      http://127.0.0.1:4848/nodes
   tailscale serve --bg --https=443 --set-path /node/socket http://127.0.0.1:4848/node/socket
   ```

   Do **not** use `tailscale funnel` or any public tunnel: public exposure is refused by
   default (doctor warns on a non-private `nodes.public_url`).
3. **Tell Arbiter its public URL** (the join script and the nodes' config embed it):

   ```sh
   arb settings set nodes.public_url https://<primary>.<tailnet>.ts.net
   ```

4. **ACL tags (recommended).** Tag the primary `tag:arbiter-primary` and each node
   `tag:arbiter-node`, and let nodes reach the primary on 443 and nothing else:

   ```jsonc
   // tailnet policy file
   "tagOwners": {
     "tag:arbiter-primary": ["autogroup:admin"],
     "tag:arbiter-node":    ["autogroup:admin"]
   },
   "acls": [
     // your existing rules, plus:
     {"action": "accept", "src": ["tag:arbiter-node"], "dst": ["tag:arbiter-primary:443"]}
   ]
   ```

   A node needs outbound access to image registries and distro mirrors, and nothing
   else: no forge access (pushes go through the primary's egress proxy). Nothing needs
   to reach *into* a node.
5. **Check it from the node** before joining: `curl https://<primary>.<tailnet>.ts.net/nodes/ping`
   must print `pong`. From the primary, `arb doctor` has a `nodes.public_url reachable`
   line doing the same probe.

Other private overlays (Headscale, a WireGuard mesh behind a TLS reverse proxy) work if
the node sees `https` with a verified chain; plain `http` is accepted only for loopback
(for example an `ssh -L 4848:127.0.0.1:4848 primary` tunnel).

## 2. Prerequisites on the node

The join script checks all of these **before it reads or spends a token**, prints a
`[ ok ]` / `[FAIL]` line for each with a remedy for the failures, and never runs
`sudo` itself. Run only the checks, changing nothing:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://<primary>.<tailnet>.ts.net/nodes/join \
  | ARB_JOIN_CHECK_ONLY=1 bash
```

| Requirement | Why |
|---|---|
| Linux, x86_64 (the only published release arch), glibc ≥ 2.28 | the release tarball is built on ubi8 |
| An ordinary user (the script refuses root) with a login session or `ssh` | rootless podman, `systemctl --user` |
| `curl tar sha256sum git systemctl loginctl podman`, podman ≥ 4, rootless | |
| `/etc/subuid` and `/etc/subgid` grant the user ≥ 65 536 ids | rootless user namespaces |
| cgroup v2 with the **`memory` controller delegated to the user** | `--memory`/`--memory-swap` caps; without it the agent refuses any run whose spec asks for a memory cap (`memory_not_delegated`) |
| linger enabled for the user | the unit and the containers must outlive the login session |
| ≥ 10 GB free under `$HOME`; the primary answering `/nodes/ping` | images, shadow clones |

### Per distro

| | Fedora / RHEL 9 / Rocky / Alma | RHEL 8 / ubi8 | Debian 12 / Ubuntu 24.04 |
|---|---|---|---|
| packages | `sudo dnf install podman git curl tar shadow-utils` | same (podman 4 from AppStream) | `sudo apt install podman git curl uidmap` |
| cgroup v2 | default | default on 8.2+; else boot with `systemd.unified_cgroup_hierarchy=1` | default |
| memory delegated to users | **usually yes**; `cpu`/`io` may be missing | needs the drop-in below | **needs the drop-in below** |
| subuid/subgid | created with the user | created with the user | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER` if absent |

(The delegation and linger checks were exercised on one host and against fixtures in the
RW2 spike, §17.1 U8–U10; the other distros are unverified by an operator, so treat the
package names and defaults above as a starting point and confirm with the check-only run.)

### cgroup v2 memory delegation (`Delegate=`)

systemd hands a user manager only the controllers listed in `Delegate=` for
`user@.service`. When `memory` is missing the script fails with *"the memory cgroup
controller is not delegated to your user"*. Fix it once, as root:

```sh
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
  | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
```

Then log the node's user out and in again (or `sudo systemctl restart user@$(id -u).service`,
which ends that user's sessions). Verify:

```sh
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control
# both lines must contain "memory"
podman run --rm --memory=64m --memory-swap=64m <any local image> true
```

The script requires `memory` in **both** files (a login session scope is not the
delegation point) and runs the `podman run --memory=64m` probe when an image is already
present. The agent re-reads the delegated controllers itself and refuses a run that
needs a memory cap it cannot enforce, rather than running it uncapped.

### Linger

`loginctl enable-linger $USER` lets user units run with nobody logged in. The script does
this for you (the one user-level fix it makes; `ARB_JOIN_CHECK_ONLY=1` only reports it).
If polkit refuses, run `sudo loginctl enable-linger <user>` yourself. Without linger the
agent dies at logout and every run on the node is lost with it.

## 3. Join a node

On the **primary**, mint a single-use token (default TTL 15 min, `--ttl` up to 24 h).
This needs the operator's own `arb` token, not a coordinator session's:

```sh
arb node add --name build-1 --label gpu=no --max-workers 2
```

It prints the join command (which carries no secret) and, on a terminal only, the token
(`--token-file PATH` writes it mode 0600 instead). The dashboard's **Add node** does the
same.

On the **node**, as the ordinary user that will own it:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://<primary>.<tailnet>.ts.net/nodes/join | bash
```

Paste the token at the hidden prompt (it is read from `/dev/tty`, never put on argv or in
shell history). For unattended installs use `ARB_JOIN_TOKEN_FILE=/path` (mode 0600) or
`ARB_JOIN_TOKEN`; optional `ARB_NODE_NAME`, `ARB_NODE_LABELS=k=v,k=v`,
`ARB_NODE_MAX_WORKERS`.

The script runs the prerequisite checks, exchanges the token at `POST /nodes/enroll`,
downloads the agent tarball with the new credential and verifies its sha256, unpacks it to
`~/.arbiter-node/releases/<version>/` (atomic `current` symlink), writes
`~/.config/arbiter-node/{agent.env,credential}` and
`~/.config/systemd/user/arbiter-node.service`, and starts the unit. The credential
(`arbn_…`, 0600) is the only secret at rest on the node.

Confirm on the primary:

```sh
arb node list          # state online, health ready, agent version == server version
arb node show build-1
arb node events build-1   # token_minted, enrolled, connected
arb doctor             # the "nodes" section
```

On the node: `~/.arbiter-node/bin/arbiter-node status | logs | leave`.

A real second node has been enrolled this way: `ryan-oryx-pro`, reached over the Vstim
tailnet through `tailscale serve`, agent 0.2.23, health `ready`, `max_workers` 1
(enrolled 2026-10-07, per the coordinator's notes on bd-afcoop; it does not run real
work until placement is turned on).

### Pin and size the node

```sh
arb node set build-1 --max-workers 2            # your override of the node's suggestion
arb node set build-1 --workspace <workspace-id> # only these workspaces run here (repeatable)
arb node set local --max-workers 2              # the primary's own cap; 0 = nodes do the work
```

`arb node list` shows `local + Σ remote caps`, which is the capacity the board plans to; there is
no install-wide cap above it (the old `conductor.max_concurrent` was removed). The primary's own
cap defaults to its hardware suggestion (`min(cpus/2, 0.8 × MemTotal / 4 GiB)`, at least 1) and is
enforced; `arb node set local --max-workers N` overrides it.

### Turn placement on

Nothing runs remotely until a workspace opts in:

```sh
arb config set worker.placement prefer_remote   # a node with headroom, else local
arb config set worker.placement remote_only     # never local; a card with no capacity is held, not failed
arb config set worker.placement local_only      # the default
```

`prefer_remote` is the safe first step. Only a fresh implementer run of a Claude task in
a podman container with a private clone is eligible; follow-ups, reviews, merge-queue
passes, non-Claude providers and bwrap/unsandboxed runs stay local whatever the mode
(the ineligible reasons in `Arbiter.Nodes.Placement`).
Switch it off instantly, install-wide, with `config :arbiter, remote_execution: false`.

### Select the podman sandbox

A run is only eligible for placement when its workspace resolves the podman sandbox
backend. The key lives under `agent.security`, so write the full path:

```sh
arb config set agent.security.sandbox.backend podman
arb config set agent.security.sandbox.review_backend bwrap   # optional; reviews stay local
```

A bare `sandbox.backend` is not a config key: `arb config set` (and REST and MCP) refuse
it and name the full path (pass `--force` only to store a key on purpose). `arb server
doctor` reports "no workspace uses the podman sandbox backend" until the full path is set.

## 4. Drain, revoke, upgrade, remove

| Goal | Command | Effect |
|---|---|---|
| Take a node out of rotation, let runs finish | `arb node drain <name>` | no new placement; stays connected; `undrain` reverses it |
| Cut a node off now | `arb node revoke <name>` | credential hash cleared, socket closed at once, its runs end `interrupted` (*node lost*) and auto-resume elsewhere; the node can never reconnect with that credential |
| Delete a revoked node's row | `arb node remove <name>` | only for a revoked node; history stays in `arb node events` |
| Move a node to the primary's version | `arb node upgrade <name>` | the agent downloads, verifies and swaps `current` when idle, then restarts under systemd |
| Stop the agent from the node side | `arbiter-node leave`, then `arb node revoke <name>` | |

**Upgrade** is normally automatic. After `arb server deploy` the nodes reconnect, are told
the new version and become `outdated`; an `outdated` node takes **no new runs**, so it
drains itself, upgrades when idle and rejoins as `ready`. The new agent confirms on its
first `hello_ok`; if it never confirms within 3 minutes the previous release is restored.
`nodes.allow_skew` (default off) lets mismatched nodes keep working through a bad deploy.
Check `arb node list` after every deploy: agent version must equal the server's.

**Rotate or replace a credential:** revoke, `arb node remove`, and re-run the join with a
new token (a re-run on the same host repairs the install).

## 5. A primary restart

Deploys and crashes restart the primary. What happens to a run on a node (§10.4–10.5):

0. On `systemctl restart` the primary's Workers are shut down by the supervisor. A Worker
   whose run is on a node does **not** cancel it and does **not** write the run row off
   as `interrupted` / "server shutdown" (that is only for local runs): the row stays
   `working` and names its node (`worker_runs.node_id`), which is what `Nodes.Recovery`
   looks runs up by. The node's run id is the row's id.
1. The sockets drop; the agent stays quiet and reconnects with backoff (1 s → 30 s).
2. Under `fence_after` (default 60 s, 30–90) the container is left alone, output is
   replayed from the last acked offset and nothing is lost: that is a *blip*. After a
   restart the primary's `Worker` is gone, so on `hello_ok` the agent is told it does not
   know the run, **quiesces** it (stops the container, bundles the shadow clone and the
   transcripts, retains them under `~/.arbiter-node/runs/<run>/retained/`).
3. At boot the primary's sweep runs `Nodes.Recovery.await/1` before anything else: it
   waits (60 s per node, 90 s in all) for each node to reconnect, pulls the retained
   work through the quarantine into the home clone, and only then does the normal
   reconcile resume the run from it.
4. A node that never comes back has its runs stamped `interrupted` / `node_lost`
   (no resume attempt consumed) and auto-resumed through placement, once. A run
   `Recovery` could not account for at all (it crashed) is left alone by the sweep, row
   and ticket, and taken by the next boot's `Recovery`.
5. A retained run the primary truly does not know (no live row for it) is reported (a
   `retained` node event) and removed by the node's reaper: the primary sends `reap`
   on every `hello` and every 10 minutes, and a run directory outside the live set is
   removed once it is **24 h** old, so at most ~24 h 10 min after the run was last
   touched. Until then it takes disk but no slot.

What good looks like: `arb node events <name>` shows `disconnected` then `connected`; the
run's history shows the resume, and the commits made before the restart are present.

## 6. Verifying an install: the `:node_agent` suite

`apps/arbiter_web/test/node_agent/remote_workers_e2e_test.exs` runs the whole feature with
nothing stubbed: a real `ARB_ROLE=agent` OS process configured by the `agent.env` the real
join script wrote, a Bandit-served endpoint, real rootless podman containers, the real
egress proxy and `arb` bridge, a real git bundle through the quarantine, and a primary
restart. It covers join → hello → placement → run → bridged egress → bundle ingest →
restart → recovery, plus drain and revoke.

It is tagged `:node_agent` and **excluded from the default `mix test` and CI** (it needs a
rootless podman, a local image with `sh` and `socat`, and boots a second BEAM). Run it
deliberately, memory-capped, from `apps/arbiter_web`:

```sh
systemd-run --user --scope -p MemoryMax=3G \
  mix test --include node_agent test/node_agent/remote_workers_e2e_test.exs
```

`ARB_E2E_IMAGE` picks the image (default: the first local image with `sh` and `socat`).
Use a short `TMPDIR` (unix socket paths cap near 100 bytes). It stops only the agent pid
it started and removes only containers it named.

## 7. Troubleshooting

Start with `arb node list`, `arb node events <name>`, `arb doctor`, and on the node
`~/.arbiter-node/bin/arbiter-node logs` (`journalctl --user -u arbiter-node.service`).

| Symptom | Cause / fix |
|---|---|
| Join script: `[FAIL] the memory cgroup controller is not delegated` | add the `Delegate=` drop-in (§2), re-login |
| `[FAIL] linger is off … could not be enabled` | `sudo loginctl enable-linger <user>` |
| `[FAIL] XDG_RUNTIME_DIR is not set` / `systemctl --user cannot reach your user manager` | you are in a `su`/`sudo` shell; log in with ssh or a console |
| `[FAIL] /etc/subuid grants 0 ids` | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 <user>` |
| `[FAIL] no answer from …/nodes/ping` | tailnet down, ACL blocks `tag:arbiter-node → tag:arbiter-primary:443`, `tailscale serve` not running, or `nodes.public_url` wrong |
| enrol: `401` | token unknown, expired (15 min) or already used; mint a new one |
| enrol: `409` | name taken; pick another `ARB_NODE_NAME` or `arb node remove` the old (revoked) one |
| enrol: `429` | rate limited (10/min globally, 5 failures/10 min per source); wait |
| enrol: `503` | the primary has no agent tarball to serve; run `arb server deploy` |
| Unit is up but `arb node list` shows it `offline` | `agent.env` URL wrong, credential revoked, or clock/TLS trouble; read the agent log |
| Node `outdated` / `incompatible` / `ahead` | agent and primary versions differ; it upgrades itself when idle, or `arb node upgrade <name>`; `incompatible` means re-run the join script |
| Node `ready` but nothing lands on it | `worker.placement` is still `local_only`; the node is pinned to other workspaces (`arb node set … --workspace`); drained; cap 0; `conductor.max_concurrent` reached; or the run is ineligible. The reason is in the dispatch log (`worker.placement is local_only`, `no node has capacity …`) |
| Card held: *no node has capacity* | `remote_only` with no node able to take it; add capacity, or switch to `prefer_remote` |
| Run ends `interrupted` *node lost: <name>* | no heartbeat for `lost_after` (90 s default); it resumes by itself. Check the node's power, network and `arb node events` for `fenced`/`node_lost` |
| Runs fail on the node with `memory_not_delegated` | the `memory` controller is not delegated to the user, see §2 |
| Run dies about a second in with `MCP config file not found: <primary worktree>/.mcp.json` | fixed in the release after v0.2.24 (bd-8y8ztm): the injected `.mcp.json` and `.claude/skills/` are untracked, so the git bundle never carried them. They now ride in the spec (`worktree` mount `files`), written into the shadow clone; the scope token travels as the secret `ARBITER_MCP_TOKEN`, never in the file on the node |
| Container cannot reach anything | by design it is network-less; egress goes through the bridge. If the bridge is down, `arb node events` shows `disconnected`; policy denials show in the run's egress events |
| After a restart a run did not recover | the node did not reconnect within 60 s, or the home clone was missing; the run is resumed from whatever the home clone holds ("server restarted") or stamped `node_lost` |
| Leftover `arb-…` containers or `~/.arbiter-node/runs/*` | the primary sends the live set on every `hello` and every 10 min; containers outside it are removed, run directories after 24 h. The agent never reaps on its own |
| `arb node add` refuses to print the token | stdout is not a terminal; use `--token-file` |

Escalate with the output of `arb node show <name> --json`, `arb node events <name>`, the
agent log, and the primary log around the same time.

## 8. Real-node acceptance checklist

After a release carrying the remote-workers work is deployed, on a real second node:

1. `arb node upgrade <name>`; `arb node list` shows it online with the server's version.
2. Re-run the check-only join (§2) on the node and record the results.
3. Pin the node to one workspace (`arb node set <name> --workspace <id>`), then turn on
   `worker.placement: prefer_remote` for that workspace.
4. Dispatch one small ticket. Confirm it was placed on the node (`worker_runs.node_id`),
   that `egress_events` exist for the run, that its commits land on the primary, and that
   the PR/review flow completes.
5. During a remote run, `systemctl --user restart arbiter` on the primary; the run is
   recovered, or ends `interrupted` (*node lost*) and resumes. Record which.
