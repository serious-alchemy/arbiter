defmodule Arbiter.Worker.ConflictAbortFindings do
  @moduledoc """
  The ReviewGate's "branch conflicts with its target, merge aborted" rejection
  (bd-1u15tl).

  Before it reviews anything the gate merges the target branch into the branch
  under review (bd-ased52). When that merge hits textual conflicts it aborts it
  and rejects with `findings/2` — not a code finding, but a statement that the
  branch cannot be reviewed until someone integrates the target.

  ## Why it is not a fix round's business to count

  bd-7fjfgv (PR #463, 2026-10-07) was rejected twice that way — once after #462
  merged into `grok_token_controller.ex`, once after #465 merged into five
  controllers — and the second rejection read "fix rounds exhausted after 1
  round(s)" though the reviewer had not raised a single finding. A sibling
  ticket merging into the same files is not the author's mistake, so
  `Arbiter.Worker.maybe_dispatch_fix_round/3` recognises these findings by
  `escalation?/1` and hands the author a *conflict round*: an implementer
  re-attached to integrate the target, which leaves
  `meta[:review_gate_fix_round_attempts]` and the findings digest untouched.

  The conflict round is bounded on its own account (`max_rounds/0`, counted from
  the ReviewGate's recorded rounds by `rejected_rounds/1`), so a branch that
  never integrates cleanly still ends in an escalation.

  The gate's conflict-resolver pass (`Arbiter.Workflows.MergeQueue.ConflictResolver`)
  is the Watchdog's, and exists only once a PR is open and being merged; here the
  author's own worker is the one that holds the worktree, so the author is the
  right handler.
  """

  alias Arbiter.ReviewGate.Round

  require Ash.Query

  @marker "ReviewGate: branch conflicts with its target; the merge was aborted and nothing was reviewed"
  @max_rounds 3

  @doc "The leading sentence of the gate's conflict-abort rejection."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  How many conflict rounds one task may be handed before the gate escalates
  instead. Independent of the fix-round cap on purpose.
  """
  @spec max_rounds() :: pos_integer()
  def max_rounds, do: @max_rounds

  @doc """
  Whether `findings` is the gate's conflict-abort rejection: `marker/0` leads
  them. A prefix check, like `Arbiter.Worker.EvidenceIntegrity.escalation?/1`,
  so a diff or a rebuttal quoting the sentence cannot trip it.
  """
  @spec escalation?(String.t() | nil) :: boolean()
  def escalation?(findings) when is_binary(findings), do: String.starts_with?(findings, @marker)
  def escalation?(_), do: false

  @doc """
  The findings the gate rejects with: `marker/0`, the conflicting `files` and
  how to clear them.
  """
  @spec findings(map(), [String.t()]) :: String.t()
  def findings(%{branch: branch, target_branch: target}, files) do
    files_block =
      case files do
        [] -> "  (conflicting paths could not be determined)"
        _ -> Enum.map_join(files, "\n", &("  - " <> &1))
      end

    """
    #{@marker}.

    Branch `#{branch}` conflicts with its target `#{target}` and cannot be
    reviewed in a stale/conflicted state. The review gate fetched
    `origin/#{target}` and tried to merge it into the branch to bring the diff
    current, but the merge hit textual conflicts. The merge was ABORTED, so the
    worktree is left clean on the branch's own HEAD.

    Resolve the conflict before review: merge or rebase `origin/#{target}`
    into `#{branch}`, resolve the conflicting files, commit, and re-run the
    gate. Surfacing the conflict here is intentional — reviewing a stale base
    would mis-attribute the target's commits to this branch (bd-ased52).

    Conflicting files:
    #{files_block}
    """
    |> String.trim()
  end

  @doc """
  How many of `task_id`'s recorded `:review` rounds were conflict-abort
  rejections, the one being handled included (the gate records its round before
  it reports). Best-effort: a failed read counts as none, so a DB hiccup never
  turns into an escalation.
  """
  @spec rejected_rounds(String.t()) :: non_neg_integer()
  def rejected_rounds(task_id) when is_binary(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review and verdict == :request_changes)
    |> Ash.read!()
    |> Enum.count(&escalation?(&1.findings))
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end
end
