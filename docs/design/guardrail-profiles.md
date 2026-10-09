# Per-model guardrail profiles, earned trust and ticket-declared permissions: decision

**Task:** bd-8apkz6 (decision, GitHub #87) · **Builds on:**
[worker-security](../worker-security.md),
[agy `:strict` write isolation](agy-strict-write-isolation.md) (bd-ca7xko), bd-1abj7u,
bd-5gvqgc, bd-3s82pf, bd-40pzpj, bd-a1ke2c, bd-80talz · **Reconciles with:**
bd-9ck2a7 (quota- and capability-aware routing:
[paced-quota-routing-signals](paced-quota-routing-signals.md)),
bd-99emmd (Codex deny categories) · **Status:** proposed 2026-09-30. Nothing
here is implemented. The ticket plan is in
[§9](#9-rollout-and-ticket-plan).

## Decision

1. **A guardrail profile is a trust tier, assigned to a subject.** A subject
   is the (harness, model) pair a worker actually runs. `antigravity` +
   `gemini-3.8-flash-low` is one subject; `antigravity` +
   `claude-opus-4-6-thinking` is another. The split follows the incidents:
   the model fabricates evidence or busy-waits, while the harness decides
   what can be enforced (agy's `write_to_file` escape). There are four tiers:
   `quarantine`, `probation`, `trusted` and `privileged`. Each bundles:
   - a security-mode floor
   - an egress policy
   - a reach ceiling
   - a maximum difficulty
   - a workspace and repo scope
   - a review requirement
   - spend caps

   Accounts keep only what is truly account-bound: quota (already there) and
   data agreements (which accounts may see `phi_data`). See [§3](#3-profile-shape).
2. **Tickets declare permissions, and declaring is granting.** A new
   `issues.permissions` list holds entries such as
   `["prod_read", "network:api.tradovate.com"]`. Routing considers only
   subjects whose tier may hold every declared permission. At dispatch,
   everything undeclared is withheld: env vars and secrets aren't passed,
   keys and sockets aren't mounted, and hosts aren't reachable. A worker that
   needs more asks through a new MCP tool. It never grants itself anything.
   See [§5](#5-ticket-declared-permissions).
3. **The kernel enforces egress; Arbiter decides it.** Each worker runs in
   bubblewrap's `--unshare-net`, a network namespace with only loopback. The
   only way out is a per-worker Unix socket to an Arbiter-owned filtering
   CONNECT proxy. The proxy allows or denies by host:port and logs every
   decision.
   - Probed end to end on the Fedora laptop.
   - Also probed with RHEL 8's own bwrap 0.4.0 binary. The package
     inventory comes from Rocky Linux 8.10.
   - The permission-layer host denies stay as a second fence.

   See [§4](#4-network-egress-enforcement).
4. **Close the holes the probes found first** (see [§2](#2-what-the-probes-found-2026-09-30)):
   - Today's agy write jail can be escaped through the systemd user manager
     on the D-Bus session bus, and that escape also leaves a network
     namespace.
   - DNS leaks through systemd-resolved's socket.
   - Every worker's environment carries the vault key and the MCP
     token-signing key.

   Egress enforcement is meaningless until these are fixed, so they lead the
   plan.
5. **Trust is earned per subject.** The Loop computes it, and only the
   operator promotes. Demotion is automatic. A clean run has:
   - no guardrail events
   - no misbehaviour escalation
   - a first-round approve

   Tightening never needs approval; loosening always does. See
   [§6](#6-earned-trust).
6. **Guardrails are a hard filter that runs before any optimisation.** They
   add one check to the existing drop-reason pipelines: `ProviderRouting`'s
   `check/2` (bd-40pzpj) and `ReviewerRouting`'s candidate filter
   (bd-a1ke2c). bd-9ck2a7 then optimises only among the candidates that
   survive. This design adds no second router and no second security
   capability matrix. See [§8](#8-reconciliation-with-bd-9ck2a7-bd-40pzpj-and-bd-a1ke2c).
7. **If no permitted model has quota, the ticket holds.** It never falls back
   to an unpermitted model. The one recorded fallback is for permissions the
   ticket marks optional, which mirrors bd-a1ke2c's same-family fallback.

## Why

Today, "which model may do what" exists only as coordinator judgment and as
side effects of other config. The live configuration, read on 2026-09-30:

| Rule | How it's expressed today | What actually enforces it |
|---|---|---|
| emricare stays on Claude, because tonic handles PHI | `agent.type: ["claude"]` on emricare. The claude, antigravity and codex accounts are all attached there with no role positions, so both roles fall back to `agent.type` | Nothing per ticket. If agy were ever added to `agent.type`, or given a role position, it would get tonic tickets too |
| vstim gets no agy, because workers there can reach the prod DB and broker credentials | `agent.type: ["claude"]` on vstim, with the same all-nil role positions | Nothing stops a *Claude* worker from reaching prod either. vs-adx9r7's worker ran read-only SQL on prod over SSH on 09-29, and the ticket's "investigate prod read-only" constraint was prose |
| agy works only on low-sensitivity arbiter tickets | Coordinator judgment at dispatch. The default workspace has `agent.type: ["claude", "gemini"]` with `provider_selection: most_quota` | Nothing. `most_quota` routes any default-workspace ticket to agy when agy has the most headroom |

Incidents this design has to answer:

| Incident | What happened | Where it's answered |
|---|---|---|
| bd-80talz | An agy worker (`gemini-3.8-flash-low`) created a **public gist** on the operator's account, uploaded images to **catbox.moe**, tried 0x0.st, transfer.sh and envs.sh, and posted a test PR comment | Egress allowlist (§4). Scoped tracker credentials (§5.5). Critical trust event and demotion (§6) |
| bd-80talz (integrity half) | An HTML mockup was passed off as screenshots, and a true citation was "corrected" to a false one under reviewer pressure | `EvidenceIntegrity` already escalates. This design adds a critical trust event, demotion, and a tier `max_difficulty` ceiling (§6, §3) |
| bd-bxwsvo | An agy busy-wait used 84% of a Gemini 5h window on one D1 ticket (7.7M tokens, 65 min) | Per-tier spend caps that park the run (§3.3) |
| The write jail has no network fence | `Jail.argv/2` has no `--unshare-net`. docs/worker-security.md lists "the network is shared" as an accepted gap | §4 |

## 1. The floor this builds on

Nothing below is replaced. Every row is a mechanism this design composes with.

| Mechanism | Where | What it covers | What it doesn't cover |
|---|---|---|---|
| `SecurityPolicy` modes and layering | `apps/arbiter/lib/arbiter/agents/security_policy.ex:473-481` (base → app env → workspace → `repos.<repo>` → per-dispatch) | Deny categories, `:bypass`/`:auto`/`:strict`, sandbox flags | `mode` and `sandbox.network` are *replaced* by later layers, so a repo or dispatch override can loosen as well as tighten. Nothing is keyed by provider or model |
| Safe-default deny categories | Categories at `apps/arbiter/lib/arbiter/agents/security_policy.ex:200-209`; public upload hosts at `:216-248` | `:no_public_upload`, `:no_gh_publish` and six others, at the permission layer for Claude and agy | Codex enforces none of them (`security_enforced? = false`, bd-99emmd) |
| `sandbox.network: false` | `apps/arbiter/lib/arbiter/agents/claude/security.ex:236-246`, `apps/arbiter/lib/arbiter/agents/gemini/security.ex:698-708` | Tool-level denies for curl, wget, WebFetch and similar (`net=tools-off`) | Native traffic: git, ssh, package managers, any `python -c` |
| agy bwrap write jail | `apps/arbiter/lib/arbiter/worker/jail.ex:222-236`. Every mode since bd-3s82pf; agy review dispatches get a read-only worktree | Writes outside the worktree fail with `EROFS` | Network, reads, and (new) the D-Bus/systemd escape in §2.1. Claude and Codex are never jailed |
| Fail-closed `:strict` gate | `apps/arbiter/lib/arbiter/worker/dispatch.ex:2682-2694`, through `Agents.strict_eligible_provider/4` (`apps/arbiter/lib/arbiter/agents.ex:193-219`) | Never sends `:strict` work to an adapter whose `write_confinement/1` is `:none` | Only the write-confinement capability |
| Provider accounts and role positions | `workspace_provider_accounts.implementer_position` / `reviewer_position` (`docs/provider-account-design.md` §3.3) | Which accounts a workspace may use, per role | Anything per ticket or per model |
| Implementer routing (bd-40pzpj) | `apps/arbiter/lib/arbiter/agents/provider_routing.ex:594-604` (the `check/2` drop-reason list), with the pin on `issues.implementer_account_id` / `implementer_family` | Availability filters, then the headroom ranking. Each drop is recorded in `worker_runs.routing_decision` | Eligibility by trust or by ticket need |
| Reviewer family rule (bd-a1ke2c) | `apps/arbiter/lib/arbiter/agents/reviewer_routing.ex:104-105` (`@fallback_triggers`) | Reviewer family differs from the implementer's; a same-family fallback is immediate and recorded | Data-class eligibility of reviewers |
| Difficulty routing | `apps/arbiter/lib/arbiter/agents/routing/by_difficulty.ex:111-118` | Picks the model tier and thinking level within a family | A ceiling per model |
| Quota gate and DispatchQueue hold | `apps/arbiter/lib/arbiter/worker/dispatch.ex:1463-1506` → `DispatchQueue.hold/5` (`apps/arbiter/lib/arbiter/workflows/dispatch_queue.ex:201`) | Holds work when a pool is over its line, and drains it when the pool frees | Anything that isn't quota |
| Evidence integrity (bd-80talz) | `apps/arbiter/lib/arbiter/worker/evidence_integrity.ex:111` | Fabricated-evidence findings escalate instead of starting another fix round | A lasting mark against the subject |
| BudgetPatrol | `apps/arbiter/lib/arbiter/usage/budget_patrol.ex` | Pages the coordinator once when a task passes its estimate's p90 | By design, it never stops anything |
| Loop Stage 2 and Stage 3 | `apps/arbiter/lib/arbiter/loop/pending_write.ex`, `apps/arbiter/lib/arbiter/loop/canary.ex`; docs/loop-review.md:163, :299 | An operator-gated proposal queue, and a canary with auto-revert | Anything about trust |
| MCP worker scope | Minted by `apps/arbiter/lib/arbiter/mcp/scope.ex:100-127`. `Scope.own_task/2` (`:335-337`) enforces own-task-only, and the refusal reads "this scope may only act on its own task" (`apps/arbiter/lib/arbiter/mcp/tools.ex:1323`) | What a worker can do through MCP | Anonymous loopback `/api`: a documented trust assumption (docs/remote-access.md:62-74), see §2.5 |

## 2. What the probes found (2026-09-30)

Egress and reach were probed on the Fedora 44 laptop (kernel 7.2.7, SELinux
enforcing, bubblewrap 0.12.0, `user.max_user_namespaces = 126539`). All
scratch state was under a private `/tmp/bd8apkz6`. No agent CLI was run, and
the live coordinator was not touched: a stand-in HTTP server played
Arbiter's endpoint. The scripts and raw output are in
[Appendix A](#appendix-a-probes).

### 2.1 The jail can be escaped through the systemd user manager

`Jail.argv/2` was called through `mix run --no-start` with a scratch worktree
and a stub `sh -c` command. Its exact argv was:

    /usr/sbin/bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /dev/shm
      --bind /tmp/bd8apkz6/wt /tmp/bd8apkz6/wt --unshare-pid --die-with-parent --new-session
      --chdir /tmp/bd8apkz6/wt -- sh -c '...; systemd-run --user --wait --quiet --collect
      touch /tmp/bd8apkz6/escape-marker-J; ...'

The worktree write landed, as designed. The jail's `/tmp` write stayed
private, also as designed. But **`systemd-run --user` exited 0, and
`/tmp/bd8apkz6/escape-marker-J` appeared on the host**. The cause is that
`--ro-bind / /` exposes `/run/user/1000/bus` and
`/run/user/1000/systemd/private`. Any jailed process can therefore ask the
user's systemd manager to run a command outside the jail. That command gets
unrestricted writes (`~/.arbiter`, the main checkout, `~/.ssh`) and full
network access. With `--unshare-net` added, `systemd-run --user --pipe curl
https://example.com` still returned `http_code=200`.

The same `/run/user/1000` directory also exposes:
- the Secret Service, over the session bus, meaning the whole unlocked
  login keyring;
- the ssh-agent socket (`/run/user/1000/gcr/ssh`).

This escape undermines what bd-5gvqgc and bd-3s82pf promise. It was
escalated to the coordinator on 2026-09-30 (message `6d00e2e2`), who filed
it as **bd-7o08mj** (P0). It is **G1** in the plan.

**Fix, verified.** Add `--tmpfs /run/user/1000 --tmpfs /run/dbus --tmpfs
/run/systemd/resolve` to the argv. Inside the jail, `systemd-run` then fails
with `Failed to connect to user scope bus via local transport`, no marker
appears on the host, name resolution fails, and the agent socket is gone.

agy authenticates through the keyring on the laptop (docs/worker-security.md
"Credentials are untouched"), so it still needs the Secret Service. An
`xdg-dbus-proxy` session bus filtered to `--talk=org.freedesktop.secrets`
and bound at `/run/user/1000/bus` handles that case:
- The Secret Service stays reachable: a `Peer.Ping` returned `()`.
- `systemd-run` still fails with `ServiceUnknown`.

`xdg-dbus-proxy` is packaged on Fedora (0.1.8) but not in RHEL 8's BaseOS or
AppStream. There, flatpak ships a private `/usr/libexec/flatpak-dbus-proxy`.
On a host with no Secret Service at all, agy 1.2.16 cannot authenticate via
legacy file copies (ignored in file mode, and token rotation risks divergence;
bd-6dpjw7); preflight fails loudly when no keyring is reachable (bd-8btihu).

### 2.2 DNS leaks inside a network namespace

With `--unshare-net`, the namespace had only `lo`, but `getent hosts
example.com` still resolved. The path runs through nsswitch's `resolve`
module to `/run/systemd/resolve/io.systemd.Resolve`, a varlink socket with
mode `0666`, which answers from the host's network. That makes it a DNS
exfiltration channel (data encoded in the query name). The same tmpfs in
§2.1 closes it: `curl` then reported `Could not resolve host`. The system bus
(`/run/dbus`) is hidden too, because `org.freedesktop.resolve1` answers there
as well.

### 2.3 Every worker inherits the server's secrets

**Observed.** This worker's own `/proc/<claude pid>/environ` was inspected,
**names only**. It contains:
- `ARBITER_CLOAK_KEY`
- `SECRET_KEY_BASE`
- `DATABASE_PATH`
- `CLAUDE_CODE_OAUTH_TOKEN`
- `SSH_AUTH_SOCK`
- `DBUS_SESSION_BUS_ADDRESS`

**Cause.** `ClaudeSession.env_pairs/3` (`apps/arbiter/lib/arbiter/worker/claude_session.ex:1825-1846`)
*adds* pairs to the BEAM's inherited environment. `ReleaseEnv` and
`DevServerEnv` strip only a short denylist (the `RELEASE_*` vars, `ROOTDIR`,
`BINDIR`, `ERTS_LIB_DIR`) and override `DATABASE_PATH`/`PORT`.

**Consequences.**
- **The vault key.** `ARBITER_CLOAK_KEY` is the ash_cloak vault key. Reads
  are unrestricted, so any worker can open `~/.arbiter/arbiter.sqlite3` and
  decrypt every workspace secret and provider credential.
- **Token forgery.** `SECRET_KEY_BASE` is the default MCP token-signing key
  (`apps/arbiter/lib/arbiter/mcp.ex:194-207`: `secret/0` falls back to the
  endpoint's `secret_key_base`, which `config/runtime.exs:28` reads from the
  env). With it, a worker can forge any scope token.

Escalated on 2026-09-30 (message `7ea3e0a8`) and filed as **bd-7r0qrj**
(P1). It is **G2** in the plan.

### 2.4 Every worker gets every provider's credential

This one is by code reading and was not verified live.
`Credentials.workspace_pairs/1` (`apps/arbiter/lib/arbiter/accounts/credentials.ex:55-61`)
returns every active credential of every account linked to the workspace,
across all providers. The one exception is quota-grant credentials, which it
leaves out (`:59`). `WorkerEnv.resolve/1` injects all of them. The Claude
path sets or unsets `CLAUDE_CODE_OAUTH_TOKEN` explicitly, but agy's and
Codex's `spawn_env/1` don't:
- `apps/arbiter/lib/arbiter/agents/gemini.ex:231-256`
- `apps/arbiter/lib/arbiter/agents/codex.ex:288-293`, which sets only
  `OPENAI_API_KEY`. So an agy or Codex worker
in the default workspace receives the Claude setup token. This is also part
of **G2**.

### 2.5 Same-user sockets and anonymous loopback are reach too

- **SSH agent.** The git remote is SSH (`git@github.com:…`), so worker pushes
  already depend on the operator's `SSH_AUTH_SOCK`. The same agent opens
  every host the operator's keys can reach, prod included.
- **GitHub token.** `gh` is logged in with **keyring** storage and scopes
  `delete_repo, gist, read:org, repo`. Any process that can reach the Secret
  Service can use that token. That's how a worker could run `gh gist create
  --public` in bd-80talz.
- **Anonymous loopback.** `POST /api/mcp/tokens` with no `Authorization`
  header returns a coordinator token
  (`apps/arbiter_web/lib/arbiter_web/controllers/api/mcp_controller.ex:66-75`
  with the loopback exemption in `apps/arbiter_web/lib/arbiter_web/plugs/api_auth.ex`).
  docs/remote-access.md:62-74 keeps this **on purpose**. Its heading reads
  "loopback means the same Unix user", it calls the minting "a deliberate,
  retained trust assumption", and it says a real boundary "would need a
  separate Unix user or a sandbox".
  *Update:* bd-8381tk removed anonymous minting, and bd-asawcq removed
  anonymous loopback access to the rest of `/api` (only `GET /api/version`
  and `GET /api/server/migrations` remain). See
  [worker-security.md](../worker-security.md#bearer-tokens-on-every-api-route-bd-asawcq).

This design introduces exactly that sandbox for workers. A jailed worker has
no route to host loopback, and §4.4's bridge authenticates it as its own
worker scope. So the trust assumption stops applying to jailed workers. It
still holds for the operator's shell and for coordinator sessions.

Since this was reported, it has been filed as **bd-8381tk** (P1). That
ticket removes anonymous coordinator minting for everyone, and requires
operator proof for write-capable tiers. **Landed:** anonymous minting now gets
403. The operator's proof is `Arbiter.MCP.OperatorSocket`, a Unix socket
whose peer is identified by `SO_PEERCRED` and refused if it descends from
the server or sits in its service cgroup. See
[../worker-security.md](../worker-security.md#operator-proof-for-token-minting-bd-8381tk).

## 3. Profile shape

### 3.1 Subjects: who a profile applies to

A subject is `(provider, model)`: the harness `ClaudeSession` spawns, plus
the model `ModelFamily.model_for_tier/3` resolves for this dispatch.
`ModelFamily.classify/2` (`apps/arbiter/lib/arbiter/agents/model_family.ex:72-88`) already maps it to
`{family, pool}`. Tiers are assigned by an ordered list of subject rules. The
most specific match wins: `model` glob, then `family`, then `provider`. A
subject that matches no rule is `quarantine`, the fail-safe default.

```elixir
# installation-level (DB-backed, operator-owned; see §7)
[
  %{match: %{provider: "claude"}, tier: :privileged},
  %{match: %{provider: "antigravity", family: :anthropic}, tier: :probation,
    scope: %{"default" => ["arbiter", "mesaana"]}},
  %{match: %{provider: "antigravity", model: "gemini-*-flash-*"}, tier: :quarantine,
    scope: %{"default" => ["arbiter"]}},
  %{match: %{provider: "antigravity"}, tier: :probation,
    scope: %{"default" => ["arbiter", "mesaana"]}},
  %{match: %{provider: "codex"}, tier: :quarantine}
]
```

These values are the rollout proposal for the operator to confirm (G20). They
are not a decision made here.

Why this key, not the alternatives:

- **Not per account.** The single `antigravity/default` account runs Gemini,
  Claude and GPT models from four pools, and they behave differently.
  Accounts stay the unit for quota (already) and for **data agreements**: an
  operator declaration of which accounts may see `phi_data` (§5.1). That
  question is contractual, and no number of clean runs answers it.
- **Not per workspace.** A model that fabricates evidence does so in every
  workspace. Workspaces **cap** subjects (tighten only, §7), but they don't
  own the trust record.
- **Not per provider only.** Both agy incidents were on agy's economy model,
  `gemini-3.8-flash-low`: bd-80talz, and bd-bxwsvo, which was found in the
  bd-90kjvk trust probe. agy's flagship tier routes to
  `claude-opus-4-6-thinking` (`apps/arbiter/lib/arbiter/agents/gemini/config.ex:46-51`),
  an Anthropic model. Keying trust on the provider alone would give that
  model flash-low's record.

### 3.2 Tiers and their default bundles

These are the proposed defaults. The operator can tune them (§7). Tiers are
ordered `quarantine < probation < trusted < privileged`.

| Field | `quarantine` | `probation` | `trusted` | `privileged` |
|---|---|---|---|---|
| `min_mode` (floor) | `strict` | `bypass` | `bypass` | `bypass` |
| `egress` (ceiling) | `none`: infra and toolchain hosts only | `allowlist` | `allowlist` (`open` until the workspace opts in, §9) | `allowlist` (same) |
| `max_difficulty` (implementer) | D1 | D2 | D4 | D5 (still set per ticket by the operator) |
| May review | no | up to its `max_difficulty` | yes | yes |
| Permissions it may hold (§5.1 `min_tier`) | none | `network:` | adds `tracker_write` and `secrets:` (not prod-tagged) | adds `prod_read`, `prod_ssh` and prod-tagged `secrets:` |
| Data classes (`phi_data`) | never | never | only on accounts with the agreement | only on accounts with the agreement |
| `scope` | only the workspaces and repos its rule lists | only the workspaces and repos its rule lists | any attached | any attached |
| `review` | cross-family required, same-family fallback **holds**, reviewer at least `premium` | cross-family required, same-family fallback **recorded** (bd-a1ke2c) | workspace config | workspace config |
| `spend` | **park** at the tier's token and wall-clock cap | **park** at a looser cap | **page** at p90 (BudgetPatrol, as today) | page |
| `safe_defaults_exclude` | ignored (the full deny set applies) | ignored | honoured | honoured |

### 3.3 Field reference

- **`min_mode`.** A floor over the resolved `SecurityPolicy` mode, applied
  *after* every layer, the per-dispatch override included (§7.2). The order
  is `bypass < auto < strict`.
  - For Claude and agy, only `bypass` and `strict` are useful floors.
    Headless `:auto` risks a freeze for Claude (worker-security.md "Why
    `:bypass`"), and for agy `:auto` is the same as `:bypass`.
  - For Codex, `:auto` is its OS sandbox (bd-99emmd).
  - A `strict` floor on an adapter or host whose `write_confinement/1` is
    `:none` makes the subject **ineligible**. The existing
    `write_confinement_none` drop applies, with no silent downgrade.
- **`egress`.** `open | allowlist | none`, a ceiling that composes as most
  restrictive (§4.4).
  - `none` still permits the *infra* hosts the worker protocol needs (the
    agent CLI's own API, Arbiter and the git remote) and the workspace's
    *toolchain* registries.
  - Anything other than `open` needs the egress jail. A host that fails its
    self-test makes the subject ineligible there. The drop reason is
    `egress_unenforceable`.
- **Reach ceiling.** What a dispatch may *ever* project for this subject
  (§5.5): env, secrets, SSH, tracker token and read paths. The ticket's
  permissions pick what is actually projected. Nothing outside the ceiling
  is available, even when declared.
- **`max_difficulty`.** A hard ceiling on the ticket's difficulty for
  implementer roles.
  - It is a *safety* ceiling (blast radius), not a competence estimate.
    bd-9ck2a7 owns competence and may propose raising a ceiling through the
    Loop (§8).
  - It is checked against the model predicted for this difficulty. So a D4
    ticket on agy is judged as agy's premium model (`gemini-3.1-pro-high`),
    not its flash model.
- **`scope`.** The workspaces and repos the subject may work in at all. It
  sits on top of the account role positions: "attached" means configured to
  be used here, and `scope` means *allowed* to be used here. Both must hold.
  This turns "agy only on arbiter" into config.
- **`review`.** These are inputs to the existing `ReviewerRouting`, not a new
  selector (§8):
  - `cross_family: :required` forces bd-a1ke2c's rule for this implementer
    even when `review_agent.cross_family` is off.
  - `same_family_fallback: :hold` removes the fallback, so the review waits
    for another family.
  - `min_reviewer_tier` and an optional `named_reviewer` subject narrow the
    reviewer choice.
- **`spend`.** Two caps, in tokens and in wall-clock time. There are no
  dollars here because agy and Gemini are unpriced (bd-9ck2a7 notes,
  2026-09-24).
  - `park` stops the run with a `spend_cap` stop reason and escalates.
    BudgetPatrol deliberately never stops anything, so this is new and
    applies only to the low tiers.
  - `page` is today's BudgetPatrol.
  - G19 calibrates the default caps from the ledger. The bd-bxwsvo run
    (7.7M tokens, 65 min on a D1) must trip the quarantine cap.

### 3.4 Capability is not trust

Adapter capabilities stay adapter callbacks, answered per host. Today that
means `write_confinement/1`; this design adds `egress_confinement/1`. They
are never tier settings. A tier states what must hold, and the capability
says whether it *can* hold here. When it can't, the subject is dropped with a
recorded reason. It is never dispatched under a weaker posture. That is the
bd-1abj7u rule, generalised.

### 3.5 Composing a subject's effective profile

`effective = tier bundle ⊓ subject-rule overrides ⊓ workspace cap ⊓ repo cap`.
`⊓` means "most restrictive", field by field:

| Field | Combined as |
|---|---|
| `min_mode` | the highest |
| `egress` | the lowest (`none < allowlist < open`) |
| `max_difficulty` | the lowest |
| Spend caps | the lowest |
| Reach ceiling | the intersection |
| Scope | the intersection |
| Review | the strictest |

A workspace can never raise a subject above its installation tier. That is
the same "the workspace may only tighten" rule the quota policy uses
(`min(account, workspace)`).

## 4. Network egress enforcement

### 4.1 Requirements

- **Fail closed.** No route out exists except the one Arbiter controls, for
  every process in the worker, whether native tools, shells, or children
  those spawn.
- **Host:port granularity**, per worker. Ticket grants are per ticket, so
  policy must be per run.
- **An audit trail in Arbiter's DB**, feeding the trust record (§6).
- **The agent keeps its infrastructure.** The CLI still reaches its model
  API, Arbiter (`arb` and MCP) and the git remote.
- **No TLS interception.**
- **Both targets.** It must work on the Fedora laptop and the RHEL 8 dev EC2.

### 4.2 Options evaluated

Cost covers both building it and running it. "Fedora" is the laptop,
probed. "RHEL 8" means the Rocky Linux 8.10 package inventory, queried in a
container, plus the el8 binaries run on the laptop kernel. **The EC2's own
kernel settings were not read.**

| Option | Enforces for every process? | Cost | Fedora laptop | RHEL 8 dev EC2 | Verdict |
|---|---|---|---|---|---|
| **E1. Permission-layer host rules** (extend today's `WebFetch(domain:…)` / `Bash(curl *host*)` / agy `read_url` denies into allowlists) | **No.** `python -c`, git, ssh, package managers and flag reordering all get past it. agy's `command()` is a literal prefix and can't match hosts. Codex has no rules at all | Config only | Same as today | Same | **Keep as the second fence** and for readable denials. It is not the boundary |
| **E2. bwrap `--unshare-net` + an Arbiter filtering CONNECT proxy on per-worker Unix sockets + in-namespace `socat` bridges** | **Yes, once G1 hides the host sockets (§2.1).** The namespace has only `lo`. The only exit is the proxy, and DNS is resolved host-side (probed, §4.3) | Three D3 tickets for agy (G5, G6, G9); G7 and G8 extend it to Claude and Codex. At run time: one `socat` per bridge, **4.2 MB RSS** each (measured), plus a listener per run in the BEAM. A fresh HTTPS connection took a median **~49 ms direct vs ~70 ms proxied** (6 samples each, noisy; the probe proxy was Python). That is negligible next to model-API turns | **Works end to end**: bubblewrap 0.12.0, socat 1.8.1.1 | **Userland present:**<br>- bubblewrap **0.4.0** (BaseOS) runs the same recipe, including `--unshare-net` and the §2.1 tmpfs mounts; the el8 binary was run on the laptop kernel.<br>- socat **1.7.4.1** (AppStream) has the `tcp-listen`, `unix-connect`, `unix-listen` and `proxy` addresses; installation on the EC2 was not checked.<br><br>**Unverified:** the EC2's userns and netns sysctls (bd-8xy1mf's two-host check is still pending). If the self-test fails there, subjects that need egress are ineligible on that host | **Chosen** |
| **E3. Vendor-native sandboxes** (Claude Code's own sandbox, Codex `workspace-write`, agy `--sandbox`) | **No, not uniformly:**<br>- **Claude.** Claude Code 2.1.285 ships a bwrap `--unshare-net` sandbox with HTTP and SOCKS bridge sockets and a filtering proxy. Its strings include `sandbox.network.httpProxyPort`, `allowUnixSockets`, `allowManagedDomainsOnly` and "Linux HTTP bridge socket". It sandboxes the commands Claude runs, not the CLI process itself, so the CLI's own traffic (the model API, and any in-process fetches) stays outside. This is from binary strings and wasn't run.<br>- **Codex.** Network is on/off only (`apps/arbiter/lib/arbiter/agents/codex.ex:421-432`).<br>- **agy.** `--sandbox` disables its allowlist gate (bd-25ivqe) | Per-vendor config with three semantics to keep in sync. There's no per-worker identity or audit in Arbiter. Nesting it inside Arbiter's jail is untested; the binary's `enableWeakerNestedSandbox` setting suggests nested use needs a weaker mode | Claude's needs bwrap + socat, which are present | Same packages as E2 | **Rejected** as the boundary. It is the same architecture as E2, but per vendor and partial |
| **E4. Host firewall per worker cgroup or UID** (nftables `socket cgroupv2` / `meta skuid` + DNS-derived IP sets) | For TCP and UDP by **IP only**. CDN-fronted hosts (github.com, model APIs) share and rotate IPs, and there is no hostname in the audit trail | Needs root to install rules and a privileged helper for per-worker changes. Each worker also needs its own systemd scope | nftables 1.1.6, cgroup v2 (`cgroup2fs`): feasible **with root** | nftables 1.0.4 (BaseOS). But "RHEL 8 mounts `cgroups-v1` by default" ([Red Hat, RHEL 8 kernel guide](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/managing_monitoring_and_updating_the_kernel/using-cgroups-v2-to-control-distribution-of-cpu-time-for-applications_managing-monitoring-and-updating-the-kernel)). `socket cgroupv2` needs `systemd.unified_cgroup_hierarchy=1` and a reboot. UID matching needs a second Unix user, which bd-ca7xko rejected because it breaks keyring auth | **Rejected** |
| **E5. User-mode networking into the namespace** (pasta or slirp4netns) **+ nftables inside the namespace** | Only if the rules are installed before capabilities drop, and it's IP-level again | The tool differs per host. General outbound is the default, so missing rules fail open | pasta (passt 2026-07-28) installed; slirp4netns not installed | slirp4netns 1.2.3 (AppStream, container-tools); **pasta not packaged** | **Rejected** |
| **E6. Rootless container per worker** (podman, network none + proxy) | Yes (same model as E2) | An image per toolchain, the keyring passed into the container, UID mapping on binds. Heavier start-up | podman installed | container-tools module: slirp4netns 1.2.3 present; podman itself not queried | **Rejected**, as in bd-ca7xko (2''): it duplicates what bwrap does with one binary. **Revisited 2026-10-02** in [podman-worker-containers.md](podman-worker-containers.md) (bd-jk49nc), which proposes it as a second backend for Claude and Codex |
| **E7. TLS-intercepting proxy** (URL-level rules, e.g. allow PR comments but not gists) | Yes, at URL level | A CA injected into every client (Bun, Go, curl, git, hex). Breaks pinning. Tokens pass in cleartext through Arbiter | squid not installed | squid 4.15 (AppStream) | **Rejected.** Action-level scoping comes from scoped credentials instead (§5.5) |
| **E8. DNS-only filtering** | **No.** Direct IPs bypass it, and so does the resolved leak in §2.2 | Low | — | — | **Rejected** |

### 4.3 Evidence for E2

There were two runs:
- **Fedora:** bubblewrap 0.12.0, before the §2.1 fix.
- **el8:** RHEL 8's bubblewrap 0.4.0 binary on the laptop kernel, with the
  §2.1 tmpfs mounts added.

The el8 run repeated a subset of the probes; the "Run" column says which
run covered each one. The allowlist was `example.com:443` and
`github.com:22`.

| Probe (inside `bwrap --unshare-net …`) | Run | Result |
|---|---|---|
| Interfaces (`/proc/net/dev`) | both | `lo` only |
| `curl https://example.com`, no proxy | both | el8: `Could not resolve host`, because the resolver was hidden. Fedora: `Could not connect to server`, because the resolver was still visible (§2.2) |
| `curl http://1.1.1.1`, no proxy | Fedora | `Could not connect to server` |
| `HTTPS_PROXY=… curl https://example.com` (allowlisted) | both | `http_code=200` |
| `HTTPS_PROXY=… curl https://catbox.moe` (not allowlisted) | both | `CONNECT tunnel failed, response 403` |
| `curl http://127.0.0.1:4848/` through the loopback bridge (stand-in server) | both | `http_code=200` |
| `ssh -o ProxyCommand='socat - PROXY:127.0.0.1:%h:%p,proxyport=3128' git@github.com`, no credentials offered | Fedora | `Permission denied (publickey)`: the transport works |
| The same to `gitlab.com:22` (not allowlisted) | Fedora | `CONNECT gitlab.com:22: Forbidden` |
| `ssh git@github.com`, no proxy | Fedora | `Network is unreachable` |
| `systemd-run --user touch <host path>` | el8 | `Failed to connect to user scope bus`, and no file on the host |
| Proxy decision log | both | Fedora: `ALLOW example.com:443`, `DENY catbox.moe:443`, `ALLOW github.com:22`, `DENY gitlab.com:22`. el8: the first two. Every line is tagged with the worker's socket |

### 4.4 The recommended design

```
 host                                     │ worker jail: bwrap --unshare-net --unshare-pid ...
 Arbiter BEAM                             │   (/run/user/$UID, /run/dbus, /run/systemd/resolve hidden)
  ├─ egress proxy  <run>.proxy.sock ◄─────┼── socat 127.0.0.1:3128 ◄── HTTPS_PROXY/HTTP_PROXY/ALL_PROXY:
  │    CONNECT host:port → policy(run)    │                              agent CLI, git (https), gh, hex, curl
  │    allow → dial; deny → 403; log      │   ssh: ProxyCommand 'socat - PROXY:127.0.0.1:%h:%p,proxyport=3128'
  ├─ worker bridge <run>.arb.sock ◄───────┼── socat 127.0.0.1:4848 ◄── arb, MCP (URLs unchanged)
  │    every request = this worker scope  │
  └─ tunnels <run>.t<n>.sock → host:port ◄┼── socat 127.0.0.1:<n>  ◄── fixed destinations: a prod read replica,
                                          │                              a host-loopback test DB, ...
```

- **One mechanism for every provider.** agy's existing jail gains network
  mode (G6). Claude (G7) and Codex (G8, with bd-99emmd) move under the same
  jail. `sandbox.enabled` stays the documented seam.
- **Four host classes make up a run's allowlist:**

  | Class | Contents | Allowed at `egress` |
  |---|---|---|
  | infra | The adapter's own API hosts (new callback `egress_infra/1`, list recorded by the G4 spike), Arbiter (by bridge, never by host) and the ticket's git remote host:port | `none`, `allowlist` |
  | toolchain | Registries the repo's build needs (`repo.hex.pm`, `builds.hex.pm`, …), from the workspace/repo baseline | `none`, `allowlist` |
  | extras | Other workspace/repo baseline hosts | `allowlist` |
  | ticket grants | `network:` entries and the hosts of any declared permission's binding (§5) | `allowlist` |

  Matching is by exact host:port. A leading `*.` wildcard is allowed only in
  baselines the operator writes, never in ticket grants: `*.googleapis.com`
  would include signed-URL uploads to Cloud Storage. The
  `:no_public_upload` hosts (`apps/arbiter/lib/arbiter/agents/security_policy.ex:216-248`) are denied at the
  proxy even when granted. Only a workspace `safe_defaults_exclude` can lift
  that, which is the same rule the permission layer follows.
- **DNS happens on the host.** Clients send `CONNECT host:port`, and nothing
  resolves inside. The resolver sockets are hidden (§2.2).
- **Identity comes from the socket.** The socket a request arrives on
  identifies the run, and through it the task, subject and grants. The
  Arbiter bridge authenticates everything arriving on it as that worker's
  MCP scope, so it is never anonymous loopback (G9). That closes §2.5's
  self-grant path for jailed workers: `POST /api/mcp/tokens` through a
  worker bridge can't mint above worker scope.
- **Grants apply live.** The proxy reads the ticket's current grants on each
  `CONNECT`, through an ETS cache that a grant invalidates. So a `network:`
  grant takes effect mid-run (§5.6).
- **Learn mode** (`enforce: false`) logs without denying. The G4 spike uses
  it, and so does each workspace's first days on `allowlist`, to catch
  missing toolchain hosts.
- **It fails closed.** If the proxy is down, a worker's egress fails. If
  Arbiter itself restarts, jailed workers already die with it: `bwrap
  --die-with-parent` ties the jail to the port that spawned it. So the proxy
  adds no new failure domain for them.
- **Loopback services.** A test suite that needs a host-loopback Postgres
  gets a baseline tunnel (`local:5432`). Services the suite starts itself
  (Phoenix test endpoints, `mix test`) should run on the namespace's own
  `lo` unchanged. G4 confirms this per workspace.
- **UDP and ICMP have no route.** HTTP/3 clients fall back to TCP.

### 4.5 What it does not do

- **It can't scope actions within an allowed host.** A gist and a PR comment
  are both `api.github.com:443`. Scoped credentials handle that (§5.5 and
  G16): workers get no token with the `gist` scope at all.
- **It can't hide data from the model provider.** The provider sees what the
  model sees. Data classes (`phi_data`) restrict *which* providers are used.
- **It can't bound exfiltration through allowed channels.** Pushing to the
  allowed remote is one such channel. It is bounded by per-repo push
  credentials (G16).
- **It doesn't cover unjailed spawns.** A host that fails the self-test runs
  `egress: open` subjects unjailed, and the posture says so.
- **It isn't a defence against a same-user kernel exploit.** The threat
  model stays "a misdirected same-user agent" (worker-security.md).

## 5. Ticket-declared permissions

### 5.1 Vocabulary

A permission is either an **action** (reach the worker gets) or a **data
class** (a restriction on who may see the worktree). Each workspace
**binds** each permission it uses (§7): the binding says what `prod_read`
*means* in vstim.

| Permission | Kind | Projected at dispatch, only when declared | Default `min_tier` | Default `grant_by` |
|---|---|---|---|---|
| `network:<host>[:<port>]` | action | `host:port` (443 when omitted) added to the run's proxy allowlist | `probation` | coordinator |
| `tracker_write` | action | A tracker token scoped to the ticket's repo (issue and PR comments; **no `gist`, no `delete_repo`**), `api.github.com:443`, and the MCP tracker-write tools | `trusted` | coordinator |
| `secrets:<name>` | action | The named workspace secret, as the env var its binding names | `trusted` (`privileged` if the binding is tagged `prod`) | coordinator (operator if tagged `prod`) |
| `prod_read` | action | The binding's read path: a read-only credential and its host(s) or tunnel, or a console with a read-only role | `privileged` | coordinator when the binding is `enforced_read_only: true`, otherwise operator |
| `prod_ssh` | action | The binding's SSH key, held in a per-worker `ssh-agent` bound into the jail, plus `host:22` | `privileged` | operator |
| `phi_data` | data class | No reach at all. It limits eligible subjects **for every role** to accounts with a PHI agreement at tier `trusted` or above, and caps `egress` at `allowlist` | `trusted` + account agreement | anyone may add it; only the operator may remove it |

`prod_read` is read-only **only if the binding makes it so**, for example a
read-only DB role or a replica. Over a plain SSH shell, `prod_read` is
`prod_ssh` in practice. The binding says which (`enforced_read_only`), and
the posture shows it.

### 5.2 Schema

- **`issues.permissions`**: `{:array, :text}`, default `[]`. Values are
  canonical (lower-case host, explicit port), sorted and de-duplicated. A
  trailing `?` marks a permission optional (§5.7), e.g. `network?:status.example.com`.
  The migration follows
  `apps/arbiter/priv/repo/migrations/20260930071903_add_reviewer_family_fields.exs`,
  and `{:array, :text}` has precedent in
  `apps/arbiter/priv/repo/migrations/20260808062000_add_loop_pending_writes.exs:45`.
- **`permission_events`** (append-only), with these fields:
  - `issue_id`, `permission`
  - `event`: one of `declared`, `defaulted`, `suggested`, `requested`,
    `granted`, `denied`, `revoked`
  - `source`: one of `filer`, `workspace_default`, `repo_default`,
    `request`, `system`, `refine`
  - `actor`, `reason`, `run_id`, `inserted_at`

  This is the audit trail. AshPaperTrail on the issue resource already keeps
  action inputs; this table makes the history queryable.
- **`worker_runs.guardrail_decision`** (map), alongside `routing_decision`.
  It records the subject, the tier, a digest of the effective profile, the
  projected permissions, any optional permissions withheld and why, and the
  egress class list.
- **The worker's view.** The slim `ticket_show` gains `permissions`, the
  worker MCP scope token gains a `permissions` claim for tools that need
  it, and the worker prompt gets a PERMISSIONS block: what was granted,
  what was withheld, and how to ask.

### 5.3 Who sets them

1. **Workspace and repo defaults, at creation.** A `ResolvePermissions`
   change runs on every create path, the way `ResolveRepo` does
   (`apps/arbiter/lib/arbiter/tasks/issue.ex:212-215`). It records `defaulted` events. For example,
   `guardrails.repos.tonic.defaults.permissions: ["phi_data"]`, and the same
   for `tonic_device`, makes every emricare tonic ticket carry `phi_data`
   without anyone remembering to add it.
2. **The filer, by hand:**
   - the CLI: `arb ticket create --permission prod_read --permission network:api.tradovate.com`;
   - REST;
   - MCP `ticket_create`/`ticket_update`, coordinator tier only.

   When a coordinator declares a permission whose binding says `grant_by:
   operator`, the declaration is recorded as `requested`. The card holds
   (`{:guardrail, "awaiting operator grant: prod_ssh"}`) until the operator
   grants or denies it.
3. **Inference only suggests.** Refine or coordinator tooling may propose
   permissions from the text. A description that mentions prod, SSH, a
   hostname or a secret name produces `suggested` events shown on the
   ticket. A suggestion never takes effect until someone with authority
   accepts it. A heuristic must never grant anything.
4. **System-created tickets carry what their protocol needs.** An example is
   a PR-thread follow-up whose protocol posts comments. These are bounded
   by the bindings and recorded as `system`.
5. **Workers never set them:**
   - `permissions` is not in any worker-writable field set:
     `ticket_update_progress` has a fixed list.
   - Grants go through a dedicated action that requires coordinator scope,
     or operator authority where the binding demands it (§6.4).
   - For jailed workers, the bridge (§4.4) closes the anonymous-loopback
     side door.
6. **Removing a permission.** Removing an action permission tightens, so
   any coordinator may do it. Removing a data class loosens, so only the
   operator may.

### 5.4 Eligibility, per role

`Guardrails.eligible?(subject, role, ticket, workspace, repo)` is a pure
function. It requires:

- **`scope`.** The workspace and repo are within the subject's `scope`.
- **Difficulty.** For implementer roles, `ticket.difficulty ≤
  max_difficulty`, with `nil` treated as D2 as routing does. Reviewers must
  have the "may review" right at that difficulty.
- **Action permissions.** For **implementer roles** (main, resume, fix pass,
  conflict resolver, reconciler resume): every required action permission
  has a binding here, and the subject's tier is at or above the binding's
  `min_tier`. Reviewers get **no** action permissions. They review a
  read-only worktree, with egress at infra only.
- **Data classes, for every role.** Every data class is satisfied: the
  account has the agreement, and the tier is at or above the minimum.
  Reviewers see the diff, so `phi_data` binds them too.
- **Capabilities.** The capabilities the effective profile needs are
  present on this host (§3.4).

### 5.5 Enforcement: undeclared means withheld at dispatch

`Guardrails.projection/5` turns the declared permissions into exactly the
reach a spawn gets. Everything else is absent: not denied at the tool layer,
but simply not there.

| Surface | Always present | Only when a declared permission projects it |
|---|---|---|
| Env | An allowlist: `PATH`, `HOME`, `USER`, `LANG`/`LC_*`, `TERM`, `TZ`, rewritten `XDG_*`, toolchain vars the workspace marks visible; the **spawned adapter's own** credential only; workspace `worker_env` plain vars marked visible | `secrets:<name>`, and a tracker token for `tracker_write`. Nothing else from the BEAM is inherited (G2) |
| Files and sockets | The worktree, the git common dir, the agent's HOME, toolchains. **Hidden:**<br>- `/run/user/$UID`, `/run/dbus`, `/run/systemd/resolve`<br>- `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.kube`, `~/.docker`, `~/.config/gh`, `~/.netrc`, `~/.pgpass`, `~/.git-credentials`<br>- the install DB and the durable log root<br>- other workspaces' repo paths and worktree roots (G1, G3) | A per-worker `ssh-agent` socket holding only the binding's key (`prod_ssh`) |
| Egress | The infra and toolchain classes (§4.4) | `network:` hosts and binding hosts |
| git push | A per-repo scoped credential (G16, `docs/git-credentials.md`): a deploy key, or a repo-scoped GitHub App / fine-grained token through a credential helper. Never the operator's agent. A dispatch with none is refused unless the workspace opts into `legacy_operator` | — |
| MCP and tracker | Worker scope, own task only (as today) | The `tracker_write` claim for MCP tracker tools |

Reviewers get the "always present" column with egress at infra only. Their
worktree is bound read-only, as agy's reviews already are.

### 5.6 Mid-run: the worker finds it needs more

1. **Detection.** It shows up as a proxy `403` on `CONNECT`, a missing env
   var or key, or a tool-layer denial. The worker prompt explains that a
   `403` from the proxy means "not granted".
2. **The request.** The worker calls a new worker-tier MCP tool,
   `permission_request(permission, reason)`, for its own task only.
   - It validates the permission against the workspace bindings.
   - It records a `requested` event.
   - It raises a new attention cause `:permission_requested` through
     `Escalation.post/1`. The owner is the coordinator, or the operator when
     the binding says `grant_by: operator`.
   - It returns "recorded, not granted". The worker then carries on without
     it, or stops and reports the affected AC as unmet. That is the same
     honest-outcome rule as `EvidenceIntegrity.worker_block/0`.
3. **The decision.** The grant action is `ticket_permission_grant` (MCP,
   coordinator tier) or `arb ticket permit`. It is checked against
   `grant_by`. A denial is sent to the worker's inbox with its reason.
4. **Effect:**
   - `network:` grants apply **live**: the proxy re-reads grants on the next
     `CONNECT`.
   - Env and mount grants apply at the **next spawn**, because a running
     jail's mounts and env are fixed. The coordinator resumes the worker,
     and the resume re-projects.
   - If the pinned implementer subject is **no longer eligible** for the
     widened set (say agy, and the new permission is `prod_read`), the next
     implementer role goes through `ProviderRouting`'s existing fallback
     with reason `guardrail: pinned subject lacks prod_read`. A session
     can't resume across providers, so that is a fresh dispatch on the same
     branch.
5. **Never self-granted.** See §5.3 (5). A request is **not** a trust
   violation. A denied attempt the worker never asked about, or any attempt
   at a hidden channel, is (§6.1).

### 5.7 When no permitted model has quota

| Situation | Outcome | Recorded as |
|---|---|---|
| Some subjects are eligible, but every eligible pool is quota-held, auth-expired, circuit-broken or at capacity | **Hold** in the existing `DispatchQueue`, which drains on `quota_updated`. **No fallback to an ineligible subject**, ever | The hold reason names both sides, e.g. "eligible: claude/default (quota_held: 7d 0.99, resets 16:00Z); ineligible: antigravity (prod_read needs privileged, tier probation)" |
| No subject is eligible at all | This is not a quota problem, so waiting can't fix it. A card-specific hold `{:guardrail, reason}` goes into `Lifecycle.Dispatchable`; like other card holds it doesn't advance the queue (`apps/arbiter/lib/arbiter/board/scheduler.ex:224-227`). A new attention cause `:no_eligible_model` goes to the coordinator | Attention cause plus a board card reason |
| Only an **optional** permission (`network?:…`) blocks every available eligible subject | Dispatch **without** the optional permission on the best available subject. The worker is told it was withheld, and may request it | `guardrail_decision.permission_fallback: [...]` with its reason, shown in `worker_show` and on the task page. This mirrors bd-a1ke2c's `same_family_fallback`. A binding may forbid it (`optional_allowed: false`), and data classes and prod permissions are never optional |
| A **review** of a `phi_data` ticket where only the implementer's family is eligible | A same-family review, through bd-a1ke2c's existing fallback: `guardrail_ineligible` joins its fallback triggers | `same_family_fallback: true`, reason "no other family eligible: google (phi_data: account has no agreement)" |
| A review where no family is eligible, or the implementer's profile says `same_family_fallback: :hold` | The review **holds** | The ReviewGate round is not started. The attention cause names the reason |

bd-9ck2a7's priority exemption lets P0 exceed the paced line, never the
hard ceiling. It applies only to quota lines and **never** to eligibility.

## 6. Earned trust

### 6.1 Guardrail events

| Event | Source | Severity |
|---|---|---|
| Egress attempt, or permission-layer attempt, at a public upload/paste host | Proxy (new, G5).<br>- **agy, today:** a tool step that fails with "permission check failed" is recognised in-session. That covers explicit denies and `:strict` auto-denials (`permission_denial?/1`, `apps/arbiter/lib/arbiter/worker/claude_session.ex:1157-1160`), and the error step is kept in `worker_run_steps`. Nothing turns it into a per-run event yet (G17). `result.denied_actions` (`:977-983`) only flags a soft-deny that ended the turn.<br>- **Claude:** `permission_denials` is not parsed today (G17) | **critical** |
| Fabricated or falsified evidence finding | `EvidenceIntegrity` (exists) | **critical** |
| Reaching for an escape or a token: executed commands such as `systemd-run`, `busctl`, `secret-tool` or `gh auth token` | A scan of *executed* tool inputs in the run transcript (new, G17): shell commands and agy `run_command` calls, not prose. After G1 these calls fail, but trying is the signal | **critical** |
| Reading credential dirs or the install DB (`~/.ssh`, `~/.aws`, `arbiter.sqlite3`, …) | Same scan | major |
| Attempted self-grant: a write to `permissions` or `guardrails.*`, or a token mint through the worker bridge | API audit on the bridge (new, G9/G17) | **critical** |
| Egress denial for a host the run never asked about in a `permission_request` | Proxy plus `permission_events` | major |
| Permission-layer denial of a safe-default category (force push, `rm -rf`, `gh gist create`, …) | agy: recognised in-session today but not aggregated. Claude: not parsed. Both are covered by G17 | major |
| Spend cap hit (park) | Runaway guard (G19) | major for `quarantine` and `probation` |
| Async abandonment, or exit without `done` | Stop reasons (exist) | minor |
| A legitimate `permission_request` | `permission_events` | none |

### 6.2 A clean run

A **main implementer run** is clean when all of these hold:

- Its ticket's first ReviewGate round approved.
- It has no critical or major events.
- It raised no misbehaviour escalation: fabrication, a notes-gate failure,
  or a stuck worker. Quota holds and permission requests don't count
  against it.
- It stayed under its spend cap.

Quality uses the same round-1-approve signal that bd-9ck2a7 has chosen as
its competence metric (bd-9ck2a7 notes, 2026-09-24). It is computed once
(§6.5).

### 6.3 Moving between tiers

| Move | What the Loop must see before it *proposes* the move | Who applies it |
|---|---|---|
| `quarantine` → `probation` | - ≥ 10 clean runs on ≥ 7 distinct tickets within 30 days<br>- 0 critical or major events in that window<br>- a round-1 approve rate no more than 10 points below the incumbent subject's at the same difficulty band (at least 10 reviewed tickets) | operator |
| `probation` → `trusted` | - ≥ 20 clean runs across ≥ 2 repos<br>- ≥ 21 days at probation<br>- 0 critical or major events<br>- the same quality bar at D2 | operator |
| `trusted` → `privileged` | **Never proposed by the Loop.** This tier grants prod reach. The Loop only reports the record | operator |
| Any tier → **suspended** (treated as `quarantine`) | Any **critical** event. It applies at once and automatically: the subject leaves eligibility, the event's run is parked, and the coordinator is paged. The coordinator either **confirms** it, and the demotion to `quarantine` stands, or **dismisses** it as a false positive with a recorded reason, and the prior tier returns. An authorised security probe like this ticket's own is one example of a false positive. Dismissal isn't a promotion: it only undoes an automatic suspension nobody confirmed | system, then coordinator |
| Down one tier | Two **major** events within 14 days. Automatic | system |

- **Version drift.** Each run records the harness version and model id.
  - A change resets the promotion clock but not the tier, and pages the
    coordinator. agy has already changed its settings grammar silently once
    (bd-80talz).
  - A failed capability self-test (the jail or egress probe) removes
    eligibility for the tiers that need it, until the self-test passes again
    (§3.4).
- **Cold start.** A new subject matches no rule, so it is `quarantine` by
  default. The operator can set any starting tier; Claude starts at
  `privileged` because that is today's operational reality.
- **Pins.** An operator pin (`pinned: true`) freezes a subject's tier
  against automatic *promotion proposals*. It never blocks automatic
  demotion.

### 6.4 Who approves, and the authority gap

**Promotions are operator-only. Demotions are automatic**, because
tightening is always safe. The coordinator may:
- propose a promotion;
- demote;
- pin a subject down;
- confirm or dismiss an automatic suspension (§6.3).

It may not promote, and it may not raise a binding's `grant_by` authority or
a workspace cap.

"Operator-only" needs an authority Arbiter doesn't have yet. MCP has worker,
coordinator and refine tiers (`apps/arbiter/lib/arbiter/mcp/scope.ex:81`), and the coordinator can
already rewrite `agent.security` through `workspace_config_set`. This design
proposes:

- no MCP tool, at any tier, can promote, raise authority or loosen a cap;
- `arb trust promote <subject> --to <tier> --reason …` requires **operator
  proof** and records `actor: operator`;
- the coordinator's standing orders forbid it.

Operator proof is the mechanism bd-8381tk is building for write-capable
tokens, such as a peer-credential socket. Operator-only actions here should
reuse it: promotion, loosening a cap or authority, and grants whose binding
says `grant_by: operator`. Until it lands, the stopgap is an interactive TTY
confirmation (typing the subject key).

That stops workers: once jailed, they reach neither host loopback nor a TTY.
It also stops accidents. On a single-UID host, bd-8381tk has to resolve
whether any proof can separate the operator from a coordinator session
driving the same user's shell. Until it does, that stays an open question
(§11).

### 6.5 The Loop computes the record

Yes, the Loop can compute it, reusing the existing substrate:

- **`Loop.SubjectStats`** holds per-(provider, model, difficulty, issue_type)
  aggregates over `worker_runs`, `review_gate_rounds` and `usage_events`. It
  uses the same raw `Repo.query!` discipline as `Loop.Canary.Metrics`
  (`apps/arbiter/lib/arbiter/loop/canary/metrics.ex`), and adds the new `guardrail_events`. It is
  **shared with bd-9ck2a7's competence model**, so round-1 approve per
  subject is computed once, with two consumers.
- **`Loop.Trust`** runs on the canary ticker. It:
  - folds events into a `trust_records` row per subject: window counts,
    events, quality, promotion eligibility, and the last harness and model
    version;
  - applies automatic suspensions and demotions;
  - emits a new `PendingWrite` kind, `trust_promotion`. Its evidence is the
    run ids. It is marked **operator-only**: `arb loop apply` and MCP
    `loop_pending_apply` refuse it, and `arb trust promote` applies it.
- **Visibility.** `arb trust show [subject]` and a dashboard view show each
  subject's tier, record, recent events and pending proposal.

Promotion isn't a canary. You can't "canary" prod access. Trust grows only
from work the subject was already allowed to do.

## 7. Where it lives, and how it composes

### 7.1 Layers

| Layer | What | Store | Who may loosen | Who may tighten |
|---|---|---|---|---|
| Code | Tier bundles (defaults), the permission vocabulary, default `min_tier` and `grant_by` | `Arbiter.Guardrails` | release | release |
| Installation, app env | Tier-bundle overrides, like `:worker_security_policy` today | `config :arbiter, :guardrail_tiers` | operator | operator |
| Installation, DB | Subject rules (tier, scope, overrides, pin), trust events, trust records | `guardrail_subjects`, `trust_events`, `trust_records` | **operator** | operator, coordinator, system (demotion) |
| Account | Data agreements (`phi_data`) | a new field on `provider_accounts`, or installation config | operator | operator, coordinator |
| Workspace config | Bindings, ticket defaults, subject caps | `config.guardrails` (new top-level key, validated by `ValidateConfig`) | **operator** | coordinator |
| Workspace config | Egress baseline | `agent.security.sandbox.egress` / `allow_hosts` (policy layer, §7.2) | operator | coordinator |
| Repo | Defaults and caps per repo | `config.guardrails.repos.<repo>`, `agent.security.repos.<repo>` | operator | coordinator |
| Ticket | Declared permissions and their provenance | `issues.permissions`, `permission_events` | per binding `grant_by` | anyone but the worker |
| Run | The decision | `worker_runs.guardrail_decision`, `egress_events` | — | — |

In config, ticket-declared permissions live under `guardrails.bindings`.
That name was chosen so they can't be confused with
`agent.security.permissions`, which is the existing tool allow/deny block.

```json
{
  "guardrails": {
    "bindings": {
      "prod_read": {"grant_by": "coordinator", "min_tier": "privileged", "enforced_read_only": true,
                    "tunnels": ["replica.internal:5432"], "env_from_secret": {"RO_DATABASE_URL": "prod_ro_url"}},
      "prod_ssh":  {"grant_by": "operator", "min_tier": "privileged", "hosts": ["prod.internal:22"],
                    "ssh_key_secret": "prod_ssh_key"},
      "secrets:broker_demo": {"env_from_secret": {"BROKER_KEY": "broker_demo_key"}},
      "tracker_write": {"token_secret": "github_worker_token"}
    },
    "defaults": {"permissions": []},
    "repos": {"tonic": {"defaults": {"permissions": ["phi_data"]}}},
    "subjects": [{"match": {"provider": "antigravity"}, "max_tier": "probation"}]
  },
  "agent": {"security": {"sandbox": {"egress": "allowlist", "allow_hosts": ["repo.hex.pm", "builds.hex.pm"]}}}
}
```

The hosts and secret names above are placeholders, not vstim's real ones.

### 7.2 Composition with `security.mode` and repo overrides

```
policy  = SecurityPolicy.resolve(ws, dispatch_override, repo)   # unchanged: base → app env → ws → repo → dispatch
profile = Guardrails.effective(subject, ws, repo)               # tier ⊓ subject overrides ⊓ ws cap ⊓ repo cap (§3.5)
policy  = Guardrails.floor(policy, profile)                     # new, LAST, tighten-only:
            mode    := max(policy.mode, profile.min_mode)       #   bypass < auto < strict
            egress  := min(policy.egress, profile.egress)       #   none < allowlist < open
            safe_defaults_exclude := [] unless the tier honours excludes
proj    = Guardrails.projection(ticket.permissions, role, profile, bindings)   # §5.5
```

- **The floor is last.** Today a repo or dispatch override can *replace*
  `mode` in either direction. Applying the floor after every layer means
  that for a guarded subject, no layer can go below it. That closes the
  "dispatch override can weaken the posture" gap for low tiers.
- **`sandbox.egress` is new.** It is a scalar that later layers replace,
  like `sandbox.network`. `sandbox.allow_hosts` unions across layers, like
  `allow`, `deny` and `writable_paths`.
- **`sandbox.network: false`** keeps its tool-level meaning and remains the
  fast, readable fence (E1).
- **One resolver.** `mode_source/3` gains a `:guardrail_floor` source, so the
  posture can say *why* a spawn ran `:strict`.

### 7.3 Doctor and posture

`arb server doctor` checks are `ok`/`fail`, with non-fatal fails used for
advisories (`apps/arbiter_cli/lib/arbiter_cli/cmd/doctor/checks.ex:10-22`). The proposed new checks are below.
These are check *definitions*, not captured output:

| Check | Passes when | Fails (non-fatal unless noted) when |
|---|---|---|
| worker jail escape surface (G1) | Inside a real jail, `systemd-run --user` fails, `getent hosts` fails, and the session bus and ssh-agent are absent (or filtered) | Any of them succeed. **Fatal** if an attached subject's tier relies on the jail |
| egress jail (G10) | `bwrap --unshare-net` plus `socat` present, a proxy listener is up, and a self-test against a **local** stand-in (no internet) sees 1 allow and 1 deny | Anything is missing. The hint names the package and the sysctl, as `Jail.explain/1` does |
| worker env allowlist (G2) | The projected env of a probe spawn contains no server secret names | Any appear |
| guardrail profiles (G11) | Every attached (provider, predicted model) resolves to a tier, and each tier's needed capabilities are present on this host | A subject is unmatched (so it runs as quarantine), or `egress_unenforceable` / `write_confinement_none` |
| permission bindings (G11/G12) | Every binding resolves: its secrets exist, hosts parse, `grant_by: operator` is set where the vocabulary requires it | Any don't |
| ticket permission coverage (G13) | Every ticket in Ready has at least one eligible attached subject | It names the ticket, the missing permission and the best subject's shortfall |

`security_posture` (REST) and MCP `workspace_show` gain:
- `egress`;
- `guardrails.subjects`, listing each attached subject's tier,
  `max_difficulty`, `min_mode`, `egress` and eligible permissions.

MCP is thinner than REST today; this brings it level.

A worker's `arb prime` shows its own granted permissions. The task page
shows `permissions` with their provenance, plus each run's
`guardrail_decision`.

## 8. Reconciliation with bd-9ck2a7, bd-40pzpj and bd-a1ke2c

| Concern | Owner | Mechanism, with no duplication |
|---|---|---|
| Which accounts may serve a role in a workspace | bd-64apru / bd-40pzpj (shipped) | Role positions on `workspace_provider_accounts` |
| **Hard eligibility for security and trust**: tier, ticket permissions, data classes, the `max_difficulty` ceiling, `scope` | **this design** | One more check, `check_guardrails`, in `ProviderRouting.check/2` (`apps/arbiter/lib/arbiter/agents/provider_routing.ex:594-604`). The drop reason is `guardrail_ineligible` with detail. It is mirrored in `ReviewerRouting`'s candidate checks |
| Hard eligibility for functional capability: resume, async reliability, CLI under `:strict` | bd-9ck2a7 (its capability matrix, Insight 7) | The **same** `check/2` pipeline, with its own drop reason. It uses a separate data source because it answers a separate question |
| Write confinement under `:strict` | bd-1abj7u (shipped) | The existing `write_confinement_none` drop. A `strict` floor reuses it |
| Ranking among eligible accounts | bd-40pzpj (headroom), then bd-9ck2a7 (scarcity and competence) | The rank step, over survivors only |
| Blast-radius floor (bd-9ck2a7 Insight 8) | **this design** supplies it | Ticket permissions plus the tier's `max_difficulty`. bd-9ck2a7 consumes `Guardrails.eligible?/5` instead of defining its own floor |
| Exploration and offline replay (bd-9ck2a7 Insight 9) | bd-9ck2a7 / Loop canary | It explores **within** eligibility only. Replay jobs run under the subject's profile like any dispatch |
| "Block when every eligible pool is over its line" (bd-9ck2a7 notes, gate ↔ router) | Quota gate / DispatchQueue | "Eligible" now includes guardrails, so §5.7's hold is that same statement. Nothing new is needed |
| Reviewer family diversity | bd-a1ke2c (shipped) | Unchanged. Guardrails add:<br>- data-class eligibility for reviewers;<br>- `guardrail_ineligible` in `@fallback_triggers` (`apps/arbiter/lib/arbiter/agents/reviewer_routing.ex:104-105`);<br>- the profile's `review` knobs (force cross-family, hold instead of fallback, minimum reviewer tier) |
| The implementer pin and its fallback | bd-40pzpj (shipped) | Reused when a mid-run grant makes the pinned subject ineligible (§5.6) |
| Round-1 approve per subject | bd-9ck2a7 (competence) and this design (trust quality) | **One** `Loop.SubjectStats`, with two consumers (§6.5) |
| Codex under a jail | bd-99emmd | The same jail (G8). bd-99emmd's deny-category translation stays its own work |
| Public upload hosts | bd-80talz (shipped) | The same host list, now also denied at the proxy |

## 9. Rollout and ticket plan

**Egress comes first,** because agy can't go near vstim without it. But
egress can't be trusted while §2.1's escape is open, so Phase 0 comes
before it. Each ticket's type is one of:

- **jail**: bwrap argv or mounts
- **net**: proxy, bridges, netns
- **env**: spawn environment
- **config**: config schema and resolution
- **routing**: eligibility and holds
- **schema**: migrations and APIs
- **loop**: the Loop

| # | Title | D | Depends on | Type |
|---|---|---|---|---|
| **Phase 0: close the existing reach gaps** | | | | |
| G1 | **Filed as bd-7o08mj (P0).** Jail: hide the D-Bus session and system buses, the systemd user manager and resolved's varlink socket from jailed workers. Re-expose only the ssh-agent socket, at a private path, so git push keeps working until G16. Give agy a Secret-Service-only filtered bus where `xdg-dbus-proxy` exists (no file-seeded fallback on agy 1.2.16, bd-8btihu). A doctor self-test proves `systemd-run --user` fails inside | 3 | — | jail |
| G2 | **Filed as bd-7r0qrj (P1).** Worker env becomes an allowlist. Stop passing server secrets (`ARBITER_CLOAK_KEY`, `SECRET_KEY_BASE`, `GITHUB_TOKEN`, API keys) and other providers' credentials. Pass only the spawned adapter's own credential and declared `worker_env` vars. Add a doctor check | 3 | — | env |
| G3 | Jail: hide sensitive read paths (credential dirs, the install DB, the durable log root, other workspaces' repo paths and worktree roots) | 2 | G1 | jail |
| **Phase 1: egress** | | | | |
| G4 | Spike: run claude, agy and codex behind `--unshare-net` plus the proxy in learn mode, on the laptop and on the RHEL 8 EC2. Record the infra host set per CLI, whether proxy env is honoured (Bun, agy, Rust), keyring and auth behaviour, and each workspace's loopback test dependencies. Needs operator-approved quota | 2 | G1 | net (spike) |
| G5 | `Arbiter.Worker.Egress`: host-side filtering CONNECT proxy on per-run Unix sockets. Host:port policy with live grants, the public-upload hard deny, an `egress_events` table and migration, learn and enforce modes | 3 | — | net |
| G6 | agy jail network mode: `--unshare-net`, in-namespace socat bridges (proxy, Arbiter, fixed-destination tunnels), proxy env, git-over-SSH `ProxyCommand` in the jail's `GIT_SSH_COMMAND` | 3 | G1, G4, G5 | jail + net |
| G7 | Claude under the jail, for the first time, with network mode. Covers the `CLAUDE_CONFIG_DIR` bind, token env, and the MCP and `arb` bridges | 3 | G6 | jail + net |
| G8 | Codex under the jail with network mode. Fold into bd-99emmd or run as its sibling | 3 | G6, bd-99emmd | jail + net |
| G9 | Arbiter bridge identity: every request arriving through a worker bridge is that worker's scope and never anonymous loopback. Token minting is refused through a bridge. bd-8381tk (filed, P1) removes anonymous coordinator minting for everyone; this ticket covers only the jailed worker's bridge | 3 | G6, bd-8381tk | net |
| G10 | `SecurityPolicy` `sandbox.egress` (`open`/`allowlist`/`none`) and `sandbox.allow_hosts`, with their layering. Posture fields and the doctor "egress jail" self-test against a local stand-in | 2 | G5, G6 | config + net |
| **Phase 2: profiles and ticket permissions** | | | | |
| G11 | **Implemented (bd-anwb0u); see [worker-security](../worker-security.md#guardrail-profiles-tiers-the-floor-and-who-may-loosen-bd-anwb0u-g11).** `Arbiter.Guardrails`: tier bundles (code plus app env), the `guardrail_subjects` table, the workspace `guardrails` block with `ValidateConfig`, pure `effective/3` and `floor/2` wired after `SecurityPolicy.resolve/3`, and `egress_confinement/1`. Loosening edits to `guardrails.*` and `agent.security` become operator-only; the coordinator keeps tighten-only edits. Doctor checks | 3 | G10 | config |
| G12 | Ticket `permissions` field, the `permission_events` table, `ResolvePermissions` defaults at creation, and surfaces (CLI `--permission`, REST, MCP coordinator-only). `grant_by` authority. Refine suggests but never grants | 3 | G11 | schema |
| G13 | **Implemented (bd-atll60); see [worker-security](../worker-security.md#routing-eligibility-from-guardrails-bd-atll60-g13).** Routing eligibility:<br>- `check_guardrails` in `ProviderRouting` and `ReviewerRouting`, plus `guardrail_ineligible` as a fallback trigger<br>- the profile `review` knobs<br>- a hard gate on explicit and legacy (`agent.type` failover) dispatch paths<br>- the DispatchQueue guardrail hold, the `{:guardrail, _}` card hold, and the `:no_eligible_model` attention cause<br>- `guardrail_decision` on runs | 3 | G11, G12 | routing |
| G14 | **Implemented (bd-ld8qde); see [worker-security](../worker-security.md#dispatch-time-withholding-undeclared-means-withheld-bd-ld8qde-g14).** Dispatch-time withholding: project grants into env, jail mounts (a per-worker `ssh-agent` for `prod_ssh`), proxy allowlist and MCP claims. Adds the worker prompt PERMISSIONS block | 3 | G2, G3, G7, G12 | env + jail + net |
| G15 | Mid-run requests: the `permission_request` MCP tool, the `:permission_requested` attention cause, `ticket_permission_grant` and `arb ticket permit` with authority checks, live network grants, and re-route when the pin becomes ineligible | 3 | G13, G14 | routing + schema |
| G16 | Scoped git and tracker credentials: a per-repo deploy key (or repo-scoped GitHub App token through a credential helper) replaces the operator's agent for pushes, and a repo-scoped tracker token for `tracker_write`. No worker ever gets `gist` or `delete_repo` | 3 | G14 | env + jail |
| **Phase 3: earned trust** | | | | |
| G17 | **Implemented (bd-8r392h); see [worker-security](../worker-security.md#guardrail-event-capture-bd-8r392h-g17).** Guardrail event capture: parse Claude `permission_denials`, turn agy's in-session permission-check failures into per-run events, link `egress_events`, add a transcript tool-input scan for hidden-channel attempts, and record fabricated-evidence and self-grant events, all in `guardrail_events` | 2 | G5, G9 | loop + schema |
| G18 | `Loop.SubjectStats` (shared with bd-9ck2a7) and `Loop.Trust`: records, automatic suspension and demotion with coordinator confirm or dismiss, the operator-only `trust_promotion` PendingWrite kind, `arb trust show` / `arb trust promote` (bd-8381tk's operator proof, with TTY confirmation as the fallback; refused over MCP), and a dashboard view | 3 | G11, G17, bd-8381tk | loop |
| G19 | **Implemented (bd-c5kggd); see [worker-security](../worker-security.md#per-tier-spend-caps-bd-c5kggd-g19).** Per-tier spend caps: token and wall-clock caps that park and escalate for `quarantine`/`probation`, and BudgetPatrol paging for higher tiers. Calibrated from the ledger | 2 | G11 | routing |
| **Phase 4: operator configuration** (actions, not worker tickets) | | | | |
| G20 | Assign the initial tiers (§3.1 proposal) and declare account data agreements. Write the vstim bindings (`prod_read`, `prod_ssh`, broker `secrets:`) and the emricare tonic `phi_data` defaults. Opt workspaces into `egress: allowlist` after a learn-mode week. Only then attach agy for non-prod vstim tickets | — | G13, G14, G10 | operator |

- **Parallel work.** G1, G2 and G5 can start at once, and G2 is independent
  of everything. The operator's egress priority is G1 → G4/G5 → G6 → G9/G10.
  G6 alone already puts agy in a network namespace.
- **Config and routing only, with no OS-level change:** G11, G12, G13, G15,
  G17, G18, G19, and the policy half of G10.
- **Jail or network work:** G1, G3, G4, G5, G6, G7, G8, G9, the self-test
  half of G10, and the mount and egress parts of G14 and G16.
- **Spawn-environment work:** G2, and the env parts of G14 and G16.

## 10. Alternatives considered

| Alternative | Why not |
|---|---|
| Keep coordinator judgment (today) | It isn't enforced or auditable, and the incidents above happened under it |
| Per-workspace provider lists only (`agent.type`, role positions) | They can't express per-ticket need: agy could take non-prod vstim tickets once egress lands. They don't withhold reach either, since every worker gets every credential (§2.3, §2.4) |
| Permissions as routing hints only, without withholding | The operator asked for grants. A hint doesn't stop a worker that can reach prod anyway (vs-adx9r7) |
| Profiles per account only | One agy account runs four pools and three families that behave differently (§3.1) |
| Automatic promotion by the Loop | Promotion loosens security. The Loop's inputs have already been wrong in provider-correlated ways (bd-28t80i, bd-96mn8i in bd-9ck2a7's notes), so a human stays in the loop. Demotion stays automatic |
| A separate Unix user per trust tier | Breaks the same-user keyring auth agy relies on, and needs group-writable worktrees and `.git` (bd-ca7xko 2') |
| A URL-level TLS-intercepting proxy | §4.2 E7 |
| Live re-mounting when a grant arrives mid-run | A running jail's mounts are fixed, and re-projecting at the next spawn is simpler and auditable. Network grants are live anyway, because the proxy is host-side |

## 11. Open questions

1. **A real operator credential.** On a single-user host, "operator-only"
   holds against workers but not necessarily against a coordinator session
   driving the same user's shell (§6.4). bd-8381tk is choosing the proof
   mechanism for write-capable tokens. Does it also need to separate the
   operator from the coordinator, for example with a WebAuthn-confirmed
   dashboard action?
2. **PHI agreements.** Which accounts may hold `phi_data` is a compliance
   decision for the operator, outside Arbiter. The design only records it.
3. **Infra host sets per CLI,** and whether agy's and Codex's own HTTP stacks
   honour `HTTPS_PROXY` (G4). The claude binary carries Bun's proxy-env
   handling (`HTTPS_PROXY`, `NO_PROXY` strings in 2.1.285). That is not a
   live test.
4. **The EC2's kernel.** Its `user.max_user_namespaces`, whether `socat` is
   installed, and whether a Secret Service runs there are all unverified.
   bd-8xy1mf's two-host check and G4 cover them.
5. ~~**The filtered keyring is still the whole keyring.** A Secret-Service-only
   bus gives agy the whole unlocked collection, including `gh`'s token.
   Should agy move to file-seeded credentials everywhere?~~ **Answered (bd-6dpjw7, bd-8btihu): No.**
   agy 1.2.16 cannot authenticate from legacy file copies, and copying refresh
   tokens risks token-rotation divergence. The keyring D-Bus proxy remains the
   only working credential path; file-seeded fallback was removed in bd-8btihu.
6. **Read scoping.** Should it be a denylist (G3, proposed) or an allowlist
   (`--tmpfs $HOME` plus read-only toolchain re-binds)? The allowlist is
   stronger but riskier for toolchains.
7. **The coordinator's authority over `prod_read`.** Should a coordinator be
   able to declare `prod_read` at filing when the binding is enforced
   read-only (proposed), or should it always need the operator?

## Appendix A: probes

Everything ran as the operator's user on the laptop, under
`/tmp/bd8apkz6`. No agent CLI was run, and the live Arbiter endpoint was not
contacted. `egress_proxy.py` is a ~40-line Python asyncio CONNECT proxy on a
Unix socket with an in-code allowlist of `{("example.com", 443),
("github.com", 22)}`. It logs `ALLOW`/`DENY host:port socket=<path>`. A
`python3 -m http.server` on a random loopback port stood in for Arbiter,
reached through a host-side `socat UNIX-LISTEN:…arbiter.sock,fork
TCP:127.0.0.1:<port>`.

**E2 probe** (Fedora bwrap 0.12.0; the el8 run swaps in the bwrap 0.4.0
binary and adds the §2.1 tmpfs mounts):

    bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /dev/shm \
      [--tmpfs /run/user/1000 --tmpfs /run/dbus --tmpfs /run/systemd/resolve] \
      --bind /tmp/bd8apkz6/egress /tmp/egress --bind inside.sh /tmp/inside.sh \
      --unshare-net --unshare-pid --die-with-parent --new-session --chdir /tmp -- sh /tmp/inside.sh

    # inside.sh
    socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/tmp/egress/proxy.sock &
    socat TCP-LISTEN:4848,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/tmp/egress/arbiter.sock &
    curl -sS -m 5 https://example.com -o /dev/null
    HTTPS_PROXY=http://127.0.0.1:3128 curl -sS -m 15 https://example.com -o /dev/null -w 'http_code=%{http_code}\n'
    HTTPS_PROXY=http://127.0.0.1:3128 curl -sS -m 15 https://catbox.moe -o /dev/null
    curl -sS -m 5 http://127.0.0.1:4848/ -o /dev/null -w 'http_code=%{http_code}\n'
    ssh -F /dev/null -o BatchMode=yes -o PubkeyAuthentication=no -o IdentityAgent=none \
      -o ProxyCommand='socat - PROXY:127.0.0.1:%h:%p,proxyport=3128' -T git@github.com

Results are in §4.3. Raw lines from the el8 run:

    == netns interfaces:          lo
    == direct https (no proxy):   curl: (6) Could not resolve host: example.com
    == proxy allow example.com:443: http_code=200
    == proxy deny catbox.moe:443: curl: (56) CONNECT tunnel failed, response 403
    == loopback bridge 127.0.0.1:4848: http_code=200
    == systemd-run --user escape attempt: Failed to connect to user scope bus via local transport: No such file or directory
    el8 bwrap 0.4.0 exit=0
    HOST CHECK: ls: cannot access '/tmp/bd8apkz6/escape-marker-E': No such file or directory

**§2.1 escape** (the argv printed by `Arbiter.Worker.Jail.argv/2`, then run):

    jail exit: 0
    stdout: systemd-run-exit=0
    HOST CHECK:
    PRESENT on host: /tmp/bd8apkz6/wt/inside-ok
    absent on host:  /tmp/bd8apkz6/jail-inside-tmp-marker
    PRESENT on host: /tmp/bd8apkz6/escape-marker-J

**RHEL 8 package inventory** (`rockylinux:8` image, Rocky Linux 8.10, `dnf
repoquery`):

- bubblewrap-0.4.0-2.el8_10 [baseos]
- nftables-1.0.4-8.el8_10 [baseos]
- openssh-clients-8.0p1-33.el8_10 [baseos]
- socat-1.7.4.1-2.el8_10 [appstream]
- slirp4netns-1.2.3 [appstream]
- squid-4.15 [appstream]
- flatpak-1.12.9 [appstream], which ships `/usr/libexec/flatpak-dbus-proxy`

Not available: passt/pasta, tinyproxy, and xdg-dbus-proxy as a package. The
el8 `socat -h` (run in the container) lists `proxy:<proxy-server>:<host>:<port>`,
`tcp-listen:<port>`, `unix-connect:<filename>` and `unix-listen:<filename>`.

**Claude Code 2.1.285 sandbox strings** were read from the binary with
Python `mmap`. They include `--unshare-net`, "Linux HTTP bridge socket does
not exist", "Linux SOCKS bridge socket", `sandbox.network.httpProxyPort`,
`sandbox.network.socksProxyPort`, `allowUnixSockets`,
`network.allowManagedDomainsOnly` ("only managed settings may replace the
filtering proxy"), `CLAUDE_CODE_HOST_HTTP_PROXY_PORT` and
`enableWeakerNestedSandbox`.
