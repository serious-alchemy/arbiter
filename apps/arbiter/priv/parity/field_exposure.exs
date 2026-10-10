# Field-exposure manifest: for the four operations with large argument sets, every field the
# code takes and where each surface (MCP, CLI, REST) exposes it. Parity audit P-30.
#
# Plain terms, read by `Arbiter.Parity.FieldExposure.load!/0`. The guard tests (one in
# `arbiter`, one in `arbiter_cli`) fail when the Ash action / registry takes a field that has
# no entry here, when an entry names a field the code no longer takes, and when a surface does
# not agree with its entry. Adding a field to `Issue :create` accept therefore fails until it
# is classified here.
#
# Entry forms
#
#   "field" => :same                            exposed on every surface under its own name
#   "field" => %{mcp: _, cli: _, rest: _}       one cell per surface, each one of
#                                                 :same            the field's own name
#                                                 "name"           the name it goes by there
#                                                                  (CLI: the switch without dashes,
#                                                                  "positional" for an argument)
#                                                 {:none, "why"}   deliberately absent there
#   "field" => {:internal, "why"}               on no surface (engagement / audit state)
#
# Operations: issue/create, issue/update (`Issue :create` / `:update` plus the REST allow-list
# `Arbiter.Tasks.IssueFields`), account/create, account/update (`ProviderAccount`, with
# `quota_config` expanded into its keys), dispatch (`Arbiter.Worker.Dispatch.Params`).
%{
  "issue/create" => %{
    "title" => %{mcp: :same, cli: "positional", rest: :same},
    "description" => :same,
    "acceptance" => :same,
    "notes" => :same,
    "qa_notes" => :same,
    "deployment_notes" => :same,
    "priority" => :same,
    "difficulty" => :same,
    "issue_type" => %{mcp: :same, cli: "type", rest: :same},
    "auto_close" => :same,
    "verify_after_deploy" => :same,
    "tracker_type" => :same,
    "tracker_ref" => :same,
    "tracker_context_type" => :same,
    "tracker_context_ref" => :same,
    "target_branch" => :same,
    "repo" => :same,
    "provider_constraint" => %{mcp: :same, cli: "require_provider", rest: :same},
    "permissions" => %{mcp: :same, cli: "permission", rest: :same},
    "workspace_id" => %{
      mcp:
        {:none, "MCP binds the ticket to the session workspace (`workspace` option), not a field"},
      cli:
        {:none,
         "the CLI resolves the workspace from its binding / `--workspace`, not a field flag"},
      rest: :same
    },
    "source_pr" => %{
      mcp: {:none, "set by tracker/PR ingestion, not by a coordinator"},
      cli: {:none, "set by tracker/PR ingestion, not by a coordinator"},
      rest: :same
    },
    "skip_upstream_create" => %{
      mcp: {:none, "gap candidate: MCP ticket_create has no outbound-tracker opt-out"},
      cli: "no_tracker",
      rest: :same
    },
    "parent_id" => %{mcp: :same, cli: "parent", rest: :same},
    "tracker_child_policy" => %{
      mcp: {:none, "internal: a refine session passes :context_only"},
      cli: {:none, "internal: a refine session passes :context_only"},
      rest: :same
    },
    "review_only" =>
      {:internal, "ReviewPatrol engagement state (ExternalReview creates it directly)"},
    "last_reviewed_sha" => {:internal, "ReviewPatrol engagement state"},
    "last_seen_comment_id" => {:internal, "ReviewPatrol engagement state"},
    "review_automation" => {:internal, "ReviewPatrol engagement state"},
    "posted_findings" => {:internal, "ReviewPatrol engagement state"},
    "last_verdict" => {:internal, "circuit-breaker seed written by ExternalReview"},
    "last_verdict_sha" => {:internal, "circuit-breaker seed written by ExternalReview"},
    "skills" => {:internal, "read only at dispatch (`Arbiter.Skills.Selection`); P-14"}
  },
  "issue/update" => %{
    "title" => :same,
    "description" => :same,
    "acceptance" => :same,
    "notes" => :same,
    "append_notes" => :same,
    "qa_notes" => :same,
    "deployment_notes" => :same,
    "priority" => :same,
    "difficulty" => :same,
    "issue_type" => %{mcp: :same, cli: "type", rest: :same},
    "auto_close" => :same,
    "verify_after_deploy" => :same,
    "tracker_type" => :same,
    "tracker_ref" => :same,
    "tracker_context_type" => :same,
    "tracker_context_ref" => :same,
    "target_branch" => :same,
    "repo" => :same,
    "pr_ref" => :same,
    "pr_body" => %{
      mcp:
        {:none, "a PR body is written by the worker/merge pipeline; no coordinator tool edits it"},
      cli: :same,
      rest: :same
    },
    "provider_constraint" => %{mcp: :same, cli: "require_provider", rest: :same},
    "permissions" => %{mcp: :same, cli: "permission", rest: :same},
    "add_permissions" => %{mcp: :same, cli: "permission", rest: :same},
    "remove_permissions" => %{mcp: :same, cli: "remove_permission", rest: :same},
    "change_origin" => {:internal, "audit label written only by `Arbiter.Loop.Apply`"},
    "review_only" => {:internal, "ReviewPatrol engagement state"},
    "last_reviewed_sha" => {:internal, "ReviewPatrol engagement state"},
    "last_reviewed_at" => {:internal, "ReviewPatrol engagement state"},
    "last_seen_comment_id" => {:internal, "ReviewPatrol engagement state"},
    "review_automation" => {:internal, "ReviewPatrol engagement state"},
    "posted_findings" => {:internal, "ReviewPatrol engagement state"},
    "settled_threads" => {:internal, "ReviewPatrol engagement state"},
    "review_count" => {:internal, "ReviewPatrol review cap counter"},
    "review_cap_escalated" => {:internal, "ReviewPatrol review cap state"},
    "last_verdict" => {:internal, "loop-signature circuit-breaker input"},
    "last_verdict_sha" => {:internal, "loop-signature circuit-breaker input"},
    "circuit_breaker_tripped" =>
      {:internal, "breaker state; cleared by the typed `resume_review` action"},
    "circuit_breaker_reason" =>
      {:internal, "breaker state; cleared by the typed `resume_review` action"},
    "circuit_breaker_sha" =>
      {:internal, "breaker state; cleared by the typed `resume_review` action"},
    "pr_opened_notified_ref" => {:internal, "PRPatrol watermark"},
    "pr_opened_transitioned_ref" => {:internal, "PRPatrol watermark"},
    "skills" => {:internal, "read only at dispatch (`Arbiter.Skills.Selection`); P-14"}
  },
  "account/create" => %{
    "provider" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: "positional",
      rest: :same
    },
    "slug" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: "positional",
      rest: :same
    },
    "label" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "plan" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "enabled" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: "disable",
      rest: :same
    },
    "max_concurrent" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "provider_account_ref" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "provider_org_ref" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "threshold_mode" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "throttle_threshold" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "weekly_threshold" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "paced_floor" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "weekly_paced_floor" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "weekly_warning_policy" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "window_seconds" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "pace_exempt_priority" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "pace_exempt_threshold" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "weekly_pace_exempt_threshold" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "spend_cap" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "spend_window" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "spend_mode" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "spend_metered" => %{
      mcp: {:none, "account create is an operator action, not on MCP"},
      cli: :same,
      rest: :same
    },
    "identity_source" => {:internal, "set by the credential attach / login flows, never typed"},
    "identity_verified_at" => {:internal, "set by identity verification, never typed"},
    "merged_into_id" => {:internal, "written by the typed merge operation (`arb account merge`)"}
  },
  "account/update" => %{
    "label" => :same,
    "plan" => :same,
    "enabled" => %{mcp: :same, cli: "enable", rest: :same},
    "max_concurrent" => :same,
    "threshold_mode" => :same,
    "throttle_threshold" => :same,
    "weekly_threshold" => :same,
    "paced_floor" => :same,
    "weekly_paced_floor" => :same,
    "weekly_warning_policy" => :same,
    "window_seconds" => :same,
    "pace_exempt_priority" => :same,
    "pace_exempt_threshold" => :same,
    "weekly_pace_exempt_threshold" => :same,
    "spend_cap" => :same,
    "spend_window" => :same,
    "spend_mode" => :same,
    "spend_metered" => :same,
    "provider_account_ref" =>
      {:internal,
       "create-only: the provider's own uuid is asserted at creation (`Arbiter.Accounts.Fields`)"},
    "provider_org_ref" =>
      {:internal,
       "create-only: the provider's own org uuid is asserted at creation (`Arbiter.Accounts.Fields`)"},
    "identity_source" => {:internal, "set by the credential attach / login flows, never typed"},
    "identity_verified_at" => {:internal, "set by identity verification, never typed"},
    "merged_into_id" => {:internal, "written by the typed merge operation (`arb account merge`)"}
  },
  "dispatch" => %{
    "task_id" => %{mcp: :same, cli: "positional", rest: :same},
    "repo" => %{mcp: :same, cli: "positional", rest: :same},
    "model" => :same,
    "provider" => :same,
    "with_claude" => :same,
    "with_gemini" => :same,
    "no_agent" => :same,
    "force" => :same,
    "over_cap" => :same,
    "force_quota" => :same,
    "force_quota_reason" => :same,
    "workspace" => %{
      mcp: :same,
      cli: {:none, "the CLI resolves the workspace from its binding, not a dispatch flag"},
      rest: {:none, "REST resolves the workspace from the token / task, not a dispatch field"}
    }
  }
}
