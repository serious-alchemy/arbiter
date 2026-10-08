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
      `:run_crashed`, `:awaiting_manual_merge`, `:tracker_sync_failed`.

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

  ## Who owns it (bd-8nlez1)

  The coordinator comes first. `hand_off/3` moves a ticket's attention to the
  operator (the coordinator's hand-off, with a note) or back to the
  coordinator (the operator's hand-back); `Arbiter.Tasks.AttentionSweep`
  moves a coordinator-owned item the coordinator left unresolved past its
  limit (`Arbiter.Tasks.AttentionLimits`). `current/1` reads one ticket's
  attention and `items/1` every open ticket's — the coordinator's computed
  queue, which has no read or clear state of its own: an item is there
  exactly while its ticket's attention is.

  ## Events

  Raising, handing off, handing back and promoting an item each put an
  `attention` event on the `inbox` topic (`announce/3`), the one a new mailbox
  row fires, so the coordinator's monitor loop wakes for them unchanged.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Worker.Watchdog

  @open_states [:active, :merging, :verifying]

  @doc """
  Record `cause` (with an optional one-line `detail`) on `ticket_id`. A no-op
  for a ticket that is not open work, or not a ticket at all. With
  `keep_existing: true` it is also a no-op for a ticket that already carries
  a cause — a report that must not mask what the ticket waits on. Best-effort:
  `{:error, _}` is returned, never raised.
  """
  @spec raise_cause(String.t(), atom(), String.t() | nil, keyword()) ::
          {:ok, Issue.t() | nil} | {:error, term()}
  def raise_cause(ticket_id, cause, detail \\ nil, opts \\ [])
      when is_binary(ticket_id) and is_atom(cause) do
    keep? = Keyword.get(opts, :keep_existing, false)

    case Ash.get(Issue, ticket_id) do
      {:ok, %Issue{state: state, attention_cause: existing}}
      when keep? and state in @open_states and existing not in [nil, cause] ->
        {:ok, nil}

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
  `resumed_from_failure: true` — the run restarted out of a failed one —
  counts one more resume attempt (`Issue.attention_resume_attempts`).
  Best-effort: `{:error, _}` is returned, never raised.
  """
  @spec clear(String.t(), atom(), keyword()) :: {:ok, Issue.t() | nil} | {:error, term()}
  def clear(ticket_id, by \\ :unspecified, opts \\ []) when is_binary(ticket_id) do
    case Ash.get(Issue, ticket_id) do
      {:ok, %Issue{} = issue} ->
        if issue.attention_cause,
          do: Logger.info("Attention: clearing #{issue.attention_cause} on #{ticket_id} (#{by})")

        Ash.update(
          issue,
          %{resumed_from_failure: Keyword.get(opts, :resumed_from_failure, false)},
          action: :clear_attention
        )

      {:error, _not_a_ticket} ->
        {:ok, nil}
    end
  rescue
    e -> {:error, e}
  end

  # ---- ownership (bd-8nlez1) ------------------------------------------------

  @doc """
  Move `ticket_id`'s current attention to `to`:

    * `:operator` — the coordinator's hand-off; `note` (why the operator has
      to act) is required;
    * `:coordinator` — the operator's hand-back; `note` is optional. The
      coordinator gets a fresh clock and attempt budget.

  Returns `{:ok, attention}` (the moved item, `current/2`), or
  `{:error, reason}`: `:not_found`, `:no_attention` (nothing to hand off),
  `:note_required`, `{:already_owned, to}`. Announces `handed_off` /
  `handed_back`. `opts` go to `current/2`.
  """
  @spec hand_off(String.t(), :coordinator | :operator, String.t() | nil, keyword()) ::
          {:ok, Lifecycle.Attention.t()} | {:error, term()}
  def hand_off(ticket_id, to, note, opts \\ []) when to in [:coordinator, :operator] do
    note = blank_to_nil(note)

    with {:ok, issue} <- fetch(ticket_id),
         {:ok, attention} <- attention_of(issue, opts),
         :ok <- check_note(to, note),
         :ok <- check_owner(attention, to),
         {:ok, moved} <- set_owner(issue, to, attention.cause, note) do
      event = if to == :operator, do: :handed_off, else: :handed_back
      now_attention = current(moved, opts)
      announce(moved, event, now_attention)
      {:ok, now_attention}
    end
  end

  @doc """
  Move `issue`'s attention to the operator because the coordinator did not
  resolve it within a limit (`Arbiter.Tasks.AttentionSweep`); `note` names
  the limit. Announces `promoted`.
  """
  @spec promote(Issue.t(), atom(), String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def promote(%Issue{} = issue, cause, note) do
    with {:ok, moved} <- set_owner(issue, :operator, cause, note) do
      Logger.info("Attention: #{issue.id}'s #{cause} moved to the operator — #{note}")
      announce(moved, :promoted, %{cause: cause, owner: :operator, note: note})
      {:ok, moved}
    end
  end

  @doc "A sentence for a `hand_off/4` error, for the MCP tool, the API and the dashboard."
  @spec describe_error(term()) :: String.t()
  def describe_error(:not_found), do: "no such ticket"
  def describe_error(:no_attention), do: "the ticket has no attention to hand off"
  def describe_error(:note_required), do: "a hand-off to the operator needs a note"

  def describe_error({:already_owned, owner}),
    do: "the ticket's attention is already the #{owner}'s"

  def describe_error(other), do: inspect(other)

  defp set_owner(issue, owner, cause, note) do
    Ash.update(issue, %{owner: owner, cause: cause, note: note}, action: :set_attention_owner)
  end

  defp fetch(ticket_id) do
    case Ash.get(Issue, ticket_id) do
      {:ok, %Issue{} = issue} -> {:ok, issue}
      _ -> {:error, :not_found}
    end
  end

  defp attention_of(issue, opts) do
    case current(issue, opts) do
      nil -> {:error, :no_attention}
      attention -> {:ok, attention}
    end
  end

  defp check_note(:operator, nil), do: {:error, :note_required}
  defp check_note(_to, _note), do: :ok

  defp check_owner(%{owner: to}, to), do: {:error, {:already_owned, to}}
  defp check_owner(_attention, _to), do: :ok

  defp blank_to_nil(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  # ---- reading it -----------------------------------------------------------

  @doc """
  `issue`'s attention (`Arbiter.Tasks.Lifecycle.Attention.t/0`), or nil —
  read through `Lifecycle.view/2` with the ticket's live runs and its
  Watchdog's liveness, as the board reads it. Opts: `:workers` (the live
  worker rows; default `Arbiter.Worker.list_children/0`), `:now` and
  `:resume_queued` (the ids of tickets with a round deferred for a slot;
  default: asked of `Arbiter.Board.Autopilot`).
  """
  @spec current(Issue.t(), keyword()) :: Lifecycle.Attention.t() | nil
  def current(%Issue{} = issue, opts \\ []) do
    workers = Keyword.get_lazy(opts, :workers, &live_workers/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    view(issue, workers, now, resume_queued([issue], opts)).attention
  end

  @typedoc "One open ticket's attention, as the coordinator's queue lists it."
  @type item :: %{
          ticket_id: String.t(),
          title: String.t() | nil,
          workspace_id: String.t() | nil,
          state: atom(),
          attention: Lifecycle.Attention.t(),
          ticket: Issue.t()
        }

  @doc """
  Every open ticket with attention, oldest first. Opts: `:workspace_id`
  (nil: every workspace), `:owner` (`:coordinator` / `:operator`; nil: both),
  `:workers`, `:now`, `:resume_queued` and `:issues` (the tickets to read,
  instead of the open ones).

  `owner: :coordinator` is the coordinator's computed queue. It has no read
  or clear state: an item is listed exactly while its ticket's attention is.
  """
  @spec items(keyword()) :: [item()]
  def items(opts \\ []) do
    workers = Keyword.get_lazy(opts, :workers, &live_workers/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    owner = Keyword.get(opts, :owner)

    issues =
      Keyword.get_lazy(opts, :issues, fn -> open_tickets(Keyword.get(opts, :workspace_id)) end)

    queued = resume_queued(issues, opts)

    issues
    |> Enum.flat_map(fn issue ->
      case view(issue, workers, now, queued).attention do
        %{owner: o} = attention when is_nil(owner) or o == owner ->
          [
            %{
              ticket_id: issue.id,
              title: issue.title,
              workspace_id: issue.workspace_id,
              state: issue.state,
              attention: attention,
              ticket: issue
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&(&1.attention.since || now), DateTime)
  end

  defp view(issue, workers, now, queued) do
    Lifecycle.view(issue, %{
      runs: workers,
      now: now,
      watchdog_alive: watchdog_alive(issue),
      resume_queued: issue.id in queued
    })
  end

  # bd-1u15tl: a Merging ticket whose re-review (or pass) waits for a worker
  # slot has no Watchdog and no review yet, by design — it is waiting, not
  # blocked. Opts: `:resume_queued`, the ids so waiting.
  defp resume_queued(issues, opts) do
    case Keyword.fetch(opts, :resume_queued) do
      {:ok, ids} ->
        ids

      :error ->
        if Enum.any?(issues, &(Lifecycle.state_of(&1) == :merging)),
          do: Arbiter.Board.Autopilot.deferred_resume_ids(),
          else: []
    end
  end

  defp open_tickets(workspace_id) do
    Issue
    |> Ash.Query.filter(state in ^@open_states)
    |> then(fn q ->
      if workspace_id, do: Ash.Query.filter(q, workspace_id == ^workspace_id), else: q
    end)
    |> Ash.read!()
  rescue
    e ->
      Logger.warning("Attention: could not read open tickets: #{Exception.message(e)}")
      []
  end

  defp live_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Only a Merging ticket's Watchdog is supposed to be running; unknown (nil)
  # elsewhere, and when the registry cannot answer.
  defp watchdog_alive(%Issue{id: id} = issue) do
    if Lifecycle.state_of(issue) == :merging, do: Watchdog.alive?(id)
  rescue
    _ -> nil
  end

  # ---- events ---------------------------------------------------------------

  @doc """
  Put an `attention` event for `issue` on its workspace's `inbox` topic
  (`Arbiter.Events`): `event` is `:raised`, `:promoted`, `:handed_off` or
  `:handed_back`. Carries the cause, owner and note of `attention` when given
  (a derived item, which the row does not store), else of the ticket's row.
  Best-effort.
  """
  @spec announce(
          Issue.t(),
          :raised | :promoted | :handed_off | :handed_back,
          map() | nil
        ) :: :ok
  def announce(issue, event, attention \\ nil)

  def announce(%Issue{workspace_id: ws_id} = issue, event, attention) when is_binary(ws_id) do
    {cause, owner, note} =
      case attention do
        %{cause: cause, owner: owner} = a -> {cause, owner, Map.get(a, :note)}
        _ -> row_attention(issue)
      end

    Arbiter.Events.broadcast(ws_id, "inbox", %{
      kind: "attention",
      event: Atom.to_string(event),
      task_id: issue.id,
      subject: issue.title,
      cause: cause && Atom.to_string(cause),
      owner: owner && Atom.to_string(owner),
      note: note
    })
  rescue
    e ->
      Logger.debug("Attention.announce/3 swallowed: #{Exception.message(e)}")
      :ok
  end

  def announce(_issue, _event, _attention), do: :ok

  defp row_attention(%Issue{attention_cause: cause} = issue) do
    if issue.attention_owner && issue.attention_owner_cause == cause,
      do: {cause, issue.attention_owner, issue.attention_note},
      else: {cause, table_owner(cause), nil}
  end

  defp table_owner(nil), do: nil

  defp table_owner(cause) do
    Enum.find_value(Lifecycle.Attention.table(), fn
      %{cause: ^cause, when: nil, owner: owner} -> owner
      _ -> nil
    end)
  end
end
