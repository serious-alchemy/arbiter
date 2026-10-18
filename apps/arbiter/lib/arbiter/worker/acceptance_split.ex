defmodule Arbiter.Worker.AcceptanceSplit do
  @moduledoc """
  The acceptance-criteria vs `deployment_notes` split, as agent-facing wording.

  `acceptance` is what the implementer can do and the reviewer can verify from
  the diff, the worktree, the tests and the MR's own CI. `deployment_notes` is
  what can only be checked after merge/deploy, or by someone with access the
  worker lacks. A coordinator-only check parked in `acceptance` makes ReviewGate
  park the ticket (`review_gate_not_converged`), so every surface that files,
  implements or reviews a ticket carries the rule. Tests pin the key phrases.
  """

  @doc "Short filing rule for tool/CLI descriptions."
  @spec filing_rule() :: String.t()
  def filing_rule do
    "ACCEPTANCE vs DEPLOYMENT_NOTES: `acceptance` holds only what the implementer can do and the " <>
      "reviewer can verify from the diff, the worktree, the tests and the MR's own CI " <>
      "(e.g. \"test X covers Y\"). `deployment_notes` holds what can only be checked after " <>
      "merge or deploy, or by someone with access the worker lacks (e.g. \"main-branch pipeline " <>
      "finishes under 5.5 min\", prod observation, forge settings, operator registrations) — " <>
      "never put those in `acceptance`, or review parks the ticket. " <>
      "ISSUE_TYPE: set a child's `issue_type` by its OWN work type, not the parent's: " <>
      "`chore`/`bug`/`feature` for any code change; `task` is research/ops only, with no diff " <>
      "(a `task` worker will refuse to edit code and close with no MR). Also set `difficulty` " <>
      "and name `depends_on` tickets in the description."
  end

  @doc "Planner/research prompt block for workers that file child tickets."
  @spec planner_block() :: String.t()
  def planner_block do
    """
    FILING CHILD TICKETS — if you file follow-up tickets (`ticket_create` /
    `arb ticket create`):
      * `acceptance` is only what the implementer can do and the reviewer can
        verify from the diff, the worktree, the tests and the MR's own CI
        (example: "test X covers Y").
      * `deployment_notes` is what can only be checked after merge or deploy, or
        by someone with access the worker lacks: prod or live observation, timing
        on a main/default-branch pipeline, forge settings, operator registrations,
        "seen working on a real failing pipeline". NEVER put those in `acceptance`
        — ReviewGate parks a ticket whose unmet criteria need coordinator action.
      * Set `issue_type` to the work type of the CHILD, not the parent's:
        `chore`/`bug`/`feature` for code changes; `task` only for research with
        no diff (a `task` worker refuses to edit code and closes with no MR).
      * Set `difficulty`, and list `depends_on` tickets in the description.
    """
  end

  @doc "Implementer prompt block (also the PR-body guidance)."
  @spec implementer_block() :: String.t()
  def implementer_block do
    """
    ACCEPTANCE CRITERIA YOU CANNOT VERIFY IN THE WORKTREE — if a criterion can
    only be checked after merge/deploy or with access you lack (prod, a
    main-branch pipeline, forge settings, operator registrations), do not fake
    it and do not block on it. Say so in the PR body (a "Not verifiable
    pre-merge" note naming the criterion and why) and suggest moving it to
    `deployment_notes`. Do the rest of the task.
    """
  end

  @doc "Reviewer prompt block."
  @spec reviewer_block() :: String.t()
  def reviewer_block do
    """
    An acceptance criterion that can only be checked after merge or deploy (or with
    access the worker lacks) is NOT a reason for REQUEST_CHANGES. Mark it
    `[DEFERRED]` (post-merge) with the reason, e.g.
    `#{Arbiter.Worker.DeferredCriteria.example_line()}`, and
    judge the remaining criteria on their merits.
    """
  end
end
