defmodule Arbiter.Tasks.AttentionSpanBackfill do
  @moduledoc """
  The one-off backfill of `ticket_attention_spans` (bd-cq1wsp, reports design
  v2 §4.3) for the attention that happened before live capture
  (`Arbiter.Tasks.AttentionSpans`) shipped. Run it with
  `Arbiter.Release.backfill(:attention_spans)` (dry run) or
  `mix arbiter.backfill_attention_spans`.

  Two sources, from `:since` (default 2026-09-15 — nothing earlier exists):

    * **the paper trail** (`issues_versions`) — replayed per ticket in order.
      A version that writes `attention_cause` (or, before bd-36ytcl, the
      ReviewGate park's `review_park_reason`) opens a span at the cause's own
      timestamp (`attention_since` / `review_parked_at`) and closes the one
      before it; `set_attention_owner` versions move the open span's owner.
      `cleared_by` follows the live rules: a version that moves the state is
      a `:transition`, a different cause `:replaced`, `clear_attention` a
      `:resume`, anything else a `:clear`;
    * **typed escalations** (`messages`) whose kind names a cause
      (`Arbiter.Messages.EscalationKind.cause/1`) — `inserted_at` to
      `resolved_at`, overlapping ones per ticket and cause merged into one
      span. One that overlaps a span of the same ticket and cause (from the
      paper trail, or already in the table) is the same attention and is
      dropped. Its span has no `cleared_by`: the escalation only says when it
      was resolved.

  Derived causes were never recorded, so they cannot be backfilled. Nor can an
  owner move on one (a hand-off of a derived `awaiting_verification`): with no
  span to move, it is skipped.

  Idempotent: a span is keyed on `(ticket_id, cause, opened_at)`, which is
  also what live capture writes for a stored cause (`opened_at` is its
  `attention_since`), so a second run — or a run after live capture has
  written the same span — inserts nothing.
  """

  import Ecto.Query

  alias Arbiter.Messages.EscalationKind
  alias Arbiter.Repo
  alias Arbiter.Tasks.AttentionSpan
  alias Arbiter.Tasks.AttentionSpans

  @default_since ~U[2026-09-15 00:00:00.000000Z]
  @batch 500

  @type result :: %{
          versions: non_neg_integer(),
          escalations: non_neg_integer(),
          spans: non_neg_integer(),
          existing: non_neg_integer(),
          planned: non_neg_integer(),
          inserted: non_neg_integer()
        }

  @doc """
  Plan the backfill and, with `apply?: true`, write it. Opts: `:apply?`
  (default `false`), `:since` (a `DateTime`, default 2026-09-15). Returns the
  versions and escalations read, the spans rebuilt, how many of those already
  exist, how many are new (`planned`) and how many were written (`inserted`;
  0 on a dry run).
  """
  @spec backfill(keyword()) :: result()
  def backfill(opts \\ []) do
    since = Keyword.get(opts, :since, @default_since)
    versions = load_versions(since)
    escalations = load_escalations(since)
    existing = load_existing()

    from_versions = replay(versions)
    from_escalations = escalation_spans(escalations, from_versions ++ existing)
    spans = from_versions ++ from_escalations

    keys = MapSet.new(existing, &key/1)
    new = Enum.reject(spans, &MapSet.member?(keys, key(&1)))
    new = attach_tickets(new)

    inserted =
      if Keyword.get(opts, :apply?, false),
        do:
          new |> Enum.chunk_every(@batch) |> Enum.map(&AttentionSpans.insert_rows/1) |> Enum.sum(),
        else: 0

    %{
      versions: length(versions),
      escalations: length(escalations),
      spans: length(spans),
      existing: length(spans) - length(new),
      planned: length(new),
      inserted: inserted
    }
  end

  # ---- the paper trail ------------------------------------------------------

  defp load_versions(since) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT version_source_id, version_action_name, version_inserted_at, changes
        FROM issues_versions
        WHERE version_inserted_at >= ?1
          AND (changes LIKE '%attention_%' OR changes LIKE '%review_park_reason%')
        ORDER BY version_source_id, version_inserted_at, id
        """,
        [iso(since)]
      )

    for [ticket_id, action, at, changes] <- rows,
        {:ok, changes} <- [Jason.decode(changes || "{}")],
        is_map(changes),
        do: %{ticket_id: ticket_id, action: action, at: parse!(at), changes: changes}
  end

  defp replay(versions) do
    versions
    |> Enum.chunk_by(& &1.ticket_id)
    |> Enum.flat_map(fn ticket_versions ->
      state = Enum.reduce(ticket_versions, %{done: [], open: nil, owner: nil}, &step/2)
      Enum.reverse(state.done) ++ List.wrap(state.open)
    end)
  end

  defp step(version, state) do
    state
    |> cause_step(version, cause_change(version.changes))
    |> owner_step(version)
  end

  # What a version did to the stored cause: `{cause, since}` (since nil when
  # the version did not write it), or `:none`.
  defp cause_change(%{"attention_cause" => cause} = changes),
    do: {cause, parse(changes["attention_since"])}

  defp cause_change(%{"review_park_reason" => cause} = changes),
    do: {cause, parse(changes["review_parked_at"])}

  defp cause_change(_changes), do: :none

  defp cause_step(state, _version, :none), do: state

  defp cause_step(%{open: %{cause: cause} = open} = state, _version, {cause, since})
       when is_nil(since) or since == open.opened_at,
       do: state

  defp cause_step(state, version, {cause, since}) do
    done =
      case state.open do
        nil -> state.done
        open -> [close(open, version, cause) | state.done]
      end

    open = if cause, do: new_span(version, cause, since || version.at)
    %{state | done: done, open: open, owner: nil}
  end

  defp close(open, version, new_cause) do
    by =
      cond do
        Map.has_key?(version.changes, "state") or Map.has_key?(version.changes, "status") ->
          :transition

        new_cause != nil ->
          :replaced

        version.action == "clear_attention" ->
          :resume

        true ->
          :clear
      end

    %{open | cleared_at: version.at, cleared_by: by}
  end

  defp new_span(version, cause, opened_at) do
    owner = AttentionSpans.table_owner(cause)

    %{
      ticket_id: version.ticket_id,
      cause: cause,
      owner: owner,
      owner_at_close: owner,
      owner_changed_at: nil,
      opened_at: opened_at,
      cleared_at: nil,
      cleared_by: nil,
      derived: false,
      source: :backfill
    }
  end

  # A hand-off, hand-back or promotion: `set_attention_owner` always stamps
  # `attention_owner_since`. It applies to the open span when it was made for
  # that span's cause (the cause is only in `changes` when it changed).
  defp owner_step(state, %{changes: changes} = version) do
    state =
      if Map.has_key?(changes, "attention_owner_cause"),
        do: Map.put(state, :owner_cause, changes["attention_owner_cause"]),
        else: state

    owner = changes["attention_owner"] || state.owner

    with %{} = open <- state.open,
         since when is_binary(since) <- changes["attention_owner_since"],
         true <- owner != nil and Map.get(state, :owner_cause) == open.cause do
      moved = %{
        open
        | owner_at_close: String.to_existing_atom(owner),
          owner_changed_at: parse(since) || version.at
      }

      %{state | open: moved, owner: owner}
    else
      _ -> %{state | owner: owner}
    end
  end

  # ---- escalations ----------------------------------------------------------

  defp load_escalations(since) do
    causes =
      for kind <- EscalationKind.ticket_kinds(),
          cause = EscalationKind.cause(kind),
          into: %{},
          do: {Atom.to_string(kind), Atom.to_string(cause)}

    %{rows: rows} =
      Repo.query!(
        """
        SELECT task_ref, escalation_kind, inserted_at, resolved_at
        FROM messages
        WHERE kind = 'escalation' AND task_ref IS NOT NULL AND inserted_at >= ?1
          AND escalation_kind IS NOT NULL
        ORDER BY task_ref, inserted_at
        """,
        [iso(since)]
      )

    for [ticket_id, kind, inserted_at, resolved_at] <- rows,
        cause = Map.get(causes, kind) do
      %{
        ticket_id: ticket_id,
        cause: cause,
        from: parse!(inserted_at),
        to: parse(resolved_at)
      }
    end
  end

  defp escalation_spans(escalations, known) do
    known = Enum.group_by(known, &{&1.ticket_id, &1.cause})

    escalations
    |> Enum.group_by(&{&1.ticket_id, &1.cause})
    |> Enum.flat_map(fn {{ticket_id, cause} = k, rows} ->
      others = Map.get(known, k, [])

      rows
      |> merge_intervals()
      |> Enum.reject(fn {from, to} ->
        Enum.any?(others, &overlaps?({from, to}, {&1.opened_at, &1.cleared_at}))
      end)
      |> Enum.map(fn {from, to} ->
        owner = AttentionSpans.table_owner(cause)

        %{
          ticket_id: ticket_id,
          cause: cause,
          owner: owner,
          owner_at_close: owner,
          owner_changed_at: nil,
          opened_at: from,
          cleared_at: to,
          cleared_by: nil,
          derived: false,
          source: :backfill
        }
      end)
    end)
  end

  # Overlapping escalations of one ticket and cause (a re-raise, two kinds
  # with the same cause) are one stretch of attention. A nil end is open.
  defp merge_intervals(rows) do
    rows
    |> Enum.sort_by(& &1.from, DateTime)
    |> Enum.reduce([], fn
      row, [{from, to} | rest] = acc ->
        if overlaps?({from, to}, {row.from, row.to}),
          do: [{from, later(to, row.to)} | rest],
          else: [{row.from, row.to} | acc]

      row, [] ->
        [{row.from, row.to}]
    end)
    |> Enum.reverse()
  end

  defp overlaps?({a_from, a_to}, {b_from, b_to}),
    do: not_after?(a_from, b_to) and not_after?(b_from, a_to)

  # `at` is not after `until` (nil: open-ended).
  defp not_after?(_at, nil), do: true
  defp not_after?(at, until), do: DateTime.compare(at, until) != :gt

  defp later(nil, _), do: nil
  defp later(_, nil), do: nil
  defp later(a, b), do: Enum.max([a, b], DateTime)

  # ---- rows -----------------------------------------------------------------

  defp load_existing do
    AttentionSpan
    |> select([s], %{
      ticket_id: s.ticket_id,
      cause: s.cause,
      opened_at: s.opened_at,
      cleared_at: s.cleared_at
    })
    |> Repo.all()
  end

  defp key(span), do: {span.ticket_id, span.cause, DateTime.to_unix(span.opened_at, :microsecond)}

  defp attach_tickets(spans) do
    %{rows: rows} = Repo.query!("SELECT id, workspace_id, repo FROM issues")
    tickets = Map.new(rows, fn [id, ws_id, repo] -> {id, {ws_id, repo}} end)

    Enum.map(spans, fn span ->
      {ws_id, repo} = Map.get(tickets, span.ticket_id, {nil, nil})
      Map.merge(span, %{workspace_id: ws_id, repo: repo})
    end)
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse(nil), do: nil

  defp parse(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> usec(dt)
      _ -> nil
    end
  end

  defp parse!(text), do: parse(text) || raise(ArgumentError, "not a timestamp: #{inspect(text)}")

  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
