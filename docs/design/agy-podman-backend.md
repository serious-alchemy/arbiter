# agy on the podman backend: worker identity, credential model, path off bwrap

**Task:** bd-1u6cqe (design, D3) · **Builds on:**
[podman worker containers](podman-worker-containers.md) (bd-jk49nc; §4.1 Claude,
§4.2 Codex, §9 Q2), [guardrail profiles](guardrail-profiles.md) (§2.1, open
question 5), [agy `:strict` write isolation](agy-strict-write-isolation.md),
bd-6dpjw7 (credential spike, closed 2026-10-03), bd-8btihu (file-seeded fallback
removed) · **Status:** proposed 2026-10-09. Nothing here is implemented; no
production code changed. The ticket plan is in [§9](#9-proposed-tickets).

## Decision

1. **The credential model of record is a dedicated worker identity**: one
   `antigravity` `ProviderAccount` per Google account that is *not* the
   operator's, whose login lives in **one per-identity podman named volume**
   holding a private Secret Service keyring. The volume is the only copy of the
   login. A run mounts it; nothing is ever copied into a per-run home. That is
   what makes rotation safe: there is no second copy to diverge
   ([§4](#4-the-credential-model)).
2. **Single-writer refresh is enforced by the existing account slot ceiling.**
   An identity account is created with `max_concurrent: 1`, so at most one agy
   container holds the volume at a time (`Accounts.Concurrency` already derives
   the count from live processes, so a crashed worker frees the slot). No new
   lock service. Raising it past 1 needs the sidecar variant in
   [§5](#5-single-writer-refresh), which is a later, measured step.
3. **The host keyring D-Bus proxy leaves the podman path entirely.** The
   container runs its own private session bus with its own Secret Service; no
   host socket, no `xdg-dbus-proxy`, no `label=disable` needed for the
   keyring, and no exposure of the operator's whole keyring (which today
   includes `gh`'s token, guardrail-profiles open question 5). The proxy stays
   exactly as it is for the bwrap path until bwrap is retired for agy
   ([§6](#6-what-happens-to-the-keyring-d-bus-proxy)).
4. **`GEMINI_API_KEY` (spike C) and a file-seeded token store (spike B) are not
   the plan, because neither was ever measured.** Both spikes were closed
   won't-do on 2026-10-05 when the operator declined to supply a test Google
   account and a Gemini API key (ticket notes). The design therefore does not
   depend on their outcomes; it keeps the API key as a *drop-in alternative
   backend for the same identity slot* ([§4.3](#43-alternatives-considered)) so a
   later positive result changes one adapter branch, not the architecture.
5. **This design cannot be built or accepted without one operator-supplied
   input: a dedicated Google account for the identity.** That is the same input
   declined on 2026-10-05, so the implementation tickets are filed **blocked on
   that decision** ([§8](#8-gates-and-unknowns)). Without it, agy stays on
   bwrap and the keyring proxy, as bd-6dpjw7 concluded.
6. **Retire bwrap for agy in three steps, not one**: opt-in per workspace,
   default for new workspaces, then delete the agy-specific jail code
   ([§7](#7-path-to-retiring-bwrap-for-agy)). The `Jail` module itself survives:
   Codex and review passes still use it.

## Evidence base, and what is not known

Everything about agy's behaviour below comes from the repo's record of
bd-6dpjw7 and bd-8btihu (`docs/worker-security.md`, `Gemini.ConfigDir`,
`Gemini.auth_probe/1`, guardrail-profiles §2.1, podman doc §4 and §9 Q2). The
ticket body for bd-6dpjw7 itself was not readable from this worker's scope, and
this host has neither `agy` nor `podman`, so **no probe was re-run for this
document**. Nothing here is a fresh measurement.

| Fact | Source | Status |
|---|---|---|
| On agy 1.2.16 the file-seeded fallback does not authenticate; legacy files (`oauth_creds.json`, `jetski-standalone-oauth-token`, `google_accounts.json`) are ignored in file mode | `Gemini.ConfigDir` moduledoc, worker-security.md | Recorded, from bd-6dpjw7 |
| The freedesktop Secret Service is the only working path; a brand-new `$HOME` with zero credential files still authenticates against it | same | Recorded (T6a spike) |
| The refresh token rotates; copying the operator's token into per-run homes risks orphaning their login | ticket, worker-security.md | Recorded |
| `env -i` does not hide the keyring: agy finds `/run/user/$UID/bus` by default, so a "no keyring" test must mask it (`bwrap --tmpfs /run/user`) | ticket | Recorded; applies to every test in [§8](#8-gates-and-unknowns) |
| agy has no `login` subcommand, a full-screen TUI, and `--gemini_dir` did not isolate it (it reused the operator's real identity) | `LoginRecipes` moduledoc (bd-82yxz2) | Recorded |
| `ANTIGRAVITY_API_KEY` is a placeholder; Antigravity stores no token Arbiter can read, so its quota cannot be observed from the token | `Accounts.Census`, `Quota.CloudCode` | Recorded |
| **Which keyring library and collection agy uses (label, attribute schema, "login" collection or "default")** | | **Unknown** |
| **Whether agy runs against a private `gnome-keyring-daemon` with an empty-password collection, with no PAM/unlock prompt** | | **Unknown; the central spike, [A1](#9-proposed-tickets)** |
| **Whether a headless first login is possible at all** (OAuth redirect, device code, paste-a-code) | | **Unknown** |
| Whether `GEMINI_API_KEY` is honoured by agy 1.2.16, and its billing/quota | `Gemini.spawn_env/1` passes it, never verified against agy | Unknown (spike C declined) |
| agy's native binary: static or dynamic, what it execs, what hosts it contacts | | Unknown |
| Whether the Google refresh token rotates *on every refresh* or only sometimes, and the grace window for a retired token | | Unknown; decides how hard [§5](#5-single-writer-refresh) must be |

## 1. Why agy stays on bwrap today, and what a container changes

[podman doc §4](podman-worker-containers.md#4-what-each-provider-cli-needs)
left agy on bwrap for two reasons: its only credential path is the host's
Secret Service over a filtered D-Bus, and the proxy that filters it,
`xdg-dbus-proxy`, is not packaged on RHEL 8. A container does not fix either
if it keeps using the *host* keyring:

* A host-side proxy socket mounted into the container needs
  `--security-opt label=disable` (SELinux blocks `connectto`; podman doc §5.3).
  That is already accepted for the Claude/Codex bridge containers (§9 Q1), so
  it is cheap in policy terms.
* The filtered bus still exposes the operator's whole unlocked collection to
  the worker (guardrail-profiles open question 5). A container cannot narrow
  that, because Secret Service has no per-item access control on the wire.

Both go away if the container has **its own** keyring. That is the design's
core move, and it is the only reason to build this rather than leave agy alone.

**Option 0, considered and not chosen:** keep the operator's keyring, start
`xdg-dbus-proxy` host-side per run (like the egress bridge), bind its socket
into the container. It needs no new account, so it is buildable today and it
retires bwrap for agy. It keeps the RHEL 8 packaging problem (the
`flatpak-dbus-proxy` workaround), keeps the whole-keyring exposure, and ties
every worker to a logged-in desktop session on the host. It is the **fallback
if the operator will never supply a dedicated account** ([§7](#7-path-to-retiring-bwrap-for-agy),
ticket A9), but it is not the target.

## 2. Worker identity

An **identity** is a Google account used only by Arbiter workers.

* **Model.** An `antigravity` `ProviderAccount` (provider already exists in the
  schema, `provider_account.ex`) plus one `ProviderCredential` of a new kind,
  `identity_volume`, whose payload is the volume name (not a secret itself),
  and `max_concurrent: 1`. Workspaces link to it through the existing
  `WorkspaceProviderAccount`, so pinning, quota routing, enablement and the
  admission checks work unchanged.
* **Volume naming.** `arb-agy-identity-<account-id>`, created by Arbiter, never
  by a worker. Contents: the keyring directory only
  (`~/.local/share/keyrings` as agy sees it), plus whatever agy writes beside
  its credential that it needs to start (to be listed by A1).
* **What an identity is not.** It is not the operator's login and shares nothing
  with `~/.gemini` on the host. Revoking it (delete the volume, revoke the
  Google session) cannot affect the operator.
* **Account hygiene is the operator's call.** Running automation on a Google
  account may be restricted by Google's terms for the product. That is a policy
  question for the operator, not something this design can settle, and it is why
  [§8](#8-gates-and-unknowns) lists the account as a gate.

### 2.1 Seeding the identity (the hard part)

`LoginRecipes` records that agy has no login subcommand and that its TUI cannot
be relayed. So the seed is a **one-time, interactive, operator-run** step, not
something the login relay can drive:

    arb agy identity login <account>      # proposed (A4)

which runs the *same image and same keyring setup a worker gets*, with the
identity volume mounted read-write and a TTY (`podman run -it`), starts the
private bus/keyring, and execs `agy` so the operator completes the Google
sign-in in it. If agy's sign-in needs a browser redirect to loopback, the
command publishes that single port to the operator's loopback (`-p 127.0.0.1:…`);
whether that is enough, or whether the flow wants a pasted code, is unknown until
A1 runs it. If a headless login proves impossible, the identity model does not
work and the design falls back to Option 0.

After the login the command verifies with a tiny `agy -p` round-trip, never
printing any credential, and records `seeded_at` on the credential row.

## 3. Container shape for agy

Reuses P3/P7/P8: `Container.argv/2`, `ContainerSpawn.prepare/1`/`wrap_port/1`,
the image lifecycle, the egress proxy and Arbiter bridges, the per-run private
clone. What is agy-specific:

| Item | Design |
|---|---|
| Routing | `Sandbox.module(:podman, provider)` accepts `gemini` only when the workspace's agy account is an identity account; otherwise it stays the refusal it is today. **Fix first**: `ContainerSpawn.provider_name/1` ends in a catch-all `provider_name(_) -> "claude"`, so adding a provider by widening `Sandbox` alone would silently spawn Claude's mounts for agy. A2 makes it an exhaustive match that raises |
| The CLI | The host's `agy` mounted read-only at `/opt/arbiter/cli/agy`, like Claude's and Codex's, if it is a self-contained binary; if it is a launcher with a runtime dependency, resolve the real binary as `codex_mounts/1` does. Unknown until A1 |
| Keyring in the container | The image gains `dbus` and `gnome-keyring` (or the smallest Secret Service provider A1 shows agy accepts). The container entrypoint is a small wrapper: start a private `dbus-daemon --session --fork`, start the keyring daemon unlocked with an empty password against the identity volume, export `DBUS_SESSION_BUS_ADDRESS` for the child, `exec` agy. The bus is a unix socket **inside the container's own tmpfs**: no host path, no SELinux label change |
| `HOME` and settings | Per run, as for Codex: `Gemini.ConfigDir` already builds an Arbiter-owned `$HOME` with generated `settings.json`, `mcp_config.json` and the posture; for a container spawn the dir is seeded under the run's temp dir and mounted rw, and the identity volume is mounted at the keyring path only. The host's symlinked passthrough (`.ssh`, `.gitconfig`) is skipped, as for Claude |
| Env | `SpawnEnv` allowlist for `gemini` stays `[]` for credentials in the identity path (no `GEMINI_API_KEY`); the `DBUS_SESSION_BUS_ADDRESS` exception is bwrap-only |
| Egress | `@egress_infra["gemini"]` gets agy's infra hosts. They are **unknown**; A1 runs a learn-mode pass and records them. Until then the container runs the proxy in learn mode only |
| Write jail | `--read-only` plus the explicit mount set gives `write_confinement/1 -> :os_jail` the same way as Claude, so `:strict` eligibility (agy-strict-write-isolation) is carried by the container. The `jetski:` denial notices are agy's own and are unchanged |
| Reviews, fix passes | Follow `pass_policy/3`, which today only containerises Claude. agy review passes stay on bwrap until A7 |

## 4. The credential model

### 4.1 Chosen: per-identity volume holding a private keyring

* **Why a volume and not `--secret`.** `podman run --secret` delivers a
  *static, read-only* value. agy's credential is rewritten by the process every
  time it refreshes. A `--secret` copy would be a per-run snapshot of a
  rotating token, which is exactly the divergence the spike warned about. A
  volume is a single mutable home. (`--secret` remains right for the deploy key
  and for an API key, which do not change underneath the run.)
* **No copies, no AuthSync.** Codex needed `Codex.AuthSync` (newest
  `last_refresh` wins, a reaper, an account-id check) because it copies
  `auth.json` into a per-run home. Here there is no copy to merge, so none of
  that machinery is needed, and the "worker can write a forged newer file"
  problem does not arise. The cost is that the volume is **writable by the
  worker**: see the threat model.
* **SELinux.** A named volume used by one container at a time is mounted with
  `:Z` (private relabel; podman does this for named volumes). The `max_concurrent: 1`
  rule above is what makes that safe; two concurrent containers on one volume
  would also trip the MCS pair.
* **Rootless ownership.** The wrapper runs as the `--userns=keep-id` user, the
  volume is created by that user, so the keyring files are owned correctly and
  the host operator can still `podman volume export` for backup.

### 4.2 Threat model

| Question | Answer |
|---|---|
| What can the worker read? | The identity's refresh token (it is in the volume agy uses), as Claude's worker reads its token env. Blast radius is the dedicated account only, which is the point of an identity. The operator's keyring, `gh` token and ssh agent are not reachable |
| Can it exfiltrate it? | Only through the egress proxy; the allowlist limits that exactly as for Claude/Codex tokens |
| Can a worker corrupt it? | Yes: it can delete or overwrite the keyring. Effect: that identity needs a re-login (`arb agy identity login`). It cannot touch another identity or the operator. The auth probe ([§8](#8-gates-and-unknowns)) catches it before the next dispatch |
| Backups and logs | The volume is credential material. `arb` must never print its contents or `podman volume inspect` output into logs; the doctor check reports name, size and `seeded_at` only |

### 4.3 Alternatives considered

| Option | Verdict |
|---|---|
| **API key (`GEMINI_API_KEY`) via `podman run --secret type=env`** | Best on paper: no keyring, no daemon, no rotation, no proxy, no single-writer problem; `Gemini.spawn_env/1` and the `SpawnEnv` allowlist already carry the variable. **Unmeasured**: spike C was declined, so it is not known that agy 1.2.16 honours it (the adapter's use of it dates from the upstream Gemini CLI that was dropped in bd-ac53wz), nor how its billing and quota differ. Antigravity's quota is observed through the account's own login (`Quota.CloudCode`); an API-key worker is probably billed per token and probably invisible to quota routing (both unverified), in which case the router would route blind. **Kept as ticket A8**: if the operator supplies a key and a probe passes, it replaces §4.1 for that account with a `ProviderCredential` of kind `api_key` and a branch in `ContainerSpawn`. Everything else in this document still applies |
| **Host-side broker holding the refresh token and handing out access tokens** | Rejected. agy 1.2.16 ignores file seeds, so there is no injection point for a short-lived token. The alternative, header injection in the egress proxy, needs TLS interception of Google traffic. Arbiter would also have to impersonate agy's OAuth client. Re-open only if agy gains a documented token-injection input |
| **Copy the operator's token into per-run homes** | Rejected by bd-6dpjw7 (orphans the operator's login). Also what `Codex.AuthSync` exists to repair, at real complexity |
| **Per-run container reading the operator's keyring through a host proxy (Option 0)** | Fallback only; see [§1](#1-why-agy-stays-on-bwrap-today-and-what-a-container-changes) |
| **Keyring daemon on the host, one per identity, socket shared into workers** | This is the sidecar in [§5](#5-single-writer-refresh); a scale-up of the chosen model, not an alternative to it |

## 5. Single-writer refresh

Hazard: two agy processes that hold the same rotating refresh token each refresh
near expiry; the first retires the token server-side and the second fails (the
same shape as the Codex note in podman doc §4.2, "two runs that both hold T0").
Two daemons on one keyring file add a second hazard: each caches in memory and
writes the whole file, so one overwrites the other's update.

**Level 1, shipped with the design: one run per identity.** `max_concurrent: 1`
on the identity account.

* Enforced by `Accounts.Concurrency.account_headroom/2`, which derives
  `live_count` from the process registry. A worker killed without cleanup
  releases its slot when it dies, so a stale lease cannot wedge an identity.
* One container, one keyring daemon, one writer, by construction. Rotation made
  in run N is in the volume when run N+1 starts.
* The lease must cover the **whole container lifetime including `teardown`**: the
  container is removed by name before the slot is considered free, or run N+1
  could mount a volume the dying run is still flushing. A5 adds this ordering
  and a test (kill the owning worker; assert the next dispatch waits for the
  `podman rm`).
* Cost: agy runs serially per identity. That is real for a busy workspace, and
  it is the expected pressure to add identities (cheap: a second account and
  volume) before building anything cleverer.

**Level 2, only if measurement says it is needed: a per-identity keyring
sidecar.** One long-lived container per identity owns the volume and runs the
only bus and keyring daemon; its bus socket is exposed on a private host
directory and each worker container mounts that socket (this is the same
`label=disable` bridge pattern §9 Q1 already accepted). All workers then share
one daemon, so there is one writer. It does **not** by itself prevent two agy
*processes* both refreshing the same token. It needs either a refresh window
(Arbiter forces a refresh when the access token is near expiry, before
releasing the run) or proof that Google's retired-token grace window covers the
overlap. Both depend on the unknown "rotates every refresh?" fact, so the
sidecar is deliberately **not** in the first ticket set. A10 is the measurement
that decides.

**Not a problem here:** the operator's own login is never involved, so nothing
in this design can orphan it.

## 6. What happens to the keyring D-Bus proxy

| Path | Proxy |
|---|---|
| bwrap agy (today) | Unchanged: `Jail.keyring_proxy/1` starts `xdg-dbus-proxy --filter --talk=org.freedesktop.secrets` per run; preflight fails loudly with no keyring (`Gemini.auth_probe/1`, `require_keyring/2`) |
| podman agy, identity | **None.** The bus is private to the container. `Jail.keyring_usable?/0`, `ConfigDir.keyring_available?/1` and the `DBUS_SESSION_BUS_ADDRESS` exception in `SpawnEnv` are not consulted. `Gemini.auth_probe/1` for an identity account becomes "the volume exists, `seeded_at` is set and the lease is free", not "a session bus exists on the host" (A6) |
| podman agy, Option 0 (fallback) | Host-side `xdg-dbus-proxy`, socket mounted, `label=disable` |

Consequences: the RHEL 8 packaging gap disappears for identity workers; the
guardrail-profiles open question 5 ("the filtered keyring is still the whole
keyring") is answered for them by construction, since the bus holds one
account's login only; the `Gemini.auth_probe` message "agy needs a keyring (D-Bus)
or its own login on this host" stays true only for the bwrap path.

Tests that assert "no keyring" must mask `/run/user/$UID` (the ticket's gotcha):
`env -i` is not enough, and a passing "no keyring" test that actually found the
host bus proves nothing. Every ticket below that has such a test says so.

## 7. Path to retiring bwrap for agy

| Step | What | Exit criterion |
|---|---|---|
| **R1: opt-in** | `sandbox.backend: podman` becomes legal for a workspace whose agy account is an identity account (A2, A3, A5, A6). Everything else still resolves to the refusal. bwrap stays the default and the only path for non-identity accounts | The A1 findings are recorded; one real agy ticket runs end to end in a container (auth, MCP call, `:strict` write denial, egress through the proxy), evidence attached, not mocked |
| **R2: default** | New workspaces with an agy identity default to podman. `arb server doctor` reports bwrap-agy as deprecated. Review passes for agy get a container path (A7) | Two weeks of agy tickets on podman with no auth-class stop reasons (`:auth_expired`) that a re-login did not fix, and the single-writer slot never observed wedged |
| **R3: delete** | Remove `Gemini.jail_agy/5`, the keyring proxy wrapper (`maybe_keyring_proxy/2`, `keyring_proxy/1`, `dbus_proxy/0`, `keyring_usable?/0`, `session_bus_reachable?/0`), `ConfigDir.keyring_available?/1`/`keyring_reachable?/1`, the `SpawnEnv` bus exception and the doctor's keyring-proxy check | No workspace is on bwrap for agy. `Jail` stays: Codex review passes and non-Claude passes still use it (`pass_policy/3`), and the bwrap backend remains selectable for them |

If the operator never supplies an identity, R1 cannot start and the answer
stays "agy on bwrap" (podman doc decision 1). Option 0 (A9) is then the only
way to retire bwrap for agy, at the costs in
[§1](#1-why-agy-stays-on-bwrap-today-and-what-a-container-changes), and is
justified only if keeping two backends is judged worse than the whole-keyring
exposure, which bwrap already accepts.

Bwrap-only agy behaviour that must have a container equivalent before R3:

| bwrap feature | Container equivalent |
|---|---|
| Write jail (worktree, git dir, own HOME) | `--read-only` + the explicit mount set (P3) |
| `--unshare-net` + egress proxy | `--network=none` + proxy bridge (P5/G5) |
| `/run/user`, `/run/dbus`, resolver masks | A container has none of them by construction |
| Shadow ssh config / deploy key | `--secret` (P9/G16) |
| Filtered keyring bus | The private bus ([§3](#3-container-shape-for-agy)) |

## 8. Gates and unknowns

Hard gates (a ticket cannot be accepted without them):

1. **A dedicated Google account** for the identity, supplied by the operator.
   Declined once already (2026-10-05). Without it every ticket below except A9
   stays blocked.
2. **A1 shows agy authenticates against a private, container-local Secret
   Service on an empty-password keyring and a headless login is possible.** If
   not, the identity model is dead and the answer reverts to Option 0 or "agy
   stays on bwrap".

Unknowns A1 and A10 must resolve and record (names, never values):

* The keyring collection/attribute schema agy writes, and the minimum Secret
  Service implementation that satisfies it.
* How a first login works headless; whether it needs a loopback port.
* Whether the refresh token rotates on every refresh and the grace window.
* agy's native binary type and the hosts it contacts (for the egress baseline).
* Whether agy touches anything outside the keyring that must persist per
  identity (device ids, installation ids, cached account info).

Verification rules for every ticket that touches credentials: never print token
or keyring values (names, sizes and fingerprints only); mask `/run/user` when
testing "no keyring"; use only the dedicated test account, never the operator's
own login; do not run two agy processes against the operator's real keyring
while measuring rotation.

Out of scope here: quota observability for an identity (the Antigravity token is
not readable by Arbiter, `Quota.CloudCode`), and the terms-of-service question
in [§2](#2-worker-identity).

## 9. Proposed tickets

The coordinator files these. All are children of bd-1e80nw. D = estimated
difficulty. **Every ticket except A9 is blocked on gate 1; A2 onward is also
blocked on A1 passing gate 2.**

| # | Title | D | Depends on | Acceptance (summary) |
|---|---|---|---|---|
| **A0** | **Operator decision: dedicated Google account (and optionally a Gemini API key) for an Arbiter worker identity.** Decision ticket for the operator, with the terms-of-service point in §2 spelled out | 1 | none | Account supplied and recorded as a `decision`, or declined with "agy stays on bwrap; close A1 to A8, keep A9 open" |
| **A1** | **Spike: agy against a container-local Secret Service.** In a `podman run -it` with a named volume, private `dbus-daemon` plus `gnome-keyring-daemon --unlock` (empty password): complete a first login, run `agy -p` headless, restart the container and run again, force and observe a token refresh, then delete the volume and confirm a clear auth failure. Run learn-mode egress and record hosts. Test "no keyring" with `/run/user` masked. Record the keyring schema, native-binary type, per-identity state beyond the keyring, and whether rotation happens on every refresh and its grace window. Output: a findings appendix here | 3 | A0 | Each unknown in §8 answered or marked unanswerable, with commands and redacted output; gate 2 stated pass/fail |
| **A2** | **Route `gemini` to the container backend for identity accounts.** `Sandbox.module(:podman, "gemini")` resolves to `Container` only for an identity account, else the existing refusal. Make `ContainerSpawn.provider_name/1` exhaustive (it currently falls through to `"claude"`). `provider_mounts("gemini", …)` for the agy binary. `@egress_infra["gemini"]` from A1 | 3 | A1 | A test that a `gemini` spawn under podman with a non-identity account is the refusal, and that an unknown provider raises instead of becoming Claude. `mix precommit` clean |
| **A3** | **Image: keyring entrypoint.** Add the Secret Service provider and `dbus` to the base image, the wrapper script (private bus, unlocked keyring, exec agy), image-hash inputs updated. The wrapper must exit non-zero with a clear message, not hang, if the keyring does not come up | 3 | A1 | Image builds; a container test starts the wrapper and gets a bus; failure modes (no volume, bad perms) exit within a bounded time. Podman-tagged tests are excluded from the default run as the others are |
| **A4** | **`ProviderAccount` identity kind and `arb agy identity login/status/revoke`.** New credential kind `identity_volume` (name only, never a secret), `seeded_at`, volume lifecycle, the interactive login command from §2.1, `status` that reports size and `seeded_at` and never contents, `revoke` that deletes the volume. Docs in `docs/worker-security.md` | 3 | A1, A3 | Round trip against the test account: login, status, a worker run, revoke. CLI and API tests. No credential in any log or response |
| **A5** | **Spawn path: mount the identity volume, own the lease.** `ContainerSpawn` for gemini: mount the volume at the keyring path (`:Z`), seed the per-run HOME via `Gemini.ConfigDir` for a container spawn (skip the passthrough symlinks), set no credential env. Enforce `max_concurrent: 1` on identity accounts at creation. Teardown removes the container before the slot is freed | 4 | A2, A3, A4 | The kill-the-worker test in §5. A second dispatch on the same identity waits. Live run: agy ticket end to end in a container (auth, an MCP call, a denied out-of-worktree write under `:strict`, egress through the proxy), real output attached |
| **A6** | **Preflight and doctor for identity accounts.** `Gemini.auth_probe/1` for an identity account checks the volume and `seeded_at` and runs no host-bus check; a doctor check lists podman readiness plus the identity volumes. Tests mask `/run/user` | 2 | A4 | Unit tests for each branch; the no-keyring test passes with `/run/user` masked |
| **A7** | **agy review and fix passes on the container backend.** Extend `pass_policy/3` so agy passes use the container when the account is an identity (they hold a slot, so they serialise with the implementer on `max_concurrent: 1`: decide and document whether a review may wait) | 3 | A5 | Review and fix-pass tests; a documented decision on slot contention |
| **A8** | **Optional: `GEMINI_API_KEY` credential kind via `podman run --secret type=env`.** Only if A0 yields a key and a probe shows agy 1.2.16 authenticates with it. Records billing/quota behaviour. Skips the volume, the keyring and the lease (no rotation) | 2 | A0, A2 | Probe evidence in this doc; `--secret` delivered with no value on argv or in `podman inspect` output |
| **A9** | **Option 0 fallback: host-side `xdg-dbus-proxy` for a podman agy.** Start the proxy host-side per run (as `Egress.JailRun` does), mount the socket, `label=disable`. Only if A0 is declined and keeping two backends for agy is judged worse than the whole-keyring exposure | 3 | A2 | Live run as A5, plus a documented, accepted whole-keyring exposure |
| **A10** | **Measure whether Level 2 (sidecar) is needed.** After a trial period on Level 1, report per-identity queueing from the registry and the A1 rotation findings. File the sidecar ticket only if serial runs are the bottleneck and identities are not cheap enough to add | 2 | A5 | A short written recommendation with numbers |
| **A11** | **Retire agy-specific bwrap code (R3).** Delete the items listed in §7 R3, update `worker-security.md`, podman doc §4/§9 Q2 and guardrail-profiles | 2 | A5, A7, two weeks of R2 | Grep for the removed symbols is empty; no workspace on bwrap for agy |

**Order.** A0, then A1 (gate 2). A2, A3 and A4 can proceed in parallel after A1.
A5 needs all three. A6 and A7 follow A5, A10 runs alongside, A11 closes it out.
A9 and A8 are alternatives that replace A3–A5 if the evidence goes the other way.
