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
    writable_paths: []          # extra writable paths inside the OS write jail
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

**Known, accepted gaps** (the threat model is a misdirected same-user agent,
not a hostile kernel exploit):

* The network is shared: `arb`, MCP and `git push` need it.
  `sandbox.network: false` is still only the tool-level deny. The
  enforcement design is
  [design/guardrail-profiles.md](design/guardrail-profiles.md) §4.
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
and `sandbox.writable_paths` **union** across layers; `mode` and the other
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

### Residual risk: same UID, same filesystem

Environment scrubbing removes the secrets handed over *for free*. A worker still
runs as the operator's UID, so it can **read `~/.arbiter/arbiter.env` and
`~/.arbiter/arbiter.sqlite3` directly** (and `~/.ssh`, `~/.config/gh`, the agy
isolated `HOME`'s symlinked passthrough of `.ssh` / `.arbiter`, and
`/proc/<server pid>/environ` of any same-UID process outside a PID namespace).
With `ARBITER_CLOAK_KEY` in `arbiter.env` that is the same break as before, just
one `cat` away. Closing it is file-level isolation, not env hygiene: the jail
(bd-7o08mj masks `/run`; hiding `~/.arbiter` is its follow-up) and the
guardrail-profile work (bd-8apkz6). Until then treat any worker with shell
access as able to reach everything the operator's account can read.

## Where the posture is surfaced

* **`arb prime`** — a `security:` block in the active-workspace section (mode,
  sandbox, deny counts).
* **Dashboard** — a per-worker permission-mode badge on the active workers
  list (ghost for `auto`, warning for `strict`, error for `bypass`).
* **REST** — `GET /api/workspaces/:id` includes a resolved `security_posture`
  object with `provider`, `policy_enforced`, and the full policy summary. This
  is the single source of truth both surfaces read.

## Related: the durable log root is secret-bearing

Worker output — including each run's archived session JSONL — lands in
`output_log_root` (default `~/dev/arbiter-worker-logs`). Archives are redacted
on ingest through `Arbiter.Redaction`, but that only covers secrets a human
marked; a key printed by a subprocess is not covered. The root is therefore
also protected by filesystem permissions (`0700` root, `0600` archives) and
must be treated as secret-bearing storage. See `docs/session-archive.md`.
