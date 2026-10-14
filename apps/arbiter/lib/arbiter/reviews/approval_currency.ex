defmodule Arbiter.Reviews.ApprovalCurrency do
  @moduledoc """
  The one definition of "our approval is still current" (bd-6zlfq6), shared by
  ReviewPatrol's sticky-approval skip (bd-4po0nv) and the `worker_review`
  self-approve guard (bd-7z5pi5) so the two cannot disagree.

  An approval is current when BOTH hold:

    * the adapter says our identity's latest verdict is APPROVED
      (`adapter.self_approved?/1`), and
    * GitHub itself still counts it: `adapter.review_decision/1` is not
      `"REVIEW_REQUIRED"` or `"CHANGES_REQUESTED"`. A branch rule can stop
      counting an earlier approval after new commits (stale-review dismissal,
      "require approval of the most recent push"), which our own review list
      does not show.

  An approval given at the PR's current head (`adapter.self_approved_at_head?/1`)
  stays current regardless of the forge's decision.

  Both capabilities are optional adapter functions. Every uncertain answer
  fails OPEN toward the pre-existing behaviour: an adapter without
  `review_decision/1`, a call that errors or raises, or a `nil` decision (no
  branch rule requires reviews) leaves the `self_approved?/1` answer
  untouched. Only a definite `REVIEW_REQUIRED` / `CHANGES_REQUESTED` from the
  forge overrides it.
  """

  @not_current_decisions ["REVIEW_REQUIRED", "CHANGES_REQUESTED"]

  @doc "Whether `adapter` reports a current approval of ours on `mr_ref`."
  @spec current?(module(), String.t()) :: boolean()
  def current?(adapter, mr_ref) do
    self_approved?(adapter, mr_ref) and
      (approved_at_head?(adapter, mr_ref) or not forge_discounts_approval?(adapter, mr_ref))
  end

  # An approval whose commit_id is the PR head is current by definition
  # (bd-8vb2z6); optional capability, any uncertainty reads as "not at head".
  defp approved_at_head?(adapter, mr_ref) do
    Code.ensure_loaded(adapter)

    function_exported?(adapter, :self_approved_at_head?, 1) and
      match?({:ok, true}, safe(fn -> adapter.self_approved_at_head?(mr_ref) end))
  end

  @doc """
  Whether the forge's own review decision says the approval no longer counts
  (`REVIEW_REQUIRED` / `CHANGES_REQUESTED`). `false` when unknown.
  """
  @spec forge_discounts_approval?(module(), String.t()) :: boolean()
  def forge_discounts_approval?(adapter, mr_ref) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :review_decision, 1) do
      case safe(fn -> adapter.review_decision(mr_ref) end) do
        {:ok, decision} when decision in @not_current_decisions -> true
        _ -> false
      end
    else
      false
    end
  end

  defp self_approved?(adapter, mr_ref) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :self_approved?, 1) do
      match?({:ok, true}, safe(fn -> adapter.self_approved?(mr_ref) end))
    else
      false
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end
end
