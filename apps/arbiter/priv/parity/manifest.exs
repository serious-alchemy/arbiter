# Parity manifest: every operation Arbiter exposes, mapped to the surfaces that reach it.
#
# Plain terms, read by `Arbiter.Parity.Manifest.load!/0`. Three guard tests (one per
# app, so each sees its own enumeration) fail when an MCP tool, `/api` route or `arb`
# verb has no row here; a fourth validates this file itself. Seeded from §6 of the
# parity audit (bd-ws8nmk); the failure messages say how to add a row.
#
# Row fields
#
#   id           unique "<domain>/<slug>"
#   title        the operation, one line
#   mcp          MCP tool names (canonical and deprecated `task_*` aliases) or nil
#   cli          `arb <verb> [<subverb>]` spellings (legacy flat verbs included) or nil
#   rest         "METHOD /path" in router pattern form (`/api/issues/:id`) or nil
#   status       :full      every surface that exists behaves the same (nils are intentional)
#                :partial   the surfaces exist but diverge (see `divergences` / `note`)
#                :excluded  single-surface by design, no parity target
#                {:gap, "P-xx"}  at least one surface SHOULD have it and does not;
#                           "P-xx" is the open child in `children` that adds it
#   absent       one ruling per nil surface (`:mcp` / `:cli` / `:rest`):
#                  {:intentional, "why it is absent"}
#                  {:gap, "P-xx", "what is missing"}
#   divergences  audit ids (D-T-2, ...) for the differences behind :partial
#   note         optional one-liner
#
# When a child ticket lands, its PR deletes its own `{:gap, "P-xx", _}` entries (the
# nil becomes a real value) and its line in `children`; the manifest test fails on a
# `children` entry no row cites and on a gap citing an id that is not listed.

%{
  children: %{
    "P-10" => "Review automation guard + task-review parity + tier alignment of CI/child-filing tools",
    "P-11" => "Worker read-side parity (show, list, runs, log, prompt, run_log_list)",
    "P-12" => "External-PR review surface: revive `arb review`, REST show/greenlight, field parity",
    "P-13" => "Ticket read-side parity and one \"Ready\" implementation",
    "P-14" => "Ticket create/update service: one `Tasks.Create` + issue-write allow-list",
    "P-15" => "Missing ticket operations: tracker discovery, tracker-only create, upstream close, rank pin",
    "P-16" => "Account field registry: edit parity across PATCH, `arb account`, UI and MCP",
    "P-17" => "MCP/CLI read gaps for accounts, usage, pauses, alerts",
    "P-21" => "Workspace operations parity: update, schema, multi-key patch, worker_env, standing orders",
    "P-23" => "Loop parity",
    "P-24" => "Shared repo listing",
    "P-25" => "Memory operator surface (REST + CLI)",
    "P-26" => "Mailbox: one context function, correct workspace and reader identity",
    "P-27" => "Coordinator attention queue on REST/CLI and read-only `server_status` on MCP"
  },
  operations: [
    # ---- tickets ----
    %{
      id: "tickets/list_tickets",
      title: "List tickets",
      mcp: ["ticket_list", "task_list"],
      cli: ["arb ticket list", "arb list"],
      rest: ["GET /api/issues"],
      status: :partial,
      divergences: ["D-T-2", "D-T-3", "D-T-17"]
    },
    %{
      id: "tickets/show_one_ticket",
      title: "Show one ticket",
      mcp: ["ticket_show", "task_show"],
      cli: ["arb ticket show", "arb show"],
      rest: ["GET /api/issues/:id"],
      status: :partial,
      divergences: ["D-T-15"]
    },
    %{
      id: "tickets/list_ready_tickets",
      title: "List Ready tickets",
      mcp: ["ticket_ready", "task_ready"],
      cli: ["arb ticket ready", "arb ready"],
      rest: ["GET /api/issues/ready"],
      status: :partial,
      divergences: ["D-T-2", "D-T-16", "D-T-23"]
    },
    %{
      id: "tickets/open_tickets_with_lifecycle_projection_hold_reas",
      title: "Open tickets with lifecycle projection + hold reason (board feed)",
      mcp: nil,
      cli: ["arb prime"],
      rest: ["GET /api/issues/lifecycle"],
      status: {:gap, "P-13"},
      absent: %{
        mcp: {:gap, "P-13", "add hold_reason (REST-I:97-111 ready_holds) to ticket_ready/ticket_list; coordinators cannot see why a Ready card is not dispatched."}
      }
    },
    %{
      id: "tickets/create_ticket_local_task_mirrors_upstream_tracke",
      title: "Create ticket (local task, mirrors upstream tracker)",
      mcp: ["ticket_create", "task_create"],
      cli: ["arb ticket create", "arb create"],
      rest: ["POST /api/issues"],
      status: :partial,
      divergences: ["D-T-4", "D-T-9", "D-T-10", "D-T-21"]
    },
    %{
      id: "tickets/create_tracker_only_unclaimed_ticket_no_local_ta",
      title: "Create tracker-only (unclaimed) ticket, no local task",
      mcp: nil,
      cli: ["arb ticket create"],
      rest: ["POST /api/workspaces/:workspace_id/tracker/tickets"],
      status: {:gap, "P-15"},
      absent: %{
        mcp: {:gap, "P-15", "coordinator posting unclaimed work for the fleet (REST+CLI both have it; tracker_* tools already cover claim/sync)."}
      }
    },
    %{
      id: "tickets/list_open_tracker_issues_unclaimed",
      title: "List open tracker issues (unclaimed)",
      mcp: nil,
      cli: ["arb ticket list"],
      rest: ["GET /api/workspaces/:workspace_id/tracker/issues"],
      status: {:gap, "P-15"},
      absent: %{
        mcp: {:gap, "P-15", "tracker_claim needs a ref and the coordinator has no way to discover refs."}
      }
    },
    %{
      id: "tickets/update_ticket_fields",
      title: "Update ticket fields",
      mcp: ["ticket_update", "task_update"],
      cli: ["arb ticket update", "arb update"],
      rest: ["PATCH /api/issues/:id", "PUT /api/issues/:id"],
      status: :partial,
      divergences: ["D-T-5", "D-T-6", "D-T-11", "D-T-18", "D-T-19"]
    },
    %{
      id: "tickets/worker_progress_write_notes_qa_deployment_pr_bod",
      title: "Worker progress write (notes/qa/deployment/pr_body/verify_after_deploy on own ticket)",
      mcp: ["ticket_update_progress", "task_update_progress"],
      cli: nil,
      rest: ["PATCH /api/issues/:id"],
      status: :partial,
      divergences: ["D-T-29"],
      absent: %{
        cli: {:intentional, "ticket update serves."}
      }
    },
    %{
      id: "tickets/close_ticket",
      title: "Close ticket",
      mcp: ["ticket_close", "task_close"],
      cli: ["arb ticket close", "arb close"],
      rest: ["POST /api/issues/:id/close"],
      status: :partial,
      divergences: ["D-T-12", "D-T-30"]
    },
    %{
      id: "tickets/reopen_ticket",
      title: "Reopen ticket",
      mcp: ["ticket_reopen", "task_reopen"],
      cli: ["arb ticket reopen", "arb reopen"],
      rest: ["POST /api/issues/:id/reopen"],
      status: :full,
      divergences: ["D-T-14"]
    },
    %{
      id: "tickets/promote_backlog_queued",
      title: "Promote Backlog -> Queued",
      mcp: ["ticket_promote", "task_promote"],
      cli: ["arb ticket promote"],
      rest: ["POST /api/issues/:id/promote"],
      status: :full,
      divergences: ["D-T-27"]
    },
    %{
      id: "tickets/demote_to_backlog",
      title: "Demote to Backlog",
      mcp: ["ticket_demote", "task_demote"],
      cli: ["arb ticket demote"],
      rest: ["POST /api/issues/:id/demote"],
      status: :full
    },
    %{
      id: "tickets/re_rank_within_priority_band",
      title: "Re-rank within priority band",
      mcp: ["ticket_rank", "task_rank"],
      cli: ["arb ticket rank"],
      rest: ["PATCH /api/issues/:id/rank"],
      status: :full
    },
    %{
      id: "tickets/pin_unpin_a_card_s_rank",
      title: "Pin/unpin a card's rank (rank_pinned)",
      mcp: nil,
      cli: nil,
      rest: nil,
      status: {:gap, "P-15"},
      absent: %{
        mcp: {:gap, "P-15", "low) - a board drag pins, CLI/MCP/REST rank \"leave the pin as it was\" (A/tasks/issue.ex:519-521) so a pinned card can only be unpinned in the browser."},
        cli: {:gap, "P-15", "low) - a board drag pins, CLI/MCP/REST rank \"leave the pin as it was\" (A/tasks/issue.ex:519-521) so a pinned card can only be unpinned in the browser."},
        rest: {:gap, "P-15", "low) - a board drag pins, CLI/MCP/REST rank \"leave the pin as it was\" (A/tasks/issue.ex:519-521) so a pinned card can only be unpinned in the browser."}
      }
    },
    %{
      id: "tickets/set_clear_epic_priority_floor",
      title: "Set/clear epic priority floor",
      mcp: ["epic_floor"],
      cli: ["arb epic floor"],
      rest: ["PATCH /api/issues/:id/floor"],
      status: :full
    },
    %{
      id: "tickets/record_verify_outcome_observed_failed",
      title: "Record verify outcome (observed/failed)",
      mcp: ["ticket_verify", "task_verify"],
      cli: ["arb ticket verify", "arb verify"],
      rest: ["POST /api/issues/:id/verify"],
      status: :full
    },
    %{
      id: "tickets/record_gate_escalation_resolution",
      title: "Record gate-escalation resolution",
      mcp: ["review_gate_resolve"],
      cli: ["arb ticket resolve", "arb review resolve"],
      rest: ["POST /api/issues/:id/resolve"],
      status: :partial,
      divergences: ["D-T-26"]
    },
    %{
      id: "tickets/hand_attention_to_operator",
      title: "Hand attention to operator",
      mcp: ["ticket_handoff"],
      cli: ["arb ticket handoff"],
      rest: ["POST /api/issues/:id/handoff"],
      status: :partial,
      divergences: ["D-T-13", "D-T-28"]
    },
    %{
      id: "tickets/hand_attention_back_to_coordinator",
      title: "Hand attention back to coordinator",
      mcp: ["ticket_handback"],
      cli: ["arb ticket handback"],
      rest: ["POST /api/issues/:id/handback"],
      status: :partial,
      note: "Same as 19."
    },
    %{
      id: "tickets/push_close_upstream_for_an_already_closed_ticket",
      title: "Push close upstream for an already-closed ticket",
      mcp: ["ticket_sync_upstream_close", "task_sync_upstream_close"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-15"},
      absent: %{
        cli: {:gap, "P-15", "arb sync reports drift entries whose remedy is exactly this action (A/tasks/claim.ex:122,542) but only MCP can run it."},
        rest: {:gap, "P-15", "arb sync reports drift entries whose remedy is exactly this action (A/tasks/claim.ex:122,542) but only MCP can run it."}
      }
    },
    %{
      id: "tickets/add_dependency_edge",
      title: "Add dependency edge",
      mcp: ["dep_add"],
      cli: ["arb dep add"],
      rest: ["POST /api/dependencies"],
      status: :partial,
      divergences: ["D-T-21"]
    },
    %{
      id: "tickets/remove_dependency_edge",
      title: "Remove dependency edge",
      mcp: ["dep_remove"],
      cli: ["arb dep rm", "arb dep remove"],
      rest: ["DELETE /api/dependencies/:from/:to"],
      status: :partial,
      divergences: ["D-T-20"]
    },
    %{
      id: "tickets/list_dependency_edges_workspace",
      title: "List dependency edges (workspace)",
      mcp: ["dep_list"],
      cli: ["arb dep list"],
      rest: ["GET /api/dependencies"],
      status: :partial,
      divergences: ["D-T-2", "D-T-32"]
    },
    %{
      id: "tickets/list_edges_of_one_ticket",
      title: "List edges of one ticket",
      mcp: ["dep_list"],
      cli: ["arb dep list"],
      rest: ["GET /api/dependencies/:issue_id"],
      status: :full
    },
    %{
      id: "tickets/claim_tracker_issue_into_a_task",
      title: "Claim tracker issue into a task",
      mcp: ["tracker_claim"],
      cli: ["arb ticket claim", "arb claim"],
      rest: ["POST /api/workspaces/:workspace_id/claim"],
      status: :partial,
      divergences: ["D-T-2", "D-T-24"]
    },
    %{
      id: "tickets/reconcile_tracker_tasks_apply",
      title: "Reconcile tracker<->tasks (apply)",
      mcp: ["tracker_sync"],
      cli: ["arb ticket sync", "arb sync"],
      rest: ["POST /api/workspaces/:workspace_id/sync"],
      status: :partial,
      divergences: ["D-T-23", "D-T-24"]
    },
    %{
      id: "tickets/reconcile_plan_dry_run",
      title: "Reconcile plan (dry run)",
      mcp: ["tracker_sync"],
      cli: ["arb ticket sync"],
      rest: ["GET /api/workspaces/:workspace_id/sync/plan"],
      status: :partial,
      note: "As 27; MCP returns {applied:false, actions} vs REST {data}."
    },
    %{
      id: "tickets/dispatch_a_ticket_s_worker_ticket_side_entry_onl",
      title: "Dispatch a ticket's worker (ticket-side entry only; owned by WORKERS analyst)",
      mcp: ["worker_dispatch"],
      cli: ["arb ticket dispatch", "arb dispatch"],
      rest: ["POST /api/workers/dispatch"],
      status: :full
    },
    %{
      id: "tickets/clear_review_circuit_breaker_via_ticket_update",
      title: "Clear review circuit-breaker via ticket update",
      mcp: ["ticket_resume_review"],
      cli: ["arb ticket update"],
      rest: ["PATCH /api/issues/:id", "POST /api/issues/:id/resume_review"],
      status: :partial,
      divergences: ["D-T-5"],
      note: "MCP `ticket_resume_review` and REST `POST /api/issues/:id/resume_review` are the typed path; REST/CLI also still write the raw circuit_breaker fields via PATCH (D-T-5), which P-14 removes."
    },
    %{
      id: "tickets/set_per_ticket_override",
      title: "Set per-ticket skills override",
      mcp: nil,
      cli: nil,
      rest: ["POST /api/issues", "PATCH /api/issues/:id"],
      status: {:gap, "P-14"},
      absent: %{
        mcp: {:gap, "P-14", "low) or REST should stop accepting it; today only REST can set it (A2)."},
        cli: {:gap, "P-14", "low) or REST should stop accepting it; today only REST can set it (A2)."}
      }
    },
    %{
      id: "tickets/deprecated",
      title: "Deprecated: arb issue <verb>",
      mcp: nil,
      cli: ["arb issue"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "CLI-only rename shim (bd-4jojpw), stderr note."},
        rest: {:intentional, "CLI-only rename shim (bd-4jojpw), stderr note."}
      }
    },
    %{
      id: "tickets/deprecated_flat_verbs",
      title: "Deprecated: flat verbs arb list/show/create/close/reopen/claim/sync/ready",
      mcp: nil,
      cli: ["arb list", "arb show", "arb create", "arb close", "arb reopen", "arb claim", "arb sync", "arb ready"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "CLI grammar shim. rank promote demote handoff handback resolve verify-less have no flat form (verify/dispatch are first-class, main.ex:335,337)."},
        rest: {:intentional, "CLI grammar shim. rank promote demote handoff handback resolve verify-less have no flat form (verify/dispatch are first-class, main.ex:335,337)."}
      }
    },
    %{
      id: "tickets/deprecated_dual_mode",
      title: "Deprecated: arb update <id> dual mode",
      mcp: nil,
      cli: ["arb update"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."},
        rest: {:intentional, "."}
      }
    },
    %{
      id: "tickets/deprecated_mcp_aliases_13_show_ready_update_prog",
      title: "Deprecated MCP task_* aliases (13: show ready update_progress create update close reopen verify promote demote rank sync_upstream_close list)",
      mcp: ["task_show", "task_ready", "task_update_progress", "task_create", "task_update", "task_close", "task_reopen", "task_verify", "task_promote", "task_demote", "task_rank", "task_sync_upstream_close", "task_list"],
      cli: nil,
      rest: nil,
      status: :excluded,
      absent: %{
        cli: {:intentional, "same-handler aliases, \"one release\", no removal date."},
        rest: {:intentional, "same-handler aliases, \"one release\", no removal date."}
      }
    },
    # ---- workers ----
    %{
      id: "workers/dispatch_a_worker_on_a_ticket",
      title: "Dispatch a worker on a ticket",
      mcp: ["worker_dispatch"],
      cli: ["arb ticket dispatch", "arb dispatch"],
      rest: ["POST /api/workers/dispatch"],
      status: :partial,
      divergences: ["D-W-5", "D-W-7", "D-W-8", "D-W-9", "D-W-10", "D-W-11"]
    },
    %{
      id: "workers/resume_a_stopped_worker",
      title: "Resume a stopped worker",
      mcp: ["worker_resume"],
      cli: ["arb worker resume", "arb resume"],
      rest: ["POST /api/workers/:task_id/resume"],
      status: :partial,
      divergences: ["D-W-1", "D-W-8", "D-W-11"]
    },
    %{
      id: "workers/review_only_worker_for_a_task_s_pr",
      title: "Review-only worker for a task's PR",
      mcp: ["worker_review"],
      cli: ["arb worker review", "arb review"],
      rest: ["POST /api/workers/review"],
      status: :partial,
      divergences: ["D-W-2", "D-W-24"]
    },
    %{
      id: "workers/review_an_external_non_arbiter_pr",
      title: "Review an external (non-arbiter) PR",
      mcp: ["worker_review"],
      cli: nil,
      rest: ["POST /api/workers/review"],
      status: {:gap, "P-12"},
      divergences: ["D-W-6"],
      absent: %{
        cli: {:gap, "P-12", "CLI - REST route exists and ops need it; wire arb review --pr (revive CR as arb review, add to @known_verbs)."}
      }
    },
    %{
      id: "workers/stop_a_worker",
      title: "Stop a worker",
      mcp: ["worker_stop"],
      cli: ["arb worker stop"],
      rest: ["POST /api/workers/:task_id/stop"],
      status: :full,
      divergences: ["D-W-4", "D-W-25"]
    },
    %{
      id: "workers/list_live_workers_current_run_per_ticket",
      title: "List live workers (current run per ticket)",
      mcp: ["worker_list"],
      cli: ["arb worker list"],
      rest: ["GET /api/workers"],
      status: :partial,
      divergences: ["D-W-3", "D-W-14", "D-W-23"]
    },
    %{
      id: "workers/show_one_worker_current_run_recent_runs_output_t",
      title: "Show one worker (current run + recent runs + output tail)",
      mcp: ["worker_show"],
      cli: ["arb worker show"],
      rest: ["GET /api/workers/:task_id"],
      status: :partial,
      divergences: ["D-W-13"]
    },
    %{
      id: "workers/run_history_for_a_task_and_fleet_wide_run_query",
      title: "Run history for a task (and fleet-wide run query)",
      mcp: ["worker_runs"],
      cli: ["arb worker runs"],
      rest: ["GET /api/workers/history"],
      status: :partial,
      divergences: ["D-W-15"]
    },
    %{
      id: "workers/get_one_run_by_id_metadata_output_tail",
      title: "Get one run by id (metadata + output tail)",
      mcp: nil,
      cli: nil,
      rest: ["GET /api/workers/history/:id"],
      status: {:gap, "P-11"},
      absent: %{
        mcp: {:gap, "P-11", "MCP - run metadata by id (extend worker_runs with run_id);"},
        cli: {:gap, "P-11", "CLI - arb worker runs --run <id>."}
      }
    },
    %{
      id: "workers/full_durable_transcript_of_a_run",
      title: "Full durable transcript of a run",
      mcp: ["worker_log"],
      cli: ["arb worker log"],
      rest: ["GET /api/workers/:task_id/log"],
      status: :partial,
      divergences: ["D-W-4", "D-W-12", "D-W-16"]
    },
    %{
      id: "workers/composed_prompt_a_run_was_spawned_with",
      title: "Composed prompt a run was spawned with",
      mcp: ["worker_prompt"],
      cli: nil,
      rest: ["GET /api/workers/:task_id/prompt"],
      status: {:gap, "P-11"},
      divergences: ["D-W-12"],
      absent: %{
        cli: {:gap, "P-11", "CLI - arb worker prompt <id> [--run R] (read-only audit;"}
      }
    },
    %{
      id: "workers/enumerate_all_runs_incl_reviewgate_synthetic_chi",
      title: "Enumerate all runs incl. ReviewGate synthetic children + transcript presence",
      mcp: ["run_log_list"],
      cli: nil,
      rest: ["GET /api/workers/:task_id/run_log_list"],
      status: {:gap, "P-11"},
      divergences: ["D-W-15"],
      absent: %{
        cli: {:gap, "P-11", "CLI - fold into arb worker runs --corpus (REST route exists)."}
      }
    },
    %{
      id: "workers/transcript_capture_rate_diagnostics",
      title: "Transcript capture-rate diagnostics",
      mcp: ["transcript_capture_stats"],
      cli: nil,
      rest: nil,
      status: :excluded,
      divergences: ["D-W-3"],
      absent: %{
        cli: {:intentional, "one-off ops diagnostic over a hard-coded corpus window (@corpus_start_date, MW:25); but its class-A workspace default is a pitfall (D-W-3)."},
        rest: {:intentional, "one-off ops diagnostic over a hard-coded corpus window (@corpus_start_date, MW:25); but its class-A workspace default is a pitfall (D-W-3)."}
      }
    },
    %{
      id: "workers/list_external_pr_review_records",
      title: "List external-PR review records",
      mcp: ["external_review_list"],
      cli: nil,
      rest: ["GET /api/external_reviews"],
      status: {:gap, "P-12"},
      divergences: ["D-W-20"],
      absent: %{
        cli: {:gap, "P-12", "arb review list);"}
      }
    },
    %{
      id: "workers/show_one_external_review_record_incl_proposed_co",
      title: "Show one external review record (incl. proposed_comments)",
      mcp: ["external_review_show"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-12"},
      absent: %{
        cli: {:gap, "P-12", "CLI (arb review show <id>)."},
        rest: {:gap, "P-12", "REST (GET /api/external_reviews/:id) - report-only review findings must be readable before greenlight;"}
      }
    },
    %{
      id: "workers/read_an_external_review_s_prompt_transcript_tool",
      title: "Read an external review's prompt/transcript/tool uses",
      mcp: ["external_review_transcript"],
      cli: nil,
      rest: ["GET /api/external_reviews/:id/transcript"],
      status: {:gap, "P-12"},
      divergences: ["D-W-22"],
      absent: %{
        cli: {:gap, "P-12", "revive CR);"}
      }
    },
    %{
      id: "workers/list_reviewgate_rounds_for_a_task",
      title: "List ReviewGate rounds for a task",
      mcp: ["review_gate_rounds_list"],
      cli: nil,
      rest: ["GET /api/review_gate_rounds"],
      status: {:gap, "P-12"},
      divergences: ["D-W-21"],
      absent: %{
        cli: {:gap, "P-12", "arb review rounds <task>; sibling of arb review resolve which already exists);"}
      }
    },
    %{
      id: "workers/greenlight_a_report_only_external_review_post_ap",
      title: "Greenlight a report-only external review (post approved comments)",
      mcp: ["review_greenlight"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-12"},
      absent: %{
        cli: {:gap, "P-12", "REST (POST /api/external_reviews/:id/greenlight, policy :dispatch like review) and CLI (arb review greenlight <id> [--select ..])…"},
        rest: {:gap, "P-12", "REST (POST /api/external_reviews/:id/greenlight, policy :dispatch like review) and CLI (arb review greenlight <id> [--select ..])…"}
      }
    },
    %{
      id: "workers/re_arm_one_auto_resolve_attempt_on_parked_watchd",
      title: "Re-arm one auto-resolve attempt on parked watchdog",
      mcp: ["queue_retry_auto_resolve"],
      cli: ["arb queue retry-auto-resolve"],
      rest: ["POST /api/queue/:task_id/retry_auto_resolve"],
      status: :full,
      divergences: ["D-W-19"]
    },
    %{
      id: "workers/restart_a_dead_merge_watchdog",
      title: "Restart a dead merge watchdog",
      mcp: ["queue_restart_watchdog"],
      cli: ["arb queue restart-watchdog"],
      rest: ["POST /api/queue/:task_id/restart_watchdog"],
      status: :partial,
      divergences: ["D-W-19"]
    },
    %{
      id: "workers/re_run_ci_for_a_task_s_pr",
      title: "Re-run CI for a task's PR",
      mcp: ["ci_rerun"],
      cli: ["arb queue rerun-ci"],
      rest: ["POST /api/queue/:task_id/rerun_ci"],
      status: :partial,
      divergences: ["D-W-17", "D-W-18"]
    },
    %{
      id: "workers/mark_a_ci_failure_as_external_infra",
      title: "Mark a CI failure as external/infra",
      mcp: ["ci_mark_external"],
      cli: ["arb queue mark-ci-external"],
      rest: ["POST /api/queue/:task_id/mark_ci_external"],
      status: :partial,
      divergences: ["D-W-17"]
    },
    %{
      id: "workers/record_a_flake_event",
      title: "Record a flake event",
      mcp: ["flake_record"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-10"},
      absent: %{
        cli: {:gap, "P-10", "REST (worker-tier, own task) and CLI arb flake record - gemini/agy workers get only 6 MCP tools (agent_config/gemini.ex @worker_tools) so they cannot call it at all…"},
        rest: {:gap, "P-10", "REST (worker-tier, own task) and CLI arb flake record - gemini/agy workers get only 6 MCP tools (agent_config/gemini.ex @worker_tools) so they cannot call it at all…"}
      }
    },
    %{
      id: "workers/pre_flip_coverage_shadow_gate_verdict",
      title: "Pre-flip coverage-shadow gate verdict",
      mcp: nil,
      cli: ["arb preflip-gate"],
      rest: ["GET /api/coverage_shadow/preflip_gate"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "one-time operator rollout gate for merge.coverage_enabled; no coordinator workflow consumes it. (CLI exits 0 on FAIL verdict - cosmetic, noted in C.)"}
      }
    },
    %{
      id: "workers/list_live_coordinator_systemd_scopes",
      title: "List live coordinator arb-session-* systemd scopes",
      mcp: nil,
      cli: ["arb session list"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "host-local (systemctl --user), reads the CLI host's units."},
        rest: {:intentional, "host-local (systemctl --user), reads the CLI host's units."}
      }
    },
    %{
      id: "workers/attach_to_a_coordinator_session_s_tmux",
      title: "Attach to a coordinator session's tmux",
      mcp: nil,
      cli: ["arb session attach"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "interactive, host-local tmux socket ($XDG_RUNTIME_DIR/arbiter/session-<id>.sock)."},
        rest: {:intentional, "interactive, host-local tmux socket ($XDG_RUNTIME_DIR/arbiter/session-<id>.sock)."}
      }
    },
    %{
      id: "workers/legacy_alias",
      title: "(legacy alias) arb resume ...",
      mcp: nil,
      cli: ["arb resume", "arb worker resume"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Deprecated flat alias, same behavior as row 2 + stderr note; remove with the other @legacy verbs."},
        rest: {:intentional, "Deprecated flat alias, same behavior as row 2 + stderr note; remove with the other @legacy verbs."}
      }
    },
    %{
      id: "workers/legacy_alias_2",
      title: "(legacy alias) arb review <task-id>",
      mcp: nil,
      cli: ["arb review", "arb worker review"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Deprecated alias; BUT also swallows arb review --pr/--transcript (mis-route, task_id \"--pr\")."},
        rest: {:intentional, "Deprecated alias; BUT also swallows arb review --pr/--transcript (mis-route, task_id \"--pr\")."}
      }
    },
    # ---- accounts ----
    %{
      id: "accounts/read_quota_by_workspace",
      title: "Read quota (by workspace)",
      mcp: ["quota_get"],
      cli: ["arb quota"],
      rest: ["GET /api/quota"],
      status: :partial,
      divergences: ["D-A-1", "D-A-3", "D-A-4", "D-A-5", "D-A-6"]
    },
    %{
      id: "accounts/read_quota_by_account",
      title: "Read quota (by account)",
      mcp: nil,
      cli: ["arb quota"],
      rest: ["GET /api/quota"],
      status: {:gap, "P-17"},
      absent: %{
        mcp: {:gap, "P-17", "MCP - add account arg to quota_get; usage/provider_pause already take account refs, so a coordinator can name accounts but cannot read their quota."}
      }
    },
    %{
      id: "accounts/usage_rollup",
      title: "Usage rollup",
      mcp: ["usage_summarize"],
      cli: ["arb usage"],
      rest: ["GET /api/usage"],
      status: :partial,
      divergences: ["D-A-1", "D-A-2", "D-A-3", "D-A-7", "D-A-8", "D-A-9"]
    },
    %{
      id: "accounts/usage_raw_events_incl",
      title: "Usage raw events (incl. --session)",
      mcp: nil,
      cli: ["arb usage events", "arb usage"],
      rest: ["GET /api/usage/events"],
      status: {:gap, "P-17"},
      absent: %{
        mcp: {:gap, "P-17", "MCP - read-only drill-down (usage_events_list: task_id/session_id/account/step/source/since/limit<=cap)…"}
      }
    },
    %{
      id: "accounts/usage_calibration_report",
      title: "Usage calibration report",
      mcp: nil,
      cli: ["arb usage"],
      rest: ["GET /api/usage/calibration"],
      status: {:gap, "P-17"},
      absent: %{
        mcp: {:gap, "P-17", "MCP - small read-only report that sits beside the loop_* analysis tools coordinators already use; low priority."}
      }
    },
    %{
      id: "accounts/list_paused_providers_accounts",
      title: "List paused providers/accounts",
      mcp: nil,
      cli: ["arb provider list"],
      rest: ["GET /api/providers/paused"],
      status: {:gap, "P-17"},
      absent: %{
        mcp: {:gap, "P-17", "MCP - provider_list (read of Pause.to_json/0); today a coordinator can only see pauses by writing one or via an unrelated scheduler tool."}
      }
    },
    %{
      id: "accounts/pause_provider_account",
      title: "Pause provider / account",
      mcp: ["provider_pause"],
      cli: ["arb provider pause"],
      rest: ["POST /api/providers/pause"],
      status: :partial,
      divergences: ["D-A-10", "D-A-11"]
    },
    %{
      id: "accounts/resume_provider_account",
      title: "Resume provider / account",
      mcp: ["provider_resume"],
      cli: ["arb provider resume"],
      rest: ["POST /api/providers/resume"],
      status: :partial,
      divergences: ["D-A-10", "D-A-11"]
    },
    %{
      id: "accounts/list_active_system_alerts",
      title: "List active system alerts",
      mcp: ["alert_list"],
      cli: nil,
      rest: ["GET /api/alerts"],
      status: {:gap, "P-17"},
      absent: %{
        cli: {:gap, "P-17", "CLI - arb alert list [--kind K] [--workspace W]; alerts (expired credential, quota poll failing, stale snapshot, overage, budget) are the installation-health signal and…"}
      }
    },
    %{
      id: "accounts/list_circuit_breakers_auth_holds_watchdog",
      title: "List circuit breakers + auth holds + watchdog",
      mcp: ["breaker_list"],
      cli: ["arb breaker list"],
      rest: ["GET /api/breakers"],
      status: :partial,
      divergences: ["D-A-1", "D-A-2"]
    },
    %{
      id: "accounts/reset_one_breaker_by_signature",
      title: "Reset one breaker by signature",
      mcp: ["breaker_reset"],
      cli: ["arb breaker reset"],
      rest: ["POST /api/breakers/reset"],
      status: :partial,
      divergences: ["D-A-12"]
    },
    %{
      id: "accounts/reset_all_breakers_scoped",
      title: "Reset all breakers (scoped)",
      mcp: ["breaker_reset"],
      cli: ["arb breaker reset"],
      rest: ["POST /api/breakers/reset"],
      status: :partial,
      divergences: ["D-A-1", "D-A-2", "D-A-12"]
    },
    %{
      id: "accounts/clear_provider_auth_hold_credential_watchdog_mar",
      title: "Clear provider auth hold + credential-watchdog mark",
      mcp: ["breaker_reset"],
      cli: ["arb breaker reset"],
      rest: ["POST /api/breakers/reset"],
      status: :full,
      divergences: ["D-A-12"]
    },
    %{
      id: "accounts/list_accounts",
      title: "List accounts",
      mcp: nil,
      cli: ["arb account list"],
      rest: ["GET /api/accounts"],
      status: {:gap, "P-17"},
      divergences: ["D-A-19"],
      absent: %{
        mcp: {:gap, "P-17", "MCP - read-only account_list/account_show; the JSON carries credential kind + 12-char fingerprint prefix + active flag only, never a secret (account_controller.ex show…"}
      }
    },
    %{
      id: "accounts/show_account",
      title: "Show account",
      mcp: nil,
      cli: ["arb account show"],
      rest: ["GET /api/accounts/:ref"],
      status: {:gap, "P-17"},
      absent: %{
        mcp: {:gap, "P-17", "MCP - as above (account_show)."}
      }
    },
    %{
      id: "accounts/create_account",
      title: "Create account",
      mcp: nil,
      cli: ["arb account create"],
      rest: ["POST /api/accounts"],
      status: :partial,
      divergences: ["D-A-14"],
      absent: %{
        mcp: {:intentional, "operator-asserted identity (design doc §2.4); creating accounts is an operator/UI action, not a coordinator-agent action."}
      }
    },
    %{
      id: "accounts/update_account_label_plan_enabled_max_concurrent",
      title: "Update account (label/plan/enabled/max_concurrent/quota_config)",
      mcp: nil,
      cli: ["arb account set"],
      rest: ["PATCH /api/accounts/:ref"],
      status: {:gap, "P-16"},
      divergences: ["D-A-15"],
      absent: %{
        mcp: {:gap, "P-16", "MCP - account_set limited to the non-secret fields (same PATCH whitelist); it is the same class of fleet-routing lever as provider_pause which is already on MCP."}
      }
    },
    %{
      id: "accounts/attach_workspace_to_account",
      title: "Attach workspace to account",
      mcp: nil,
      cli: ["arb account attach"],
      rest: ["POST /api/accounts/:ref/attach"],
      status: :partial,
      divergences: ["D-A-16", "D-A-17"],
      absent: %{
        mcp: {:intentional, "topology change, operator action."}
      }
    },
    %{
      id: "accounts/detach_workspace_from_account",
      title: "Detach workspace from account",
      mcp: nil,
      cli: nil,
      rest: nil,
      status: {:gap, "P-16"},
      absent: %{
        mcp: {:intentional, "same reason as attach)."},
        cli: {:gap, "P-16", "REST + CLI - DELETE /api/accounts/:ref/attach/:workspace_id + arb account detach WS REF…"},
        rest: {:gap, "P-16", "REST + CLI - DELETE /api/accounts/:ref/attach/:workspace_id + arb account detach WS REF…"}
      }
    },
    %{
      id: "accounts/rotate_credential_store_secret",
      title: "Rotate credential (store secret)",
      mcp: nil,
      cli: ["arb account rotate"],
      rest: ["POST /api/accounts/:ref/rotate"],
      status: :partial,
      absent: %{
        mcp: {:intentional, "the secret would be a tool argument, i.e. in the model transcript and MCP request logs."}
      }
    },
    %{
      id: "accounts/merge_accounts",
      title: "Merge accounts",
      mcp: nil,
      cli: ["arb account merge"],
      rest: ["POST /api/accounts/:ref/merge"],
      status: :full,
      absent: %{
        mcp: {:intentional, "irreversible re-pointing of ledger/credential rows; operator action."}
      }
    },
    %{
      id: "accounts/delete_account_soft",
      title: "Delete account (soft / --hard / --detach)",
      mcp: nil,
      cli: ["arb account delete"],
      rest: ["DELETE /api/accounts/:ref"],
      status: :partial,
      absent: %{
        mcp: {:intentional, "destructive, operator action."}
      }
    },
    %{
      id: "accounts/start_provider_login_relay",
      title: "Start provider login (relay)",
      mcp: nil,
      cli: ["arb account login"],
      rest: ["POST /api/accounts/:ref/login"],
      status: :partial,
      divergences: ["D-A-18"],
      absent: %{
        mcp: {:intentional, "interactive (URL/device code + hidden-echo paste prompt) and launches the provider CLI in a tmux session on the host; credential-adjacent."}
      }
    },
    %{
      id: "accounts/login_status_poll",
      title: "Login status poll",
      mcp: nil,
      cli: ["arb account login"],
      rest: ["GET /api/account_logins/:id"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "and no standalone CLI verb - machine hop of the interactive flow."}
      }
    },
    %{
      id: "accounts/login_paste_code",
      title: "Login paste code",
      mcp: nil,
      cli: ["arb account login"],
      rest: ["POST /api/account_logins/:id/paste"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "standalone - a code must never ride in argv or a tool arg (CLI refuses --code, login.ex:46-56)."}
      }
    },
    %{
      id: "accounts/login_cancel",
      title: "Login cancel",
      mcp: nil,
      cli: ["arb account login"],
      rest: ["POST /api/account_logins/:id/cancel"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "; flow-internal."}
      }
    },
    %{
      id: "accounts/login_transcript_download",
      title: "Login transcript download",
      mcp: nil,
      cli: nil,
      rest: ["GET /providers/logins/:id/transcript"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "redacted final-screen download for the dashboard."},
        cli: {:intentional, "redacted final-screen download for the dashboard."}
      }
    },
    %{
      id: "accounts/list_worker_images",
      title: "List worker images",
      mcp: nil,
      cli: ["arb image list"],
      rest: ["GET /api/images"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "host/podman operator surface; no UI. (A read-only image_list would be harmless but nothing needs it.)"}
      }
    },
    %{
      id: "accounts/build_worker_image",
      title: "Build worker image",
      mcp: nil,
      cli: ["arb image build"],
      rest: ["POST /api/images/build"],
      status: :partial,
      divergences: ["D-A-1"],
      absent: %{
        mcp: {:intentional, "minutes-long (25 min client timeout) synchronous host build, would block/timeout a JSON-RPC call."}
      }
    },
    %{
      id: "accounts/refresh_image_pins",
      title: "Refresh image pins",
      mcp: nil,
      cli: ["arb image refresh"],
      rest: ["POST /api/images/refresh"],
      status: :full,
      absent: %{
        mcp: {:intentional, "host maintenance."}
      }
    },
    %{
      id: "accounts/prune_images",
      title: "Prune images",
      mcp: nil,
      cli: ["arb image prune"],
      rest: ["POST /api/images/prune"],
      status: :full,
      absent: %{
        mcp: {:intentional, "destructive host maintenance."}
      }
    },
    %{
      id: "accounts/fetch_short_lived_grok_access_token",
      title: "Fetch short-lived grok access token",
      mcp: nil,
      cli: ["arb grok-token"],
      rest: ["POST /api/grok/token"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "it returns a live bearer token;"}
      }
    },
    %{
      id: "accounts/diag_claude_worker_credentials_report",
      title: "Diag: claude worker credentials report",
      mcp: nil,
      cli: ["arb doctor"],
      rest: ["GET /api/server/claude_credentials"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Cross-domain (server/doctor analyst owns the ruling); listed so every route is covered."}
      }
    },
    %{
      id: "accounts/diag_grok_login_state",
      title: "Diag: grok login state",
      mcp: nil,
      cli: ["arb doctor"],
      rest: ["GET /api/server/grok_auth"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Cross-domain; as above."}
      }
    },
    %{
      id: "accounts/diag_provider_accounts_enablement",
      title: "Diag: provider-accounts enablement",
      mcp: nil,
      cli: ["arb doctor"],
      rest: ["GET /api/server/provider_accounts"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Cross-domain; as above."}
      }
    },
    # ---- workspace ----
    %{
      id: "workspace/list_workspaces",
      title: "List workspaces",
      mcp: ["workspace_list"],
      cli: ["arb workspace list"],
      rest: ["GET /api/workspaces"],
      status: :partial,
      divergences: ["D-C-22"]
    },
    %{
      id: "workspace/show_workspace",
      title: "Show workspace",
      mcp: ["workspace_show"],
      cli: ["arb workspace show"],
      rest: ["GET /api/workspaces/:id"],
      status: :partial,
      divergences: ["D-C-10", "D-C-21"]
    },
    %{
      id: "workspace/create_workspace",
      title: "Create workspace",
      mcp: nil,
      cli: ["arb workspace create"],
      rest: ["POST /api/workspaces"],
      status: :partial,
      divergences: ["D-C-19"],
      absent: %{
        mcp: {:intentional, "provisioning starts merge/dispatch/PR patrol processes and registers repo paths; operator action, not a coordinator-LLM one."}
      }
    },
    %{
      id: "workspace/update_workspace_attrs_name_description_prefix_w",
      title: "Update workspace attrs (name/description/prefix/whole config)",
      mcp: nil,
      cli: nil,
      rest: ["PATCH /api/workspaces/:id", "PUT /api/workspaces/:id"],
      status: {:gap, "P-21"},
      divergences: ["D-C-6"],
      absent: %{
        mcp: {:intentional, "rename/prefix change is operator-level; config goes through workspace_config_set."},
        cli: {:gap, "P-21", "CLI - arb workspace update <ws> [--name --description --prefix] (UI has save_details, workspace_detail_live.ex:216)."}
      }
    },
    %{
      id: "workspace/get_workspace_config_whole_dotted_key",
      title: "Get workspace config (whole / dotted key)",
      mcp: ["workspace_config_get"],
      cli: ["arb config get"],
      rest: ["GET /api/workspaces/:id"],
      status: :partial,
      divergences: ["D-C-14"]
    },
    %{
      id: "workspace/config_overview_grouped_summary",
      title: "Config overview (grouped summary)",
      mcp: ["workspace_config_overview"],
      cli: ["arb config overview"],
      rest: nil,
      status: :partial,
      divergences: ["D-C-14"],
      absent: %{
        rest: {:intentional, "pure view of config; but MCP and CLI are two separate copies (D-C-14, D-C-D1): host the grouping in one core function."}
      }
    },
    %{
      id: "workspace/set_one_config_key_deep_merge",
      title: "Set one config key (deep-merge)",
      mcp: ["workspace_config_set"],
      cli: ["arb config set"],
      rest: ["PATCH /api/workspaces/:id/config"],
      status: :partial,
      divergences: ["D-C-4", "D-C-16", "D-C-17", "D-C-18"]
    },
    %{
      id: "workspace/unset_one_config_key",
      title: "Unset one config key",
      mcp: ["workspace_config_unset"],
      cli: ["arb config unset"],
      rest: ["PATCH /api/workspaces/:id/config"],
      status: :partial,
      divergences: ["D-C-15"]
    },
    %{
      id: "workspace/multi_key_patch_unset_in_one_write",
      title: "Multi-key patch + unset in one write",
      mcp: nil,
      cli: nil,
      rest: ["PATCH /api/workspaces/:id/config"],
      status: {:gap, "P-21"},
      divergences: ["D-C-17"],
      absent: %{
        mcp: {:gap, "P-21", "MCP - accept patch/unset_paths maps in workspace_config_set (UI does multi-key atomic saves, policy_config_component.ex:56…"},
        cli: {:intentional, "config set per key is the CLI contract; --file patch.json would be a nice-to-have."}
      }
    },
    %{
      id: "workspace/config_schema_key_docs",
      title: "Config schema / key docs",
      mcp: nil,
      cli: ["arb config schema"],
      rest: nil,
      status: {:gap, "P-21"},
      absent: %{
        mcp: {:gap, "P-21", "MCP - a coordinator editing config via workspace_config_set has no in-band schema."},
        rest: {:gap, "P-21", "REST - GET /api/workspaces/config_schema."}
      }
    },
    %{
      id: "workspace/standing_orders_list",
      title: "Standing orders: list",
      mcp: ["workspace_config_get", "workspace_config_overview"],
      cli: ["arb workspace standing-order ls"],
      rest: ["GET /api/workspaces/:id"],
      status: :partial,
      note: "No dedicated verb on MCP/REST: INTENTIONALLY ABSENT: MCP/REST - list lives in config; whole-config access suffices."
    },
    %{
      id: "workspace/standing_orders_add",
      title: "Standing orders: add",
      mcp: ["workspace_config_set"],
      cli: ["arb workspace standing-order add"],
      rest: ["PATCH /api/workspaces/:id/config"],
      status: :partial,
      divergences: ["D-C-37"]
    },
    %{
      id: "workspace/standing_orders_remove",
      title: "Standing orders: remove",
      mcp: ["workspace_config_set"],
      cli: ["arb workspace standing-order rm"],
      rest: ["PATCH /api/workspaces/:id/config"],
      status: :partial,
      note: "Same ruling as add."
    },
    %{
      id: "workspace/repo_scoped_standing_orders",
      title: "Repo-scoped standing orders",
      mcp: ["workspace_config_set"],
      cli: ["arb workspace standing-order"],
      rest: ["PATCH /api/workspaces/:id/config"],
      status: :partial,
      divergences: ["D-C-17"]
    },
    %{
      id: "workspace/secrets_list_names",
      title: "Secrets: list names",
      mcp: ["workspace_config_get"],
      cli: ["arb workspace secret ls"],
      rest: ["GET /api/workspaces"],
      status: :full
    },
    %{
      id: "workspace/secrets_set",
      title: "Secrets: set",
      mcp: nil,
      cli: ["arb workspace secret set"],
      rest: ["PATCH /api/workspaces/:id"],
      status: :excluded,
      divergences: ["D-C-4", "D-C-5", "D-C-36"],
      absent: %{
        mcp: {:intentional, "credential material must not transit an LLM context."}
      }
    },
    %{
      id: "workspace/secrets_remove",
      title: "Secrets: remove",
      mcp: nil,
      cli: ["arb workspace secret rm"],
      rest: ["PATCH /api/workspaces/:id"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "same as set."}
      }
    },
    %{
      id: "workspace/worker_env_vars_list_names_secret_flags",
      title: "Worker env vars: list names + secret flags",
      mcp: nil,
      cli: nil,
      rest: ["GET /api/workspaces"],
      status: {:gap, "P-21"},
      absent: %{
        mcp: {:gap, "P-21", "MCP - names/flags in workspace_show (workers/coordinators need to know which env exists; no values)."},
        cli: {:gap, "P-21", "CLI - arb workspace env ls."}
      }
    },
    %{
      id: "workspace/worker_env_vars_set_toggle_secret_flag",
      title: "Worker env vars: set / toggle secret flag",
      mcp: nil,
      cli: nil,
      rest: nil,
      status: {:gap, "P-21"},
      absent: %{
        mcp: {:intentional, "may carry credentials; same rule as secrets."},
        cli: {:gap, "P-21", "CLI - arb workspace env set <name> [--secret] [--value-file|-]."},
        rest: {:gap, "P-21", "REST - add worker_env to the whitelist;"}
      }
    },
    %{
      id: "workspace/worker_env_vars_remove",
      title: "Worker env vars: remove",
      mcp: nil,
      cli: nil,
      rest: nil,
      status: {:gap, "P-21"},
      absent: %{
        mcp: {:intentional, "."},
        cli: {:gap, "P-21", "CLI env rm;"},
        rest: {:gap, "P-21", "REST (worker_env:{name:null});"}
      }
    },
    %{
      id: "workspace/worker_env_vars_reveal_value",
      title: "Worker env vars: reveal value",
      mcp: nil,
      cli: nil,
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "revealing a secret value must stay off every machine surface (MCP especially); browser (operator session) only."},
        cli: {:intentional, "same; if ever added it needs :operator policy, never coordinator."},
        rest: {:intentional, "revealing a secret value must stay off every machine surface (MCP especially); browser (operator session) only."}
      }
    },
    %{
      id: "workspace/installation_settings_get_all_one_key",
      title: "Installation settings: get (all / one key)",
      mcp: ["installation_config_get"],
      cli: ["arb settings get"],
      rest: ["GET /api/installation/config"],
      status: :partial,
      divergences: ["D-C-11", "D-C-12"]
    },
    %{
      id: "workspace/installation_settings_set",
      title: "Installation settings: set",
      mcp: ["installation_config_set"],
      cli: ["arb settings set"],
      rest: ["PATCH /api/installation/config"],
      status: :partial,
      divergences: ["D-C-3", "D-C-7"]
    },
    %{
      id: "workspace/installation_settings_clear_override",
      title: "Installation settings: clear override",
      mcp: ["installation_config_set"],
      cli: ["arb settings unset"],
      rest: ["PATCH /api/installation/config"],
      status: :full
    },
    %{
      id: "workspace/installation_settings_schema_descriptions",
      title: "Installation settings: schema/descriptions",
      mcp: nil,
      cli: ["arb settings schema"],
      rest: ["GET /api/installation/config"],
      status: :partial,
      divergences: ["D-C-11"],
      absent: %{
        mcp: {:intentional, "installation_config_get should return the REST describe shape instead of a new tool (D-C-11)."}
      }
    },
    %{
      id: "workspace/skill_list",
      title: "Skill list",
      mcp: ["skill_list"],
      cli: ["arb skill list"],
      rest: ["GET /api/skills"],
      status: :partial,
      divergences: ["D-C-24"]
    },
    %{
      id: "workspace/skill_show_get",
      title: "Skill show/get",
      mcp: ["skill_get"],
      cli: ["arb skill show"],
      rest: ["GET /api/skills/:id"],
      status: :partial,
      divergences: ["D-C-23"]
    },
    %{
      id: "workspace/skill_create",
      title: "Skill create",
      mcp: ["skill_create"],
      cli: ["arb skill create"],
      rest: ["POST /api/skills"],
      status: :partial,
      divergences: ["D-C-23", "D-C-26"]
    },
    %{
      id: "workspace/skill_update",
      title: "Skill update",
      mcp: ["skill_update"],
      cli: ["arb skill update"],
      rest: ["PATCH /api/skills/:id", "PUT /api/skills/:id"],
      status: :partial,
      divergences: ["D-C-23", "D-C-26"]
    },
    %{
      id: "workspace/skill_delete",
      title: "Skill delete",
      mcp: ["skill_delete"],
      cli: ["arb skill delete"],
      rest: ["DELETE /api/skills/:id"],
      status: :partial,
      divergences: ["D-C-25"]
    },
    %{
      id: "workspace/loop_analysis_report",
      title: "Loop: analysis report",
      mcp: nil,
      cli: ["arb loop analyze", "arb loop"],
      rest: ["GET /api/loop/analyze"],
      status: {:gap, "P-23"},
      divergences: ["D-C-30"],
      absent: %{
        mcp: {:gap, "P-23", "MCP - loop_analyze (coordinator tier, discover bounded like memory_distill's caps, memory_pending.ex:123)…"}
      }
    },
    %{
      id: "workspace/loop_analysis_persist_proposals",
      title: "Loop: analysis + persist proposals",
      mcp: nil,
      cli: ["arb loop analyze"],
      rest: ["POST /api/loop/propose"],
      status: {:gap, "P-23"},
      absent: %{
        mcp: {:gap, "P-23", "MCP - loop_propose (same tool as analyze with propose:true); proposals land only as reviewable pending rows, decision stays human/coordinator-apply."}
      }
    },
    %{
      id: "workspace/loop_hand_author_repo_doc_patch_proposal",
      title: "Loop: hand-author repo-doc patch proposal",
      mcp: nil,
      cli: ["arb loop propose repo-doc-patch"],
      rest: ["POST /api/loop/propose/repo_doc_patch"],
      status: {:gap, "P-23"},
      absent: %{
        mcp: {:gap, "P-23", "MCP - loop_propose_repo_doc_patch; it is a pure queue write exactly like loop_propose_routing, which MCP has."}
      }
    },
    %{
      id: "workspace/loop_hand_author_routing_canary_proposal",
      title: "Loop: hand-author routing canary proposal",
      mcp: ["loop_propose_routing"],
      cli: ["arb loop propose routing"],
      rest: ["POST /api/loop/propose/routing"],
      status: :partial,
      divergences: ["D-C-1", "D-C-9"]
    },
    %{
      id: "workspace/loop_canary_status",
      title: "Loop: canary status",
      mcp: ["loop_canary_status"],
      cli: ["arb loop canary status"],
      rest: ["GET /api/loop/canary"],
      status: :partial,
      divergences: ["D-C-2", "D-C-8"]
    },
    %{
      id: "workspace/loop_list_pending",
      title: "Loop: list pending",
      mcp: ["loop_pending_list"],
      cli: ["arb loop pending"],
      rest: ["GET /api/loop/pending"],
      status: :partial,
      divergences: ["D-C-2", "D-C-9"]
    },
    %{
      id: "workspace/loop_show_pending_diff",
      title: "Loop: show pending (diff)",
      mcp: ["loop_pending_diff"],
      cli: ["arb loop diff"],
      rest: ["GET /api/loop/pending/:id"],
      status: :partial,
      divergences: ["D-C-29"]
    },
    %{
      id: "workspace/loop_apply_one",
      title: "Loop: apply one",
      mcp: ["loop_pending_apply"],
      cli: ["arb loop apply"],
      rest: ["POST /api/loop/pending/:id/apply"],
      status: :full,
      divergences: ["D-C-28", "D-C-34"]
    },
    %{
      id: "workspace/loop_apply_all",
      title: "Loop: apply all",
      mcp: nil,
      cli: ["arb loop apply all"],
      rest: nil,
      status: :excluded,
      divergences: ["D-C-2"],
      absent: %{
        mcp: {:intentional, "deliberate \"never a server-side bulk write\" (loop.ex:479-480 comment); but CLI --workspace is dead so it applies across ALL workspaces (D-C-2, H)."},
        rest: {:intentional, "deliberate \"never a server-side bulk write\" (loop.ex:479-480 comment); but CLI --workspace is dead so it applies across ALL workspaces (D-C-2, H)."}
      }
    },
    %{
      id: "workspace/loop_reject",
      title: "Loop: reject",
      mcp: ["loop_pending_reject"],
      cli: ["arb loop reject"],
      rest: ["POST /api/loop/pending/:id/reject"],
      status: :full
    },
    %{
      id: "workspace/memory_list_pending_candidates",
      title: "Memory: list pending candidates",
      mcp: ["memory_pending_list"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-25"},
      absent: %{
        cli: {:gap, "P-25", "CLI/REST - arb memory pending / GET /api/memory/pending; the write side is gated to a PLAIN coordinator token (no session id) i.e…"},
        rest: {:gap, "P-25", "CLI/REST - arb memory pending / GET /api/memory/pending; the write side is gated to a PLAIN coordinator token (no session id) i.e…"}
      }
    },
    %{
      id: "workspace/memory_show_pending_diff",
      title: "Memory: show pending diff",
      mcp: ["memory_pending_diff"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-25"},
      absent: %{
        cli: {:gap, "P-25", "CLI/REST (same reason)."},
        rest: {:gap, "P-25", "CLI/REST (same reason)."}
      }
    },
    %{
      id: "workspace/memory_promote_apply",
      title: "Memory: promote (apply)",
      mcp: ["memory_pending_apply"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-25"},
      absent: %{
        cli: {:gap, "P-25", "CLI/REST - REST policy must be :operator (not :coordinator) to preserve \"session token refused\" (memory_pending.ex:138-143)."},
        rest: {:gap, "P-25", "CLI/REST - REST policy must be :operator (not :coordinator) to preserve \"session token refused\" (memory_pending.ex:138-143)."}
      }
    },
    %{
      id: "workspace/memory_reject_candidate",
      title: "Memory: reject candidate",
      mcp: ["memory_pending_reject"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-25"},
      absent: %{
        cli: {:gap, "P-25", "CLI/REST (:operator)."},
        rest: {:gap, "P-25", "CLI/REST (:operator)."}
      }
    },
    %{
      id: "workspace/memory_list_quarantine",
      title: "Memory: list quarantine",
      mcp: ["memory_quarantine_list"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-25"},
      absent: %{
        cli: {:gap, "P-25", "CLI/REST."},
        rest: {:gap, "P-25", "CLI/REST."}
      }
    },
    %{
      id: "workspace/memory_restore_from_quarantine",
      title: "Memory: restore from quarantine",
      mcp: ["memory_quarantine_restore"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-25"},
      absent: %{
        cli: {:gap, "P-25", "CLI/REST (:operator)."},
        rest: {:gap, "P-25", "CLI/REST (:operator)."}
      }
    },
    %{
      id: "workspace/memory_distill_a_session_transcript",
      title: "Memory: distill a session transcript",
      mcp: ["memory_distill"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-25"},
      absent: %{
        cli: {:gap, "P-25", "CLI/REST (:operator); memory root is a host-local file store (Paths.memory_root()) but the server owns it, so REST is fine."},
        rest: {:gap, "P-25", "CLI/REST (:operator); memory root is a host-local file store (Paths.memory_root()) but the server owns it, so REST is fine."}
      }
    },
    %{
      id: "workspace/list_repos",
      title: "List repos",
      mcp: ["repo_list"],
      cli: ["arb repo list"],
      rest: ["GET /api/repos"],
      status: :partial,
      divergences: ["D-C-31"]
    },
    %{
      id: "workspace/show_repo",
      title: "Show repo",
      mcp: ["repo_show"],
      cli: ["arb repo show"],
      rest: nil,
      status: {:gap, "P-24"},
      divergences: ["D-C-31"],
      absent: %{
        rest: {:gap, "P-24", "REST - GET /api/repos/:name so the three finders collapse; low priority."}
      }
    },
    %{
      id: "workspace/workspace_resolution_for",
      title: "Workspace resolution for arb init",
      mcp: nil,
      cli: ["arb init"],
      rest: ["GET /api/workspaces"],
      status: :excluded,
      divergences: ["D-C-38"],
      absent: %{
        mcp: {:intentional, "host-local scaffolding."}
      }
    },
    %{
      id: "workspace/workspace_resolution_for_2",
      title: "Workspace resolution for arb where",
      mcp: nil,
      cli: ["arb where"],
      rest: ["GET /api/workspaces"],
      status: :excluded,
      divergences: ["D-C-38"],
      absent: %{
        mcp: {:intentional, "tokens/scope already carry the workspace."}
      }
    },
    # ---- misc ----
    %{
      id: "misc/read_coordinator_mailbox_unread",
      title: "Read coordinator mailbox, unread",
      mcp: ["coordinator_inbox"],
      cli: ["arb message inbox", "arb inbox"],
      rest: ["GET /api/messages"],
      status: :partial,
      divergences: ["D-M-2", "D-M-5", "D-M-6", "D-M-12"]
    },
    %{
      id: "misc/read_coordinator_outstanding_queue_read_not_clea",
      title: "Read coordinator \"outstanding\" queue (read, not cleared)",
      mcp: ["coordinator_inbox"],
      cli: nil,
      rest: ["GET /api/messages"],
      status: {:gap, "P-26"},
      absent: %{
        cli: {:gap, "P-26", "arb inbox --outstanding (inbox.ex:72-105 has no such form; --all = 20 newest of any state, not the triage queue)."}
      }
    },
    %{
      id: "misc/coordinator_attention_queue_open_tickets_whose_a",
      title: "Coordinator attention queue (open tickets whose attention the coordinator owns)",
      mcp: ["coordinator_inbox"],
      cli: nil,
      rest: nil,
      status: {:gap, "P-27"},
      divergences: ["D-M-7"],
      absent: %{
        cli: {:gap, "P-27", "arb inbox prints it / arb attention."},
        rest: {:gap, "P-27", "GET /api/attention?owner=&workspace_id= over Tasks.Attention.items/1 (MCP is the only consumer, MSG:158)."}
      }
    },
    %{
      id: "misc/browse_coordinator_mailbox_history_incl_read_cle",
      title: "Browse coordinator mailbox history incl. read+cleared",
      mcp: nil,
      cli: ["arb inbox"],
      rest: ["GET /api/messages"],
      status: :partial,
      absent: %{
        mcp: {:intentional, "mailbox model is unread/outstanding queue only; archive browsing is REST/dashboard."}
      }
    },
    %{
      id: "misc/drain_a_task_s_mailbox_unread_worker_reads_own_c",
      title: "Drain a task's mailbox (unread; worker reads own, coordinator any)",
      mcp: ["inbox_check"],
      cli: ["arb message inbox", "arb inbox"],
      rest: ["GET /api/messages", "POST /api/messages/:id/read"],
      status: :partial,
      divergences: ["D-M-1", "D-M-5", "D-M-9"]
    },
    %{
      id: "misc/task_mailbox_outstanding_read_not_cleared",
      title: "Task mailbox, outstanding (read, not cleared)",
      mcp: ["inbox_check"],
      cli: nil,
      rest: ["GET /api/messages"],
      status: {:gap, "P-26"},
      absent: %{
        cli: {:gap, "P-26", "same --outstanding flag as row 2."}
      }
    },
    %{
      id: "misc/show_one_message_in_full",
      title: "Show one message in full",
      mcp: nil,
      cli: nil,
      rest: ["GET /api/messages/:id"],
      status: :partial,
      absent: %{
        mcp: {:intentional, "list results already carry full bodies."},
        cli: {:intentional, "inbox read <id> shows one in full."}
      }
    },
    %{
      id: "misc/mark_one_message_read",
      title: "Mark one message read",
      mcp: nil,
      cli: ["arb inbox read"],
      rest: ["POST /api/messages/:id/read"],
      status: :partial,
      divergences: ["D-M-10"],
      absent: %{
        mcp: {:intentional, "unread listing already marks read; per-id ack is not a coordinator need."}
      }
    },
    %{
      id: "misc/clear_specific_messages_by_id",
      title: "Clear specific messages by id",
      mcp: ["coordinator_inbox_clear"],
      cli: ["arb inbox clear"],
      rest: ["DELETE /api/messages"],
      status: :partial,
      divergences: ["D-M-2", "D-M-10"]
    },
    %{
      id: "misc/clear_all_coordinator_messages_for_one_task",
      title: "Clear all coordinator messages for one task",
      mcp: ["coordinator_inbox_clear"],
      cli: ["arb inbox clear"],
      rest: ["DELETE /api/messages"],
      status: :partial,
      divergences: ["D-M-3", "D-M-10"]
    },
    %{
      id: "misc/clear_the_read_tail_bulk",
      title: "Clear the read tail (bulk)",
      mcp: ["coordinator_inbox"],
      cli: ["arb inbox clear"],
      rest: ["DELETE /api/messages"],
      status: :partial,
      divergences: ["D-M-5", "D-M-10"]
    },
    %{
      id: "misc/clear_everything_incl_unread",
      title: "Clear everything incl. unread",
      mcp: nil,
      cli: ["arb inbox clear"],
      rest: ["DELETE /api/messages"],
      status: :partial,
      absent: %{
        mcp: {:intentional, "clearing unseen mail is destructive;"}
      }
    },
    %{
      id: "misc/send_a_message_to_a_mailbox",
      title: "Send a message to a mailbox",
      mcp: ["message_send"],
      cli: ["arb message send", "arb msg"],
      rest: ["POST /api/messages"],
      status: :partial,
      divergences: ["D-M-1", "D-M-8", "D-M-9"]
    },
    %{
      id: "misc/direct_a_worker_coordinator_direction",
      title: "Direct a worker (coordinator direction)",
      mcp: ["message_send"],
      cli: ["arb message"],
      rest: ["POST /api/messages"],
      status: :partial,
      divergences: ["D-M-9"]
    },
    %{
      id: "misc/list_recent_notifications",
      title: "List recent notifications",
      mcp: ["notify_list"],
      cli: ["arb message notify", "arb notify"],
      rest: ["GET /api/messages"],
      status: :partial,
      divergences: ["D-M-4"]
    },
    %{
      id: "misc/deprecated_flat_aliases",
      title: "Deprecated flat aliases",
      mcp: nil,
      cli: ["arb inbox", "arb notify", "arb msg"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Legacy aliases; remove with the next CLI cut. Same handlers as rows 1/5/15/13."},
        rest: {:intentional, "Legacy aliases; remove with the next CLI cut. Same handlers as rows 1/5/15/13."}
      }
    },
    %{
      id: "misc/legacy_field",
      title: "directive_ref / --directive legacy field",
      mcp: ["message_send"],
      cli: ["arb message send"],
      rest: ["POST /api/messages"],
      status: :full
    },
    %{
      id: "misc/pause_the_board_autopilot",
      title: "Pause the board autopilot",
      mcp: ["scheduler_pause"],
      cli: ["arb scheduler pause"],
      rest: ["POST /api/scheduler/pause"],
      status: :partial,
      divergences: ["D-M-17"]
    },
    %{
      id: "misc/resume_the_board_autopilot",
      title: "Resume the board autopilot",
      mcp: ["scheduler_resume"],
      cli: ["arb scheduler resume"],
      rest: ["POST /api/scheduler/resume"],
      status: :partial,
      divergences: ["D-M-17"]
    },
    %{
      id: "misc/drain_scheduler_status",
      title: "Drain/scheduler status",
      mcp: ["scheduler_status"],
      cli: ["arb scheduler status"],
      rest: ["GET /api/scheduler/status"],
      status: :full
    },
    %{
      id: "misc/wait_until_scheduler_quiescent",
      title: "Wait until scheduler quiescent",
      mcp: nil,
      cli: ["arb scheduler wait"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."},
        rest: {:intentional, "."}
      }
    },
    %{
      id: "misc/mint_a_node_join_token",
      title: "Mint a node join token",
      mcp: nil,
      cli: ["arb node add"],
      rest: ["POST /api/nodes/join-tokens"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "operator proof required (POL:306); an LLM coordinator must not enrol machines that receive provider tokens (POL:24-28)."}
      }
    },
    %{
      id: "misc/list_nodes",
      title: "List nodes",
      mcp: nil,
      cli: ["arb node list"],
      rest: ["GET /api/nodes"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "follows REST policy (reads are operator-only)."}
      }
    },
    %{
      id: "misc/show_one_node_or",
      title: "Show one node (or local)",
      mcp: nil,
      cli: ["arb node show"],
      rest: ["GET /api/nodes/:ref"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Same as 23."}
      }
    },
    %{
      id: "misc/node_event_log",
      title: "Node event log",
      mcp: nil,
      cli: ["arb node events"],
      rest: ["GET /api/nodes/:ref/events"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Same as 23. (events local -> 404: fetch(\"local\") is nil, node_controller.ex:84,167.)"}
      }
    },
    %{
      id: "misc/edit_node_name_labels_max_workers_takes_max_work",
      title: "Edit node (name, labels, max_workers; local takes max_workers)",
      mcp: nil,
      cli: ["arb node set"],
      rest: ["PATCH /api/nodes/:ref"],
      status: :excluded,
      divergences: ["D-M-16"],
      absent: %{
        mcp: {:intentional, "operator-proof mutation)."}
      }
    },
    %{
      id: "misc/drain_node",
      title: "Drain node",
      mcp: nil,
      cli: ["arb node drain"],
      rest: ["POST /api/nodes/:ref/drain"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "(operator-proof mutation)."}
      }
    },
    %{
      id: "misc/undrain_node",
      title: "Undrain node",
      mcp: nil,
      cli: ["arb node undrain"],
      rest: ["POST /api/nodes/:ref/undrain"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Same."}
      }
    },
    %{
      id: "misc/revoke_node",
      title: "Revoke node",
      mcp: nil,
      cli: ["arb node revoke"],
      rest: ["POST /api/nodes/:ref/revoke"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Same."}
      }
    },
    %{
      id: "misc/upgrade_node_agent",
      title: "Upgrade node agent",
      mcp: nil,
      cli: ["arb node upgrade"],
      rest: ["POST /api/nodes/:ref/upgrade"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Same."}
      }
    },
    %{
      id: "misc/remove_revoked_node",
      title: "Remove (revoked) node",
      mcp: nil,
      cli: ["arb node remove"],
      rest: ["DELETE /api/nodes/:ref"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Same."}
      }
    },
    %{
      id: "misc/node_enrolment_agent_download",
      title: "Node enrolment + agent download",
      mcp: nil,
      cli: nil,
      rest: ["GET /nodes/join", "GET /nodes/ping", "POST /nodes/enroll", "GET /nodes/agent/:file", "GET /nodes/files/:sha"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Machine endpoints for the node agent; join token / arbn_ credential, disjoint from Scope/ApiPolicy. Not for agents or the CLI. Handler details (unverified)."},
        cli: {:intentional, "Machine endpoints for the node agent; join token / arbn_ credential, disjoint from Scope/ApiPolicy. Not for agents or the CLI. Handler details (unverified)."}
      }
    },
    %{
      id: "misc/node_agent_channel",
      title: "Node agent channel",
      mcp: nil,
      cli: nil,
      rest: ["WS /node/socket"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Node credential only; node agent transport. (unverified)"},
        cli: {:intentional, "Node credential only; node agent transport. (unverified)"}
      }
    },
    %{
      id: "misc/mint_a_coordinator_token",
      title: "Mint a coordinator token",
      mcp: nil,
      cli: ["arb mcp token mint"],
      rest: ["POST /api/mcp/tokens"],
      status: :partial,
      divergences: ["D-M-15"],
      absent: %{
        mcp: {:intentional, "a tool that mints tokens would let any coordinator-tier call widen authority; minting is bearer/operator-socket only."}
      }
    },
    %{
      id: "misc/verify_decode_a_token",
      title: "Verify/decode a token",
      mcp: nil,
      cli: ["arb mcp token verify"],
      rest: ["POST /api/mcp/tokens/verify"],
      status: :partial,
      divergences: ["D-M-15"],
      absent: %{
        mcp: {:intentional, "debug aid."}
      }
    },
    %{
      id: "misc/mint_an_operator_proof_token",
      title: "Mint an operator-proof token",
      mcp: nil,
      cli: ["arb mcp token mint", "arb init"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "operator proof must come from the peer-credential-checked unix socket (operator_socket.ex:224-240)."},
        rest: {:intentional, "operator proof must come from the peer-credential-checked unix socket (operator_socket.ex:224-240)."}
      }
    },
    %{
      id: "misc/dashboard_login_token_operator_dashboard_session",
      title: "Dashboard login token (-> operator dashboard session)",
      mcp: nil,
      cli: ["arb dashboard login"],
      rest: ["POST /api/dashboard/login_tokens"],
      status: :partial,
      divergences: ["D-M-14"],
      absent: %{
        mcp: {:intentional, "browser operator grant."}
      }
    },
    %{
      id: "misc/server_version_sha_boot_time_update_check",
      title: "Server version / sha / boot time / update check",
      mcp: nil,
      cli: ["arb version", "arb server version"],
      rest: ["GET /api/version"],
      status: {:gap, "P-27"},
      divergences: ["D-M-18"],
      absent: %{
        mcp: {:gap, "P-27", "read-only server_version (or server_status) returning /api/version (sha, built_at, booted_at): the Verifying flow needs \"did the restart land on the new sha\";"}
      }
    },
    %{
      id: "misc/pending_migration_status",
      title: "Pending-migration status",
      mcp: nil,
      cli: ["arb server doctor"],
      rest: ["GET /api/server/migrations"],
      status: {:gap, "P-27"},
      absent: %{
        mcp: {:gap, "P-27", "fold into the server_status of row 44 (anonymous on REST)."}
      }
    },
    %{
      id: "misc/host_posture_diagnostics_13_bind_address_agy_wri",
      title: "Host posture diagnostics (13): bind_address, agy_write_jail, egress_jail, guardrails, claude_credentials, grok_auth, provider_accounts, merge_routing, tmux, worker_tmp, podman_sandbox, worker_memory, dashboard_auth",
      mcp: nil,
      cli: ["arb server doctor"],
      rest: ["GET /api/server/bind_address", "GET /api/server/agy_write_jail", "GET /api/server/egress_jail", "GET /api/server/guardrails", "GET /api/server/merge_routing", "GET /api/server/podman_sandbox", "GET /api/server/tmux", "GET /api/server/worker_memory", "GET /api/server/worker_tmp", "GET /api/server/dashboard_auth"],
      status: :partial,
      absent: %{
        mcp: {:intentional, "host paths, credential-gap and jail posture are operator-host facts an LLM cannot act on; egress_jail starts a proxy per call…"}
      }
    },
    %{
      id: "misc/run_diagnostics_doctor",
      title: "Run diagnostics (doctor)",
      mcp: nil,
      cli: ["arb server doctor", "arb doctor"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."},
        rest: {:intentional, "."}
      }
    },
    %{
      id: "misc/coordinator_prime_briefing",
      title: "Coordinator \"prime\" briefing",
      mcp: nil,
      cli: ["arb prime"],
      rest: ["GET /api/scheduler/status"],
      status: :partial,
      absent: %{
        mcp: {:intentional, "as an MCP tool: a coordinator session composes the five calls; one fat tool would bloat context and hide per-call errors)."}
      }
    },
    %{
      id: "misc/resolve_active_workspace_show_endpoint",
      title: "Resolve active workspace / show endpoint",
      mcp: nil,
      cli: ["arb where"],
      rest: ["GET /api/workspaces"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."}
      }
    },
    %{
      id: "misc/bootstrap_a_coordinator_directory",
      title: "Bootstrap a coordinator directory",
      mcp: nil,
      cli: ["arb init"],
      rest: ["POST /api/mcp/tokens"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."}
      }
    },
    %{
      id: "misc/start_the_server",
      title: "Start the server",
      mcp: nil,
      cli: ["arb server start", "arb start"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."},
        rest: {:intentional, "."}
      }
    },
    %{
      id: "misc/restart_the_server",
      title: "Restart the server",
      mcp: nil,
      cli: ["arb server restart", "arb restart"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, ". systemctl/kill; kills in-flight workers; worker-session guard."},
        rest: {:intentional, ". systemctl/kill; kills in-flight workers; worker-session guard."}
      }
    },
    %{
      id: "misc/deploy_from_a_github_release",
      title: "Deploy from a GitHub release",
      mcp: nil,
      cli: ["arb server deploy"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."},
        rest: {:intentional, "."}
      }
    },
    %{
      id: "misc/deploy_by_git_pull_dev_checkout",
      title: "Deploy by git pull (dev checkout)",
      mcp: nil,
      cli: ["arb server deploy", "arb update"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Same as 53."},
        rest: {:intentional, "Same as 53."}
      }
    },
    %{
      id: "misc/apply_migrations",
      title: "Apply migrations",
      mcp: nil,
      cli: ["arb server migrate", "arb migrate"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."},
        rest: {:intentional, "."}
      }
    },
    %{
      id: "misc/install_cli_from_checkout",
      title: "Install CLI from checkout",
      mcp: nil,
      cli: ["arb install cli", "arb install-cli"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Host-local build+copy of the escript."},
        rest: {:intentional, "Host-local build+copy of the escript."}
      }
    },
    %{
      id: "misc/install_uninstall_systemd_service",
      title: "Install/uninstall systemd service",
      mcp: nil,
      cli: ["arb install service", "arb install-service"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Host-local systemd/linger/env-file writer (captures secrets into arbiter.env). --uninstall skips both guards (unverified, per inventory)."},
        rest: {:intentional, "Host-local systemd/linger/env-file writer (captures secrets into arbiter.env). --uninstall skips both guards (unverified, per inventory)."}
      }
    },
    %{
      id: "misc/self_update_the_cli_binary",
      title: "Self-update the CLI binary",
      mcp: nil,
      cli: ["arb self-update", "arb upgrade"],
      rest: nil,
      status: :excluded,
      divergences: ["D-M-19"],
      absent: %{
        mcp: {:intentional, "GitHub + local filesystem only. Progress lines go to stdout and break --json (self_update.ex:305-309, D-M-19)."},
        rest: {:intentional, "GitHub + local filesystem only. Progress lines go to stdout and break --json (self_update.ex:305-309, D-M-19)."}
      }
    },
    %{
      id: "misc/list_coordinator_tmux_sessions",
      title: "List coordinator tmux sessions",
      mcp: nil,
      cli: ["arb session list"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "."},
        rest: {:intentional, "."}
      }
    },
    %{
      id: "misc/attach_to_a_coordinator_tmux_session",
      title: "Attach to a coordinator tmux session",
      mcp: nil,
      cli: ["arb session attach"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "interactive TTY, host-local."},
        rest: {:intentional, "interactive TTY, host-local."}
      }
    },
    %{
      id: "misc/event_stream_inbox_review_gate_worker_failed_top",
      title: "Event stream (inbox, review_gate, worker_failed, ... topics; NDJSON, replay by since)",
      mcp: nil,
      cli: nil,
      rest: ["GET /events"],
      status: :excluded,
      divergences: ["D-M-22"],
      absent: %{
        mcp: {:intentional, "tools/call is request/response and GET /mcp SSE is keepalive only; coordinator_inbox polling covers the inbox topic."},
        cli: {:intentional, "consumed by the runbook's curl -N monitor (arb init template), not an operator verb."}
      }
    },
    %{
      id: "misc/browser_terminal_channel",
      title: "Browser terminal channel",
      mcp: nil,
      cli: nil,
      rest: ["WS /session"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Browser/terminal transport; bridged workers refused. (handler unverified)"},
        cli: {:intentional, "Browser/terminal transport; bridged workers refused. (handler unverified)"}
      }
    },
    %{
      id: "misc/help_cli_version",
      title: "Help / CLI version",
      mcp: nil,
      cli: ["arb help"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "CLI-local."},
        rest: {:intentional, "CLI-local."}
      }
    },
    %{
      id: "misc/legacy_server_redirects",
      title: "Legacy server redirects",
      mcp: nil,
      cli: ["arb doctor", "arb start", "arb restart", "arb migrate", "arb update", "arb install-cli", "arb install-service"],
      rest: nil,
      status: :excluded,
      absent: %{
        mcp: {:intentional, "Deprecated aliases to the server/install verbs; same handlers as rows 47, 51-57."},
        rest: {:intentional, "Deprecated aliases to the server/install verbs; same handlers as rows 47, 51-57."}
      }
    },
    %{
      id: "misc/release_deploy_dashboard_update",
      title: "Dashboard-triggered release deploy (operator)",
      mcp: nil,
      cli: nil,
      rest: ["POST /api/release/deploy", "GET /api/release/deploy"],
      status: :excluded,
      absent: %{
        mcp: {:intentional, "replaces the running server; operator-proof only, an LLM coordinator must not be able to swap the release"},
        cli: {:intentional, "`arb server deploy` performs the deploy host-locally; this route is the dashboard update button trigger"}
      }
    }
  ]
}
