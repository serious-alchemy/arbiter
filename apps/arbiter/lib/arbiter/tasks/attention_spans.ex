defmodule Arbiter.Tasks.AttentionSpans do
  @moduledoc """
  Live capture of `ticket_attention_spans` (bd-cq1wsp, reports design v2
  §4.3): every stretch of a ticket's attention, as `Arbiter.Tasks.AttentionSpan`
  rows. History only accrues forward from here — what the ticket row does not
  keep is lost — so each writer is the thing that changes the attention:

    * **stored causes** — every Issue write that touches the attention runs
      `record_write/3` in its own transaction
      (`Arbiter.Tasks.Issue.Changes.RecordAttentionSpan`): a raise
      (`Attention.raise_cause/3`, a ReviewGate park, `pr_closed`,
      `await_verification`) opens a span, a clear (`ClearAttention`: a
      transition, a run restart, a park cleared) or a different cause closes
      it, and an owner move (`Attention.hand_off/4`, `Attention.promote/3`)
      moves the open span's owner. Raising the cause a ticket already carries
      is the same span;
    * **derived causes** — `Arbiter.Tasks.AttentionSweep` hands every sweep's
      items to `sync_derived/3`, which opens a `derived: true` span for one it
      has no open span for and closes (`:sweep_gone`) an open one it no longer
      sees. The open spans are the sweep's memory, so a restart neither
      duplicates nor loses one. A transition closes the ticket's derived spans
      at once, and a run restart its run-based ones (`run_crashed`,
      `run_asked_question`).

  Capture is best-effort: a failed span write is logged and never fails the
  ticket's own write.
  """

  import Ecto.Query

  require Ash.Query
  require Logger

  alias Arbiter.Repo
  alias Arbiter.Tasks.AttentionSpan
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle

  # The derived causes a run restart answers: the run is being worked again.
  @run_causes ["run_crashed", "run_asked_question"]

  @type scope :: :all | {:tickets, [String.t()]} | {:workspace, String.t()}

  @doc "Every span of `ticket_id`, oldest first."
  @spec for_ticket(String.t()) :: [AttentionSpan.t()]
  def for_ticket(ticket_id) when is_binary(ticket_id) do
    AttentionSpan
    |> Ash.Query.filter(ticket_id == ^ticket_id)
    |> Ash.Query.sort(opened_at: :asc, id: :asc)
    |> Ash.read!()
  end

  # ---- stored causes --------------------------------------------------------

  @doc """
  Record what one Issue write did to the ticket's attention: `before` is the
  row it started from, `written` the row it wrote, `action` the action's name.
  Called inside the write's transaction. Never raises.
  """
  @spec record_write(Issue.t(), Issue.t(), atom() | nil) :: :ok
  def record_write(%Issue{} = before, %Issue{} = written, action) do
    now = DateTime.utc_now()
    moved? = before.state != written.state
    same? = same_stored?(before, written)

    if before.attention_cause && not same?,
      do: close_stored(written.id, cleared_by(action, moved?, written.attention_cause), now)

    cond do
      moved? -> close_derived(written.id, :all, :transition, now)
      action == :clear_attention -> close_derived(written.id, @run_causes, :resume, now)
      true -> :ok
    end

    if written.attention_cause && not same?, do: open_stored(written, now)
    if owner_moved?(before, written), do: move_owner(written, now)
    :ok
  rescue
    e ->
      Logger.warning(
        "AttentionSpans: could not record #{inspect(action)} on #{written.id}: " <>
          Exception.message(e)
      )

      :ok
  end

  # The write kept the span it had: the same cause, raised at the same time.
  defp same_stored?(before, written) do
    before.attention_cause == written.attention_cause and
      before.attention_since == written.attention_since
  end

  defp cleared_by(_action, true = _moved?, _new_cause), do: :transition
  defp cleared_by(_action, _moved?, new_cause) when not is_nil(new_cause), do: :replaced
  defp cleared_by(:clear_attention, _moved?, _new_cause), do: :resume
  defp cleared_by(_action, _moved?, _new_cause), do: :clear

  defp open_stored(issue, now) do
    cause = issue.attention_cause
    owner = owner_of(issue, cause)

    insert(issue, %{
      cause: Atom.to_string(cause),
      owner: owner,
      owner_at_close: owner,
      opened_at: issue.attention_since || now,
      derived: false
    })
  end

  # Who owns `cause` on `issue` now: the owner table, or a move the ticket
  # already carries for it — read the way the board reads it.
  defp owner_of(issue, cause) do
    case Lifecycle.view(issue).attention do
      %{cause: ^cause, owner: owner} -> owner
      _ -> table_owner(cause)
    end
  end

  @doc "The owner table's default owner of `cause` (an atom or its name)."
  @spec table_owner(atom() | String.t()) :: Lifecycle.Attention.owner()
  def table_owner(cause) do
    name = to_string(cause)

    Enum.find_value(Lifecycle.Attention.table(), :coordinator, fn
      %{when: nil, cause: c, owner: owner} -> if Atom.to_string(c) == name, do: owner
      _ -> nil
    end)
  end

  defp owner_moved?(before, written) do
    written.attention_owner != nil and written.attention_owner_cause != nil and
      (before.attention_owner != written.attention_owner or
         before.attention_owner_cause != written.attention_owner_cause or
         before.attention_owner_since != written.attention_owner_since)
  end

  # Move the open span of the cause the move was made for. A move with no
  # open span to move — its derived item not yet seen by a sweep, or a cause
  # raised before capture shipped — opens one, from the default owner.
  defp move_owner(issue, now) do
    cause = Atom.to_string(issue.attention_owner_cause)
    at = issue.attention_owner_since || now

    {moved, _} =
      AttentionSpan
      |> where([s], s.ticket_id == ^issue.id and s.cause == ^cause and is_nil(s.cleared_at))
      |> Repo.update_all(
        set: [owner_at_close: issue.attention_owner, owner_changed_at: at, updated_at: now]
      )

    if moved == 0 do
      stored? = issue.attention_cause == issue.attention_owner_cause

      insert(issue, %{
        cause: cause,
        owner: table_owner(cause),
        owner_at_close: issue.attention_owner,
        owner_changed_at: at,
        opened_at: if(stored?, do: issue.attention_since || now, else: now),
        derived: not stored?
      })
    end
  end

  defp close_stored(ticket_id, by, now) do
    AttentionSpan
    |> where([s], s.ticket_id == ^ticket_id and s.derived == false and is_nil(s.cleared_at))
    |> close_all(by, now)
  end

  defp close_derived(ticket_id, causes, by, now) do
    AttentionSpan
    |> where([s], s.ticket_id == ^ticket_id and s.derived == true and is_nil(s.cleared_at))
    |> then(fn q -> if causes == :all, do: q, else: where(q, [s], s.cause in ^causes) end)
    |> close_all(by, now)
  end

  defp close_all(query, by, now) do
    Repo.update_all(query, set: [cleared_at: now, cleared_by: by, updated_at: now])
    :ok
  end

  # ---- derived causes -------------------------------------------------------

  @doc """
  Bring the derived spans in `scope` in line with one sweep's `items`
  (`Arbiter.Tasks.Attention.items/1`, every owner): open a span for a derived
  item with none, move an open span whose item changed owner, and close
  (`:sweep_gone`) an open span whose item is gone. `scope` is what the sweep
  read — `:all` open tickets, `{:tickets, ids}` or `{:workspace, id}` — so a
  narrow sweep never closes a span it did not look at. Never raises.
  """
  @spec sync_derived([map()], scope(), DateTime.t()) :: :ok
  def sync_derived(items, scope, now) do
    derived =
      for %{attention: %{since: nil, cause: cause}} = item <- items,
          into: %{},
          do: {{item.ticket_id, Atom.to_string(cause)}, item}

    open = scope |> open_derived() |> Map.new(&{{&1.ticket_id, &1.cause}, &1})

    Enum.each(derived, fn {{_id, cause} = key, item} ->
      case Map.fetch(open, key) do
        {:ok, span} -> follow_owner(span, item.attention, now)
        :error -> open_derived_span(item, cause, now)
      end
    end)

    gone = open |> Map.drop(Map.keys(derived)) |> Map.values() |> Enum.map(& &1.id)

    unless gone == [],
      do: AttentionSpan |> where([s], s.id in ^gone) |> close_all(:sweep_gone, now)

    :ok
  rescue
    e ->
      Logger.warning("AttentionSpans: could not sync derived spans: #{Exception.message(e)}")
      :ok
  end

  defp open_derived(scope) do
    AttentionSpan
    |> where([s], s.derived == true and is_nil(s.cleared_at))
    |> scoped(scope)
    |> Repo.all()
  end

  defp scoped(query, :all), do: query
  defp scoped(query, {:tickets, ids}), do: where(query, [s], s.ticket_id in ^ids)
  defp scoped(query, {:workspace, ws_id}), do: where(query, [s], s.workspace_id == ^ws_id)

  defp open_derived_span(item, cause, now) do
    insert(item.ticket, %{
      cause: cause,
      owner: item.attention.owner,
      owner_at_close: item.attention.owner,
      opened_at: now,
      derived: true
    })
  end

  # An owner the ticket row does not record — `merge_blocked` turning into
  # an approval block changes hands with the PR.
  defp follow_owner(%{owner_at_close: owner}, %{owner: owner}, _now), do: :ok

  defp follow_owner(span, attention, now) do
    AttentionSpan
    |> where([s], s.id == ^span.id)
    |> Repo.update_all(
      set: [
        owner_at_close: attention.owner,
        owner_changed_at: attention.owner_since || now,
        updated_at: now
      ]
    )
  end

  # ---- rows -----------------------------------------------------------------

  defp insert(issue, attrs) do
    insert_rows([
      Map.merge(
        %{ticket_id: issue.id, workspace_id: issue.workspace_id, repo: issue.repo, source: :live},
        attrs
      )
    ])
  end

  @doc """
  Insert span rows (maps of `AttentionSpan` fields; `id` and timestamps are
  filled in). A row whose `(ticket_id, cause, opened_at)` already exists is
  skipped. Returns how many were inserted.
  """
  @spec insert_rows([map()]) :: non_neg_integer()
  def insert_rows(rows)

  # Every row carries every column: SQLite has no `DEFAULT` in a multi-row
  # VALUES list.
  @row_defaults %{
    workspace_id: nil,
    repo: nil,
    owner_changed_at: nil,
    owner_at_close: nil,
    cleared_at: nil,
    cleared_by: nil,
    derived: false,
    source: :live
  }

  def insert_rows([]), do: 0

  def insert_rows(rows) do
    now = DateTime.utc_now()

    rows =
      Enum.map(rows, fn row ->
        @row_defaults
        |> Map.merge(row)
        |> Map.put_new(:id, Ash.UUIDv7.generate())
        |> Map.merge(%{inserted_at: now, updated_at: now})
        |> Map.update!(:opened_at, &usec/1)
        |> Map.update(:cleared_at, nil, &usec/1)
        |> Map.update(:owner_changed_at, nil, &usec/1)
      end)

    {count, _} =
      Repo.insert_all(AttentionSpan, rows,
        on_conflict: :nothing,
        conflict_target: [:ticket_id, :cause, :opened_at]
      )

    count
  end

  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
  defp usec(nil), do: nil
end
