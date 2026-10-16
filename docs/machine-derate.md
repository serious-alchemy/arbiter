# Machine self-derate: thermal and memory pressure (bd-6w7usy)

Every machine that runs workers — the primary and each node — watches its own
CPU temperature and memory pressure and folds that into how many slots it
offers the scheduler. It replaces the ad-hoc shell thermal watches coordinator
sessions used to run per machine (and which died with the session).

A derate **only stops new work**. It never kills, pauses or interrupts a running
worker.

## What is sensed

Linux only, best-effort, sampled every 10 s and smoothed (an exponentially
weighted average, weight 0.4 on the newest sample) so one spike does not flap
capacity. Code: `Arbiter.Machine.Sensors`, `Arbiter.Machine.Monitor`.

| reading | source |
|---|---|
| CPU package temperature | `/sys/class/hwmon/hwmon*` chips named `coretemp`, `k10temp` or `zenpower` (`Package id N`, `Tctl`, `Tdie`; an unlabelled CPU chip counts its hottest input); failing that, the hottest `/sys/class/thermal/thermal_zone*/temp` whose `type` looks like a CPU/package sensor (`x86_pkg_temp`, `acpitz`, `cpu-thermal`, …). Implausible values (≤ 0 °C, ≥ 150 °C) are dropped |
| memory pressure | `/proc/pressure/memory` (PSI `some`/`full`, `avg10`/`avg60`); `some avg10` is what the rule uses |
| free memory | `MemAvailable` from `/proc/meminfo` |

A reading that cannot be taken (no sensor, a kernel without `CONFIG_PSI`, not
Linux) is **unknown**, and **unknown never derates**.

## The rule

`Arbiter.Machine.Derate` (pure; `Derate.evaluate/4`) maps the readings, the
machine's cap and live count, the thresholds and the prior state to a level and
the slots `offered` (always ≤ the cap):

| level | entered when | effect |
|---|---|---|
| `none` | — | offers its whole cap |
| `soft` | CPU ≥ `thermal_soft_c`, **or** memory PSI `some avg10` ≥ `psi_some_avg10`, **or** `MemAvailable` < `mem_floor_gib` | **no new slots**: `offered = min(cap, live)`. On the primary, new implementers and resumes of a ticket's own run are held; review-side follow-ups (reviewers, fix and conflict passes, review fix rounds) still run, because holding them could deadlock a ticket waiting for its own review. On a node, `offered = live` leaves no room for any new run |
| `hard` | CPU ≥ `thermal_hard_c` | as soft, **and** new resumes and fix passes are held too: on the primary the follow-up kinds are held, on a node nothing is placed. Memory pressure alone is never hard |

Entering a hard level is immediate; soft thermal entry is smoothed (`thermal_entry_samples`). **Hysteresis**: a derate lifts only after the
readings have stayed below the *release* thresholds (`threshold − delta`) for
`recover_s` seconds continuously; a reading back inside the band
(`release … threshold`) holds the level and restarts the clock. A hard derate
steps down to soft (then none) one window at a time.

## Defaults (on by default)

| key | default | meaning |
|---|---|---|
| `enabled` | `true` | `false` turns derating off for that machine |
| `thermal_soft_c` | `90` | °C at or above which no new slots are offered |
| `thermal_hard_c` | `95` | °C at or above which resumes and fix passes are held too (never below soft) |
| `thermal_delta_c` | `5` | hysteresis: recover only below `soft − delta` (and `hard − delta`) |
| `thermal_entry_samples` | `3` | soft thermal entry needs the median of this many samples (~30 s at the 10 s period) at or above `thermal_soft_c`, and recovery reads the same median, so one `Tctl` spike cannot bench the node. Hard stays immediate (one sample at `thermal_hard_c`). `1` = react to a single sample |
| `psi_some_avg10` | `25` | memory PSI `some avg10` (%) at or above which no new slots are offered |
| `psi_delta` | `10` | hysteresis for PSI |
| `mem_floor_gib` | `4` | `MemAvailable` below this (one worker's worth) offers no new slots |
| `mem_delta_gib` | `1` | hysteresis for the floor |
| `recover_s` | `180` | seconds the readings must stay clear before the derate lifts |

## Tuning

**The primary** — the installation setting `machine.derate` (operator-only), a
JSON object holding only the keys you want to change; it is re-read every
sample, so a change applies within ~10 s with no restart:

    arb settings set machine.derate '{"thermal_soft_c": 85, "thermal_hard_c": 92}'
    arb settings set machine.derate '{"enabled": false}'      # off for the primary
    arb settings set machine.derate null                      # back to the defaults

An unknown key or an invalid value is refused rather than ignored, so a typo
cannot silently leave the guard off.

**A node** — environment variables on the node agent (in
`~/.config/arbiter-node/agent.env`, the unit's `EnvironmentFile`), read at boot; a malformed value keeps the
default:

| variable | key |
|---|---|
| `ARB_NODE_DERATE` (`off`/`false`/`0`) | `enabled` |
| `ARB_NODE_THERMAL_SOFT_C`, `ARB_NODE_THERMAL_HARD_C`, `ARB_NODE_THERMAL_DELTA_C` | the thermal thresholds |
| `ARB_NODE_MEM_PSI_SOME`, `ARB_NODE_MEM_PSI_DELTA` | `psi_some_avg10`, `psi_delta` |
| `ARB_NODE_MEM_FLOOR_GIB`, `ARB_NODE_MEM_DELTA_GIB` | `mem_floor_gib`, `mem_delta_gib` |
| `ARB_NODE_DERATE_RECOVER_S` | `recover_s` |

Restart the agent (`systemctl --user restart arbiter-node`) to apply.

## How it reaches the scheduler

* **Node → primary.** The agent's heartbeat carries `temp_c`, `psi`, `offered`,
  `derate` (`none|soft|hard`) and `derate_reason`. The primary re-derives the
  slots from the node's *effective* cap (the operator's override or the node's
  suggestion, bounded by the owner's ceiling): `Derate.apply_level/3` →
  `min(cap, live)` while derated. A heartbeat that stops naming a derate (an
  older agent, a stopped monitor) reads as no derate.
* **Primary.** `Arbiter.Nodes.LocalCapacity.cap/0` returns `offered`, `derate`,
  `derate_reason` and `temp_c` next to the cap; `LocalCapacity.admit/3` holds
  per the table above.
* **Hard machine-level layer.** `offered` replaces the static cap in
  `Nodes.Capacity` (the install's effective capacity), `Nodes.Placement`
  (node candidacy) and the scheduler walk's machine capacity sets. It is not a
  paced layer: a derated machine offers nothing new, outright. `--over-cap`
  (`force: true`) still goes over a primary's derate, as it does its cap, and
  is recorded.

## Where to see it

* `arb scheduler status` / `scheduler_status` / `GET /api/scheduler/status`:
  `machines[]` carry `cap`, `offered`, `live`, `free`, `temp_c`, `psi`,
  `derate` and `derate_reason`.
* `arb node list` / `GET /api/nodes`: `OFFERED`, `TEMP` and `PSI` columns, and a
  `↳ hard derate: thermal 96 °C — offering 2 of 4` line under a derated row.
* The dashboard: the machine chips in the capacity strip (`box 2/2 of 6`, red
  for hard, amber for soft; the popup says why) and the nodes page.
* Held cards: `held — ryan-oryx-pro thermal 96 °C (self-derated: no new slots
  until the readings stay clear; running workers continue)`; a dispatch refused
  on the primary says `held — local thermal 96 °C`.

## Alerting

Entering a **hard** derate raises the `machine_derate` system alert (keyed by the
machine name; `local` is the primary); leaving it clears it. Both are announced
on the `inbox` event topic, so the coordinator mailbox and stream get them and
`arb alert list --kind machine_derate` shows it while it lasts. A soft derate
raises nothing. See `docs/design/ticket-lifecycle.md` (Child 8).

## Not sensed / limits

macOS and Windows machines report nothing and so never derate. Kubernetes
cluster nodes report no machine sensing (a controller pod has no host
`/sys`). Container CPU quotas are not accounted: the temperature is the host's.
