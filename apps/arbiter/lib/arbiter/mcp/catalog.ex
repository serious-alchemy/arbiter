defmodule Arbiter.MCP.Catalog do
  @moduledoc """
  The `Arbiter.MCP` tool catalog: the declarative list of Phase 1 tools (name,
  the tiers that may call each, a one-line description, and a JSON Schema for the
  inputs) plus the dispatch path that the transport (`ArbiterWeb.MCP.Plug`) drives
  for `tools/list` and `tools/call`.

  Tier-level visibility is the **only** capability decision made here: a tool is
  visible to — and callable by — a scope iff the scope's tier is in the tool's
  `:tiers`. Data-level rules (own-task, workspace isolation) live in the handlers
  (`Arbiter.MCP.Tools`) via `Arbiter.MCP.Scope`.

  ## Phase 1 catalog

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `ticket_show` | worker, coordinator | `Ash.get(Issue, id)` + child-progress calcs |
  | `ticket_ready` | coordinator | `Issue.ready/1` |
  | `inbox_check` | worker, coordinator | `Messages.inbox/2` + `mark_read` |
  | `coordinator_inbox` | coordinator | `Messages.inbox/2` + `mark_read` (coordinator mailbox) |
  | `coordinator_inbox_clear` | coordinator | `Messages.clear_ids/2` + `Messages.clear_by_task/2` |
  | `workspace_show` | worker, coordinator | `Ash.get(Workspace, id)` |
  | `ticket_update_progress` | worker, coordinator | `Ash.update(issue, …, action: :update)` |

  ## Phase 2 catalog (coordinator tools + the both-tier `message_send`)

  | Tool | Tiers | Backs onto |
  |---|---|---|
  | `ticket_create` | worker (child of own task only), coordinator | `Arbiter.Tasks.Create.run/2` (dedup, upstream drain, edges; P-14) |
  | `ticket_verify` | coordinator | `Arbiter.Tasks.Verification.record_outcome/3` |
  | `ticket_update` | coordinator | `Ash.update(issue, …, action: :update)` |
  | `ticket_close` | coordinator | `Ash.update(issue, …, action: :close)` |
  | `ticket_reopen` | coordinator | `Ash.update(issue, …, action: :reopen)` |
  | `ticket_promote` | coordinator | `Ash.update(issue, …, action: :promote_to_ready)` |
  | `ticket_demote` | coordinator | `Ash.update(issue, …, action: :return_to_backlog)` |
  | `ticket_rank` | coordinator | `Ash.update(issue, …, action: :set_rank)` |
  | `ticket_resume_review` | coordinator | `Ash.update(issue, …, action: :resume_review)` (P-14) |
  | `epic_floor` | coordinator | `Ash.update(issue, …, action: :set_floor)` (ES2, bd-3e7inj) |
  | `ticket_handoff` | coordinator | `Arbiter.Tasks.Attention.hand_off/3` to the operator (bd-8nlez1) |
  | `ticket_handback` | coordinator | `Arbiter.Tasks.Attention.hand_off/3` back to the coordinator (bd-8nlez1) |
  | `ticket_sync_upstream_close` | coordinator | `Ash.update(issue, …, action: :sync_upstream_close)` |
  | `dep_add` | worker (`parent_of` from own task only), coordinator | `Arbiter.Tasks.Dependencies.add/4` (use `parent_of` to attach a child) |
  | `dep_remove` | coordinator | `Arbiter.Tasks.Dependencies.remove/3` |
  | `dep_list` | worker + coordinator | `Arbiter.Tasks.Dependencies.list/1` |
  | `worker_dispatch` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.dispatch/2` |
  | `worker_resume` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.resume/2` |
  | `worker_review` | coordinator (`can_dispatch`) | `Arbiter.Worker.Dispatch.dispatch/2` (`review: true`) / `Arbiter.Reviews.ExternalReview.dispatch/1` (`pr`) |
  | `worker_stop` | coordinator | `Arbiter.Worker.stop/2` |
  | `worker_list` | coordinator | `Arbiter.Workers.Current.list/1` |
  | `worker_show` | coordinator | `Arbiter.Workers.Current.show/2` (the same current-run read as `worker_list`) |
  | `worker_runs` | coordinator | `Arbiter.Workers.Runs.history/2` (task optional → fleet-wide; `run_id` → one run), newest first (accepts synthetic ids) |
  | `worker_log` | coordinator | `Arbiter.Worker.OutputLog.read_lines/1` for one run (by `run_id` or the task's most recent) |
  | `worker_prompt` | coordinator | `Arbiter.Worker.PromptLog.read/1` for one run (by `run_id` or the task's most recent) |
  | `run_log_list` | coordinator | `Ash.read(Arbiter.Workers.Run, task_id: … or …#…)`, task + synthetic children |
  | `external_review_transcript` | coordinator | `Arbiter.Reviews.Transcript.read_lines/1` + `tool_uses/1` for one non-task-linked review (by review record id) |
  | `transcript_capture_stats` | coordinator | `Ash.read(Arbiter.Workers.Run, workspace_id: …)` since the corpus start date, rendered-transcript capture rate plus the session-JSONL archive rate (reported separately) |
  | `message_send` | worker, coordinator | `Messages.send_mail/1` (flag / direction) |
  | `notify_list` | worker, coordinator | `Messages.Mailbox.notifications/1` |
  | `ticket_list` | coordinator | `Ash.read(Issue, …)` with filters |
  | `tracker_claim` | coordinator | `Arbiter.Tasks.Claim.claim/3` |
  | `tracker_list_issues` | coordinator | `Arbiter.Trackers.list_open/1` |
  | `tracker_create_ticket` | coordinator | `Arbiter.Trackers.create_ticket_only/2` |
  | `tracker_sync` | coordinator | `Arbiter.Tasks.Claim.plan/1` + `apply_plan/2` |
  | `workspace_list` | coordinator | `Ash.read(Workspace)` (summary fields) |
  | `workspace_config_get` | worker, coordinator | `Ash.get(Workspace, id)` → read `config` / dotted key |
  | `workspace_config_overview` | worker, coordinator | `Ash.get(Workspace, id)` → grouped config summary |
  | `workspace_config_set` | coordinator | `Ash.update(ws, …, action: :patch_config)` deep-merge |
  | `workspace_config_unset` | coordinator | `Ash.update(ws, …, action: :patch_config)` unset |
  | `workspace_config_schema` | worker, coordinator | `Workspace.ConfigSchema.describe/0` |
  | `workspace_standing_order_add` | coordinator | `Workspace.Operations` (atomic append) |
  | `workspace_standing_order_remove` | coordinator | `Workspace.Operations` (atomic remove by index or text) |
  | `installation_config_get` | worker, coordinator | `Arbiter.Settings` getters (credential watchdog + quota-provider visibility) |
  | `installation_config_set` | coordinator | `Arbiter.Settings` setters (credential watchdog + quota-provider visibility + output-offload sweeper switch) |
  | `skill_create` | coordinator | `Arbiter.Skills.create_skill/1` |
  | `skill_update` | coordinator | `Arbiter.Skills.update_skill/2` |
  | `skill_delete` | coordinator | `Arbiter.Skills.delete_skill/1` |
  | `skill_list` | worker, coordinator | `Arbiter.Skills.list_skills/0` |
  | `skill_get` | worker, coordinator | `Arbiter.Skills.get_skill/1` |
  | `loop_pending_list` | coordinator | `Arbiter.Loop.list_pending/1` + `evidence_bar/1` |
  | `loop_pending_diff` | coordinator | `Arbiter.Loop.get_pending/1` (full row incl. unified diff) |
  | `loop_pending_apply` | coordinator | `Arbiter.Loop.apply_pending/2` (dispatches to the existing domain API) |
  | `loop_analyze` | coordinator | `Arbiter.Loop.Analysis.analyze/1` via `Analysis.Request` + `Analysis.Summary` (report-only, bounded) |
  | `loop_propose` | coordinator | `Arbiter.Loop.Analysis.analyze/1` with `propose?: true` (queues reviewable proposals) |
  | `loop_propose_repo_doc_patch` | coordinator | `Arbiter.Loop.propose_repo_doc_patch/1` (hand-authored queue write) |
  | `loop_propose_routing` | coordinator | `Arbiter.Loop.propose_routing/1` (operator-authored routing canary proposal) |
  | `loop_canary_status` | coordinator | `Arbiter.Loop.Canary.status/1` (both arms' metrics + verdict progress) |
  | `loop_pending_reject` | coordinator | `Arbiter.Loop.reject_pending/2` (soft — the row persists as `rejected`) |
  | `trust_show` | coordinator | `Arbiter.Loop.Trust.View.list/0` / `detail/1` (G18 earned trust; no tool promotes) |
  | `trust_confirm` | coordinator | `Arbiter.Loop.Trust.confirm/2` (an automatic suspension stands: quarantine) |
  | `trust_dismiss` | coordinator | `Arbiter.Loop.Trust.dismiss/3` (a suspension was a false positive: its tier returns) |
  | `permission_request` | worker | `Arbiter.Tasks.PermissionRequest.submit/4` (G15a: records a `requested` event and raises `:permission_requested`; grants nothing) |
  | `ticket_permission_grant` | coordinator | `Arbiter.Tasks.PermissionDecision.answer/4` (G15b: grant or deny a requested permission; operator-only bindings are refused without operator proof; a `network:` grant is live) |
  | `usage_summarize` | coordinator | `Arbiter.Usage.summarize/1` |
  | `usage_events_list` | coordinator | `Arbiter.Usage.list_events/1` (raw ledger rows, P-17) |
  | `usage_calibration` | coordinator | `Arbiter.Usage.calibration/1` (difficulty mis-rating report, P-17) |
  | `queue_retry_auto_resolve` | coordinator | `Arbiter.Worker.Watchdog.retry_auto_resolve/1` (bd-bspakl) |
  | `queue_restart_watchdog` | coordinator | `Arbiter.Worker.Watchdog.restart/2` (bd-8jixav) |
  | `ci_rerun` | worker, coordinator | `Arbiter.Worker.CIRerun.rerun/2` → `Watchdog.rerun_ci/2` / `Merger.rerun_ci/2` (bd-5mzzww) |
  | `ci_mark_external` | worker, coordinator | `Arbiter.Worker.Watchdog.mark_ci_external/2` (bd-5mzzww) |
  | `scheduler_pause` | coordinator | `Arbiter.Board.Autopilot.pause/2` (persisted, bd-pgi97m) |
  | `scheduler_resume` | coordinator | `Arbiter.Board.Autopilot.resume/2` (persisted, bd-pgi97m) |
  | `scheduler_status` | coordinator | `Arbiter.Board.Drain.status/1` |
  | `server_status` | coordinator | `Arbiter.Server.Status.snapshot/0` (P-27) |
  | `provider_pause` | coordinator | `Arbiter.Providers.Pause.pause/2` (persisted, bd-5ef587) |
  | `provider_resume` | coordinator | `Arbiter.Providers.Pause.resume/2` |
  | `provider_list` | coordinator | `Arbiter.Providers.Pause.to_json/0` (active pauses, P-17) |
  | `account_list` | coordinator | `Arbiter.Accounts.list_accounts/1` via `Accounts.Serializer` (P-17) |
  | `account_show` | coordinator | `Arbiter.Accounts.get_account/1` via `Accounts.Serializer` (credential kind + fingerprint prefix only, P-17) |
  | `account_set` | coordinator | `Arbiter.Accounts.edit_account/2` (non-secret fields only, bd-1kr3qf) |
  | `alert_list` | coordinator | `Arbiter.Alerts.active/1` (system alerts, bd-7gt8rm) |
  | `breaker_list` | coordinator | `Arbiter.CircuitBreaker.list/1` + `call_sites/0` |
  | `breaker_reset` | coordinator | `Arbiter.CircuitBreaker.reset/1` / `reset_all/1` |
  | `repo_list` | coordinator | `Arbiter.Tasks.RepoConfig.list_repos()` (mirrors `arb repo list`) |
  | `repo_show` | coordinator | single repo from `list_repos()` |
  | `quota_get` | worker, coordinator | `Arbiter.Quota` snapshot per provider (or one account) |
  | `flake_record` | worker, coordinator | structured flake event for `arb loop analyze` (bd-6vullc) |
  | `external_review_list` | coordinator | `ExternalReview` audit records for a workspace (bd-31fh9e) |
  | `external_review_show` | coordinator | one `ExternalReview` record with its proposed comments |
  | `review_greenlight` | coordinator (`can_dispatch`) | posts the approved subset of a report-only review (bd-36qzgx) |
  | `review_gate_rounds_list` | coordinator | ReviewGate round outcomes for a ticket (bd-aqyjuc) |
  | `review_gate_resolve` | coordinator | records the answer to a gate escalation (bd-4qjl0q) |
  | `memory_pending_list` | coordinator | memory promotion queue / rejected audit trail |
  | `memory_pending_diff` | coordinator | one memory candidate with its diff and citation check |
  | `memory_pending_apply` | coordinator | promotes a candidate into the shared memory layer |
  | `memory_pending_reject` | coordinator | rejects a candidate (kept for audit) |
  | `memory_quarantine_list` | coordinator | shared memories quarantined as stale |
  | `memory_quarantine_restore` | coordinator | re-verifies and restores a quarantined memory |
  | `memory_distill` | coordinator | proposes memory candidates from an ended session's transcript |
  """

  alias Arbiter.Guardrails.Events
  alias Arbiter.Guardrails.SelfGrant
  alias Arbiter.MCP.RefinePolicy
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools

  # JSON-RPC / MCP error codes. -32003 is an implementation-defined server error
  # in the reserved -32000..-32099 range; -32602 is "invalid params".
  @code_not_permitted -32_003
  @code_invalid_params -32_602

  @type tool :: %{
          name: String.t(),
          tiers: [Scope.tier()],
          description: String.t(),
          input_schema: map(),
          handler: (Scope.t(), map() -> {:ok, map()} | {:error, {atom(), String.t()}})
        }

  @type call_result ::
          {:ok, map()}
          | {:rpc_error, integer(), String.t()}
          | {:tool_error, String.t(), String.t()}

  @both [:worker, :coordinator]
  @coordinator [:coordinator]
  @worker [:worker]

  # Enum values for the loop-proposal queue tools. Kept as strings here because
  # they go straight into a JSON Schema; `Arbiter.Loop.PendingWrite` holds the
  # authoritative atom constraints.
  @loop_states ~w(proposed hypothesis applied rejected superseded)
  @loop_kinds ~w(skill_patch skill_create difficulty_override config_set repo_doc_patch
                 trust_promotion)

  # The optional `workspace` field every workspace-resolving tool advertises.
  # Coordinator tokens are workspace-agnostic (one token, any workspace); naming
  # a workspace here targets it explicitly. Omitting it follows the one rule in
  # `Arbiter.Tasks.Workspaces`: a bound token uses its own workspace; reads then
  # cover ALL workspaces; writes use the sole workspace or fail. A workspace-bound
  # scope (a worker) may only ever name its own.
  @workspace_field %{
    "type" => "string",
    "description" =>
      "Workspace name or id to operate in (optional). Coordinator tokens are " <>
        "workspace-agnostic. Omitted: a list/read tool covers ALL workspaces (the " <>
        "response echoes `workspace_id`); a tool that writes uses the only workspace " <>
        "when there is exactly one and otherwise fails listing the candidates — it " <>
        "never falls back to a workspace merely named `default`. A worker may only " <>
        "ever name its own workspace."
  }

  # Tools that call resolve_workspace_id and thus support the optional `workspace` arg.
  # All other tools do not accept a workspace override.
  @workspace_tools ~w(ticket_ready coordinator_inbox coordinator_inbox_clear workspace_show quota_get ticket_create worker_list worker_runs ticket_list usage_summarize usage_events_list usage_calibration notify_list tracker_claim tracker_sync tracker_list_issues tracker_create_ticket workspace_config_get workspace_config_overview workspace_config_set workspace_config_unset workspace_standing_order_add workspace_standing_order_remove external_review_list repo_show)

  # P-13 (D-T-14): the `ticket_*` write tools return the full ticket record REST
  # returns (`Arbiter.Tasks.IssueSerializer.data/1`); `summary: true` asks for
  # the ten-field slim row instead. Injected into each one below.
  @summary_tools ~w(ticket_update_progress ticket_create ticket_update ticket_close ticket_reopen
                    ticket_verify ticket_promote ticket_demote ticket_rank ticket_resume_review
                    epic_floor ticket_handoff ticket_handback ticket_sync_upstream_close)

  @summary_field %{
    "type" => "boolean",
    "description" =>
      "Return the slim ten-field row (id, title, state, close_reason, priority, difficulty, " <>
        "issue_type, workspace_id, acceptance_waived, rank) instead of the full ticket " <>
        "record. Default false: the full record, the same shape `GET /api/issues/:id` returns."
  }

  @raw_tools [
    %{
      name: "ticket_show",
      tiers: @both,
      description:
        "Read one ticket: id, title, description, acceptance, child-progress " <>
          "`child_closed`/`child_total` over its `parent_of` children, and where it is in " <>
          "the lifecycle — `state` (backlog | queued | active | merging | verifying | " <>
          "closed), `column` (backlog | blocked | ready | in_progress | merging | verifying " <>
          "| closed), `step` (the computed step inside In progress or Merging, else null), " <>
          "`blocked_by` (unsatisfied gating blockers), `attention` ({owner, waiting_on, " <>
          "reason, cause, since, note} or null) and `close_reason`. `priority` is the own " <>
          "priority; `effective_priority` is what the ticket is scheduled as (an epic " <>
          "floor can lift it), `priority_via` the epic supplying that floor (or null) and " <>
          "`priority_lift` `applied` | `capped` | null. A worker reads its " <>
          "own ticket (the `id` argument may be omitted); a coordinator must pass the `id`. " <>
          "Pass `full: true` to include review fields (notes, qa_notes, deployment_notes, " <>
          "pr_body, pr_ref, tracker_ref, target_branch, repo, auto_close, " <>
          "verify_after_deploy + the verification state, timestamps) plus `dependencies`, " <>
          "`history` (the audit trail, newest first, each write with its actor) and " <>
          "`current_run` (what the ticket's run is doing, or null). Every view also " <>
          "carries `estimate`: what comparable closed tickets actually cost, as " <>
          "`{range: [p25, p75], median, p90, n, basis, fallback_level}` over a 60-day " <>
          "window. `basis` names the group the numbers came from " <>
          "(`difficulty+type` / `difficulty` / `global` / `unrated_as_d2`) and " <>
          "`fallback_level` how coarse it is (0 = finest) — treat a coarse, small-`n` " <>
          "range as a hint, not a budget. Null when the ledger is too thin to say; " <>
          "worker spend only, excluding coordinator-session overhead.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" =>
              "Ticket id (e.g. \"bd-dem49g\"). Optional for a worker (defaults to its own ticket)."
          },
          "full" => %{
            "type" => "boolean",
            "description" =>
              "When true, return the complete record including notes, qa_notes, " <>
                "deployment_notes, pr_body, pr_ref, tracker_ref, target_branch, repo, " <>
                "auto_close, verify_after_deploy, awaiting_verification_at, " <>
                "verification_outcome, verification_evidence, attention_cause (a ReviewGate " <>
                "park is its cause), and timestamps. " <>
                "Defaults to false (slim payload for workers)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.task_show/2
    },
    %{
      name: "ticket_ready",
      tiers: [:coordinator],
      description:
        "List the tickets in the Ready column, in dispatch order (effective priority, rank, age — an epic's floor lifts its children): " <>
          "state `queued` with no unsatisfied gating blocker. A blocker that is Verifying " <>
          "(merged, awaiting its verification) no longer blocks. Backlog, Blocked and " <>
          "epics are never listed. Each carries `state`, `column`, `step`, `blocked_by` " <>
          "and `attention` — and `hold_reason` when the scheduler is holding that card. The " <>
          "same set `GET /api/issues/ready` and `arb ready` return.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.task_ready/2
    },
    %{
      name: "inbox_check",
      tiers: @both,
      description:
        "Read the mailbox for a ticket — the structured replacement for `arb inbox`. " <>
          "A worker checks its own ticket; a coordinator passes `task_id`. " <>
          "Two states: `state: \"unread\"` (default) lists unread messages and, unless `mark_read: false`, marks them read; " <>
          "`state: \"outstanding\"` lists read-but-uncleared messages as a pure read — no mutations.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Recipient ticket id. Optional for a worker (defaults to its own ticket)."
          },
          "state" => %{
            "type" => "string",
            "enum" => ["unread", "outstanding"],
            "description" =>
              "Mailbox state to return. \"unread\" (default): unread messages, marked read on return. " <>
                "\"outstanding\": read-but-uncleared messages, no mutations."
          },
          "mark_read" => %{
            "type" => "boolean",
            "description" =>
              "Stamp the returned unread messages read. Default true; pass false to peek " <>
                "(the REST/CLI default is false — those are plain reads)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.inbox_check/2
    },
    %{
      name: "coordinator_inbox",
      tiers: @coordinator,
      description:
        "Read the coordinator escalation mailbox for the workspace — the structured " <>
          "replacement for `arb message inbox` / `arb inbox`. Lists messages where " <>
          ~s[`to_ref == "coordinator"`. Two states: `state: "unread"` (default) lists unread ] <>
          "messages and marks them read on return; optionally `clear: true` also soft-clears the " <>
          "outstanding tail (mirrors `arb inbox clear`). `state: \"outstanding\"` lists read-but-uncleared " <>
          "messages (the triage queue) as a pure read — no mutations. `state: \"outstanding\"` and " <>
          "`clear: true` are mutually exclusive. Coordinator only. Both states also return " <>
          "`attention`: the computed queue of open tickets whose attention you own (cause, " <>
          "what it waits on, why, since when). It has no read or clear state — an item goes " <>
          "when its ticket moves on; resolve it, or hand it to the operator with `ticket_handoff`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "state" => %{
            "type" => "string",
            "enum" => ["unread", "outstanding"],
            "description" =>
              "Mailbox state to return. \"unread\" (default): unread messages, marked read on return. " <>
                "\"outstanding\": read-but-uncleared messages, no mutations."
          },
          "mark_read" => %{
            "type" => "boolean",
            "description" =>
              "Stamp the returned unread messages read. Default true; pass false to peek " <>
                "(the REST/CLI default is false — those are plain reads)."
          },
          "clear" => %{
            "type" => "boolean",
            "description" =>
              "Also soft-clear the outstanding tail after listing (mirrors `arb inbox clear`). " <>
                "Only valid with state: \"unread\". Default false."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.coordinator_inbox/2
    },
    %{
      name: "coordinator_inbox_clear",
      tiers: @coordinator,
      description:
        "Soft-clear specific coordinator-mailbox messages — the structured replacement for " <>
          "`arb inbox clear <id> ...` / `arb inbox clear --task <task-id>`. Accepts `ids` " <>
          "(a list of message ids) and/or `task_id`; at least one is required. `ids` resolve " <>
          "directly by id, regardless of workspace. `task_id` clears every coordinator message " <>
          "concerning that ticket in every workspace you may see (a bound token: its own; pass " <>
          "`workspace` to narrow it). Returns the same keys as REST `DELETE /api/messages`. Rows are retained (soft-clear), never destroyed. " <>
          "Clears only YOUR view of the shared mailbox: a session token clears its own copy, " <>
          "leaving every other session and the sessionless coordinator still owing the message. " <>
          "Returns `cleared` (ids), `cleared_count` and `not_found`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Message ids (or full ids resolved elsewhere) to clear."
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Clear every coordinator message concerning this ticket."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.coordinator_inbox_clear/2
    },
    %{
      name: "workspace_show",
      tiers: @both,
      description:
        "Show the scope's own workspace: config, the resolved worker security posture, and " <>
          "the release `update` block (update_available, latest, current version).",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_show/2
    },
    %{
      name: "quota_get",
      tiers: @both,
      description:
        "Current rate-limit / quota state for the scope's workspace. `claude`: Anthropic's 5h + " <>
          "7d utilization, reset times, status, which window Anthropic says binds, and " <>
          "`gating_window` / `gating_reason` — which window (if any) is currently holding " <>
          "dispatch, per this workspace's quota config (`gating_window` may be `\"paused\"` when an " <>
          "operator pause holds it), and `gating_workspaces` — other workspaces on the account whose " <>
          "own ceiling holds dispatch (each `workspace_id`, `workspace`, `window`, `reason`) " <>
          "(captured by the local " <>
          "proxy; `null` until the first proxied request), plus an on-demand per-model weekly " <>
          "utilization + extra_usage overage refresh. `codex`: OpenAI session + weekly " <>
          "windows fetched live from the rate-limit endpoint (`null` with a `codex_message` when " <>
          "Codex isn't authenticated or the usage API is unavailable), plus pacing state: " <>
          "`elapsed_fraction`, `used_fraction`, `gating_reason` (null unless held) and a " <>
          "`pacing` map (window length resolved per plan; `enabled: false` with a " <>
          "`disabled_reason` when the plan or length is unknown). `gemini` / `antigravity`: " <>
          "live per-model Cloud Code Assist quota (`null` when that CLI isn't authenticated on " <>
          "this host). Coordinator only: `account` (uuid, `provider:slug` or an unambiguous slug) " <>
          "reads that one account's quota instead of a workspace's, in the REST " <>
          "`GET /api/quota?account=` shape (`workspace` is then ignored).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "account" => %{
            "type" => "string",
            "description" =>
              "Provider account ref to read instead of a workspace (coordinator only)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.quota_get/2
    },
    %{
      name: "ticket_update_progress",
      tiers: @both,
      description:
        "Record progress / completion notes on a ticket — `notes`, `qa_notes`, `deployment_notes`, " <>
          "`pr_body`, plus the `verify_after_deploy` flag (the structured replacement for " <>
          "`arb ticket update --qa-notes …`). A worker may only update its own ticket and cannot " <>
          "change its state or priority.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Ticket id. Optional for a worker (defaults to its own ticket)."
          },
          "notes" => %{
            "type" => "string",
            "description" =>
              "Free-form progress / working notes. REPLACES the field; `\"\"` clears it. " <>
                "To add to what is there without losing a concurrent write, use `append_notes`."
          },
          "append_notes" => %{
            "type" => "string",
            "description" =>
              "Append to `notes` (separated by a blank line), atomically on the server — " <>
                "never a read-modify-write. Not combinable with `notes`."
          },
          "qa_notes" => %{
            "type" => "string",
            "description" => "What QA should verify. `\"\"` clears it."
          },
          "deployment_notes" => %{
            "type" => "string",
            "description" => "Rollout / backout considerations."
          },
          "pr_body" => %{
            "type" => "string",
            "description" =>
              "The worker-authored PR/MR description (Summary / Test plan / References) the " <>
                "MergeQueue opens the ticket's single canonical PR with."
          },
          "verify_after_deploy" => %{
            "type" => "boolean",
            "description" =>
              "Set true when your diff's only execution context is the long-lived server — " <>
                "env/config plumbing, a doctor/health probe, a capture or ingest path, " <>
                "anything a green test suite cannot prove is live. The merge then moves the " <>
                "ticket to Verifying (state `verifying`) instead of closing it, and the coordinator " <>
                "restarts and observes the new path once before it closes."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.task_update_progress/2
    },

    # ---- Phase 2: coordinator-only mutating tools ----
    %{
      name: "ticket_create",
      tiers: @both,
      description:
        "Create a ticket in the workspace. A worker may file only a follow-up CHILD of its own " <>
          "task (`parent_id` = its own task id, required), in its own workspace, with only " <>
          "`title`, `description`, `acceptance`, `issue_type`, `priority`, `difficulty` " <>
          "(the same rule as `POST /api/issues`). `title` is required; optional `description`, " <>
          "`acceptance`, `priority`, `difficulty`, `issue_type`, `auto_close`, " <>
          "`tracker_type`, …. The ticket is created in the session's workspace (the bound one, or the " <>
          "`workspace` you name). A ticket whose title matches an open one in that workspace is " <>
          "refused as a duplicate unless `force: true`. If the upstream tracker mirror fails the " <>
          "call is an error that names the ticket that WAS created (re-link it with " <>
          "`ticket_update`; do not file it again). " <>
          "Created tickets land in the Backlog column (state `backlog`), not Ready, " <>
          "and stay there until a human promotes them from the ticket detail page. " <>
          "The board scheduler (Autopilot) is the only dispatcher, and it promotes from " <>
          "Ready only, so a ticket filed here waits for that promotion. bd-7mbrlg: filing a `bug`/`feature`/`chore` with no " <>
          "`acceptance` returns a non-blocking `warnings` entry in the response — the ticket " <>
          "still gets created, but `ticket_promote` will later refuse it without ACs or a waiver.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Ticket title (required)."},
          "parent_id" => %{
            "type" => "string",
            "description" =>
              "Attach the new ticket as a `parent_of` child of this existing ticket, in the same " <>
                "workspace, in one call (equivalent to a follow-up `dep_add` with " <>
                "type `parent_of`). Optional. For a refine session it defaults to the bound " <>
                "ticket and may only name the bound ticket or one of its descendants. " <>
                "#1973: when the parent is linked to a tracker ticket and `tracker_type` is " <>
                "omitted, the child follows the workspace's `tracker.child_policy` — by " <>
                "default it stays local (`tracker_type: none`) with the parent's ticket as " <>
                "`tracker_context_ref`, so no upstream ticket is minted. Refine-session " <>
                "children are always context-only. Pass `tracker_type` to mint anyway."
          },
          "force" => %{
            "type" => "boolean",
            "description" =>
              "File the ticket even though an open ticket (or open tracker issue) with the same " <>
                "title exists. Default false: a duplicate title is refused."
          },
          "description" => %{"type" => "string", "description" => "Markdown body."},
          "acceptance" => %{"type" => "string", "description" => "Markdown acceptance criteria."},
          "notes" => %{"type" => "string"},
          "qa_notes" => %{"type" => "string"},
          "deployment_notes" => %{"type" => "string"},
          "priority" => %{
            "type" => "integer",
            "description" => "0 (P0, highest) .. 4 (P4, lowest). Default 2."
          },
          "difficulty" => %{
            "type" => "integer",
            "description" =>
              "0 (D0, trivial) .. 5 (D5). D4 is extreme — novel architecture, deep " <>
                "ambiguity. D5 is the flagship tier: a deliberate operator escalation for " <>
                "work worth a full quota window, not simply \"harder than D4\"."
          },
          "issue_type" => %{
            "type" => "string",
            "description" =>
              "task | research | bug | feature | epic | chore | decision. `research` and " <>
                "`task` are the two no-PR types (no worktree, commit gate, ReviewGate or merge), " <>
                "and NEITHER may be used for code work: `research` is an investigation whose " <>
                "findings write-up in `notes` is required before it completes; `task` is a plain " <>
                "operational action (a restart, a config flip) that completes when the agent " <>
                "reports it done, with a short outcome note. Use bug | feature | chore for " <>
                "anything that ships code."
          },
          "auto_close" => %{
            "type" => "boolean",
            "description" =>
              "When true, this ticket auto-closes once all its `parent_of` children are closed " <>
                "(≥1 child). Default false."
          },
          "verify_after_deploy" => %{
            "type" => "boolean",
            "description" =>
              "When true, merging this ticket's PR does NOT close it: the ticket moves to " <>
                "Verifying (state `verifying`) and the coordinator is notified to restart the " <>
                "server and observe the new path once, then record the result with " <>
                "`ticket_verify`. Set it for any change whose only execution context is the " <>
                "long-lived server (env/config plumbing, a doctor probe, a capture/ingest " <>
                "path) — the class that merges green and is found broken hours later. " <>
                "Default false."
          },
          "provider_constraint" => %{
            "type" => ["object", "null"],
            "description" =>
              ~s|Where this ticket's IMPLEMENTER may run (bd-13pqcp): `{"require": ["claude"]}` | <>
                ~s|(only those providers) or `{"exclude": ["gemini"]}` (anything but those) — | <>
                "one key, never both. Providers are adapter types (claude, gemini, codex); " <>
                "`agy` is accepted as `gemini`, the adapter that runs it. Honoured by every " <>
                "dispatch path (Autopilot, routing, failover, resume, fix and conflict passes); " <>
                "when no allowed provider has capacity the ticket is held — " <>
                "`held — provider constraint (<detail>)` — and never falls back to an excluded " <>
                "provider. The reviewer is not constrained. Pass `null` or `{}` to clear. " <>
                "Coordinator only.",
            "properties" => %{
              "require" => %{"type" => "array", "items" => %{"type" => "string"}},
              "exclude" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "additionalProperties" => false
          },
          "permissions" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The permissions this ticket declares (G12, docs/design/guardrail-profiles.md " <>
                "§5): `network:<host>[:<port>]`, `tracker_write`, `secrets:<name>`, `prod_read`, " <>
                "`prod_ssh`, `phi_data`, `research_read`; a `?` after the kind (`network?:host`) marks an action " <>
                "optional. On update this REPLACES the list. A permission whose binding says " <>
                "`grant_by: operator` (default: `prod_ssh`) is recorded as `requested` and gives " <>
                "no reach until the operator grants it; removing `phi_data` is operator-only. " <>
                "Withheld at dispatch unless declared. Coordinator only — a worker or refine " <>
                "session never sets them (a refine session may only suggest)."
          },
          "tracker_type" => %{
            "type" => "string",
            "description" => "none | jira | shortcut | linear | github | gitlab."
          },
          "tracker_ref" => %{"type" => "string"},
          "tracker_context_type" => %{
            "type" => "string",
            "description" =>
              "Tracker type for a context-only reference (e.g. \"jira\"). Paired with " <>
                "`tracker_context_ref`. No claim semantics; the referenced ticket is fetched " <>
                "read-only at review dispatch to supply the reviewer with acceptance criteria. " <>
                "Safe to use on coworker-owned tickets."
          },
          "tracker_context_ref" => %{
            "type" => "string",
            "description" =>
              "Tracker issue ref for read-only context (e.g. \"AX-18004\"). The ticket's " <>
                "description is fetched at review dispatch and injected into the reviewer's " <>
                "prompt. No assignment check, no write-back."
          },
          "target_branch" => %{"type" => "string"},
          "repo" => %{
            "type" => "string",
            "description" =>
              "The repo this ticket belongs to, as a configured `repo_paths` key " <>
                "(e.g. \"emricare/tonic\"). Every ticket carries one (bd-9dwbvt); omit it and " <>
                "it is resolved for you — the workspace's only repo, else its `default_repo`. " <>
                "Creation is REFUSED, listing the configured keys, when a multi-repo " <>
                "workspace has no `default_repo`, and a repo that is not a configured key is " <>
                "rejected. Every dispatch of the ticket uses it unless one names another repo."
          }
        },
        "required" => ["title"],
        "additionalProperties" => false
      },
      handler: &Tools.task_create/2
    },
    %{
      name: "ticket_update",
      tiers: @coordinator,
      description:
        "Update a ticket's fields in the workspace (priority / title / …). It never moves the " <>
          "lifecycle `state`: use `ticket_promote` / `ticket_demote` / `ticket_close` / " <>
          "`ticket_reopen` for that.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "acceptance" => %{"type" => "string"},
          "notes" => %{
            "type" => "string",
            "description" => "REPLACES the field; `\"\"` clears it (as for every text field)."
          },
          "append_notes" => %{
            "type" => "string",
            "description" =>
              "Append to `notes` (separated by a blank line), atomically on the server. " <>
                "Not combinable with `notes`."
          },
          "qa_notes" => %{"type" => "string"},
          "deployment_notes" => %{"type" => "string"},
          "priority" => %{"type" => "integer"},
          "difficulty" => %{"type" => "integer"},
          "issue_type" => %{
            "type" => "string",
            "description" =>
              "task | research | bug | feature | epic | chore | decision. `research` " <>
                "(findings in `notes` required) and `task` (an operational action) are the " <>
                "no-PR types; neither may be used for code work."
          },
          "auto_close" => %{
            "type" => "boolean",
            "description" =>
              "Auto-close this ticket when all its `parent_of` children are closed."
          },
          "verify_after_deploy" => %{
            "type" => "boolean",
            "description" =>
              "When true, merging this ticket's PR does NOT close it: the ticket moves to " <>
                "Verifying (state `verifying`) and the coordinator is notified to restart the " <>
                "server and observe the new path once, then record the result with " <>
                "`ticket_verify`. Set it for any change whose only execution context is the " <>
                "long-lived server (env/config plumbing, a doctor probe, a capture/ingest " <>
                "path) — the class that merges green and is found broken hours later. " <>
                "Default false."
          },
          "provider_constraint" => %{
            "type" => ["object", "null"],
            "description" =>
              ~s|Where this ticket's IMPLEMENTER may run (bd-13pqcp): `{"require": ["claude"]}` | <>
                ~s|(only those providers) or `{"exclude": ["gemini"]}` (anything but those) — | <>
                "one key, never both. Providers are adapter types (claude, gemini, codex); " <>
                "`agy` is accepted as `gemini`, the adapter that runs it. Honoured by every " <>
                "dispatch path (Autopilot, routing, failover, resume, fix and conflict passes); " <>
                "when no allowed provider has capacity the ticket is held — " <>
                "`held — provider constraint (<detail>)` — and never falls back to an excluded " <>
                "provider. The reviewer is not constrained. Pass `null` or `{}` to clear. " <>
                "Coordinator only.",
            "properties" => %{
              "require" => %{"type" => "array", "items" => %{"type" => "string"}},
              "exclude" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "additionalProperties" => false
          },
          "permissions" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "The permissions this ticket declares (G12, docs/design/guardrail-profiles.md " <>
                "§5): `network:<host>[:<port>]`, `tracker_write`, `secrets:<name>`, `prod_read`, " <>
                "`prod_ssh`, `phi_data`, `research_read`; a `?` after the kind (`network?:host`) marks an action " <>
                "optional. On update this REPLACES the list. A permission whose binding says " <>
                "`grant_by: operator` (default: `prod_ssh`) is recorded as `requested` and gives " <>
                "no reach until the operator grants it; removing `phi_data` is operator-only. " <>
                "Withheld at dispatch unless declared. Coordinator only — a worker or refine " <>
                "session never sets them (a refine session may only suggest)."
          },
          "add_permissions" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Permissions to add to the ticket's current list (same authority rules as " <>
                "`permissions`). Applied against the stored list, so concurrent edits don't clobber."
          },
          "remove_permissions" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Permissions to remove from the current list. Removing an action tightens (any " <>
                "coordinator); removing `phi_data` is operator-only."
          },
          "tracker_type" => %{"type" => "string"},
          "tracker_ref" => %{"type" => "string"},
          "tracker_context_type" => %{"type" => "string"},
          "tracker_context_ref" => %{"type" => "string"},
          "pr_ref" => %{"type" => "string"},
          "target_branch" => %{"type" => "string"},
          "repo" => %{
            "type" => "string",
            "description" =>
              "The repo this ticket belongs to, as a configured `repo_paths` key " <>
                "(e.g. \"emricare/tonic\")."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_update/2
    },
    %{
      name: "ticket_close",
      tiers: @coordinator,
      description:
        "Close a ticket in the workspace. Optional `reason`. Also closes the linked external " <>
          "tracker issue by default when the ticket has a `tracker_ref`; pass " <>
          "`close_upstream: false` to leave it open.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "reason" => %{"type" => "string"},
          "close_upstream" => %{
            "type" => "boolean",
            "description" =>
              "Also close the linked tracker issue (default true; pass false to opt out)."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_close/2
    },
    %{
      name: "ticket_reopen",
      tiers: @coordinator,
      description:
        "Reopen a closed ticket (clears closed_at, returns it to the ready queue, and best-effort " <>
          "reopens the linked tracker issue). The only supported path out of `closed` — `ticket_update` " <>
          "rejects that transition.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_reopen/2
    },
    %{
      name: "ticket_verify",
      tiers: @coordinator,
      description:
        "Record the restart-and-observe result for a ticket in Verifying (state `verifying`) " <>
          "(bd-9so315). Pass exactly one of `observed` or `failed`, whose value is the " <>
          "evidence — what you actually saw on the running server. `observed` closes the " <>
          "ticket; `failed` reopens it for another attempt. The evidence is persisted on the " <>
          "ticket either way.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "observed" => %{
            "type" => "string",
            "description" =>
              "Evidence that the change is live and working, e.g. \"restarted at 14:02; " <>
                "GET /api/doctor now reports 3 repos\". Closes the ticket."
          },
          "failed" => %{
            "type" => "string",
            "description" =>
              "Evidence that it is NOT working after the restart. Reopens the ticket for " <>
                "another attempt, with the evidence persisted for the next worker."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_verify/2
    },
    %{
      name: "ticket_promote",
      tiers: @coordinator,
      description:
        "Promote a ticket from Backlog to the queue (state `backlog` → `queued`: column Ready, or " <>
          "Blocked while a gating blocker is open) via the `promote` transition. " <>
          "Coordinator tier, or a refine session within its subtree. Idempotent by design — promoting an already-queued ticket is a no-op success, " <>
          "not an error. bd-7mbrlg: a `bug`/`feature`/`chore` with blank `acceptance` is refused unless " <>
          "you pass `acceptance_waived` with a reason (`task`/`decision`/`epic` are exempt; D0 work is " <>
          "auto-waived). **Promote last.** Autopilot can claim a ticket within seconds of it going " <>
          "Ready, so every `parent_of` child and every dependency edge the ticket needs must " <>
          "already exist before you promote it — an edge added after the promote can lose the " <>
          "race. A refine-tier promotion returns this rule as `promotion_note`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "acceptance_waived" => %{
            "type" => "string",
            "description" =>
              "Reason for promoting a bug/feature/chore with no acceptance criteria. Required " <>
                "(non-blank) only when the ticket is a gated type, has blank `acceptance`, and " <>
                "isn't D0. Persisted onto the ticket and shown in `ticket_show`."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_promote/2
    },
    %{
      name: "ticket_demote",
      tiers: @coordinator,
      description:
        "Demote a queued ticket (column Ready or Blocked) back to Backlog via the `demote` transition. " <>
          "Coordinator only. Idempotent by design — demoting an already-backlog ticket is a no-op success, " <>
          "not an error. A ticket can only be demoted if it has no live worker and its state is `queued`, " <>
          "or `active` / `merging` with its run stopped. Refuses a ticket with a live worker, and one that " <>
          "is Verifying or Closed, with a clear reason — demoting those would orphan the worker or undo " <>
          "completed work.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_demote/2
    },
    %{
      name: "ticket_rank",
      tiers: @coordinator,
      description:
        "Reorder a ticket inside its workspace's rank order via the `:set_rank` action — the space " <>
          "`board/scheduler.ex` and Autopilot dispatch read (priority, then rank, then age). " <>
          "Coordinator only. Exactly one of `top`, `bottom`, `before_id`, `after_id` is required, unless `pinned` is given alone. " <>
          "`before_id`/`after_id` must name a ticket in the same workspace, or the call is rejected. " <>
          "Never changes `priority` — ranking before/after a ticket in a different priority band " <>
          "only orders within rank, it does not move the ticket into that band.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "top" => %{"type" => "boolean", "description" => "Move to the top of the workspace."},
          "bottom" => %{
            "type" => "boolean",
            "description" => "Move to the bottom of the workspace."
          },
          "before_id" => %{
            "type" => "string",
            "description" => "Move immediately ahead of this ticket (same workspace)."
          },
          "after_id" => %{
            "type" => "string",
            "description" => "Move immediately behind this ticket (same workspace)."
          },
          "pinned" => %{
            "type" => "boolean",
            "description" =>
              "Set or clear `rank_pinned` (a board drag pins; a plain move leaves the pin as it was). " <>
                "Alone: pin/unpin without moving. With a move: `true` pins with the move, " <>
                "`false` moves then unpins."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_rank/2
    },
    %{
      name: "ticket_resume_review",
      tiers: @coordinator,
      description:
        "Clear a tripped ReviewPatrol circuit breaker on a ticket so its PR review resumes, via the " <>
          "typed `:resume_review` action (the same one `POST /api/issues/:id/resume_review` and " <>
          "`arb ticket update --resume-review` use). Coordinator only. Idempotent — resuming an " <>
          "untripped ticket is a no-op success. The head commit the breaker tripped at is " <>
          "watermarked, so the next review tick does not re-trip on the same commit. " <>
          "`ticket_update` does not write `circuit_breaker_*` — this is the one door.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.ticket_resume_review/2
    },
    %{
      name: "epic_floor",
      tiers: @coordinator,
      description:
        "Set or clear an epic's priority floor via the `:set_floor` action " <>
          "(`docs/design/epic-aware-scheduling.md` §6.2). Coordinator only (the operator's and the " <>
          "coordinator's tokens); a worker cannot call it. `floor_priority` is required: 1..3 " <>
          "(or the strings `P1`..`P3`) sets the floor, `null` or `none` clears it. P0 is never a " <>
          "floor. Only an epic can carry one — any other ticket is rejected. The epic's own " <>
          "`priority` is unrelated and is not changed.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Epic id (required)."},
          "floor_priority" => %{
            "type" => ["integer", "string", "null"],
            "description" =>
              "1..3 or P1..P3 to set the floor; null or none to clear it. Required."
          }
        },
        "required" => ["id", "floor_priority"],
        "additionalProperties" => false
      },
      handler: &Tools.epic_floor/2
    },
    %{
      name: "ticket_handoff",
      tiers: @coordinator,
      description:
        "Hand a ticket's attention to the operator (bd-8nlez1). The coordinator inbox's " <>
          "`attention` queue is yours: resolve what you can. Use this only for an item you " <>
          "cannot move — the operator acts on it from the dashboard. `note` (required) says " <>
          "what the operator has to do; it is shown with the ticket and in `ticket_show`. The " <>
          "ticket must have attention now, owned by you. The move lasts until the attention " <>
          "clears or the operator hands it back.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "note" => %{
            "type" => "string",
            "description" => "What the operator has to do, and why you cannot (required)."
          }
        },
        "required" => ["id", "note"],
        "additionalProperties" => false
      },
      handler: &Tools.ticket_handoff/2
    },
    %{
      name: "ticket_handback",
      tiers: @coordinator,
      description:
        "Hand a ticket's attention back to the coordinator (bd-8nlez1) — the operator's " <>
          "answer to a hand-off or to an item promoted past its limit. The coordinator gets " <>
          "a fresh time limit and resume-attempt budget. `note` (optional) is shown with the " <>
          "ticket.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "note" => %{"type" => "string", "description" => "What changed (optional)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.ticket_handback/2
    },
    %{
      name: "ticket_sync_upstream_close",
      tiers: @coordinator,
      description:
        "Push a close to the linked tracker issue for a ticket that's already `:closed` locally " <>
          "but was never synced upstream (e.g. it closed via auto-close rollup or a caller that " <>
          "forgot `close_upstream: true`). Makes no local state change — the ticket must already " <>
          "be `:closed` and carry a `tracker_ref`. Does not reopen, re-run StopWorker/" <>
          "CleanupWorktree, or re-trigger the parent auto-close rollup.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."}
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.task_sync_upstream_close/2
    },
    %{
      name: "dep_add",
      tiers: @both,
      description:
        "Add a dependency edge between two tickets in the workspace. A worker may add only a " <>
          "`parent_of` edge from its own task to an unparented ticket in its workspace (no " <>
          "`notes`/`created_by`), the same rule as `POST /api/dependencies`. `type` is one of blocks, " <>
          "depends_on, relates_to, discovered_from, parent_of, conflicts_with. Use `parent_of` " <>
          "(from = parent, to = child) to attach a child to a parent ticket — that is how " <>
          "grouping/epics work; the parent then rolls up child progress and can auto-close. " <>
          "`conflicts_with` is a symmetric mutex enforced by the board scheduler " <>
          "(Autopilot), which will not co-dispatch the pair, in either edge " <>
          "direction, while one of them is in flight (running, in review, awaiting review or " <>
          "in a fix pass). The held card reads `blocked — conflicts with <id> (<state>)` and " <>
          "goes once the counterpart merges, closes or is parked. " <>
          "Only blocks/depends_on gate readiness, and a gating edge that would close a cycle " <>
          "is rejected with the cycle named.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "from_issue_id" => %{"type" => "string", "description" => "The dependent ticket."},
          "to_issue_id" => %{"type" => "string", "description" => "The dependency target."},
          "type" => %{"type" => "string", "description" => "Edge type (required)."},
          "notes" => %{"type" => "string"},
          "created_by" => %{
            "type" => "string",
            "description" => "Ignored: the creator is derived from the token."
          }
        },
        "required" => ["from_issue_id", "to_issue_id", "type"],
        "additionalProperties" => false
      },
      handler: &Tools.dep_add/2
    },
    %{
      name: "dep_remove",
      tiers: @coordinator,
      description:
        "Remove dependency edges between two tickets in the workspace. Omit `type` to remove every " <>
          "edge between the pair. Idempotent.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "from_issue_id" => %{"type" => "string"},
          "to_issue_id" => %{"type" => "string"},
          "type" => %{
            "type" => "string",
            "description" => "Optional edge type to narrow removal."
          }
        },
        "required" => ["from_issue_id", "to_issue_id"],
        "additionalProperties" => false
      },
      handler: &Tools.dep_remove/2
    },
    %{
      name: "dep_list",
      tiers: @both,
      description:
        "List dependency edges in the workspace. Coordinator or worker — a worker with no " <>
          "`workspace` arg sees its own workspace's edges; naming a different one is refused, " <>
          "the same rule dep_add/dep_remove already apply. With no `issue_id`, lists every edge " <>
          "in the workspace; with `issue_id`, lists that ticket's edges in both directions " <>
          "instead. Each row carries both endpoints' id/title/state/priority, so a live edge " <>
          "is distinguishable from a closed↔closed one without a second lookup. A symmetric " <>
          "edge (`conflicts_with`) is never doubled — it's stored once, directed, and appears " <>
          "once no matter which endpoint you query from.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Workspace name or id. Optional; defaults to the scope's workspace."
          },
          "issue_id" => %{
            "type" => "string",
            "description" => "Scope the listing to one ticket's edges instead of the workspace."
          },
          "type" => %{
            "type" => "string",
            "description" => "Optional edge type to filter by."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.dep_list/2
    },
    %{
      name: "worker_dispatch",
      tiers: @coordinator,
      description:
        "Dispatch a worker to work a ticket in the workspace. Requires a `can_dispatch` coordinator " <>
          "token and is depth-limited (the dispatch-recursion guardrail). Omitting `provider` " <>
          "resolves the worker from the workspace's `agent.type` config (first healthy provider via " <>
          "ProviderPool). Pass `provider` to override; set `no_agent: true` to move the ticket " <>
          "to In progress without spawning a worker (hand-off / manual-attach workflows) — it " <>
          "cannot be combined with `provider`. An unknown provider or argument is refused, " <>
          "never silently replaced by the workspace default.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Ticket to dispatch (required)."},
          "repo" => %{
            "type" => "string",
            "description" =>
              "Repo to run in. Optional, and a one-shot override: it beats the ticket's own " <>
                "`repo` assignment, which in turn beats auto-selecting the workspace's sole " <>
                "configured repo."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "provider" => %{
            "type" => "string",
            # `"enum"` is filled from the agent registry by `live_schema/1`.
            "description" =>
              "Override the workspace's default provider. Omit to use the workspace `agent.type` config."
          },
          "no_agent" => %{
            "type" => "boolean",
            "description" =>
              "Dry dispatch — move the ticket to In progress without spawning a worker. Use for hand-off / manual-attach workflows."
          },
          "with_claude" => %{
            "type" => "boolean",
            "description" =>
              "DEPRECATED alias for `provider: \"claude\"`. `true` → start a Claude worker."
          },
          "with_gemini" => %{
            "type" => "boolean",
            "description" =>
              "DEPRECATED alias for `provider: \"gemini\"`. `true` → start a Gemini worker."
          },
          "force" => %{
            "type" => "boolean",
            "description" =>
              "Dispatch a ticket that is not Ready — in Backlog, or blocked by open dependencies. " <>
                "Without it such a dispatch is refused with the reason. The bypass is recorded as a " <>
                "`dispatch_forced` event. Defaults to false."
          },
          "over_cap" => %{
            "type" => "boolean",
            "description" =>
              "Dispatch even though the provider account this run would use has no free slot " <>
                "(its `max_concurrent`, or this workspace's share, is reached). Without it such a " <>
                "dispatch is refused with the account, its cap and the runs holding it. The " <>
                "override is recorded as an `account_cap_override` event. Defaults to false."
          },
          "force_quota" => %{
            "type" => "boolean",
            "description" =>
              "ADVANCED: bypass the quota gate for this dispatch. Use only for judged-important work when the gate holds despite headroom. Defaults to false (quota-gated)."
          },
          "force_quota_reason" => %{
            "type" => "string",
            "description" =>
              "ADVANCED: optional rationale for bypassing the quota gate. Only used when `force_quota: true`."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_dispatch/2
    },
    %{
      name: "worker_resume",
      tiers: @coordinator,
      description:
        "Resume a stopped worker (`arb worker resume`): re-spawn the agent continuing the ticket's " <>
          "PRIOR session (`--resume <session_id>`) in its preserved worktree — the same operation as " <>
          "`POST /api/workers/:task_id/resume`. Refused with `no_session` / `no_outpost` when there is " <>
          "nothing to continue. Pass `mode: \"briefing\"` for a fresh agent briefed from the worktree's " <>
          "git state instead. Requires a `can_dispatch` coordinator token and is depth-limited (the " <>
          "dispatch-recursion guardrail).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Ticket to resume (required)."},
          "mode" => %{
            "type" => "string",
            "enum" => ["session", "briefing"],
            "description" =>
              "`session` (default): continue the prior session. `briefing`: a fresh agent " <>
                "briefed from the worktree's git state (the previous MCP behaviour)."
          },
          "repo" => %{
            "type" => "string",
            "description" => "Repo to run in (optional; inherited from the ticket's last run)."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "force" => %{
            "type" => "boolean",
            "description" =>
              "Resume over a full concurrency cap. A ticket that released its slot (parked for you, " <>
                "stopped, completed) must re-acquire one; when none is free the resume is refused " <>
                "with the cap and the tickets holding it. `true` goes over the cap anyway, and the " <>
                "override is recorded. Defaults to false."
          },
          "force_quota" => %{
            "type" => "boolean",
            "description" =>
              "ADVANCED: bypass the quota gate for this resume. Use only for judged-important work when the gate holds despite headroom. Defaults to false (quota-gated)."
          },
          "force_quota_reason" => %{
            "type" => "string",
            "description" =>
              "ADVANCED: optional rationale for bypassing the quota gate. Only used when `force_quota: true`."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_resume/2
    },
    %{
      name: "worker_review",
      tiers: @coordinator,
      description:
        "Dispatch a review-only worker (`arb review`): no worktree, no branch, no merge. Requires a " <>
          "`can_dispatch` coordinator token and is depth-limited. Pass `task_id` to review the PR/MR " <>
          "linked to a ticket (claude-driven; `with_claude: false` skips the agent), or `pr` (URL or " <>
          "number, + optional `repo`/`workspace`) to review an external / non-arbiter PR through the " <>
          "MR adapter — findings + a verdict are posted to the PR, no ticket or branch required. For a " <>
          "`pr` review, `follow_up` opens a review_only ReviewPatrol engagement after the verdict so " <>
          "the PR is re-reviewed on new commits and its replies handled (defaults on when the " <>
          "workspace has ReviewPatrol running). A `pr` review is refused when this identity has " <>
          "already left a current approving review on the PR (avoids double-posting an approval), " <>
          "or when the resolved review_automation mode is \"off\" (a hard opt-out repo/workspace " <>
          "policy) — pass `force: true` to override either refusal.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Ticket to review (one of `task_id` or `pr` is required)."
          },
          "pr" => %{
            "type" => "string",
            "description" =>
              "External PR/MR to review: a forge URL, an `owner/repo#N` slug, or a number " <>
                "(pass `repo` so a bare number resolves to owner/repo)."
          },
          "repo" => %{
            "type" => "string",
            "description" =>
              "Local checkout. Ticket review: the reviewer's cwd (needs `gh`/`git`). " <>
                "`pr`: resolves owner/repo for a bare PR number."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "(`pr` only) Workspace name/id whose MR provider to target."
          },
          "model" => %{"type" => "string", "description" => "Per-dispatch model override."},
          "with_claude" => %{
            "type" => "boolean",
            "description" => "(ticket review) Spawn the reviewer agent (default true)."
          },
          "tracker_context_ref" => %{
            "type" => "string",
            "description" =>
              "Tracker issue ref to fetch acceptance criteria from — read-only " <>
                "context for the reviewer. No claim, no assignment check, no write-back. Safe " <>
                "for coworker-owned tickets (e.g. \"AX-18004\"). On a `pr` review with `follow_up`, " <>
                "it is also carried onto the engagement for re-review intent."
          },
          "tracker_context_type" => %{
            "type" => "string",
            "description" =>
              "Tracker type for `tracker_context_ref` (e.g. \"jira\"). " <>
                "Defaults to the workspace's tracker when omitted."
          },
          "follow_up" => %{
            "type" => "boolean",
            "description" =>
              "(`pr` only) Open a review_only ReviewPatrol engagement after the verdict posts so " <>
                "the PR is re-reviewed on new commits, its author replies are handled, and it is " <>
                "tracked to merge. Dedups on an already-open engagement for the same PR. When " <>
                "omitted, defaults to on iff the workspace has a ReviewPatrol running."
          },
          "automation" => %{
            "type" => "string",
            "enum" => [
              "auto",
              "report_only",
              "propose",
              "flag",
              "notify",
              "off",
              "never",
              "disabled"
            ],
            "description" =>
              "Override the workspace review_automation policy: \"auto\" = review AND post to the " <>
                ~s[PR; "report_only" (alias "propose") = review fully but post NOTHING — surface ] <>
                "findings + proposed comments to the coordinator to greenlight (infra default, " <>
                ~s[human-in-the-loop); "flag" (alias "notify") = do not review, just flag new ] <>
                ~s[commits/replies; "off" (aliases "never"/"disabled") = hard opt-out — refuse ] <>
                "to dispatch a reviewer at all, no agent spawned, nothing posted (pass `force: true` " <>
                "to override a single dispatch). When omitted, the mode is resolved from the " <>
                "workspace policy using the PR author (the actual author for a `pr` review; " <>
                "`pr_author` for a ticket review) or the workspace's `review_automation.repo_overrides` " <>
                "for `repo`."
          },
          "pr_author" => %{
            "type" => "string",
            "description" =>
              "(ticket review) Login of the PR author, used to resolve the workspace " <>
                "review_automation policy (auto_authors list). Ignored when `automation` is set."
          },
          "scope" => %{
            "type" => "string",
            "enum" => ["diff", "repo"],
            "description" =>
              "(`pr` only) Review depth: \"diff\" (default) — the reviewer only sees the unified " <>
                "diff. \"repo\" — additionally traces cross-file consumers of anything the diff " <>
                "changes against a read-only checkout of `repo` (no branch switch, no commit), " <>
                "surfacing downstream call sites a diff-only review would miss. When omitted, " <>
                "resolved from the workspace `review_scope` policy: a configured default, or " <>
                "auto-escalated to \"repo\" when the diff touches a `sensitive_globs` path " <>
                "(e.g. auth/signing code) — cross-cutting or security PRs get the deeper pass " <>
                "without per-dispatch opt-in."
          },
          "force" => %{
            "type" => "boolean",
            "description" =>
              "Skip the self-approve guard (`pr` only: dispatch even when this identity has " <>
                "already left a current approving review on the PR) AND/OR the review_automation " <>
                "\"off\" guard (`pr` and `task_id`: dispatch even when the resolved mode is " <>
                ~s["off"/"never"/"disabled"). Default false — normally such a dispatch is ] <>
                "refused so we don't double-post an approval or ignore a hard opt-out."
          },
          "force_quota" => %{
            "type" => "boolean",
            "description" =>
              "(ticket review) ADVANCED: bypass the quota gate for this review. Recorded with the " <>
                "caller as actor. Defaults to false (quota-gated)."
          },
          "force_quota_reason" => %{
            "type" => "string",
            "description" =>
              "(ticket review) ADVANCED: optional rationale for bypassing the quota gate. Only used " <>
                "when `force_quota: true`."
          }
        },
        "required" => [],
        "additionalProperties" => false
      },
      handler: &Tools.worker_review/2
    },
    %{
      name: "worker_stop",
      tiers: @coordinator,
      description:
        "Stop the worker currently working a ticket (`arb worker stop`). Scoped to the coordinator's " <>
          "workspace; a ticket with no live worker is reported not-found. Teardown only — does not dispatch.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Ticket whose worker to stop (required)."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_stop/2
    },
    %{
      name: "message_send",
      tiers: @both,
      description:
        "Send a message to a ticket's mailbox (the structured replacement for `arb message <task> <text>`). " <>
          "A coordinator sends a direction from `coordinator`; a worker raises a flag from its own ticket " <>
          "to a sibling. The sender identity is set from the scope and pinned to its workspace.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string", "description" => "Recipient ticket id (required)."},
          "body" => %{"type" => "string", "description" => "Message body (required)."},
          "subject" => %{"type" => "string"},
          "kind" => %{
            "type" => "string",
            "enum" => ["notification", "completion", "failure", "escalation", "info"],
            "description" =>
              "Message kind (notification|completion|failure|escalation|info). " <>
                "Defaults to auto-derived kind based on scope (direction for coordinator, flag for worker)."
          },
          "task_ref" => %{
            "type" => "string",
            "description" =>
              "The ticket id this message concerns. Shown in brackets by `arb inbox`. " <>
                "Defaults to the recipient task_id."
          },
          "directive_ref" => %{
            "type" => "string",
            "description" => "Deprecated alias for task_ref. Ignored if task_ref is also given."
          }
        },
        "required" => ["task_id", "body"],
        "additionalProperties" => false
      },
      handler: &Tools.message_send/2
    },
    %{
      name: "notify_list",
      tiers: @both,
      description:
        "List the most recent notifications (completions, milestones, system events) for the workspace. " <>
          "Read-only; optional `limit` (default 20).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max notifications to return (default 20)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.notify_list/2
    },
    %{
      name: "worker_list",
      tiers: @coordinator,
      description:
        "List the workspace's tickets with a live run, each as its current run: task_id " <>
          "(the ticket), run_task_id (the id the run runs under — a ReviewGate reviewer's is " <>
          "`<ticket>#review`), kind (implement | review | fix_pass | conflict), state " <>
          "(starting | working | waiting | finished), outcome (succeeded | failed | " <>
          "interrupted | handed_off, once finished), waiting_on, registry_key, role, phase, " <>
          "repo, started_at, activity, model (short display name e.g. \"Sonnet\"), cost_usd (sum " <>
          "of all ledger entries for the ticket), resumable (boolean: whether the ticket can be " <>
          "safely resumed), and blocked_reason (string or nil: human-readable reason if " <>
          "resumable is false). A merge-queue pass is an ordinary run of its ticket, " <>
          "registered under the ticket id with role `fix_pass` / `conflict_resolver`; the " <>
          "ticket's own run has role null. Check resumable before " <>
          "attempting to stop/resume: false indicates the ticket is blocked (e.g. awaiting " <>
          "merge queue or review gate) and cannot be safely touched. Never operate on a " <>
          "subordinate row (role is not null) — the merge queue owns those passes. The " <>
          "response always includes `workspace_id`: the workspace this call actually scoped " <>
          "to (the `workspace` arg if given, else the caller's bound workspace, else null " <>
          "= ALL workspaces), and `count`. Each row is the same shape as a `GET /api/workers` row. An empty `workers: []` means no live workers in THAT " <>
          "scope — check `workspace_id` before reading a zero count as \"everything " <>
          "died\".",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "fields" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Optional slim view: return only these top-level keys of the full payload " <>
                "(the same payload the REST route returns). An unknown name is " <>
                "an error, not a silent omission."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.worker_list/2
    },
    %{
      name: "worker_show",
      tiers: @coordinator,
      description:
        "The ticket's current run (`arb worker show <task-id>`) — the same read `worker_list` " <>
          "makes — with its kind, state, outcome, activity and recent output lines, plus " <>
          "`runs`: its recent runs newest first, each labelled with its kind, state and " <>
          "outcome (`current: true` on the current one), and `pre_push_checks`: the steps of " <>
          "the pre-push recipe the commit gate ran for the run, per attempt. A live run is read from its worker " <>
          ~s[(`source: "live"`), a finished one from its run row (`source: "history"`), ] <>
          "in the same vocabulary. Not-found only when the ticket never had a run.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Ticket whose worker to inspect (required)."
          },
          "lines" => %{
            "type" => "integer",
            "description" =>
              "Optional: return only the last N output lines instead of the full history."
          },
          "fields" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Optional slim view: return only these top-level keys of the full payload " <>
                "(the same payload the REST route returns). An unknown name is " <>
                "an error, not a silent omission."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.worker_show/2
    },
    %{
      name: "worker_runs",
      tiers: @coordinator,
      description:
        "Run history, newest first (`arb worker runs`) — the same query as `GET " <>
          "/api/workers/history`. With `task_id` it lists every run recorded for that ticket; " <>
          "with none it is FLEET-WIDE (\"which runs failed in the last hour\": `outcome: " <>
          "failed`, `before`/`kind`/`state`/`workspace` narrow it). With `run_id` it returns " <>
          "that one run including its output tail (`GET /api/workers/history/:id`). Each list " <>
          "entry is a run summary (no output lines — use `worker_log` for the transcript): id, " <>
          "task_id, task_title, repo, workspace_id, kind, state, outcome, model, started_at, " <>
          "completed_at, exit_code, failure_reason, failure_summary (a bounded human-readable " <>
          "ReviewGate VERDICT + top finding, when the run failed via a ReviewGate rejection; " <>
          "nil otherwise), provider, provider_fallback, and — under `routing.provider_selection: " <>
          "most_quota` — provider_account_id, model_family and routing_decision (the chosen " <>
          "account, per-candidate quota headroom, dropped candidates with reasons, any fallback " <>
          "or override). Optional `limit` (default 20, max #{Arbiter.Workers.Runs.history_cap()}; " <>
          "the same cap on every surface). `task_id` may be a ReviewGate synthetic id " <>
          "(`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`) — those aren't `issues` " <>
          "rows, but the run lookup still resolves (authorization checks the base ticket).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Ticket whose run history to list (optional: omit for a fleet-wide query). " <>
                "Accepts a plain ticket id or a ReviewGate synthetic id such as " <>
                "`<base>#review`. With `run_id`, the run must belong to this task."
          },
          "run_id" => %{
            "type" => "string",
            "description" => "Read this one run (summary + output tail) instead of a list."
          },
          "kind" => %{
            "type" => "string",
            "enum" => Enum.map(Arbiter.Workers.Run.kinds(), &Atom.to_string/1),
            "description" => "Only runs of this kind."
          },
          "state" => %{
            "type" => "string",
            "enum" => Enum.map(Arbiter.Workers.RunState.states(), &Atom.to_string/1),
            "description" => "Only runs in this state."
          },
          "outcome" => %{
            "type" => "string",
            "enum" => Enum.map(Arbiter.Workers.RunState.outcomes(), &Atom.to_string/1),
            "description" => "Only finished runs with this outcome."
          },
          "before" => %{
            "type" => "string",
            "description" =>
              "ISO 8601 cursor: only runs that started strictly before it (page older with " <>
                "the oldest `started_at` of the previous page)."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Max runs to return (default 20, max #{Arbiter.Workers.Runs.history_cap()})."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.worker_runs/2
    },
    %{
      name: "worker_log",
      tiers: @coordinator,
      description:
        "Full, uncapped durable transcript of one run — the audit source of record, " <>
          "retaining every line however long the run. Pass `run_id` to read that exact run " <>
          "(independent of which run is latest — the only way to reach a superseded/failed " <>
          "attempt), or `task_id` (no `run_id`) for the ticket's most recent run (`arb worker " <>
          "log <task-id>`, unchanged behaviour). `task_id` may be a ReviewGate synthetic id " <>
          "(`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`). `exists` distinguishes " <>
          ~s["no file yet / never captured" (false, empty `lines`) from "captured but empty" ] <>
          "(true, empty `lines`). Not-found when no matching run exists.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Ticket whose latest run's transcript to read. Accepts a plain ticket id or a " <>
                "ReviewGate synthetic id such as `<base>#review`. With `run_id`, the run must belong to this task."
          },
          "run_id" => %{
            "type" => "string",
            "description" =>
              "Exact run id whose transcript to read, independent of which run is latest " <>
                "for its ticket. Selects the run; a `task_id` given beside it must own it."
          },
          "tail" => %{
            "type" => "integer",
            "description" =>
              "Return only the last N lines (`line_count` stays the true total and " <>
                "`truncated` says whether `lines` is shorter). Default: the whole transcript."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.worker_log/2
    },
    %{
      name: "worker_prompt",
      tiers: @coordinator,
      description:
        "The composed prompt one run was spawned with (bd-9rdwe4, #1017 gap G5), redacted " <>
          "through the same choke-point as transcript lines — the sibling of `worker_log` for " <>
          ~s("what was this agent told" instead of "what did it say". Pass `run_id` to read ) <>
          "that exact run, or `task_id` (no `run_id`) for the ticket's most recent run. `task_id` " <>
          "may be a ReviewGate synthetic id (`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, " <>
          "`#t<N>`). `exists` distinguishes \"no prompt ever persisted\" (false, `prompt` nil) " <>
          "from a captured (possibly empty-after-redaction) one. `prompt_sha256` mirrors the " <>
          "Run row's column so identical prompts are comparable without re-fetching the text. " <>
          "Not-found when no matching run exists.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Ticket whose latest run's prompt to read. Accepts a plain ticket id or a " <>
                "ReviewGate synthetic id such as `<base>#review`. Ignored when `run_id` is given."
          },
          "run_id" => %{
            "type" => "string",
            "description" =>
              "Exact run id whose prompt to read, independent of which run is latest for its " <>
                "ticket. Selects the run; a `task_id` given beside it must own it."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.worker_prompt/2
    },
    %{
      name: "run_log_list",
      tiers: @coordinator,
      description:
        "Enumerate every run recorded for a ticket AND its ReviewGate synthetic children " <>
          "(`<task_id>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`), newest first — the " <>
          "whole retrievable transcript corpus for a ticket in one call. Unlike `worker_runs` " <>
          "(exact `task_id` match only), this also matches anything prefixed `<task_id>#`, " <>
          "surfacing the reviewer/re-prompt corpus alongside the author's own runs. Each " <>
          "entry: run_id, task_id, kind, state, outcome, model, started_at, " <>
          "transcript_exists, line_count. Optional `limit` (default 200, max #{Arbiter.Workers.Runs.corpus_cap()}).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Base ticket whose full run corpus (including synthetic children) to list " <>
                "(required). Pass the plain ticket id even to reach synthetic runs."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Max runs to return (default 200, max #{Arbiter.Workers.Runs.corpus_cap()})."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.run_log_list/2
    },
    %{
      name: "transcript_capture_stats",
      tiers: @coordinator,
      description:
        "Transcript-capture health for a workspace (bd-9wotbo, gap G4): what fraction of " <>
          "Claude-driven runs actually produced a durable transcript. Scoped to " <>
          "`started_at >= 2026-06-20` (the arbiter-worker-logs corpus start date — earlier runs " <>
          "lived under the retired arbiter-polecat-logs root, an accepted, unreachable loss). " <>
          "Workflow-mode (bookkeeping-only) runs never open a Claude session, so they're reported " <>
          "separately as workflow_only_runs and excluded from claude_sessions / capture_rate_pct " <>
          "rather than counted as capture failures. Returns corpus_start_date, total_runs, " <>
          "claude_sessions, transcript_missing, workflow_only_runs, capture_rate_pct (nil when " <>
          "claude_sessions is 0). bd-db0p38: the richer artifact — the agent CLI's own session " <>
          "JSONL, archived per run as <run_id>.jsonl.gz — is counted separately, since the two " <>
          "losses are independent and a single rate hides the JSONL's absence: jsonl_sessions " <>
          "(runs with provider == \"claude\"), jsonl_archived, jsonl_missing, " <>
          "jsonl_archive_rate_pct. bd-6nupvc T9: agy (provider == \"gemini\") runs archive into " <>
          "their own SQLite branch (<run_id>.db.gz), counted separately as gemini_db_sessions, " <>
          "gemini_db_archived, gemini_db_missing, gemini_db_archive_rate_pct — folding them into " <>
          "the jsonl_* counts would report every one as a lost JSONL, since agy runs also carry a " <>
          "config_dir (their effective $HOME) but never had a JSONL to lose. non_claude_sessions " <>
          "is session-bearing runs on neither provider, which have no archive branch at all today. " <>
          "Optional `workspace` to target a workspace other than the default.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" => "Workspace name/id to report on. Omit for the default workspace."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.transcript_capture_stats/2
    },
    %{
      name: "external_review_list",
      tiers: @coordinator,
      description:
        "List recent ExternalReview audit records for a workspace (bd-31fh9e). Returns in-flight " <>
          "and completed external PR reviews in reverse-chronological order. Each record carries the " <>
          "PR ref, verdict, finding count, model, cost, dispatched-by, and timestamps. Optional " <>
          "`limit` (default 20, max 200), `status` filter (`running` | `completed` | `failed`), and " <>
          "`workspace` to target a workspace other than the default.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max records to return (default 20, max 200)."
          },
          "status" => %{
            "type" => "string",
            "enum" => ["running", "completed", "failed"],
            "description" => "Filter by review status. Omit for all."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.external_review_list/2
    },
    %{
      name: "external_review_show",
      tiers: @coordinator,
      description:
        "Fetch a single ExternalReview record by `record_id`, including its full " <>
          "`proposed_comments` (file, line, severity, message, body) — the pre-greenlight read " <>
          "path for a report_only review (bd-dmy4pk). Workspace-agnostic: looked up directly by " <>
          "id, no workspace filter.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "record_id" => %{
            "type" => "string",
            "description" => "ExternalReview record id to fetch (required)."
          }
        },
        "required" => ["record_id"],
        "additionalProperties" => false
      },
      handler: &Tools.external_review_show/2
    },
    %{
      name: "external_review_transcript",
      tiers: @coordinator,
      description:
        "Full durable corpus of one external review (bd-7efini): the composed prompt it was " <>
          "given, the raw stream-json transcript its reviewer emitted, and every tool call in " <>
          "that transcript paired with the result it returned. `worker_log`'s counterpart for a " <>
          "review — an external review is not task-linked, so it has no run row and can't be " <>
          "reached via `run_log_list`/`worker_log`; it is keyed on its own review record id. " <>
          "Returns record_id, pr_ref, path, prompt_path, exists, prompt_exists, prompt, " <>
          "line_count, lines, truncated, tool_use_count, tools_used, tool_uses. Workspace-" <>
          "agnostic, like `external_review_show`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "record_id" => %{
            "type" => "string",
            "description" => "ExternalReview record id whose transcript to read (required)."
          },
          "tail" => %{
            "type" => "integer",
            "description" =>
              "Return only the last N transcript lines (`truncated: true` when lines were " <>
                "dropped). Omit for the whole transcript — a tool-heavy review runs to " <>
                "thousands of JSONL lines."
          },
          "include_prompt" => %{
            "type" => "boolean",
            "description" => "Set false to skip the (large) composed prompt. Default true."
          }
        },
        "required" => ["record_id"],
        "additionalProperties" => false
      },
      handler: &Tools.external_review_transcript/2
    },
    %{
      name: "review_gate_rounds_list",
      tiers: @coordinator,
      description:
        "List internal ReviewGate round outcomes for a ticket (bd-aqyjuc): one row per reviewer " <>
          "or implementer pass, oldest-first. Each row carries the round number, role " <>
          "(review/impl, or conflict_review for a scoped review of hand-resolved merge/rebase " <>
          "conflicts — bd-954ym8, which also returns `conflict_review` counts of auto-covered " <>
          "clean rebases, scoped reviews and fallbacks to a full review), verdict (approve/request_changes, nil for impl), findings text, " <>
          "finding count, the model that ran the pass, its cost, and whether it converged — " <>
          "and, under `review_agent.cross_family` (bd-a1ke2c), the reviewer's model family, " <>
          "the implementer's, and `same_family_fallback` with its reason when no other family " <>
          "was available — " <>
          "so a round-1 rejection followed by a round-2 approval is visible as two distinct " <>
          "rows instead of collapsing into the ticket's terminal outcome. Backfill is out of " <>
          "scope; rows only exist for ReviewGate runs from 2026-07-28 onward.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Ticket whose ReviewGate rounds to list (required)."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Cap the response to the most recent N rounds, still returned oldest-first " <>
                "(optional; omit for full history). `total_count` in the response always " <>
                "reports how many rounds exist."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.review_gate_rounds_list/2
    },
    %{
      name: "review_gate_resolve",
      tiers: @coordinator,
      description:
        "Record your answer to a gate escalation (bd-4qjl0q) — the ReviewGate hitting its " <>
          "round cap without converging, or the notes / commit gate spending its send-back " <>
          "budget. Persists the decision (accept_as_is / amend / send_back / reject), your " <>
          "reasoning, the actor and a timestamp against the ticket and, for a ReviewGate " <>
          "escalation, the reviewer round it answers (the latest one unless you name it). " <>
          "`review_gate_rounds_list` then returns it after the rounds with `outcome: resolved`, " <>
          "so an override of a reviewer's standing finding is visible where the argument is, " <>
          "not only in a commit message. A record, not an action: it does not resume, merge " <>
          "or close anything — do that with the usual tools. But it is read by the merge path: " <>
          "ONLY accept_as_is / amend permit a merge without a fresh reviewer APPROVE (and only " <>
          "of the head they were recorded against). send_back means ANOTHER REVIEW ROUND FOLLOWS " <>
          "the implementer's next completion — it never authorises a merge, and a PR whose " <>
          "latest reviewer verdict is not APPROVE stays unmerged until that round approves. " <>
          "CLI: `arb review resolve <ticket> --amend \"<reasoning>\"`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "Ticket whose escalation you are resolving (required)."
          },
          "decision" => %{
            "type" => "string",
            "enum" => ["accept_as_is", "amend", "send_back", "reject"],
            "description" =>
              "accept_as_is: ship with the finding standing (permits the merge). amend: you " <>
                "change the requirement or direct a specific change on your own authority " <>
                "(permits the merge). send_back: return it to the implementer — another review " <>
                "round follows when it finishes; does NOT permit a merge. reject: abandon the " <>
                "work (does not permit a merge). (required)"
          },
          "reasoning" => %{
            "type" => "string",
            "description" => "Why — the part a commit message used to carry (required)."
          },
          "gate" => %{
            "type" => "string",
            "enum" => ["review_gate", "notes_gate", "commit_gate"],
            "description" => "Which gate escalated. Default review_gate."
          },
          "actor" => %{
            "type" => "string",
            "description" => "Ignored: the decider is derived from the token."
          },
          "round" => %{
            "type" => "integer",
            "description" =>
              "ReviewGate round this answers. Default: the ticket's latest reviewer round."
          },
          "fix_round_attempt" => %{
            "type" => "integer",
            "description" => "The fix-round pass `round` belongs to (default 0 with `round`)."
          },
          "head_sha" => %{
            "type" => "string",
            "description" =>
              "The commit your accept_as_is / amend covers. Default: the head of the ticket's " <>
                "PR as last observed. A head pushed after it needs a reviewer round or a new " <>
                "decision."
          }
        },
        "required" => ["task_id", "decision", "reasoning"],
        "additionalProperties" => false
      },
      handler: &Tools.review_gate_resolve/2
    },
    %{
      name: "review_greenlight",
      tiers: @coordinator,
      description:
        "Greenlight a report-only (propose) review (bd-36qzgx): post the approved subset of a " <>
          "review's proposed comments to the PR under the fleet's identity — and nothing else. " <>
          "Requires a `can_dispatch` coordinator token. Pass `record_id` (from external_review_list; " <>
          "the review's `mode` must be `report_only`). `select` chooses which proposed comments post: " <>
          "omit or \"all\" for every comment, a list of zero-based indices for a subset, or [] to " <>
          "approve nothing (a true no-op on the PR). `post_verdict` also submits the recommended " <>
          "verdict (defaults on when ≥1 comment is approved).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "record_id" => %{
            "type" => "string",
            "description" =>
              "ExternalReview record id of the report-only review to greenlight (required)."
          },
          "select" => %{
            "oneOf" => [
              %{"type" => "string", "enum" => ["all"]},
              %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 0}}
            ],
            "description" =>
              "Which proposed comments to post: \"all\" (default), a list of zero-based indices, or [] for none."
          },
          "post_verdict" => %{
            "type" => "boolean",
            "description" =>
              "Also submit the recommended verdict as a single review. Defaults on iff ≥1 comment is approved."
          },
          "repo" => %{
            "type" => "string",
            "description" =>
              "Local checkout (only needed by adapters resolving owner/repo for a bare PR number)."
          }
        },
        "required" => ["record_id"],
        "additionalProperties" => false
      },
      handler: &Tools.review_greenlight/2
    },
    %{
      name: "ticket_list",
      tiers: @coordinator,
      description:
        "List tickets in the workspace with optional filters: `state` (backlog | queued | " <>
          "active | merging | verifying | closed), `column` (backlog | blocked | ready | " <>
          "in_progress | merging | verifying | closed), `priority` (integer 0–4) and " <>
          "`difficulty` (integer 0–5), `issue_type` (task | research | bug | feature | epic | chore | " <>
          "decision) and `engagements` " <>
          "(all | exclude | only — ReviewPatrol review engagements, i.e. review_only tickets with a " <>
          "source_pr; default all, so nothing is hidden unless you ask). Each ticket carries " <>
          "`state`, `column`, `step`, `blocked_by` and `attention` — and, on a Ready card the " <>
          "scheduler is holding, `hold_reason`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "state" => %{
            "type" => "string",
            "description" =>
              "Filter by stored lifecycle state: backlog | queued | active | merging | " <>
                "verifying | closed."
          },
          "difficulty" => %{
            "type" => "integer",
            "description" => "Filter by difficulty (0 = trivial … 5 = hardest)."
          },
          "column" => %{
            "type" => "string",
            "description" =>
              "Filter by board column: backlog | blocked | ready | in_progress | merging | " <>
                "verifying | closed. Blocked and Ready split `queued` by its gating edges."
          },
          "priority" => %{
            "type" => "integer",
            "description" => "Filter by priority (0 = highest, 4 = lowest)."
          },
          "issue_type" => %{
            "type" => "string",
            "description" =>
              "Filter by type: task | research | bug | feature | epic | chore | decision."
          },
          "engagements" => %{
            "type" => "string",
            "description" =>
              "ReviewPatrol review engagements (review_only with a source_pr): all (default) | " <>
                "exclude | only. A worker_review task or a PR follow-up is not an engagement."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.task_list/2
    },
    %{
      name: "tracker_claim",
      tiers: @coordinator,
      description:
        "Claim an external tracker issue into a ticket (`arb claim <issue#>`). Verifies the issue is " <>
          "assigned to the workspace user (skip with `force: true`) and creates a linked ticket. " <>
          "Idempotent — returns the existing ticket if one already references the issue. " <>
          "`difficulty` and `issue_type` are otherwise derived from the issue's tracker labels " <>
          "where the adapter supports it (currently GitHub); `difficulty` and `repo` below " <>
          "override whatever would otherwise be derived or left unset (`difficulty` is checked " <>
          "against 0..5 before the tracker is called). Returns `{status: created | existing, " <>
          "task}` — the REST shape; refusals are typed `already_claimed` (409) / `not_assigned` (403).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "ref" => %{
            "type" => "string",
            "description" => "Tracker issue ref / number (required)."
          },
          "force" => %{
            "type" => "boolean",
            "description" => "Skip the assignment-as-claim check (default false)."
          },
          "difficulty" => %{
            "type" => "integer",
            "description" =>
              "0 (D0, trivial) .. 5 (D5). Overrides any value derived from the issue's " <>
                "labels. Omit to keep the derived value (or nil, which routing treats as D2)."
          },
          "repo" => %{
            "type" => "string",
            "description" =>
              "The repo this ticket belongs to, as a configured `repo_paths` key " <>
                "(e.g. \"emricare/tonic\"). Optional — only needed in a multi-repo workspace, " <>
                "where dispatch otherwise can't tell which checkout the claimed issue is for."
          }
        },
        "required" => ["ref"],
        "additionalProperties" => false
      },
      handler: &Tools.tracker_claim/2
    },
    %{
      name: "tracker_list_issues",
      tiers: @coordinator,
      description:
        "List the open tracker issues assigned to the workspace user (`arb ticket list --tracker`, " <>
          "`GET /api/workspaces/:id/tracker/issues`) — the `ref`s `tracker_claim` takes. Returns " <>
          "`{data: [{ref, title, url, status, assignees}], supported}`; `supported: false` (no rows) " <>
          "means the tracker has no backlog listing, not an error.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.tracker_list_issues/2
    },
    %{
      name: "tracker_create_ticket",
      tiers: @coordinator,
      description:
        "Create an UNCLAIMED ticket in the workspace's external tracker with no local ticket " <>
          "(`arb ticket create --ticket-only`, `POST /api/workspaces/:id/tracker/tickets`), so any " <>
          "fleet contributor can pick it up with `tracker_claim`. Needs a configured tracker whose " <>
          "adapter supports outbound create. Returns `{ref, url, tracker_type}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Ticket title (required)."},
          "description" => %{"type" => "string", "description" => "Ticket body (optional)."},
          "priority" => %{"type" => "integer", "description" => "0 (P0) .. 4 (P4) (optional)."},
          "issue_type" => %{
            "type" => "string",
            "description" => "Issue type, e.g. bug | feature | task (optional)."
          }
        },
        "required" => ["title"],
        "additionalProperties" => false
      },
      handler: &Tools.tracker_create_ticket/2
    },
    %{
      name: "tracker_sync",
      tiers: @coordinator,
      description:
        "Reconcile the workspace's tickets against its external tracker (`arb sync`): open assigned " <>
          "issues with no ticket get a linked ticket; open tickets whose issue is closed upstream or " <>
          "reassigned away get closed (unassigned issues are left alone); closed tickets whose close was " <>
          "meant to propagate upstream — a recorded close intent, or for rows closed before that was " <>
          "recorded a non-blank `pr_ref` — but whose tracker issue is still open are reported as `drift` " <>
          "(a close that never propagated upstream — drift entries are report-only and never mutate the " <>
          "local ticket). `task`-type and `review_only` tickets are exempt: they are expected to close with " <>
          "their ticket still open. `dry: true` returns the plan without acting. No-ops cleanly when the " <>
          "tracker does not support reconciliation. Returns the REST shape — `data` (the planned " <>
          "actions; a `create` carries `url`), `applied` and, once applied, `results` — plus " <>
          "`actions` (= `data`) and `count`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "dry" => %{
            "type" => "boolean",
            "description" => "Return the plan without applying it (default false)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.tracker_sync/2
    },
    %{
      name: "workspace_list",
      tiers: @coordinator,
      description:
        "List the configured workspaces (id, name, prefix, tracker type) — the discovery surface for " <>
          "which workspaces exist. Summary fields only; full config + security posture stay behind " <>
          "`workspace_show` for the bound workspace.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_list/2
    },
    %{
      name: "workspace_config_get",
      tiers: @both,
      description:
        "Read a dotted.key (e.g. \"merge.auto_merge\") or the full config for a named workspace. " <>
          "Secret *values* are never returned — only `secret_keys` (the names of configured secrets) " <>
          "and any `credentials_ref` pointers already embedded in the config JSON. " <>
          "`effective_merge_strategies` maps each repo to the merge strategy it actually uses " <>
          "(a `merge.repos.<repo>.strategy` override, else `merge.strategy`). " <>
          "Returns `{workspace, key, value, effective_merge_strategies, secret_keys}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" =>
              "Dotted config key to read (e.g. \"merge.auto_merge\"). Omit to return the full config."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.workspace_config_get/2
    },
    %{
      name: "workspace_config_overview",
      tiers: @both,
      description:
        "A human-readable grouped summary of the workspace config: tracker, merge, agent, " <>
          "review_agent, routing, review, review_gate, standing_orders, and the names of configured " <>
          "secrets (values never exposed). Mirrors `arb config overview`. " <>
          "Returns `{workspace, tracker, merge, agent, …, secret_keys}`.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_config_overview/2
    },
    %{
      name: "workspace_config_set",
      tiers: @coordinator,
      description:
        "Set config via the deep-merge config endpoint, preserving all sibling keys. Either one " <>
          "dotted `key` + `value`, or a multi-key atomic write: `patch` (a nested object deep-merged " <>
          "in; a key containing a dot is just a map key) and/or `unset_paths` (dotted keys to remove, " <>
          "applied first) — never both forms. A literal dot in a dotted key segment (a repo name) is " <>
          "written `\\.` (`repo_paths.my\\.repo`). Call `workspace_config_schema` for every key and its " <>
          "valid values. Refused by the server, on every surface: `secret*` / " <>
          "`credentials*` top-level keys (use `arb workspace secret` for secrets), emptying " <>
          "`repo_paths`, and `tracker.type` with no `tracker.config` (`force: true` overrides the " <>
          "last two). Returns `{workspace, config, secret_keys}` after the merge so the caller " <>
          "can confirm the result.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" =>
              "Dotted config key to set (e.g. \"merge.auto_merge\"). Required with `value` unless " <>
                "`patch` / `unset_paths` is used."
          },
          "patch" => %{
            "type" => "object",
            "description" =>
              "Multi-key form: a partial config deep-merged into the existing one (objects recurse, " <>
                "scalars and arrays replace). Use instead of key/value."
          },
          "unset_paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Multi-key form: dotted paths to remove before `patch` is merged (an absent path is a no-op)."
          },
          "force" => %{
            "type" => "boolean",
            "description" =>
              "Override the safety rails (repo_paths emptied, tracker.type with no tracker.config)."
          },
          "value" => %{
            "oneOf" => [
              %{"type" => "boolean"},
              %{"type" => "integer"},
              %{"type" => "number"},
              %{"type" => "string"},
              %{"type" => "object"},
              %{"type" => "array"},
              %{"type" => "null"}
            ],
            "description" =>
              "Value to assign. Accepts any JSON type: boolean, integer, string, object, array, " <>
                "or null. Pass a real JSON array/object for list/nested keys (e.g. " <>
                "[\"claude\", \"gemini\"]) — do NOT pass a JSON-encoded string."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.workspace_config_set/2
    },
    %{
      name: "workspace_config_schema",
      tiers: @both,
      description:
        "The reference for every `workspace.config` key (tracker, merge, agent, security, routing, " <>
          "review, quota, standing_orders, repo_paths, …) with valid values and defaults — what " <>
          "`workspace_config_set` accepts. Same text as `arb config schema` and " <>
          "`GET /api/workspaces/config_schema`. Returns `{text, enums}`.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.workspace_config_schema/2
    },
    %{
      name: "workspace_standing_order_add",
      tiers: @coordinator,
      description:
        "Append ONE standing order (coordinator-facing, shown in `arb prime`) atomically on the " <>
          "server — two concurrent adds both survive, unlike rewriting the list with " <>
          "`workspace_config_set`. `repo` targets a registered repo's `repo_paths.<repo>." <>
          "standing_orders`. Returns `{workspace, repo, standing_orders}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "The standing order. Required."},
          "repo" => %{
            "type" => "string",
            "description" =>
              "A registered repo name, for a repo-scoped order. Omit for workspace-wide."
          }
        },
        "required" => ["text"],
        "additionalProperties" => false
      },
      handler: &Tools.workspace_standing_order_add/2
    },
    %{
      name: "workspace_standing_order_remove",
      tiers: @coordinator,
      description:
        "Remove ONE standing order atomically on the server, by 1-based index or exact text. " <>
          "`repo` targets a registered repo's list. Returns `{workspace, repo, standing_orders}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "target" => %{
            "oneOf" => [%{"type" => "integer"}, %{"type" => "string"}],
            "description" => "1-based index, or the order's exact text. Required."
          },
          "repo" => %{
            "type" => "string",
            "description" =>
              "A registered repo name, for a repo-scoped order. Omit for workspace-wide."
          }
        },
        "required" => ["target"],
        "additionalProperties" => false
      },
      handler: &Tools.workspace_standing_order_remove/2
    },
    %{
      name: "workspace_config_unset",
      tiers: @coordinator,
      description:
        "Remove a single dotted.key from the config via the deep-merge endpoint, preserving all " <>
          "sibling keys. Unsetting an absent key is a no-op success. A literal dot in a key " <>
          "segment is written `\\.`. The server refuses to unset the last `repo_paths` entry or " <>
          "`tracker.config` under a typed tracker unless `force: true`. Returns `{workspace, config, secret_keys}` after the removal.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" =>
              "Dotted config key to remove (e.g. \"agent.config.vernacular\"). Required."
          },
          "force" => %{
            "type" => "boolean",
            "description" => "Override the safety rails (see above)."
          }
        },
        "required" => ["key"],
        "additionalProperties" => false
      },
      handler: &Tools.workspace_config_unset/2
    },
    %{
      name: "installation_config_get",
      tiers: @both,
      description:
        "Read an install-wide runtime setting (not workspace-scoped): " <>
          "`credential_watchdog_adapters`, `credential_watchdog_interval_ms`, " <>
          "`credential_watchdog_recovery_interval_ms`, " <>
          "`quota_providers_shown` / `quota_providers_hidden` (the providers forced onto / off " <>
          "the status-bar quota chip and /usage; null = auto-detect). " <>
          "`output_offload_enabled`, the `scheduling_*` knobs and the `nodes.*` keys are readable " <>
          "too. `value` is the value in force (the override, else the default); `override` is " <>
          "the raw persisted value (null = none). " <>
          "Omit `key` to get every setting (`value` = map of effective values, `items` = the " <>
          "full per-key records). Returns `{key, type, description, allowed, value, override, " <>
          "overridden, default, settings}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "enum" => Arbiter.Settings.Registry.keys(),
            "description" =>
              "Setting name (e.g. \"credential_watchdog_interval_ms\"). Omit for all settings."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.installation_config_get/2
    },
    %{
      name: "installation_config_set",
      tiers: @coordinator,
      description:
        "Set an install-wide runtime setting; `null` always clears the override and falls back " <>
          "to the app-env/hardcoded default. " <>
          ~s[`credential_watchdog_adapters` (list of agent types — "claude", "gemini", ] <>
          "\"codex\"; `[]` probes nothing), `credential_watchdog_interval_ms` and " <>
          "`credential_watchdog_recovery_interval_ms` (positive integers) take effect on the " <>
          "CredentialWatchdog's next poll cycle. `quota_providers_shown` / " <>
          ~s[`quota_providers_hidden` (lists of quota providers — "claude", "codex", ] <>
          ~s["antigravity") force a provider onto / off the status-bar quota chip and /usage ] <>
          "on top of auto-detection (hidden wins; null = auto-detect; codex stays hidden " <>
          "until parity); they take effect on the next page load. " <>
          "`output_offload_enabled` (boolean; the output-offload sweeper ships OFF, `true` " <>
          "turns it on, `null` back off) takes effect on the sweeper's next tick. " <>
          "`scheduling_finish_first` (boolean) and `scheduling_finish_first_max_wait_hours` " <>
          "(positive integer) tune the epic-aware Ready order's finish-first tiebreak " <>
          "(null = off / 24h); `scheduling_epic_floors_enabled` and " <>
          "`scheduling_max_lifted_in_flight` and the `nodes.*` keys (remote-node enrolment) " <>
          "are operator-only and refused without an operator-proof token. " <>
          "No restart required. Returns `{key, value}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "enum" => Arbiter.Settings.Registry.keys(),
            "description" => "Setting name (e.g. \"credential_watchdog_interval_ms\"). Required."
          },
          "value" => %{
            "description" =>
              "Positive integer (or, for credential_watchdog_adapters, a list of agent-type " <>
                "strings; for nodes.public_url, an https URL string), or null to clear the override.",
            "oneOf" => [
              %{
                "type" => "null",
                "description" => "Clear the override and fall back to default."
              },
              %{
                "type" => "integer",
                "minimum" => 1,
                "description" =>
                  "Positive integer for credential_watchdog_interval_ms, credential_watchdog_recovery_interval_ms, " <>
                    "scheduling_max_lifted_in_flight or scheduling_finish_first_max_wait_hours."
              },
              %{
                "type" => "boolean",
                "description" =>
                  "true/false for output_offload_enabled, scheduling_finish_first, " <>
                    "scheduling_epic_floors_enabled or nodes.allow_public_endpoint."
              },
              %{
                "type" => "string",
                "description" => "http(s) URL for nodes.public_url."
              },
              %{
                "type" => "array",
                "items" => %{
                  "type" => "string",
                  "enum" => ["claude", "gemini", "codex", "antigravity"]
                },
                "description" =>
                  ~s|List of agent type strings for credential_watchdog_adapters (e.g., ["claude", "gemini"]), | <>
                    "or of quota provider codes for quota_providers_shown / quota_providers_hidden " <>
                    ~s|(e.g., ["antigravity"]).|
              }
            ]
          }
        },
        "required" => ["key", "value"],
        "additionalProperties" => false
      },
      handler: &Tools.installation_config_set/2
    },
    %{
      name: "skill_create",
      tiers: @coordinator,
      description:
        "Create a skill (a reusable markdown instruction module arbiter materializes into a " <>
          "worker's worktree). Scope with the optional `workspace` arg: omit it for a GLOBAL " <>
          "skill shared by every workspace (default), or name a workspace to create a " <>
          "workspace-scoped skill that shadows a same-named global there. `name` (unique " <>
          "within the scope, kebab-case) and `body` (markdown) are required; optional " <>
          "`metadata` object, `activation_mode` (always_on|situational, default situational), " <>
          "and `code_only` (bool, default false). The paper-trail version records the calling " <>
          "actor. Returns the created skill (with `scope`/`workspace_id`), plus a non-fatal " <>
          "`warning` when the name collides with a bundled skill.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Unique kebab-case name; the /<name> slash command. Required."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) to scope the skill to. Omit for a global skill."
          },
          "body" => %{
            "type" => "string",
            "description" => "Markdown skill body (the SKILL.md contents). Required."
          },
          "metadata" => %{
            "type" => "object",
            "description" => "Optional free-form metadata (e.g. description, tags)."
          },
          "activation_mode" => %{
            "type" => "string",
            "enum" => ["situational", "always_on"],
            "description" =>
              "always_on = arbiter auto-invokes /<name> in every worker prompt where the " <>
                "skill applies; situational = advertised only, agent decides. Default situational."
          },
          "code_only" => %{
            "type" => "boolean",
            "description" =>
              "When true, the skill only applies to code-producing tickets (feature/bug/chore); " <>
                "excluded from decision/task/epic. Default false."
          }
        },
        "required" => ["name", "body"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_create/2
    },
    %{
      name: "skill_update",
      tiers: @coordinator,
      description:
        "Update a skill identified by `skill` (its id, or its name resolved within the " <>
          "`workspace` scope with a scoped skill shadowing the global). Any subset of " <>
          "`name` / `body` / `metadata` / `activation_mode` / `code_only` may be supplied; a " <>
          "skill's workspace scope is fixed at creation and cannot be changed here. The " <>
          "prior `body` is preserved as a paper-trail version (restorable), and the version " <>
          "records the calling actor. Returns the updated skill, plus a non-fatal `warning` " <>
          "when the (new) name collides with a bundled skill.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{
            "type" => "string",
            "description" => "Skill id or name to update. Required."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) that scopes a name lookup. Omit to target a global skill."
          },
          "name" => %{"type" => "string", "description" => "New kebab-case name (optional)."},
          "body" => %{"type" => "string", "description" => "New markdown body (optional)."},
          "metadata" => %{"type" => "object", "description" => "Replacement metadata (optional)."},
          "activation_mode" => %{
            "type" => "string",
            "enum" => ["situational", "always_on"],
            "description" =>
              "always_on auto-invokes /<name>; situational advertises only (optional)."
          },
          "code_only" => %{
            "type" => "boolean",
            "description" => "Restrict the skill to code-producing tickets (optional)."
          }
        },
        "required" => ["skill"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_update/2
    },
    %{
      name: "skill_delete",
      tiers: @coordinator,
      description:
        "Delete a skill identified by `skill` (its id, or its name resolved within the " <>
          "`workspace` scope with a scoped skill shadowing the global). A caller bound to a " <>
          "workspace cannot delete another workspace's scoped skill. " <>
          "Returns `{deleted: true, id, name}`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{
            "type" => "string",
            "description" => "Skill id or name to delete. Required."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) that scopes a name lookup. Omit to target a global skill."
          }
        },
        "required" => ["skill"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_delete/2
    },
    %{
      name: "skill_list",
      tiers: @both,
      description:
        "List skills (name, scope/workspace_id, metadata, activation_mode, code_only — no " <>
          "`body`), ordered by name. Scoped to what the caller may see: a worker sees its " <>
          "own workspace's effective set (globals overlaid by that workspace's scoped " <>
          "skills, scoped winning on a name clash); a coordinator sees every skill, or the " <>
          "effective set for a given `workspace`. Same registry as " <>
          "`skill_create`/materialization; use `skill_get` to fetch a body.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) to list the effective set for. Coordinator " <>
                "only; a worker is always scoped to its own workspace."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.skill_list/2
    },
    %{
      name: "skill_get",
      tiers: @both,
      description:
        "Fetch one skill's full markdown body by `skill` (its id, or its name resolved " <>
          "within the caller's workspace scope — a workspace-scoped skill shadows the " <>
          "global). A worker may only read a global skill or one scoped to its own " <>
          "workspace; a coordinator may read any, or scope a name lookup with `workspace`. " <>
          "Lets the coordinator (not worktree-isolated, so it can't rely on materialization) " <>
          "or any agent pull a skill body on demand from the same registry.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "skill" => %{
            "type" => "string",
            "description" => "Skill id or name to fetch. Required."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Optional workspace (id or name) that scopes a name lookup. Coordinator only."
          }
        },
        "required" => ["skill"],
        "additionalProperties" => false
      },
      handler: &Tools.skill_get/2
    },
    # ---- the Stage 2 loop-proposal queue (bd-9j2g3x) -----------------------
    #
    # Coordinator-only, every one of them. A fleet-wide skill patch or config
    # change is not a worker's call, and a worker bound to one task must never be
    # able to apply a write whose blast radius is the whole fleet.
    %{
      name: "loop_pending_list",
      tiers: @coordinator,
      description:
        "List queued loop-engineering proposals produced by `arb loop analyze --propose`. " <>
          "Optional `state` (one name or a list; defaults to the live states `hypothesis` + " <>
          "`proposed`), `kind`, `workspace`, `limit`. A `hypothesis` is a finding below the " <>
          "evidence bar kept with its incident refs so later windows reinforce it in place; " <>
          "crossing the bar promotes it to `proposed`. Returns summaries (no diffs) plus the " <>
          "workspace's `evidence_bar`; use `loop_pending_diff` to read one in full.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "state" => %{
            "oneOf" => [
              %{"type" => "string", "enum" => @loop_states},
              %{"type" => "array", "items" => %{"type" => "string", "enum" => @loop_states}}
            ],
            "description" =>
              "Optional state filter: one name or a list. Defaults to hypothesis + proposed."
          },
          "kind" => %{
            "type" => "string",
            "enum" => @loop_kinds,
            "description" => "Optional kind filter."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) to scope the list to."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Optional cap on rows returned, newest first."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_list/2
    },
    %{
      name: "loop_pending_diff",
      tiers: @coordinator,
      description:
        "Read one queued loop proposal in full by `id`: its unified `diff`, `payload`, " <>
          "pre-registered `target_metric` / `baseline`, accumulated `incident_refs` / " <>
          "`task_refs`, and — when it is not applicable yet — `inapplicable_reason` naming " <>
          "the current evidence and what is still missing. Read this before applying.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Proposal id. Required."},
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) the proposal must belong to."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_diff/2
    },
    %{
      name: "loop_pending_apply",
      tiers: @coordinator,
      description:
        "Apply the queued loop proposal `id`. Coordinator only — a worker must never apply a " <>
          "fleet-wide change. Dispatches on `kind` to the same public domain API a human " <>
          "would call (`Arbiter.Skills.update_skill/2`, the workspace config deep-merge, an " <>
          "ticket update), so the write lands with a normal paper-trail version attributed to " <>
          "the proposal id. Refuses anything that is not `proposed`; a `hypothesis` reply " <>
          "names its evidence count and the shortfall. Nothing is ever applied " <>
          "automatically — this tool is the only apply path.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Proposal id to apply. Required."},
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) the proposal must belong to."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_apply/2
    },
    %{
      name: "loop_pending_reject",
      tiers: @coordinator,
      description:
        "Soft-reject the queued loop proposal `id` with an optional `reason`. The row " <>
          "persists as `rejected` (never deleted), so later windows reinforce its evidence " <>
          "in place rather than re-proposing the same finding from scratch — but it does not " <>
          "re-open on its own.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Proposal id to reject. Required."},
          "reason" => %{
            "type" => "string",
            "description" => "Optional reason, recorded on the row."
          },
          "workspace" => %{
            "type" => "string",
            "description" => "Optional workspace (id or name) the proposal must belong to."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_pending_reject/2
    },

    # ---- earned trust (G18, guardrail-profiles §6.3–6.5) ----------------------
    #
    # Coordinator-only. The coordinator reads the records and decides on an
    # automatic suspension; it never promotes. There is deliberately no
    # `trust_promote`: no MCP tool, at any tier, can promote a subject, because a
    # promotion loosens its guardrails and needs operator proof
    # (`arb trust promote`). `loop_pending_apply` refuses a `trust_promotion`.
    %{
      name: "trust_show",
      tiers: @coordinator,
      description:
        "Earned trust (G18): every subject's (`provider/model`) tier, its 30-day record " <>
          "(runs, clean runs, critical/major/minor guardrail events, round-1 approve rate), " <>
          "promotion eligibility, last harness and model version, any automatic suspension " <>
          "and any pending `trust_promotion` proposal. With `subject`, that one subject in full: " <>
          "recent events and history too. A promotion is operator-only: no MCP tool can apply " <>
          "one; the operator runs `arb trust promote`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "subject" => %{
            "type" => "string",
            "description" =>
              "Optional `provider/model` (e.g. `antigravity/gemini-3.8-flash-low`) to show in full."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.trust_show/2
    },
    %{
      name: "trust_confirm",
      tiers: @coordinator,
      description:
        "Confirm an automatic suspension (a critical guardrail event suspended `subject`): " <>
          "the demotion to `quarantine` stands. The subject's rule drops to quarantine and the " <>
          "suspension ends, so it is eligible again for quarantine work only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "subject" => %{
            "type" => "string",
            "description" => "The suspended subject, `provider/model`. Required."
          }
        },
        "required" => ["subject"],
        "additionalProperties" => false
      },
      handler: &Tools.trust_confirm/2
    },
    %{
      name: "trust_dismiss",
      tiers: @coordinator,
      description:
        "Dismiss an automatic suspension of `subject` as a false positive (an authorised " <>
          "security probe is one), with a recorded `reason`: the suspension ends and the tier " <>
          "it never changed returns. Not a promotion: it cannot raise a tier.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "subject" => %{
            "type" => "string",
            "description" => "The suspended subject, `provider/model`. Required."
          },
          "reason" => %{
            "type" => "string",
            "description" => "Why it was a false positive. Required; recorded in the history."
          }
        },
        "required" => ["subject", "reason"],
        "additionalProperties" => false
      },
      handler: &Tools.trust_dismiss/2
    },
    %{
      name: "permission_request",
      tiers: @worker,
      description:
        "Ask for a permission this run does not have (a proxy `403`, a missing env var or key " <>
          "means \"not granted\"). It validates `permission` against the workspace bindings, " <>
          "records the request on your own ticket and tells whoever may grant it (the " <>
          "coordinator, or the operator when the binding says so). It grants nothing: the answer " <>
          "is \"recorded, not granted\" and your reach is unchanged. Carry on without it, or stop " <>
          "and report the affected acceptance criteria as unmet. A legitimate request is not a " <>
          "trust violation; a workaround attempt is.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "permission" => %{
            "type" => "string",
            "description" =>
              "What you need: `network:<host>[:<port>]`, `tracker_write`, `secrets:<name>`, " <>
                "`prod_read` or `prod_ssh`. Required."
          },
          "reason" => %{
            "type" => "string",
            "description" =>
              "What you need it for and what is blocked without it. Required; the grantor reads it."
          },
          "id" => %{
            "type" => "string",
            "description" => "Ticket id. Optional; only your own ticket is accepted."
          }
        },
        "required" => ["permission", "reason"],
        "additionalProperties" => false
      },
      handler: &Tools.permission_request/2
    },
    %{
      name: "ticket_permission_grant",
      tiers: @coordinator,
      description:
        "Answer a worker's `permission_request` (or grant a permission on your own): grant " <>
          "`permission` on ticket `id`, or `deny: true` with a `reason`. The binding's " <>
          "`grant_by` decides who may: an operator-only permission needs operator proof, which " <>
          "an MCP token does not carry, so it is refused here and answered with `arb ticket " <>
          "permit` from the operator's shell. A `network:` grant is live: the running worker's " <>
          "next connection to that host succeeds, no restart. An env, mount, tunnel or ssh " <>
          "grant reaches the worker at its next spawn (resume it). A denial is delivered to the " <>
          "worker's inbox with your `reason`. Both are recorded in `permission_events` with " <>
          "you as the actor.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "Ticket id (required)."},
          "permission" => %{
            "type" => "string",
            "description" =>
              "The permission to decide, as the request named it: `network:<host>[:<port>]`, " <>
                "`tracker_write`, `secrets:<name>`, `prod_read` or `prod_ssh`. Required."
          },
          "deny" => %{
            "type" => "boolean",
            "description" => "Deny instead of grant. Needs `reason`. Default false."
          },
          "reason" => %{
            "type" => "string",
            "description" =>
              "Required with `deny`: the worker reads it. Optional on a grant (recorded)."
          }
        },
        "required" => ["id", "permission"],
        "additionalProperties" => false
      },
      handler: &Tools.ticket_permission_grant/2
    },
    %{
      name: "memory_pending_list",
      tiers: @coordinator,
      description:
        "List memory candidates that browser-hosted sessions wrote for the shared memory layer " <>
          "(RFC §9.4 phase 13). `state: pending` (default) is the promotion queue; `state: rejected` " <>
          "is the audit trail of rejected candidates, with reason and time. Each entry's `id` " <>
          "(`<session-id>/<file>.md`) addresses it in memory_pending_diff/apply/reject.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "state" => %{"type" => "string", "enum" => ["pending", "rejected"]}
        },
        "additionalProperties" => false
      },
      handler: &Tools.memory_pending_list/2
    },
    %{
      name: "memory_pending_diff",
      tiers: @coordinator,
      description:
        "Read one memory candidate in full: its content, a line diff against the shared memory it " <>
          "would replace (null for a new one), and the citation verification promotion would run " <>
          "(file:line anchors, modules, ticket ids; URLs are never fetched), so a refusal is visible first.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Candidate id from memory_pending_list. Required."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.memory_pending_diff/2
    },
    %{
      name: "memory_pending_apply",
      tiers: @coordinator,
      description:
        "Promote a memory candidate into the shared layer every future session mounts. Coordinator/" <>
          "operator only: refused for session tokens. Verifies its citations against the workspace " <>
          "checkout's HEAD first and refuses a stale one; records source_session, author_model, " <>
          "promoted_by, promoted_at, verified_sha and anchors. Replacing an existing shared memory " <>
          "needs `overwrite: true` (the old copy is kept).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Candidate id from memory_pending_list. Required."
          },
          "overwrite" => %{
            "type" => "boolean",
            "description" => "Replace a shared memory of the same name. Default false."
          }
        },
        "required" => ["id"],
        "additionalProperties" => false
      },
      handler: &Tools.memory_pending_apply/2
    },
    %{
      name: "memory_pending_reject",
      tiers: @coordinator,
      description:
        "Reject a memory candidate. Coordinator/operator only: refused for session tokens. The " <>
          "candidate is marked with the reason, actor and time and kept for audit (never deleted); " <>
          "memory_pending_list with `state: rejected` shows it.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "Candidate id from memory_pending_list. Required."
          },
          "reason" => %{"type" => "string", "description" => "Why it was rejected. Required."}
        },
        "required" => ["id", "reason"],
        "additionalProperties" => false
      },
      handler: &Tools.memory_pending_reject/2
    },
    %{
      name: "memory_quarantine_list",
      tiers: @coordinator,
      description:
        "List shared memories the staleness checker quarantined because a cited file, line, " <>
          "module or ticket no longer resolves, with the reason, the SHA checked against and when. " <>
          "Quarantined memories are never mounted into sessions.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      },
      handler: &Tools.memory_quarantine_list/2
    },
    %{
      name: "memory_quarantine_restore",
      tiers: @coordinator,
      description:
        "Re-verify a quarantined memory against the current HEAD and, if nothing is stale, serve it " <>
          "again. Coordinator/operator only: refused for session tokens. Refuses while a citation is " <>
          "still stale; fix the memory's citations first, or pass `reanchor: true` to accept code that " <>
          "changed under a cited line and re-anchor every citation on the line it names now.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "File name from memory_quarantine_list. Required."
          },
          "reanchor" => %{
            "type" => "boolean",
            "description" => "Re-anchor citations on their current lines. Default false."
          }
        },
        "required" => ["name"],
        "additionalProperties" => false
      },
      handler: &Tools.memory_quarantine_restore/2
    },
    %{
      name: "memory_distill",
      tiers: @coordinator,
      description:
        "Distill memory candidates from an ended session's archived transcript (RFC phase 14): " <>
          "one bounded model pass that proposes candidates into the promotion queue " <>
          "(memory_pending_list) and never writes the shared layer. Each candidate cites its " <>
          "source transcript and turn range; ones that cannot be anchored or served are " <>
          "dropped with a reason. Coordinator/operator only: refused for session tokens. Metered " <>
          "on usage_events (step transcript_distillation) and capped per pass and per day by " <>
          "server config; the optional bounds here can only lower those caps.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "session_id" => %{
            "type" => "string",
            "description" => "The ended session whose transcript to distill. Required."
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" =>
              "Transcript bytes the model may read: the newest turns, or from from_turn on."
          },
          "from_turn" => %{
            "type" => "integer",
            "description" => "Start the window at this turn instead of at the newest turns."
          },
          "max_candidates" => %{
            "type" => "integer",
            "description" => "Most candidates this pass may queue."
          },
          "max_cost_usd" => %{
            "type" => "number",
            "description" => "Dollar cap for this pass."
          }
        },
        "required" => ["session_id"],
        "additionalProperties" => false
      },
      handler: &Tools.memory_distill/2
    },
    %{
      name: "loop_analyze",
      tiers: @coordinator,
      description:
        "Run the operator-invoked loop-analysis pass over a window (`arb loop analyze`) and " <>
          "return its markdown report plus a structured `summary` and the `usage_event_id` of " <>
          "its own cost row. Report-only: it queues and applies nothing (use `loop_propose` to " <>
          "queue what the report implies). Bounded: `limit` defaults to and is clamped at 500 runs.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "since" => %{
            "type" => "string",
            "description" =>
              "Window start: `7d` / `24h` / `30m` shortcut or ISO8601. Default: last 7 days."
          },
          "until" => %{
            "type" => "string",
            "description" => "Window end, ISO8601. Default now."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Cap on runs scanned, newest first. Default and maximum 500 (larger values are clamped)."
          },
          "label" => %{"type" => "string", "description" => "Only runs carrying this label."},
          "discover" => %{
            "type" => "boolean",
            "description" =>
              "Also run the opt-in discovery model pass (one bounded model call; queues nothing). Default false."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Workspace (id or name); omitted = every workspace (or the token's own)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.loop_analyze/2
    },
    %{
      name: "loop_propose",
      tiers: @coordinator,
      description:
        "The `loop_analyze` pass plus persistence of the proposals it implies " <>
          "(`arb loop analyze --propose`): each lands as a reviewable `hypothesis`/`proposed` " <>
          "row (returned under `proposals`; candidates the write path refused under " <>
          "`proposals_dropped`). Nothing is applied — decide with `loop_pending_apply` / " <>
          "`loop_pending_reject`. Same params and bounds as `loop_analyze`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "since" => %{
            "type" => "string",
            "description" =>
              "Window start: `7d` / `24h` / `30m` shortcut or ISO8601. Default: last 7 days."
          },
          "until" => %{
            "type" => "string",
            "description" => "Window end, ISO8601. Default now."
          },
          "limit" => %{
            "type" => "integer",
            "description" =>
              "Cap on runs scanned, newest first. Default and maximum 500 (larger values are clamped)."
          },
          "label" => %{"type" => "string", "description" => "Only runs carrying this label."},
          "discover" => %{
            "type" => "boolean",
            "description" =>
              "Also run the opt-in discovery model pass (one bounded model call; queues nothing). Default false."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Workspace (id or name); omitted = every workspace (or the token's own)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.loop_propose/2
    },
    %{
      name: "loop_propose_repo_doc_patch",
      tiers: @coordinator,
      description:
        "Hand-author a `repo_doc_patch` proposal (`arb loop propose repo-doc-patch`): a one-line " <>
          "`lesson` for `repo`'s CLAUDE.md, already `proposed`. A pure queue write — review it with " <>
          "`loop_pending_diff` and apply it with `loop_pending_apply`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "repo" => %{
            "type" => "string",
            "description" => "The repo (its `repo_paths` key in the workspace). Required."
          },
          "lesson" => %{
            "type" => "string",
            "description" =>
              "Single-line lesson text, no `arbiter:begin`/`arbiter:end` marker. Required."
          },
          "category" => %{"type" => "string", "description" => "Optional category label."},
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Workspace (id or name); the sole workspace when omitted, else required."
          }
        },
        "required" => ["repo", "lesson"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_propose_repo_doc_patch/2
    },
    %{
      name: "loop_propose_routing",
      tiers: @coordinator,
      description:
        "Hand-author a routing canary: creates an operator-authored `:config_set` proposal for " <>
          "`routing.rules.D<difficulty>` (`model_tier`, optional `thinking`), already `proposed`. " <>
          "With `loop.autonomous_routing_enabled` set on the workspace, the next canary tick " <>
          "starts a 50/50 canary for it. Set `loop.canary_auto_promote: false` to decide the " <>
          "outcome yourself via `loop_pending_apply` / `loop_pending_reject`. Monitor with " <>
          "`loop_canary_status`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "difficulty" => %{
            "type" => "integer",
            "description" => "Routing tier D0..D5. Required."
          },
          "model_tier" => %{
            "type" => "string",
            "description" => "Model tier to route that difficulty to, e.g. `standard`. Required."
          },
          "thinking" => %{"type" => "string", "description" => "Optional thinking level."},
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Workspace (id or name); the sole workspace when omitted, else required."
          }
        },
        "required" => ["difficulty", "model_tier"],
        "additionalProperties" => false
      },
      handler: &Tools.loop_propose_routing/2
    },
    %{
      name: "loop_canary_status",
      tiers: @coordinator,
      description:
        "Status of the workspace's running routing canary: proposal id, age, expiry, canary-arm " <>
          "dispatches still needed for a verdict, and both arms' current dispatches, tickets, " <>
          "reviewed tickets, first-pass convergence, review rounds, cost and cost per round. " <>
          "Returns `running: false` with a message when there is none.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Workspace (id or name); the sole workspace when omitted, else required."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.loop_canary_status/2
    },
    %{
      name: "usage_summarize",
      tiers: @coordinator,
      description:
        "Roll up the token/cost usage ledger for the workspace. `by` is required (day, task, " <>
          "epic, workspace, provider_account, repo, model, step, provider, source, session — " <>
          "`campaign` also accepted as a " <>
          "deprecated alias for `epic`); optional `since` (ISO-8601) and `limit`. " <>
          "`by=task` covers ticket-attributed spend only: quota probes, auth pre-flights and " <>
          "coordinator/terminal sessions have no ticket and are grouped under `by=source` instead.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "by" => %{"type" => "string", "description" => "Grouping dimension (required)."},
          "since" => %{
            "type" => "string",
            "description" => "ISO-8601 datetime lower bound (optional)."
          },
          "limit" => %{"type" => "integer", "description" => "Cap the returned rows (optional)."},
          "account" => %{
            "type" => "string",
            "description" =>
              "Narrow to one provider account (uuid, `provider:slug` or an unambiguous slug)."
          }
        },
        "required" => ["by"],
        "additionalProperties" => false
      },
      handler: &Tools.usage_summarize/2
    },
    %{
      name: "usage_events_list",
      tiers: @coordinator,
      description:
        "List raw usage-ledger rows, newest first (the drill-down behind `usage_summarize`). " <>
          "Optional filters: `account` (uuid, `provider:slug` or slug), `task_id` (also matches " <>
          "synthetic children `<id>#…`), `session_id`, `step` (work | review | impl …), " <>
          "`source` (task | probe | preflight | coordinator_session | terminal_session | " <>
          "maintenance), `since` (ISO-8601) and `limit` (default 50, max 1000). Omitting " <>
          "`workspace` covers all workspaces; the response echoes `workspace_id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "account" => %{"type" => "string", "description" => "Provider account ref."},
          "task_id" => %{"type" => "string", "description" => "Ticket id."},
          "session_id" => %{"type" => "string", "description" => "Session id."},
          "step" => %{"type" => "string", "description" => "Usage step."},
          "source" => %{"type" => "string", "description" => "Usage source."},
          "since" => %{
            "type" => "string",
            "description" => "ISO-8601 datetime lower bound (optional)."
          },
          "limit" => %{"type" => "integer", "description" => "Row cap (default 50, max 1000)."}
        },
        "additionalProperties" => false
      },
      handler: &Tools.usage_events_list/2
    },
    %{
      name: "usage_calibration",
      tiers: @coordinator,
      description:
        "The difficulty mis-rating report: closed tickets whose actual cost lands outside " <>
          "their own difficulty tier's p25–p75 but inside an adjacent tier's, with per-tier " <>
          "percentiles and under/over-rating rates. Optional `workspace` and `window_days`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "window_days" => %{
            "type" => "integer",
            "description" => "Look-back window in days (positive; default per report)."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.usage_calibration/2
    },

    # ---- board scheduler (autopilot) pause/resume --------------------------
    %{
      name: "scheduler_pause",
      tiers: @coordinator,
      description:
        "Pause the board scheduler (autopilot): stop promoting Ready cards to Running. " <>
          "Workers already dispatched continue to completion; no new dispatches occur " <>
          "while paused. Resume with `scheduler_resume`. Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.scheduler_pause/2
    },
    %{
      name: "scheduler_resume",
      tiers: @coordinator,
      description:
        "Resume the board scheduler (autopilot): start promoting Ready cards to Running again. " <>
          "Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.scheduler_resume/2
    },
    %{
      name: "scheduler_status",
      tiers: @coordinator,
      description:
        "Return the board scheduler's drain state: `state` is running, draining or " <>
          "quiescent; `safe_to_restart` is true only when paused AND nothing is in flight; " <>
          "`in_flight` lists every live piece of work — fix passes, conflict resolvers, " <>
          "review rounds and dispatches keep running while paused. Check it before a " <>
          "server restart. Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.scheduler_status/2
    },
    %{
      name: "server_status",
      tiers: @coordinator,
      description:
        "Return the server's version, git `sha`, `built_at`, `booted_at`, `release_repo`, " <>
          "the `update` block (latest release, `update_available`) and `migrations` " <>
          "(`status` ok/warning/unknown, `pending_count`). Read-only; use it after a restart " <>
          "to confirm the new build is live before verifying a ticket. Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.server_status/2
    },

    # ---- provider pause/resume (bd-5ef587) ---------------------------------
    %{
      name: "provider_pause",
      tiers: @coordinator,
      description:
        "Pause a provider (claude, codex, antigravity) or one provider account (id, " <>
          "`provider:slug` or slug): it is dropped from every routing decision — " <>
          "implementer, reviewer, failover, resume, fix and conflict passes — with reason " <>
          "`paused`, and held dispatches say `held — <provider> paused: <reason>`. Running " <>
          "workers keep running unless `stop_running` is true. Persisted. Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "ref" => %{
            "type" => "string",
            "description" => "Provider, account id, `provider:slug` or slug."
          },
          "reason" => %{
            "type" => "string",
            "description" => "Why — shown on the board and in holds."
          },
          "stop_running" => %{
            "type" => "boolean",
            "description" => "Also stop workers running on it."
          }
        },
        "required" => ["ref"],
        "additionalProperties" => false
      },
      handler: &Tools.provider_pause/2
    },
    %{
      name: "provider_resume",
      tiers: @coordinator,
      description: "Resume a paused provider or provider account. Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "ref" => %{
            "type" => "string",
            "description" => "Provider, account id, `provider:slug` or slug."
          }
        },
        "required" => ["ref"],
        "additionalProperties" => false
      },
      handler: &Tools.provider_resume/2
    },
    %{
      name: "provider_list",
      tiers: @coordinator,
      description:
        "List the active provider / account pauses (set by `provider_pause`): each entry " <>
          "carries `target`, `label`, `reason`, `by`, `actor` and `at`. Empty when nothing is " <>
          "paused. Coordinator only.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.provider_list/2
    },

    # ---- provider accounts, read side (P-17) ------------------------------
    %{
      name: "account_list",
      tiers: @coordinator,
      description:
        "List provider accounts (ordered by provider then slug): id, provider, slug, label, " <>
          "plan, enabled, max_concurrent, quota_config and identity fields. Merged-away and " <>
          "soft-deleted accounts are hidden unless `include_merged` / `include_deleted`. " <>
          "Carries no credential material. Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "provider" => %{
            "type" => "string",
            "enum" => ~w(claude codex antigravity grok),
            "description" => "Restrict to one provider."
          },
          "include_merged" => %{
            "type" => "boolean",
            "description" => "Include merged-away accounts."
          },
          "include_deleted" => %{
            "type" => "boolean",
            "description" => "Include soft-deleted accounts."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.account_list/2
    },
    %{
      name: "account_show",
      tiers: @coordinator,
      description:
        "Show one provider account with its credentials and attached workspaces. A credential " <>
          "is reported as `kind`, `env_var`, a 12-character `fingerprint` prefix, `active` and " <>
          "lifecycle timestamps — the secret itself is never returned. Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "ref" => %{
            "type" => "string",
            "description" => "Account uuid, `provider:slug` or an unambiguous bare slug."
          }
        },
        "required" => ["ref"],
        "additionalProperties" => false
      },
      handler: &Tools.account_show/2
    },

    # ---- provider accounts (bd-1kr3qf) --------------------------------------
    %{
      name: "account_set",
      tiers: @coordinator,
      description:
        "Edit one provider account's non-secret settings in a single write: `label`, " <>
          "`plan`, `enabled` (false parks it), `max_concurrent` (the account concurrency " <>
          "ceiling; null clears it) and a `quota_config` patch — the gate settings " <>
          "(thresholds, paced floors, weekly warning policy, window lengths, pace " <>
          "exemption) and the dollar spend cap (`spend_cap`, `spend_window` day|week|month, " <>
          "`spend_mode` flat|paced, `spend_metered`: fresh dispatches are held once metered " <>
          "spend reaches the cap; started tickets finish). A null `quota_config` value clears that key; keys not named are " <>
          "left alone, and a bad value rejects the whole edit. `ref` is an account id, " <>
          "`provider:slug` or a bare slug. Credentials, secrets, login, create, attach, " <>
          "merge and delete are operator actions and are not available here. " <>
          "Coordinator only.",
      input_schema: Arbiter.MCP.Catalog.AccountSchema.account_set(),
      handler: &Tools.account_set/2
    },

    # ---- system alerts (bd-7gt8rm) -------------------------------------------
    %{
      name: "alert_list",
      tiers: @coordinator,
      description:
        "List the active system alerts: problems with the installation that are not " <>
          "tied to a ticket — `credential_expired` (per adapter and detection source), " <>
          "`quota_poll_failing`, `quota_snapshot_stale` (per Claude account: quota " <>
          "accounting blind, the 5h gate failing open), `overage_alert` (per workspace " <>
          "and provider), `budget_exceeded` (per ticket) and `spend_cap` (per account: " <>
          "80% of its dollar spend cap, or the cap reached). Each carries `kind`, `key`, `subject`, " <>
          "`detail`, `owner` (always `operator`), `raised_at`, `last_raised_at`, " <>
          "`raise_count` and `cleared_at`. An alert clears by itself when its condition " <>
          "does, so the list is exactly what is still wrong. Optional `workspace`, " <>
          "`kind`. Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{"type" => "string", "description" => "Workspace id or name."},
          "kind" => %{
            "type" => "string",
            "enum" => Enum.map(Arbiter.Alerts.SystemAlert.kinds(), &Atom.to_string/1),
            "description" => "Restrict to one alert kind."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.alert_list/2
    },
    # ---- shared circuit breaker (bd-5jr49o) ---------------------------------
    %{
      name: "breaker_list",
      tiers: @coordinator,
      description:
        "List shared circuit-breaker state: which auto-filing / auto-escalating / " <>
          "auto-redispatching signatures have tripped, their trigger counts, bounds and " <>
          "windows — plus the static registry of every gated call site, which is present " <>
          "even on a freshly-restarted server, `auth_holds`: each provider whose " <>
          "dispatch is held after consecutive auth-failed workers, and " <>
          "`credential_watchdog`: every adapter CredentialWatchdog still marks expired " <>
          "(including one with no open auth hold at all, e.g. a periodic-probe expiry) " <>
          "— `gated?` says whether it's actually blocking dispatch right now. Optional " <>
          "`workspace`, `kind`, `open_only`. " <>
          "Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "workspace" => %{"type" => "string", "description" => "Workspace id or name."},
          "kind" => %{
            "type" => "string",
            "description" => "Restrict to one registered breaker kind (see `call_sites`)."
          },
          "open_only" => %{
            "type" => "boolean",
            "description" => "Only breakers that are currently tripped open."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.breaker_list/2
    },
    %{
      name: "breaker_reset",
      tiers: @coordinator,
      description:
        "Close a tripped circuit breaker so the suppressed action can run again. Pass " <>
          "`signature` (from `breaker_list` or the trip escalation) for one breaker, or " <>
          "`all: true` with an optional `workspace` / `kind` scope. Pass `provider` " <>
          "(`claude` / `codex` / `gemini`) instead to clear that provider's auth hold " <>
          "AND any CredentialWatchdog expiry mark for it, whether or not the hold " <>
          "itself was open — the one lever for a stuck `credential_watchdog` entry " <>
          "in `breaker_list` that never had a worker die on it (e.g. a periodic-probe " <>
          "expiry). Fix the underlying condition first: resetting a breaker whose cause " <>
          "is still live just restarts the flood. Coordinator only.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "signature" => %{
            "type" => "string",
            "description" => "The exact breaker signature to close."
          },
          "all" => %{
            "type" => "boolean",
            "description" => "Close every breaker matching `workspace` / `kind`."
          },
          "confirm_all" => %{
            "type" => "boolean",
            "description" =>
              "Required with `all: true` when neither `workspace` nor `kind` is given " <>
                "(an installation-wide reset)."
          },
          "workspace" => %{"type" => "string", "description" => "Workspace id or name."},
          "kind" => %{"type" => "string", "description" => "Restrict `all` to one kind."},
          "provider" => %{
            "type" => "string",
            "description" =>
              "Clear this provider's auth hold (`claude`, `codex`, `gemini`) — see " <>
                "`auth_holds` in `breaker_list`."
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.breaker_reset/2
    },
    %{
      name: "queue_retry_auto_resolve",
      tiers: @coordinator,
      description:
        "Re-arm one more auto-resolve attempt on a ticket's merge Watchdog after it has " <>
          "exhausted max_auto_resolve_attempts on a :ci_failed block and parked indefinitely " <>
          "(bd-bspakl), or spent its max_conflict_attempts conflict passes and escalated " <>
          "(bd-4olwyg). Bumps this episode's budget by exactly one attempt; the next " <>
          "watchdog poll (within its poll interval) dispatches a fresh fix-pass worker if " <>
          "the block is still ci_failed, or a fresh conflict-resolve pass if the PR is still " <>
          "conflicting. Use after an 'auto-resolve exhausted' or 'unresolved conflict' " <>
          "escalation in the coordinator inbox, when you've confirmed another pass is worth " <>
          "trying (e.g. after clearing whatever broke the last one).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" => "The parked ticket ID to re-arm (required)."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.queue_retry_auto_resolve/2
    },
    %{
      name: "queue_restart_watchdog",
      tiers: @coordinator,
      description:
        "Mint a FRESH merge Watchdog for a Merging ticket whose Watchdog has died, started " <>
          "from the ticket's row (bd-8jixav, bd-741sid). A Watchdog is a temporary process: " <>
          "when it crashes it is gone for good, silently, and the ticket sits in Merging with " <>
          "an open MR nobody is polling. Use this when a Merging ticket shows 'no watchdog " <>
          "running', or when queue_retry_auto_resolve answered 'no merge watchdog is " <>
          "currently running' on a ticket whose PR is genuinely still open. Refused if a " <>
          "watchdog is already running (two on one MR would race the merge). Much cheaper " <>
          "than worker_resume, which restarts the review gate from round 1. A ticket the " <>
          "operator pulled out of the merge queue goes back in it, so restart one only when " <>
          "the operator asks for that.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "The Merging ticket that needs a new watchdog (required). Its PR must be on " <>
                "its row."
          }
        },
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      handler: &Tools.queue_restart_watchdog/2
    },
    # ---- CI retry (bd-5mzzww / #1448) ---------------------------------------
    %{
      name: "ci_rerun",
      tiers: @both,
      description:
        "Re-run CI for a ticket's PR, choosing the GRANULARITY of the re-run (bd-5mzzww). " <>
          "Arbiter previously had no CI-retry verb at all — every retry was a human clicking " <>
          "the forge UI, and the button a human reaches for first ('re-run failed jobs') " <>
          "reuses every job that already succeeded. When the failing check tests an artifact " <>
          "an EARLIER job in the same run produced (a review app, a built image), that re-run " <>
          "re-tests the identical stale input and is deterministically guaranteed to fail " <>
          "again. Modes: `auto` (default — picks the cheapest re-run that could actually tell " <>
          "you something new: it escalates past failed_jobs whenever completed upstream jobs " <>
          "would be reused, or the run is already on attempt 2+), `failed_jobs`, `all_jobs` " <>
          "(re-runs the whole run, rebuilding upstream jobs), `workflow` (a fresh " <>
          "workflow_dispatch — the only mode that can carry `inputs` such as force_deploy). " <>
          "A worker may re-run its own ticket's CI; a coordinator must name `task_id`.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Ticket whose PR to re-run CI for. A worker may omit this (its own ticket) and may " <>
                "not name another; a coordinator must supply it."
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["auto", "failed_jobs", "all_jobs", "workflow"],
            "description" =>
              "Re-run granularity (default `auto`). Never pick `failed_jobs` for a second " <>
                "consecutive attempt — a repeat of an identical re-run is never informative."
          },
          "workflow" => %{
            "type" => "string",
            "description" =>
              "Workflow name or file basename (e.g. \"review-app.yml\"), when the head " <>
                "commit has more than one failed run."
          },
          "inputs" => %{
            "type" => "object",
            "description" =>
              ~s(workflow_dispatch inputs, e.g. {"force_deploy": "true"}. Supplying any ) <>
                "input forces `workflow` mode, since only a fresh dispatch can carry them. " <>
                "Combining inputs with mode `failed_jobs`/`all_jobs` is rejected.",
            "additionalProperties" => %{"type" => "string"}
          }
        },
        "additionalProperties" => false
      },
      handler: &Tools.ci_rerun/2
    },
    %{
      name: "ci_mark_external",
      tiers: @both,
      description:
        "Record a 'this CI failure is infrastructure, not my diff' verdict on a ticket parked " <>
          "on a :ci_failed block, reclassifying the park as :ci_failed_external (bd-5mzzww). " <>
          "Use when you have EVIDENCE the failure is repo-wide — e.g. the same check failing " <>
          "on unrelated branches today, and nothing in this diff touching the failing code. " <>
          "The coordinator escalation then reads 'CI is broken repo-wide, not on this branch' " <>
          "and carries your note, instead of a generic ci_failed park indistinguishable from " <>
          "genuinely broken code. The mark is scoped to the current block episode and clears " <>
          "as soon as the block reason changes, so a later real failure is never mislabelled.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Ticket parked on the :ci_failed block. A worker may omit this (its own ticket)."
          },
          "note" => %{
            "type" => "string",
            "description" =>
              "Required. The evidence for the verdict, in one or two sentences — an operator " <>
                "will read this before deciding to force-merge."
          }
        },
        "required" => ["note"],
        "additionalProperties" => false
      },
      handler: &Tools.ci_mark_external/2
    },
    %{
      name: "flake_record",
      tiers: @both,
      description:
        "Record a structured flake event (bd-6vullc): a fix_pass concluded a CI failure was " <>
          "a flake or infra issue — re-ran the job with no code change and it went green, or " <>
          "there's evidence it's broken repo-wide. This is what lets recurring flakes be " <>
          "counted across fix_passes and surfaced in `arb loop analyze`, instead of living " <>
          "only in one run's closing prose. Call it INSTEAD of (or alongside) `ci_rerun` / " <>
          "`ci_mark_external` whenever you conclude the failure wasn't your diff — name the " <>
          "failing test's file:line when you can identify one, and always give a short " <>
          "`signature` (a distinctive fragment of the failure, e.g. a log line or error " <>
          "message) so occurrences without a test location still group together.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{
            "type" => "string",
            "description" =>
              "Ticket the fix_pass is running for. A worker may omit this (its own ticket)."
          },
          "ci_job" => %{
            "type" => "string",
            "description" => "Required. The failing CI job/check name."
          },
          "signature" => %{
            "type" => "string",
            "description" =>
              "Required. A short, distinctive fragment of the failure (a log line, error " <>
                "message, or teardown name) — the grouping key when no test file:line is known."
          },
          "test_file" => %{
            "type" => "string",
            "description" =>
              "The failing test's file, when identifiable, e.g. \"test/coverage_test.exs\"."
          },
          "test_line" => %{
            "type" => "integer",
            "description" => "The failing test's line, when identifiable."
          },
          "note" => %{
            "type" => "string",
            "description" => "Optional evidence for the flake/infra conclusion."
          },
          "repo" => %{
            "type" => "string",
            "description" => "Defaults to the calling ticket's repo when omitted."
          }
        },
        "required" => ["ci_job", "signature"],
        "additionalProperties" => false
      },
      handler: &Tools.flake_record/2
    },
    %{
      name: "repo_list",
      tiers: @coordinator,
      description:
        "List registered repos with their paths, sources, active worker counts, and git worktree counts. " <>
          "Repos are discovered from workspace repo_paths configs, the application-env fallback, " <>
          "and any repos active workers are using. Mirrors `arb repo list`.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.repo_list/2
    },
    %{
      name: "repo_show",
      tiers: @coordinator,
      description:
        "Show details for a single repo: path, source, active worker count, and git worktree count. " <>
          "Returns not-found if the repo name does not exist.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Repo name (required)."
          }
        },
        "required" => ["name"],
        "additionalProperties" => false
      },
      handler: &Tools.repo_show/2
    }
  ]

  # Inject the optional `workspace` field into every tool that calls resolve_workspace_id,
  # so callers can target a workspace explicitly without each tool restating the property by hand.
  @tools Enum.map(@raw_tools, fn tool ->
           tool =
             if tool.name in @workspace_tools do
               update_in(tool, [:input_schema, "properties"], fn props ->
                 Map.put(props, "workspace", @workspace_field)
               end)
             else
               tool
             end

           if tool.name in @summary_tools do
             update_in(tool, [:input_schema, "properties"], fn props ->
               Map.put(props, "summary", @summary_field)
             end)
           else
             tool
           end
         end)

  # bd-4jojpw: the tools were renamed `task_*` → `ticket_*`. Each old name stays
  # callable for one release: `call/3` resolves it to its `ticket_*` tool, so the
  # result is the same by construction, and `visible/1` lists it (marked
  # deprecated) so a client that filters its menu by name — a Gemini
  # `includeTools` written before the rename, a running session's cached tool
  # list — keeps finding it. Removing this table is the follow-up cleanup.
  @legacy_aliases %{
    "task_show" => "ticket_show",
    "task_ready" => "ticket_ready",
    "task_update_progress" => "ticket_update_progress",
    "task_create" => "ticket_create",
    "task_update" => "ticket_update",
    "task_close" => "ticket_close",
    "task_reopen" => "ticket_reopen",
    "task_verify" => "ticket_verify",
    "task_promote" => "ticket_promote",
    "task_demote" => "ticket_demote",
    "task_rank" => "ticket_rank",
    "task_sync_upstream_close" => "ticket_sync_upstream_close",
    "task_list" => "ticket_list"
  }

  @alias_tools @legacy_aliases
               |> Enum.sort()
               |> Enum.map(fn {old, new} ->
                 target = Enum.find(@tools, &(&1.name == new))

                 %{
                   target
                   | name: old,
                     description:
                       "Deprecated alias of `#{new}` — call `#{new}` instead. Same " <>
                         "arguments, same result; this `task_*` name is kept for one " <>
                         "release and then removed."
                 }
               end)

  @doc "All tool definitions, regardless of tier. Canonical names only — no deprecated aliases."
  @spec all() :: [tool()]
  def all, do: @tools

  # `worker_dispatch.provider` enumerates the registered agent types, which are
  # only known at runtime (extensions), so `fetch/1` and `visible/1` fill it in;
  # `all/0` stays static because `Arbiter.Extensions` boots through it.
  defp live_schema(%{name: "worker_dispatch"} = tool) do
    update_in(tool, [:input_schema, "properties", "provider"], fn prop ->
      Map.put(prop, "enum", Arbiter.Agents.valid_agent_types())
    end)
  end

  defp live_schema(tool), do: tool

  @doc """
  The deprecated `task_*` tool names, each mapped to the `ticket_*` tool it now
  calls (bd-4jojpw). Kept for one release.
  """
  @spec legacy_aliases() :: %{String.t() => String.t()}
  def legacy_aliases, do: @legacy_aliases

  @doc "The canonical tool name for `name`: its `ticket_*` target if it is a deprecated alias."
  @spec canonical_name(String.t()) :: String.t()
  def canonical_name(name) when is_binary(name), do: Map.get(@legacy_aliases, name, name)

  @doc """
  The tool definitions visible to `scope`.

  For `:worker` / `:coordinator` that is the tools whose `:tiers` include the
  scope's tier. For `:refine` it is `Arbiter.MCP.RefinePolicy`'s allow list —
  a separate, exhaustive table rather than a `:tiers` entry, so that a new tool
  cannot join (or miss) a refine session's authority by omission. See that
  module for why.
  """
  @spec visible(Scope.t()) :: [tool()]
  def visible(%Scope{} = scope),
    do:
      Enum.filter(@tools ++ @alias_tools ++ Arbiter.Extensions.mcp_tools(), &visible?(scope, &1))
      |> Enum.map(&live_schema/1)

  # A deprecated alias is visible exactly where its `ticket_*` target is: it
  # carries the target's `:tiers`, and the refine table is keyed by the target.
  defp visible?(%Scope{tier: :refine}, tool), do: RefinePolicy.allow?(canonical_name(tool.name))
  defp visible?(%Scope{tier: tier}, tool), do: tier in tool.tiers

  @doc """
  Look up a tool definition by name. A deprecated `task_*` alias resolves to
  its `ticket_*` tool.
  """
  @spec fetch(String.t()) :: {:ok, tool()} | :error
  def fetch(name) when is_binary(name) do
    canonical = canonical_name(name)

    case Enum.find(@tools, &(&1.name == canonical)) ||
           Enum.find(Arbiter.Extensions.mcp_tools(), &(&1.name == canonical)) do
      nil -> :error
      tool -> {:ok, live_schema(tool)}
    end
  end

  @doc """
  Authorize and execute a `tools/call`. Returns a normalized result the transport
  renders:

    * `{:ok, data}` — success (→ a tool result with `structuredContent`);
    * `{:rpc_error, code, message}` — unknown tool, or a scope/tier violation
      (→ a JSON-RPC error object, never a transport error);
    * `{:tool_error, message, type}` — an operational failure such as not-found or
      bad arguments (→ a tool result with `isError: true`). `type` is the
      `Arbiter.Errors` type of the handler's error kind (`not_found`,
      `validation_error`, `conflict`, `busy`, `internal_error`, ...) — the same
      vocabulary REST's `{error: {type}}` uses, so a client can branch on it.
  """
  @spec call(Scope.t(), String.t(), map()) :: call_result()
  def call(%Scope{} = scope, name, arguments) when is_binary(name) do
    args = if is_map(arguments), do: arguments, else: %{}

    case fetch(name) do
      :error ->
        {:rpc_error, @code_invalid_params, "Unknown tool: #{name}"}

      {:ok, tool} ->
        audit_self_grant(scope, tool, args)

        case permitted(scope, tool) do
          :ok -> run(tool, scope, args)
          {:error, message} -> {:rpc_error, @code_not_permitted, message}
        end
    end
  end

  # G17 (design §6.1): a worker reaching for `permissions` or `guardrails.*`
  # writes, or a permission grant, is a critical guardrail event, whether or
  # not the tier gate below refuses it.
  defp audit_self_grant(%Scope{tier: :worker} = scope, tool, args) do
    if SelfGrant.mcp?(tool.name, args),
      do: Events.record_self_grant(scope, "mcp #{tool.name}", tool: tool.name)

    :ok
  end

  defp audit_self_grant(_scope, _tool, _args), do: :ok

  # The tier gate. A refine scope is answered from the exhaustive
  # `RefinePolicy` table — including its `:undecided` case, which denies: a tool
  # nobody has ruled on is not a tool a browser session gets to call. Every other
  # tier keeps reading the tool's own `:tiers`.
  defp permitted(%Scope{tier: :refine}, tool) do
    if RefinePolicy.allow?(tool.name),
      do: :ok,
      else: {:error, RefinePolicy.denial_message(tool.name)}
  end

  defp permitted(%Scope{tier: tier}, tool) do
    if tier in tool.tiers,
      do: :ok,
      else: {:error, "Tool #{tool.name} is not permitted for a #{tier} scope"}
  end

  # bd-6i7yzq: the MCP edge. Every write the handler makes (ticket transitions,
  # config, skills, ...) is attributed to the token's actor — attribution only,
  # `permitted/2` above is still the whole gate.
  defp run(tool, scope, args) do
    case Arbiter.Actor.with_actor(Arbiter.Actor.from_scope(scope), fn ->
           tool.handler.(scope, args)
         end) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:error, {:unauthorized, msg}} ->
        {:rpc_error, @code_not_permitted, msg}

      {:error, {kind, msg}} when is_atom(kind) and is_binary(msg) ->
        {:tool_error, msg, Arbiter.Errors.type(kind)}

      {:error, {kind, msg, _details}} when is_atom(kind) and is_binary(msg) ->
        {:tool_error, msg, Arbiter.Errors.type(kind)}
    end
  rescue
    e ->
      {:tool_error, "tool #{tool.name} failed: #{Exception.message(e)}",
       Arbiter.Errors.type(:internal)}
  end
end
