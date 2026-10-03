# Per-worker memory cap and OOM policy

Incident 2026-10-03 (GitHub #265): a worker's child BEAM (a `mix test` in a
worktree) grew to 17.5 GB. The kernel OOM-killer picked it, and because every
worker lived in the server's own cgroup (`arbiter.service`, `OOMPolicy=stop`,
`MemoryMax=infinity`) systemd stopped the **whole service** — every in-flight run
died and the coordinator's MCP connection dropped. It happened twice in ten
minutes.

Two independent fixes ship together. Either alone helps; both close it.

## 1. Each agent spawn runs in its own capped scope

`Arbiter.Worker.MemoryScope` wraps every agent spawn (every provider, every
resume / nudge respawn) in a transient systemd scope:

```
systemd-run --user --scope --unit=arb-run-<task>-<hex> \
  -p MemoryMax=<cap> -p MemorySwapMax=0 -p OOMPolicy=kill \
  env -u XDG_RUNTIME_DIR <agent argv…>
```

The scope is a **sibling** of the service's cgroup, so the cap bounds the agent
and everything it spawns, and an OOM kills exactly that scope — agent and all —
while the server and every other worker carry on. `MemorySwapMax=0` is
deliberate: cgroup v2's `memory.max` counts RAM only, so without it a runaway
tree spills into swap and thrashes the host instead of being killed.

When it happens the run is recorded **failed** with stop category
`memory_cap_exceeded` and a reason of the form

> memory cap exceeded: the worker's process tree hit its per-worker limit
> (MemoryMax=12G, peak 12.0 GiB) and was OOM-killed …

(The agent's own exit status is a bare 137, the same as any SIGKILL. systemd
keeps the answer: the scope goes `failed` with `Result=oom-kill`, which the
Worker reads when the port exits and then `reset-failed`s.)

### Configuring the cap

| Setting | Meaning |
| --- | --- |
| `ARBITER_WORKER_MEMORY_MAX` (e.g. in `~/.arbiter/arbiter.env`) | A size systemd accepts for `MemoryMax=`: `12G`, `512M`, or a percentage of physical RAM (`40%`). |
| `config :arbiter, :worker_memory_max, "12G"` | Same, for dev checkouts. The environment variable wins. |
| *(unset)* | `40%` of physical RAM, per worker. |
| `off` / `0` / `none` / `infinity` | No cap; workers spawn exactly as before. |

An unparseable value is logged and replaced by the default — it never silently
disables the protection. Changes need a server restart.

The cap applies to the **whole process tree** of one agent: `claude` itself
(~1 GB), plus a `mix test` BEAM, plus a dialyzer run, if the agent runs them at
the same time. Raise it if legitimate workloads hit it.

### When the cap cannot be applied

Needs Linux, systemd, cgroup v2, and a user manager that has the **memory
controller delegated** (the case on the Fedora dogfood host; check others with
the probe below, and expect it to be absent inside most containers). On first use the server probes this *with the real properties* —
including reading the new scope's `memory.max` back, because a manager without
the controller accepts `MemoryMax=` and silently ignores it. If the probe fails
the worker is spawned uncapped, one warning is logged
(`MemoryScope: per-worker memory cap unavailable — …`), and the probe is retried
after five minutes. `arb doctor` reports the same state.

## 2. `OOMPolicy=continue` on the service

`arb install service` now writes `OOMPolicy=continue` into the unit's `[Service]`
section. systemd's default, `stop`, stops the whole service when the kernel
OOM-kills *any* process in its cgroup; `continue` leaves the survivors running
(and if the server's own BEAM is the one killed, `Restart=on-failure` still
brings it back). It is the backstop for whatever still lives in the unit's
cgroup — the cap protects against workers, this protects against everything else.

### An already-installed unit is host config

Re-running `arb install service` rewrites the unit and picks the line up. If you
would rather not regenerate it, add a drop-in:

```sh
systemctl --user edit arbiter.service
```

```ini
[Service]
OOMPolicy=continue
```

then `systemctl --user daemon-reload`. (A system-wide install: drop `--user`.)
The change takes effect for the running service on its next restart; verify with

```sh
systemctl --user show arbiter.service -p OOMPolicy
```

## 3. Attributing an OOM to a task

Every spawn's scope unit name is recorded on the run, `worker_runs.cgroup_scopes`
(one entry per spawn, in order), and logged at spawn time:

```
Worker: task=bd-6zuoo6 run=… agent spawned in scope arb-run-bd-6zuoo6-1a2b3c4d.scope (MemoryMax=40%)
```

A kernel OOM line names the victim's cgroup (`task_memcg=…/arb-run-bd-6zuoo6-1a2b3c4d.scope`),
so:

```sh
journalctl -k --since '1 hour ago' | grep -i 'oom'          # → …/arb-run-<task>-<hex>.scope
sqlite3 ~/.arbiter/arbiter.sqlite3 \
  "select task_id, id, stop_category from worker_runs where cgroup_scopes like '%arb-run-<task>-<hex>%'"
```

Runs that predate the column, or ran with the cap off or unavailable, have a
NULL `cgroup_scopes`.

## 4. `arb doctor`

The **worker memory cap** check asks the server which systemd unit it runs in,
that unit's `OOMPolicy`, and whether the cap is in force. It warns when

- the unit has `OOMPolicy=stop` and workers are **not** capped (the incident
  configuration), or
- the unit has `OOMPolicy=stop` even though workers are capped, or
- workers are not capped even though `OOMPolicy=continue` is set.

A server that is not a systemd service (a shell-launched `mix phx.server`) has no
policy to judge and reports ok.

## Reproducing by hand

Without Arbiter, on any host that can run the scope:

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemd-run --user --scope --quiet --unit=arb-demo \
  -p MemoryMax=64M -p MemorySwapMax=0 -p OOMPolicy=kill \
  sh -c 'tail /dev/zero'; echo "exit=$?"            # exit=137
systemctl --user show arb-demo.scope -p Result,MemoryPeak,ActiveState
#   Result=oom-kill  MemoryPeak=67108864  ActiveState=failed
systemctl --user reset-failed arb-demo.scope
```

The end-to-end proof inside Arbiter is the opt-in `:live_systemd` test:

```sh
XDG_RUNTIME_DIR=/run/user/$(id -u) \
  mix test --include live_systemd test/integration/worker_memory_cap_test.exs
```

It starts a second worker beside the runaway one and asserts that only the
runaway is killed, that its run row is `failed` / `memory_cap_exceeded`, and that
the failed scope was cleared.

## Not covered

Spawns that are not agent sessions — `git`, `gh`, the doctor's probes, a
coordinator session's tmux scope (which already has its own
`systemd-run --user --scope`) — stay in the service cgroup, as before. That is
what `OOMPolicy=continue` is for.
