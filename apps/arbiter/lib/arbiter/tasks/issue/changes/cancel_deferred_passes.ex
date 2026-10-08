defmodule Arbiter.Tasks.Issue.Changes.CancelDeferredPasses do
  @moduledoc """
  After-action hook for `:close` and `:await_verification` (bd-4l7l2n): cancel
  any fix, conflict or resume round the board scheduler is holding for this
  ticket until a slot frees. The ticket is done (its PR merged, or it was
  closed), so replaying the round would spawn a worker on a finished ticket
  and hold a scarce slot.

  Best-effort: no scheduler running is not a failure.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, issue ->
      module = Application.get_env(:arbiter, :resume_deferrer, Arbiter.Board.Autopilot)
      module.cancel_deferred(issue.id)
      {:ok, issue}
    end)
  end
end
