defmodule Arbiter.Reports.BurnUp do
  @moduledoc """
  Epic burn-up for `/reports` (bd-cl2rtd; design
  `docs/design/reports-design-v2.md` §5.7, D2: one chart over transitions and
  dependency edges).

  Two step lines per day, each in a ticket count and a difficulty-weighted
  variant (`Arbiter.Reports.Throughput.weight/1`):

    * **scope** — the epic's direct children (`parent_of` edges) whose edge
      `created_at` is on or before the end of that day. Scope moves: a burn-up,
      not a burn-down.
    * **done** — children in scope whose latest `ticket_transitions` row at or
      before the end of that day is `closed`. A reopen writes a later,
      non-closed row, so the line steps back down.

  A child that closed before it was attached to the epic only counts as done
  from the day its edge appears, so done never exceeds scope. Edge removals
  before 2026-09-15 left no trace (design §5.7); a removed child stays in scope.
  """

  import Ecto.Query

  alias Arbiter.Repo
  alias Arbiter.Reports.Throughput
  alias Arbiter.Tasks.Lifecycle

  @state_names Map.new(Lifecycle.states(), &{Atom.to_string(&1), &1})

  @type edge :: %{child_id: String.t(), at: DateTime.t(), weight: number()}
  @type transition :: %{ticket_id: String.t(), to_state: Lifecycle.state(), at: DateTime.t()}

  @doc """
  The burn-up of `epic_id`, or `[]` when it has no children. `range` is
  `"all"` or `"<n>d"`; the window opens at the epic's creation (or its first
  edge, if earlier), clipped to the range, and ends at `now`.
  """
  @spec load(String.t(), String.t(), DateTime.t()) :: [map()]
  def load(epic_id, range \\ "all", now \\ DateTime.utc_now())
  def load("", _range, _now), do: []

  def load(epic_id, range, now) do
    edges = edges(epic_id)

    if edges == [] do
      []
    else
      rows = transitions(Enum.map(edges, & &1.child_id))
      first = [epic_created(epic_id) | Enum.map(edges, & &1.at)] |> dates() |> Enum.min(Date)
      from = clip(first, range, now)
      burn_up(edges, rows, from, DateTime.to_date(now))
    end
  end

  defp dates(list), do: list |> Enum.reject(&is_nil/1) |> Enum.map(&DateTime.to_date/1)

  defp clip(first, "all", _now), do: first

  defp clip(first, range, now) do
    days = range |> String.trim_trailing("d") |> String.to_integer()
    Enum.max([first, now |> DateTime.add(-days * 86_400, :second) |> DateTime.to_date()], Date)
  end

  defp epic_created(epic_id) do
    from(i in "issues",
      where: i.id == ^epic_id,
      select: type(i.created_at, :utc_datetime_usec)
    )
    |> Repo.one()
  end

  defp edges(epic_id) do
    from(d in "dependencies",
      join: i in "issues",
      on: i.id == d.to_issue_id,
      where: d.type == "parent_of" and d.from_issue_id == ^epic_id,
      select: %{
        child_id: d.to_issue_id,
        at: type(d.created_at, :utc_datetime_usec),
        difficulty: i.difficulty
      }
    )
    |> Repo.all()
    |> Enum.map(fn e ->
      %{child_id: e.child_id, at: e.at, weight: Throughput.weight(e.difficulty)}
    end)
  end

  # An epic has a bounded number of children, so a bound id list is safe.
  defp transitions(ids) do
    from(t in "ticket_transitions",
      where: t.ticket_id in ^ids,
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

  @doc """
  One point per day from `from` to `to`:
  `%{day, scope, done, scope_weight, done_weight}`. Transitions may arrive in
  any order across tickets; a ticket's own rows are read by `at`, ties in the
  order given.
  """
  @spec burn_up([edge()], [transition()], Date.t(), Date.t()) :: [map()]
  def burn_up(edges, transitions, %Date{} = from, %Date{} = to) do
    by_ticket =
      transitions
      |> Enum.group_by(& &1.ticket_id)
      |> Map.new(fn {id, rows} -> {id, Enum.sort_by(rows, & &1.at, DateTime)} end)

    edges = Enum.map(edges, &Map.put(&1, :day, DateTime.to_date(&1.at)))
    days = if Date.compare(from, to) == :gt, do: [], else: Enum.to_list(Date.range(from, to))

    for day <- days do
      in_scope = Enum.filter(edges, &(Date.compare(&1.day, day) != :gt))
      done = Enum.filter(in_scope, &closed_on?(Map.get(by_ticket, &1.child_id, []), day))

      %{
        day: day,
        scope: length(in_scope),
        done: length(done),
        scope_weight: weight(in_scope),
        done_weight: weight(done)
      }
    end
  end

  defp weight(edges), do: edges |> Enum.map(& &1.weight) |> Enum.sum()

  # Latest row at or before the end of `day` is `closed`.
  defp closed_on?(rows, day) do
    rows
    |> Enum.take_while(&(Date.compare(DateTime.to_date(&1.at), day) != :gt))
    |> List.last()
    |> case do
      %{to_state: :closed} -> true
      _ -> false
    end
  end
end
