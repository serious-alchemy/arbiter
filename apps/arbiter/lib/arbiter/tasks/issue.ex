defmodule Arbiter.Tasks.Issue do
  @moduledoc """
  An Issue is a unit of work in the task ledger. Equivalent to a bd "task" in the
  Go implementation: title, description, lifecycle state, priority, dependencies, audit trail,
  optional external-tracker reference.

  IDs are human-friendly strings: `"{workspace.prefix}-{short_id}"`, e.g. `"bd-3o8"`,
  `"apex-AX17575"`. The short_id is a 6-char base36 random; collisions are
  negligible at our scale.

  ## Lifecycle state (bd-842qio)

  `state` is the ticket's one stored lifecycle state —
  `backlog | queued | active | merging | verifying | closed` — and only the
  named transition actions move it: `:promote`, `:demote`, `:start`,
  `:open_pr`, `:return_to_work`, `:await_verification`, `:close`, `:reopen`.
  The table lives in `Arbiter.Tasks.Lifecycle`; the model in
  `docs/design/ticket-lifecycle.md`. The legacy doors `:promote_to_ready` and
  `:return_to_backlog` apply `promote` / `demote`, and `:requeue` puts a
  stopped run's ticket back in the queue.

  Failure semantics of the two doors (P-13, D-T-27 — decided: document, do not
  unify). The **idempotent** `:promote_to_ready` / `:return_to_backlog` are the
  door for the API surfaces — REST (`POST /api/issues/:id/promote`, `/demote`),
  the MCP `ticket_promote` / `ticket_demote` tools and the CLI — where a retried
  or racing call (a script, an Autopilot tick that already promoted it) must
  not fail: promoting a ticket that is already `queued` or beyond, or demoting
  one already in `backlog`, is a no-op success. The **strict** `:promote` /
  `:demote` are the board's (`BoardLive`): a card the operator drags
  from a column it is no longer in means the board is stale, and the error is
  what tells the LiveView to reload. The two doors apply the same transition and
  the same guards (the acceptance-criteria gate on promote; `GuardDemote`'s
  live-worker / `verifying` / `closed` refusal on demote); they differ only in
  what a ticket already past the transition's source state gets — a no-op
  success or an error.

  `:update` accepts none of `state`, `close_reason` or `rank`. bd-36ytcl
  removed the legacy `status` and `refined` columns the transitions used to
  dual-write, and the ReviewGate park columns (the park is the ticket's
  attention cause).

  ## Post-merge verification (bd-9so315)

  A task flagged `verify_after_deploy: true` is one whose only execution context
  is the long-lived server — env/config plumbing, a doctor probe, a capture
  path. Merging it proves nothing: the running server still holds the old code.
  For those, the merge parks the task at `:verifying` (via
  `:await_verification`) instead of closing it, and the coordinator records a
  restart-and-observe result through `Arbiter.Tasks.Verification`:

    * `observed/2` → `verification_outcome: :observed` + evidence, then `:close`.
    * `failed/2`   → `verification_outcome: :failed` + evidence, then `:reopen`.

  The upstream tracker close is **not** deferred: it still happens at merge
  time, because the PR body's `Closes #N` keyword closes the upstream issue on
  merge regardless of what Arbiter does, and leaving the local record claiming
  otherwise is exactly the drift `Tasks.Claim`'s check exists to catch. A
  `failed/2` verification reopens the upstream issue along with the task.

  ## Rich-content fields

  All Markdown: `description`, `acceptance`, `notes`, `qa_notes`, `deployment_notes`.
  Stored verbatim. Adapters (Tracker.Jira etc., gte-029) convert to the external
  format (ADF for Jira, native Markdown for Linear/GitHub) at write-time.

  ## External tracker

  `tracker_type` defaults to the workspace's tracker.type (from `Workspace.config`),
  falling back to `:none` if the workspace doesn't specify one. Override per-task by
  passing `tracker_type:` to the create action.

  A task created with a `parent_id` whose parent is tracker-linked defaults from
  the parent instead (#1973), per the workspace's `tracker.child_policy`: by
  default it stays local (`tracker_type: :none`) and copies the parent's ticket
  into `tracker_context_type`/`tracker_context_ref`, so no ticket is minted. See
  `Arbiter.Tasks.Issue.Changes.InheritTrackerType`.

  The ticket key a task's branch name and conventional-commit PR title carry is
  `tracker_ref` when set, else `tracker_context_ref` (see
  `Arbiter.Worker.BranchNamer` and `Arbiter.Mergers.PRTitle`).

  ## Audit

  Via `AshPaperTrail.Resource` extension. Every create / update / close / reopen
  produces a paper-trail version row capturing the diff + actor.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Tasks,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshPaperTrail.Resource]

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Issue.Changes.Transition
  alias Arbiter.Tasks.Lifecycle.Projection

  @lifecycle_states Arbiter.Tasks.Lifecycle.states()
  @close_reasons Arbiter.Tasks.Lifecycle.close_reasons()
  @attention_causes Arbiter.Tasks.Lifecycle.Attention.causes()

  # bd-9s9dqz: the two no-PR types. Neither provisions a worktree, runs the
  # commit gate or ReviewGate, or enters Merging — a ticket of either goes
  # active → closed (or → verifying) directly. They differ only in the
  # deliverable: `:research` must leave a findings write-up in `notes` (the
  # notes gate), `:task` is an operational action that completes when the agent
  # reports it done. Both are forbidden for code work.
  @no_pr_types ~w(task research)a
  @findings_types ~w(research)a

  # bd-7mbrlg: `task`, `research`, `decision`, and `epic` never open a PR, so ReviewGate's
  # criteria guards (`:unmet_criteria` / `:missing_criteria`) never score them
  # — no point gating promotion on ACs they can't use. `bug`/`feature`/`chore`
  # are the reviewable, PR-producing types those guards actually score.
  @gated_issue_types ~w(bug feature chore)a

  # An epic is a rollup of children, never a unit a worker can be handed
  # directly. `Arbiter.Board.Snapshot` reads this same list rather
  # than redeclaring it — see `non_dispatchable_types/0`.
  @non_dispatchable_types ~w(epic)a

  sqlite do
    table "issues"
    repo Arbiter.Repo

    references do
      reference :workspace, on_delete: :restrict
    end
  end

  paper_trail do
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    store_action_inputs?(true)
    ignore_attributes([:created_at, :updated_at])

    # bd-6i7yzq: who acted (`Arbiter.Actor` label) — explicit `actor:` or the
    # process's ambient actor, stamped by `Arbiter.PaperTrail.StampActor`.
    metadata :actor, :string, allow_nil?: true

    # bd-741sid: the Watchdog's poll, every interval for every open PR. The
    # ticket keeps the latest answer; a version row per poll is not history.
    ignore_actions([:record_merger_status])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :title,
        :description,
        :acceptance,
        :notes,
        :qa_notes,
        :deployment_notes,
        :priority,
        :difficulty,
        :issue_type,
        :auto_close,
        :tracker_type,
        :tracker_ref,
        :tracker_context_type,
        :tracker_context_ref,
        :source_pr,
        :target_branch,
        :repo,
        :workspace_id,
        :verify_after_deploy,
        # ReviewPatrol engagement fields (bd-2ovun1): let a review_only
        # engagement be created atomically with its baseline/cursor + automation
        # mode, so ExternalReview doesn't have to create-then-update (which could
        # leave a half-formed, un-deduplicatable engagement on a failure). All
        # default to the non-engagement values, so normal task creation is
        # unaffected.
        :review_only,
        :last_reviewed_sha,
        :last_seen_comment_id,
        :review_automation,
        :posted_findings,
        # Seeds the loop-signature circuit breaker (bd-1atwts) with the
        # verdict ExternalReview's first pass POSTED, if any — otherwise
        # both breaker arms are blind to the initial verdict for the whole
        # window until ReviewPatrol's first re-review. Left nil for a
        # report-only first pass, which posts nothing.
        :last_verdict,
        :last_verdict_sha,
        :skills,
        :provider_constraint
      ]

      # `review_count` / `review_cap_escalated` / `circuit_breaker_tripped` /
      # `circuit_breaker_reason` / `circuit_breaker_cleared_sha` are
      # deliberately NOT create-accepted: they default to their non-tripped
      # values (0 / false / nil) for a brand-new engagement, and are only ever
      # advanced by ReviewPatrol's own :update calls.

      # Opt-out for `arb create --no-tracker` / `--local-only`. When true, the
      # CreateUpstream hook skips the outbound-create call even when the
      # workspace has a tracker configured.
      argument :skip_upstream_create, :boolean, default: false

      # #1973: the parent this task is being filed under. Informs the tracker
      # default only — a child of a tracker-linked parent defaults from the
      # parent's linkage instead of minting its own ticket (see
      # `InheritTrackerType`). The caller still attaches the `parent_of` edge
      # itself (`ticket_create`, `POST /api/dependencies`).
      argument :parent_id, :string, allow_nil?: true

      # #1973: overrides the workspace's `tracker.child_policy` for this create.
      # A refine session passes `:context_only` — it is by definition
      # decomposing an already-tracked issue.
      argument :tracker_child_policy, :atom do
        allow_nil? true
        constraints one_of: [:context_only, :inherit_parent, :mint]
      end

      change {Arbiter.Tasks.Issue.Changes.GenerateId, []}

      # bd-842qio: `state` is deliberately not create-accepted — every ticket
      # is born `:backlog` (the attribute default) and leaves only through a
      # transition. `rank` puts it at the end of its workspace's order.
      change {Arbiter.Tasks.Issue.Changes.AssignRank, []}
      change {Arbiter.Tasks.Issue.Changes.InheritTrackerType, []}
      change {Arbiter.Tasks.Issue.Changes.NormalizeProviderConstraint, []}

      # bd-9dwbvt: bind a repo at creation time — explicit, else the
      # workspace's only repo, else its `default_repo`, else a validation
      # error naming the configured keys. Every creation path lands here.
      change {Arbiter.Tasks.Issue.Changes.ResolveRepo, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:created, issue)
               {:ok, issue}
             end)

      # Mirror the new task into the workspace's configured tracker. Runs in
      # after_transaction so the task is committed first — an upstream
      # failure surfaces as `{:error, %{kind: :upstream_create_failed, ...}}`
      # to the caller but leaves the task intact.
      change {Arbiter.Tasks.Issue.Changes.CreateUpstream, []}
    end

    update :update do
      primary? true

      accept [
        :title,
        :description,
        :acceptance,
        :notes,
        :qa_notes,
        :deployment_notes,
        :priority,
        :difficulty,
        :issue_type,
        :auto_close,
        :verify_after_deploy,
        :tracker_type,
        :tracker_ref,
        :tracker_context_type,
        :tracker_context_ref,
        :pr_ref,
        :pr_body,
        :pr_opened_notified_ref,
        :pr_opened_transitioned_ref,
        :target_branch,
        :repo,
        :review_only,
        :last_reviewed_sha,
        :last_seen_comment_id,
        :review_automation,
        :last_reviewed_at,
        :posted_findings,
        :settled_threads,
        :review_count,
        :review_cap_escalated,
        :last_verdict,
        :last_verdict_sha,
        :circuit_breaker_tripped,
        :circuit_breaker_reason,
        :circuit_breaker_sha,
        :skills,
        :provider_constraint
      ]

      require_atomic? false

      # Audit-only attribution (bd-9j2g3x). `Issue` has no `actor` column to
      # snapshot the way `Skill` / `Workspace` do, but `store_action_inputs?` in
      # the `paper_trail` block above records every present argument onto the
      # version row — so a non-human write can name itself here (the loop's
      # apply path passes `"loop:proposal:<id>"`) and the version history says
      # which queued proposal moved the field. Changes nothing about the update
      # itself; a caller that omits it is recorded exactly as before.
      argument :change_origin, :string

      # P-08 (D-T-19): server-side atomic append to `notes`, so `--append-notes`
      # is not a client read-modify-write. Mutually exclusive with `notes`.
      argument :append_notes, :string

      # `source_pr` is deliberately NOT in `accept` above: it's the PR-dedup
      # linkage PRPatrol/ExternalReview set at :create time (and :reopen clears
      # it), and no legitimate caller of :update ever needs to touch it. A
      # generic partial-update path (e.g. `ticket_update`, which has no
      # `source_pr` parameter at all) must never be able to null it out from
      # under PRPatrol's `deduped?/2` check — see bd-ag9pq3.

      # bd-842qio: `state`, `close_reason` and `rank` are not in `accept`, so
      # this action refuses them outright — the named transitions move a
      # ticket.

      # Watermark the head SHA on a circuit-breaker resume so the breaker
      # doesn't immediately re-trip on the next tick (bd-1atwts).
      change {Arbiter.Tasks.Issue.Changes.RecordCircuitBreakerClear, []}
      change {Arbiter.Tasks.Issue.Changes.NormalizeProviderConstraint, []}
      change {Arbiter.Tasks.Issue.Changes.AppendNotes, []}

      # A floor only means something on an epic: retyping one away clears it.
      change {Arbiter.Tasks.Issue.Changes.ClearFloorOnRetype, []}

      # Propagate title/description changes to the linked external tracker.
      # Best-effort; no-op when neither field changed or no tracker.
      change {Arbiter.Tasks.Issue.Changes.SyncFields, []}

      change after_action(fn changeset, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)

               # An epic retyped away from `:epic` no longer matches the
               # `:epic` check in `broadcast_lifecycle/2`, but the epic
               # badge still has to drop it (bd-cixhhs).
               if Map.get(changeset.data, :issue_type) == :epic and issue.issue_type != :epic do
                 Phoenix.PubSub.broadcast(
                   Arbiter.PubSub,
                   Arbiter.Tasks.Issue.epics_topic(),
                   {:epic_lifecycle, :updated, issue}
                 )
               end

               {:ok, issue}
             end)

      # Switching `auto_close` on is itself a rollup trigger (bd-4i7kky). The
      # flag is otherwise only re-evaluated when a child closes or an edge is
      # written, so an epic whose children had *all* already closed stayed open
      # when `auto_close` was set afterwards — until someone closed it by hand.
      # Post-commit, like the `:close` rollup, so the close runs in its own
      # transaction.
      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          changeset, {:ok, issue} ->
            if issue.auto_close and Ash.Changeset.changing_attribute?(changeset, :auto_close) do
              {:ok, Arbiter.Tasks.Issue.maybe_auto_close(issue)}
            else
              {:ok, issue}
            end

          _changeset, error ->
            error
        end)
      end
    end

    # bd-9so315 — post-merge verification.
    #
    # The merge succeeded but the change's only execution context is the
    # long-lived server, so nothing has actually run the new code yet. Park the
    # task here instead of closing it: the worker/worktree teardown still runs
    # (the work IS done), the coordinator is notified, and the task only leaves
    # this state through `Arbiter.Tasks.Verification`.
    #
    # The `await_verification` transition (bd-842qio): active | merging →
    # verifying. A ticket still sitting in the queue has nothing merged to
    # verify; `Tasks.Verification.finalize_merged/2` walks a queued ticket
    # through `start` first.
    update :await_verification do
      require_atomic? false

      change {Transition, transition: :await_verification}
      change set_attribute(:awaiting_verification_at, &DateTime.utc_now/0)

      # A re-entry (a `failed/2` verification reopened the task, it was worked
      # again and merged again) must not inherit the previous round's verdict.
      change set_attribute(:verification_outcome, nil)
      change set_attribute(:verification_evidence, nil)

      # bd-a370ak: the PR merged, so there is no merge left to retry.
      change set_attribute(:pending_merge, nil)

      # bd-8if9zt: the transition cleared the earlier cause (a merged PR
      # answers any `pr_closed` or `merge_blocked`); the ticket now waits on its
      # restart-and-observe.
      change set_attribute(:attention_cause, :awaiting_verification)
      change set_attribute(:attention_since, &DateTime.utc_now/0)
      change {Arbiter.Tasks.Issue.Changes.AnnounceAttention, []}
      change {Arbiter.Tasks.Issue.Changes.RecordAttentionSpan, []}

      # Same teardown as `:close`: the worker finished and its PR merged, so
      # leaving the agent + worktree alive for the whole verification window
      # would pin a slot and leak a checkout. All best-effort.
      #
      # bd-9iv4qd: this transition only ever follows a merge, so the task's
      # local branch is reaped with the worktree.
      change {Arbiter.Tasks.Issue.Changes.StopWorker, []}
      change {Arbiter.Tasks.Issue.Changes.CleanupWorktree, merged: true}
      change {Arbiter.Tasks.Issue.Changes.DropDispatchHold, []}

      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, issue} ->
            Arbiter.Tasks.Issue.broadcast_lifecycle(:awaiting_verification, issue)
            {:ok, issue}

          _changeset, error ->
            error
        end)
      end
    end

    # Records the restart-and-observe verdict + its evidence. Makes NO state
    # change of its own — `Arbiter.Tasks.Verification` follows it with `:close`
    # (observed) or `:reopen` (failed), so the evidence is durable even if the
    # follow-on transition fails.
    update :record_verification do
      require_atomic? false
      accept [:verification_outcome, :verification_evidence]

      change {Arbiter.Tasks.Issue.Changes.GuardState, action: :record_verification}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # ---- review-gate park (bd-9zuvbh, design #1635 §5.3 class C) ----------
    #
    # A park is an attention cause, not a transition: the ticket keeps its
    # state so `Tasks.Claim`, the board and the dependency graph keep treating
    # it as live work, and `Dispatch.resume/2` can re-attach to the parked worker the
    # moment a human acts. That is the whole difference from `:failed` — the
    # work is intact and one decision away from merging, so nothing about it
    # should read as "this run did not happen".
    update :park_review do
      require_atomic? false

      # bd-8if9zt: the park reason is the ticket's attention cause — since
      # bd-36ytcl its only record (`Arbiter.Tasks.ReviewPark.park_reasons/0`).
      argument :cause, :atom do
        allow_nil? false
        constraints one_of: @attention_causes
      end

      change set_attribute(:attention_cause, arg(:cause))
      change set_attribute(:attention_detail, nil)
      change set_attribute(:attention_since, &DateTime.utc_now/0)
      change {Arbiter.Tasks.Issue.Changes.AnnounceAttention, []}
      change {Arbiter.Tasks.Issue.Changes.RecordAttentionSpan, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # The human action half of class C's terminal state: re-running the review
    # (or any other deliberate clearing) drops the park. `:close` clears it too,
    # inline, so a parked task that is simply abandoned does not leave a stale
    # entry in `arb prime`.
    update :clear_review_park do
      require_atomic? false

      # bd-8if9zt: the park is the ticket's attention cause, so clearing it
      # clears the cause and resolves the park's escalations.
      change {Arbiter.Tasks.Issue.Changes.ClearAttention, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # bd-a370ak / #2002: the durable pending-merge stamp. Written only through
    # `Arbiter.Mergers.PendingMerge`; deliberately no lifecycle broadcast — the
    # Watchdog writes it from its poll loop and nothing renders it live.
    update :set_pending_merge do
      require_atomic? false
      accept [:pending_merge]
    end

    # bd-40pzpj: the implementer account/family provider routing picked at the
    # task's first routed dispatch. Written only by
    # `Arbiter.Agents.ProviderRouting`; no lifecycle broadcast.
    update :pin_implementer do
      require_atomic? false
      accept [:implementer_account_id, :implementer_family]
    end

    # bd-a1ke2c: the reviewer-family pin, set at the task's first review pass
    # under `review_agent.cross_family`. Written only by
    # `Arbiter.Agents.ReviewerRouting`; no lifecycle broadcast.
    update :pin_reviewer do
      require_atomic? false
      accept [:reviewer_family]
    end

    # P-14: the typed way to clear a tripped ReviewPatrol circuit breaker
    # (bd-1atwts). No coordinator surface writes the raw `circuit_breaker_*`
    # fields through `:update` any more (`Arbiter.Tasks.IssueFields`); REST (`POST /api/issues/:id/resume_review`),
    # MCP (`ticket_resume_review`) and `arb ticket update --resume-review` all
    # land here. Idempotent: clearing an untripped breaker changes nothing.
    # `RecordCircuitBreakerClear` watermarks the head the breaker tripped at, so
    # the next ReviewPatrol tick does not re-trip on the very same commit.
    update :resume_review do
      require_atomic? false
      accept []

      change set_attribute(:circuit_breaker_tripped, false)
      change set_attribute(:circuit_breaker_reason, nil)
      change {Arbiter.Tasks.Issue.Changes.RecordCircuitBreakerClear, []}

      change after_action(fn _changeset, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # bd-djapyj: reorder a ticket inside its workspace's rank order — the
    # space `board/scheduler.ex` and `board/autopilot.ex` read (priority,
    # then rank, then age). `rank` is deliberately not in `:update`'s
    # accept list (see above); this is its one door in, alongside the CLI
    # (`arb ticket rank`), the API (`PATCH /api/issues/:id/rank`), and the MCP
    # `ticket_rank` tool. bd-79w1fs's drag-to-rank should call this action too
    # rather than writing `rank` directly.
    #
    # Exactly one of `position: :top`, `position: :bottom`, `before_id`, or
    # `after_id` must be given — `Changes.SetRank` rejects any other
    # combination, rejects a before/after target in a different workspace,
    # rejects a before/after target that is the ticket itself, and never
    # touches `priority`: ranking before/after a ticket in another priority
    # band only orders within rank, it does not move the ticket into that
    # band. Callers MUST go through `Arbiter.Tasks.Rank.move/2`, not this
    # action directly — see its moduledoc.
    update :set_rank do
      require_atomic? false
      accept []

      argument :position, :atom do
        allow_nil? true
        constraints one_of: [:top, :bottom]
      end

      argument :before_id, :string, allow_nil?: true
      argument :after_id, :string, allow_nil?: true

      # ES6: a board drag asks for the move to pin the card (`rank_pinned`).
      # The CLI, API and MCP rank doors don't, so they leave the pin as it was.
      argument :pin, :boolean, default: false

      change {Arbiter.Tasks.Issue.Changes.SetRank, []}
    end

    # ES6: pin or unpin a card without moving it. A board drag pins the cards
    # above the drop too (`ArbiterWeb.BoardLive`), so the order the operator
    # produced is the order the pinned-first sort reads back.
    update :set_rank_pinned do
      require_atomic? false
      accept []

      argument :pinned, :boolean, allow_nil?: false, default: true

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :rank_pinned,
          Ash.Changeset.get_argument(changeset, :pinned)
        )
      end
    end

    # ES2: the only writer of `floor_priority`. Epic-only, 1..3 or nil to
    # clear; `Changes.SetFloor` refuses a worker/refine-tier actor. The paper
    # trail records the action name and the new value.
    update :set_floor do
      require_atomic? false
      accept []

      argument :floor_priority, :integer do
        allow_nil? true
        constraints min: 1, max: 3
      end

      change {Arbiter.Tasks.Issue.Changes.SetFloor, []}

      change after_action(fn _changeset, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    update :close do
      require_atomic? false
      argument :reason, :string

      # bd-2wilou: defaults to true. A task with a `tracker_ref` used to leave
      # its upstream issue open unless the caller remembered to pass
      # `close_upstream: true` — a board sweep found five issues stranded this
      # way across three separate dates. `SyncTracker` already no-ops when
      # there's no tracker/`tracker_ref`, so flipping the default is a pure win
      # for every ordinary close path; a caller that must NOT propagate (e.g.
      # `MergedPRFinalizer`'s legacy follow-up close, where `tracker_ref` is
      # actually a merged PR number) now has to opt out explicitly with
      # `close_upstream: false`.
      argument :close_upstream, :boolean, default: true

      # bd-9iv4qd: the close is the ticket's PR merging. Set by
      # `Tasks.Verification.finalize_merged/2` (the funnel every merge path
      # closes through); `CleanupWorktree` then also reaps the task's local
      # branch, when nothing on it is held only locally.
      argument :pr_merged, :boolean, default: false

      # bd-842qio: how the ticket closed. Persisted to `close_reason`;
      # `:completed` when the caller gives none. `reason` above is the
      # free-text note for the audit trail, not this.
      argument :close_reason, :atom do
        allow_nil? true
        constraints one_of: @close_reasons
      end

      change {Transition, transition: :close}
      change set_attribute(:closed_at, &DateTime.utc_now/0)

      # bd-9zuvbh: closing is one of the two human actions that resolve a
      # ReviewGate park (the other is re-running the review). The transition
      # clears the park with the rest of the ticket's attention (bd-8if9zt),
      # so `arb prime`'s parked list stays free of tasks nobody needs to look
      # at.

      # bd-a370ak: a closed task has no merge left to retry.
      change set_attribute(:pending_merge, nil)

      # bd-bsco7f: persist what this close meant upstream, so the drift check
      # can read the intent instead of guessing it from `pr_ref`. Mirrors the
      # gate SyncTracker actually applies below: a review-only task never
      # touches the ticket it borrowed, whatever `close_upstream` says.
      change {Arbiter.Tasks.Issue.Changes.RecordCloseIntent, []}

      # Best-effort teardown: stop the task's worker (if any) and remove
      # its worktree (unless it holds work, which is saved to the notes).
      # Failures never fail the :close itself. Runs for every :close path —
      # CLI, Driver, MergeQueue, Watchdog, MergedPRFinalizer, the upstream-close
      # sync (bd-9iv4qd tests each).
      change {Arbiter.Tasks.Issue.Changes.StopWorker, []}
      change {Arbiter.Tasks.Issue.Changes.CleanupWorktree, []}
      change {Arbiter.Tasks.Issue.Changes.DropDispatchHold, []}

      # Propagate the close to the linked external tracker by default (see the
      # `close_upstream` argument above). Pass `close_upstream: false` to leave
      # the upstream issue open. Best-effort: a sync failure never fails the
      # local close.
      change {Arbiter.Tasks.Issue.Changes.SyncTracker, []}

      # After closing, roll the closure up to any auto-close parent of this task
      # (a `:parent_of` epic that should close once all its children are done),
      # then broadcast the closure. Both run via after_transaction (post-commit)
      # rather than after_action (pre-commit), so LiveView queries from separate
      # DB connections see the committed state and the dashboard updates
      # correctly when a directive is completed.
      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, issue} ->
            Arbiter.Tasks.Issue.maybe_auto_close_parents(issue)
            Arbiter.Tasks.Issue.broadcast_lifecycle(:closed, issue)
            {:ok, issue}

          _changeset, error ->
            error
        end)
      end
    end

    update :sync_upstream_close do
      require_atomic? false

      # No local state/closed_at change — this action exists solely to push
      # a close to the linked tracker for a task that's already `:closed`
      # locally but never synced upstream (e.g. it closed before the caller
      # thought to pass `close_upstream: true`). GuardState requires the
      # task to already be :closed; StopWorker/CleanupWorktree/the auto-close
      # rollup are all close-time side effects and deliberately do NOT run
      # here, since this isn't a transition.
      change {Arbiter.Tasks.Issue.Changes.GuardState, action: :sync_upstream_close}

      # bd-bsco7f: this action exists *only* to propagate a close upstream, so
      # the intent is unambiguous — record it. A legacy close that predates
      # `close_upstream_expected` becomes drift-visible once someone repairs it
      # this way and the ticket is still open afterwards. (A review-only task
      # still records `false` — SyncTracker below skips it, so nothing is
      # pushed and nothing should be claimed.)
      change {Arbiter.Tasks.Issue.Changes.RecordCloseIntent, forced: true}

      change {Arbiter.Tasks.Issue.Changes.SyncTracker, force: true}
    end

    # The `reopen` transition (bd-842qio): closed | verifying → queued. A
    # reopened ticket goes back into the queue (refined) whatever it was when
    # it closed, and the transition clears `close_reason`.
    update :reopen do
      require_atomic? false

      change {Transition, transition: :reopen}
      change set_attribute(:closed_at, nil)

      # bd-38l3px: a reopened task starts a FRESH attempt — the PR it opened in
      # its prior (now-closed) run is no longer its active PR. Leaving `pr_ref` /
      # `source_pr` populated lets `MergedPRFinalizer` re-detect that
      # already-merged PR on a later sweep and silently re-close the task every
      # reopen cycle (the query keys on `pr_ref`, independent of tracker_type).
      # Clearing them here severs the stale reference at the source so the next
      # dispatch opens a new PR and the finalizer never targets the wrong task.
      change set_attribute(:pr_ref, nil)
      change set_attribute(:source_pr, nil)

      # bd-a370ak: the reopened task's old PR is not a merge to retry.
      change set_attribute(:pending_merge, nil)

      # bd-741sid: nor is it a PR to watch, and its review is not the next
      # attempt's review.
      change set_attribute(:merger_url, nil)
      change set_attribute(:merger_status, nil)
      change set_attribute(:merger_checked_at, nil)
      change set_attribute(:merge_watch, nil)
      change set_attribute(:review_gate_state, nil)

      # bd-bqlwjo: a new PR opened after this reopen must still get its own
      # "opened a pull request" comment even though the ticket row itself
      # persists across the cycle — clear the last-announced ref alongside
      # `pr_ref` rather than relying on the (very likely, but not guaranteed)
      # new PR having a different URL.
      change set_attribute(:pr_opened_notified_ref, nil)
      change set_attribute(:pr_opened_transitioned_ref, nil)

      # bd-bsco7f: same reasoning for the recorded close intent — it describes a
      # close that no longer stands. The next close records its own.
      change set_attribute(:close_upstream_expected, nil)

      # Propagate the reopen to the linked external tracker (reopens the GitHub
      # issue, etc.). Best-effort: a sync failure never fails the local reopen.
      change {Arbiter.Tasks.Issue.Changes.SyncTracker, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:reopened, issue)
               {:ok, issue}
             end)
    end

    # bd-b5wyjd: refinement is done — move the card from Backlog to Ready.
    #
    # Its own action rather than a field in `:update`'s accept list, for the
    # same reason `:close` is: promotion is a decision with a name, and a
    # named action is what the paper_trail version row records. No generic
    # partial-update path (`ticket_update`, the REST patch, the edit form) can
    # flip a card into the dispatch queue as a side effect of renaming it.
    #
    # No tracker sync, no worker: promotion has no other side effects.
    #
    # bd-842qio: this is the legacy door onto the `promote` transition
    # (backlog → queued), kept for the surfaces that call it by this name
    # (`arb promote`, MCP `ticket_promote`, the task page) until bd-6fkgvo moves
    # them. It keeps its promise of idempotency: a ticket anywhere but
    # `:backlog` is left exactly as it is instead of refused.
    update :promote_to_ready do
      require_atomic? false

      # bd-7mbrlg: reason an operator gives to promote a bug/feature/chore
      # with no acceptance criteria. Required (and persisted to
      # `acceptance_waived`) only when the issue is a gated type, has no
      # `acceptance`, and isn't D0 (auto-waived) — see
      # `Changes.RequireAcceptanceCriteria`.
      argument :acceptance_waived, :string, allow_nil?: true

      change {Arbiter.Tasks.Issue.Changes.RequireAcceptanceCriteria, []}
      change {Transition, transition: :promote, idempotent: true}
      change {Arbiter.Tasks.Issue.Changes.RankOnPromote, []}

      # `after_transaction` (post-commit), not `after_action`: bd-cvfjms's
      # `Arbiter.Sessions.RefineLifecycle` reacts to this broadcast from a
      # separate process/connection to end the bound refine session, and
      # writes a fallback summary onto this same issue row if the agent left
      # `notes` blank. Reading (and writing) that row from a separate
      # connection before this transaction commits is exactly the race
      # `:close`'s own `after_transaction` above exists to avoid.
      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, issue} ->
            Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
            {:ok, issue}

          _changeset, error ->
            error
        end)
      end
    end

    # Inverse of `:promote_to_ready` — move a card from Ready back to Backlog.
    #
    # bd-a1bmyx: refinement is complete but the task was returned — move it back
    # to Backlog so it can be re-refined if needed. The same reasons apply as
    # `:promote_to_ready`: a named action (not a generic update), idempotent
    # (demoting an already-backlog card is a no-op).
    #
    # Refuses if the task has a live worker (demoting would orphan it) or if it
    # is in a state where demotion is unsafe (verifying, closed).
    # bd-2098: an active or merging task whose worker already stopped is
    # demoted too, in the same single write.
    #
    # bd-842qio: the legacy door onto the `demote` transition, idempotent on a
    # ticket already in `:backlog`, like `:promote_to_ready` above.
    update :return_to_backlog do
      require_atomic? false

      change {Arbiter.Tasks.Issue.Changes.GuardDemote, []}
      change {Transition, transition: :demote, idempotent: true}

      # Broadcast the demotion event, same pattern as `:promote_to_ready`.
      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, issue} ->
            Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
            {:ok, issue}

          _changeset, error ->
            error
        end)
      end
    end

    # ---- lifecycle transitions (bd-842qio) ---------------------------------
    #
    # The rest of the table. `:await_verification`, `:close` and `:reopen`
    # above are transitions too; `Arbiter.Tasks.Lifecycle` has the whole
    # table and `Changes.Transition` checks it.

    # backlog → queued. The same acceptance-criteria gate as
    # `:promote_to_ready`, but strict: promoting a ticket that is not in the
    # backlog is an error, not a no-op.
    update :promote do
      require_atomic? false

      argument :acceptance_waived, :string, allow_nil?: true

      change {Arbiter.Tasks.Issue.Changes.RequireAcceptanceCriteria, []}
      change {Transition, transition: :promote}
      change {Arbiter.Tasks.Issue.Changes.RankOnPromote, []}

      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, issue} ->
            Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
            {:ok, issue}

          _changeset, error ->
            error
        end)
      end
    end

    # queued | active | merging → backlog, with `:return_to_backlog`'s
    # live-worker refusal.
    update :demote do
      require_atomic? false

      change {Arbiter.Tasks.Issue.Changes.GuardDemote, []}
      change {Transition, transition: :demote}

      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          _changeset, {:ok, issue} ->
            Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
            {:ok, issue}

          _changeset, error ->
            error
        end)
      end
    end

    # backlog | queued → active: a dispatch took the ticket (`Worker.Dispatch`;
    # from Backlog only with `--force`).
    update :start do
      require_atomic? false

      # bd-6xaaam: a review dispatch stamps `review_only` in the same write,
      # so `SyncTracker` below leaves a tracker issue it does not own alone.
      accept [:review_only]

      change {Transition, transition: :start}

      # open → in_progress upstream.
      change {Arbiter.Tasks.Issue.Changes.SyncTracker, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # active | merging → queued (bd-36ytcl): the ticket's run stopped without
    # finishing and it goes back to the Ready queue — `Worker.AuthDeath` after
    # an auth failure.
    update :requeue do
      require_atomic? false

      change {Transition, transition: :requeue}

      # in_progress → open upstream.
      change {Arbiter.Tasks.Issue.Changes.SyncTracker, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # active → merging: the worker opened (or adopted) its PR. Records the ref
    # in the same write — it is what the MergeQueue adopts (bd-7b46wd) — and,
    # since bd-741sid, the PR's URL and the lane its Watchdog watches it on. A
    # PR open again is the answer to an earlier `pr_closed`.
    update :open_pr do
      require_atomic? false
      accept [:pr_ref, :merger_url, :merge_watch]

      change {Transition, transition: :open_pr}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # The same PR record without a transition: a ticket already `:merging` that
    # re-adopts its PR, or the ReviewGate's pre-review open while the ticket is
    # still at work (bd-129xh4).
    update :record_pr do
      require_atomic? false
      accept [:pr_ref, :merger_url, :merge_watch]

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # bd-741sid: the Watchdog's poll. Deliberately no `"tasks"` broadcast — it
    # lands every poll interval for every open PR, and the scheduler replans on
    # that topic; `Arbiter.Tasks.PullRequest` broadcasts it on its own topic.
    # Nor is a poll an edit: `merger_checked_at` says when it was read, and
    # `updated_at` keeps saying when the ticket last changed.
    update :record_merger_status do
      require_atomic? false
      accept [:merger_status, :merger_checked_at]

      change atomic_update(:updated_at, expr(updated_at))
    end

    # bd-741sid: the Watchdog's lane, rewritten when its reviewed-SHA baseline
    # moves. No broadcast, like `:record_merger_status`.
    update :record_merge_watch do
      require_atomic? false
      accept [:merge_watch]
    end

    # bd-741sid: the ReviewGate round state. No broadcast.
    update :record_review_gate do
      require_atomic? false
      accept [:review_gate_state]
    end

    # merging → active: a CI fix pass or a conflict resolver took the ticket
    # back to work (`MergeQueue.FixPassDispatcher`, `.ConflictResolver`).
    update :return_to_work do
      require_atomic? false

      change {Transition, transition: :return_to_work}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # bd-741sid: the ticket's PR was closed without merging. A `:merging`
    # ticket goes back to work (`return_to_work`); one already `:active` — a
    # fix pass was running when the PR closed — stays where it is. Either way it
    # carries the `pr_closed` attention cause, for a person to decide.
    update :pr_closed do
      require_atomic? false
      argument :detail, :string, allow_nil?: true

      change {Transition, transition: :return_to_work, idempotent: true}
      change set_attribute(:attention_cause, :pr_closed)
      change set_attribute(:attention_detail, arg(:detail))
      change set_attribute(:attention_since, &DateTime.utc_now/0)
      change {Arbiter.Tasks.Issue.Changes.AnnounceAttention, []}
      change {Arbiter.Tasks.Issue.Changes.RecordAttentionSpan, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # bd-8if9zt: record why the ticket needs attention, without a transition
    # (`Arbiter.Tasks.Attention.raise_cause/3`). Raising the cause the ticket
    # already carries keeps its `attention_since`, so a repeat does not reset
    # how long it has waited.
    update :raise_attention do
      require_atomic? false

      argument :cause, :atom do
        allow_nil? false
        constraints one_of: @attention_causes
      end

      argument :detail, :string, allow_nil?: true

      change fn changeset, _context ->
        cause = Ash.Changeset.get_argument(changeset, :cause)

        changeset
        |> Ash.Changeset.force_change_attribute(:attention_cause, cause)
        |> Ash.Changeset.force_change_attribute(
          :attention_detail,
          Ash.Changeset.get_argument(changeset, :detail)
        )
        |> then(fn cs ->
          if changeset.data.attention_cause == cause and changeset.data.attention_since,
            do: cs,
            else: Ash.Changeset.force_change_attribute(cs, :attention_since, DateTime.utc_now())
        end)
        |> then(fn cs ->
          # bd-8nlez1: a hand-off belongs to the cause it was made for; a
          # different cause starts back at the owner table's default.
          if changeset.data.attention_owner_cause in [nil, cause],
            do: cs,
            else:
              Ash.Changeset.force_change_attributes(cs, %{
                attention_owner: nil,
                attention_owner_cause: nil,
                attention_note: nil,
                attention_owner_since: nil
              })
        end)
      end

      change {Arbiter.Tasks.Issue.Changes.AnnounceAttention, []}
      change {Arbiter.Tasks.Issue.Changes.RecordAttentionSpan, []}

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # bd-8if9zt: the ticket's run restarted (`Arbiter.Tasks.Attention.clear/2`)
    # — whatever it waited on is being worked again. Clears the cause and the
    # legacy park columns, and resolves the ticket's escalations.
    update :clear_attention do
      require_atomic? false

      # bd-8nlez1: a resume out of a failed run is one more attempt at it,
      # counted for the `run_crashed` attempt limit (`AttentionSweep`).
      argument :resumed_from_failure, :boolean, allow_nil?: false, default: false

      change {Arbiter.Tasks.Issue.Changes.ClearAttention, []}

      change fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :resumed_from_failure) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :attention_resume_attempts,
            (changeset.data.attention_resume_attempts || 0) + 1
          )
        else
          changeset
        end
      end

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end

    # bd-8nlez1: move the ticket's attention to `owner` — the coordinator
    # handing it off to the operator with a note, the operator handing it back,
    # or an expired limit (`Arbiter.Tasks.Attention.hand_off/3`). The move
    # applies to `cause`, the attention the ticket has now, and goes when that
    # clears. A hand-back gives the coordinator a fresh clock and a fresh
    # attempt budget.
    update :set_attention_owner do
      require_atomic? false

      argument :owner, :atom do
        allow_nil? false
        constraints one_of: [:coordinator, :operator]
      end

      argument :cause, :atom do
        allow_nil? false
        constraints one_of: @attention_causes
      end

      argument :note, :string, allow_nil?: true

      change set_attribute(:attention_owner, arg(:owner))
      change set_attribute(:attention_owner_cause, arg(:cause))
      change set_attribute(:attention_note, arg(:note))
      change set_attribute(:attention_owner_since, &DateTime.utc_now/0)
      change {Arbiter.Tasks.Issue.Changes.RecordAttentionSpan, []}

      change fn changeset, _context ->
        if Ash.Changeset.get_argument(changeset, :owner) == :coordinator,
          do: Ash.Changeset.force_change_attribute(changeset, :attention_resume_attempts, 0),
          else: changeset
      end

      change after_action(fn _, issue, _ ->
               Arbiter.Tasks.Issue.broadcast_lifecycle(:updated, issue)
               {:ok, issue}
             end)
    end
  end

  changes do
    change Arbiter.PaperTrail.StampActor, on: [:create, :update, :destroy]
  end

  @epics_topic "tasks:epics"

  @doc """
  PubSub topic carrying only epic lifecycle events (as `{:epic_lifecycle, event, issue}`),
  plus an epic's retype away from `:epic`. Chrome that only needs the open-epic
  count subscribes here so it doesn't double-subscribe a page to `"tasks"`.
  """
  def epics_topic, do: @epics_topic

  @doc false
  def broadcast_lifecycle(event, issue)
      when event in [:created, :updated, :closed, :reopened, :awaiting_verification] do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, "tasks", {:task_lifecycle, event, issue})

    if Map.get(issue, :issue_type) == :epic do
      Phoenix.PubSub.broadcast(Arbiter.PubSub, @epics_topic, {:epic_lifecycle, event, issue})
    end

    if ws_id = Map.get(issue, :workspace_id) do
      Arbiter.Events.broadcast(
        ws_id,
        "task_state",
        issue
        |> event_lifecycle()
        |> Map.merge(%{
          task_id: Map.get(issue, :id),
          event: to_string(event),
          # bd-842qio: the stored lifecycle state. `close_reason` is null
          # unless the ticket is closed.
          state: to_string(Map.get(issue, :state) || ""),
          close_reason: close_reason_string(Map.get(issue, :close_reason))
        })
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp close_reason_string(nil), do: nil
  defp close_reason_string(reason), do: to_string(reason)

  # bd-6fkgvo: the ticket's column and attention, as every other surface reads
  # them. Projected from the row and its blockers only: this runs inside the
  # write, whose caller may be a worker, and reading the live runs would call
  # that worker back.
  defp event_lifecycle(issue) do
    view = Projection.view(issue, workers: [])

    %{
      column: view.column && to_string(view.column),
      attention: Projection.attention_payload(view.attention)
    }
  rescue
    _ -> %{column: nil, attention: nil}
  end

  attributes do
    attribute :id, :string do
      primary_key? true
      allow_nil? false
      public? true
      # Pattern allows uppercase to accommodate phase markers (gte-P1),
      # Apex-style mixed-case IDs from the Dolt import, AND legacy IDs
      # with underscores or multiple hyphens (e.g. `ac-access_control-merge_queue`,
      # `vs-server-worker-chrome`). Without that tolerance,
      # AshPaperTrail's Version row creation rejects those IDs and any
      # close/update on a legacy task fails. Newly generated IDs are
      # still tidy lowercase prefix-shortid (see Changes.GenerateId).
      constraints match: ~r/^[a-z][a-zA-Z0-9]*-[a-zA-Z0-9_-]+$/
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
    end

    attribute :description, :string do
      public? true
      default ""
      description "Markdown."
    end

    attribute :acceptance, :string do
      public? true
      default ""
      description "Markdown."
    end

    attribute :notes, :string do
      public? true
      default ""
      description "Markdown."
    end

    attribute :qa_notes, :string do
      public? true
      default ""
      description "Markdown. Synced to Jira's QA Testing Notes custom field via Tracker.Jira."
    end

    attribute :deployment_notes, :string do
      public? true
      default ""
      description "Markdown. Synced to Jira's Deployment Notes custom field via Tracker.Jira."
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :backlog
      constraints one_of: @lifecycle_states

      description """
      The ticket's stored lifecycle state (bd-842qio): backlog, queued, active,
      merging, verifying or closed. Changed only by the named transition
      actions — see `Arbiter.Tasks.Lifecycle`.
      """
    end

    attribute :close_reason, :atom do
      allow_nil? true
      public? true
      constraints one_of: @close_reasons

      description """
      How a closed ticket closed: completed, wont_do or duplicate. Set by the
      `close` transition (`:completed` when not given); nil whenever the ticket
      is not closed, so `reopen` clears it.
      """
    end

    attribute :rank, :integer do
      allow_nil? false
      public? true

      description """
      Manual order inside a priority band: Backlog and Ready sort by priority,
      then rank. A new ticket is ranked after every ticket in its workspace
      (`Changes.AssignRank`), and so is a ticket promoted to Ready
      (`Changes.RankOnPromote`): promotion order is dispatch order within a
      band. `:set_rank` reorders it afterwards.
      """
    end

    attribute :rank_pinned, :boolean do
      allow_nil? false
      public? true
      default false

      description """
      ES6 (`docs/design/epic-aware-scheduling.md` §4): an operator dragged this
      card inside its band, so it sorts first within that band, ahead of the
      finish-first tiebreak. Set only by `:set_rank` with `pin: true` and
      `:set_rank_pinned`, never by `:create` or `:update`. Cleared by promote,
      demote, close and reopen (`Changes.Transition`).
      """
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 2
      constraints min: 0, max: 4
      description "0 = P0 (highest), 4 = P4 (lowest). Default 2 (P2)."
    end

    attribute :difficulty, :integer do
      public? true
      # #1519: the ceiling is 5, not 4. The column is a plain integer with no
      # DB-level CHECK (see the initial_sqlite migration and the issues
      # resource snapshot), so widening the range is an Ash-validation change
      # only — no migration.
      constraints min: 0, max: 5

      description """
      How hard the task is (0..5 / D0..D5). Orthogonal to :priority.
      Drives provider-agnostic model/thinking routing via
      `Arbiter.Agents.Routing.ByDifficulty`. Nullable; routing treats
      `nil` as D2 (the default tier).

      D0 Trivial  — single-file, fully specified, no judgment.
      D1 Simple   — localized, clear approach, light reasoning.
      D2 Moderate — multi-file or some design choice (default).
      D3 Hard     — cross-cutting, non-obvious design, correctness-critical.
      D4 Extreme  — novel architecture, deep ambiguity, may warrant multi-pass.
      D5 Flagship — a deliberate escalation, never an ordinary rating: work
                    judged worth a full quota window on the flagship model.
                    Only an operator sets it, and only when D4's premium
                    model at max effort has already failed or is plainly
                    inadequate. "Harder than D4" is not a reason.
      """
    end

    attribute :issue_type, Arbiter.Extensions.RegisteredAtom do
      allow_nil? false
      public? true
      # bd-5lc99r: `:task` and `:research` (bd-9s9dqz split) are OPT-IN
      # non-reviewable types (`:research` — deliverable is a findings summary in
      # `notes`; `:task` — an operational action; neither has a commit/review/
      # PR). Because the catch-all creation paths (CLI `arb create` without
      # `--type`, tracker/GitHub sync in Tasks.Claim, the REST API, untyped MCP
      # creates) fall through to this default, it MUST be a reviewable type or
      # every untyped coding task would silently skip the worktree/commit/review
      # path. `:feature` is the generic reviewable default; choose `:task`
      # explicitly to get a non-reviewable workflow.
      default :feature
      constraints seam: :issue_type
    end

    attribute :floor_priority, :integer do
      public? true
      constraints min: 1, max: 3

      description """
      Epic priority floor (ES2, `docs/design/epic-aware-scheduling.md` §6.2).
      `nil` means no floor, so the schedule is exactly today's. 1..3 only: an
      incident (P0) must always beat a floor. Only an epic carries one, and it
      is set only by `:set_floor`, never by `:create` or `:update`; a board
      drag or `arb ticket update --priority` never sets it. The epic's own
      `priority` is unrelated and is not a scheduling input.
      """
    end

    attribute :auto_close, :boolean do
      allow_nil? false
      public? true
      default false

      description """
      When true, this task auto-closes once ALL of its `:parent_of` children
      are closed (and there is at least one child). This is the parent-with-
      progress flag that replaces the old Convoy `:system_managed` vs `:owned`
      lifecycle: `auto_close: true` ≈ system_managed, `false` ≈ owned (the user
      closes the parent explicitly). Default `false`.
      """
    end

    attribute :acceptance_waived, :string do
      public? true
      constraints trim?: true

      description """
      Reason an operator gave for promoting a `bug`/`feature`/`chore` to Ready
      without acceptance criteria (bd-7mbrlg). Set only by `:promote_to_ready`
      — see `Arbiter.Tasks.Issue.Changes.RequireAcceptanceCriteria`, which
      also auto-fills a standard reason for D0 (trivial) work. `nil` means no
      waiver was ever needed or given.
      """
    end

    attribute :tracker_type, Arbiter.Extensions.RegisteredAtom do
      allow_nil? false
      public? true
      default :none
      constraints seam: :tracker
    end

    attribute :tracker_ref, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "External tracker's ID for this task (e.g. \"AX-17585\" for Jira)."
    end

    attribute :tracker_context_type, Arbiter.Extensions.RegisteredAtom do
      allow_nil? true
      public? true
      constraints seam: :tracker

      description """
      Tracker type for a context-only reference (e.g. `:jira`) — on a review
      task, or on a child filed under a tracker-linked parent (#1973).
      Paired with `tracker_context_ref`. No claim semantics and never synced back
      to the tracker — used only to fetch acceptance criteria at dispatch time to
      give the reviewer the ticket's intent. Safe to use on coworker-owned tickets.
      """
    end

    attribute :tracker_context_ref, :string do
      allow_nil? true
      public? true
      constraints max_length: 255, trim?: true

      description """
      Tracker issue ref for context-only use on a review task (e.g. \"AX-18004\").
      Paired with `tracker_context_type`. The referenced ticket's description is
      fetched at dispatch and injected into the reviewer's prompt. No assignment
      check, no write-back (no state transition, no assignee change). When
      `tracker_ref` is blank it is also the ticket key in the branch name and
      conventional-commit PR title (#1973), so a context-only child of
      `VR-19083` still opens a `[VR-19083]` PR.
      """
    end

    attribute :pr_ref, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "PR/MR number opened for this task (e.g. \"123\"). Set by the merger when a PR is opened; distinct from tracker_ref which holds the originating issue ref."
    end

    # ---- the open PR's state (bd-741sid) ------------------------------------
    #
    # What a worker resident on its open PR used to hold in memory, so the
    # ticket's Watchdog can run — and be restarted — from this row alone.
    # Written through `Arbiter.Tasks.PullRequest`.

    attribute :merger_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 2048, trim?: true
      description "The clickable URL of `pr_ref`, from the adapter that opened it."
    end

    attribute :merger_status, :map do
      allow_nil? true
      public? true

      description """
      The forge's last answer about the PR, as the ticket's Watchdog last polled
      it: `status`, `approved`, `pipeline`, `block_reason`, `head_sha`, ... with
      string keys. Read it through `Arbiter.Tasks.PullRequest.merger_status/1`,
      which gives the atom-keyed map back.
      """
    end

    attribute :merger_checked_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the Watchdog last read `merger_status`."
    end

    attribute :merge_watch, :map do
      allow_nil? true
      public? false

      description """
      The lane the ticket's Watchdog watches the PR on: the adapter that opened
      it, whether the ReviewGate already approved it (`via_review_gate`), the
      head the run pushed (`local_head_sha`), the reviewed-SHA baseline the
      Watchdog latched (`reviewed_sha`), and any explicit merge/poll overrides.
      Everything `Arbiter.Worker.Watchdog.restart/1` needs besides the row's
      own `pr_ref`, `repo` and workspace.
      """
    end

    attribute :review_gate_state, :map do
      allow_nil? true
      public? false

      description """
      The ReviewGate round state for the ticket's current attempt: the branch
      and worktree under review, the pre-review PR, the round, the last
      verdict, the fix-round count and findings digest, and the merge options
      the author was dispatched with. Lets a verdict be applied to the ticket
      when no author worker is resident any more.
      """
    end

    # ---- attention (bd-741sid writes `pr_closed`; bd-8if9zt owns the rest) ---

    attribute :attention_cause, :atom do
      allow_nil? true
      public? true
      constraints one_of: @attention_causes

      description """
      Why the ticket needs attention, beside its state
      (`Arbiter.Tasks.Lifecycle.Attention` has the causes and who owns each).
      Set by a ReviewGate park, a closed PR, a blocked merge, a stopped run,
      and on entering verification; cleared whenever the ticket's state moves
      on or its run restarts (`Arbiter.Tasks.Attention.clear/2`).
      """
    end

    attribute :attention_detail, :string do
      allow_nil? true
      public? true
      description "What happened, in a sentence, for `attention_cause`."
    end

    attribute :attention_since, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When `attention_cause` was set."
    end

    # ---- attention ownership (bd-8nlez1) ------------------------------------

    attribute :attention_owner, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:coordinator, :operator]

      description """
      Who owns the ticket's attention when a hand-off, a hand-back or an
      expired limit moved it off the owner table's default
      (`Arbiter.Tasks.Lifecycle.Attention`). Applies only while the ticket's
      attention is `attention_owner_cause`; nil means the table decides.
      Cleared with the rest of the attention.
      """
    end

    attribute :attention_owner_cause, :atom do
      allow_nil? true
      public? true
      constraints one_of: @attention_causes
      description "The attention cause `attention_owner` was set for."
    end

    attribute :attention_note, :string do
      allow_nil? true
      public? true
      description "The hand-off note, or the limit that moved the attention to the operator."
    end

    attribute :attention_owner_since, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When `attention_owner` was last set."
    end

    attribute :attention_resume_attempts, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0

      description """
      How many times the ticket's run was resumed out of a failed run while
      the ticket stayed in its state. Reset by a transition and by a
      hand-back to the coordinator; read by the `run_crashed` attempt limit
      (`Arbiter.Tasks.AttentionSweep`).
      """
    end

    attribute :pr_opened_notified_ref, :string do
      allow_nil? true
      public? true
      constraints max_length: 2048, trim?: true

      description """
      The PR/MR URL `Arbiter.Trackers.Sync` last posted the "Arbiter opened a
      pull request for this ticket" comment for (bd-bqlwjo). A `:pr_opened`
      lifecycle event whose `pr_url` matches this value is a repeat run on the
      same PR — a ReviewGate implementation round, a `worker_resume`, or a
      re-open of an already-linked PR — and both the state transition and the
      comment/remote-link are skipped. Cleared implicitly by `reopen` clearing
      `pr_ref`, so a new PR after `ticket_reopen` gets its own comment even
      though the ticket itself is unchanged. Durable (not an ETS/process
      cache) so idempotency survives a server restart.
      """
    end

    attribute :pr_opened_transitioned_ref, :string do
      allow_nil? true
      public? true
      constraints max_length: 2048, trim?: true

      description """
      The PR/MR URL `Arbiter.Trackers.Sync` last successfully drove the
      `:pr_opened` state transition for (bd-bqlwjo). Tracked separately from
      `pr_opened_notified_ref`: the comment/remote-link is posted at most once
      per PR ref regardless of outcome (a repeat is a visible duplicate the
      user is showing us), but the state transition itself must keep
      retrying on the next run for the same PR ref until it actually lands —
      e.g. after a gated-fields escalation (blank qa_notes/deployment_notes)
      or a transient tracker failure on the first attempt. Set only when
      `transition_event/2` returns `:ok` for `:pr_opened`. Cleared alongside
      `pr_opened_notified_ref` by `reopen`.
      """
    end

    attribute :source_pr, :string do
      public? true
      constraints max_length: 255, trim?: true

      description """
      The PR/MR number this task was filed *in response to* (e.g. \"591\").
      Set by PRPatrol on a follow-up task so a second follow-up isn't filed for
      the same PR. Distinct from `tracker_ref` (the lifecycle write-back target,
      which a PRPatrol follow-up deliberately leaves unset / `tracker_type: :none`
      so it never tries to transition a merged PR) and from `pr_ref` (the PR this
      task's own work opens).
      """
    end

    attribute :pr_body, :string do
      public? true
      default ""

      description """
      Markdown. The worker-authored PR/MR description, written at completion
      (Summary / Test plan / References) reflecting the change that actually
      landed — and filling the repo's PR template when one exists. The MergeQueue
      opens the single canonical PR with this body, so the worker never opens
      its own PR. Distinct from `description` (the originating ticket spec).
      """
    end

    attribute :repo, :string do
      public? true
      constraints max_length: 255, trim?: true

      description """
      The repo this task belongs to, as a `repo_paths` key (e.g. "org/tonic").

      Resolved at creation by `Arbiter.Tasks.Issue.Changes.ResolveRepo` —
      explicit, else the workspace's only repo, else its `default_repo`, else
      the create is refused (bd-9dwbvt). Still nullable at the schema level:
      rows filed before that change (until
      `mix arbiter.backfill_issue_repos` runs), workspaces that configure no
      repos at all, and an operator deliberately clearing it on `:update` all
      leave it null, and dispatch keeps its old late resolution for those.

      When set, it is the default repo for every dispatch of this task — an
      explicit per-dispatch `repo:` opt still wins. See
      `Arbiter.Worker.Dispatch.resolve_repo_for_dispatch/2`.
      """
    end

    attribute :target_branch, :string do
      public? true
      constraints max_length: 255, trim?: true

      description """
      The branch this task's work is based on AND the PR merge target.
      Nullable; when unset the effective target is resolved from the repo's
      default, then the workspace's `merge.base`, then `"main"`.
      """
    end

    attribute :closed_at, :utc_datetime_usec do
      public? true
    end

    # ---- post-merge verification (bd-9so315) ------------------------------

    attribute :verify_after_deploy, :boolean do
      allow_nil? false
      public? true
      default false

      description """
      When true, merging this task's PR does NOT close it: the merge parks it
      at `:awaiting_verification` and notifies the coordinator to restart the
      server and observe the new path once.

      Set it for any change whose only execution context is the long-lived
      server — env/config plumbing, a `doctor` probe, a capture/ingest path,
      anything that "works" in tests but has never run in the live process.
      That class is the largest source of escaped defects (see the
      2026-09-13 follow-up-rate investigation): merged, auto-closed, and
      discovered broken ~8 hours later.

      Settable by the coordinator (`ticket_create` / `ticket_update`, `arb ticket
      create/update --verify-after-deploy`) and by a worker on its own task
      (`ticket_update_progress`) once it can see that its diff touches such a
      path.
      """
    end

    attribute :awaiting_verification_at, :utc_datetime_usec do
      allow_nil? true
      public? false

      description """
      When the task entered `:awaiting_verification`. The board's Waiting
      column and `arb prime` render the age of the wait from this. Written by
      `:await_verification`; left in place afterwards as a record of how long
      the verification took.
      """
    end

    attribute :verification_outcome, :atom do
      allow_nil? true
      public? false
      constraints one_of: [:observed, :failed]

      description """
      The recorded restart-and-observe verdict: `:observed` (the new path was
      seen working on the running server → the task closed) or `:failed` (it
      was not → the task reopened). `nil` before a verdict is recorded, and
      reset by a fresh `:await_verification`.
      """
    end

    attribute :verification_evidence, :string do
      allow_nil? true
      public? false

      description """
      The evidence text the coordinator recorded with the verdict — what was
      actually observed on the running server. Persisted verbatim so the
      claim "this is live and working" is auditable rather than remembered.
      """
    end

    attribute :close_upstream_expected, :boolean do
      allow_nil? true
      public? false

      description """
      bd-bsco7f: what this task's close *meant* for the linked tracker issue.

      `close_upstream` is an argument on `:close`, not an attribute — once the
      action returns, nothing on the record says whether the close was supposed
      to propagate upstream. That left `Tasks.Claim`'s drift check inferring
      intent from `pr_ref`'s presence, which silently misses the manual-close
      path: a `bug` fixed by hand (no PR) whose upstream close failed looked
      identical to a findings-only investigation that should leave its ticket
      open. This attribute records the answer at close time instead.

      Written by `:close` (from the `close_upstream` argument) and by
      `:sync_upstream_close` (which exists solely to push a close upstream, so
      the intent is unambiguously true). Either way a `review_only` task records
      `false`: SyncTracker skips review-only tasks on both paths, so no upstream
      close ever happens for one. Cleared by `:reopen`.

      `nil` means "closed before this was recorded" — for those rows the drift
      check still falls back to the `pr_ref` proxy. Not `public?`: it is a
      record of what an action did, never something a caller sets directly.
      """
    end

    attribute :review_only, :boolean do
      allow_nil? true
      public? true
      default false

      description """
      When true, this task was dispatched as a review-only directive (via
      `worker_review`). Review-only tasks must never mutate a linked tracker
      issue they don't own: no reassignment, no description sync, no state
      transition. SyncTracker, SyncFields, and the Driver's close-upstream
      logic all check this flag and skip any write-back when it is set.
      """
    end

    # ReviewPatrol engagement fields (bd-cw3w9p) —————————————————————————————

    attribute :last_reviewed_sha, :string do
      allow_nil? true
      public? true

      description "PR head SHA at our last posted review. Set by ReviewPatrol after each review cycle."
    end

    attribute :last_seen_comment_id, :string do
      allow_nil? true
      public? true
      description "High-watermark cursor for author replies (ReviewPatrol Phase 2)."
    end

    attribute :review_automation, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:auto, :report_only, :flag, :off]

      description """
      Engagement automation mode for ReviewPatrol:
        :auto        — re-review automatically on new commits AND post to the PR.
        :report_only — re-review on new commits but post NOTHING; report the
                       proposed comments to the coordinator to greenlight (infra
                       default, bd-36qzgx).
        :flag        — surface new commits / replies as a flag; do not review.
        :off         — hard opt-out (bd-7opdaf): never re-review, never post,
                       never flag. A worker_review dispatch that would resolve
                       to :off is refused up front unless force: true.
      Nullable; the effective default is resolved from workspace policy (task B).
      """
    end

    attribute :last_reviewed_at, :utc_datetime do
      allow_nil? true
      public? true

      description """
      Timestamp of our last posted re-review. ReviewPatrol's debounce cursor
      (bd-f3fg22): a new-commit re-review is suppressed while now - last_reviewed_at
      is inside the configured debounce window, so a burst of pushes yields at most
      one re-review per window.
      """
    end

    attribute :posted_findings, {:array, :map} do
      allow_nil? true
      public? true
      default []

      description """
      The findings ReviewPatrol has already posted on this engagement's PR — each a
      map with "file", "line", "message", and "severity" (bd-f3fg22). Two uses on a
      new-commit re-review: the relevance gate (only re-review when the new diff
      touches a file we previously flagged) and unchanged-finding de-dupe (never
      re-post a finding whose file/line/message we already posted).
      """
    end

    attribute :settled_threads, {:array, :map} do
      allow_nil? true
      public? true
      default []

      description """
      The review threads on this engagement's PR that are CLOSED — the author
      refuted our finding with cited evidence, we conceded it in-thread, or the
      thread was resolved (bd-cccjtn). Each entry is a map with "thread_id",
      "file", "line", "finding", "reason" ("we_conceded" | "resolved" |
      "author_refuted"), "author_reply", "reply_ids", "settled_at" and
      "settled_sha". "reply_ids" (bd-wtvu9r) is the per-finding refutation
      state: WHICH comment id(s) actually answered this finding — the author's
      cited-evidence reply, or our own conceding comment — so "every blocking
      finding has an author reply" is an auditable claim rather than a guess.

      Three uses on a re-review, all in `Arbiter.Workflows.ReviewPatrol.ThreadMemory`:
      the reviewer prompt carries the settled threads so it knows what is already
      answered, the check-runner wrapper DROPS any finding re-raised within a
      few lines of a settled thread unless the new commits actually touch those
      lines, and the circuit breaker's answered-findings arm (bd-wtvu9r) reads
      the finding -> reply-id join to decide whether another verdict round could
      contain anything but re-litigation. Persisting this matters because `list_open_review_threads/1` returns
      only UNRESOLVED threads — resolving a conceded thread would otherwise erase
      every trace that we conceded it.
      """
    end

    attribute :review_count, :integer do
      allow_nil? true
      public? true
      default 0

      description """
      Number of re-reviews ReviewPatrol has posted to this engagement's PR
      (bd-ahvk03). Incremented on each successful `:auto`-mode re-review;
      once it reaches the configured cap (`config["review_patrol"]["max_reviews"]`,
      then the `:review_patrol_max_reviews` app env, default 3) ReviewPatrol
      stops re-reviewing and escalates once instead of looping.
      """
    end

    attribute :review_cap_escalated, :boolean do
      allow_nil? true
      public? true
      default false

      description """
      Whether ReviewPatrol has already raised the review-cap escalation for
      this engagement (bd-ahvk03). Set on the first tick that hits the cap so
      the same PR isn't re-escalated every subsequent tick.
      """
    end

    attribute :last_verdict, :atom do
      allow_nil? true
      public? true
      constraints one_of: [:approve, :request_changes]

      description """
      The verdict (`:approve` or `:request_changes`) ReviewPatrol most recently
      POSTED to the PR (bd-1atwts). Paired with `last_verdict_sha` to detect a
      would-be repeat verdict on a commit we've already ruled on — one arm of
      the per-engagement circuit breaker.
      """
    end

    attribute :last_verdict_sha, :string do
      allow_nil? true
      public? true

      description """
      The PR head SHA `last_verdict` was posted against (bd-1atwts). If
      ReviewPatrol is ever about to post another verdict for this exact SHA —
      the "same-SHA verdict" loop signature — the circuit breaker trips instead
      of posting.
      """
    end

    attribute :circuit_breaker_tripped, :boolean do
      allow_nil? true
      public? true
      default false

      description """
      Whether ReviewPatrol's per-engagement circuit breaker has fired
      (bd-1atwts): a same-SHA repeat verdict, or an author re-request disputing
      a verdict we already posted for the current head with no new commits.
      While true, ReviewPatrol posts nothing further on this engagement — no
      verdicts, no re-reviews — until a human clears it. Mirrors
      `review_cap_escalated`'s one-way-trip shape, but for the loop signature
      rather than raw review volume.
      """
    end

    attribute :circuit_breaker_reason, :string do
      allow_nil? true
      public? true

      description """
      Human-readable reason the circuit breaker tripped (bd-1atwts), recorded
      alongside the coordinator escalation for later audit.
      """
    end

    attribute :circuit_breaker_sha, :string do
      allow_nil? true
      public? true

      description """
      The PR head SHA the circuit breaker last tripped AT (bd-wtvu9r). The two
      bd-1atwts arms only trip on an unchanged head, so for them this equals
      `last_verdict_sha`; the answered-findings arm trips on a head that has
      already moved past the verdicted commit, so the tripped head has to be
      recorded separately. `Arbiter.Tasks.Issue.Changes.RecordCircuitBreakerClear`
      prefers it over `last_verdict_sha` when watermarking a resume — otherwise
      a resume of that arm would watermark the older, wrong commit and the very
      next tick would re-trip.
      """
    end

    attribute :circuit_breaker_cleared_sha, :string do
      allow_nil? true
      public? true

      description """
      The PR head SHA in effect when a coordinator last cleared
      `circuit_breaker_tripped` (bd-1atwts). Merely clearing the flag restores
      the exact state that tripped it — neither the head nor `last_verdict` /
      `last_verdict_sha` move on a trip, since tripping deliberately posts
      nothing — so without this watermark the breaker arms re-trip on the
      very next tick. Set automatically (from `circuit_breaker_sha`, falling
      back to `last_verdict_sha`, at the moment of the clear) by the resume path in
      `Arbiter.Tasks.Issue.Changes.RecordCircuitBreakerClear`; both trip
      predicates in `Arbiter.Workflows.ReviewPatrol` treat `head ==
      circuit_breaker_cleared_sha` as "already adjudicated, don't re-trip".
      The watermark stops mattering once a new commit moves the head.
      """
    end

    # Per-task skill override — the task layer of the layered skill selection
    # (epic child 3, bd-d5hy7y). Skills are otherwise inherited from the
    # workspace + repo config layers; this map adjusts or replaces that set for
    # this one task. Recognised keys (all optional, string-keyed):
    #
    #   * `"opt_out" => true`      — this task gets NO skills at all (hard override).
    #   * `"only" => ["a", "b"]`   — replace the inherited set entirely with these.
    #   * `"add" => ["a"]`         — add skills on top of the inherited set.
    #   * `"remove" => ["b"]`      — remove skills from the inherited set (per-task opt-out of one skill).
    #   * `"activation" => %{"tdd" => "situational"}` — per-skill activation override for this task.
    #
    # An empty map (the default) means "inherit the workspace + repo layers
    # unchanged". Resolved at dispatch by `Arbiter.Skills.Selection`.
    attribute :skills, :map do
      allow_nil? true
      public? true
      default %{}

      description "Per-task skill selection override (opt_out/only/add/remove/activation); the task layer of layered skill selection."
    end

    # ---- pending merge (bd-a370ak / #2002) ----------------------------------

    attribute :implementer_account_id, :uuid do
      allow_nil? true
      public? true

      description """
      The provider account provider routing pinned this task's implementer to
      (bd-40pzpj), set at the first dispatch routed by
      `routing.provider_selection: most_quota`. Every implementer role —
      resumes, ReviewGate implementer rounds, CI fix passes, conflict
      resolvers — reuses it while it is available and falls back (recorded on
      the run) when it is not. `nil` when the task was never routed.
      """
    end

    attribute :implementer_family, :string do
      allow_nil? true
      public? true
      constraints max_length: 64, trim?: true

      description "Model family of the pinned implementer account (`Arbiter.Agents.ModelFamily`)."
    end

    attribute :provider_constraint, :map do
      allow_nil? true
      public? true

      description """
      Which providers may run this ticket's implementer (bd-13pqcp):
      `%{"require" => ["claude"]}` (only those) or `%{"exclude" => ["gemini"]}`
      (anything but those) — one key, never both. Honoured by every path that
      picks an implementer account (`Arbiter.Agents.ProviderConstraint`); the
      reviewer is not constrained. `nil` — the default — is no constraint.
      Set by the coordinator/operator only.
      """
    end

    attribute :reviewer_family, :string do
      allow_nil? true
      public? true
      constraints max_length: 64, trim?: true

      description """
      The model family pinned for this task's ReviewGate reviewer (bd-a1ke2c),
      set at the first review pass under `review_agent.cross_family`. Every
      later review pass — every round, a post-approval re-review, a
      print-timeout rotation — reviews in this family while it is available.
      `nil` when cross-family review never ran on the task.
      """
    end

    attribute :pending_merge, :map do
      allow_nil? true
      public? false

      description """
      An approved merge the Watchdog deferred or could not complete — CI still
      running, a draft PR, a transient forge refusal — recorded durably so it
      outlives the worker that owned it. `nil` when no merge is pending.

      Written and read only through `Arbiter.Mergers.PendingMerge`, which owns
      the shape. `Arbiter.Workflows.PendingMergeSweeper` re-arms a worker-less
      retry for any stamp nobody owns any more. Cleared by `:close`,
      `:await_verification`, a merge, or a closed PR.
      """
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :workspace, Arbiter.Tasks.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  calculations do
    # Progress rollup over this task's `:parent_of` children. SQLite can't do
    # inline aggregates across the dependency join, so these are batch module
    # calculations (see Arbiter.Tasks.Issue.Calcs). Load with
    # `Ash.load!(issue, [:child_total, :child_closed])`.
    calculate :child_total, :integer, Arbiter.Tasks.Issue.Calcs.ChildTotal do
      public? true
    end

    calculate :child_closed, :integer, Arbiter.Tasks.Issue.Calcs.ChildClosed do
      public? true
    end

    # THE review-engagement predicate (bd-crk6tb): `review_only == true and
    # not is_nil(source_pr)`. Neither half alone is an engagement — a
    # `worker_review <task>` dispatch stamps `review_only` with a nil
    # `source_pr`, and a PRPatrol author-side follow-up carries `source_pr`
    # with `review_only == false`. `review_only` is nullable, so the `if`
    # collapses SQL's unknown into `false`: the result is always a strict
    # boolean and `== false` filters never lose a NULL row. Query through
    # `exclude_engagements/1` / `only_engagements/1`; do not hand-roll it.
    calculate :engagement?,
              :boolean,
              expr(if(review_only == true and not is_nil(source_pr), do: true, else: false)) do
      public? true
    end
  end

  @doc """
  Narrow an `Issue` query (or the resource itself) to ordinary tickets — every
  row that is NOT a review engagement. The one call every issue *list* runs
  through; engagements surface on `/reviews` instead.
  """
  @spec exclude_engagements(Ash.Query.t() | module()) :: Ash.Query.t()
  def exclude_engagements(query) do
    Ash.Query.filter(query, engagement? == false)
  end

  @doc "Narrow an `Issue` query (or the resource itself) to review engagements only."
  @spec only_engagements(Ash.Query.t() | module()) :: Ash.Query.t()
  def only_engagements(query) do
    Ash.Query.filter(query, engagement? == true)
  end

  @doc "Every attention cause (`Arbiter.Tasks.Lifecycle.Attention.causes/0`)."
  @spec attention_causes() :: [atom()]
  def attention_causes, do: @attention_causes

  @doc "List of valid issue_type atoms."
  def issue_types, do: Arbiter.Extensions.atoms(:issue_type)

  @doc """
  Whether `issue_type` is one of the no-PR types (`:task`, `:research`) — the
  single predicate every dispatch/completion branch asks (bd-9s9dqz). Accepts
  the atom or its string form (worker meta can carry either); anything else,
  including `nil`, is `false`.
  """
  @spec no_pr_type?(atom() | String.t() | nil) :: boolean()
  def no_pr_type?(issue_type) when is_atom(issue_type), do: issue_type in @no_pr_types

  def no_pr_type?(issue_type) when is_binary(issue_type),
    do: match_type?(issue_type, @no_pr_types)

  def no_pr_type?(_), do: false

  @doc """
  Whether `issue_type` is a no-PR type whose completion requires a findings
  write-up in `notes` (the notes gate) — `:research` only (bd-9s9dqz).
  """
  @spec findings_type?(atom() | String.t() | nil) :: boolean()
  def findings_type?(issue_type) when is_atom(issue_type), do: issue_type in @findings_types

  def findings_type?(issue_type) when is_binary(issue_type),
    do: match_type?(issue_type, @findings_types)

  def findings_type?(_), do: false

  defp match_type?(string, atoms), do: Enum.any?(atoms, &(Atom.to_string(&1) == string))

  @doc "List of valid tracker_type atoms."
  def tracker_types, do: Arbiter.Extensions.atoms(:tracker)

  @doc """
  Issue types gated by bd-7mbrlg's acceptance-criteria-before-Ready rule:
  `bug`, `feature`, `chore`. `task`, `research`, `decision`, and `epic` are exempt — they
  never open a PR, so ReviewGate's criteria guards never score them.
  """
  def gated_issue_types, do: @gated_issue_types

  @doc "Whether `issue_type` is subject to the acceptance-criteria-before-Ready rule."
  def gated_type?(issue_type), do: issue_type in @gated_issue_types

  @doc """
  Puts a ticket to work — the move into `:active` a dispatch makes before its
  run starts (bd-842qio):

    * `:queued` → the `start` transition;
    * `:backlog` → the `start` transition too: a manual dispatch that skipped
      the Ready queue (bd-asxw4e puts it behind `--force`);
    * `:active` / `:merging` → already at work, returned unchanged;
    * anything else → the `start` transition's refusal.

  `attrs` rides along on the same write (a review dispatch's `review_only`).
  """
  @spec start_work(t(), map()) :: {:ok, t()} | {:error, term()}
  def start_work(issue, attrs \\ %{})

  def start_work(%{state: state} = issue, _attrs) when state in [:active, :merging],
    do: {:ok, issue}

  def start_work(issue, attrs), do: Ash.update(issue, attrs, action: :start)

  @doc """
  A PR was opened, or adopted, for this ticket (bd-842qio): record its
  `pr_ref` through the `open_pr` transition when the ticket is `:active`. A
  ticket in any other state — already `:merging` when a revise round re-adopts
  its PR — just has the ref recorded. The ticket is read fresh, so a stale
  struct cannot move one that closed in the meantime.

  Options (bd-741sid), written in the same update:

    * `:merger_url` — the PR's clickable URL.
    * `:merge_watch` — the lane its Watchdog watches it on
      (`Arbiter.Tasks.PullRequest`).
    * `:transition` (default `true`) — `false` records the PR without moving
      the ticket: the pre-review open, and a review-only engagement, whose
      ticket never enters Merging.
  """
  @spec pr_opened(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def pr_opened(id, pr_ref, opts \\ []) when is_binary(id) and is_binary(pr_ref) do
    attrs =
      opts
      |> Keyword.take([:merger_url, :merge_watch])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.put(:pr_ref, pr_ref)

    with {:ok, issue} <- Ash.get(__MODULE__, id) do
      action =
        if issue.state == :active and Keyword.get(opts, :transition, true),
          do: :open_pr,
          else: :record_pr

      Ash.update(issue, attrs, action: action)
    end
  end

  @doc """
  The ticket's PR was closed without merging (bd-741sid): back to work, with
  the `pr_closed` attention cause naming `pr_ref`. Only an open ticket moves;
  a closed or verifying one is returned untouched.
  """
  @spec pr_closed(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def pr_closed(id, pr_ref) when is_binary(id) do
    with {:ok, issue} <- Ash.get(__MODULE__, id) do
      if issue.state in [:active, :merging] do
        detail = "PR #{pr_ref || "(unknown)"} was closed without being merged."
        Ash.update(issue, %{detail: detail}, action: :pr_closed)
      else
        {:ok, issue}
      end
    end
  end

  @doc """
  A CI fix pass or a conflict resolver was just dispatched on this ticket
  (bd-842qio): a `:merging` ticket goes back to `:active` through the
  `return_to_work` transition. Any other state is left alone, and a failed
  write is logged rather than raised — the pass is already running either way.
  """
  @spec back_to_work(t() | String.t()) :: :ok
  def back_to_work(%{id: id}), do: back_to_work(id)

  def back_to_work(id) when is_binary(id) do
    with {:ok, %{state: :merging} = issue} <- Ash.get(__MODULE__, id),
         {:error, error} <- Ash.update(issue, %{}, action: :return_to_work) do
      Logger.warning(
        "Issue: return_to_work failed for task=#{id} after a pass was dispatched: " <>
          Exception.message(error)
      )
    end

    :ok
  end

  @doc """
  Issue types that are never dispatchable to a worker. Currently just `epic`:
  a rollup of children, not a unit of work in its own right. The canonical list; `Arbiter.Board.Snapshot` reads it
  instead of keeping its own copy.
  """
  def non_dispatchable_types, do: @non_dispatchable_types

  @doc """
  Returns the "ready" tickets: exactly those whose `Arbiter.Tasks.Lifecycle.view/2`
  column is `:ready` (bd-6zapbl) — `:queued`, with every gating blocker
  satisfied (`:verifying` or `:closed`, per `Lifecycle.blocker_satisfied?/1`) —
  in dispatch order (`Arbiter.Tasks.EffectivePriority.order/1`).

  So a `:backlog` ticket is never ready, whatever its edges: it has not been
  refined into the queue. And a blocker that has merged and is waiting on its
  post-merge verification no longer holds its dependents back.

  Informational dep types (`:relates_to`, `:discovered_from`, `:parent_of`) do
  NOT gate readiness — only `:blocks` and `:depends_on` count, through
  `Arbiter.Tasks.EdgeGate.blockers/2`, the same computation the board's
  Ready/Blocked split reads. Epics (`non_dispatchable_types/0`) are excluded
  up front: an epic is a rollup of children, never a unit of work.

  This is a thin read over `Arbiter.Tasks.Lifecycle.Projection.ready/2` — the one
  Ready implementation behind the `ticket_ready` MCP tool,
  `GET /api/issues/ready`, `arb ready` and `arb prime`'s "Ready issues" (P-13).
  Like the board it consults the live runs, so a `:queued` ticket whose run
  registered before dispatch's `start` transition landed is not ready.

  ## Options

    * `:workspace_id` — when set, restrict the result to a single
      workspace. Gating dependencies are still consulted across
      workspaces (a task in workspace A can be blocked by a task in
      workspace B). Default: no filter (all workspaces).
    * `:workers` — the live worker rows, instead of reading them.

  At our scale (~thousands of issues) reading every issue and edge is fine.
  """
  def ready(opts \\ []) do
    {workspace_id, opts} = Keyword.pop(opts, :workspace_id)

    workspace_id
    |> Projection.ready(opts)
    |> Enum.map(&elem(&1, 0))
  end

  # ---- parent-with-progress rollup ---------------------------------------

  @doc """
  Walk the `:parent_of` parents of `issue` and call `maybe_auto_close/1` on
  each. Intended for the `after_transaction` hook on `Issue.close`: when a child
  closes, any auto-close parent whose children are now all done closes too.
  Returns `:ok`.
  """
  def maybe_auto_close_parents(issue) do
    issue.id
    |> parents_of()
    |> Enum.each(fn parent -> parent |> maybe_auto_close() |> maybe_notify_children_closed() end)

    :ok
  end

  # An epic with `auto_close` OFF is "owned": it never closes by itself, so when
  # its last child closes nobody is told and it sits open until noticed (the
  # bd-4i7kky incident). Raise one coordinator escalation at that moment. Only
  # here — child-close time — and not in `maybe_auto_close/1`, which also runs on
  # edge writes: attaching an already-closed child is not "the last child just
  # closed". Reopening a child and closing it again fires again, and a repeat
  # while the first is still open folds into it (ticket-scoped dedupe).
  defp maybe_notify_children_closed(%{issue_type: :epic, auto_close: false} = parent) do
    parent = Ash.load!(parent, [:child_total, :child_closed])

    if parent.state != :closed and parent.child_total > 0 and
         parent.child_closed == parent.child_total do
      Arbiter.Messages.CoordinatorNotifier.epic_children_closed(
        %{task_id: parent.id, workspace_id: parent.workspace_id},
        parent.child_total
      )
    end

    :ok
  end

  defp maybe_notify_children_closed(_parent), do: :ok

  @doc """
  If `parent` has `auto_close` set, is still open, and all its (≥1) `:parent_of`
  children are closed, close it with reason "all children closed". Returns the
  (possibly updated) parent task. Safe to call repeatedly.

  Closing the parent runs the normal `:close` action — including this same
  rollup — so the closure cascades up a chain of auto-close epics. Always
  passes `close_upstream: true`: an auto-close epic represents "real"
  completion with no human in the loop to opt in, so a linked tracker issue
  (if any) should close along with it (bd-dqjd2f). No-ops when the parent
  has no tracker_ref, same as any other close.
  """
  def maybe_auto_close(parent) do
    parent = Ash.load!(parent, [:child_total, :child_closed])

    cond do
      not parent.auto_close ->
        parent

      parent.state == :closed ->
        parent

      parent.child_total == 0 ->
        parent

      parent.child_closed < parent.child_total ->
        parent

      true ->
        {:ok, closed} =
          Ash.update(
            parent,
            %{reason: "all children closed", close_upstream: true},
            action: :close
          )

        closed
    end
  end

  # The parent tasks of `child_id`: the `from_issue` of every `:parent_of` edge
  # pointing at it. A child may have more than one parent.
  defp parents_of(child_id) do
    parent_of = :parent_of

    Arbiter.Tasks.Dependency
    |> Ash.Query.filter(type == ^parent_of and to_issue_id == ^child_id)
    |> Ash.read!()
    |> Enum.map(& &1.from_issue_id)
    |> Enum.uniq()
    |> Enum.map(&Ash.get!(__MODULE__, &1))
  end
end
