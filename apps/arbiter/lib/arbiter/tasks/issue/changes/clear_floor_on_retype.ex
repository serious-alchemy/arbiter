defmodule Arbiter.Tasks.Issue.Changes.ClearFloorOnRetype do
  @moduledoc """
  ES2 (bd-3e7inj): a `floor_priority` only means something on an epic, so
  retyping a floored epic to anything else clears the floor in the same
  write (and the paper trail records it) rather than leaving a floor that
  `:set_floor` would have refused.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    retyped_away? =
      Changeset.changing_attribute?(changeset, :issue_type) and
        Changeset.get_attribute(changeset, :issue_type) != :epic

    if retyped_away? and changeset.data.floor_priority != nil do
      Changeset.force_change_attribute(changeset, :floor_priority, nil)
    else
      changeset
    end
  end
end
