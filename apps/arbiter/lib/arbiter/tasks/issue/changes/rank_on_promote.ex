defmodule Arbiter.Tasks.Issue.Changes.RankOnPromote do
  @moduledoc """
  Ranks a ticket last in its workspace when it moves Backlog → Ready, using
  the same `AssignRank.next_rank/1` a new ticket gets, so promotion order is
  dispatch order inside a priority band.

  Declared after `Changes.Transition`. It only acts when that change actually
  moved the ticket out of `:backlog`; the idempotent no-op of an already-Ready
  ticket leaves the rank alone.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.Issue.Changes.AssignRank
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.data.state == :backlog and Changeset.changing_attribute?(changeset, :state) do
      Changeset.before_action(changeset, fn cs ->
        Changeset.force_change_attribute(cs, :rank, AssignRank.next_rank(cs.data.workspace_id))
      end)
    else
      changeset
    end
  end
end
