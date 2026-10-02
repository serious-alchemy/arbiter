defmodule Arbiter.Tasks.EpicFloor do
  @moduledoc """
  Pure resolver for a ticket's effective priority under epic floors
  (`docs/design/epic-aware-scheduling.md` §4, §6.1; ticket ES1).

  Takes issues plus `{parent_id, child_id}` pairs (the `:parent_of` edges, as
  `Arbiter.Board.Snapshot` already carries them) and returns, per ticket id:

      %{
        own: 2,             # the ticket's own priority
        effective: 1,       # min(own, every floor on an epic ancestor)
        via: "bd-epic",     # the epic supplying the winning floor, or nil
        lifted?: true,      # effective is strictly better than own
        nearest_epic: "bd-epic" | nil,
        open_leaves: 7,     # non-closed leaf descendants of the nearest epic
        in_progress: 2      # of that epic's leaves: active/merging/verifying or closed completed
      }

  Priority is numeric, lower is more urgent, so "never less urgent" is
  `effective <= own`.

  ## Walk

  Ancestors are found breadth-first over the parent edges with a visited set
  and a depth cap of #{8} (`parent_of` cycles are not prevented on insert).
  Non-epic parents are walked through but carry no floor. Floors compose by
  `min`; `via` is the winning epic, the nearest on a tie (then lowest id).
  The nearest epic is the closest `:epic` ancestor; with several at the same
  depth, the one with the fewest open leaves (then lowest id). Leaves are the
  non-epic descendants of that epic with no children, walked through
  sub-epics with the same guards. Edges naming ids not in `issues` are
  ignored. The result never depends on the order of the edge list.

  An issue is anything with `:id`, `:priority`, `:issue_type`, `:state`,
  `:close_reason` and optionally `:floor_priority` (nil or absent: no floor;
  honoured only on epics, only within 1..3).
  """

  @max_depth 8
  @in_progress_states [:active, :merging, :verifying]

  @type resolution :: %{
          own: integer(),
          effective: integer(),
          via: String.t() | nil,
          lifted?: boolean(),
          nearest_epic: String.t() | nil,
          open_leaves: non_neg_integer(),
          in_progress: non_neg_integer()
        }

  @doc "The depth cap on the ancestor and descendant walks."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "Resolves every issue. See the moduledoc."
  @spec resolve([map()], [{String.t(), String.t()}]) :: %{String.t() => resolution()}
  def resolve(issues, parent_of) do
    by_id = Map.new(issues, &{&1.id, &1})

    pairs =
      parent_of
      |> Enum.filter(fn {p, c} -> Map.has_key?(by_id, p) and Map.has_key?(by_id, c) end)
      |> Enum.uniq()

    parents = adjacency(pairs, fn {p, c} -> {c, p} end)
    children = adjacency(pairs, fn {p, c} -> {p, c} end)

    leaves_of =
      Map.new(by_id, fn {id, issue} ->
        {id, if(epic?(issue), do: leaves(id, children, by_id), else: [])}
      end)

    Map.new(by_id, fn {id, issue} ->
      {id, resolve_one(issue, ancestors(id, parents), by_id, leaves_of)}
    end)
  end

  @doc "Resolves one ticket id; `nil` when it isn't in `issues`."
  @spec resolve_one_id([map()], [{String.t(), String.t()}], String.t()) :: resolution() | nil
  def resolve_one_id(issues, parent_of, id), do: issues |> resolve(parent_of) |> Map.get(id)

  defp resolve_one(issue, ancestors, by_id, leaves_of) do
    epics =
      for {id, depth} <- ancestors,
          a = Map.fetch!(by_id, id),
          epic?(a),
          do: {id, depth, a}

    {via, floor} =
      epics
      |> Enum.flat_map(fn {id, depth, a} ->
        case floor_of(a) do
          nil -> []
          f -> [{f, depth, id}]
        end
      end)
      |> Enum.min(fn -> nil end)
      |> case do
        nil -> {nil, nil}
        {f, _depth, id} -> {id, f}
      end

    own = issue.priority
    effective = if floor, do: min(own, floor), else: own
    lifted? = effective < own

    nearest =
      case epics do
        [] ->
          nil

        _ ->
          min_depth = epics |> Enum.map(&elem(&1, 1)) |> Enum.min()

          epics
          |> Enum.filter(&(elem(&1, 1) == min_depth))
          |> Enum.map(fn {id, _, _} -> id end)
          |> Enum.min_by(fn id -> {length(open(leaves_of[id])), id} end)
      end

    {open_leaves, in_progress} =
      case nearest do
        nil -> {0, 0}
        id -> {length(open(leaves_of[id])), Enum.count(leaves_of[id], &in_progress?/1)}
      end

    %{
      own: own,
      effective: effective,
      via: if(lifted?, do: via),
      lifted?: lifted?,
      nearest_epic: nearest,
      open_leaves: open_leaves,
      in_progress: in_progress
    }
  end

  # `[{id, depth}]` of the strict ancestors, breadth-first, depth-capped.
  defp ancestors(id, parents), do: walk([id], MapSet.new([id]), parents, 1, [])

  defp walk([], _seen, _adj, _depth, acc), do: acc
  defp walk(_frontier, _seen, _adj, depth, acc) when depth > @max_depth, do: acc

  defp walk(frontier, seen, adj, depth, acc) do
    next =
      frontier
      |> Enum.flat_map(&Map.get(adj, &1, []))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(seen, &1))

    walk(
      next,
      Enum.reduce(next, seen, &MapSet.put(&2, &1)),
      adj,
      depth + 1,
      acc ++ Enum.map(next, &{&1, depth})
    )
  end

  # Leaf descendants of `epic_id` (non-epic, childless), as issues.
  defp leaves(epic_id, children, by_id) do
    epic_id
    |> ancestors(children)
    |> Enum.map(fn {id, _} -> Map.fetch!(by_id, id) end)
    |> Enum.filter(&(not epic?(&1) and Map.get(children, &1.id, []) == []))
    |> Enum.reject(&(&1.id == epic_id))
  end

  defp adjacency(pairs, fun) do
    pairs
    |> Enum.map(fun)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {k, vs} -> {k, Enum.sort(vs)} end)
  end

  defp epic?(issue), do: issue.issue_type == :epic

  defp floor_of(issue) do
    case Map.get(issue, :floor_priority) do
      f when is_integer(f) and f in 1..3 -> f
      _ -> nil
    end
  end

  defp open(leaves), do: Enum.reject(leaves, &(&1.state == :closed))

  defp in_progress?(%{state: state}) when state in @in_progress_states, do: true
  defp in_progress?(%{state: :closed} = i), do: Map.get(i, :close_reason) == :completed
  defp in_progress?(_), do: false
end
