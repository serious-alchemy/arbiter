defmodule Arbiter.Usage.FollowUpSpend do
  @moduledoc """
  A ticket's spend rolled up from the follow-up tickets filed against it.

  Within one ticket, fix-pass and review spend already folds into the base task
  (`base_task_id`). Work filed as its *own* ticket — a defect follow-up, a CI
  fix for a broken MR — is a separate task, so it is added here instead.

  A follow-up is any ticket with an outbound `:fixes` or `:discovered_from`
  edge to the originating ticket (`follow_up -[fixes]-> original`), followed
  transitively: a follow-up's own follow-ups count toward the original. Each
  ticket is counted once (a ticket reachable by two paths is not doubled) and
  the walk keeps a visited set, so a cycle terminates and the origin is never
  its own follow-up.

  `total_usd` is `own_usd + follow_ups_usd`; unpriced tickets contribute
  nothing to the dollar figures and are counted in `unpriced_runs`.
  """

  import Ecto.Query, only: [from: 2]

  alias Arbiter.Repo
  alias Arbiter.Tasks.Issue
  alias Arbiter.Usage.LiveSpend

  @edge_types ~w(fixes discovered_from)

  # Ids per `IN` read; keeps each query under SQLite's expression-depth limit.
  @id_chunk 500

  @type follow_up :: %{
          id: String.t(),
          title: String.t() | nil,
          usd: float() | nil,
          depth: pos_integer()
        }

  @type t :: %{
          own_usd: float(),
          follow_ups_usd: float(),
          total_usd: float(),
          follow_ups: [follow_up()]
        }

  @doc "The edge types spend rolls up over."
  @spec edge_types() :: [String.t()]
  def edge_types, do: @edge_types

  @doc """
  The rolled-up spend for `task_id`. `opts` are `LiveSpend.for_tasks/2`'s
  (`:workers`, `:settled`).
  """
  @spec for_task(String.t(), keyword()) :: t()
  def for_task(task_id, opts \\ []) when is_binary(task_id) do
    found = follow_up_ids(task_id)
    ids = [task_id | Enum.map(found, &elem(&1, 0))]

    spends = LiveSpend.for_tasks(ids, opts)
    titles = titles(Enum.map(found, &elem(&1, 0)))

    follow_ups =
      Enum.map(found, fn {id, depth} ->
        %{id: id, title: Map.get(titles, id), usd: usd(spends, id), depth: depth}
      end)

    own = usd(spends, task_id) || 0.0
    rolled = follow_ups |> Enum.reduce(0.0, &(&2 + (&1.usd || 0.0))) |> Float.round(4)

    %{
      own_usd: own,
      follow_ups_usd: rolled,
      total_usd: Float.round(own + rolled, 4),
      follow_ups: follow_ups
    }
  end

  @doc """
  `[{id, depth}]` of every follow-up of `task_id`, breadth-first, nearest
  first; never includes `task_id` itself.
  """
  @spec follow_up_ids(String.t()) :: [{String.t(), pos_integer()}]
  def follow_up_ids(task_id) when is_binary(task_id),
    do: walk([task_id], MapSet.new([task_id]), 1, [])

  defp walk([], _seen, _depth, acc), do: Enum.reverse(acc)

  defp walk(frontier, seen, depth, acc) do
    new =
      frontier
      |> followers()
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()

    walk(
      new,
      Enum.reduce(new, seen, &MapSet.put(&2, &1)),
      depth + 1,
      Enum.reverse(Enum.map(new, &{&1, depth}), acc)
    )
  end

  # Tickets with a `fixes` / `discovered_from` edge pointing at any of `ids`.
  defp followers(ids) do
    ids
    |> Enum.chunk_every(@id_chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from(d in "dependencies",
          where: d.to_issue_id in ^chunk and d.type in ^@edge_types,
          select: d.from_issue_id
        )
      )
    end)
  end

  defp titles([]), do: %{}

  defp titles(ids) do
    ids
    |> Enum.chunk_every(@id_chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(from(i in Issue, where: i.id in ^chunk, select: {i.id, i.title}))
    end)
    |> Map.new()
  end

  defp usd(spends, id) do
    case Map.get(spends, id) do
      %{total_usd: n} when is_number(n) -> n
      _ -> nil
    end
  end
end
