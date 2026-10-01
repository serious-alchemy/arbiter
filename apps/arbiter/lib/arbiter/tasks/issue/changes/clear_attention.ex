defmodule Arbiter.Tasks.Issue.Changes.ClearAttention do
  @moduledoc """
  Clears a ticket's attention when its state moves on (bd-8if9zt): the cause
  (`attention_cause` / `attention_detail` / `attention_since`) and — once the
  write has committed — the ticket's open ticket-scoped escalations, which are
  marked resolved.

  Called by `Changes.Transition` for every named transition. An action that raises a cause of its own (`:pr_closed`,
  `:await_verification`) sets it after the transition change, so its cause
  survives. Only escalations inserted before the write started are resolved,
  so a page the same write raises afterwards (a sync failure on close, the
  `pr_closed` page) is not swallowed.

  As a change (`change {ClearAttention, []}`) it clears unconditionally — the
  `:clear_attention` action, used when a ticket's run restarts.

  The ownership a hand-off or an expired limit set (`attention_owner`,
  `attention_owner_cause`, `attention_note`, `attention_owner_since`,
  bd-8nlez1) goes with the cause. The run-restart count
  (`attention_resume_attempts`) survives a restart — counting restarts is its
  point — and is reset only when the state moves (`clear/1`).
  """

  use Ash.Resource.Change

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue.Changes.RecordAttentionSpan
  alias Ash.Changeset

  @fields [
    :attention_cause,
    :attention_detail,
    :attention_since,
    :attention_owner,
    :attention_owner_cause,
    :attention_note,
    :attention_owner_since
  ]

  @impl true
  def change(changeset, _opts, _context), do: clear(changeset, keep_attempts: true)

  @doc """
  Clear the cause on `changeset` and resolve the ticket's escalations once
  the write commits. Resets the run-restart count too, unless
  `keep_attempts: true` (a restart, not a transition).
  """
  @spec clear(Changeset.t(), keyword()) :: Changeset.t()
  def clear(changeset, opts \\ []) do
    fields =
      if Keyword.get(opts, :keep_attempts, false),
        do: Map.new(@fields, &{&1, nil}),
        else: nil_fields()

    changeset
    |> Changeset.force_change_attributes(fields)
    |> RecordAttentionSpan.record()
    |> resolve_after_commit()
  end

  # Resolve the ticket's escalations once the write commits.
  defp resolve_after_commit(changeset) do
    started = DateTime.utc_now()

    Changeset.after_transaction(changeset, fn
      _changeset, {:ok, issue} = ok ->
        resolve(issue.id, started)
        ok

      _changeset, error ->
        error
    end)
  end

  # The attributes a state move resets: each attention field to nil, and the
  # run-restart count to zero.
  defp nil_fields, do: @fields |> Map.new(&{&1, nil}) |> Map.put(:attention_resume_attempts, 0)

  # Best-effort: the ticket has already moved; a mailbox hiccup must not turn
  # a committed transition into an error.
  defp resolve(ticket_id, before) do
    _ = Message.resolve_ticket_escalations(ticket_id, before: before)
    :ok
  rescue
    _ -> :ok
  end
end
