defmodule Arbiter.Tasks.Workspace.ConfigSchema do
  @moduledoc """
  A comprehensive, human-readable reference for every key `workspace.config`
  accepts. Served by `GET /api/workspaces/config_schema` and the MCP
  `workspace_config_schema` tool, and printed by `arb config schema`.

  Lives next to `Arbiter.Tasks.Workspace.Changes.ValidateConfig` (the enforcer
  this text documents) in core so every surface reads one copy; the enum lists
  below are literal, and `Arbiter.Tasks.Workspace.ConfigSchemaTest` asserts each
  is byte-for-byte equal to the matching `valid_*/0` function so a change to the
  validator without a matching update here fails CI instead of silently
  drifting.
  """

  @tracker_types ~w(none jira shortcut linear github gitlab)
  @merger_strategies ~w(direct gitlab github)
  @agent_types ~w(claude gemini codex grok)
  @routing_policies ~w(static by_priority by_difficulty by_budget round_robin)
  @security_modes ~w(auto strict bypass)
  @sandbox_filesystems ~w(worktree none)
  @safe_default_categories ~w(no_destructive_fs no_force_push no_secret_reads no_outside_writes no_pr_create no_async_wait no_public_upload no_gh_publish)
  @review_automation_modes ~w(auto report_only propose flag notify off never disabled)
  @quota_modes ~w(throttle continue)

  # Every top-level key the reference below documents, plus the ones other
  # subsystems own (skills, refine, coordinator_notifications, the deprecated
  # security block). A `:patch_config` write of any other root is refused.
  @top_level_keys ~w(tracker merge agent review_agent security guardrails routing review
                     review_gate notes_gate review_automation quota conductor worker attention
                     loop standing_orders repo_paths default_repo pr_patrol review_patrol skills
                     refine coordinator_notifications)

  # Roots whose children live under `agent.security.` — writing one at the top
  # is the mistake this table exists to catch (bd-311cun).
  @security_roots ~w(sandbox permissions)

  @doc "The top-level keys a config write may set without `force`."
  @spec known_top_level_keys() :: [String.t()]
  def known_top_level_keys, do: @top_level_keys

  @doc """
  The canonical dotted path for a key written at the wrong root, or `nil` when
  there is no confident suggestion (e.g. `sandbox.backend` ->
  `agent.security.sandbox.backend`).
  """
  @spec suggest_path(String.t()) :: String.t() | nil
  def suggest_path(path) when is_binary(path) do
    case String.split(path, ".", parts: 2) do
      [root | _] when root in @security_roots -> "agent.security." <> path
      ["security" | _] -> "agent." <> path
      _ -> nil
    end
  end

  @doc false
  def tracker_types, do: @tracker_types
  @doc false
  def merger_strategies, do: @merger_strategies
  @doc false
  def agent_types, do: @agent_types
  @doc false
  def routing_policies, do: @routing_policies
  @doc false
  def security_modes, do: @security_modes
  @doc false
  def sandbox_filesystems, do: @sandbox_filesystems
  @doc false
  def safe_default_categories, do: @safe_default_categories
  @doc false
  def review_automation_modes, do: @review_automation_modes
  @doc false
  def quota_modes, do: @quota_modes

  @doc """
  The reference as a machine-readable map: the rendered `text` plus the enum
  lists it interpolates, keyed by the config field they constrain.
  """
  @spec describe() :: map()
  def describe do
    %{
      text: render(),
      enums: %{
        tracker_types: @tracker_types,
        merger_strategies: @merger_strategies,
        agent_types: @agent_types,
        routing_policies: @routing_policies,
        security_modes: @security_modes,
        sandbox_filesystems: @sandbox_filesystems,
        safe_default_categories: @safe_default_categories,
        review_automation_modes: @review_automation_modes,
        quota_modes: @quota_modes
      }
    }
  end

  @doc "Renders the full workspace config reference as plain text."
  @spec render() :: String.t()
  def render do
    """
    WORKSPACE CONFIG REFERENCE

    Every top-level key of `workspace.config` (all optional). An unknown
    top-level key is refused by `arb config set` / REST / MCP unless forced, and
    a known leaf written at the wrong root is answered with the canonical path
    (e.g. `sandbox.backend` -> `agent.security.sandbox.backend`). Enforced
    server-side by Arbiter.Tasks.Workspace.Changes.ValidateConfig — this
    reference is tested against that module so it can't silently drift.

    tracker  (map)
      type    one of: #{Enum.join(@tracker_types, ", ")}     (default: none)
      config  map, adapter-specific (host/project_key/owner/repo/…);
              credentials_ref: "env:VAR" | "secret:<key>" (see `arb workspace secret`)

    merge  (map)
      strategy             one of: #{Enum.join(@merger_strategies, ", ")}   (default: direct)
      config                map, adapter-specific (owner/repo/credentials_ref/…)
      auto_merge            bool — auto-merge an approved MR/PR         (default: false)
      pr_title_format       string, e.g. "conventional_commit"
      watchdog_max_polls    positive integer, or the string "infinity"
      watch_pipeline        bool — wait for CI before declaring merged  (default: false)
      repos                 map, repo_paths key -> per-repo override of any key
                            above (strategy, config, auto_merge, …). Deep-merged
                            over the workspace-level merge block, so unset
                            fields fall back field by field; e.g. a remote-less
                            repo in a github workspace:
                              arb config set merge.repos.mesaana.strategy direct
                            `arb server doctor` flags a forge-strategy repo with
                            no origin remote, or one whose origin is not the
                            effective merge.config owner/repo.

    agent / review_agent  (map — worker / reviewer respectively)
      type            one of: #{Enum.join(@agent_types, ", ")}, or a non-empty list of
                      those strings for a multi-provider pool           (default: claude)
      config          map, adapter-specific:
        model             concrete model name (overrides tier routing)
        credentials_ref   "env:VAR" | "secret:<key>"
        api_keys          list of credentials_refs, round-robin rotated
        tier_models       map, tier -> concrete model, e.g.
                          {"economy":"haiku","standard":"sonnet","premium":"opus"}
        thinking_argv     map, thinking level -> extra CLI argv, e.g.
                          {"high":["--effort","high"]}
        <provider>        (claude|gemini|codex) map — per-provider override
                          scope. In a multi-provider pool the flat keys above
                          are SHARED by every provider; nest an override here
                          to scope it to one adapter, e.g.
                          agent.config.codex.tier_models. A provider's own
                          sub-map is merged over the flat keys for that
                          provider only, so it never leaks to another.
      security        map — see "security" below; layered under agent.security
                      (workspace-level override of the install-wide default)
      cross_family    (review_agent only) bool — the ReviewGate reviewer's model
                      family must differ from the implementer's (bd-a1ke2c).
                      Every review pass (rounds, re-reviews, print-timeout
                      rotation) uses one family per task, picked by most quota
                      left among review_agent.type's other families at that
                      family's reviewer tier (Arbiter.Agents.ModelFamily). A
                      same-family review only when every other family is
                      unconfigured, quota-held, auth-expired or circuit-broken
                      — immediately, and recorded on the round. (default: false)

    security  (map, nested at agent.security)
      CANONICAL PATH: agent.security.permissions.mode
      ALWAYS WRITE THE FULL PATH: `arb config set agent.security.sandbox.backend
      podman`, never `sandbox.backend` (a root `sandbox` key is refused).

      permissions.mode          one of: #{Enum.join(@security_modes, ", ")}  (default: bypass)
        bypass  — headless-safe default; skips the interactive permission
                  classifier so a --print run can never freeze on a prompt.
                  Deny list is still enforced.
        auto    — classifier active (auto-accepts edits, can still pause to
                  ask); do NOT use for headless workers, only supervised runs.
        strict  — only explicitly allowed tools run; unlisted tools are denied.
      permissions.allow         list of operator-added allow rules (adapter-interpreted)
      permissions.deny          list of operator-added deny rules (adapter-interpreted)
      permissions.safe_defaults DEPRECATED / INERT — no longer narrows the
                                resolved set (bd-4420va: a pinned list used to
                                replace the baseline, so a workspace that
                                pinned it silently never got a category added
                                later). Still parsed without error for
                                backward compat, but has no effect. Use
                                permissions.safe_defaults_exclude instead.
      permissions.safe_defaults_exclude
                                list of baseline destructive-op categories to
                                turn OFF by name — the only supported way to
                                drop one, each one of:
                                #{Enum.join(@safe_default_categories, ", ")}
                                (default: []; every current category applies)
      sandbox.enabled           bool                                     (default: true)
      sandbox.filesystem        one of: #{Enum.join(@sandbox_filesystems, ", ")}       (default: worktree)
      sandbox.network           bool — false cuts network-egress tools   (default: true)

      DEPRECATED (backward compat only, do not use in new configs):
        - top-level security.mode (use agent.security.permissions.mode instead)
        - agent.config.security_mode (use agent.security.permissions.mode instead)

    guardrails  (map — per-subject guardrail caps and ticket-permission bindings; bd-anwb0u)
      Tighten-only per workspace: it can only lower what the installation's subject
      rules (the guardrail_subjects table) assigned. A block with no subject rules
      behind it enforces nothing. Loosening it (or agent.security) is operator-only;
      a coordinator token may only tighten. Unknown keys are refused.
      subjects[]    list of caps: {match: {provider|family|model}, max_tier, min_mode,
                    egress, max_difficulty, spend: {action, tokens, wall_clock_s},
                    review: {cross_family, same_family_fallback, min_reviewer_tier}}
                    max_tier: quarantine | probation | trusted | privileged
      bindings      map permission-name -> {grant_by: operator|coordinator, min_tier,
                    enforced_read_only, tunnels, hosts, env_from_secret, ssh_key_secret,
                    token_secret}
      defaults      {permissions: [name, …]} granted to every ticket by default
      repos.<repo>  {defaults, subjects} — the same shapes, scoped to one repo

    routing  (map)
      policy    one of: #{Enum.join(@routing_policies, ", ")}   (default: static)
      rules     map, policy-specific:
                  by_priority   — "P0".."P4" -> partial agent-config map
                  by_difficulty — "D0".."D5" -> partial agent-config map
                                  (default mapping: D0=economy/none, D1=economy/low,
                                   D2=standard/medium, D3=premium/high,
                                   D4=premium/max, D5=premium/max. D5 is the tier
                                   to point at a flagship model via tier_models.)
      base_policy         (by_budget only) "by_priority" | "by_difficulty" (default: by_priority)
      budget_usd_per_day  (by_budget only) number — degrades one model tier once
                          today's spend crosses this ceiling
      adapters            (round_robin only) list of partial agent-config maps,
                          cycled per dispatch
      provider_selection  "failover" | "most_quota" | "scored" (default: failover — today's
                          first-healthy agent.type). most_quota sends the
                          implementer to the workspace's implementer-allowed
                          provider account with the most quota headroom against
                          its pace, pins it on the task for every later
                          implementer role, and records the decision on each
                          run. Keep it OFF until the agy write jail lands.
                          scored routes like most_quota but also prices every
                          candidate (headroom ÷ expected draw, plus a priority-
                          weighted time term) — see scoring.mode.
      scoring.mode        "shadow" (default) | "enforce" — under scored, shadow
                          dispatches by most_quota and only records the scorer's
                          choice (routing_decision.shadow); enforce dispatches
                          by the scorer's order.
      scoring.time_weight map "P0".."P4" -> non-negative number: the weight of the
                          expected-time-to-merge term for a ticket's own priority
                          (default 0 for every priority).
      scoring.competence  bool (default: false) — under scored, use the hand
                          competence matrix to estimate expected draw and time
                          to close for each candidate model and task difficulty.
      scoring.reviewer_coupling bool (default: false) — under competence, project
                          the cross-family reviewer and price review runs on the
                          projected reviewer's quota pool.
      grok.enabled        bool (default: false) — send D1 tickets to grok (free tier,
                          ~500K tokens/day). Applies under every policy and over
                          provider_selection; a caller-named provider still wins.
      grok.difficulties   list of 0..5 (default: [1]) — the difficulties grok takes
                          when grok.enabled is true.
      capability_gates    bool (default: false) — drop a candidate that lacks a required
                          capability (reason capability_missing) before quota is
                          weighed, in both routers and on the unrouted dispatch
                          path. A resume role requires `resume`; a repo adds more.
                          The matrix is code defaults plus an operator-owned
                          installation override.
      repos.<repo>.requires  list of capabilities (resume, async_verification) every
                          dispatch for that repo requires of its provider, e.g.
                          a repo whose suite takes minutes: ["async_verification"].
      floors.repos.<repo>.min_model_tier  economy | standard | premium | flagship —
                          the blast-radius floor: a task in that repo never routes
                          below this tier, even when a rule or a Stage 3 canary
                          assigns a lower one (the tier is clamped up, the run is
                          recorded floor_clamped, and Canary.Metrics leaves it
                          out); a pinned model below it is dropped (below_floor)
                          or the dispatch refused. Operator-owned: the Loop never
                          writes it. Absent means no floor.
      floors.policy_floor  bool (default: false) — the router drops (below_floor) a
                          candidate whose model is below the tier the routing policy
                          chose, so choosing among accounts can't buy quota with
                          quality.

    review / review_gate  (map)
      required    bool — whether a review round gates completion
      max_rounds  positive integer — caps difficulty-derived round count (min wins)
      require_ci_green  bool — (review only, bd-cut6uv) the ReviewGate waits for CI
                  to be green on the exact head SHA before it dispatches a reviewer,
                  and the reviewer skips the full test suite. Red CI re-runs the
                  failed jobs once (green on the re-run is recorded as a flake),
                  then goes to a fix pass; CI that never reports within
                  merge.watchdog_max_polls falls back to a reviewer that runs the
                  tests. Default: on for a github/gitlab merge strategy, off for
                  direct. Per-repo override: review.repos.<repo>.require_ci_green.

    notes_gate  (map — the research-directive notes gate, bd-4qjl0q)
      nudge_cap   non-negative integer — send-backs a research worker gets for
                  signalling done with blank `notes` before the gate escalates
                  to the coordinator. 0 escalates on the first trip. (default: 2)

    review_automation  (map)
      default          one of: #{Enum.join(@review_automation_modes, ", ")}
                       (report_only is an alias of propose; flag is an alias of notify;
                        off is an alias of never/disabled — refuses to dispatch a
                        reviewer at all, force: true overrides a single dispatch)
      auto_authors     list of strings — PR authors that always get "auto"
      repo_overrides   map, repo name -> one of the modes above

    quota  (map — quota-aware dispatch throttle)
      on_exhaustion       one of: #{Enum.join(@quota_modes, ", ")}
      overage_alert_usd   positive number (or its JSON string form)
      throttle_threshold  number in (0, 1] — 5h/session window ceiling
                          (default: 0.85)
      weekly_threshold    number in (0, 1] — 7d/weekly window ceiling
                          (default: 0.90; higher than the 5h ceiling because
                          the weekly window resets at most once a week, so
                          holding early parks the fleet for days)
      weekly_warning_policy  one of: ignore, hold — what a 7d `allowed_warning`
                          does. Default `ignore`: the warning tier is advisory,
                          `weekly_threshold` is the control. `hold` treats the
                          warning like a reject. A 7d `rejected` always holds
                          either way.
      pace_exempt_priority  0–4 or "none" — narrows the account's P0 pace
                          exemption (the account's `pace_exempt_priority`
                          grants it; a workspace can only narrow it, never
                          grant it). "none" switches it off here.
      pace_exempt_threshold, weekly_pace_exempt_threshold
                          number in (0, 1] — lowers the account's 5h / 7d
                          exempt cap, the ceiling an exempt dispatch may lift
                          the paced line to. Never raises it; never above the
                          flat ceiling.

    conductor  (map)
      max_concurrent  positive integer — cap on concurrently-dispatched workers

    worker  (map — how a worker checkout is provisioned, bd-2jerqw)
      placement       "local_only" (default — every run stays on this machine),
                      "prefer_remote" (the podman-backed Claude implementer
                      goes to an enrolled node with a free slot, else runs
                      here) or "remote_only" (never here: held when no node
                      has a free slot). Reviewers, fix/conflict passes, other
                      providers and bwrap-jailed runs always stay local
                      whatever this says. See `arb node`.
      seed_paths      list of repo-relative paths — copied (cp -a --reflink=auto,
                      never symlinked, so a worker's build cannot write through
                      to the source repo or race a sibling) from the source repo
                      into each new worktree, when present there and not yet in
                      the worktree. Unset: the built-in set (deps/*, plus
                      _build/{test,dev}/lib/<name> where deps/<name> exists).
                      Set: the list REPLACES that set, so restate "deps" if you
                      still want it. Absolute, `..` and `.git` entries are
                      skipped with a warning.
      prepush_check   shell command run in the worker's checkout by the commit
                      gate before anything is pushed or a PR opened — for the
                      main run, review fix rounds and CI fix passes (bd-28c6qo).
                      Non-zero exit: its output goes back to the same worker
                      session and nothing is pushed. Unset: no check.
                      e.g. "mix precommit && mix audit"
      prepush_check_timeout_seconds
                      positive integer — default 1200. Size for the slowest
                      step (dialyzer on a cold PLT is ~7 min; seed priv/plts).
      prepush_check_on_timeout
                      "proceed" (default — a timeout says nothing about the
                      code, so the push goes ahead and CI is the backstop) or
                      "fail" (treated like a failed check). An infra error
                      (no worktree, command not found) always proceeds.
      repos           map, repo name -> {seed_paths, prepush_check,
                      prepush_check_timeout_seconds, prepush_check_on_timeout},
                      deep-merged over the workspace-level value (per-repo wins)

                      umbrella:    ["deps", "_build/test/lib", "_build/dev/lib", "priv/plts"]
                      single app:  ["deps", "_build/test", "_build/dev", "priv/plts"]

    attention  (map — coordinator-first escalation limits, bd-8nlez1)
      coordinator_limit_minutes  non-negative integer — a coordinator-owned
                          attention item left unresolved this long is handed
                          to the operator, noted "coordinator did not resolve
                          within <limit>". 0 turns it off.   (default: 240)
      run_crashed_max_resumes    non-negative integer — a run_crashed item whose
                          ticket was already resumed this many times out of a
                          failed run goes to the operator. 0 turns it off.
                                                              (default: 3)

    loop  (map — the loop-engineering review pipeline; see docs/loop-review.md)
      evidence_bar  (map) — how much evidence a finding needs before it is
                    proposed rather than filed as a hypothesis
        min_incidents       positive integer                        (default: 3)
        min_distinct_tasks  positive integer                        (default: 2)
      ci            (map) — the CI section of `arb loop analyze` (bd-cuu8n3)
        lint_share_threshold  number in (0, 1] — a repo whose lint share of CI
                    fix_passes exceeds this gets a repo_doc_patch proposal
                    ("run <check command> before push")       (default: 0.3)
        min_fix_passes  positive integer — fix_passes a repo needs in the
                    window before its lint share is judged      (default: 3)
        check_commands  map of repo => command the proposal names; otherwise
                    derived from the repo's red lint-job names
      autonomous_routing_enabled  bool — OFF on every workspace by default. Set
                    true to let Arbiter apply one already-proposed routing-tier
                    adjustment on its own, to half of this workspace's
                    dispatches, and revert it automatically if first-pass review
                    convergence regresses. Nothing else is ever auto-applied.
                    Unset (or set false) to stop it, effective on the next
                    dispatch even mid-canary.
      canary_auto_promote         bool (default: true). Set false and a passing
                    canary no longer writes routing.rules: the coordinator is
                    mailed the per-arm stats once and the proposal stays
                    :proposed for `arb loop apply <id>` / `arb loop reject <id>`.
                    A regressing canary is still reverted automatically.
      canary_min_dispatches       integer >= 20 — canary-arm dispatches required
                    before any verdict. May be raised, never lowered.
      canary_regression_tolerance number in 0..0.5 — how far below the control
                    arm's first-pass convergence the canary may sit without
                    being reverted                                (default: 0.0)
      canary_max_age_days         integer 1..90 — a canary that has not reached
                    canary_min_dispatches by then expires: the rule is dropped,
                    the proposal soft-rejected, the operator mailed (default: 14)
      canary        (map) — written and removed by Arbiter itself while a canary
                    runs; not meant to be hand-edited

    standing_orders  (list) — coordinator-facing only, never reaches a worker
      list of short imperative strings (or {"title","detail"} objects), surfaced
      high in `arb prime`'s briefing — which is read by the *coordinator*, not
      by workers. No worker prompt ever includes these orders; they are never
      injected into a dispatch. (A digest of the effective text is recorded on
      each `worker_runs` row as `standing_orders_digest`, but that's provenance
      for correlating outcomes against config changes, not delivery.) If you
      need a repo's workers to see an instruction, put it in that repo's
      `CLAUDE.md` instead. Manage with `arb workspace standing-order ls|add|rm`.
      Workspace-global — `arb prime` shows them for any repo. For an order that
      only applies to one repo, scope it under `repo_paths.<repo>.standing_orders`
      instead (see below), or manage it with
      `arb workspace standing-order ls|add|rm --repo <name>` (`--rig` is
      accepted as a deprecated alias for `--repo`).

    repo_paths  (map)
      repo name -> local worktree root path used to resolve a dispatch's working dir.
      An entry may be a bare string path, or a map carrying:
        path             string — the worktree root (required in map form)
        target_branch    string — base branch for this repo, overriding "main"
        standing_orders  list — orders scoped to this repo only, surfaced in
                          `arb prime` (coordinator-facing only, see above)
                          alongside the workspace-global ones. Manage with
                          `arb workspace standing-order add --repo <name>`.

    default_repo  (string)
      One of the `repo_paths` keys. The repo a new issue is assigned when it
      names none and the workspace has more than one repo (bd-9dwbvt), and the
      repo dispatch falls back to for an otherwise ambiguous run (bd-5pctey).
      Unnecessary in a single-repo workspace. Without it, a multi-repo
      workspace REFUSES to create an issue that names no repo.

    pr_patrol  (map)
      author_logins        list of forge logins — when non-empty, PRPatrol only
                           files follow-ups for PRs authored by one of these logins
      resolve_bot_threads  bool — resolve addressed bot/automated-reviewer review
                           threads (e.g. Copilot) after the follow-up worker
                           replies                                    (default: true)
      resolve_human_threads  bool — resolve addressed HUMAN-reviewer review
                           threads after the follow-up worker replies; left
                           false by default so a human confirms their own
                           threads                                    (default: false)
      our_login            string — the fleet's own forge login, used to detect
                           review threads we've already answered so PRPatrol
                           doesn't re-file a follow-up for one forever; falls
                           back to review_patrol.our_login if unset, and if
                           neither is set PRPatrol can't tell its own replies
                           apart from anyone else's

    review_patrol  (map)
      our_login  string — the fleet's own forge login, used to filter PR review
                threads down to the ones we participated in

    Secrets referenced by any `credentials_ref: "secret:<key>"` above are managed
    with `arb workspace secret set|rm|ls` — values are never echoed back.
    """
  end
end
