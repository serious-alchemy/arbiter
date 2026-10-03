defmodule Arbiter.Reports.AttentionWaits do
  @moduledoc """
  Attention / wait time for `/reports` (bd-59x0gb; design
  `docs/design/reports-design-v2.md` §5.5): how long tickets sit waiting, for
  what cause, and on whom.

  Two sources, read as slim column sets (no `raw`, no notes):

    * `ticket_attention_spans` (§4.3) — one row per stretch of a cause, stored
      or derived. A span is dated by `opened_at`; the range filter and the
      week bucket use it.
    * `ticket_transitions` — the `verifying` dwell, shown as its own cause
      (`awaiting_verification`, owner coordinator). The spans table also
      carries a stored `awaiting_verification` span since 2026-09-29; those
      rows are skipped so a ticket is not counted twice, and the dwell (which
      covers every era) stands in for them.

  ## Rules

    * An **open** span (no `cleared_at`; a `verifying` dwell with no later
      transition) ends at `now` and is flagged `open?`: "still waiting". Its
      figures are lower bounds, so the page marks them and lists them apart.
    * **Owner split.** A span that moved owner (`owner_changed_at`) is two
      pieces: `owner` from `opened_at` to the move, `owner_at_close` (who owns
      it now, while open) from the move to the end. Coordinator and operator
      time are summed from the pieces, never from the span's opening owner.
      Only the last move is recorded, so a span handed back and forth more than
      once is attributed to its first and last owner.
    * **P50 / P90** are per cause, over each span's whole duration (nearest
      rank, `Arbiter.Reports.Throughput.percentile/2`, so every report shares
      one definition). Open spans are included at their duration so far.
    * Hours are real elapsed hours; a span is attributed to the week it opened.
  """

  alias Arbiter.Repo
  alias Arbiter.Reports.Throughput

  @verifying_cause "awaiting_verification"
  @owners [:coordinator, :operator]
  @scope_filters ~w(workspace repo type difficulty epic)
  @open_list_limit 25

  @type piece :: %{
          cause: String.t(),
          owner: :coordinator | :operator,
          from: DateTime.t(),
          to: DateTime.t()
        }

  @type span :: %{
          ticket_id: String.t(),
          cause: String.t(),
          opened_at: DateTime.t(),
          cleared_at: DateTime.t() | nil,
          owner: atom(),
          owner_changed_at: DateTime.t() | nil,
          owner_at_close: atom() | nil
        }

  @doc "The cause the `verifying` dwell is reported under."
  @spec verifying_cause() :: String.t()
  def verifying_cause, do: @verifying_cause

  @spec load(map(), DateTime.t()) :: map()
  def load(filters, now \\ DateTime.utc_now()) do
    cutoff = cutoff(Map.get(filters, "range", "all"), now)
    scope = scope(filters, "ticket_id")

    compute(read_spans(scope, cutoff), read_dwell(scope, cutoff, now), now)
  end

  @doc """
  The report from already-read `spans` (see `t:span/0`, plus `source`) and
  `dwell` — `verifying` stretches as `%{ticket_id:, opened_at:, cleared_at:}`
  with a nil `cleared_at` while the ticket is still verifying. Pure.
  """
  @spec compute([map()], [map()], DateTime.t()) :: map()
  def compute(spans, dwell, now) do
    stored = Enum.reject(spans, &(&1.cause == @verifying_cause))

    waits =
      Enum.map(stored, &wait(&1, now)) ++
        Enum.map(dwell, fn d ->
          wait(
            Map.merge(d, %{
              cause: @verifying_cause,
              owner: :coordinator,
              owner_changed_at: nil,
              owner_at_close: nil
            }),
            now
          )
        end)

    open = waits |> Enum.filter(& &1.open?) |> Enum.sort_by(& &1.hours, :desc)

    %{
      spans: length(waits),
      open: length(open),
      causes: causes(waits),
      owners: owner_hours(waits),
      weekly: weekly(waits),
      cells: cells(waits),
      waiting: open |> Enum.take(@open_list_limit) |> Enum.map(&waiting_row/1)
    }
  end

  # ---- model -------------------------------------------------------------

  defp wait(span, now) do
    to = span.cleared_at || now
    pieces = pieces(span, to)

    %{
      ticket_id: span.ticket_id,
      cause: span.cause,
      opened_at: span.opened_at,
      open?: is_nil(span.cleared_at),
      hours: hours(span.opened_at, to),
      owner: List.last(pieces).owner,
      pieces: pieces
    }
  end

  defp pieces(%{owner_changed_at: nil} = span, to),
    do: [piece(span, span.owner, span.opened_at, to)]

  defp pieces(span, to) do
    moved = clamp(span.owner_changed_at, span.opened_at, to)
    last = span.owner_at_close || span.owner

    [piece(span, span.owner, span.opened_at, moved), piece(span, last, moved, to)]
  end

  defp piece(span, owner, from, to), do: %{cause: span.cause, owner: owner, from: from, to: to}

  defp clamp(at, lo, hi) do
    cond do
      DateTime.compare(at, lo) == :lt -> lo
      DateTime.compare(at, hi) == :gt -> hi
      true -> at
    end
  end

  defp hours(from, to), do: max(DateTime.diff(to, from, :microsecond), 0) / 3_600_000_000

  defp piece_hours(%{from: from, to: to}), do: hours(from, to)

  # ---- aggregates --------------------------------------------------------

  defp causes(waits) do
    waits
    |> Enum.group_by(& &1.cause)
    |> Enum.map(fn {cause, group} ->
      sorted = group |> Enum.map(& &1.hours) |> Enum.sort()
      by_owner = owner_hours(group)

      %{
        cause: cause,
        n: length(group),
        open: Enum.count(group, & &1.open?),
        total_hours: Enum.sum(sorted),
        p50_hours: Throughput.percentile(sorted, 0.5),
        p90_hours: Throughput.percentile(sorted, 0.9),
        coordinator_hours: by_owner.coordinator,
        operator_hours: by_owner.operator
      }
    end)
    |> Enum.sort_by(&{-&1.total_hours, &1.cause})
  end

  defp owner_hours(waits) do
    base = Map.new(@owners, &{&1, 0.0})

    waits
    |> Enum.flat_map(& &1.pieces)
    |> Enum.reduce(base, fn piece, acc ->
      Map.update(acc, piece.owner, 0.0, &(&1 + piece_hours(piece)))
    end)
  end

  # `{week, cause, owner}` → hours, week = the Monday the span opened.
  defp cells(waits) do
    waits
    |> Enum.flat_map(fn w ->
      week = w.opened_at |> DateTime.to_date() |> Date.beginning_of_week()
      Enum.map(w.pieces, &{{week, &1.cause, &1.owner}, piece_hours(&1)})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {{week, cause, owner}, hs} ->
      %{week: week, cause: cause, owner: owner, hours: Enum.sum(hs)}
    end)
    |> Enum.sort_by(&{&1.week, &1.cause, &1.owner}, fn a, b -> a <= b end)
  end

  defp weekly(waits) do
    by_week = waits |> cells() |> Enum.group_by(& &1.week)

    case Map.keys(by_week) do
      [] ->
        []

      weeks ->
        {first, last} = {Enum.min(weeks, Date), Enum.max(weeks, Date)}

        Enum.map(Date.range(first, last, 7), fn week ->
          rows = Map.get(by_week, week, [])

          %{
            week: week,
            hours:
              Map.new(@owners, fn o -> {o, rows |> Enum.filter(&(&1.owner == o)) |> sum()} end)
          }
        end)
    end
  end

  defp sum(rows), do: rows |> Enum.map(& &1.hours) |> Enum.sum()

  defp waiting_row(w) do
    Map.take(w, [:ticket_id, :cause, :owner, :opened_at, :hours])
  end

  # ---- reads -------------------------------------------------------------

  defp read_spans({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "opened_at")

    """
    SELECT ticket_id, cause, owner, owner_changed_at, owner_at_close, opened_at, cleared_at
    FROM ticket_attention_spans
    WHERE 1 = 1 #{scope_sql} #{range_sql}
    ORDER BY opened_at
    """
    |> query(scope_params ++ range_params)
    |> Enum.map(fn [ticket_id, cause, owner, changed, at_close, opened, cleared] ->
      %{
        ticket_id: ticket_id,
        cause: cause,
        owner: owner(owner),
        owner_changed_at: parse(changed),
        owner_at_close: owner(at_close),
        opened_at: parse(opened),
        cleared_at: parse(cleared)
      }
    end)
  end

  # Every transition of a ticket that ever entered `verifying` (in range), so
  # each stretch ends at the ticket's next transition.
  defp read_dwell({scope_sql, scope_params}, cutoff, _now) do
    {range_sql, range_params} = range(cutoff, "at")

    """
    SELECT ticket_id, to_state, at FROM ticket_transitions
    WHERE ticket_id IN (
      SELECT ticket_id FROM ticket_transitions
      WHERE to_state = 'verifying' #{scope_sql} #{range_sql})
    ORDER BY ticket_id, at, id
    """
    |> query(scope_params ++ range_params)
    |> Enum.group_by(&hd/1, fn [_id, state, at] -> {state, parse(at)} end)
    |> Enum.flat_map(fn {ticket_id, rows} -> dwell(ticket_id, rows, cutoff) end)
  end

  defp dwell(ticket_id, rows, cutoff) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{"verifying", at}, i} ->
        if in_range?(at, cutoff) do
          cleared = rows |> Enum.at(i + 1) |> then(&(&1 && elem(&1, 1)))
          [%{ticket_id: ticket_id, opened_at: at, cleared_at: cleared}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp in_range?(_at, nil), do: true
  defp in_range?(at, cutoff), do: DateTime.compare(at, parse(cutoff)) != :lt

  # ---- helpers -----------------------------------------------------------

  # Every `?` is a bound parameter; what is interpolated is this module's own
  # constant fragments and column names, never request input.
  # sobelow_skip ["SQL.Query"]
  defp query(sql, params), do: Repo.query!(sql, params).rows

  defp owner(nil), do: nil
  defp owner(owner) when owner in ["coordinator", "operator"], do: String.to_existing_atom(owner)

  defp parse(nil), do: nil

  defp parse(%DateTime{} = at), do: at

  defp parse(stamp) do
    {:ok, at, _} = DateTime.from_iso8601(stamp)
    at
  end

  defp scope(filters, column) do
    {conds, params} =
      @scope_filters
      |> Enum.flat_map(fn key ->
        case Map.get(filters, key, "") do
          "" -> []
          value -> [scope_cond(key, value)]
        end
      end)
      |> Enum.unzip()

    case conds do
      [] ->
        {"", []}

      _ ->
        {"AND #{column} IN (SELECT id FROM issues WHERE issue_type != 'epic' AND " <>
           Enum.join(conds, " AND ") <> ")", List.flatten(params)}
    end
  end

  defp scope_cond("workspace", id), do: {"workspace_id = ?", [id]}
  defp scope_cond("repo", repo), do: {"repo = ?", [repo]}
  defp scope_cond("type", type), do: {"issue_type = ?", [type]}
  defp scope_cond("difficulty", d), do: {"difficulty = ?", [String.to_integer(d)]}

  defp scope_cond("epic", epic) do
    {"id IN (SELECT to_issue_id FROM dependencies WHERE type = 'parent_of' AND from_issue_id = ?)",
     [epic]}
  end

  defp range(nil, _column), do: {"", []}
  defp range(cutoff, column), do: {"AND #{column} >= ?", [cutoff]}

  defp cutoff("all", _now), do: nil

  defp cutoff(range, now) do
    days = range |> String.trim_trailing("d") |> String.to_integer()
    at = DateTime.add(now, -days * 86_400, :second)
    DateTime.to_iso8601(%{at | microsecond: {elem(at.microsecond, 0), 6}})
  end
end
