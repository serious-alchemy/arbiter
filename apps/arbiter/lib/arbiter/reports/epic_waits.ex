defmodule Arbiter.Reports.EpicWaits do
  @moduledoc """
  The epic Ready-wait readout for `/reports` (bd-agj7wt, ES7; design
  `docs/design/epic-aware-scheduling.md` §9): do the last children of an epic
  wait longer in Ready than the first ones, and is that fix slowing tickets that
  have no parent. A port of
  `docs/design/epic-aware-scheduling/measure_epic_waits.py` (its sections 1 and
  the guard line); keep the two in step, `test/fixtures/epic_waits.json` is the
  parity fixture.

  Method, as in the script:

    * `ticket_transitions` stores lifecycle states, so Ready and Blocked are both
      `queued`. A queued span counts as Ready only after every gating blocker
      (`depends_on` targets, `blocks` sources) has closed, using today's edges and
      each blocker's latest `closed_at`. A span still open is counted up to `now`.
    * *Head / middle / tail* is a child's position in its epic's close order (over
      the epic's direct non-epic children, epics with at least three): the first
      50%, 50-80% and the last 20% of siblings to close.
    * Only closed children and closed parentless tickets (no `parent_of` edge, not
      an epic) with a Ready span are measured.
    * The **guard** is the Ready wait of closed parentless P1 and P2 tickets: the
      epic floor must not push it up.

  Everything is hours. Percentiles are the script's: `p90` is the sorted value at
  `min(n - 1, trunc(0.9 * n))`.
  """

  alias Arbiter.Repo

  @epoch ~U[0001-01-01 00:00:00Z]
  @min_children 3

  defp buckets do
    [
      {:head, "head (first 50% to close)", &(&1 < 0.5)},
      {:middle, "middle (50-80%)", &(&1 >= 0.5 and &1 < 0.8)},
      {:tail, "tail (last 20% to close)", &(&1 >= 0.8)}
    ]
  end

  @type summary :: %{
          n: non_neg_integer(),
          median: float() | nil,
          p75: float() | nil,
          p90: float() | nil,
          mean: float() | nil
        }

  @type data :: %{
          issues: [
            %{
              id: String.t(),
              priority: integer(),
              state: String.t(),
              type: String.t(),
              closed_at: DateTime.t() | nil
            }
          ],
          dependencies: [{String.t(), String.t(), String.t()}],
          transitions: [{String.t(), String.t() | nil, String.t(), DateTime.t()}]
        }

  @doc "The summary of an empty sample."
  @spec empty_summary() :: summary()
  def empty_summary, do: %{n: 0, median: nil, p75: nil, p90: nil, mean: nil}

  @doc """
  Reads the readout for `filters` (the `/reports` filter map; `workspace` and
  `range` apply). `range` windows the measured tickets by close time; sibling
  order and blocker edges always see the whole epic.
  """
  @spec load(map(), DateTime.t()) :: map()
  def load(filters, now \\ DateTime.utc_now()) do
    workspace = Map.get(filters, "workspace", "")
    {data, ids} = read(workspace, now)

    compute(data, now,
      subject?: &MapSet.member?(ids, &1),
      closed_since: closed_since(Map.get(filters, "range", "all"), now)
    )
  end

  @doc """
  The pure computation. `opts`: `subject?` (ticket id → boolean, default all;
  the script's workspace prefix) and `closed_since` (a `DateTime` or nil).
  Transitions after `now` are ignored.
  """
  @spec compute(data(), DateTime.t(), keyword()) :: map()
  def compute(data, now, opts \\ []) do
    subject? = Keyword.get(opts, :subject?, fn _ -> true end)
    since = Keyword.get(opts, :closed_since)
    d = index(data, now)

    done =
      d
      |> epic_children(subject?)
      |> Enum.filter(
        &(&1.pos != nil and not &1.open? and in_range?(d.issues[&1.id].closed_at, since))
      )

    loose = parentless(d, subject?, since)

    %{
      closed_children: length(done),
      buckets:
        for {key, label, test} <- buckets() do
          sel = Enum.filter(done, &test.(&1.pos))

          %{
            key: key,
            label: label,
            all: summary(Enum.map(sel, & &1.wait)),
            p2: summary(for(r <- sel, r.priority == 2, do: r.wait))
          }
        end,
      by_priority:
        for p <- 0..4 do
          %{
            priority: p,
            epic_child: summary(for(r <- done, r.priority == p, do: r.wait)),
            parentless: summary(for({q, w} <- loose, q == p, do: w))
          }
        end,
      guard: summary(for({q, w} <- loose, q in [1, 2], do: w))
    }
  end

  # {priority, wait} per closed ticket with no parent, not an epic, that was Ready.
  defp parentless(d, subject?, since) do
    for {id, i} <- d.issues,
        subject?.(id),
        not Map.has_key?(d.parents, id),
        i.type != "epic",
        closed_by?(d, id),
        ready_spans(d, id) != [],
        in_range?(i.closed_at, since),
        do: {i.priority, elem(ready_wait(d, id), 0)}
  end

  @doc "Median, p75, p90 and mean of `values` (hours), the script's way."
  @spec summary([number()]) :: summary()
  def summary([]), do: empty_summary()

  def summary(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    pct = fn f -> Enum.at(sorted, min(n - 1, trunc(f * n))) end

    %{
      n: n,
      median: median(sorted, n),
      p75: pct.(0.75),
      p90: pct.(0.90),
      mean: Enum.sum(sorted) / n
    }
  end

  defp median(sorted, n) do
    if rem(n, 2) == 1 do
      Enum.at(sorted, div(n, 2)) * 1.0
    else
      (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
    end
  end

  # ---- model ------------------------------------------------------------

  defp index(data, now) do
    issues = Map.new(data.issues, &{&1.id, &1})

    edges =
      Enum.reduce(data.dependencies, %{kids: %{}, parents: %{}, gates: %{}}, fn
        {from, to, "parent_of"}, acc ->
          %{
            acc
            | kids: Map.update(acc.kids, from, [to], &(&1 ++ [to])),
              parents: Map.put(acc.parents, to, true)
          }

        {from, to, "depends_on"}, acc ->
          %{acc | gates: Map.update(acc.gates, from, [to], &(&1 ++ [to]))}

        {from, to, "blocks"}, acc ->
          %{acc | gates: Map.update(acc.gates, to, [from], &(&1 ++ [from]))}

        _, acc ->
          acc
      end)

    trans =
      data.transitions
      |> Enum.filter(fn {_, _, _, at} -> DateTime.compare(at, now) != :gt end)
      |> Enum.sort_by(fn {_, _, _, at} -> at end, DateTime)
      |> Enum.group_by(&elem(&1, 0))

    Map.merge(edges, %{issues: issues, trans: trans, now: now})
  end

  defp closed_by?(d, id), do: closed_by?(d, id, d.now)

  defp closed_by?(d, id, at) do
    i = d.issues[id]
    i.state == "closed" and i.closed_at != nil and DateTime.compare(i.closed_at, at) != :gt
  end

  defp epic?(d, id), do: match?(%{type: "epic"}, d.issues[id])

  defp ready_spans(d, id) do
    {spans, cur} =
      d.trans
      |> Map.get(id, [])
      |> Enum.reduce({[], nil}, fn
        {_, _, "queued", at}, {spans, nil} ->
          {spans, at}

        {_, "queued", to, at}, {spans, cur} when to != "queued" and cur != nil ->
          {[{cur, at, to} | spans], nil}

        _, acc ->
          acc
      end)

    Enum.reverse(spans) ++ if(cur, do: [{cur, nil, nil}], else: [])
  end

  # nil while a gating blocker is open; the epoch when nothing gates.
  defp unblocked_at(d, id) do
    closes =
      for b <- Map.get(d.gates, id, []), Map.has_key?(d.issues, b), do: d.issues[b].closed_at

    cond do
      Enum.any?(closes, &(&1 == nil or DateTime.compare(&1, d.now) == :gt)) -> nil
      closes == [] -> @epoch
      true -> Enum.max(closes, DateTime)
    end
  end

  # {hours queued and unblocked, still queued?}
  defp ready_wait(d, id) do
    unblocked = unblocked_at(d, id)
    spans = ready_spans(d, id)

    total =
      if unblocked == nil do
        0.0
      else
        for {start, stop, _} <- spans, reduce: 0.0 do
          acc ->
            s = latest(start, unblocked)
            e = stop || d.now

            if DateTime.compare(e, s) == :gt,
              do: acc + DateTime.diff(e, s, :microsecond) / 3_600_000_000,
              else: acc
        end
      end

    {total, Enum.any?(spans, fn {_, stop, _} -> stop == nil end)}
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  # One row per non-epic direct child, with a Ready span, of an epic that has
  # at least three of them.
  defp epic_children(d, subject?) do
    for {epic, kids} <- d.kids,
        epic?(d, epic),
        subject?.(epic),
        kids = Enum.filter(kids, &(Map.has_key?(d.issues, &1) and not epic?(d, &1))),
        length(kids) >= @min_children,
        order = close_order(d, kids),
        kid <- kids,
        ready_spans(d, kid) != [] do
      {wait, open?} = ready_wait(d, kid)
      idx = Enum.find_index(order, &(&1 == kid))

      %{
        id: kid,
        priority: d.issues[kid].priority,
        wait: wait,
        open?: open?,
        pos: if(idx, do: idx / (length(kids) - 1))
      }
    end
  end

  defp close_order(d, kids) do
    kids
    |> Enum.filter(&closed_by?(d, &1))
    |> Enum.sort_by(&d.issues[&1].closed_at, DateTime)
  end

  # ---- database ---------------------------------------------------------

  defp in_range?(_closed, nil), do: true
  defp in_range?(closed, since), do: DateTime.compare(closed, since) != :lt

  defp closed_since("all", _now), do: nil

  defp closed_since(range, now) do
    days = range |> String.trim_trailing("d") |> String.to_integer()
    DateTime.add(now, -days * 86_400, :second)
  end

  # Whole-fleet issues and edges (blockers and parents may sit in another
  # workspace); transitions only for the measured workspace's tickets.
  defp read(workspace, now) do
    issues =
      "SELECT id, priority, state, issue_type, closed_at, workspace_id FROM issues"
      |> query([])
      |> Enum.map(fn [id, priority, state, type, closed, ws] ->
        {%{id: id, priority: priority, state: state, type: type, closed_at: parse(closed)}, ws}
      end)

    subjects =
      for {i, ws} <- issues, workspace == "" or ws == workspace, into: MapSet.new(), do: i.id

    dependencies =
      "SELECT from_issue_id, to_issue_id, type FROM dependencies ORDER BY rowid"
      |> query([])
      |> Enum.map(fn [from, to, type] -> {from, to, type} end)

    transitions =
      workspace
      |> transition_rows()
      |> Enum.map(fn [id, from, to, at] -> {id, from, to, parse(at)} end)
      |> Enum.reject(fn {_, _, _, at} -> DateTime.compare(at, now) == :gt end)

    {%{
       issues: Enum.map(issues, &elem(&1, 0)),
       dependencies: dependencies,
       transitions: transitions
     }, subjects}
  end

  defp transition_rows("") do
    query(
      "SELECT ticket_id, from_state, to_state, at FROM ticket_transitions ORDER BY at, id",
      []
    )
  end

  defp transition_rows(workspace) do
    query(
      "SELECT ticket_id, from_state, to_state, at FROM ticket_transitions " <>
        "WHERE ticket_id IN (SELECT id FROM issues WHERE workspace_id = ?) ORDER BY at, id",
      [workspace]
    )
  end

  # Every caller passes a literal; the only dynamic part is bound.
  # sobelow_skip ["SQL.Query"]
  defp query(sql, params), do: Repo.query!(sql, params).rows

  defp parse(nil), do: nil

  defp parse(stamp) do
    {:ok, at, _} = DateTime.from_iso8601(stamp)
    at
  end
end
