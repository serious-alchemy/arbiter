# Core/Pro Extension Seams — Inventory and Gaps

**Status:** Proposal for the operator to rule on (bd-89v7hp). This proposal changes no code and files no issues.
**Companion to:** [Licensing Model & Open-Core Architecture](licensing-model.md) §5 ("Extension Seams in the Existing Codebase").
**Baseline:** `main` at `a99a3735` (2026-09-23). Every `file:line` below is at that commit and is relative to `apps/arbiter/lib/arbiter/` unless it starts with `apps/`, `docs/`, or `test/`.

This document does **not** decide what goes into Pro. It decides where the *hinges* should go, so that the later decision is cheap in either direction.

---

## 0. Headline findings

1. **The decision record's premise, "clean extension seams are already established", is half true.** Five of the six named behaviours are genuine policy seams, and four of those already select an implementation **per workspace**. But **none of the six can accept an implementation from a package outside the umbrella.** Every registry is a closed, compile-time `@adapters` / `@policies` map. Several also have hard-coded `case` statements beside them that seed per-adapter config outside the behaviour. A Pro package today cannot add a tracker, merger, agent, routing policy, or quota gate without editing core.
2. **The `Application.get_env/3` module-swap idiom is not how the policy seams resolve, and it should not become how they do.** It is install-global. For the policy seams it is used only by `Quota.Gate`, where a global override *beats* every workspace. The per-workspace half of the problem is already solved by `workspace.config` keys. The missing half is **open registration**, and it can stay install-global (§4).
3. **There are now 16 `@callback` modules, not 17.** `Arbiter.Workflows.QuotaGate` was deleted with the Conductor in `a05a2403` (#1965, 2026-09-22). `Arbiter.Quota.Gate` is the one and only quota policy seam (§3).
4. **`Arbiter.MCP.Catalog` cannot admit tools from an external package. The answer is no** (§5).
5. **`Quota.Gate` has the wrong shape for a Pro gate:** the board's promotion gate bypasses the resolved module (§2.6).
6. **`Routing.Policy` has the wrong shape for a Pro policy:** it is fed an always-empty ledger and is called several times per dispatch (§2.5).

---

## 1. Classification of every `@callback`-defining module

Each module is classified as one of:

* **Seam:** a genuine policy seam; a Pro implementation is plausible.
* **Internal:** not a seam; it exists for testing or for polymorphism within core.
* **Uncertain:** could go either way; the reason is given.

| # | Module | File | Class | One-line reason |
|---|---|---|---|---|
| 1 | `Arbiter.Agents.Agent` | `agents/agent.ex` | **Seam** | An adapter for an enterprise model gateway or another vendor's CLI is a plausible Pro deliverable, and selection is already per workspace (`config["agent"]["type"]`, `agents.ex:57-58`). |
| 2 | `Arbiter.Trackers.Tracker` | `trackers/tracker.ex` | **Seam** | Enterprise trackers (Azure DevOps, ServiceNow, Jira DC with SSO) are the textbook paid adapter, and selection is per workspace (`trackers.ex:332`). |
| 3 | `Arbiter.Mergers.Merger` | `mergers/merger.ex` | **Seam** | Additional forges (Bitbucket, Azure Repos, Gerrit) and merge-train strategies are plausible paid adapters, and selection is per workspace (`mergers.ex:36`). |
| 4 | `Arbiter.Sessions.Provider` | `sessions/provider.ex` | **Internal** | Two callbacks (`command/1`, `env/1`) naming the CLI that runs in a coordinator tmux pane. It is a per-provider companion of `Agents.Agent` and encodes no policy. The decision record's description ("PTY/terminal and process launch providers") overstates it. |
| 5 | `Arbiter.Agents.Routing.Policy` | `agents/routing/policy.ex` | **Seam** | "Which model for which task" is the most obviously sellable policy, and selection is per workspace (`config["routing"]["policy"]`, `agents/routing.ex:63-72`). |
| 6 | `Arbiter.Quota.Gate` | `quota/gate.ex` | **Seam** | Quota and budget policy at the single dispatch choke point; a stricter or budget-denominated gate is plausible Pro. |
| 7 | `Arbiter.Workflows.QuotaGate` | *(deleted)* | **Internal** | Removed in `a05a2403` (#1965). It was the Conductor-only concurrency clamp layered over `Quota.Gate`'s shared helpers (§3). |
| 8 | `Arbiter.Workflow` | `workflow.ex` | **Internal** | A step DSL for core-defined workflows (`Workflows.Work`, `CodeReview`, `ReviewReply`). Callers name the module directly (`reviews/external_review.ex:677`, `worker/dispatch.ex:1306`), and there is no registry. |
| 9 | `Arbiter.MCP.AgentConfig` | `mcp/agent_config.ex` | **Internal** | A per-agent-CLI writer for the `.mcp.json`-style config file. It is a companion of `Agents.Agent` with a closed map (`mcp/agent_config.ex:23`). |
| 10 | `Arbiter.Sessions.Runner` | `sessions/runner.ex` | **Internal** | Its moduledoc says it is "the test seam as well" for the `systemd-run`/`tmux` shell-outs. The only real implementation is `Runner.Host`. |
| 11 | `Arbiter.Sessions.Terminal` | `sessions/terminal.ex` | **Uncertain** | A test seam today (`Terminal.Tmux` plus a stub), but it is the only abstraction behind which a remote or containerized session host could sit. A hosted or multi-host tier would need exactly that. It is resolved install-global (`sessions.ex:619-621`). |
| 12 | `Arbiter.Workflows.PatrolServer` | `workflows/patrol_server.ex` | **Internal** | A `use` scaffold sharing GenServer plumbing between the in-tree patrols. It is code reuse, not a plug point. |
| 13 | `Arbiter.Workflows.MergeQueue.AutoResumeDispatcher` | `workflows/merge_queue/auto_resume_dispatcher.ex` | **Internal** | A behaviour that implements itself (`@behaviour __MODULE__`, :45). It is swapped only through `Watchdog` opts so tests do not spawn workers (`worker/watchdog.ex:369,1033`). |
| 14 | `Arbiter.Workflows.MergeQueue.ConflictResolver` | `workflows/merge_queue/conflict_resolver.ex` | **Internal** | It implements itself (:65) and is swapped via opts or `:merge_queue_conflict_resolver` (`workflows/merge_queue.ex:397-401`) for tests. The resolution intelligence lives in the spawned worker's prompt, not here. |
| 15 | `Arbiter.Workflows.MergeQueue.FixPassDispatcher` | `workflows/merge_queue/fix_pass_dispatcher.ex` | **Internal** | It implements itself (:58) and is swapped only via the `Watchdog` `:fix_pass_dispatcher` opt (`worker/watchdog.ex:327,836`). |
| 16 | `Arbiter.Workflows.MergeQueue.ReviseDispatcher` | `workflows/merge_queue/revise_dispatcher.ex` | **Internal** | It implements itself (:49) and is swapped via opt or `:merge_queue_revise_dispatcher` (`workflows/merge_queue.ex:407-411`) for tests. |
| 17 | `Arbiter.Workflows.ReviewGateFixRoundDispatcher` | `workflows/review_gate_fix_round_dispatcher.ex` | **Internal** | It implements itself (:68). Its `impl/0` global `get_env` (:135) exists "so the test environment … can swap the implementation" (:130-131). |

**Tally:** 5 seams, 1 uncertain, 11 internal. `Agents.Agent`, `MCP.AgentConfig` and `Sessions.Provider` (plus a quota-snapshot normalizer, §2.1) form one **provider bundle**. Adding an agent CLI means implementing all of them, so they must open together even though only `Agent` is classed as the seam.

---

## 2. The six named seams: callbacks and sufficiency

For each seam: the callbacks as defined today, and whether an alternate implementation shipped from *outside the umbrella* could work with them unchanged. The answer is **no** for all six, because none has open registration (§4). The rest of each entry covers what else is missing.

### 2.1 `Arbiter.Agents.Agent`: 13 callbacks (7 optional)

* **Required:**
  * `default_argv/2`
  * `init_session/1`
  * `parse_line/2`
  * `done_sentinel/0`
  * `usage_attrs/1`
  * `provider/0`
* **Optional:**
  * `spawn_env/1`
  * `resolved_model/1`
  * `security_enforced?/0`
  * `auth_probe_argv/1`
  * `async_tool_instruction/0`
  * `async_tool_instruction/3`
  * `async_arm_signature/0`

**Verdict: not sufficient.** The spawn, parse and usage contract is sound. What's missing:

* **Closed registration:**
  * `@adapters` (`agents.ex:42-46`)
  * `@valid_agent_types` (`agents.ex:48`), which config validation reads (`tasks/workspace/changes/validate_config.ex:203`)
  * the hard-coded fallback list (`agents.ex:201,210`)
* **Config seeding is outside the behaviour.** `Agents.prepare/2` calls `Claude.Config`, `Gemini.Config` and `Codex.Config.put_active/2` by name (`agents.ex:253-258`). It needs an optional `prepare(workspace, role)` callback.
* **An undeclared contract.** `splice_prompt/2` is probed with `function_exported?` (`worker.ex:3771,4267`) and implemented by all three adapters, but it is not a `@callback`.
* **Companion registries keyed by the provider atom.** A new agent must also land in each of these:
  * `MCP.AgentConfig`'s `@adapters` (`mcp/agent_config.ex:23`)
  * `Sessions.Provider`'s `@adapters` (`sessions/provider.ex:38`) and the `Session.provider` `one_of` (`sessions/session.ex:114,380`)
  * `Quota`'s `@provider_codes` (`quota.ex:162`)
  * a `Quota.Gate.Snapshot.normalize/2` clause per quota table (`quota/gate/snapshot.ex:111-169`)

  Without the last two, a Pro agent's dispatches are never quota-gated. Neither has a callback.

### 2.2 `Arbiter.Trackers.Tracker`: 22 callbacks (9 optional)

* **Required:**
  * `fetch/1`
  * `transition/2`
  * `update_fields/2`
  * `link_for/1`
  * `parse_ref/1`
  * `list_transitions/1`
  * `list_open/1`
  * `create/1`
  * `current_user/0`
  * `assignees/1`
  * `issue_status/1`
  * `extract_title/1`
  * `extract_description/1`
* **Optional:**
  * `extract_priority/1`
  * `extract_difficulty/1`
  * `extract_issue_type/1`
  * `add_remote_link/3`
  * `add_comment/2`
  * `gating_fields/2`
  * `check_prior_claim/1`
  * `signal_claim/3`
  * `search_by_title/1`

**Verdict: the operational surface is sufficient; the wiring is not.**

* **No workspace argument on any callback.** Adapters read per-process config seeded by hard-coded `case`s:
  * `Trackers.prepare/2` (`trackers.ex:82-93`)
  * `prepare_with_repo/3` (`trackers.ex:117-131`)
  * `do_with_workspace/3` (`trackers.ex:404-409`)

  A Pro tracker has no way to receive its config. It needs an optional `prepare(workspace, repo)` or `with_workspace/2` callback.
* **Closed registration:**
  * `@adapters` (`trackers.ex:27-34`)
  * `valid_tracker_types` in config validation (`validate_config.ex:81`)
* **The tracker type is persisted.** `Issue.tracker_type` is an Ash attribute with a compile-time `one_of: @tracker_types` (`tasks/issue.ex:81,713,725`). A new type is a resource-constraint change, not just a registry entry.

### 2.3 `Arbiter.Mergers.Merger`: 22 callbacks (11 optional)

* **Required:**
  * `open/4`
  * `get/1`
  * `merge/2`
  * `close/1`
  * `add_comment/2`
  * `request_review/2`
  * `link_for/1`
  * `get_diff/2`
  * `post_inline_comment/3`
  * `submit_review/4`
  * `list_review_feedback/1`
* **Optional:**
  * `update_branch/1`
  * `ancestor?/3`
  * `failing_check_logs/1`
  * `rerun_ci/2`
  * `ref_for_pr/2`
  * `list_open/0`
  * `list_open_review_threads/1`
  * `reply_to_review_comment/4`
  * `resolve_review_thread/3`
  * `list_required_check_failures/1`
  * `batch_pr_signals/1`

**Verdict: not sufficient.**

* **Config seeding is hard-coded.** The same shape as trackers: `Mergers.prepare/1` (`mergers.ex:80-88`) and `prepare_with_repo/2` (`mergers.ex:141-151`).
* **Closed registration:**
  * `@adapters` (`mergers.ex:24-28`)
  * `@valid_merger_strategies` (`tasks/workspace.ex:60`)
* **GitHub coupling outside the behaviour.**
  * `reviews/pr_state.ex:207` special-cases `Mergers.Github`.
  * `Mergers.Github.RepoResolver` is used directly by dispatch and the patrols (`worker/dispatch.ex:65`, `workflows/review_patrol.ex:338`, `workflows/pr_patrol_supervisor.ex:62`).

  A non-GitHub Pro merger would get the core lifecycle, but not PR/review patrol. There is no `resolve_repo` callback.

### 2.4 `Arbiter.Sessions.Provider`: 2 callbacks

* `command/1`
* `env/1`

**Verdict: sufficient for what it does, and what it does is small.**

* Closed map: `@adapters` (`sessions/provider.ex:38`).
* Closed attribute: `Session.provider` `one_of` (`sessions/session.ex:380`).
* The credential path is described as out-of-band (a "per-session config dir", moduledoc), with no callback for it.

It is not a seam on its own (see §1 row 4). It opens as part of the provider bundle.

### 2.5 `Arbiter.Agents.Routing.Policy`: 1 callback

* `choose(task, workspace, ledger_snapshot) :: %{type: atom(), config: map()}`

**Verdict: wrong shape for an advanced (Pro) policy.**

* **The ledger input is always empty.** Every call site passes `%{}`:
  * `worker/dispatch.ex:1042`
  * `worker/dispatch.ex:1074`
  * `worker/dispatch.ex:2155`
  * `worker/review_gate.ex:4226`

  `ByBudget` therefore never degrades (`agents/routing/by_budget.ex`, moduledoc: "only *useful* once the ledger is queried into a snapshot on every dispatch"). A cost-aware policy has no data.
* **`choose/3` is called more than once per dispatch.** Once to pick the quota-gate provider (`dispatch.ex:1074`) and again to build the spawn (`dispatch.ex:2155`), and the calls are not guaranteed to run in the same process. `RoundRobin` keeps its cursor in the process dictionary (`agents/routing/round_robin.ex:48-54`). Any stateful or learning policy can therefore gate on one provider and spawn on another. Either the contract must say "pure and idempotent", or core must call it once and thread the choice.
* **Missing inputs:** repo (acknowledged at `loop/canary.ex:64`), role (author, reviewer or implementer), provider availability, and quota headroom.
* **Missing output:** it cannot choose a **provider account or credential**. That is the lever cost-aware routing most wants, now that accounts exist (`accounts/provider_account.ex`).
* **Closed registration:** `@policies` and `@valid_policies` (`agents/routing.ex:34-41`).

### 2.6 `Arbiter.Quota.Gate`: 1 callback

* `check(task, quota, workspace, opts) :: :allow | {:hold, term()} | {:overage, float()}`

**Verdict: wrong shape.**

* **The board bypasses the gate.** The callback is consulted at dispatch (`worker/dispatch.ex:1095-1108`) and on queue drain (`workflows/dispatch_queue.ex:391-406`). But the board's promotion gate, `Board.Snapshot.quota_hold/1` (`board/snapshot.ex:504-540`), never calls `check/4`. It calls `Gate` helpers directly. And `Quota.continue_mode?/1` is a module-identity test against `Gate.Continue` (`quota.ex:149-151`).

  With a Pro gate installed, Autopilot and the board keep applying *core's* hold logic. The board paints holds the dispatcher would not honour, or promotes cards the dispatcher then holds. The gate needs a second callback, the board-level question: "is this workspace/provider/account held, and why?"
* **Wrong input for budgets.** The input is a provider *utilization* snapshot. There is no spend or budget input, so a dollar-denominated gate must query the ledger itself.
* **Wrong output for routing.** It cannot express "allow, but route cheaper". There is no `{:downgrade, choice}` decision, so quota and routing cannot cooperate.
* **Wrong resolution.** `Quota.gate_for_workspace/1` checks the global `:arbiter, :quota, :gate` override *first* (`quota.ex:126`). Per workspace, the only selector is the two-value `quota.on_exhaustion` enum. A Pro gate can therefore only be installed install-wide, for every workspace at once.

---

## 3. `Arbiter.Quota.Gate` vs `Arbiter.Workflows.QuotaGate`

**They were layered, not duplicate, and the question is now moot because `Workflows.QuotaGate` no longer exists.**

* **`Workflows.QuotaGate`** (last seen at `a05a2403^:apps/arbiter/lib/arbiter/workflows/quota_gate.ex`):
  * Declared `quota_headroom(provider_account_id, opts) :: non_neg_integer() | :unlimited`.
  * It was the **Conductor's per-graph concurrency clamp**, folded into `effective_cap = min(workspace_max, system_max, quota_headroom)`.
  * Its `Default` implementation deferred the over-cap decision to `Arbiter.Quota.Gate.over_cap?/2`, so it was a *consumer* of `Quota.Gate`'s shared logic that answered a different question ("how many slots?") at a different point (Conductor drain, not per dispatch).
  * It was swapped globally through `config :arbiter, :conductor_quota_gate`.
* **Removal:** it was deleted with the Conductor in `a05a2403` ("Remove workflow Graphs and the Conductor — the board scheduler is the only dispatcher", #1965, 2026-09-22). The commit says so explicitly: "`Workflows.QuotaGate` / `QuotaGate.Default` (Conductor-only; Autopilot reads `Quota.Gate` / `Board.Snapshot.quota_hold/1`)".
* **Surviving references are stale or negative:**
  * `apps/arbiter/test/arbiter/workflows/graph_removal_test.exs:16-17` asserts the module is *not* compiled.
  * `docs/provider-account-design.md:313,438,784` still describes it as live.
* **The policy seam is `Arbiter.Quota.Gate`,** with the shape defects in §2.6.

The "how many concurrent slots" question now has **no seam at all**. The board scheduler's slot gate reads `Settings.conductor_system_max_concurrent` and workspace `conductor.max_concurrent` directly. See §6, cross-workspace policy.

---

## 4. The `Application.get_env/3` module-swap idiom vs multi-workspace

### 4.1 Existing call sites

| Key | Default | Site | Kind |
|---|---|---|---|
| `:review_gate_fix_round_dispatcher` | self | `workflows/review_gate_fix_round_dispatcher.ex:135` | test seam (internal) |
| `:merge_queue_conflict_resolver` | `MergeQueue.ConflictResolver` | `workflows/merge_queue.ex:397-401` | test seam (internal) |
| `:merge_queue_revise_dispatcher` | `MergeQueue.ReviseDispatcher` | `workflows/merge_queue.ex:407-411` | test seam (internal) |
| `:dispatch_queue_dispatcher` | `Worker.Dispatch` | `workflows/dispatch_queue.ex:283` | test seam |
| `:migrations_module` | `Arbiter.Migrations` | `worker/dispatch.ex:901` | test seam |
| `:sessions_runner` | `Sessions.Runner.Host` | `sessions.ex:606-607` | test seam (internal) |
| `:sessions_terminal` | `Sessions.Terminal.Tmux` | `sessions.ex:619-621` | test seam (uncertain; §1 row 11) |
| `:quota` → `:gate` | nil, then `Throttle`/`Continue` by workspace | `quota.ex:126` | **the only policy seam using it**; kill switch plus test injection |
| `:github_limiter_server` | self | `github/limiter.ex:285` | swaps a *registered process name*, not a behaviour module |

The description cites `worker/dispatch.ex:747`. At this baseline that line is inside `resolve_session_resume_provider/3` and holds no `get_env`. The only module swap left in `dispatch.ex` is `:migrations_module` at :901.

**Five of the six named seams do not use `get_env` at all.** Agents, trackers, mergers, routing policies and session providers resolve through closed compile-time maps, keyed by a value read from `workspace.config` or the persisted row.

### 4.2 Evaluation

* A global `get_env` swap is fine for what it is used for today: test injection and kill switches.
* It **cannot** express "workspace A uses the Pro routing policy, workspace B uses core". The only way to bend it that far is to put workspace ids into release config, which inverts ownership: workspaces are runtime data, and release config is deploy-time.
* Where it does touch a policy seam (`quota.ex:126`), it actively *defeats* per-workspace selection, because the global override wins.

### 4.3 Is per-workspace seam resolution required? **Yes.**

"An installation can run multiple workspaces side by side, each with its own repos, tracker, and merge settings". A paid capability that can only be switched on for the whole installation forces the operator to buy Pro for every workspace, or for none. It also makes a gradual rollout (one workspace first) impossible.

The good news is that **per-workspace *selection* already exists for four of the five genuine seams.** What is missing is **open *registration***, and registration does not need to be per workspace: a Hex package is installed per release, not per workspace.

### 4.4 Proposed mechanism: install-global registry, per-workspace selection

1. **`Arbiter.Extension` behaviour** (new):

   ```elixir
   @callback contributions() :: [{seam :: atom(), key :: String.t(), module()}]
   @callback mcp_tools() :: [Arbiter.MCP.Catalog.tool()]   # optional, see §5
   ```

   Here `seam` is one of `:agent`, `:tracker`, `:merger`, `:routing_policy`, `:quota_gate`, `:session_provider`, `:mcp_agent_config`, `:quota_snapshot`.
2. **Registration:** `config :arbiter, :extensions, [ArbiterPro.Extension]`, read once at boot. This is the one legitimate install-global `get_env`.
3. **`Arbiter.Extensions`** (new) loads the list in `Arbiter.Application.start/2` before any consumer starts. It:
   * checks that each contributed module exports every non-optional callback of the seam's behaviour (`behaviour_info(:callbacks)`);
   * **fails boot** on a key that collides with a core key, so Pro can add but never shadow core, per the additive-only policy in `licensing-model.md` §6;
   * stores the merged maps in `:persistent_term`. A lookup is one term read, so the per-dispatch cost is negligible.
4. **Each dispatcher's registry becomes `core ∪ extensions`:** `Agents.adapters/0`, `Trackers.adapters/0`, `Mergers.adapters/0`, `Routing.policies/0`, `Sessions.Provider.adapter/1`, `MCP.AgentConfig`, and the quota-gate and snapshot lookups. The `valid_*` lists derive from the merged maps, so `ValidateConfig` accepts `tracker.type: "azure_devops"` exactly when a package that provides it is installed.
5. **Selection stays in `workspace.config`**, under keys that already exist: `agent.type`, `tracker.type`, `merge.strategy`, `routing.policy`. There is one new key, `quota.gate`: a registry key, with the existing `quota.on_exhaustion` kept as core shorthand. `ValidateConfig` already allows unknown top-level keys (`validate_config.ex:47`), so a Pro-specific config block needs no migration.
6. **Demote `:arbiter, :quota, :gate`** to a test-and-kill-switch seam that can only force the core `Throttle`, never install a policy.
7. **Missing callbacks** added as optional, defaulting to today's behaviour:
   * `prepare(workspace, opts)` on `Agent`, `Tracker` and `Merger`
   * `splice_prompt/2` declared on `Agent`
   * a board-level hold callback on `Quota.Gate`
8. **Persisted atoms:** `Issue.tracker_type` (`tasks/issue.ex:713,725`) and `Session.provider` (`sessions/session.ex:380`) drop the compile-time `one_of` in favour of a runtime validation against the registry. A row whose provider package was later uninstalled degrades the way `Trackers.adapter_for_workspace_type/2` already does (warn, fall back to `None`, `trackers.ex:368-385`) instead of failing to load.

**Modules that would change:**

* **New:**
  * `extension.ex`
  * `extensions.ex`
* **Boot:**
  * `application.ex`
* **Registries:**
  * `agents.ex`
  * `agents/agent.ex`
  * `agents/routing.ex`
  * `trackers.ex`
  * `trackers/tracker.ex`
  * `mergers.ex`
  * `mergers/merger.ex`
  * `quota.ex`
  * `quota/gate.ex`
  * `quota/gate/snapshot.ex`
  * `sessions/provider.ex`
  * `mcp/agent_config.ex`
* **MCP catalog (§5):**
  * `mcp/catalog.ex`
  * `mcp/refine_policy.ex`
* **Persistence and validation:**
  * `tasks/issue.ex`
  * `sessions/session.ex`
  * `tasks/workspace.ex`
  * `tasks/workspace/changes/validate_config.ex`
* **Callers:**
  * `board/snapshot.ex`
  * `worker/dispatch.ex`
  * `worker/review_gate.ex`
  * `worker.ex`

---

## 5. Can `Arbiter.MCP.Catalog` accept tools from an external package? **No.**

* **The tool list is fixed at compile time.** It is a compile-time literal, `@raw_tools [...]` (`mcp/catalog.ex:134`), post-processed into the module attribute `@tools` (`mcp/catalog.ex:2206`).
* **Every read goes through `@tools` and nothing else.** That covers:
  * `all/0` (:2218)
  * `visible/1` (:2230-2231)
  * `fetch/1` (:2235)
  * `call/3` (:2253)

  None consults application env, a registry or a runtime table.
* **Its consumers are fixed too.** The transport consumes only `Catalog.visible/1` and `Catalog.call/3` (`apps/arbiter_web/lib/arbiter_web/mcp/plug.ex:355,372`). The tier vocabulary is the closed `:worker | :coordinator | :refine` (`mcp/scope.ex:81,96`).

The *shape* is extension-friendly. A tool is a plain map with a `handler` function capture (`mcp/catalog.ex:95-101`), and `RefinePolicy` is an exhaustive allow-list that **denies** any tool it has not ruled on (`mcp/refine_policy.ex:54-195`). So an externally registered tool would be safely invisible to browser refine sessions by default.

The fix is small. Build `@tools ++ Extensions.mcp_tools()` at boot into `:persistent_term`, and have `all/0`, `visible/1` and `fetch/1` read that. Reject name collisions with core tools at boot. Until then, a Pro tier ships no MCP tools.

---

## 6. Candidate commercial capabilities → seam status

| Capability | Status | Detail |
|---|---|---|
| **Cost attribution & chargeback** | **Seam missing** (`Arbiter.Usage`) | The ledger (`usage/event.ex`) attributes cost to task, workspace, repo, model, provider, provider account, credential, worker run and session. It has no team, cost-centre, tag or user dimension. `Usage.summarize/1` groups only by the closed `@valid_by` list (`usage.ex:104`). Pricing is hard-coded per provider (`usage/claude_pricing.ex:85-117`, `agents/gemini/pricing.ex:54`), and Codex cost is always nil (`agents/codex/stream.ex:55`). Rows are written with direct `Ash.create` calls from six places with no hook (e.g. `worker.ex:1686`, `sessions/usage_ingest.ex:443`). **Needed:** a `Usage.Attributor` behaviour (extra dimensions at write time), an open `group_by` registry, and a `Pricing` behaviour. The cheapest time to add the dimension column is before a customer's ledger is large. |
| **RBAC & SSO** | **Seam missing** (`ArbiterWeb.Router` / `Arbiter.MCP.Scope`) | There is no user, role or membership resource. The `:browser` pipeline has no auth plug (`apps/arbiter_web/lib/arbiter_web/router.ex:44-51`). `ApiAuth` lets an unauthenticated loopback request through as `mcp_scope: nil` (`apps/arbiter_web/lib/arbiter_web/plugs/api_auth.ex:54-55`). No Ash resource declares `policies` or `authorizers`, and `actor:` is passed only as a PaperTrail label (`paper_trail.ex`). The only authorization concept is the three-tier MCP `Scope`. **Needed:** an authentication plug slot in both pipelines, an `Arbiter.Actor` notion threaded as the Ash actor, and Ash policy stubs that core satisfies trivially (single operator) and Pro can tighten. This is the most expensive seam to retrofit, because every LiveView mount and Ash call site gains an actor. |
| **Cross-workspace policy enforcement** | **Seam missing** (`Arbiter.Settings` / `ValidateConfig`) | Installation-wide settings (`settings.ex`, `installation_settings`) and per-workspace `config` compose through hard-coded precedence rules: quota `min(account, workspace)` (`quota/gate.ex`), security-policy floor (`agents/security_policy.ex:198-272`), and slot caps (`board/snapshot.ex:410`). No hook can veto or clamp a workspace's config against an org policy. **Needed:** a `Workspace.ConfigPolicy` behaviour invoked from `ValidateConfig.change/3` (`validate_config.ex:56`), plus a read-time clamp at the existing precedence resolvers. |
| **Compliance-grade audit & retention** | **Seam is wrong shape** (`Arbiter.Events` / retention) | `Events.Record` exists and is broadcast on PubSub (`events.ex:124-142`), but it is mutable (`defaults [:read, :destroy]`, `events/record.ex:41`) and pruned at 7 days by default (`events/retention.ex`). `usage_events` is also destroyable (`usage/event.ex:91`) and has no retention policy at all. Retention is config values, not a policy seam. AshPaperTrail covers `Workspace`, `Issue`, `Skill`, `Dependency` and `PendingWrite` only. There are **no** `:telemetry.execute` calls in app code. **Needed:** an `Arbiter.Audit.Sink` behaviour (or `:telemetry` events at the existing `Events.broadcast/3` choke point, which costs nothing if nobody attaches), and a `Retention.Policy` behaviour so a Pro tier can hold records for longer, export them, or seal them. |
| **Advanced model routing** | **Seam exists: `Arbiter.Agents.Routing.Policy`, wrong shape** | See §2.5: it is never fed ledger data, it is called several times per dispatch, it cannot pick an account, and its registry is closed. |
| **Quota / budget policy** | **Seam exists: `Arbiter.Quota.Gate`, wrong shape** | See §2.6: the board bypasses it, its input is utilization-only, it cannot downgrade, and a global override beats the workspace. The dollar-denominated pieces are advisory only: `Usage.Budget`/`BudgetPatrol` page and never block (`usage/budget_patrol.ex`), `quota.overage_alert_usd` only alerts, and `routing.budget_usd_per_day` is inert. |

---

## 7. Proposed seam work, prioritized

This list is ordered by **(cost to add later) − (cost to add now)**: the widest gap comes first. Sizes are D0–D4. These are proposals for the operator to rule on; none has been filed.

1. **Open registration: `Arbiter.Extension` plus `Arbiter.Extensions` (§4.4 items 1–5).** **D3.** Every other Pro seam depends on it. Once a Pro package exists, it would have to monkey-patch closed maps, and changing the registry contract then breaks a shipped customer artifact.
2. **Actor threading and an auth plug slot (RBAC/SSO groundwork).** **D4.** This touches every Ash call site and LiveView mount. It grows linearly with the codebase every week, and retrofitting it under a paying customer's SSO integration is the single most expensive item on this list.
3. **Replace the persisted-atom `one_of` constraints with registry validation** (`tasks/issue.ex:713,725`, `sessions/session.ex:380`). **D2.** Constraint changes on persisted rows get more expensive with every stored row and every downstream consumer of the enum. It is cheap while only core types exist.
4. **Attribution dimensions on `usage_events` plus a `Usage.Attributor` write hook.** **D2.** Chargeback over history needs the dimension on rows written *now*. Every month without it is ledger that can never be attributed retroactively.
5. **Add `prepare(workspace, opts)` callbacks to `Agent`, `Tracker` and `Merger`, and delete the hard-coded `case` seeding** (`agents.ex:253-258`, `trackers.ex:82-131,404-409`, `mergers.ex:80-151`). **D2.** This is a mechanical refactor with three in-tree adapters each. It gets worse with every adapter added in the meantime (Linear and Shortcut already doubled the tracker count).
6. **`Quota.Gate` board-hold callback, and route `Board.Snapshot.quota_hold/1` through the resolved gate; demote the global `:gate` override** (§2.6). **D2.** The board/dispatcher divergence is latent today because there are only two in-tree gates. A third implementation exposes it immediately, and the fix is a callback addition that is breaking once external implementations exist.
7. **Single routing decision per dispatch, and a real ledger snapshot for `Routing.Policy.choose/3`** (§2.5). **D2.** Adding required inputs to a one-callback behaviour is a breaking change for every external implementation, so they should be added before any exist. The multiple-call inconsistency is already a latent bug for `RoundRobin`.
8. **Open `MCP.Catalog` to `Extension.mcp_tools/0`** (§5). **D1.** Small and self-contained, and adding it later is not much costlier. It ranks here only because it is the difference between a Pro tier that can and cannot ship coordinator tools.
9. **Audit sink and `:telemetry` events at `Events.broadcast/3`, plus a `Retention.Policy` behaviour.** **D2.** Emitting telemetry costs nothing until attached. Retention is later-cheap *except* that records pruned under the 7-day default before a customer arrives cannot be recovered.
10. **`Workspace.ConfigPolicy` hook in `ValidateConfig`** (cross-workspace policy). **D1.** There is one choke point (`validate_config.ex:56`), so it is cheap now and only moderately worse later.
11. **`Pricing` behaviour replacing the per-provider price tables.** **D1.** It is small and isolated. Later-cost stays low because prices are read at a few sites.
12. **Documentation fixes.**
    * `docs/licensing-model.md` §5 should say 16 behaviours, drop the claim that seams are "already established", and re-describe `Sessions.Provider`.
    * `docs/provider-account-design.md:313,438,784` still describes the removed `Workflows.QuotaGate`.

    **D0.** This is cheap at any time. It is listed last only because it carries no later-cost penalty, but it should ride along with item 1.

**Explicitly not proposed:** promoting any of the eleven internal behaviours (§1) to seams. They exist for test injection or code reuse, and freezing them as a public contract would add cost with no commercial upside. `Sessions.Terminal` (uncertain) should be revisited only if a hosted or multi-host tier becomes a real candidate.
