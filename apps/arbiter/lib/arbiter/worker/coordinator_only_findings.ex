defmodule Arbiter.Worker.CoordinatorOnlyFindings do
  @moduledoc """
  Detects a ReviewGate rejection whose `[NOT MET]` criteria are ALL findings the
  reviewer itself says need coordinator/operator action, not another
  implementer round (bd-6d3h8m).

  ## The gap this closes

  On bd-28t80i (PR #2050, 2026-09-25) every review round — 6 of them, across
  the original pass and one automatic fix round — flagged the same criterion,
  AC3, which could only be verified once the change was deployed and the live
  dashboard observed. No implementer round can make that criterion `[MET]`;
  each one just reproduced the same finding, and the fleet spent 4 implementer
  passes and ~$8.59 discovering that before the fix-round budget finally forced
  an escalation.

  ## The detection rule

  Mirrors `Arbiter.Worker.EvidenceIntegrity`'s shape:

    * `Arbiter.Worker.ReviewVerification.criteria_block/0`'s prompt (extended
      by `coordinator_only_block/0`, appended alongside it) asks the reviewer
      to tag a `[NOT MET]` criterion with `tag/0` when the gap is not something
      another implementer round can fix — it needs a merge, a deploy, or a
      coordinator/operator decision.
    * `only_coordinator_blocked_unmet?/1` reads a reviewer's raw findings text
      and is true only when there is at least one `[NOT MET]` criterion AND
      every `[NOT MET]` line carries the tag. One untagged `[NOT MET]` means
      there is still implementer work to do, so it stays false.
    * `Arbiter.Worker.ReviewGate.route_after_reject/2` runs this rule (like it
      already does for `EvidenceIntegrity.flagged?/1`) and, when it fires,
      escalates immediately with `marker/0` leading the findings instead of
      dispatching the gate's own internal revise round.
    * `Arbiter.Worker.maybe_dispatch_fix_round/3` checks `escalation?/1` — a
      cheap prefix check on `marker/0`, not a re-run of the tag scan — so the
      author's automatic fix round is skipped too, the same way a
      fabricated-evidence rejection skips it.

  Scanning the ReviewGate's *escalation payload* (the full thread/diff) for the
  tag would risk a false positive from an implementer's rebuttal quoting it, or
  a diff that touches this very prompt text — the same reason
  `EvidenceIntegrity.escalation?/1` only checks the marker prefix rather than
  re-running its own detection rule on arbitrary text.
  """

  @tag "[NEEDS-COORDINATOR]"
  # bd-49r9ns: `DeferredCriteria`'s tags are coordinator-only too. A
  # `[DEFERRED]` line only reaches here when the deferral is switched off, the
  # CI evidence is missing, or the verdict was not an APPROVE, and a
  # `[NEEDS-COORDINATOR-PREMERGE]` line always does. Either way no implementer
  # round can close the gap, so it parks instead of burning a revise round.
  @marker "ReviewGate: every unmet criterion needs coordinator/operator action, not an implementer round"

  # A `[NOT MET]` CRITERIA line, same shape as
  # `Arbiter.Worker.ReviewVerification`'s `@criteria_unmet`, kept independent so
  # this module's detection rule can't drift by way of an unrelated edit to
  # that module's regex.
  @not_met_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*NOT\s+MET\s*\]/im

  # #958: a standalone `- [DEFERRED] ...` line is the same coordinator-only gap
  # when the deferral is unavailable (opted out, CI not green on the reviewed
  # head), so it is a candidate line and parks via `@tagged_line`.
  @standalone_deferred_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*DEFERRED\s*\]/im

  # A park tag in the outcome position: right after `[NOT MET]`, or the
  # standalone `[DEFERRED]` outcome itself.
  @tagged_line ~r/^\s*(?:[-*]|\d+[.)])\s*(?:\[\s*NOT\s+MET\s*\]\s*(?:\[NEEDS-COORDINATOR(?:-PREMERGE)?\]|\[DEFERRED\])|\[\s*DEFERRED\s*\])/i

  @doc "The tag a reviewer puts on a `[NOT MET]` criterion needing coordinator/operator action."
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc """
  The leading sentence of a ReviewGate rejection that stopped because every
  unmet criterion needs coordinator/operator action. `Arbiter.Worker` keys the
  no-fix-round escalation off it.
  """
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Whether `findings` carries a CRITERIA breakdown with at least one `[NOT MET]`
  line, where EVERY `[NOT MET]` line carries `tag/0`. A round with no `[NOT
  MET]` lines at all is not this case (there is no rejection to route), and one
  untagged `[NOT MET]` line means an implementer round is still warranted.

  Pass `standalone_deferred: true` (only for the APPROVE path's unmet-criteria
  guard reject) to count a standalone `- [DEFERRED]` line as a coordinator-blocked
  criterion too; on a genuine REQUEST_CHANGES it is not a reason to skip the
  implementer's fix round. A tag counts only in the outcome position of its
  line, not when prose or the criterion text mentions it.
  """
  @spec only_coordinator_blocked_unmet?(String.t() | nil, keyword()) :: boolean()
  def only_coordinator_blocked_unmet?(findings, opts \\ [])

  def only_coordinator_blocked_unmet?(findings, opts) when is_binary(findings) do
    standalone? = Keyword.get(opts, :standalone_deferred, false)

    unmet_lines =
      findings
      |> String.split("\n")
      |> Enum.filter(
        &(Regex.match?(@not_met_line, &1) or
            (standalone? and Regex.match?(@standalone_deferred_line, &1)))
      )

    unmet_lines != [] and Enum.all?(unmet_lines, &Regex.match?(@tagged_line, &1))
  end

  def only_coordinator_blocked_unmet?(_, _), do: false

  @doc """
  Whether a rejection's findings call for the coordinator rather than a fix
  round: the ReviewGate stopped because every unmet criterion needs
  coordinator/operator action, so `marker/0` leads them. Mirrors
  `EvidenceIntegrity.escalation?/1` — a prefix check, not a re-scan of
  arbitrary text (see moduledoc).
  """
  @spec escalation?(String.t() | nil) :: boolean()
  def escalation?(findings) when is_binary(findings),
    do: String.starts_with?(findings, @marker)

  def escalation?(_), do: false

  @doc """
  The findings a ReviewGate reports when it stops because every unmet
  criterion needs coordinator/operator action: `marker/0`, what happens next,
  the reviewer's own findings, then `payload` (the usual escalation payload
  with the full transcript and diff).
  """
  @spec escalation_findings(String.t(), String.t()) :: String.t()
  def escalation_findings(reviewer_findings, payload) do
    """
    #{@marker}. No further fix round was dispatched; this needs a human.

    Every `[NOT MET]` criterion in this round is one the reviewer explicitly
    marked #{@tag} — it cannot be resolved by another implementer round (e.g.
    it can only be verified after a merge or a deploy). Another automatic fix
    round would just reproduce the same finding.

    #{reviewer_findings}

    #{payload}
    """
  end

  @doc """
  Appended alongside `ReviewVerification.criteria_block/0` in the review
  prompt: tells the reviewer how to mark a `[NOT MET]` criterion that another
  implementer round cannot address.
  """
  @spec coordinator_only_block() :: String.t()
  def coordinator_only_block do
    """
    If a `[NOT MET]` criterion cannot be addressed by another implementer
    round — it requires a merge, a deploy, or a coordinator/operator decision,
    not more code on this branch — say so by adding #{@tag} right after the
    outcome bracket on that line:

        - [NOT MET] #{@tag} <criterion> — <why this needs a human/deploy, not another round>

    Only use this when NO implementer round could possibly close the gap. Do
    not use it to avoid writing an ordinary finding.
    """
  end
end
