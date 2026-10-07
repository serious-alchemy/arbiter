defmodule Arbiter.Tasks.Issue.Changes.AppendNotes do
  @moduledoc """
  P-08 (D-T-19): the `append_notes` argument of `Issue :update`.

  `arb ticket update --append-notes` used to GET the ticket, concatenate
  client-side and PATCH the whole `notes` field back, so a worker's concurrent
  `ticket_update_progress` write was silently overwritten. The append is now one
  `UPDATE … SET notes = <old> || '\\n\\n' || <new>` evaluated by the database
  against the row as it is at write time — not against whatever copy of the
  ticket the caller happened to load — so two appends can never lose each other.

  An empty (or absent) `append_notes` is a no-op. Combining it with `notes` in
  the same call is refused: the two would contradict each other (replace vs
  extend) and an atomic append cannot sit on top of a value set in the same
  statement.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  require Ash.Expr

  @separator "\n\n"

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.get_argument(changeset, :append_notes) do
      text when text in [nil, ""] ->
        changeset

      text ->
        if Changeset.changing_attribute?(changeset, :notes) do
          Changeset.add_error(changeset,
            field: :append_notes,
            message: "cannot be combined with notes: replace the field or append to it, not both"
          )
        else
          Changeset.atomic_update(changeset, :notes, append_expr(text))
        end
    end
  end

  defp append_expr(text) do
    Ash.Expr.expr(
      fragment(
        "CASE WHEN ? IS NULL OR ? = '' THEN ? ELSE ? || ? || ? END",
        notes,
        notes,
        ^text,
        notes,
        ^@separator,
        ^text
      )
    )
  end
end
