# Rootless podman as a worker sandbox backend: decision

**Task:** bd-jk49nc (decision spike, GitHub #203) · **Builds on:**
[guardrail-profiles](guardrail-profiles.md) (bd-8apkz6),
[agy `:strict` write isolation](agy-strict-write-isolation.md) (bd-ca7xko),
bd-5gvqgc, bd-3s82pf · **Status:** proposed 2026-10-02. Nothing here is
implemented. No production code or config changed; the measurements ran
against scratch clones under `/tmp`. The ticket plan is in
[§7.3](#73-ticket-breakdown).

## Decision

1. **Containers: yes, as a second backend behind `sandbox.backend: bwrap |
   podman`, and used first for the providers that have no jail at all, Claude
   and Codex (G7, G8).** agy stays on bwrap, where G6 has already shipped and
   where its Secret Service keyring auth is easier to serve. A container is
   default-deny for files, env, sockets, processes and users, and the
   incident list that motivated this spike (bd-7o08mj, bd-7r0qrj, bd-51m9ba,
   bd-3t973v) is exactly what a default-deny boundary removes by construction.
   It is not a replacement for the policy layer (G11 to G19), the egress proxy
   (G5) or the bridge identity work (G9); all of those are needed either way.
2. **Not before the target host passes the doctor check.** Everything below
   was measured on the Fedora 44 laptop (podman 5.8.7, crun, netavark, pasta,
   SELinux enforcing). This installation has no EC2 access (operator,
   2026-10-02), so the former "check the EC2" gate is now **`arb server
   doctor` on the target host**: its `podman sandbox readiness` check
   (`Arbiter.Worker.PodmanReadiness`, P1) reports each prerequisite with a hint
   per failure. A RHEL 8 host would run podman 4.9.4 with slirp4netns,
   fuse-overlayfs and, by default, cgroups v1 (package inventory from Rocky
   8.10, [§2.4](#24-build-rebuild-and-versioning-laptop-and-ec2)); the items
   expected to differ are listed in [Appendix B](#appendix-b-expected-rhel-8-differences).
   If the check fails on a host, that host stays on bwrap for G7 and G8.
3. **Per-repo dev images: yes, but keyed by toolchain, not by repo.** One
   shared base image (OS, git, build tools, `procps`, `socat`, the provider
   CLIs and `arb`), plus a thin toolchain layer per distinct `(Erlang, Elixir,
   Node)` tuple. Arbiter and vstim today want the same tuple, so they share an
   image; tonic wants a different one. A repo maps to an image through its
   `.arbiter/Containerfile` (toolchain only, built from the default branch,
   never from a worker's branch). Mise-at-start and a fat image are worse
   ([§2.1](#21-the-unit-of-an-image)).
4. **"Just mount the worktree?" No. Mount a private clone, not the
   registered worktree.** The exact set ([§3.2](#32-the-recommended-mount-set)):
   - the worker's own checkout **with its own `.git` directory**, read-write;
   - the main repo's `objects/` directory, **read-only**, reached through
     `objects/info/alternates` (`:O`, so no SELinux relabel of the host
     checkout);
   - a per-run HOME, a per-run deps cache copy, and a per-run `CLAUDE_CONFIG_DIR`
     (all read-write, all private);
   - an optional per-run bridge socket directory and an optional deploy-key
     secret.

   Nothing else from the host is visible. A *registered* worktree needs eight
   mounts including the shared `refs/` and `logs/` read-write, and the probe
   showed that lets the worker rewrite a sibling worktree's branch.
5. **The measured cost is small where it matters.** A warm container starts
   in about 0.25 s against about 0.01 s for bwrap; a fresh image pays a
   one-off 3.5 to 6 s the first time a UID-mapped run uses it. Against a
   workload of minutes per ticket that is noise. Toolchain times (deps
   compile, `mix test`) matched bwrap within run-to-run variation
   ([§6](#6-measurements)).
6. **What it does not fix:** SELinux makes host-owned sockets unreachable
   from `container_t`, so the Arbiter and proxy bridges need
   `--security-opt label=disable`, which drops the SELinux half of the
   isolation (the user namespace, capability drop and mount namespace
   remain). That trade-off is the main open question
   ([§5.3](#53-selinux-and-the-bridge-sockets)).

## Why

The question (operator, 2026-10-01) was whether a container would be simpler
and safer than the bwrap jail plus its growing list of masks. The answer
splits:

- **Safer: yes.** `Jail.argv/2` starts from `--ro-bind / /` and subtracts
  (`mask_args`, `secret_files`, the keyring proxy, the ssh shadow config, the
  `/run/user`, `/run/dbus` and resolver tmpfs masks). Every incident in the
  list was a path or socket the denylist had not named yet. A container starts
  from an empty root and adds, so an unnamed path is invisible, not exposed.
- **Simpler: partly.** The masks, G3 and the G2-style env allowlist mostly
  disappear for container workers. What replaces them is image lifecycle,
  git layout, credential seeding and SELinux handling. Those are new surface,
  and several have sharp edges (all found while probing, listed in
  [Appendix A](#appendix-a-probes)).
- **Claude runs unjailed today.** `claude.ex` documents `write_confinement:
  :permission_layer` and never calls `Jail.wrap`; the worker that wrote this
  document was itself one (`--dangerously-skip-permissions`, operator UID).
  The biggest exposure is therefore the provider that carries most of the
  load, which is why G7 is the right first customer.

## 1. Prior art

Containers were considered twice and rejected both times on the same
grounds, which were about cost for a single new binary, not about security.

| Where | Verdict | Reason given |
|---|---|---|
| [agy-strict-write-isolation.md](agy-strict-write-isolation.md), option 2'' (bd-ca7xko) | "No, for now" | "High: image per toolchain, keyring over D-Bus into the container, UID mapping on bind mounts. Heavier start-up per spawn. Duplicates what bwrap does with one binary." |
| [guardrail-profiles.md §4.2](guardrail-profiles.md), E6 | Rejected, "as in bd-ca7xko (2'')" | "An image per toolchain, the keyring passed into the container, UID mapping on binds. Heavier start-up." Recorded for the RHEL 8 column: "podman itself not queried" |
| bd-5gvqgc, bd-3s82pf (the bwrap jail and its default-on rollout) | Not considered | Both took bd-ca7xko's decision as given. |

Those rejections were scoped to **agy** and to **egress**, when the open
problem was one write-escape in one provider. Three things have changed:

1. The jail grew from one escape fix into a denylist of masks, and the week's
   incidents were all denylist misses.
2. The next two jail tickets (G7, G8) put the two largest providers behind
   the same denylist, so the denylist's maintenance cost multiplies.
3. The probes here answer the original objections with numbers: UID mapping
   is one flag (`--userns=keep-id`), start-up is 0.25 s, and the keyring
   objection is real but only applies to agy, which this proposal leaves on
   bwrap.

## 2. Per-repo dev images (the operator's first question)

### 2.1 The unit of an image

| Option | Shape | For | Against | Verdict |
|---|---|---|---|---|
| **A. One image per repo** | `arbiter-dev/arbiter`, `.../vstim`, `.../tonic`, ... | Simple mental model; each repo owns its file | Arbiter and vstim want the same Erlang 28.2 and Elixir 1.19.4, so two identical builds. The CLIs and OS layer are duplicated and drift apart. Three of five repos are not BEAM repos at all (see 2.3) | **Close, but wrong unit** |
| **B. Shared base + toolchain layer per distinct tuple** | `base` (OS, git, procps, socat, CLIs) → `beam-1.19.4-28.2`, `beam-1.17.3-27.1.2`, `nix`, `kube` | One CLI/OS surface to patch; identical toolchains built once; layers cache | Needs a mapping from repo to tuple (a config line) | **Chosen** |
| **C. Shared base + mise installs from `.tool-versions` at container start** | One image; the worker pays the install each run | No image per toolchain to track | Only tonic has a `.tool-versions`. Arbiter and vstim take versions from the *global* `~/.config/mise/config.toml` (elixir 1.19.4, erlang 28.2) and Arbiter's CI pins OTP 28.5, so three sources disagree already. Installing Erlang at start is minutes per run unless precompiled (not measured). Needs network at start, which `--network=none` forbids | Rejected |
| **D. One fat image with every runtime** | Everything, all versions | One build | ~GBs; one CVE rebuilds all; every worker gets every tool (reach the profile design wants to withhold, G14) | Rejected |

Measured sizes (Debian 12 `hexpm/elixir` base, `build-essential`, `git`,
`procps`, `bc`, `socat`, `sqlite3`, `nodejs`, `npm`): the image is **777 MB**
and the `claude` binary adds **244 MB**. The base pull took 5.3 s; building
the apt layer took 49 to 66 s; the `claude` layer 6.8 s.

### 2.2 Where the definition lives

Split it by who can be trusted with the content:

| Concern | Lives in | Why |
|---|---|---|
| Toolchain: base image reference, `apt` packages, runtime versions | **The repo**: `.arbiter/Containerfile` (optional; Arbiter ships a default generated from the repo's pin file) | It versions with the code that needs it and is reviewed in the same PR as a version bump |
| Everything that decides **reach**: mounts, network policy, which secrets, env, the tier | **Arbiter config** (workspace and profile layers, G11) | Repo content is worker-writable. A worker on a branch can edit the file |
| Which provider CLIs are present | **Arbiter**: a base-image layer or a read-only versioned CLI dir | `claude` shipped three versions in four days (2.1.285 to 2.1.287); baking it into every per-repo layer forces rebuilds |

**Rule:** an image is built only from the **default branch's** copy of
`.arbiter/Containerfile`, by Arbiter, never from a worker's branch. A worker
that edits the file changes nothing until a human merges it. The build itself
runs unprivileged and with the network, so it is a supply-chain surface
(`hexpm/elixir` and the apt mirrors); pin the base by digest, as tonic already
does for `pgsty/silo`.

tonic already has two image pipelines to reuse: `registry.gitlab.com/emricare/tonic/build_base:1.17.3`
and `test_runner:1.17.3` (its Dockerfile and `.gitlab-ci.yml`). vstim keeps
`Dockerfile.worker` and `ci/docker_files/`.

### 2.3 What each repo needs

Read from the repos on the laptop on 2026-10-02.

| Repo | Runtimes | Services for tests | Notes |
|---|---|---|---|
| **arbiter** (umbrella: `arbiter`, `arbiter_web`, `arbiter_cli`, `arbiter_release_env`) | Elixir 1.19.4, Erlang 28.2 (global mise config; `mix.exs` says `~> 1.15`; CI pins OTP **28.5**). Node for assets (esbuild and tailwind binaries come from `mix`). C toolchain for `exqlite` | **None.** SQLite. `compose.yml` has a Postgres on 5433 for dev only; tests do not use it | In-container tests need `procps` (`pgrep`, used by `OsProcess` and `teardown_test.exs`), `git`, `tmux`/systemd tests are excluded by tag. `mdex_native` downloads a precompiled NIF at build, which needs network at *image* build time |
| **vstim** (`~/dev/trading/vstim`) | Elixir `~> 1.18` (Dockerfile.worker: 1.19.4-erlang-28.2), Node (`assets/package.json`) | **Postgres 15** (compose) / **16** (`.gitlab-ci.yml`, `postgres:16-alpine`), nginx for dev only | No `.tool-versions`. Workers can reach prod through SSH today (vs-adx9r7, guardrail-profiles); under a container that reach disappears unless G14 grants it |
| **emricare/tonic** | Elixir **1.17.3**, Erlang **27.1.2** (`.tool-versions`); Node via assets | **Postgres 15** and an S3-compatible store (`pgsty/silo`) per `docker-compose.yml` | PHI repo; its own CI image `test_runner:1.17.3`. Pinned compose uses a bind of `../tonic_database` and `../db_socket` outside the repo |
| **emricare/tonic_device** | **Nix** (NixOS modules, `tests/` as Nix VM tests, `hosts/`, `secrets/` with age keys) | Nix VM tests need KVM and `/dev/kvm`, which a default container does not have | Not a BEAM repo. Needs a `nix` image; may be a poor fit for rootless containers (nested virtualisation, `secrets/`) |
| **mesaana** | Kubernetes manifests (`infra/`, `namespaces/`); `kubectl`, `helm` | None for tests | Mostly docs and manifests; the container's value here is withholding cluster credentials |

CLIs the base image needs: `claude` (a 244 MB dynamically linked bun binary;
ran on glibc 2.36 without change), `codex`, `agy`, `grok` (no adapter exists:
only a disabled login recipe in `accounts/login_recipes.ex`), `gh`, `glab`
and `arb`. `arb` is an **escript**, so the image needs Erlang (it already
has it for BEAM repos, but the `kube` and `nix` images would need it too).

### 2.4 Build, rebuild and versioning, laptop and EC2

- **Tag by content, not by name.** `arbiter-dev/<toolchain>:<hash12>` where
  the hash covers the Containerfile, the pin file, and the base-image digest.
  A changed `.tool-versions` (or the mise config line, or the Containerfile)
  changes the hash; an unchanged one reuses the image.
- **Lazy build with single-flight** at dispatch: if the tag is missing, one
  build runs and the dispatch waits (build is 1 to 2 minutes when the base is
  cached). The probe's first build including the apt layer was 66 s.
- **Lockfile changes do not rebuild the image.** `mix.lock` changes the *deps
  cache*, which lives outside the image ([§3.3](#33-deps-and-build-caches)).
- **Weekly base refresh** for OS security updates, plus `podman image prune`
  of tags older than two refreshes.
- **Laptop:** rootless podman is installed and already pulls `hexpm`, `debian`
  and `ubi` images. **RHEL 8 (EC2):** unverified; run the doctor check on the host. From the Rocky 8.10 package
  inventory (`container-tools:rhel8`): podman **4.9.4**, crun 1.14.3,
  fuse-overlayfs 1.13, netavark 1.10.3, slirp4netns 1.2.3, skopeo 1.14.6,
  socat 1.7.4.1. **Not packaged:** `passt`/`pasta`, `xdg-dbus-proxy`.
  Consequences:
  - Use `--network=none` plus the socket bridge (§5), which needs neither
    pasta nor slirp4netns.
  - Rootless overlay on a 4.18 kernel needs `fuse-overlayfs`, which is
    slower on many small files (`_build`, `deps`). Not measured.
  - RHEL 8 mounts cgroups v1 by default, so rootless `--memory` and
    `--pids-limit` may be unavailable. Not measured.
  - `/etc/subuid` and `/etc/subgid` entries must exist for the user.
  - The two-host check bd-8xy1mf did for bwrap must be repeated for podman (P1).

**Implemented (P4, bd-9r5jdt).** `Arbiter.Worker.Image` plans an image from
the default branch's committed tree (`origin/<default>`, else the local branch;
read with `git cat-file`, never a worktree) and builds it from an **empty
context**. Two layers: `localhost/arbiter-dev/base:<hash>` (Debian trixie,
`git`, `procps`, `socat`, `build-essential`, an empty `/opt/arbiter/cli` on
`PATH` for a versioned read-only provider-CLI mount) and
`localhost/arbiter-dev/<name>:<hash>` (`FROM ${ARBITER_BASE}`). Every external
`FROM` is rewritten to `ref@sha256:…` through a pin store
(`~/.arbiter/images/pins.json`); an unpinnable `FROM` refuses the build. The
default toolchain Containerfile copies `/usr/local` out of
`library/elixir:<v>-otp-<major>-slim` (and `library/node` when `.tool-versions`
names one), so the base's Debian release must be at least as new as that
image's: bookworm's glibc 2.36 fails `beam.smp` (found by the opt-in
`image_podman_test.exs`). `Image.Builder` is the single flight per tag; the
`Refresher` re-resolves the pins weekly and prunes (newest two per name; `rmi`
is never forced). `arb image list|build|refresh|prune`. Not done here: eager
rebuild after a refresh (images rebuild on next use), the provider CLIs
themselves (P7 mounts them), and dispatch calling `Image.ensure/3` (P7).

## 3. The mount strategy (the operator's second question)

### 3.1 What a worktree actually is

A linked worktree's `.git` is a **file**: `gitdir:
<main>/.git/worktrees/<name>`. That directory holds the per-worktree `HEAD`,
`index` and `commondir`; everything else (objects, refs, config, hooks,
packed-refs, reflogs) lives in the **common dir**. Mounting only the
worktree directory therefore gives a checkout that is not a repository:
`fatal: not a git repository` (reproduced).

Today's bwrap jail binds the **entire common dir read-write**, with `hooks`,
`config` and `worktrees` read-only (`Jail.git_args/2`). That is already wider
than the worker needs: any jailed process can rewrite any branch ref.

### 3.2 The recommended mount set

Three layouts were built and run on scratch repos (a bare stand-in for the
main repo, never the live checkout). `git commit` and `git push` were run
inside rootless containers in each.

| Layout | Mounts | Writable that is not the worker's | Probe result |
|---|---|---|---|
| **A. Registered worktree, minimal** | worktree rw; `common/worktrees/<name>` rw; `common/refs` rw; `common/logs` rw; `common/objects` ro (or `GIT_OBJECT_DIRECTORY` + `GIT_ALTERNATE_OBJECT_DIRECTORIES`); `HEAD`, `config`, `packed-refs` ro | **Every ref**, so every sibling worktree's branch | Commit works only with all eight. Missing `logs/` fails the commit; missing the objects redirect fails with "unable to create". **`git update-ref refs/heads/<sibling>` succeeded** from inside. Deleting a packed ref failed only because `packed-refs` was read-only |
| **B. Private clone, shared objects read-only (`git clone --shared`)** | worktree incl. its own `.git` rw; `main/objects` ro | **None** | Commit, `git cat-file` of history, and `git push` to a mounted bare remote all worked; writing into the shared objects returned EROFS |
| **C. Private clone, own object store (`git clone --no-hardlinks --bare`)** | one rw directory | None | Works trivially. Costs 0.10 s and 37 MB for this repo (pack is 33 MB, 980 branches); `--shared` costs 0.18 to 0.33 s and 428 KB. `--local` (hardlinks) is **rejected**: a worker could chmod and overwrite a shared object file in place, and it fails across filesystems anyway |

**Recommended: layout B.** The mount set, per worker:

| Mount | Mode | Notes |
|---|---|---|
| `<worker checkout>` → same absolute path | rw | Contains its own `.git/` directory. The `.git` gitdir has `objects/info/alternates` pointing at the main repo's objects |
| `<worker checkout>/.git` → same absolute path | rw, a mount of its own | Added by P5: a mount point cannot be renamed away or replaced by a `gitdir:` file |
| `.git/config`, `.git/hooks`, `.git/commondir`, `.git/objects/info/alternates` | **ro**, on top | Added by P5: host-side git keeps running in this checkout after the container exits, so a planted hook, `core.fsmonitor`, alternates path or `commondir` would run on the host. `commondir` is a `"."` guard file the clone is created with, so there is something to make read-only |
| `<main>/.git/objects` → same absolute path | **ro, `:O`** | Overlay mount: readable with no SELinux relabel of the main checkout, writes (there are none, git writes to the private store) land in a throwaway upper layer |
| per-run HOME | rw | A fresh directory; holds `.mix`, `.hex`, caches, the provider config dir |
| per-run deps cache copy | rw | Seeded from the image-keyed cache ([§3.3](#33-deps-and-build-caches)); lives inside the checkout (`deps/`, `_build/`) |
| per-run bridge dir | rw | One unix socket per bridge (proxy, Arbiter) from `Egress.JailRun`; `:z`-free thanks to `label=disable` ([§5.3](#53-selinux-and-the-bridge-sockets)) |
| deploy key | ro (`--secret`) | Only when the ticket declares a push grant (G16) |

Not mounted, so not visible: `~/.ssh`, `~/.arbiter` (the install DB, cookie,
`arbiter.env`), `/run/user/$UID` (the D-Bus and keyring sockets), the
resolver socket, the main checkout's working files, other worktrees, other
workspaces' repos, and the host environment. This is what G3 lists as masks.

**What layout B costs Arbiter.** Arbiter creates worktrees with `git worktree
add` (`worktree.ex:100`, `:283`, `:586`) and cleans with `worktree remove` and
`prune` (`:611`, `:639`, `:1058`); `Reviews.Checkout` and `Sessions.RepoCheckout`
add detached worktrees too. A worker branch in layout B is **not** known to the
main repo until it is fetched back (`git -C <main> fetch <checkout>
<branch>:<branch>`, or the worker's own push). So:

- worktree creation becomes `git clone --shared --no-checkout` + alternates +
  checkout, still on the host, still before spawn;
- cleanup becomes `rm` of the checkout (no `worktree remove` or `prune`);
- anything that reads worker commits from the main repo (ReviewGate diffs,
  MergeQueue, PrimarySync) needs a sync-back step after the run, or reads from
  the checkout path as it already mostly does;
- the main repo must not `git gc --prune` objects a live worker still
  borrows. Objects reachable from `origin/main` are safe; the risk is a
  rewritten history while a worker is mid-run. Mitigation: set
  `gc.pruneExpire` generously on the main repo, and give each worker a ref in
  the main repo (`refs/arbiter/workers/<id>`) while it runs so its base stays
  reachable.

This is the largest single item in the plan (P5, D4). Layout A avoids it at
the price of cross-worktree ref writes. The decision gate for P5 is whether the
sync-back is smaller than it looks once `Worktree` (1,700+ lines) is read in
full. This spike did not read it that far.

**After the P5 reading day (bd-4wy1w1).** The sync-back is smaller than it
looked; the hardening is larger.

- **ReviewGate and the MergeQueue do not read worker commits out of the main
  repo.** Every git command they run is in the worker's checkout (or in a
  review checkout cut from it) and talks to `origin`. A clone whose `origin`
  is the main repo's forge URL, with `origin/<base>` and a local `<base>`
  seeded from the main repo, answers them unchanged (push gate, target
  merge, merge-base, CI head, review checkout, rebase-before-push, push).
  A literal `git clone --shared` would get this wrong: its `origin` is the
  main checkout and its `origin/*` are the main repo's *local* branches. So
  P5 builds the clone by hand (`git init` + alternates + the two refs).
- **Five readers do look the branch up by name in the main repo**: the
  Direct merger, GitLab's `open/4` (pushes from the main repo), the conflict
  resolver's zero-divergence check, a dispatched reviewer's never-pushed
  fallback, and close-time branch reaping. Each now runs a sync-back first
  (`git -C <main> fetch <clone> +refs/heads/<b>:refs/heads/<b>`), plus one at
  the end of every reviewable run. PrimarySync needs none (it never reads
  worker branches).
- **The design missed one risk.** Host-side git keeps running in the
  worker's checkout after a container has had it (the push gate, merges,
  rebases, `leftover_work/2`). In layout B the whole `.git` is inside the
  writable mount, so a worker could plant a hook, `core.fsmonitor`, an
  alternates path or a `commondir` pointing at a config it wrote, and get
  code run on the host. The bwrap jail already closes these for a linked
  worktree; the mount table above now does for a clone.
- **The gc risk is real and the pin works.** Measured, in a live container:
  rewriting the main repo and running `git gc --prune=now` mid-run broke the
  worker's history without a pin and left it intact with one. The clone pins
  its start commit, its `origin/<base>` and its last synced head under
  `refs/arbiter/workers/<leaf>/`, and `core.alternateRefsPrefixes` keeps
  fetch negotiation in the clone from borrowing history only a sibling's
  branch reaches. `gc.pruneExpire` on the main repo was not changed.

Re-estimate: D3 for the code, with the risk in the mount hardening and the
pins rather than in the number of consumers (§9 Q3). Appendix D has the
probes.

### 3.3 Deps and `_build` caches

Measured: building deps from nothing took **201 to 221 s**; with a warm
cache, **17 to 18 s** ([§6](#6-measurements)). A cache is essential.

- **Seeded per-worker copies, not a shared writable volume.** A shared named
  volume mounted read-write into every worker is a persistence path: one
  worker can leave a poisoned `_build` that the next worker (or the operator,
  if the volume is ever bound back to the host) executes. `Jail`'s own comment
  makes the same point about `~/.mix/archives`. `Worktree.seed_compiled_deps/2`
  already does the safe thing (`cp -a --reflink=auto` per worktree); bd-5tncmq
  generalises it beyond Mix.
- **Key it by `(lockfile hash, image tag)`.** The cache is **ABI-bound to the
  image**: it contains NIFs (`exqlite`, `mdex_native`) built against a given
  libc and OTP. A cache seeded from the operator's host `_build` (Fedora,
  glibc 2.42) into a Debian 12 container (glibc 2.36) is not guaranteed to
  load. A host-built `_build` did let `epic_floor_test.exs` pass in the
  container (7 tests, 0 failures), but the run took 72 s against 17 s warm, so
  mix recompiled something; which part was not isolated. **Produce the cache
  inside the image** with a seed job (`mix deps.get && mix deps.compile`) run
  when the lockfile hash is new, and copy from there.
- **Hex and Mix homes stay per run**, as `Jail.toolchain_env/1` does today.
  The cache carries the Hex archive and rebar3 the seed job installed
  (`mix_home/`, compiled for the image's OTP) and each run's `HOME` gets its own
  copy at `~/.mix`. A container has no operator `~/.mix` to link in (the bwrap
  jail does), and without Hex `mix` stops to ask whether to install it, offline.

**As built (bd-1wm14e, `Arbiter.Worker.DepsCache`).**

| Question | Answer |
|---|---|
| Key | `<sha256(mix.lock at the default branch)[0,12]>-<sha256(image tag)[0,12]>` under `<scratch_root>/deps-cache`. The image tag is already a content hash of the Containerfile, build args and `.tool-versions`, so any toolchain change is a miss. The lockfile is read from the default branch's committed tree, never a worker's branch |
| Seed job | One container on a miss, single-flight per key: the default branch's tree exported with `git archive` into a scratch dir, `mix local.hex/rebar`, `mix deps.get`, `deps.compile` for `test` and `dev`. P3 hardening, two mounts (the export and a scratch `HOME`), `--network=pasta` because it fetches. Only `deps/`, `_build/<env>/lib/<dep>` and `mix_home/` are kept; the project's own app dirs are dropped, as in `seed_compiled_deps/3` |
| Publication | Staged beside the final name, `.complete` written last, renamed into place. A failed seed leaves nothing and the next dispatch retries |
| Per-worker copy | `cp -a --reflink=always` into the private clone, falling back to a plain `cp -a` where the filesystem cannot clone. The cache is never mounted into any container and never written after it is complete. The key is stamped in `<clone>/.git/arbiter-deps-cache`: the same key is left alone (a resumed worker keeps its compiled work), a new one replaces `deps/` and `_build/` |
| Failure | Best-effort. No lockfile, offline, or a failed seed logs a warning and the worker starts without the cache (it fetches through the egress proxy, as before) |
| Where | `ContainerSpawn.prepare/1`, after the image is resolved and before the egress run starts: a cold seed takes minutes |
| Config | `config :arbiter, :worker_deps_cache` (default `true`; `false` in the test env) |

**Measured (bd-1wm14e, 2026-10-04, this repo, image `beam-1.19.4-28.2`, reflink
filesystem).** `mix deps.compile --skip-umbrella-children` at `MIX_ENV=test` in a
fresh checkout of `origin/main`, three runs each, the same host:

| Step | Container (image-keyed cache) | bwrap (`seed_compiled_deps/3` from the host `_build`) |
|---|---|---|
| Cold seed, once per `(lockfile, image)` | 413 to 468 s (three runs: 413, 457, 468) | n/a (the operator's own `_build`) |
| Per-worker install of `deps/`, `_build/`, Hex (190 MB) | 0.85 to 1.1 s, `cp --reflink` | 1.1 to 1.5 s, `cp --reflink=auto` |
| `deps.compile`, run 1 (first use in the new directory) | 99.5 s | 99.9 s |
| `deps.compile`, runs 2 and 3 (warm) | 4.9 s, 4.8 s | 4.2 s, 4.3 s |

A warm container worker is within about 0.6 s of bwrap (rebar3 deps rebuild on
every run on both). The first run is ~100 s on **both** backends, and that is
not specific to containers: Mix records the compile-time config of the root
project and the dependency's directory in each `_build/<env>/lib/<dep>/.mix/
compile.elixir`, so any `_build` copied to a new path is rebuilt for the deps
that read it (73 "Compiling N files" steps in the first run here). `DepsCache.install/3` rewrites the directory
inside each manifest so that deps that do **not** read config (every dep of a
plain project: a one-dependency project measured 0 recompiles after the rewrite,
4 files before) are not rebuilt; this repo's config is path-dependent
(`config/test.exs` derives the test database name from the cwd), and
pinning `MIX_TEST_PARTITION` to the seed's value did not remove the first-run
rebuild, so the cause of the remainder is not isolated. Without the Hex archive
in the cache, a container worker could not run `mix` at all offline (it stops to
ask to install Hex). Run 1 needs the network when `mdex_native` is among the
rebuilt deps: its precompiled NIF is downloaded to `~/.cache`, empty in a
per-run `HOME` (offline, run 1 stopped in `mdex_native`).

Not done: pruning old cache directories (about 190 MB each for this repo; one
per lockfile and image tag).

### 3.4 SELinux on Fedora

All measured with SELinux **enforcing**.

| Mount flag | Effect on the host | Verdict |
|---|---|---|
| none | Container gets `Permission denied` on `user_home_t` files (reproduced: `unable to open object pack directory`) | Unusable |
| `:Z` | **Relabels the host path** with a private MCS pair. Observed: `container_file_t:s0:c143,c959` on the worker's checkout and home | Fine for per-worker private dirs that only that container touches. **Never** on a path the host or other workers share |
| `:z` | Relabels the host path `container_file_t` with a shared label | Works (objects read OK) but permanently changes the main checkout's labels. Avoid on the main `.git` |
| `:O` (overlay) | **No relabel**, reads work, writes are discarded. Verified on a fresh, never-labelled bare repo: label unchanged afterwards | **Use for the shared read-only objects** |
| `--security-opt label=disable` | The container runs unconfined by SELinux; no relabel needed anywhere | Needed for host unix sockets ([§5.3](#53-selinux-and-the-bridge-sockets)) |

Host effect of `:Z`: the host's own unconfined processes (Arbiter, git, the
sweeper) read and delete `container_file_t` files without trouble, so cleanup
works. Two workers with different MCS pairs cannot read each other's
directories, which is a feature.

## 4. What each provider CLI needs

Source for current behavior: `agents/*.ex`, `worker/spawn_env.ex`,
`worker/dispatch.ex` (read-only survey, 2026-10-02).

| Provider | Today | Needs in a container | Measured here |
|---|---|---|---|
| **Claude** | `claude --print …`, env from `SpawnEnv` (empty by default, allowlist). `CLAUDE_CONFIG_DIR` is an Arbiter-owned dir seeded with `settings.json` and `CLAUDE.md`. Auth is `CLAUDE_CODE_OAUTH_TOKEN` from the provider account. **Not jailed** | The binary in the image, a per-run `CLAUDE_CONFIG_DIR`, the token as an inherited env var (`-e NAME`, no value on argv, so `ps` shows nothing), `.mcp.json` in the checkout | **Ran end to end.** A completely empty `CLAUDE_CONFIG_DIR` with only the token worked for `claude -p` |
| **Codex** | `codex exec …`; Arbiter **never sets `CODEX_HOME`**, so a non-review worker reads the operator's `~/.codex/auth.json` directly. Jailed only for reviews, with the network shared | A per-run `CODEX_HOME` seeded with a copy of the ChatGPT login (`auth.json`) | Not run. Risk: a copied ChatGPT refresh token rotates, so concurrent copies can invalidate each other (the same shape as the Claude CLI rotating a seeded `.credentials.json` regardless of the token env, observed earlier) |
| **agy** | Jailed under bwrap, auth through the freedesktop Secret Service over a filtered D-Bus (`xdg-dbus-proxy`) or, when no keyring, file-copied `oauth_creds.json` into an isolated HOME | Either a D-Bus proxy socket mounted in (SELinux blocks `connectto` unless `label=disable`) or the file-seeded credentials the adapter already supports | Not run; **guardrail-profiles open question 5 stays open.** `xdg-dbus-proxy` is not packaged on RHEL 8. Recommend leaving agy on bwrap |
| **grok** | **No adapter.** Only a disabled login recipe (`GROK_HOME`, `auth.json`) | A per-run `GROK_HOME` when an adapter exists. Memory records that grok deletes `auth.json` after a rejected refresh | Not applicable |
| **MCP and `arb` to Arbiter** | URL `http://127.0.0.1:4848/mcp`, `Authorization: Bearer <worker token>` in `.mcp.json`; the same token is `ARB_TOKEN`; `ARB_HOST` defaults to `127.0.0.1:4848` | A bridge to the host's loopback ([§5](#5-network)) | Verified: with host loopback mapped in, `GET /api/version` → **200** and `GET /api/issues/bd-jk49nc` without a token → **401**, so bd-asawcq holds from inside a container |
| **`git push`** | `SSH_AUTH_SOCK` is dropped by `SpawnEnv`; pushes use key files in `~/.ssh` or `GH_TOKEN`/`GITLAB_TOKEN` from workspace `worker_env`. The agy jail forwards `GIT_SSH_COMMAND` with a shadow ssh config | A key or token the container is *given*. There is no `~/.ssh` | See below |

### 4.1 Claude under podman (P7)

`sandbox.backend: podman` runs a Claude worker's `claude --print` in a
container. The wrap point is `ClaudeSession`, at the two places every spawn goes
through (bd-d2o3xb):

- **`ClaudeSession.start/1`** (once per worker) calls
  `ContainerSpawn.prepare/1` when the spawn carries a podman `:security` policy:
  host readiness (`Container.status/0`, `network_status/0`), the private clone's
  mount set (`PrivateClone.mounts/1`; anything that is not a private clone is
  refused), the image (`Image.ensure/3` from the repo's default branch, or
  `config :arbiter, :worker_container_image`), the egress run
  (`Egress.JailRun`, learn mode, the same one agy's jail starts), and the
  per-run `HOME` and `CLAUDE_CONFIG_DIR`. The result rides in
  `port_args.sandbox`, so the commit-gate nudge and the auto-resume, which
  re-open the stashed args, are wrapped the same way.
- **`ClaudeSession.open_scoped_port/2`** turns the inner `sh -c 'exec claude
  --print …'` argv into the `podman run` argv. It skips `MemoryScope`: a
  container is not in the server's cgroup.

What the container sees (each verified by `container_spawn_live_test.exs`
against real podman):

| Item | How |
|---|---|
| The checkout, its `.git` and read-only guards, the main repo's `objects/` | `PrivateClone.mounts/1` |
| `CLAUDE_CONFIG_DIR`, `HOME`, `TMPDIR` | per run, under the run's temp dir; the config dir holds only the generated `settings.json` and `CLAUDE.md`, never a credential file or another run's history |
| `claude` and `arb` | the host's binaries, resolved through symlinks, bound read-only at `/opt/arbiter/cli` (on the image's `PATH`). `arb` is an escript, so the image needs a matching OTP |
| Token env | the spawn's explicit pairs only, each as `-e NAME` with the value in the `podman` client's environment: nothing on argv. `PATH`, `HOME`, `XDG_*` and the proxy variables are literals |
| Proxy and Arbiter | the run's two sockets bound read-only, and `Jail`'s own `socat` script inside the container on `127.0.0.1`: `HTTPS_PROXY`, `ARB_HOST` and the `.mcp.json` URL work unchanged; `--network=none`, so those sockets are the only exit |

Only Claude has a wrap point. `Sandbox.module/1` still refuses `:podman` (so
agy and Codex cannot run unsandboxed under it); `Sandbox.module/2` resolves it
for Claude. Dispatch's provider gate accepts Claude, swaps automatic routing to
Claude, and refuses an explicit other provider. `Claude.default_argv/2` refuses
a podman policy unless the caller passes `sandbox_wrap: true` (Dispatch does),
so the **reviewer, conflict-resolution and fix-pass spawns are not wrapped**:
they need a wrap point of their own, and a reviewer's checkout is not a private
clone.

**`sandbox.review_backend` (bd-4rvf98).** Refusing those spawns outright meant a
podman repo could not stay on podman: the first live trial (vs-clks8c, v0.2.15)
implemented in a container, then parked at the ReviewGate reviewer with
`{:sandbox_backend_unavailable, :podman, …}` (`reviewer_failed`). So the spawns
that are not a task worker's implement pass (a ReviewGate reviewer, a ReviewGate
revise pass, a `review: true` dispatch) resolve **`sandbox.review_backend`**
instead of `sandbox.backend` (`SecurityPolicy.for_review_spawn/1`). It defaults
to `bwrap`, so `backend: podman` alone gives a containerised implement worker and
bwrap-backed reviews. It layers exactly like `backend` (most-restrictive-wins,
settable at installation, workspace, repo and dispatch level, independently of
`backend`) and `ValidateConfig` accepts `bwrap` and `podman`. The refusal
semantics are unchanged: the key is never derived from `backend` and never
loosens on its own, and a `review_backend` with no implementation for the spawn
(`podman`, until a review wrap point exists) is refused, parking the review,
rather than run unjailed. Option (a), a container wrap for review checkouts (not
private clones; the hard part), is the follow-up that would make `podman` a
usable `review_backend`. The CI fix-pass and conflict-resolver dispatchers
(`MergeQueue.FixPassDispatcher`, `.ConflictResolver`) resolve no workspace
policy at all, so neither key reaches them.

**Push credentials: G16's scoped key versus agent forwarding.** Mounting the
operator's ssh-agent socket gives every key and fails under SELinux for the
same `connectto` reason as the bridges. G16 (a per-repo deploy key delivered
as a `podman run --secret` file, mounted read-only at `/run/secrets/…`, or a
per-run `ssh-agent` loaded with just that key) is strictly better, and a
container makes it *enforceable*: with no `~/.ssh` and no agent, the deploy
key is the only credential that exists. Under `--network=none`, `git push`
reaches the remote through the proxy bridge with the `ProxyCommand socat`
`GIT_SSH_COMMAND` that `Jail.ssh_env/1` already builds.

## 5. Network

### 5.1 The two designs

| Design | Mechanism | Result in the probe | Verdict |
|---|---|---|---|
| **N1. `--network=none` + proxy socket** | The container has only `lo`. A host unix socket (Arbiter's filtering CONNECT proxy, G5) is mounted in; `socat` inside listens on `127.0.0.1:3128` and forwards to it; `HTTPS_PROXY` points there | Direct `curl` to the model API: **fails** (000). Via the bridge: allowed host **404** (reached the API), denied host **000** and the proxy logged `ALLOW api.anthropic.com` / `DENY catbox.moe`. `/proc/net/dev` shows only `lo` | **Chosen.** Identical to G5/G6; independent of pasta and slirp4netns, so it works on RHEL 8 |
| **N2. pasta or slirp4netns + an egress allowlist** | User-mode networking with outbound open, rules added inside | `--network=pasta`: `api.anthropic.com` reachable (404), host loopback and gateway **not** reachable by default. `--network=pasta:--map-host-loopback,<ip>` makes Arbiter reachable, **but maps every host loopback service**: Arbiter (4848) and **epmd (4369)** were both reachable | **Rejected.** Fail-open by default, IP-level rules, mapping exposes all loopback services, `pasta` is not packaged on RHEL 8, `slirp4netns` is not installed on the laptop |

N1 is the same security model as guardrail-profiles §4.2 E2 with a
different kernel primitive: both give the process a namespace with `lo` only,
and the only exit is a socket Arbiter owns. `Egress.JailRun` already produces
the proxy socket and the `arb` bridge socket for bwrap; for podman the same
sockets are mounted into the container, and the `socat` wrapper runs in the
container instead of under bwrap. G5, G9, G10 and G17 do not change.

### 5.2 Reaching Arbiter

With N1, `127.0.0.1:4848` inside the container is the bridge listener; the
socat in the container forwards it to a per-run unix socket that
`Egress.JailRun` already creates (`arb` bridge), and Arbiter terminates it as
that worker's identity. Anonymous loopback is not available (bd-asawcq),
so the worker presents its own bearer token from `.mcp.json` and
`ARB_TOKEN`. `host.containers.internal` is not used.

### 5.3 SELinux and the bridge sockets

A container running as `container_t` cannot `connect()` to a unix socket
whose **listener** is an unconfined host process. The file label is
irrelevant (relabelling the socket directory with `:Z` did not help); the
denial is on the listener's domain. Reproduced:

- default label: `socat … connect(, AF=1 "/proxy/p.sock", 15): Permission denied`;
- `--security-opt label=disable`: the same command works (see the N1 row).

Options, in order of preference:

1. **`label=disable` for this container** and rely on the user namespace
   (`--userns=keep-id`), `--cap-drop=all`, `--security-opt no-new-privileges`,
   the read-only rootfs and the mount namespace. It removes the SELinux
   container-escape layer, not the mount, PID, user and network namespaces.
2. Run the proxy and the bridge listeners in a **sidecar container** with the
   same MCS category (`label=level:s0:c<N>,c<M>`), so the connect is
   container-to-container. More moving parts.
3. Ship a small custom SELinux module allowing `container_t` →
   `unconfined_t` `connectto`. Needs root and one more host-state item.

**On RHEL 8 the SELinux mode is unknown**; `label=disable` is a no-op if it
is permissive or disabled. The doctor check reports the mode and runs the
bridge self-test with and without the label.

## 6. Measurements

Host: Fedora 44, kernel 7.2.7, podman 5.8.7 (crun, netavark, overlay),
bubblewrap 0.12, SELinux enforcing, 2026-10-02. One run per cell (no
repetition for the long stages); the machine was running the live coordinator
and other workers throughout, so differences under about 10 percent are noise.

### 6.1 Start-up

| Measurement | bwrap | podman |
|---|---|---|
| Start, run `true`, warm (5 samples) | **10 to 14 ms** (`--ro-bind / /`, `--unshare-pid --unshare-net`) | **233 to 267 ms** (`podman run --rm`) |
| Same with `--userns=keep-id --read-only --cap-drop=all --no-new-privileges --network=none` | n/a | 341 to 375 ms (2 samples, after the first) |
| Same with real mounts (`:Z`, network none) | n/a | 245 to 251 ms (4 samples) |
| `--network=pasta`, warm | n/a | 270 to 306 ms |
| `elixir -e 'IO.puts 1'` (BEAM boot inside) | 260 ms host (3 samples) | 472 to 531 ms |
| **Cold: first `keep-id` run of a never-run image** | n/a | **5.9 s** (the 777 MB image), **3.5 s** (a fresh derived image). Podman chowns the image layers for the UID mapping once per image id. The same image run without `keep-id`: 0.20 s |
| Image build, apt layer + users | n/a | 66 s first, 49 s with the base cached; base pull 5.3 s |

### 6.2 Toolchain stages (Arbiter, `MIX_ENV=test`, `test/arbiter/tasks`, 1,013 tests)

The bwrap column is the **real `Arbiter.Worker.Jail.wrap/2` argv** (fresh
clone, fresh per-worker HOME, per-worker `HEX_HOME`/`MIX_HOME`). The podman
column is the image above with a fresh clone and fresh HOME. "No cache" means
no `deps/` and no `_build/`; "warm" means the second run in the same
directory.

| Stage | bwrap, no cache | podman, no cache | bwrap, warm | podman, warm |
|---|---|---|---|---|
| `mix local.hex`/`rebar` | 1.9 s | 1.9 s | 2.8 s | 0.9 s |
| `mix deps.get` | 3.8 s | 4.7 s | 3.9 s | 2.7 s |
| `mix deps.compile` | **221.0 s** | **201.0 s** | 18.3 s | 16.6 s |
| `mix compile` | 6.2 s | 2.0 s | 2.1 s | 2.1 s |
| `mix test` stage (compile + run) | 78.3 s | 67.3 s | 73.8 s | 68.7 s |
| ... of which ExUnit "Finished in" | 29.2 s | 18.5 s | 25.0 s | 19.3 s |
| **Total wall** | **311.3 s** | **280.9 s** | **101.0 s** | **91.3 s** |
| Result | 1,013 tests, 0 failures | 1,013 tests, 0 failures | same | same |

Read it as **parity, not a win**. The cache is worth about 210 s in both
(201 to 221 s → 17 to 18 s for deps), the container is not slower, and the
apparent 10 percent edge for podman is inside the noise given the single runs
and a concurrently busy host. The first container run failed one test:
`TeardownTest` shells out to `pgrep`, and the image lacked `procps`. Adding
it fixed it; the lesson is that **the image must carry the whole tool surface
the test suite invokes**, and that gap is only found by running the suite.

### 6.3 One real Claude run in a rootless container

A real `claude -p` (version 2.1.287, `--model haiku` to keep quota small,
`--dangerously-skip-permissions`, as workers run) inside the container, on a
scratch clone of this branch with its remote removed (no push possible) on a
scratch branch, with warm deps. The task: run `mix test
test/arbiter/tasks/epic_floor_test.exs`, write the count to
`PODMAN_PROBE.txt`, `git add` and commit.

| Measure | Result |
|---|---|
| Container flags | `--userns=keep-id --read-only --tmpfs /tmp --cap-drop=all --security-opt no-new-privileges --network=pasta`, token as an inherited env var, fresh empty `CLAUDE_CONFIG_DIR` |
| Wall clock, `podman run` start to exit | **69.3 s** |
| Claude's own `duration_ms` / `duration_api_ms` | 60,775 ms / 6,648 ms |
| Turns | 4 |
| Cost reported | $0.0531 |
| Outcome | Result line `epic_floor_test: 7 tests, 0 failures`; the commit `probe: podman container run` exists on the scratch branch and the file holds that line |
| What was and was **not** isolated | Files, env, process and UID namespaces: yes. Network: this run used `--network=pasta` (open egress) for simplicity; the `--network=none` + proxy design was proved separately with a stand-in proxy (§5.1), **not** with Claude itself |

**What this does not measure.** There is no matching *unjailed* Claude run:
Claude is not under bwrap today (G7 is unbuilt), so the bwrap comparison is
the toolchain table above. No agy or Codex run was made. No RHEL 8 measurement
exists (see Appendix B). Scratch artefacts stayed under `/tmp/jk49` and the images are local
tags `localhost/arb-dev-spike:*`; nothing was pushed.

### 6.4 Kill semantics (found while measuring)

`OsProcess` kills a worker's process tree with `pgrep -P` and `kill -KILL`.
For a container that is not enough:

- `kill -KILL` on the `podman run` client left the container **running** (it
  needed `podman rm -f <name>`);
- `kill -TERM` on the client left a container whose PID 1 is `sleep` running
  (PID 1 ignores signals it has no handler for);
- with `--init` the same `SIGTERM` stopped and removed it.

(Re-checked for P3 on podman 5.8.7: a `Port`-attached client that was
SIGKILLed had its container removed within a second, so the survival above is
not guaranteed either way; removal by name is idempotent and is what the backend
relies on.) So the backend must name every container (`--name arb-<run>`), run with
`--init` and `--rm`, and the watchdog and `StopWorker` must use `podman kill`
or `podman rm -f` by name.

## 7. Fit with Arbiter

### 7.1 Can it slot into `Arbiter.Worker.Jail`?

Mostly yes. `Jail.wrap/2` returns an argv list that the adapters splice the
CLI into; `gemini.ex:570` and `codex.ex:257` just use the result. Constraints
the survey found:

- **No `sandbox.backend` key exists.** `SecurityPolicy`'s `sandbox` map
  (`enabled`, `filesystem`, `network`, `writable_paths`, `egress_tunnels`) is
  where it belongs, with `merge_sandbox` taking the most restrictive layer
  value like the other fields.
- **Claude is not wired to the jail at all.** `claude.ex`'s `default_argv`
  and `ClaudeSession.start` (which uses `Port.open({:spawn_executable, …})`
  and `System.find_executable`) need a wrap point; with a container the
  executable is resolved **inside the image**, not on the host `PATH`.
- **Adapters assume the CLI's position in the argv** (`splice_prompt`,
  `split_jail`). The podman argv must keep one stable `--` boundary.
- **The prompt tmpfile** (`/tmp` plus `< "$f"` for oversize prompts) must be
  inside a mount.
- **Doctor** (`diagnose`, `diagnose_network`, `explain_*`) gains a podman
  branch: `podman` present, `/etc/subuid` entry, user namespaces, SELinux mode
  and a real `podman run` probe.

The right shape is a small behaviour, `Arbiter.Worker.Sandbox`
(`status/0`, `wrap/2`, `teardown/1`), with `Jail` (bwrap) and a new
`Container` module as implementations, chosen per provider by policy. An
estimate for the new module's argv builder is a few hundred lines; the jail's
masks, secret files, resolver tmpfs, keyring proxy and ssh shadow config
(roughly the 500 to 660 and 840 to 1060 line ranges of `jail.ex`) are not
needed for it, but they do stay for agy.

### 7.2 What happens to each guardrail ticket

| Ticket | Title | Today | Under this plan |
|---|---|---|---|
| **bd-7o08mj** (G1) | Hide D-Bus, systemd, resolver | closed | Unchanged; keeps protecting agy on bwrap. For containers it holds by construction |
| **bd-7r0qrj** (G2) | Worker env allowlist | closed | Unchanged for bwrap and for unjailed providers. For containers the env is **only what is passed with `-e`** |
| **bd-3q2djr** (G3) | Hide sensitive read paths | backlog | **Shrinks to agy-on-bwrap only.** For containers there is nothing to hide: only the mounts exist. Keep it small and do it for agy; the doctor "cannot read the install DB" self-test is reused as a container probe |
| **bd-cfktou** (G6) | agy network mode | verifying | **Remains** (agy on bwrap). Its `Egress.JailRun` sockets and in-namespace `socat` bridge are reused as-is by the container backend, so G6 is on the critical path of this plan, not obsoleted by it |
| **bd-d2o3xb** (G7) | Claude under the jail | backlog | **Re-scoped: Claude under the podman backend** (P7). Same goals (config-dir bind, token env, MCP and `arb` bridges), different primitive. Do not build bwrap masks for Claude |
| **bd-50d5j6** (G8) | Codex under the jail | backlog | **Re-scoped: Codex under podman**, folded with bd-99emmd as the original ticket suggested. Adds a per-run `CODEX_HOME` |
| **bd-ld8qde** (G14) | Dispatch-time withholding | backlog | **Shrinks, and inverts.** Withholding is the default; G14 becomes "add exactly the declared grants" (extra `-e`, `--secret`, a proxy allowlist entry). The "hide what is undeclared" half disappears for containers. D4 → D3 |
| **bd-9cygoo** (G16) | Scoped git and tracker credentials | backlog | **Remains and becomes enforceable.** Without `~/.ssh` or an agent in the container, the deploy key is the only push credential. Deliver it with `--secret`, not an agent socket (SELinux, and an agent holds every key). The operator still has to create the per-repo deploy keys or the GitHub App |
| bd-8xy1mf | Doctor probe for bwrap on both hosts | closed | **Repeat for podman** (P1) |
| G4, G5, G9, G10, G11 to G13, G15, G17 to G19 | Spike, `Egress`, bridge identity, config, routing, trust | various | **Unchanged.** Policy and the proxy are backend-independent |
| bd-5tncmq | Generalise dep seeding | backlog | **Gains a requirement:** the cache is keyed by image tag as well as lockfile (ABI) |

### 7.3 Ticket breakdown

All are children of bd-1e80nw. Order is by dependency; D is the estimated
difficulty.

| # | Title | D | Depends on |
|---|---|---|---|
| **P1** | **Spike/doctor: rootless podman readiness.** Re-scoped 2026-10-02 (no EC2 access): laptop go/no-go ([Appendix C](#appendix-c-p1-laptop-results-and-gono-go-bd-46xndf)) plus the portable `podman sandbox readiness` doctor check (`/etc/subuid`, `user.max_user_namespaces`, SELinux mode, cgroup version, podman version and storage driver, `label=disable` socket-bridge self-test). **Done (bd-46xndf).** The gate for any other host is that check | 2 | none |
| P2 | `sandbox.backend: bwrap \| podman` key in `SecurityPolicy` (layering by most-restrictive), plus the `Arbiter.Worker.Sandbox` behaviour with `Jail` as the first implementation. No behavior change by default | 3 | none |
| P3 | **Done (bd-bu4ye2).** `Arbiter.Worker.Container`: a pure argv builder like `Jail.argv/2` (`--name`, `--init`, `--rm`, `--userns=keep-id`, `--read-only`, `--cap-drop=all`, `no-new-privileges`, tmpfs, explicit `-e NAME` allowlist, mounts, label policy), a doctor probe and teardown by name | 3 | P1, P2 |
| P4 | **Done (bd-9r5jdt, `Arbiter.Worker.Image`).** Image lifecycle: `.arbiter/Containerfile` or a generated default, content-hash tags, single-flight lazy build from the **default branch**, weekly base refresh, prune, `arb image list/build`. Provider CLIs in the base image or a versioned read-only CLI dir | 3 | P3 |
| P5 | **Done (bd-4wy1w1, `Arbiter.Worker.PrivateClone`).** Git layout B: private `--shared` clone with read-only `:O` alternates, sync-back into the main repo, a pinned base ref against gc, cleanup and sweeper changes, ReviewGate and MergeQueue reads. **The riskiest item.** Re-estimated D3 after the reading day (§3.2) | 4 | P3 |
| P6 | **Done (bd-1wm14e, `Arbiter.Worker.DepsCache`).** Image-keyed deps cache: seed job inside the image, per-worker `cp --reflink` copy, key `(lockfile hash, image tag)`. Extend bd-5tncmq | 3 | P4 |
| P7 | **Done (bd-d2o3xb, `Arbiter.Worker.ContainerSpawn`).** Claude under the container backend (replaces G7 bd-d2o3xb): config dir, token env, `.mcp.json`, `arb`, proxy and Arbiter bridges via G5's sockets, wrap point in `ClaudeSession`. See [§4.1](#41-claude-under-podman-p7) | 3 | P3, P5, G5 |
| P8 | **Codex under the container backend** (replaces G8 bd-50d5j6, with bd-99emmd): per-run `CODEX_HOME`, refresh-token rotation handling | 3 | P7 |
| P9 | Deploy-key delivery as `--secret` (the body of G16 bd-9cygoo and the per-run-agent part of G14) | 3 | P7 |
| P10 | **Done (bd-dmcbos, `Arbiter.Worker.TestServices`).** Test services: a per-worker pod with a Postgres sidecar on the pod's `lo` for vstim and tonic (Postgres 15/16, plus an S3 store for tonic). Optional; arbiter needs none. See [Appendix E](#appendix-e-p10-test-services-probes-bd-dmcbos) | 3 | P7 |
| P11 | Re-plan the six tickets in [§7.2](#72-what-happens-to-each-guardrail-ticket): re-scope G7 and G8, shrink G3 and G14, annotate G6 and G16 | 1 | this decision |

**What to do first.** P1 and P2 are independent and cheap, and P1 decides
whether the rest proceeds. P5 should start with a day reading `Worktree`,
`CleanupWorktree`, `ReviewGate` and `MergeQueue` for what they assume about
worktree registration, because the D4 estimate rests on that.

## 8. Risks and alternatives

| Risk or alternative | Assessment |
|---|---|
| **Two backends to maintain** | Real cost. Mitigated by the behaviour boundary (P2) and by giving each backend disjoint providers: bwrap keeps agy, podman gets Claude and Codex. If agy later moves to file-seeded credentials, bwrap can be retired |
| **`label=disable`** | Gives up the SELinux layer for the bridge-using containers. The remaining isolation is the user, mount, PID and network namespaces and dropped capabilities. A sidecar listener removes the need (§5.3, option 2) at a complexity cost |
| **Rootless container escapes** | A container is not a VM. A kernel namespace bug breaks it as it breaks bwrap. No stronger claim is made than "default-deny and fewer moving parts" |
| **Image supply chain** | New: a worker image is built from public bases with network. Pin by digest, build from the default branch, never from a worker's branch |
| **Extending bwrap to Claude and Codex instead** | Cheaper to start (no images) but multiplies the denylist across the two largest providers and leaves the same incident class open. This is the main alternative; P1 is the gate between them |
| **Docker/Podman daemon, VM-based sandboxes** | Rejected without probing: a daemon is root-adjacent, and a VM adds boot time and image weight without a need the container does not meet |
| **Worker UID / separate Unix user** | Already rejected in [guardrail-profiles §10](guardrail-profiles.md): breaks same-user keyring auth and needs group-writable worktrees |

## 9. Open questions

1. ~~Is `label=disable` acceptable for Claude and Codex containers, or is the
   sidecar-listener variant worth its complexity?~~ **Decided, operator,
   2026-10-02: accepted.** `--security-opt label=disable` applies to the Claude
   and Codex containers that use the Arbiter/proxy bridge sockets, and only to
   those; the sidecar-listener variant is not built. Isolation rests on the
   user, mount, PID and network namespaces, `--cap-drop=all`,
   `no-new-privileges`, `--read-only` and the explicit mount set.
   `Arbiter.Worker.Container` (P3) adds the flag exactly when a container has
   bridge sockets. (The doctor check still reports the host's SELinux mode,
   which makes it moot where SELinux is permissive or disabled.)
2. Can agy's file-seeded credentials work everywhere (guardrail-profiles
   open question 5)? If yes, agy could join the container backend and bwrap
   could be retired.
3. ~~How large is P5 really? The estimate is D4; it should be re-estimated after
   the reading day.~~ **Answered (bd-4wy1w1): D3.** ReviewGate and the
   MergeQueue read the worker's checkout, not the main repo, so only five
   main-repo readers needed a sync-back; the larger work was hardening the
   clone's `.git` against host-side git and pinning against gc (§3.2).
4. Rootless overlay on RHEL 8 (`fuse-overlayfs`): is `_build`/`deps`
   copy-and-compile throughput acceptable? Not measured.
5. Does the per-worker image need `gh` and `glab` at all once G16 gives
   workers a repo-scoped tracker token?

## Appendix A: probes

Everything ran 2026-10-02 on the Fedora laptop under `/tmp/jk49`
(scratch clones of this branch, stand-in bare repos; the live checkout and
`~/.arbiter` were never mounted or relabelled). Findings in one place:

| Probe | Result |
|---|---|
| Registered-worktree mount without `common/` | `fatal: not a git repository` |
| Layout A (all eight mounts) | commit works; `git update-ref refs/heads/<sibling>` **succeeded**; deleting a packed ref failed (`packed-refs.lock` unwritable) |
| Layout A without `logs/` | `unable to create directory for '…/logs/refs/heads/…'` |
| Layout B, objects `:ro` without relabel | `unable to open object pack directory: Permission denied` |
| Layout B, objects `:ro,z` | works; **relabels** the objects dir `container_file_t` |
| Layout B, `label=disable` | works; push to a mounted bare remote worked; write to shared objects: EROFS |
| Layout B, objects `:O` on a never-labelled repo | works; **host label unchanged** |
| Unix socket from host to `container_t` | `Permission denied` on `connect()` |
| Same with `label=disable` | works |
| `--network=none` + `socat` bridge to a stand-in CONNECT proxy | allowed host 404 (reached), denied host 000, direct 000, only `lo` |
| `--network=pasta` | open egress; host loopback/gateway not reachable |
| `--network=pasta:--map-host-loopback,<ip>` | Arbiter (4848) and **epmd (4369)** both reachable; unauthenticated `/api/issues/…` → 401 |
| `slirp4netns` | not installed on the laptop |
| Image without `procps` | `TeardownTest` fails (`System.cmd("pgrep")` → `:enoent`) |
| First `keep-id` run of a new image id | 3.5 to 5.9 s once |
| `kill -KILL` / `kill -TERM` of the `podman run` client | container survives; `--init` fixes TERM; `podman rm -f <name>` needed |
| Host-built `_build` reused in the Debian container | test passed, 72 s (recompile suspected, not isolated) |
| Credentials | The Claude token was passed as an inherited env var and never written to a file, a commit or these notes |

Per-image sizes and build times are in §2.1 and §6.1.

## Appendix B: expected RHEL 8 differences

What `arb server doctor` (`podman sandbox readiness`) should be expected to say
on a RHEL 8 host with `container-tools:rhel8` (podman 4.9.4), versus the laptop.
None of this is measured; it is the prediction the check exists to confirm.

| Check | Laptop (Fedora 44) | Expected on RHEL 8 | What the check does |
|---|---|---|---|
| podman | 5.8.7 | 4.9.4 | ok (4.x or newer required); below 4 fails |
| storage driver | native overlay | overlay with `mount_program = fuse-overlayfs` (kernel 4.18 has no rootless overlay) | **warn**: copies are slower; the `_build`/`deps` throughput of §9 Q4 is still unmeasured there |
| cgroups | v2 | **v1** by default | **warn**: no rootless resource limits. Not a blocker, since the design does not rely on cgroup limits |
| network helper | pasta | slirp4netns only (pasta is not packaged) | ok if either is present. §5.1's `pasta:--map-host-loopback` design is unavailable; `--network=none` plus the socket bridge (N1) is unaffected |
| SELinux | enforcing | likely enforcing (RHEL default); not verified | reports the mode. `label=disable` is a no-op if permissive/disabled |
| socket bridge | needs `label=disable` | same if enforcing | self-test runs the bridge with `label=disable` (must work) and with the default label (informational) |
| subuid/subgid, `user.max_user_namespaces` | 65536 / 126539 | not verified; the sysctl may be 0 on hardened images, and a subid range exists only if the user was created with one (service accounts often lack it) | fail with the `usermod`/`sysctl` fix |
| `--init` kill semantics (§6.4) | measured | crun 1.14 expected same; not probed by the doctor (needs a running container and `podman kill`) | not covered; re-run the §6.4 commands by hand if in doubt |
| first-run `keep-id` cost | 1 s here (§6.1 measured 3.5 to 5.9 s for larger images) | unknown, likely slower on fuse-overlayfs | not covered (timing, not readiness) |

## Appendix C: P1 laptop results and go/no-go (bd-46xndf)

Run 2026-10-03 on the Fedora 44 laptop (podman 5.8.7), scratch dir under `/tmp`,
images `debian:12`. Probes ran by hand and through
`Arbiter.Worker.PodmanReadiness.diagnose/0` (`MIX_ENV=test mix run --no-start`).
**Not run:** a full dispatch through the real Arbiter spawn path; there is no
container backend yet (P3), so "the real spawn path" is the doctor probe plus
the equivalent `podman run` argv (`--userns=keep-id --init --rm`).

| Probe | Result |
|---|---|
| `/etc/subuid`, `/etc/subgid` | `ryan:524288:65536` in both: pass |
| `user.max_user_namespaces` | 126539: pass |
| SELinux | Enforcing |
| cgroups | v2 (`cgroup2fs`; `podman info` `cgroupVersion: v2`), crun |
| storage | native `overlay`, rootless, netavark, `pasta` present, `slirp4netns` absent, `fuse-overlayfs` installed but unused |
| `--userns=keep-id` cost | 0.96 s for the first run of `debian:12` under keep-id, 0.24 s on the second (the 3.5 to 5.9 s of §6.1 was for a fresh, larger image) |
| Socket bridge, `label=disable` | host unix listener reached from the container: `pong` |
| Socket bridge, default label | `connect: Permission denied` (confirms §5.3) |
| `--init` kill | `podman kill -s TERM`: with `--init` the container exited (143) within 2 s; without it still `Up` after 2 s and needed the 10 s SIGKILL fallback (confirms §6.4) |
| `deps` (51 MB) + `_build` (112 MB) copy | host `cp -a` 1.59 s (btrfs, reflink=auto); in-container bind to bind 0.91 s; bind to tmpfs 0.84 s; bind to overlay upper layer 1.58 s. **Compile** throughput was not re-measured (no Elixir image used); §6.2 holds the toolchain stage times |

**Go/no-go for this installation: GO** for continuing to P2/P3 on this
laptop: every prerequisite passes, the only SELinux requirement is the
already-planned `label=disable` on bridge containers, and the doctor check
reports `ready` with no failures or warnings. Caveats: the verdict covers
readiness, not a Claude run end to end (§6.3 has that), and says nothing about
RHEL 8 (Appendix B), for which the gate is the doctor check on that host.

## Appendix D: P5 layout B probes (bd-4wy1w1)

Run 2026-10-03 on the Fedora 44 laptop (podman 5.8.7, git 2.55.0, SELinux
enforcing), scratch repos under `/tmp`, a `debian:12` image with `git`
added. Reproduced by `private_clone_podman_test.exs` (`--include podman`).

| Probe | Result |
|---|---|
| Commit, merge, rebase, `gc`, `repack -a -d` in the clone, with `.git` its own mount and `config`/`hooks`/`commondir`/alternates read-only | all work, under `:Z` and under `label=disable` |
| `git update-ref refs/heads/<sibling> HEAD` in the clone (the spike's layout-A probe) | succeeds, but changes the clone's ref only; the main repo's refs are byte-identical afterwards |
| `git --git-dir=<main>/.git update-ref …`, `git -C <main> branch -f …`, writing `<main>/.git/refs/…` or `packed-refs` | all fail: only `objects/` of the main repo is mounted |
| `touch <main>/.git/objects/x` | succeeds in the overlay's throwaway layer; nothing on the host |
| `git config core.fsmonitor …`, a new hook, rewriting alternates or `commondir`, `mv .git` | all fail (`EBUSY` / `EROFS`) |
| `.git/commondir` containing `"."` | git treats it as no file: `rev-parse --git-common-dir`, `worktree add/remove/prune`, `gc`, fetch, push and rebase unchanged |
| Main repo rewritten and `gc --prune=now` while a container reads its history | **without pins**: `fatal: bad object HEAD` from the next read on (shell probe); **with pins**: 24/24 reads and `fsck --connectivity-only` pass |
| Same, read through `:O` without pins (ExUnit control) | not deterministic: `git log` still worked from a cached dentry while `fsck` failed. The overlay can serve a pack the host already deleted, which is borrowed time, not safety; the host-side clone is broken either way |

## Appendix E: P10 test services probes (bd-dmcbos)

Run 2026-10-03 on the Fedora 44 laptop (podman 5.8.7, SELinux enforcing).
Reproduced by `test_services_podman_test.exs` (`--include podman`; needs
`postgres:15-alpine`, `postgres:16-alpine` and `pgsty/silo` locally).

`TestServices` gives a repo with a service definition (vstim: Postgres 16;
tonic: Postgres 15 and `pgsty/silo`; others none) a pod created with
`--network none --userns keep-id`. The services are hardened members
(`--read-only`, `--cap-drop=all`, tmpfs state, no host mounts) and the worker
container joins with `--pod`.

| Probe | Result |
|---|---|
| Worker container in the pod, `psql "$DATABASE_URL"`: DDL, inserts, a read | works; `current_database()` is `vstim_test`; the container's only interface is `lo`, its uid is the host's |
| A TCP listener on the host's `127.0.0.1` (the control connects from the host) | `nc -z` from the worker: **unreachable**. Checked by hand as well: with the host's Arbiter on 4848 and epmd on 4369 both listening, neither was reachable from a pod member |
| The pod's Postgres from the host (`127.0.0.1:5432`) | `econnrefused`: nothing is published |
| tonic's pod | Postgres 15 and silo (`/minio/health/ready` over `127.0.0.1:9000`) both answer the worker |
| Bridge socket, pod member, `label=disable` | `psql -h <dir>` to a host unix listener connects; default label: `Permission denied`. §5.3 holds inside a pod |
| `--userns=keep-id` on a pod member | refused (`cannot set user namespace mode when joining pod with infra container`), even when the pod has it. So the pod carries `--userns keep-id` and the worker takes no `--userns`/`--network` of its own |
| Postgres as the host uid on a read-only root | initdb needs a writable owned `PGDATA`: a tmpfs is root-owned under keep-id, and `--tmpfs …,uid=` is rejected, so the data and socket tmpfs are mode 1777 with `PGDATA` a subdirectory; the entrypoint's `chmod` of `/var/run/postgresql` fails and is harmless. `PGHOST` cannot move the socket (the entrypoint unsets it) |
| `podman exec <ctr> -- cmd` | runs a command named `--` (as `run … image -- cmd` does): readiness argvs carry no `--` |
| Pod removal | `podman pod rm --force --ignore --time 0 <pod>` removes the worker container and every sidecar. `--rm` on the worker container does **not** remove the pod, so the pod has its own teardown: `ContainerSpawn.teardown/1`, a monitor-based `TestServices.Reaper` for any worker death (including `:kill`), and a boot sweep of pods whose recorded server pid is gone |

What was **not** run: vstim's or tonic's own `mix test`. Neither repo's image or
deps exist in this container (no network, by design), so the suite in the test
is a stand-in (DDL and queries through the injected `DATABASE_URL`). The first
run of a real suite needs the repo's image (P4/P6) and a deps cache, then is
checked by dispatching a vstim ticket with `sandbox.backend: podman`.
