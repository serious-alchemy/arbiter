defmodule Arbiter.Tasks.Attention do
  @moduledoc """
  Raising and clearing a ticket's attention cause (ticket lifecycle 6/13,
  bd-8if9zt). The owner table — who has to act on each cause — is
  `Arbiter.Tasks.Lifecycle.Attention`, and `Lifecycle.view/2` renders it.

  ## Raising

  A cause is recorded by the thing that knows it:

    * a ReviewGate park (`Arbiter.Tasks.ReviewPark.park/2`) — its reason;
    * a PR closed without merging (`Issue.pr_closed/2`) — `:pr_closed`;
    * entering verification (`:await_verification`) — `:awaiting_verification`;
    * a ticket-scoped escalation whose kind names a cause
      (`Arbiter.Messages.EscalationKind.cause/1`, raised from
      `Arbiter.Messages.Escalation.post/1`) — `:merge_blocked`,
      `:run_crashed`, `:awaiting_manual_merge`.

  Only a ticket that is `:active`, `:merging` or `:verifying` takes one: a
  queued or closed ticket has nothing in flight to need attention.

  ## Clearing

  Automatic, never by hand:

    * **the ticket's state moves on** — every transition clears the cause and
      resolves the ticket's open escalations
      (`Arbiter.Tasks.Issue.Changes.ClearAttention`);
    * **its run restarts** — a resumed run (`Arbiter.Worker`, when it starts
      a run linked to a prior one) calls `clear/2`, which does the same
      without a transition. So does a ReviewGate re-run clearing its park
      (`ReviewPark.clear/2`).
  """

  require Logger

  alias Arbiter.Tasks.Issue

  @open_states [:active, :merging, :verifying]

  @doc """
  Record `cause` (with an optional one-line `detail`) on `ticket_id`. A no-op
  for a ticket that is not open work, or not a ticket at all. Best-effort:
  `{:error, _}` is returned, never raised.
  """
  @spec raise_cause(String.t(), atom(), String.t() | nil) :: {:ok, Issue.t() | nil} | {:error, term()}
  def raise_cause(ticket_id, cause, detail \\ nil) when is_binary(ticket_id) and is_atom(cause) do
    case Ash.get(Issue, ticket_id) do
      {:ok, %Issue{state: state} = issue} when state in @open_states ->
        Ash.update(issue, %{cause: cause, detail: detail}, action: :raise_attention)

      {:ok, _not_open} ->
        {:ok, nil}

      {:error, _not_a_ticket} ->
        {:ok, nil}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Clear `ticket_id`'s attention and resolve its open escalations — its run
  restarted, or its park was cleared. `by` names what cleared it, for the log.
  Idempotent: a ticket with nothing to clear still has its escalations swept.
  Best-effort: `{:error, _}` is returned, never raised.
  """
  @spec clear(String.t(), atom()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def clear(ticket_id, by \\ :unspecified) when is_binary(ticket_id) do
    case Ash.get(Issue, ticket_id) do
      {:ok, %Issue{} = issue} ->
        if issue.attention_cause,
          do: Logger.info("Attention: clearing #{issue.attention_cause} on #{ticket_id} (#{by})")

        Ash.update(issue, %{}, action: :clear_attention)

      {:error, _not_a_ticket} ->
        {:ok, nil}
    end
  rescue
    e -> {:error, e}
  end
end
