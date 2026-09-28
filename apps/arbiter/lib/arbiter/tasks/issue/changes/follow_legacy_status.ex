defmodule Arbiter.Tasks.Issue.Changes.FollowLegacyStatus do
  @moduledoc """
  The lifecycle overlap shim (bd-842qio): when an action changes the legacy
  `status` directly, re-derive `state` from the row so the two never disagree.

  `:update` does not accept `state` — the named transitions are the way to move
  a ticket. But until the later lifecycle children switch every writer over,
  `status` is still written directly in a few places the transition table has
  no row for:

    * a requeue, `in_progress → open` — `Arbiter.Worker.AuthDeath` and the
      board's drag back to Ready;
    * an operator's status edit — `arb update --status`, MCP `task_update`
      and the task page's edit form;
    * a manual dispatch of a Backlog ticket (`Arbiter.Worker.Dispatch`), which
      bypasses the Ready queue until bd-asxw4e puts it behind `--force`;
    * `:return_to_backlog` on an in-progress ticket whose worker already
      stopped (bd-2098), which resets it to `open` and unrefined.

  Each lands on the state the migration's backfill would give the same row
  (`Arbiter.Tasks.Lifecycle.legacy_state/1`), so a legacy write can never
  leave a ticket in a state its columns contradict. Runs after `GuardStatus`,
  which still refuses anything but `open ⇄ in_progress` here. Deleted along
  with `status` in bd-36ytcl.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.Issue.Changes.ClearAttention
  alias Arbiter.Tasks.Lifecycle
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Changeset.before_action(&follow/1)
    |> ClearAttention.resolve_after_commit(true)
  end

  defp follow(changeset) do
    status = Changeset.get_attribute(changeset, :status)

    if status == changeset.data.status do
      changeset
    else
      state =
        Lifecycle.legacy_state(%{
          status: status,
          refined: Changeset.get_attribute(changeset, :refined),
          pr_ref: Changeset.get_attribute(changeset, :pr_ref),
          pending_merge: Changeset.get_attribute(changeset, :pending_merge)
        })

      changeset
      |> Changeset.force_change_attribute(:state, state)
      |> clear_attention(state)
    end
  end

  # bd-8if9zt: a state change clears the ticket's attention, as a named
  # transition does (`Changes.Transition`).
  defp clear_attention(changeset, state) do
    if state == changeset.data.state,
      do: changeset,
      else: Changeset.force_change_attributes(changeset, ClearAttention.nil_fields())
  end
end
