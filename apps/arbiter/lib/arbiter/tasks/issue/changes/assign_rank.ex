defmodule Arbiter.Tasks.Issue.Changes.AssignRank do
  @moduledoc """
  Gives a new ticket its `rank` (bd-842qio): one step past the highest rank in
  its workspace, so it sorts after every ticket already there — in particular
  after every ticket with its priority, which is the order Backlog and Ready
  read (priority, then rank).

  Ranks run per workspace rather than per priority band so that a later
  priority change keeps a ticket's place in creation order, exactly as the old
  priority-then-age order did. They are spaced `step/0` apart so a later
  drag-to-rank (bd-79w1fs) can drop a ticket between two neighbours by writing
  one row instead of renumbering the band.

  Two creates racing in one workspace can draw the same rank. That is harmless:
  a tie falls back to creation order.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Changeset

  @step 1024

  @doc "The gap between two consecutively created tickets' ranks."
  @spec step() :: pos_integer()
  def step, do: @step

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn cs ->
      case Changeset.get_attribute(cs, :workspace_id) do
        nil -> cs
        workspace_id -> Changeset.force_change_attribute(cs, :rank, next_rank(workspace_id))
      end
    end)
  end

  defp next_rank(workspace_id) do
    highest =
      Arbiter.Tasks.Issue
      |> Ash.Query.filter(workspace_id == ^workspace_id)
      |> Ash.max!(:rank)

    (highest || 0) + @step
  end
end
