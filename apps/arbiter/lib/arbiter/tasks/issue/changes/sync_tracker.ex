defmodule Arbiter.Tasks.Issue.Changes.SyncTracker do
  @moduledoc """
  After-action hook for the transitions an upstream tracker cares about
  (`:start`, `:requeue`, `:close`, `:reopen`): propagate the ticket's new
  state to the linked external tracker, as the tracker status it maps to
  (`Arbiter.Trackers.Tracker.status_for_state/1`).

  Fires only when **all** of these hold:

    * the tracker status actually changed (old != new),
    * the task has a tracker (`tracker_type != :none`), and
    * the task carries a `tracker_ref`.

  When it fires, it seeds the per-process tracker config from the task's
  workspace (`Arbiter.Trackers.prepare/2`) and calls the resolved adapter's
  `transition/2`, mapping that tracker status to the external state via the
  adapter's own `status_map` (e.g. GitHub `:closed -> "closed"`,
  `:open`/`:in_progress -> "open"`).

  ## Gated forward transition

  Some trackers gate a forward transition on custom fields being populated —
  Acme's Jira (Apex / AX) refuses to move a ticket forward until its "QA
  Testing Notes" and "Deployment Notes" fields are filled. That gate is handled
  **provider-agnostically inside `Arbiter.Trackers.Sync.transition_event/2`**:
  it asks the adapter which fields gate the transition (`Tracker.gating_fields/2`),
  pushes the task's produced values into them *before* transitioning, and
  escalates — naming the exact missing field — when a required value hasn't been
  produced. This change therefore carries no provider-specific gating logic; it
  just routes the status transition through `Sync`.

  ## Failure is loud, not swallowed

  The local transition still always succeeds (a sync failure never rolls back
  the task). But the *sync* failure is no longer silent: the transition runs
  through `Arbiter.Trackers.Sync.transition_event/2`, which logs loudly and
  raises an escalation on a genuine failure (an unreachable mapped status,
  an auth/5xx error). A tracker that simply doesn't model the event is skipped
  quietly. This is the fix for AX-17911, whose In-Progress sync failed
  invisibly because a `status_map` mismatch was swallowed (bd-c4cfuv).

  ## Forced sync (`force: true`)

  `:sync_upstream_close` (bd-dqjd2f) makes no local state change — it exists
  precisely to push a close to the tracker for a task that's already `:closed`
  locally. Passing `force: true` skips the unchanged-status no-op guard (which
  would otherwise always skip a state-unchanged sync) and, when
  the task is closed with a tracker ref, transitions + verifies the upstream
  close unconditionally.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Trackers.Sync
  alias Arbiter.Trackers.Tracker

  @impl true
  def change(changeset, opts, _context) do
    force? = Keyword.get(opts, :force, false)

    Ash.Changeset.after_action(changeset, fn cs, issue ->
      if force? do
        maybe_force_sync(issue)
      else
        close_upstream = Ash.Changeset.get_argument(cs, :close_upstream)
        maybe_sync(Tracker.status_for_state(cs.data.state), issue, cs.action.name, close_upstream)
      end

      {:ok, issue}
    end)
  end

  defp maybe_force_sync(issue) do
    cond do
      issue.state != :closed -> :ok
      issue.tracker_type == :none -> :ok
      blank?(issue.tracker_ref) -> :ok
      issue.review_only == true -> :ok
      true -> sync(issue)
    end
  end

  defp maybe_sync(old_status, issue, action_name, close_upstream) do
    cond do
      is_nil(Tracker.status_for_state(issue.state)) -> :ok
      old_status == Tracker.status_for_state(issue.state) -> :ok
      issue.tracker_type == :none -> :ok
      blank?(issue.tracker_ref) -> :ok
      action_name == :close and not close_upstream -> :ok
      # bd-6xaaam: review-only tasks must never mutate a tracker issue they
      # don't own (no status transition on in_progress or close).
      issue.review_only == true -> :ok
      true -> sync(issue)
    end
  end

  defp sync(issue) do
    Trackers.prepare(issue, load_workspace(issue.workspace_id))
    do_transition(issue)
  rescue
    e ->
      Logger.warning("SyncTracker: error syncing task=#{issue.id}: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("SyncTracker: exit syncing task=#{issue.id}: #{inspect(reason)}")
  end

  defp do_transition(issue) do
    # Route through Sync so a genuine failure is loud + raises an escalation
    # (the swallow-on-error that hid AX-17911 is gone). A benign "tracker
    # doesn't model this status" is still skipped quietly.
    result = Sync.transition_event(issue, Tracker.status_for_state(issue.state))

    # For close transitions, verify the upstream issue is actually closed —
    # a silent no-op or a stale server can leave it open even after :ok.
    # Shared with `Arbiter.Tasks.Verification`'s merge-time close so both
    # close paths retry identically (bd-9so315). Not when the adapter declined
    # the close because the item is already past the closed status (bd-4i7kky):
    # there is nothing to verify, and a retry would only be declined again.
    if issue.state == :closed and result != {:skipped, :upstream_past_target} do
      Sync.verify_closed(issue)
    end
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
