defmodule Arbiter.Tasks.Issue.Changes.AnnounceAttention do
  @moduledoc """
  Wakes the coordinator when a write raises a new attention cause on a ticket
  (bd-8nlez1): once the write commits, an `attention` event goes out on the
  `inbox` topic (`Arbiter.Tasks.Attention.announce/3`), the same topic a new
  mailbox row fires, so the coordinator's monitor loop needs no change.

  Only a new cause announces: raising the cause the ticket already carries (a
  repeat escalation refreshing its row) says nothing new.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    before = changeset.data.attention_cause

    Changeset.after_transaction(changeset, fn
      _changeset, {:ok, issue} = ok ->
        if issue.attention_cause && issue.attention_cause != before,
          do: Arbiter.Tasks.Attention.announce(issue, :raised)

        ok

      _changeset, error ->
        error
    end)
  end
end
