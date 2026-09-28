defmodule Arbiter.Messages.EscalationKind do
  @moduledoc """
  The typed identity of an escalation (ticket lifecycle 6/13, bd-8if9zt).

  An escalation used to be told apart from every other escalation only by its
  subject text, so a reworded subject was a new escalation and nothing could
  say which ones belonged to a ticket's current trouble. Every `:escalation`
  message now carries one of these kinds in `Message.escalation_kind`, and the
  resource refuses an escalation without one.

  ## Scope

    * **`:ticket`** — about one ticket (`task_ref`). Deduplicated by
      `(kind, ticket)`: while one is open, raising the same kind for the same
      ticket again refreshes that item instead of adding a second
      (`Arbiter.Messages.Escalation.post/1`). Resolved automatically when the
      ticket's state moves on or its run restarts
      (`Arbiter.Tasks.Attention.clear/2`).
    * **`:system`** — about the installation, not a ticket: credentials, quota,
      budget, the circuit breaker, the loop — and PRPatrol's failed
      follow-up dispatch, which is about a repo's config: its `task_ref` is a
      follow-up the patrol closes at once so the next tick can retry, and
      that close must not resolve the page. Typed here; their own lifecycle
      (clearing when the condition clears) is child 8 (bd-7gt8rm). Their
      producers keep their own dedupe.

  `:agent_raised` is what an agent or a person sends by hand (`arb message`,
  the MCP `message_send` tool, `POST /api/messages`). It is ticket-scoped, so
  it resolves with its ticket, but never deduplicated: two hand-written
  escalations are two different things to say. `:legacy` is an escalation
  written before kinds existed (the bd-8if9zt migration's backfill); it is
  treated the same way.

  ## Causes

  Some ticket-scoped kinds also record why the ticket needs attention
  (`Issue.attention_cause`), per `cause/1`; the others are reports about a
  ticket that leave its attention alone.
  """

  @ticket_kinds [
    :agent_raised,
    :approved_awaiting_merge,
    :auto_merge_stalled,
    :auto_resume_exhausted,
    :awaiting_verification,
    :commit_gate,
    :conflict_unresolved,
    :dispatch_stuck,
    :fix_rounds_exhausted,
    :legacy,
    :merge_block_unresolved,
    :merge_blocked,
    :merge_conflict,
    :merge_failed,
    :merge_park_heartbeat,
    :notes_gate,
    :orphaned_merge_abandoned,
    :pr_author_replied,
    :pr_closed,
    :preflight_failed,
    :provider_fallback,
    :report_only_review,
    :review_cap_reached,
    :review_coverage_write_failed,
    :review_gate_findings,
    :review_loop,
    :review_parked,
    :spawn_failed,
    :ticket_stuck,
    :tracker_sync_failed,
    :transcript_capture_failed,
    :watchdog_startup_failed,
    :worker_stopped
  ]

  @system_kinds [
    :budget_exceeded,
    :circuit_breaker_tripped,
    :credential_expired,
    :credential_restored,
    :loop_canary,
    :loop_proposal,
    :operator_login_lapsed,
    :overage_alert,
    :pr_patrol_dispatch_failed,
    :quota_grant_failing,
    :quota_poll_failing,
    :review_patrol_rate_limited,
    :setup_token_missing
  ]

  @undeduped [:agent_raised, :legacy]

  # The attention cause a kind records on its ticket. A kind absent here is a
  # report about the ticket that does not change what the ticket waits on —
  # or, like `:awaiting_verification`, one whose transition (`:await_verification`)
  # already recorded the cause.
  @causes %{
    approved_awaiting_merge: :awaiting_manual_merge,
    auto_merge_stalled: :merge_blocked,
    auto_resume_exhausted: :run_crashed,
    conflict_unresolved: :merge_blocked,
    merge_block_unresolved: :merge_blocked,
    merge_blocked: :merge_blocked,
    merge_conflict: :merge_blocked,
    merge_failed: :merge_blocked,
    merge_park_heartbeat: :merge_blocked,
    orphaned_merge_abandoned: :merge_blocked,
    pr_closed: :pr_closed,
    spawn_failed: :run_crashed,
    ticket_stuck: :run_crashed,
    worker_stopped: :run_crashed
  }

  @type t :: atom()

  @doc "Every escalation kind."
  @spec all() :: [t()]
  def all, do: @ticket_kinds ++ @system_kinds

  @doc "The kinds about one ticket."
  @spec ticket_kinds() :: [t()]
  def ticket_kinds, do: @ticket_kinds

  @doc "The kinds about the installation rather than a ticket."
  @spec system_kinds() :: [t()]
  def system_kinds, do: @system_kinds

  @doc "`:ticket` or `:system`; nil for an unknown kind."
  @spec scope(term()) :: :ticket | :system | nil
  def scope(kind) when kind in @ticket_kinds, do: :ticket
  def scope(kind) when kind in @system_kinds, do: :system
  def scope(_), do: nil

  @doc "Whether a kind is one of these."
  @spec valid?(term()) :: boolean()
  def valid?(kind), do: scope(kind) != nil

  @doc """
  Whether raising `kind` again for the same ticket folds into the open item
  (every ticket-scoped kind but `:agent_raised` and `:legacy`).
  """
  @spec deduped?(t()) :: boolean()
  def deduped?(kind), do: scope(kind) == :ticket and kind not in @undeduped

  @doc "The attention cause `kind` records on its ticket, or nil."
  @spec cause(t()) :: atom() | nil
  def cause(kind), do: Map.get(@causes, kind)
end
