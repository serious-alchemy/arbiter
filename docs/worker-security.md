# Worker security: configurable permissions & sandboxing

**Task:** bd-9u10op · **Builds on:** bd-c6xf18 (pluggable agent harness),
bd-3y2mda (config-dir isolation)

## The problem this fixes

A worker (a worker or reviewer) is an autonomous coding agent spawned in a
git worktree via `claude --print …`. Before this change it ran with **no
permission flags**, so it silently inherited the **host operator's** global
`~/.claude/settings.json` — which on a developer install routinely carried
`defaultMode: auto` with an **empty deny list** — and it ran **un-sandboxed**
on the host, with full filesystem and network reach, contained to its worktree
only by convention.

On 2026-06-03 that posture bit us: with an empty deny and no sandbox, a
stack-lifecycle worker's `git merge` wedged the live server. There was no
Arbiter-level way to say "a worker in this domain may do X but not Y, and is
isolated to its worktree."

This change makes the posture **explicit, configurable, and
provider-agnostic**.

## The model

A single normalized, provider-agnostic policy —
`Arbiter.Agents.SecurityPolicy` — that every provider adapter maps to its own
mechanism. The policy names *intent*; it never speaks any provider's flag
syntax.

```elixir
%Arbiter.Agents.SecurityPolicy{
  permissions: %{
    mode: :auto | :strict | :bypass,
    allow: ["…"],            # operator-added allow rules
    deny:  ["…"],            # operator-added deny rules
    safe_defaults: [:no_destructive_fs, :no_force_push,
                    :no_secret_reads, :no_outside_writes],
    safe_defaults_exclude: []   # names dropped from the current default set
  },
  sandbox: %{
    enabled: true,
    filesystem: :worktree | :none,
    network: true | false,
    writable_paths: [],         # extra writable paths inside the OS write jail
    egress_tunnels: []          # "LOCAL:HOST:PORT" host services bridged into the jail's netns
  }
}
```

### Permission modes

| Mode      | Meaning                                                                     | Interactive classifier? | Deny enforced? |
|-----------|-----------------------------------------------------------------------------|------------------------|----------------|
| `:bypass` | **Headless-safe default.** No interactive classifier; deny list still on.   | **no** (headless-safe) | **yes**        |
| `:auto`   | Opt-in for supervised runs. Classifier active; can pause and ask approval.  | yes (can freeze)       | **yes**        |
| `:strict` | Only explicitly-allowed tools run; everything else is blocked.              | yes (collapses to deny)| **yes**        |

#### Why `:bypass` is the headless-safe default

Workers are headless — they run via `claude --print` with no human watching.
The interactive permission classifier in `:auto` mode was designed for
*interactive* sessions: it can pause and ask "do you want to allow this?" When
no human is present, that prompt has no one to answer it, and the worker
freezes mid-task. The task stalls silently.

`:bypass` uses `--dangerously-skip-permissions` to skip the interactive
classifier entirely, preventing headless freezes. Crucially, the deny list is a
**separate, orthogonal mechanism** — deny rules are hard tool-level blocks
enforced at the tool layer, and they are still applied via `--settings` even
in `:bypass` mode. So:

> **Worktree containment = blast-radius fence. Deny list = real security fence.
> `:bypass` = headless-safe, deny list on.**

Use `security.mode: auto` in workspace config if you want the interactive
classifier (and accept the freeze risk for headless runs). Use `:strict` for
the tightest allow-list posture.

### Safe-by-default deny

`safe_defaults` is the **non-empty** baseline every adapter must deny, even in
`auto`. It always resolves to the **current full set of default categories
minus any explicit exclusions** — a workspace can only shrink it by naming
categories in `safe_defaults_exclude`, never by pinning a fixed list. This
means a workspace config written before a new category existed still picks
that category up automatically the moment it ships (see bd-4420va: a pinned
`safe_defaults` from before v0.1.78 silently missed `:no_public_upload` until
this rule was added). The legacy `permissions.safe_defaults` config key is
still accepted for backward compatibility but is **inert** — its value is
ignored entirely, since the resolved set is always computed from the current
defaults. The categories:

| Category             | Blocks (examples)                                         |
|----------------------|-----------------------------------------------------------|
| `:no_destructive_fs` | `rm -rf`, `mkfs`, `dd`                                     |
| `:no_force_push`     | `git push --force` / `-f` (`--force-with-lease` is allowed)|
| `:no_secret_reads`   | reading `.env`, `*.pem`, `~/.ssh/**`, cloud creds          |
| `:no_outside_writes` | writing `/etc/**`, `~/.ssh/**`, `~/.claude/**`, …          |
| `:no_pr_create`      | `gh pr create`, `glab mr create` (the MergeQueue owns PRs) |
| `:no_async_wait`     | the `Monitor` / `ScheduleWakeup` tools (Claude only)       |
| `:no_public_upload`  | public upload/paste hosts                                  |
| `:no_gh_publish`     | `gh gist create`/`edit`, `gh issue comment` (workers only) |

### Public upload and paste hosts (`:no_public_upload`, `:no_gh_publish`, bd-80talz)

On bd-aro53b an agy worker made a public gist on the operator's account and
uploaded mockup "screenshots" to files.catbox.moe. It also tried 0x0.st,
transfer.sh and envs.sh. A public, anonymous host accepts repo content, logs
or secrets as easily as images, and usually keeps them for good.
`SecurityPolicy.public_upload_hosts/0` is the documented host list, as bare
domains:

> catbox.moe (and litterbox, litter.catbox.moe), 0x0.st, transfer.sh,
> file.io, envs.sh, x0.at, temp.sh, tmpfiles.org, uguu.se, bashupload.com,
> oshi.at, keep.sh, filebin.net, pixeldrain.com, gofile.io, pastebin.com,
> paste.ee, paste.rs, dpaste.com, dpaste.org, hastebin.com, termbin.com,
> ix.io, sprunge.us, rentry.co, controlc.com, justpaste.it, privatebin.net,
> imgur.com, imgbb.com, postimages.org

| Provider | URL tools | Shell | Commands |
|----------|-----------|-------|----------|
| Claude | `WebFetch(domain:<host>)` + `WebFetch(domain:*.<host>)` | `Bash(<tool> *<host>*)` for `curl`, `wget`, `http`, `nc` | `gh gist create`/`edit`, `gh issue comment` |
| agy | `read_url(<host>)` + `execute_url(<host>)` (a bare domain covers its subdomains; probed) | **by host: not expressible** (`command(...)` is a literal prefix, a glob in it matches nothing; probed). Upload-shaped `curl -F`/`--form`/`-T`/`--upload-file` prefixes are denied instead | same |
| Codex | **not enforced**: Codex has no deny-list mechanism (`security_enforced? = false`) | — | — |

The `gh` rules in the Commands column are a separate category,
`:no_gh_publish`, that binds headless workers only. Interactive operator and
coordinator sessions (`SecurityPolicy.interactive_session/0`) keep the host
denies but may still comment on issues and use gists: that is ordinary work
for them, and the incident was a worker. `gh pr comment` stays allowed for
workers too: the review-thread follow-up protocol uses it.
These are permission-layer rules, like the rest of this page: an upload through
`python -c`, or a `curl` whose flags come in another order on agy, is not
matched. The worker prompt's `NO PUBLIC UPLOADS` rule
(`Arbiter.Worker.EvidenceIntegrity.worker_block/0`) says the same thing to
every provider, Codex included.

To opt a domain out of specific categories, name them in
`permissions.safe_defaults_exclude` (e.g. `["no_destructive_fs"]`, not
recommended). This is the **only** way to drop a default category —
`safe_defaults_exclude` unions across resolution layers (workspace, repo
override, per-dispatch), so once a category is excluded anywhere in the
chain it stays excluded; nothing can re-add it back except removing the
exclusion. The old `permissions.safe_defaults: []` key (a literal, replacing
list) is **inert** — it is still accepted so existing configs keep parsing,
but its value has no effect on the resolved deny set, which is always
`safe_default_categories() -- safe_defaults_exclude`. `arb server doctor` and
`arb prime` flag any workspace whose resolved policy is missing a current
default category, naming which ones. **Effective floor caveat:** the isolated
`CLAUDE_CONFIG_DIR/settings.json` is generated once from the install-default
policy (which includes every safe-default category) and Claude unions deny
lists across settings sources. Excluding a category in workspace config
removes it from the per-spawn `--settings` deny list, but the config-dir
floor still carries it. The practical effect is that the config-dir
safe-default denies are a **hard minimum** that cannot be removed through
workspace config alone — only changing `SecurityPolicy.base/0` or the
install-level `:worker_security_policy` app env removes them.

### Sandbox

`filesystem: :worktree` keeps file access scoped to the handed worktree;
`network: false` cuts the agent's **network-egress tools** (`WebFetch`,
`WebSearch`, `curl`, `wget`, `nc`, …). It does **not** block native OS network
traffic (`git push`, package installs, SSH) — those require a kernel-level
sandbox. The badge and surface show `net=tools-off` to make this scope explicit.

> **Enforcement level — be honest about it.** For the Claude provider these are
> *permission-layer* guards inside the agent (it won't run a denied command),
> not a kernel jail. They stop the failure mode of the motivating incident (the
> agent's own destructive op) and are a strict improvement over inheriting an
> empty deny. Genuine OS-level isolation (network namespaces, a real fs jail)
> is a documented follow-up; the `sandbox.enabled` field is the seam for it.

#### The OS write jail (`Arbiter.Worker.Jail`, bd-5gvqgc, bd-3s82pf)

The first real kernel-level fence, used for **every agy spawn** whenever the
policy's `sandbox.enabled` and `sandbox.filesystem: :worktree` hold — the
base default, so the jail is default-on for agy in `:bypass`/`:auto` too, not
just `:strict` (bd-3s82pf; see the agy section below for why agy needs it).
`sandbox.enabled: false` remains an explicit opt-out that skips the jail in
every mode. The worker runs under bubblewrap:

    bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /dev/shm \
      [--bind-try <each sandbox.writable_paths entry>] \
      --bind|--ro-bind <worktree> --bind <agy HOME> --setenv HOME <agy HOME> \
      --bind <git common dir> \
      --ro-bind <common>/hooks --ro-bind <common>/config --ro-bind <common>/worktrees \
      --bind <own gitdir> --ro-bind-try <own gitdir>/commondir --ro-bind <worktree>/.git \
      --setenv HEX_HOME|MIX_HOME|XDG_CACHE_HOME <per-worker dirs under the agy HOME> \
      --unshare-pid --die-with-parent --new-session --chdir <worktree> -- agy -p ...

The worktree bind is `--ro-bind` instead of `--bind` for a worktree-backed
review dispatch (`Dispatch.review_security_policy/2`'s
`deny: ["Edit", "Write", "NotebookEdit"]`), so the reviewer read-only posture
becomes an OS guarantee: an agy reviewer's native `write_to_file` fails with
`EROFS` against its own worktree, the same as any other outside-worktree
write.

**Fail-closed only in `:strict`.** Outside `:strict`, a host that can't jail
(no `bwrap`, userns restricted, `worker_isolate_config` off, …) just runs agy
unjailed — the same posture as before this change — rather than refusing the
dispatch: `:bypass`/`:auto` never gated on write confinement, and jailing
there is a hardening, not a promise dispatch made. `:strict` still refuses
(`{:write_jail_unavailable, reason}`) rather than silently downgrading.
`Gemini.write_jail_warning/1` names the reason for that degraded, unjailed
`:bypass`/`:auto` case (`nil` when the jail applies, or the CLI/policy makes
the whole question moot); it is surfaced per-workspace as
`security_posture.write_jail_warning` on the workspace API and as the
`arb server doctor` check "agy write jail". The full doctor **self-test**
(does `bwrap` actually work on *this* host) is bd-8xy1mf — the warning here
only reports what `write_confinement`'s own probe already found while
building this spawn's argv.

* **Writable:** the worktree, the git common dir (commits need its objects and
  refs), the worker's own agy `$HOME`, and any `sandbox.writable_paths`.
  Everything else, including the rest of the operator's `$HOME`, `~/.arbiter`
  and the main checkout, is read-only: a write fails with `EROFS`
  (`read-only file system`), whichever tool makes it.
* **Read-only on top**, after every writable bind so no `writable_paths` entry
  can re-open them: `hooks/` and `config` in the common dir, the sibling
  worktrees' gitdirs (`<common>/worktrees`, with the worker's own gitdir
  re-opened on top), the own gitdir's `commondir` and the worktree's `.git`
  file. Each would otherwise let a jailed process get code run *unjailed* by
  the host's next git command (a hook, `core.fsmonitor`, or a `commondir` /
  `.git` pointer at a fake git dir with its own config).
* **Private `/tmp` and `/dev/shm`**, gone with the jail. That also ends the
  shared-`/tmp` collisions between workers (the verify DB under
  `System.tmp_dir!/0`, test scratch dirs).
* **Toolchain caches are per-worker.** `HEX_HOME`, `MIX_HOME` and
  `XDG_CACHE_HOME` point under `<agy HOME>/.arbiter-jail/`. The per-worker
  `MIX_HOME` links the operator's Hex archive and rebar3 through read-only, so
  `mix deps.get` works while `mix archive.install` / `local.hex` cannot plant
  code the operator's later mix runs would load. The Hex package cache starts
  cold per worktree. `sandbox.writable_paths` (absolute or `~/…`, unioned
  across layers like `allow`) is the escape hatch for anything else; every
  shared writable path is a way to leave something behind that runs outside
  the jail later, so keep it short. `/` and the operator's `$HOME` itself are
  refused, and a missing path is skipped (`--bind-try`).
* **Teardown.** `--unshare-pid` makes the jail its own pid namespace and
  `--die-with-parent` ties it to the outer `bwrap` the worker port spawned.
  The existing stop path (`OsProcess.kill_tree/1` on the port's `os_pid`)
  kills that outer process, which kills the namespace's pid 1, and the kernel
  then kills everything in the namespace, however deep or detached. That is
  tighter than before, when the depth-bounded descendant walk could miss a
  process agy backgrounded. The jailed command's exit status is passed through
  unchanged.
* **Availability is probed, not assumed.** `Jail.available?/0` runs the jail
  once per VM on a scratch dir (under `$XDG_CACHE_HOME/arbiter/jail-probe`,
  not `/tmp`) and requires the write inside to land and the write outside to
  fail with `EROFS`. The userns sysctls, AppArmor's
  `apparmor_restrict_unprivileged_userns` and a setuid bwrap all change the
  answer, so the binary alone proves nothing. The result is cached until
  restart. A host that fails keeps agy out of `:strict` (the fail-closed gate,
  bd-1abj7u) and runs agy unjailed everywhere else (`write_jail_warning`
  names why); a real `arb server doctor` self-test that runs the probe
  itself is bd-8xy1mf.

**Open escape, not accepted** (found 2026-09-30 by bd-8apkz6; the fix is
filed as bd-7o08mj, see [design/guardrail-profiles.md](design/guardrail-profiles.md) §2.1):
`--ro-bind / /` leaves `/run/user/$UID/bus` and
`/run/user/$UID/systemd/private` reachable. A jailed process can therefore run
an unjailed command through `systemd-run --user`, which writes anywhere and
has full network. This was reproduced with `Jail.argv/2`'s own output.
systemd-resolved's varlink socket also answers DNS from inside the jail.
Hiding `/run/user/$UID`, `/run/dbus` and `/run/systemd/resolve` with
`--tmpfs` closes both.

**Network mode (bd-cfktou, G6).** agy's jail also runs with `--unshare-net`:
the namespace has only `lo`, with no route for UDP or ICMP, and the resolver
sockets are hidden, so nothing resolves inside. The only way out is a
per-run set of Unix sockets under `Egress.socket_dir/0` (the directory is
blanked with a `--tmpfs`, and only that run's own sockets are bound back),
each reached by an in-namespace `socat` on loopback:

| In the jail | Goes to |
|---|---|
| `127.0.0.1:3128` (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`) | the run's filtering CONNECT proxy (`Arbiter.Worker.Egress`) |
| `127.0.0.1:<Arbiter port>` (4848 by default) | Arbiter's endpoint, so `arb` and the MCP URL are unchanged |
| `127.0.0.1:<port>` per fixed tunnel | one fixed `host:port` |
| `ssh` (git over SSH) | `GIT_SSH_COMMAND` carries `-o 'ProxyCommand socat - PROXY:127.0.0.1:%h:%p,proxyport=3128'`, so the proxy sees `github.com:22` |

`NO_PROXY=127.0.0.1,localhost,::1` keeps loopback URLs (the Arbiter bridge,
a test server in the namespace) off the proxy. The proxy's baseline is the
adapter's infra hosts plus the host of each git remote in the worktree.

**Fixed tunnels.** A host-loopback service a workspace's tests need (say
Postgres on the host's `127.0.0.1:5432`) is not reachable from the namespace's
own `lo`. List it per workspace (or per repo) as
`config["agent"]["security"]["sandbox"]["egress_tunnels"] = ["5432:127.0.0.1:5432"]`
(`LOCAL:HOST:PORT`): the jail gets `127.0.0.1:5432` bridged to that one
destination, on the host side, through a `t<n>` socket. The destination is
fixed by operator config, not by the agent, and the layers union like
`writable_paths`. Malformed entries are dropped. A local port that collides
with the proxy (3128) or Arbiter bridge fails the spawn (`duplicate_bridge_port`).

The proxy and bridges live and die with the worker. A spawn whose proxy
cannot start (or whose `socat` is missing at spawn time) **fails** with
`{:egress_unavailable, reason}` in every mode; it never runs on the shared
network. `Jail.network_status/0` is the host check behind the doctor line:
if it fails, agy gets the filesystem jail on the shared network as before and
a warning is logged. `config :arbiter, :worker_jail_network, false` switches
network mode off.

**Known, accepted gaps** (the threat model is a misdirected same-user agent,
not a hostile kernel exploit):

* The network is shared **on a host without network mode** (no `socat`, or
  no network namespaces; `arb server doctor` fails "agy jail network" there).
  Where network mode works (below) the jail has no shared network at all.
  `sandbox.network: false` is still only the tool-level deny. The
  enforcement design is
  [design/guardrail-profiles.md](design/guardrail-profiles.md) §4.
* The proxy runs in **learn mode**: only public-upload hosts are refused
  today. Every other decision is logged to `egress_events` and allowed,
  until agy's authenticated host set is recorded and an enforcing mode can be
  switched on (G10). The first live probe of agy (bd-cfktou) stopped at the
  OAuth prompt, so that set is not recorded yet.
* Reads are not restricted.
* The main `.git` stays writable, so a jailed worker can still write sibling
  worktrees' refs (the same as without the jail).
* `git config --local` fails with `EBUSY`: git renames a lockfile over the
  read-only bind of `config`.
* Submodule git dirs (`<common>/modules/*`) are not protected.
* Tools that hard-code `$HOME/.cache` instead of honouring `XDG_CACHE_HOME`
  reach the operator's cache entries through the agy HOME's passthrough
  symlinks, which are read-only in the jail (for example Arbiter's own test
  config, which puts its scratch root under `$HOME/.cache/arbiter/scratch`).
  Use `sandbox.writable_paths` for those.
* Nothing can be handed between the host and the worker through `/tmp`.
* The agy HOME is writable from inside the jail and Arbiter writes into it on
  the host at the next spawn. `ConfigDir` removes a symlink planted where one
  of its own directories or files goes rather than follow it, and the
  toolchain dirs get the same treatment.

## Configuring it

### Per-domain (the common case)

Set it in the workspace `config` JSON under `agent.security` — no source edits,
no touching anyone's `~/.claude`. The default is `:bypass` (headless-safe). To
opt into the interactive classifier (and accept the freeze risk), set
`"mode": "auto"`:

```json
{
  "agent": {
    "type": "claude",
    "config": { "model": "sonnet" },
    "security": {
      "permissions": {
        "mode": "auto",
        "deny": ["Bash(docker:*)"],
        "allow": ["Bash(npm run test:*)"]
      },
      "sandbox": { "filesystem": "worktree", "network": false }
    }
  }
}
```

**⚠️ Deprecated paths — do not use in new configs:**

The following paths are accepted for backward compatibility with old configs
but **must not** be used in new work. Always use the canonical
`agent.security.permissions.mode` path shown above:

- `workspace.config["security"]["mode"]` — **deprecated**
- `workspace.config["agent"]["config"]["security_mode"]` — **deprecated**

These alternate paths exist only to avoid breaking old configs; no new
workspace should rely on them.

### Per-repo override (multi-repo workspaces)

A workspace whose repos need *different* postures — e.g. one repo runs stricter
or with network egress cut — adds a `"repos"` map under `agent.security`, keyed
by the same repo name used in `config["repo_paths"]`. The repo block is layered
over the workspace-wide posture for that repo only; every other repo resolves
the workspace-wide default unchanged. No new config surface — it's the same
generic `config` JSON (`arb config set` / `workspace_config_set`).

```json
{
  "agent": {
    "security": {
      "permissions": { "mode": "auto", "deny": ["Bash(docker:*)"] },
      "sandbox": { "network": true },
      "repos": {
        "device": {
          "permissions": { "mode": "strict", "deny": ["Bash(curl:*)"] },
          "sandbox": { "network": false }
        }
      }
    }
  }
}
```

Here the `device` repo resolves `mode: strict`, `network: false`, and a deny
list of *both* `Bash(docker:*)` (workspace) and `Bash(curl:*)` (repo) — deny
unions across layers, scalars replace. The dispatch threads the resolved repo
name (`Dispatch` `:repo` opt) into `SecurityPolicy.resolve/3`.

### Install-wide default

Override the floor every domain inherits via application config (see
`config/config.exs`):

```elixir
config :arbiter, :worker_security_policy, %{
  "permissions" => %{"mode" => "auto"},
  "sandbox" => %{"network" => false}
}
```

The hardcoded safe baseline lives in `Arbiter.Agents.SecurityPolicy.base/0`.

### Per-task / per-dispatch override

`Arbiter.Worker.Dispatch.dispatch/2` accepts a `:security` map (same shape as
`agent.security`) or a `:security_mode` shorthand, layered last.

### Resolution precedence

`base/0` → `:worker_security_policy` app env → `workspace.config["agent"]["security"]`
→ `workspace.config["agent"]["security"]["repos"][repo]` (only when a repo name
is passed) → per-dispatch override. `allow`/`deny`/`safe_defaults_exclude`
and `sandbox.writable_paths` / `sandbox.egress_tunnels` **union** across layers; `mode` and the other
`sandbox` fields are **replaced** by the highest layer that sets them. `safe_defaults` itself is never set directly —
it is always recomputed as `safe_default_categories() -- safe_defaults_exclude`
after every layer is applied, so it always reflects the current default set
minus whatever any layer has excluded by name. The legacy `safe_defaults`
config key is parsed for backward compatibility but does not affect
resolution.

## How the Claude adapter maps it

`Arbiter.Agents.Claude.Security` translates the normalized policy into the CLI:

* **mode** → `--dangerously-skip-permissions` for `:bypass` (the default);
  `--permission-mode auto|default` for `:auto`/`:strict`. In all modes, deny
  rules are applied via `--settings` — bypass only skips the interactive
  classifier, not the deny list.
* **allow / deny / safe_defaults / sandbox** → an inline
  `--settings '<json>'` permission document (the CLI accepts a JSON string, so
  there is no shared-file race and nothing is read from `~/.claude`).

### No more host inheritance

`Arbiter.Agents.Claude.ConfigDir` runs every worker against an isolated
`CLAUDE_CONFIG_DIR`. It now:

* **never carries the operator's `.credentials.json`** — not symlinked, not
  copied (bd-80ecol): a worker authenticates with its own setup token
  (`CLAUDE_CODE_OAUTH_TOKEN`) or an API key, and a Claude dispatch with neither
  is refused (`Arbiter.Agents.Claude.CredentialCheck`),
* **generates `settings.json`** from the install-default policy — a hardened,
  non-empty-deny floor — instead of symlinking the operator's, and
* writes its own task-focused `CLAUDE.md` (never the operator's persona).

So no worker spawn — worker, reviewer, or bare ad-hoc run — inherits the host
operator's permission posture.

## How the agy (Gemini) adapter maps it

`Arbiter.Agents.Gemini.Security` is the agy analogue of the Claude module above
(bd-7s29yq / T6b). agy has **no** `--settings` flag and **no** config-dir
environment variable: its permission posture comes from
`$HOME/.gemini/antigravity-cli/settings.json` and nothing else. So the mapping
has two halves that must agree:

| Mode      | agy argv                          | generated `toolPermission` | deny enforced? |
| --------- | --------------------------------- | -------------------------- | -------------- |
| `:bypass` | `--dangerously-skip-permissions`  | `always-proceed`           | **yes**        |
| `:auto`   | *(none)*                          | `always-proceed`           | **yes**        |
| `:strict` | *(none)*                          | `proceed-in-sandbox`       | **yes** — and unallowed ⇒ blocked |

`:strict` deliberately maps onto agy's own `"proceed-in-sandbox"` value, not
its `"strict"` value, and omits the `--sandbox` argv flag — see bd-25ivqe
below; both were probed live and the obvious-looking alternative (agy
`toolPermission: "strict"` + `--sandbox`) turned out to auto-deny every tool
call in headless mode regardless of `permissions.allow`.

`Arbiter.Agents.Gemini.ConfigDir` supplies the `$HOME` the settings document
lands in: one directory per worktree under `~/.cache/arbiter/worker-agy/`,
seeded on every spawn with

* the **generated** `settings.json` (never the operator's),
* an Arbiter-owned, persona-forbidding `GEMINI.md`,
* `.gemini/config/mcp_config.json` when the dispatch has an MCP scope token, and
* symlink passthrough for everything else in the operator's `$HOME` *except*
  `.gemini`, `.agents` and `.antigravity` — the three trees agy reads its
  config, memory, skills and plugins from.

The home root itself lives under `~/.cache`, i.e. *inside* the operator's
`$HOME`, so a directory that contains the root (`.cache`, `.cache/arbiter`) is
mirrored as a real directory and its children linked individually rather than
being linked flat — a flat `<home>/.cache -> ~/.cache` would make
`<home>/.cache/arbiter/worker-agy/<key>` resolve back to `<home>`, an unbounded
symlink cycle inside the worker's own `$HOME`.

Rules are rewritten into agy's own grammar (`command(...)`, `read_file(...)`,
`write_file(...)`, `read_url(...)`, `execute_url(...)`). A *bare* Claude tool
name (no `(...)`) maps onto the equivalent whole-path rule where agy has one —
`Write`/`Edit`/`MultiEdit`/`NotebookEdit` → `write_file(/)`, `Read` →
`read_file(/)`, `WebFetch`/`WebSearch` → `read_url(*)`, and
`WebFetch(domain:<host>)` → `read_url(<host>)`. Until bd-80talz the URL rules
were emitted as `url(*)`, which is not an agy rule kind: agy rewrites
`settings.json` on load and silently drops it (probed on 1.2.11), so the
network-off deny and the reviewer's `WebFetch` deny never reached agy. Until
bd-f8f9ln the path rules were emitted as globs (`write_file(**)`,
`write_file(/etc/**)`, `write_file(~/.ssh/**)`), which agy keeps but never
matches; see "Path rules are literal prefixes" below. Every
`write_file`/`read_file` path is now emitted in the form agy matches. A rule
with no agy analogue at all — `Monitor`, `ScheduleWakeup`, for which agy has
no tool-name rule kind — is dropped rather than emitted uninterpretably.

### What was verified live, and what agy does *not* enforce

Probed against the installed `agy` while implementing bd-7s29yq, each with a
throwaway `$HOME`:

* The generated `settings.json` **is** read in place of the operator's, and
  `toolPermission` is echoed verbatim as `init.permission_mode` on the
  stream-json `init` event. `apps/arbiter/test/fixtures/agy_init_strict.json`
  is a real captured event (`permission_mode: "proceed-in-sandbox"`);
  `agy_init_inherited.json` is the pre-fix control (`"always-proceed"`).
* `permissions.deny` is a **hard block in every mode**, including under
  `--dangerously-skip-permissions`: with `deny: ["command(rm)"]`, a
  `rm ./inside.txt` came back `permission check failed for unsandboxed ...` and
  the file survived. This is why `security_enforced?/0` can answer `true`.
* **`toolPermission: "strict"` is a dead end for headless use (bd-25ivqe).**
  This was the original mapping for Arbiter's `:strict` mode, and it looked
  right in review and in unit tests that only asserted on the generated
  settings document — but live, `permissions.allow` is never consulted under
  agy's own `"strict"` value in headless/print mode. A bare `command(arb)`, a
  wildcard `command(*)`, and even the literal full command string all still
  came back auto-denied. Only `always-proceed` (`--dangerously-skip-permissions`)
  let anything through. `apps/arbiter/test/fixtures/agy_run_command_denied.json`
  and `agy_run_command_allowed.json` are real captured `run_command` steps
  pinning the *working* mapping below.
* **`toolPermission: "proceed-in-sandbox"` is the value that actually
  enforces an allowlist headlessly.** Same settings document, only
  `toolPermission` changed: an allow-listed command ran, and a command with
  no matching allow rule was denied with agy's own
  `permission check failed for unsandboxed ...` wording — reported on
  stderr and via `denied_actions` on the `result` event, and it does not hang
  to the print timeout. `:strict` maps onto this value, not agy's own
  `"strict"`, and is genuinely allowlist-only as a result: a `:strict` agy
  worker gets no shell at all unless the workspace policy names the commands
  it may run.
* **`allowNonWorkspaceAccess: false` does not work.** With it set, a
  `touch <outside-the-worktree>/marker` via `run_command` still succeeded, and
  so did a `view_file` read of a file outside the workspace. The key is still
  emitted (it is the documented switch and costs nothing).
* **`write_file(...)` rules *do* gate agy's native `write_to_file`, but only
  as literal path prefixes (bd-f8f9ln, agy 1.2.11).** bd-25ivqe AC6 concluded
  the opposite: a `write_file(**)` deny and a `write_file(<dir>/**)` deny both
  let `write_to_file` through. Re-probed with `toolPermission:
  "proceed-in-sandbox"`, the real cause is two separate things. A glob never
  matches (see the next bullet), and the probe's target was under `/tmp`,
  which agy lets through with no rule at all (see the `/tmp` bullet). A bare
  directory rule works in both directions: `write_file(/tmp)` in `deny`
  blocked a `/tmp` write ("Matches user-configured deny rule"), and
  `write_file(/)` in `deny` blocked an in-worktree write that
  `write_file(<worktree>)` in `allow` would otherwise have let through, so
  deny outranks allow for writes too. The captures are in
  `apps/arbiter/test/fixtures/agy_write_file_rule_matching.json`.
  `disabledTools` (a real `settings.json` key) gates MCP-server tools, not
  agy's own built-ins.
* **Path rules are literal prefixes (bd-f8f9ln).** `write_file(<dir>)`
  allowed `<dir>/sub/a.txt` and refused `<dir>x/a.txt` (the match stops at a
  path-component boundary). `write_file(<dir>/**)` did not match
  `<dir>/a.txt`. `~` is not expanded: `write_file(~/scratch)` in `allow` did
  not allow `$HOME/scratch/j.txt`. `read_file(...)` behaves the same way:
  `read_file(**/.env)` did not stop a `view_file` of `<ws>/.env`, and
  `read_file(<ws>/.env)` did. So `Gemini.Security` strips a trailing
  `*`/`**` segment (`**` alone becomes `/`), and expands `~` against the
  operator's home. A relative glob such as `read_file(**/.env)` has no prefix
  form and is still emitted as is, which means the `:no_secret_reads`
  `read_file` globs do not block anything on agy today.
* **agy lets `/tmp` writes through with no allow rule.** Under
  `"proceed-in-sandbox"`, with an allow list naming only `command(pwd)`, a
  `write_to_file` to `/tmp/<dir>/e.txt` landed, while the same call into the
  trusted workspace itself was soft-denied. This is agy's own scratch
  allowance, not something the settings grant, and an explicit
  `write_file(/tmp)` deny removes it. It is why bd-b67vc2 saw `/tmp` allowed
  and `~/.cache` refused. It no longer matters for the host: every jailed agy
  spawn gets a private tmpfs `/tmp`, so the write never reaches the host.
  `:strict` now allows `write_file(/tmp)` explicitly, so the behaviour no
  longer depends on an agy default.
* **Headless `:strict` soft-denies an un-allowed write, as it does a
  command.** Before bd-f8f9ln a `:strict` agy worker's allow list had no
  `write_file` rule, so its first `write_to_file` into its own worktree came
  back "user denied permission for write_file(...)", with `denied_actions:
  [{"action": "write_file"}]`, and the turn ended (bd-bi3in6, run
  `39f3366f`). `git rev-parse` was soft-denied the same way. See "The
  `:strict` working set" below for the fix.
  **Decided in bd-ca7xko** ([design/agy-strict-write-isolation.md](design/agy-strict-write-isolation.md)):
  refuse `:strict` dispatch to agy until agy runs under a bubblewrap jail
  that makes the worktree the only writable project path (probed live: a
  jailed `write_to_file` outside it fails with `read-only file system`).
  **Landed in bd-5gvqgc:** under `:strict`, `Gemini.default_argv/2` runs
  agy inside the OS write jail (see [The OS write jail](#the-os-write-jail-arbiterworkerjail-bd-5gvqgc-bd-3s82pf))
  and `Gemini.write_confinement/1` answers `:os_jail`, so the gate admits
  agy, on a host that passes `Jail.available?/0` with worker config
  isolation and `sandbox.enabled` on. Where it can't jail, `write_confinement`
  stays `:none` and the adapter itself refuses a `:strict` spawn
  (`{:write_jail_unavailable, reason}`) rather than run agy unconfined, for a
  caller that reaches it without the gate. **Extended in bd-3s82pf: the jail
  is now default-on for agy in `:bypass` and `:auto` too**, keyed on the same
  `sandbox.enabled` / `sandbox.filesystem: :worktree` base default — the
  escape is identical there, so an agy worker in the default mode could
  otherwise still write wherever the operator's user can. Those modes never
  refuse: a host that can't jail just runs agy unjailed, same as before this
  change, with `Gemini.write_jail_warning/1` naming the reason for
  doctor/posture. A worktree-backed agy **review** dispatch also gets its
  worktree bound `--ro-bind` instead of `--bind`, so the reviewer read-only
  posture is an OS guarantee there too. Since bd-f8f9ln the reviewer's
  `write_file(/)` deny is also enforced by agy itself.
* **`--sandbox` disables the allowlist gate under `"proceed-in-sandbox"`
  (bd-25ivqe).** With `--sandbox` on argv, agy runs the command inside a real
  `bwrap` jail and *auto-proceeds* there regardless of `permissions.allow` —
  a command with no matching allow rule that was denied without `--sandbox`
  succeeded with it. Only `permissions.deny` still gated it. `--sandbox` is
  therefore omitted from `:strict`'s argv entirely; the original mapping
  (`--sandbox` + `toolPermission: "strict"`) predates this finding.

As on the Claude side these are *permission-layer* guards inside the agent.
The one exception is the `:strict` write jail above, which is OS isolation
for writes only.

### The `:strict` working set (bd-f8f9ln)

A `:strict` agy spawn only runs inside the OS write jail, so the jail is the
write boundary. agy's own gate must not also refuse the work the jail allows.
Under `:strict`, `Gemini.Security.allow_rules/2` adds:

* `write_file(<worktree>)`, `write_file(/tmp)`, and `write_file(<path>)` for
  each `sandbox.writable_paths` entry (normalized the way the jail normalizes
  them). This is the same set the jail binds writable. The worker's agy
  `$HOME` is also writable in the jail, but it is not allowed here, and its
  `.gemini/antigravity-cli` settings directory is denied outright.
* The commands a worker needs on top of the bootstrap set (`arb`, `git
  status`/`diff`/`log`, `pwd`): `git add`, `commit`, `rev-parse`, `show`,
  `branch`, `checkout`, `switch`, `restore`, `rm`, `mv`, `fetch`, `pull`,
  `push`, `rebase`, `reset`, `stash`, `merge-base`, `ls-files`, `grep`,
  `blame`, and `mix`, `mkdir`, `touch`, `cp`, `mv`, `rm`.

Deny still outranks allow, so `git push --force`, `rm -rf`, `gh pr create` and
the rest of the deny baseline stay blocked. A write outside the allowed set
is refused twice. agy soft-denies it first (captured: an out-of-worktree
write, and a write to a sibling directory that shares the worktree's name as
a prefix, were both refused). If that is ever bypassed (a shell command, a
future agy change), the jail answers `read-only file system`
(`Arbiter.Worker.JailTest`). On 2026-09-29, agy 1.2.13 was probe-verified under
`:strict` (bd-9xiwu1 / chore-68), confirming that writes outside the worktree
and denied tool calls are correctly blocked. On 2026-09-30: on v0.2.2, agy under
`:strict` made Arbiter MCP calls (bd-cy4ls6) and an agy review reached a verdict
(bd-cwe9n2). `:auto` and `:bypass` do not get
the working set: `always-proceed` never consults `allow`.

### Credentials are untouched by the `$HOME` redirect

On a host with a working freedesktop Secret Service, agy keeps its live Google
grant in the **keyring**, which is scoped to the Linux user session and not to
`$HOME` — the T6a spike proved a brand-new `$HOME` with zero credential files
still authenticates. `ConfigDir.keyring_available?/0` detects that and seeds
nothing. Only when no Secret Service is reachable do we **copy** (never
symlink, which a refresh would write back through) `oauth_creds.json`,
`jetski-standalone-oauth-token` and `google_accounts.json`.

## Provider-agnostic by construction

`SecurityPolicy` carries no Claude-specific syntax. The `Arbiter.Agents.Agent`
behaviour contract requires any adapter to:

1. Map the normalized `:security` policy to its provider's mechanism.
2. Enforce a non-empty destructive-op deny baseline (the policy's
   `safe_defaults`) in `:auto` and `:strict` modes.
3. Not fall through to the host operator's personal agent config.
4. Implement `security_enforced?/0` returning `true` once it honors the above.

**Current status:** `Claude` enforces the policy unconditionally
(`security_enforced? = true`). `Gemini` enforces it when — and only when — the
CLI on `PATH` is `agy` *and* worker config isolation is on, since without an
Arbiter-owned `$HOME` there is nowhere to put the generated settings document;
it answers `false` otherwise, including for the upstream `gemini` CLI, which has
no allow/deny mechanism at all. (The upstream Gemini CLI *provider* —
`gemini_cli` accounts, quota and the Providers page entry — was dropped in
bd-ac53wz; only the adapter's own fallback to that binary when `agy` is not on
`PATH` remains, and it still answers `false` here.) `Codex` does not implement the contract yet and
answers `false`. The REST `security_posture.policy_enforced` field reports each
adapter's own answer, so operators can see whether the declared posture is
actually being enforced by the running adapter.

## The worker environment is an allowlist (bd-7r0qrj, GitHub #143)

A worker child used to **inherit the server's whole OS environment** (`Port.open`
/ `System.cmd` only *extend* it) and then had every linked provider account's
credential added on top. A Claude worker could see `ARBITER_CLOAK_KEY`,
`SECRET_KEY_BASE`, `DATABASE_PATH`, `SSH_AUTH_SOCK`, `DBUS_SESSION_BUS_ADDRESS`
and the Codex/Gemini keys. `ARBITER_CLOAK_KEY` plus a readable
`~/.arbiter/arbiter.sqlite3` decrypts every workspace secret and provider
credential; `SECRET_KEY_BASE` is the default MCP token signing key.

`Arbiter.Worker.SpawnEnv` is now the single builder. The child starts from an
**empty** environment (every inherited name that is not allowlisted is
explicitly unset) and receives only:

1. **The allowlist**, copied from the server's env: `PATH`, `HOME`, `USER`,
   `LOGNAME`, `SHELL`; `LANG`, `LANGUAGE`, `LC_*`, `TERM`, `COLORTERM`,
   `NO_COLOR`, `TZ`; `TMPDIR`/`TEMP`/`TMP`; `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
   `XDG_CACHE_HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_DIRS`, `XDG_DATA_DIRS`;
   toolchain homes (`MIX_HOME`, `MIX_ARCHIVES`, `HEX_HOME`, `HEX_MIRROR`,
   `REBAR_CACHE_DIR`, `ERL_AFLAGS`, `ELIXIR_ERL_OPTIONS`, `MISE_DATA_DIR`,
   `MISE_CONFIG_DIR`, `MISE_CACHE_DIR`, `MISE_STATE_DIR`,
   `MISE_TRUSTED_CONFIG_PATHS`, `ASDF_DATA_DIR`, `CARGO_HOME`, `RUSTUP_HOME`,
   `GOPATH`, `GOROOT`, `GOMODCACHE`, `NPM_CONFIG_CACHE`); `gh`/`glab`/`git`
   config locations (`GH_CONFIG_DIR`, `GLAB_CONFIG_DIR`, `GH_HOST`,
   `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM`); TLS/egress
   (`SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE`,
   `REQUESTS_CA_BUNDLE`, `HTTP(S)_PROXY`, `ALL_PROXY`, `NO_PROXY` and their
   lowercase forms); and the `arb` CLI's non-secret endpoints (`ARB_HOST`,
   `ARB_WORKSPACE`). Adding a name needs a reason in the `@exact` comment.
2. **The caller's explicit pairs**: the adapter's `spawn_env/1` (its own
   provider's credential, the isolated `HOME` / `CLAUDE_CONFIG_DIR`), the
   workspace's user-defined `worker_env` (this is where a per-workspace
   `GH_TOKEN` / `GITLAB_TOKEN` comes from), the task-scoped dev-server
   `DATABASE_PATH` / `PORT` (`DevServerEnv`), and `ARB_WORKER_BEAD_ID`.

**Never reaches a worker:** `ARBITER_*` (including `ARBITER_CLOAK_KEY`),
`SECRET_KEY_BASE`, `DATABASE_PATH` / `DATABASE_URL` *of the server*,
`RELEASE_*` / `ROOTDIR` / `BINDIR`, `MIX_ENV`, `SSH_AUTH_SOCK`,
`XDG_RUNTIME_DIR`, and anything else in `~/.arbiter/arbiter.env` that is not
listed above. (`DATABASE_PATH` is still *set* in a worker, but to a per-task
throwaway sqlite file under the temp dir so a worker-started `mix phx.server`
cannot open the live database; it is never the server's value.)

**Credentials are per provider.** A `claude` worker may hold
`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_*`; a `codex` worker `OPENAI_API_KEY` /
`CODEX_API_KEY`; a `gemini` (agy) worker `GEMINI_API_KEY` /
`GOOGLE_GENAI_API_KEY` / `ANTIGRAVITY_API_KEY`. Any *other* provider's
credential is dropped even when the workspace is linked to several accounts
(`WorkerEnv.resolve/1` still resolves all of them; `SpawnEnv` filters). A spawn
with no provider is treated as `claude`.
The filter is applied **at the source** as well as by name: `WorkerEnv.resolve/2`
asks `Credentials.workspace_pairs/2` for only the accounts whose
`ProviderAccount.provider` matches the worker (`gemini` ↔ `antigravity`;
an unknown provider matches nothing), so a credential stored under a
non-standard `env_var` (e.g. a Codex key named `MY_CUSTOM_CODEX_KEY`, or a
numbered pool variant) still never reaches another provider's worker. The
name-based drop stays as defence in depth for ambient and `worker_env` pairs.

**Every agent-CLI spawn** goes through it: implement (`ClaudeSession.start/1`),
review, fix, conflict, the preflight auth probe, the ReviewGate's
`Checks.invoke_reviewer`, `ReviewReply`, the Loop discovery invoker, and the
quota probes (`CloudCode` agy usage, `GrantRefresher`).
`spawn_env_test.exs` pins the inventory.

### Decisions worth knowing

* **`SSH_AUTH_SOCK` is dropped.** git over ssh must use a key file readable in
  `~/.ssh` (passphrase-less, same UID — see the residual risk below), a
  per-repo deploy key, or — preferred — https with a `GH_TOKEN` /
  `GITLAB_TOKEN` set in the workspace's `worker_env`. A workspace that truly
  needs the operator's agent can put `SSH_AUTH_SOCK` in its `worker_env`
  explicitly; that is an opt-in per workspace, not a default.
* **`DBUS_SESSION_BUS_ADDRESS` is dropped, with one exception**: an agy
  (`gemini`) worker gets it when the session bus socket exists, because agy
  keeps its own Google grant in the freedesktop Secret Service
  (`Gemini.ConfigDir.keyring_available?/0`); without the bus a keyring host's
  agy worker is unauthenticated. No other provider receives it.
* **`MIX_ENV` is not inherited**; a worker's `mix` picks its own.
* **Agent-CLI config vars set in the server's env are no longer inherited.**
  An install that exported any of these in `~/.arbiter/arbiter.env` and relied
  on workers picking them up loses that behaviour silently: `ANTHROPIC_BASE_URL`,
  `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CONFIG_DIR` (when
  worker config isolation is off; with isolation on, Arbiter sets its own),
  `CODEX_HOME`, and `XDG_RUNTIME_DIR`. To keep one, set it per workspace in
  `worker_env` — that is now the only route, and it applies to every provider's
  worker in that workspace.

### Residual risk: same UID, same filesystem

Environment scrubbing removes the secrets handed over *for free*. A worker still
runs as the operator's UID, so it can **read `~/.arbiter/arbiter.env` and
`~/.arbiter/arbiter.sqlite3` directly** (and `~/.ssh`, `~/.config/gh`, the agy
isolated `HOME`'s symlinked passthrough of `.ssh` / `.arbiter`, and
`/proc/<server pid>/environ` of any same-UID process outside a PID namespace).
With `ARBITER_CLOAK_KEY` in `arbiter.env` that is the same break as before, just
one `cat` away. Closing it is file-level isolation, not env hygiene: the jail
(bd-7o08mj masks `/run`; bd-8381tk masks `arbiter.env` and the release
cookie for jailed workers, see below; the rest of `~/.arbiter` is follow-up)
and the guardrail-profile work (bd-8apkz6). Until then treat any worker with shell
access as able to reach everything the operator's account can read.

## The server's Erlang distribution (bd-51m9ba, GitHub #156)

The release keeps Erlang distribution on so the operator can still run
`~/.arbiter/current/bin/arbiter rpc '…'` / `remote` (e.g. to disable a
provider account). Distribution is a code-execution channel: anyone who
holds the cookie and can reach epmd and the node's listener runs arbitrary
code in the server, with no MCP token or scope check in the way. Before this
fix epmd and the node listened on `0.0.0.0`, the node was an sname, and the
cookie was the world-readable `releases/COOKIE` that ships inside the
published tarball, so it was the same for every install.

What the release does now (`rel/env.sh.eex`, `rel/vm.args.eex`,
`rel/remote.vm.args.eex`, `restrict_cookie/1` in the root `mix.exs`):

* **Loopback only.** `env.sh` exports `ERL_EPMD_ADDRESS=127.0.0.1`, which an
  inherited value cannot override, and makes the node a long name,
  `arbiter@127.0.0.1` (`RELEASE_DISTRIBUTION=name`). `vm.args` and
  `remote.vm.args` pin `-kernel inet_dist_use_interface {127,0,0,1}`. An sname
  is not an option: it resolves the host name, often to a LAN address, where a
  loopback-only epmd does not answer and `rpc` would break.
* **A per-install cookie.** `env.sh` creates `<data-home>/release.cookie`
  (`ARB_DATA_HOME`, default `~/.arbiter`): 32 random bytes, hex-encoded, under
  `umask 077`, published atomically with `ln`. It exports that file's contents
  as `RELEASE_COOKIE` and runs `chmod 600` on it at every invocation. The
  server, `rpc`, `remote` and `stop` all read the same file, so the operator's
  `rpc` works from the same UID unchanged. An operator-set `RELEASE_COOKIE`
  still wins. If the file can neither be read nor created, the node gets a
  throwaway cookie and a warning on stderr. It never falls back to the
  bundled cookie: losing `rpc` is the safe failure.
* **The bundled `releases/COOKIE` is 0600** after the build
  (`restrict_cookie/1`) and after every start (`env.sh`), even though nothing
  uses it any more.
* **The agy jail shadows the cookie.** `Arbiter.Worker.Jail.secret_files/0`
  binds `/dev/null` over `<data-home>/release.cookie` (alongside the
  bundled `releases/COOKIE` and `arbiter.env`, bd-8381tk) after every writable
  bind. The jail shares the host network, so without this a jailed worker
  could read the cookie and reach epmd over loopback. The jail's escape probe,
  which runs behind `arb doctor`'s "agy jail escape" check, now fails if the
  cookie reads back non-empty. `RELEASE_COOKIE` is not in the worker env
  allowlist (bd-7r0qrj), and the jail's own PID namespace keeps
  `/proc/<server>/environ` out of reach.
* **`arb doctor` checks it.** The "erlang distribution is loopback-only" check
  (`ArbiterCli.Cmd.Doctor.Distribution`) reads `/proc/net/tcp{,6}` for
  listeners on epmd's port and on the `arbiter` node's port, which it gets from
  epmd's `NAMES` reply. It also stats `<data-home>/release.cookie` and
  `<data-home>/current/releases/COOKIE`. It reports each bind address and mode
  it saw and fails (exit 1) on a non-loopback listener or a group- or
  world-readable cookie. It never blocks deploy readiness.

An epmd that was already running keeps its old binding: `ERL_EPMD_ADDRESS`
only applies when epmd starts. Under the systemd unit epmd lives in the
service's cgroup and is restarted with it. Doctor reports one that wasn't.

### Residual risk: same UID, and the command line

* **An unjailed same-UID worker can still get in.** Claude workers are not
  jailed today. They run as the operator's UID, so they can `cat` the 0600
  `~/.arbiter/release.cookie` or read `RELEASE_COOKIE` from
  `/proc/<server pid>/environ`, then run `bin/arbiter rpc` over loopback. File
  modes and loopback binding do nothing against the same UID. Closing this
  needs worker read-masking: G3, hiding sensitive read paths
  (`bd-3q2djr`), and G7, running Claude under the jail (`bd-d2o3xb`). Until
  both land, treat an unjailed worker as able to run code in the server.
* **The cookie appears in the server's command line.** Mix's release script
  passes it as `--cookie`, which becomes `beam.smp … -setcookie <cookie>`.
  Any local user can see it with `ps` unless `/proc` is mounted with
  `hidepid=2`. Distribution is loopback-only now, so this matters only for
  other accounts on the same host. A jailed worker is not affected: it has its
  own PID namespace. Taking the cookie off argv means replacing Mix's
  `bin/arbiter` launcher, which is follow-up work. On a shared host, mount
  `/proc` with `hidepid=2`.

## Where the posture is surfaced

* **`arb prime`** — a `security:` block in the active-workspace section (mode,
  sandbox, deny counts).
* **Dashboard** — a per-worker permission-mode badge on the active workers
  list (ghost for `auto`, warning for `strict`, error for `bypass`).
* **REST** — `GET /api/workspaces/:id` includes a resolved `security_posture`
  object with `provider`, `policy_enforced`, and the full policy summary. This
  is the single source of truth both surfaces read.

## Operator proof for token minting (bd-8381tk)

### The problem

`POST /api/mcp/tokens` used to hand a **coordinator** token to any anonymous
caller on loopback (`ArbiterWeb.Plugs.ApiAuth` then let loopback through
without a bearer token; since bd-asawcq it no longer does, see "Bearer tokens
on every `/api` route" below). Every worker runs on the server's host, so any worker could
make itself coordinator with one `curl`: dispatch, config writes, closing
tickets, installation config. `/mcp` itself always required a bearer token,
so this endpoint was the way in.

The hard part is that workers run **as the operator's own Unix user**.
Whatever proof is chosen has to separate two processes with the same uid.

### Options considered

| Option | Why not (alone) |
|---|---|
| Operator secret in a 0600 file that the CLI reads | Same uid, so the worker reads it too. The jail doesn't restrict reads, and Claude workers are unjailed. A `Read` deny rule is permission-layer only (`python -c open(...)` walks past it). Worse, `arb mcp token mint` run *inside* a worker would read the file automatically. |
| One-time pairing token | Has to be stored somewhere the operator's later commands can read, which is the same-uid problem again. Also adds a setup step to every install. |
| Unix socket with an `SO_PEERCRED` **uid** check | The uid is identical for the operator and every worker, so on its own it proves nothing. |
| **Unix socket + `SO_PEERCRED` pid + where that process came from** | **Chosen.** See below. |

### The mechanism

What *does* differ between the operator and a worker is where the process
came from. Everything Arbiter runs is started by the server's own BEAM:
`beam.smp` → `erl_child_setup` → the agent CLI → its shell → the tools it
runs. The operator's terminal or ssh session is not. Under systemd,
everything the server starts also inherits its service cgroup
(`…/app.slice/arbiter.service`). The operator's shell lives in a terminal
scope or an ssh `session-N.scope`.

`Arbiter.MCP.OperatorSocket` listens on a Unix domain socket (only when the
HTTP endpoint serves). For each connection it reads `SO_PEERCRED`: the
connecting process's pid and uid, recorded by the kernel at `connect()` and
not forgeable by the client. `Arbiter.MCP.OperatorProof.authorize/2` then
requires all of:

1. **the server's uid** (the socket is also 0600 in a 0700 directory);
2. **not descended from the server**: the parent chain is walked through
   `/proc/<pid>/stat`, and reaching the server's own OS pid means refusal;
3. **not inside the server's service cgroup**, when the server runs as a
   `.service` unit (the release). This catches a double-forked orphan that
   `systemd --user` has adopted, which check 2 alone misses. A dev server
   run from a terminal shares that terminal's scope, so the check is skipped
   there, and a dev server's worker that double-forks gets past checks 2
   and 3 (see the same-UID limits below);
4. **not inside an Arbiter session's scope.** Coordinator, refine and login
   sessions are launched as
   `systemd-run --user --scope --unit=arb-session-<id> … tmux new-session -d`
   (`Arbiter.Sessions.launch_argv/2`). The tmux server daemonizes, so its
   processes descend from `systemd --user`, not the server, and their
   cgroup `…/app.slice/arb-session-<id>.scope` is a *sibling* of
   `arbiter.service`. Checks 2 and 3 both miss them by design (that is how
   sessions survive a server restart). So a peer whose cgroup path has any
   segment starting with `arb-session-` (`Arbiter.Sessions.Naming.unit_prefix/0`)
   is refused, `in_session_scope`. This check runs on dev servers too.

Anything unreadable fails closed. No secret is exchanged: running from the
operator's own shell *is* the proof. The request line is read before any
reply, and every mint and refusal is logged with the peer pid.

Socket path, shared by the server and `arb`:
`/run/user/<uid>/arbiter/operator-<port>.sock`, or
`~/.arbiter/run/operator-<port>.sock` on a host without a per-user runtime
dir. `<port>` is the HTTP port, so a dev server and the release don't
collide. `ARB_OPERATOR_SOCKET` overrides the path on both sides. Keep an
override **outside** every worker-writable path: the jail's writable binds
come after its masks and would re-expose it. Set
`config :arbiter, Arbiter.MCP.OperatorSocket, enabled: false` to switch the
listener off. Tokens can then only be minted by a caller that already holds
one.

### Who mints what, now

| Caller | Path | Result |
|---|---|---|
| Anonymous loopback `POST /api/mcp/tokens` (any worker's `curl`) | HTTP | **401, no token, any tier** (403 from bd-8381tk until bd-asawcq moved the refusal into `ApiAuth`). Anonymous minting is removed outright rather than kept at a read-only tier: no caller needed it. |
| Operator: `arb mcp token mint`, `arb init` (no `ARB_TOKEN`) | operator socket | coordinator token (may narrow via `workspace_id`, `can_dispatch`, `ttl`) |
| Operator on another machine | `ssh <host> arb mcp token mint` (socket on the server host), or `ARB_TOKEN` + HTTP | as above |
| Holder of a token (`ARB_TOKEN`, a session's own `arb`) | bearer HTTP | capped at the caller's authority (bd-5b5hq7). Worker and refine callers get 403. |
| Workers and reviewers | minted by the server at dispatch (`Scope.mint_worker`) | unchanged, never self-served |
| Arbiter coordinator/refine sessions | minted by the server at provisioning (`Scope.mint_session` / `mint_refine`) | unchanged |
| `arb mcp token mint` (or a raw socket client) run inside a worker | operator socket | refused: `spawned_by_arbiter`, or `in_arbiter_cgroup` for a double-forked orphan (release / systemd unit only; on a dev server an orphan passes) |
| `arb mcp token mint` (or a raw socket client, with `ARB_SESSION_ID`/`ARB_TOKEN` cleared) run inside an Arbiter session | operator socket | refused: `in_session_scope` |

### What the jail adds

For agy under `Arbiter.Worker.Jail` the refusal is not the only barrier. The
socket isn't reachable at all:

* `/run/user/<uid>` is already a `--tmpfs` (bd-7o08mj), so the default
  socket directory doesn't exist inside the jail. `mask_paths/0` also masks
  the fallback or override directory, because a socket on a read-only bind is
  still connectable.
* `systemd-run --user` fails (the bus is masked), so a jailed worker can't
  leave `arbiter.service` either.
* `Jail.secret_files/0` binds `/dev/null` over the files that would skip
  the proof entirely: `~/.arbiter/arbiter.env` (it holds `SECRET_KEY_BASE`,
  the MCP signing key, so a reader could sign their own coordinator token)
  and the Erlang distribution cookies, `<data-home>/release.cookie` (the
  per-install one, bd-51m9ba) and `$RELEASE_ROOT/releases/COOKIE` (the
  bundled one), which give `bin/arbiter rpc` into the server. The bind sits on a `nodev`
  mount, so reads fail with `EACCES`.

### Verified live (2026-09-30)

These checks ran from a real worker of the live release. The listener was
the real `OperatorSocket` running this branch's code, with its policy's
server pid set to the live Arbiter BEAM. The client was the real `arb`
escript built from this branch:

* **This worker's shell** (descendant of the live server BEAM): refused,
  `spawned_by_arbiter`.
* **The same shell after a `setsid -f` double fork** (parent is now
  `systemd --user`): refused, `in_arbiter_cgroup`.
* **Inside the real `Jail.argv`**: `arb` gets `enoent` for the socket,
  `systemd-run --user` can't reach a bus, and both secret files read
  `Permission denied`.
* **A daemonized process inside a real `arb-session-*` scope**, the
  `systemd-run --user --scope --unit=arb-session-<id>` shape sessions use,
  with a `setsid -f` child standing in for the tmux server (its parent is
  not the BEAM and its cgroup is not the BEAM's): refused,
  `in_session_scope`. This is the opt-in test
  `mix test --include live_systemd test/arbiter/mcp/operator_proof_test.exs`
  in `apps/arbiter`, run from a worker with `XDG_RUNTIME_DIR` set. It calls
  `OperatorProof.authorize/2` directly, not through the socket.
* **A transient `systemd-run --user` service** (outside the server's tree and
  cgroup, which is where the operator's shell sits): got a coordinator token,
  and `Scope.from_token/1` decoded it as `tier: :coordinator`.

### Same-UID reasoning: what this does and does not buy

* **Jailed workers (agy): a real boundary for minting.** They can't reach the
  socket, can't leave the cgroup through the bus, and can't read the signing
  key or the cookie.
* **Unjailed workers (Claude today): a guardrail against the paths an agent
  actually takes**: `arb mcp token mint`, `curl` to the HTTP route, a script
  that connects to the socket, a backgrounded or double-forked child. They
  are **not** a hard boundary. A same-uid process with full host access can
  still escape on purpose: run itself as a transient unit with
  `systemd-run --user` (the last demo above is exactly that), move itself to
  another cgroup under the user's delegated subtree, `ptrace` the operator's
  shell (`kernel.yama.ptrace_scope` was 0 on the host this was verified on), or read
  `~/.arbiter/arbiter.env` directly and sign its own token. Closing that
  takes the OS jail for Claude workers (G7 in
  [design/guardrail-profiles.md](design/guardrail-profiles.md)), or a
  separate Unix user.
* **The operator versus a coordinator session they started themselves** (a
  Claude Code session in their own terminal) is not separated. That session
  is operator-delegated. Arbiter-provisioned sessions are separated by
  check 4: their processes run in an `arb-session-<id>.scope`, and the
  socket refuses that scope. Sessions are unjailed, so this is the same kind
  of guardrail as for unjailed workers: a session process that re-launches
  itself into a differently named unit on purpose gets past it.
* **A dev server's double-forked orphan is not refused.** Check 3 only
  applies when the server runs as a `.service` unit. A worker of a dev
  server (`mix phx.server` from a terminal) that runs `setsid -f` ends up
  reparented to `systemd --user` in the terminal's own scope, so it passes
  checks 2 and 3. Run the release as `arbiter.service` for the full check.

### Known open gaps (not fixed here)

* **Erlang distribution** is now loopback-only with a per-install 0600
  cookie (bd-51m9ba, see "The server's Erlang distribution" above). An
  unjailed same-UID worker can still read that cookie and `bin/arbiter rpc`
  into the server; the jail's cookie mask covers jailed workers only.
* **pid reuse between `connect()` and the `/proc` walk** is theoretically
  possible. A reused pid would belong to a process the attacker doesn't
  control, and a worker-spawned reuser would still be caught by the cgroup
  check.

### Migration

* Existing `.mcp.json` files keep working. Tokens that were already minted
  are still validly signed until they expire (30 days by default) or the
  signing key rotates.
* To refresh an `arb init` checkout's token, run `arb init --force` in that
  checkout **from your own shell**, or mint with `arb mcp token mint --json`
  and replace the `Authorization: Bearer …` value in `.mcp.json`. An
  `arb init` run from inside a worker or session now writes the
  `REPLACE_WITH_COORDINATOR_TOKEN` placeholder instead of a real token.
* Scripts that minted with a bare `curl -X POST /api/mcp/tokens` must switch
  to `arb mcp token mint --json | jq -r .token`, run on the server host.
* Tokens may already have been minted by workers through the old anonymous
  route, so rotate the signing key once after deploying. This invalidates
  every outstanding token:
  1. Generate a new key (`openssl rand -base64 64 | tr -d '\n'`) and replace
     `SECRET_KEY_BASE` in `~/.arbiter/arbiter.env`. If
     `config :arbiter, Arbiter.MCP, secret:` is set, rotate that instead;
     it takes precedence for token signing.
  2. `systemctl --user restart arbiter`.
  3. Re-mint every coordinator token (`arb mcp token mint`, `arb init
     --force`) and update each `.mcp.json` and `ARB_TOKEN`. Running
     Arbiter sessions hold tokens signed with the old key, so restart them.
     Workers get fresh tokens at their next dispatch.

## Bearer tokens on every `/api` route (bd-asawcq)

### The problem

bd-8381tk closed anonymous **minting**, but `ArbiterWeb.Plugs.ApiAuth` still
let any loopback caller with no `Authorization` header through to every other
`/api` route. Loopback is not an identity: every worker runs on this host as
the operator's Unix user. So any worker's plain `curl` could dispatch, PATCH
workspace config, close or reopen tickets, apply Loop proposals, pause the
scheduler or read every workspace's tickets. On live v0.2.6 an anonymous
`GET /api/issues/<id>` answered 200, and an anonymous
`PATCH /api/workspaces/default/config` answered 422, a validation error, so
the request had got past auth.

### The mechanism

* **No anonymous loopback.** `ApiAuth` authenticates first. A request with
  no `Authorization` header reaches only routes `ArbiterWeb.ApiPolicy`
  classifies `:anonymous`; everything else answers **401**, on loopback
  exactly like off it. A header that is present but expired, revoked or
  malformed is 401 too. It is never downgraded to anonymous.
* **Per-route tier and scope.** `ArbiterWeb.ApiPolicy` is one explicit table
  keyed by verb and router pattern, with no implicit default: a route
  missing from it is refused 403. A valid token the route's policy refuses
  is **403**. The checks mirror the MCP tools: dispatch needs a
  coordinator token with `can_dispatch` (like `worker_dispatch`); a
  worker token may read tickets in its own workspace, update **its own**
  task's progress fields (like `ticket_update_progress`), file a follow-up as
  a child of its own task, read its own mailbox and send mail as itself. It
  can do nothing else. A refine token gets read-only access over REST, since
  its writes exist only as subtree-gated MCP tools.
* **Anonymous routes, and why.** Only two, both read-only and free of
  secrets and workspace data:

  | Route | Why it stays anonymous |
  |---|---|
  | `GET /api/version` | Version and build sha. `arb server deploy`/`arb update` poll it across a restart, and `arb doctor` compares it before any token exists. |
  | `GET /api/server/migrations` | Pending-migration count only. Deploy readiness and `arb doctor` read it the same way. |

  Every other route, the other `/api/server/*` health reads included, needs a
  token: they name credential paths, accounts and repos.
* **`arb` always sends a token.** `ArbiterCli.Client` uses `ARB_TOKEN` when
  set. Inside an Arbiter session it uses the session's own token
  (bd-5b5hq7). Otherwise, against this machine's server, it mints a
  one-hour coordinator token over the operator socket on its first request
  and reuses it for the rest of the invocation, re-minting once if it
  expires mid-run. The token lives only in that process's memory, never on
  disk where a same-user worker could read it. Every `arb` verb keeps
  working from the operator's own shell with no setup. If the socket
  refuses, which it does for a worker or a session without its own token,
  the request goes out without a token and the 401's hint says why.
* **Workers carry their own token.** Every agent spawn that works a task
  (dispatch, CI fix pass, conflict resolver, ReviewGate's revise-round
  implementer) gets the task's worker-tier token as `ARB_TOKEN`. It is the
  same token as its `.mcp.json`, so its `arb inbox`, `arb message` and
  `arb ticket update` authenticate as that one task. A ReviewGate reviewer
  gets none: it only reads the diff and prints a verdict. The server's own
  `ARB_TOKEN`, if the operator exported one, is never inherited
  (`Arbiter.Worker.SpawnEnv`).
* **The dashboard is unaffected.** It is the `:browser` pipeline plus the
  LiveView socket and calls the domain in-process, so it sends no bearer
  token and needs none. `/events` and `/mcp` already did their own token
  checks.
* **`arb doctor` checks it.** The "anonymous /api access refused" check
  sends two probes with no token: `PATCH /api/workspaces/<nonexistent>/config`
  with `{}`, and `GET /api/issues`. Neither changes anything, even on a
  server that lets them through. Anything but 401/403 fails the check and
  exits 1.

`ArbiterWeb.ApiPolicyTest` iterates the router. A new `/api` route with no
entry in the table fails it, and so does any write route an anonymous loopback
request isn't refused on. `ArbiterWeb.ApiTierTest` covers the tier and scope
checks.

### What this does and does not buy

The same-UID limits from bd-8381tk apply unchanged. A worker that escapes
its spawn tree on purpose (a transient `systemd-run --user` unit) can still
mint over the operator socket, and an unjailed one can read
`~/.arbiter/arbiter.env` and sign its own token. What is gone is the
zero-effort path: a worker's `curl`, or its own `arb` with `ARB_TOKEN`
unset, is no longer coordinator-equivalent.

### Migration

* Scripts that `curl` `/api` without a token must send
  `Authorization: Bearer $(arb mcp token mint --json | jq -r .token)`, run on
  the server host.
* An `arb` older than this release still works from the operator's shell
  only with `ARB_TOKEN` set. Upgrade it alongside the server.

## Related: the durable log root is secret-bearing

Worker output — including each run's archived session JSONL — lands in
`output_log_root` (default `~/dev/arbiter-worker-logs`). Archives are redacted
on ingest through `Arbiter.Redaction`, but that only covers secrets a human
marked; a key printed by a subprocess is not covered. The root is therefore
also protected by filesystem permissions (`0700` root, `0600` archives) and
must be treated as secret-bearing storage. See `docs/session-archive.md`.
