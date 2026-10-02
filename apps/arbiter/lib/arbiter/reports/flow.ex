defmodule Arbiter.Reports.Flow do
  @moduledoc """
  Cumulative flow and stage dwell for `/reports` (bd-836iuz; design
  `docs/design/reports-design-v2.md` §5.1 and the stage half of §5.2), both
  derived from `ticket_transitions` as intervals: a row opens an interval in
  its `to_state` that the ticket's next row closes.

  The two reports read slim `(ticket_id, to_state, at)` rows, filtered by a
  join-free subquery over `issues`, and the interval arithmetic is pure so it
  is checked against hand-traced tickets (`cumulative_flow/3`,
  `ticket_dwell/1`, `stage_dwell/2`).

  ## Repeats and reopens

  A ticket can enter a state more than once (`return_to_work`, a requeue, a
  `reopen`). Both reports work on *intervals*, never on "the" entry:

    * **Cumulative flow** — on day *d* a ticket is in the `to_state` of the
      last row at or before the end of *d*. A same-day detour (`active` →
      `merging` → `closed` within one day) leaves no trace on the day it
      happened; a reopen steps the ticket back out of `closed`. Every ticket
      is in exactly one band from its first row on, so Σ bands = tickets
      created by *d*.
    * **Stage dwell** — a stage's dwell for a ticket is the **sum** of that
      state's intervals: the second `active` after a `return_to_work` adds to
      the first, and a reopened ticket's `queued` time is both passes. Time
      spent `closed` is not a stage (a reopened ticket's first `closed`
      interval is left out), and a ticket's last, open-ended interval counts
      for nothing — the cohort is closed tickets, whose last interval is
      `closed`.

  ## What "closed" means here

  Epics are never tickets in these reports. Cumulative flow counts every
  non-epic ticket that matches the filters, whatever its state. Stage dwell
  is over **completed** tickets (`state = closed`, `close_reason = completed`)
  whose `closed_at` falls in the range, as throughput is.

  ## Era caveats (design §3.2)

  History before 2026-08-24 has no backlog (`queued` meant "open"), and in
  the pre-lifecycle era `merging` begins at the first `pr_ref`. Both reports
  state that on the page; neither tries to repair it.
  """

  import Ecto.Query

  alias Arbiter.Repo
  alias Arbiter.Reports.{Epics, Throughput}
  alias Arbiter.Tasks.Lifecycle

  @states Lifecycle.states()
  @state_names Map.new(@states, &{Atom.to_string(&1), &1})
  # The stages dwell reports; `backlog` is kept in the per-ticket map for
  # completeness but is not a delivery stage.
  @stages [:queued, :active, :merging, :verifying]
  @dwell_states [:backlog | @stages]
  @micros_per_hour 3_600_000_000

  @doc "The lifecycle states, in lifecycle order (the CFD's bands)."
  @spec states() :: [Lifecycle.state()]
  def states, do: @states

  @doc "The delivery stages stage dwell reports, in flow order."
  @spec stages() :: [Lifecycle.state()]
  def stages, do: @stages

  @type transition :: %{ticket_id: String.t(), to_state: Lifecycle.state(), at: DateTime.t()}

  # ---- loading ----

  @doc """
  Loads both reports. `filters` is the `/reports` filter map; `now` is the
  clock the `range` is measured back from (and the last day of the flow).

  `range` bounds the **window** of the flow (every matching ticket is still
  counted from its creation, so bands keep summing to tickets created) and
  the **`closed_at`** of the stage-dwell cohort.
  """
  @spec load(map(), DateTime.t()) :: %{flow: [map()], dwell: map()}
  def load(filters, now \\ DateTime.utc_now()) do
    cutoff = cutoff(Map.get(filters, "range", "all"), now)
    %{flow: load_flow(filters, cutoff, now), dwell: load_dwell(filters, cutoff)}
  end

  defp load_flow(filters, cutoff, now) do
    tickets = from(i in tickets_query(filters), select: i.id)

    case transitions(tickets) do
      [] ->
        []

      rows ->
        first = rows |> Enum.map(&DateTime.to_date(&1.at)) |> Enum.min(Date)
        from = if cutoff, do: Enum.max([DateTime.to_date(cutoff), first], Date), else: first
        cumulative_flow(rows, from, DateTime.to_date(now))
    end
  end

  defp load_dwell(filters, cutoff) do
    cohort =
      from(i in tickets_query(filters),
        where: i.state == "closed" and i.close_reason == "completed" and not is_nil(i.closed_at)
      )
      |> closed_since(cutoff)

    tickets =
      cohort
      |> select([i], %{
        id: i.id,
        difficulty: i.difficulty,
        closed_at: type(i.closed_at, :utc_datetime_usec)
      })
      |> Repo.all()

    stage_dwell(tickets, transitions(from(i in cohort, select: i.id)))
  end

  defp closed_since(query, nil), do: query

  defp closed_since(query, cutoff),
    do: where(query, [i], i.closed_at >= type(^cutoff, :utc_datetime_usec))

  defp cutoff("all", _now), do: nil

  defp cutoff(range, now) do
    days = range |> String.trim_trailing("d") |> String.to_integer()
    DateTime.add(now, -days * 86_400, :second)
  end

  # Non-epic tickets that match the filters, one id per row. A subquery, never
  # a bound id list (SQLite's expression-tree limit, design §6).
  defp tickets_query(filters) do
    Enum.reduce(filters, from(i in "issues", where: i.issue_type != "epic"), fn
      {_, ""}, q -> q
      {"workspace", id}, q -> where(q, [i], i.workspace_id == ^id)
      {"repo", repo}, q -> where(q, [i], i.repo == ^repo)
      {"type", type}, q -> where(q, [i], i.issue_type == ^type)
      {"difficulty", d}, q -> where(q, [i], i.difficulty == ^String.to_integer(d))
      {"epic", epic}, q -> where(q, [i], i.id in subquery(Epics.children_query(epic)))
      _, q -> q
    end)
  end

  # Slim rows, in the order the table guarantees: `at`, then insertion order.
  defp transitions(ticket_ids) do
    from(t in "ticket_transitions",
      where: t.ticket_id in subquery(ticket_ids),
      order_by: [t.ticket_id, t.at, fragment("rowid")],
      select: %{
        ticket_id: t.ticket_id,
        to_state: t.to_state,
        at: type(t.at, :utc_datetime_usec)
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | to_state: Map.fetch!(@state_names, &1.to_state)})
  end

  # ---- cumulative flow ----

  @doc """
  One point per day from `from` to `to`: `%{day, counts, total}`, where
  `counts` has every state and `total` is their sum — the tickets created by
  the end of that day. Rows are `t:transition/0`s in any order across
  tickets; a ticket's own rows are read by `at`, ties in the order given.
  """
  @spec cumulative_flow([transition()], Date.t(), Date.t()) :: [map()]
  def cumulative_flow(transitions, %Date{} = from, %Date{} = to) do
    days = if Date.compare(from, to) == :gt, do: [], else: Enum.to_list(Date.range(from, to))

    in_state =
      transitions
      |> Enum.group_by(& &1.ticket_id)
      |> Enum.reduce(%{}, fn {_id, rows}, acc ->
        rows
        |> sorted()
        |> spans()
        |> Enum.reduce(acc, fn {state, first_day, last_day}, acc ->
          clip_days(first_day, last_day, from, to)
          |> Enum.reduce(acc, fn day, acc -> Map.update(acc, {day, state}, 1, &(&1 + 1)) end)
        end)
      end)

    for day <- days do
      counts = Map.new(@states, &{&1, Map.get(in_state, {day, &1}, 0)})
      %{day: day, counts: counts, total: counts |> Map.values() |> Enum.sum()}
    end
  end

  # `{state, first_day, last_day}`: the days a row is the ticket's state *at
  # the end of the day*. A row superseded the day it was written has none.
  defp spans(rows) do
    rows
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [row, next] ->
        first = DateTime.to_date(row.at)
        last = next.at |> DateTime.to_date() |> Date.add(-1)
        if Date.compare(last, first) == :lt, do: [], else: [{row.to_state, first, last}]

      [row] ->
        [{row.to_state, DateTime.to_date(row.at), :open}]
    end)
  end

  defp clip_days(first, last, from, to) do
    first = Enum.max([first, from], Date)
    last = if last == :open, do: to, else: Enum.min([last, to], Date)
    if Date.compare(first, last) == :gt, do: [], else: Date.range(first, last)
  end

  # ---- stage dwell ----

  @doc """
  Hours in each of `backlog`, `queued`, `active`, `merging`, `verifying` for
  one ticket's rows: the sum of that state's intervals (see the moduledoc).
  """
  @spec ticket_dwell([transition()]) :: %{Lifecycle.state() => float()}
  def ticket_dwell(rows) do
    zero = Map.new(@dwell_states, &{&1, 0.0})

    rows
    |> sorted()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(zero, fn [row, next], acc ->
      if row.to_state in @dwell_states do
        hours = DateTime.diff(next.at, row.at, :microsecond) / @micros_per_hour
        Map.update!(acc, row.to_state, &(&1 + hours))
      else
        acc
      end
    end)
  end

  @doc """
  Stage dwell over a cohort of closed tickets (`%{id, difficulty, closed_at}`)
  and their transitions. A ticket with no rows is skipped.

    * `overall` — P50/P90 hours per stage, nearest-rank, over every ticket in
      the cohort (a ticket that never merged contributes 0 to `merging`);
    * `by_difficulty` — the median per stage for each difficulty, D0…D4 then
      unrated (`nil`, which also takes any difficulty above D4);
    * `first_pr` — hours from first `active` to first `merging`, over tickets
      that merged;
    * `queued_to_closed` — hours from first `queued` to `closed_at`.
  """
  @spec stage_dwell([map()], [transition()]) :: map()
  def stage_dwell(tickets, transitions) do
    by_ticket = Enum.group_by(transitions, & &1.ticket_id)

    rows =
      for ticket <- tickets, {:ok, trans} <- [Map.fetch(by_ticket, ticket.id)] do
        trans = sorted(trans)
        {ticket, ticket_dwell(trans), trans}
      end

    dwells = Enum.map(rows, &elem(&1, 1))

    %{
      n: length(rows),
      stages: @stages,
      overall: Map.new(@stages, &{&1, percentiles(Enum.map(dwells, fn d -> d[&1] end))}),
      by_difficulty: by_difficulty(rows),
      first_pr: first_pr(rows),
      queued_to_closed: queued_to_closed(rows)
    }
  end

  defp by_difficulty(rows) do
    rows
    |> Enum.group_by(fn {t, _, _} -> rank(t.difficulty) end)
    |> Enum.sort_by(fn {d, _} -> if d == nil, do: 99, else: d end)
    |> Enum.map(fn {d, group} ->
      dwells = Enum.map(group, &elem(&1, 1))

      %{
        difficulty: d,
        n: length(group),
        medians: Map.new(@stages, &{&1, median(Enum.map(dwells, fn dw -> dw[&1] end))})
      }
    end)
  end

  defp rank(d), do: if(Map.has_key?(Throughput.weights(), d), do: d)

  defp first_pr(rows) do
    rows
    |> Enum.flat_map(fn {_, _, trans} ->
      with %{at: active} <- Enum.find(trans, &(&1.to_state == :active)),
           %{at: merging} <- Enum.find(trans, &(&1.to_state == :merging)) do
        [max(DateTime.diff(merging, active, :microsecond), 0) / @micros_per_hour]
      else
        _ -> []
      end
    end)
    |> summary()
  end

  defp queued_to_closed(rows) do
    rows
    |> Enum.flat_map(fn {ticket, _, trans} ->
      case Enum.find(trans, &(&1.to_state == :queued)) do
        nil ->
          []

        %{at: queued} ->
          [max(DateTime.diff(ticket.closed_at, queued, :microsecond), 0) / @micros_per_hour]
      end
    end)
    |> summary()
  end

  defp summary(hours), do: Map.put(percentiles(hours), :n, length(hours))

  defp percentiles(hours) do
    sorted = Enum.sort(hours)

    %{
      p50_hours: Throughput.percentile(sorted, 0.5),
      p90_hours: Throughput.percentile(sorted, 0.9)
    }
  end

  defp median(hours), do: hours |> Enum.sort() |> Throughput.percentile(0.5)

  defp sorted(rows), do: Enum.sort_by(rows, & &1.at, DateTime)
end
