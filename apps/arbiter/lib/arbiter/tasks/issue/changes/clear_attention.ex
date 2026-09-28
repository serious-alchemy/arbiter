defmodule Arbiter.Tasks.Issue.Changes.ClearAttention do
  @moduledoc """
  Clears a ticket's attention when its state moves on (bd-8if9zt): the cause
  (`attention_cause` / `attention_detail` / `attention_since`), the legacy
  ReviewGate park columns it dual-writes, and — once the write has committed —
  the ticket's open ticket-scoped escalations, which are marked resolved.

  Called by `Changes.Transition` for every named transition and by
  `Changes.FollowLegacyStatus` for a legacy status write that moves the state.
  An action that raises a cause of its own (`:pr_closed`,
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
  point — and is reset only when the state moves (`clear/1`, `nil_fields/0`).
  """

  use Ash.Resource.Change

  alias Arbiter.Messages.Message
  alias Ash.Changeset

  @fields [
    :attention_cause,
    :attention_detail,
    :attention_since,
    :review_park_reason,
    :review_parked_at,
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
    |> resolve_after_commit(false)
  end

  @doc """
  Resolve the ticket's escalations once the write commits — only when its
  committed state differs from the one the write started from, when
  `only_if_state_changed?` is true. For a change that learns whether the state
  moves only in a `before_action` (`Changes.FollowLegacyStatus`), which clears
  the fields itself with `nil_fields/0`.
  """
  @spec resolve_after_commit(Changeset.t(), boolean()) :: Changeset.t()
  def resolve_after_commit(changeset, only_if_state_changed?) do
    started = DateTime.utc_now()
    from = changeset.data.state

    Changeset.after_transaction(changeset, fn
      _changeset, {:ok, issue} = ok ->
        if not only_if_state_changed? or issue.state != from, do: resolve(issue.id, started)
        ok

      _changeset, error ->
        error
    end)
  end

  @doc """
  The attributes a state move resets: each attention field to nil, and the
  run-restart count to zero.
  """
  @spec nil_fields() :: map()
  def nil_fields, do: @fields |> Map.new(&{&1, nil}) |> Map.put(:attention_resume_attempts, 0)

  # Best-effort: the ticket has already moved; a mailbox hiccup must not turn
  # a committed transition into an error.
  defp resolve(ticket_id, before) do
    _ = Message.resolve_ticket_escalations(ticket_id, before: before)
    :ok
  rescue
    _ -> :ok
  end
end
