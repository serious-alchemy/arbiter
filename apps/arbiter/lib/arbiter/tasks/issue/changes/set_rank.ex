defmodule Arbiter.Tasks.Issue.Changes.SetRank do
  @moduledoc """
  bd-djapyj: the `:set_rank` action's implementation. Moves a ticket to the
  top or bottom of its workspace's rank order, or immediately before/after
  another ticket in the same workspace — the rank space `board/scheduler.ex`
  and `board/autopilot.ex` read (priority, then rank, then age). Never
  touches `priority`: moving before/after a ticket in a different priority
  band only changes rank, so the mover leaves its own band.

  `top`/`bottom` always have room (nothing bounds rank above or below), so
  they never need to renumber. `before`/`after` need an integer strictly
  between two existing neighbours; when the neighbours are only 1 (or 0)
  apart, there is no such integer, so the whole workspace is renumbered,
  spaced `AssignRank.step/0` apart exactly like the bd-842qio backfill and
  every new ticket's `AssignRank` — relative order is preserved for every
  other ticket in the workspace.

  AshSqlite reports `can?(_, :transact)` as `false`, so this action's own
  `Ash.update` call opens no transaction — the per-row renumber writes below
  are plain SQL outside of Ash's tracking. Every caller MUST run this action
  through `Arbiter.Tasks.Rank.move/2`, which wraps the call in an explicit
  `Arbiter.Repo.transaction/1` so a renumber and the moved ticket's own
  write either both land or neither does.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.AssignRank
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &move/1)
  end

  defp move(changeset) do
    with {:ok, spec} <- move_spec(changeset),
         :ok <- reject_self(spec, changeset.data.id),
         {:ok, target} <- resolve_target(spec, changeset.data.workspace_id) do
      apply_move(changeset, spec, target)
    else
      {:error, message} -> Changeset.add_error(changeset, field: :rank, message: message)
    end
  end

  defp reject_self({kind, id}, issue_id) when kind in [:before, :after] and id == issue_id,
    do: {:error, "cannot rank a ticket relative to itself"}

  defp reject_self(_spec, _issue_id), do: :ok

  # ---- argument parsing -----------------------------------------------------

  defp move_spec(changeset) do
    position = Changeset.get_argument(changeset, :position)
    before_id = present(Changeset.get_argument(changeset, :before_id))
    after_id = present(Changeset.get_argument(changeset, :after_id))

    case {position, before_id, after_id} do
      {:top, nil, nil} -> {:ok, {:top, nil}}
      {:bottom, nil, nil} -> {:ok, {:bottom, nil}}
      {nil, id, nil} when is_binary(id) -> {:ok, {:before, id}}
      {nil, nil, id} when is_binary(id) -> {:ok, {:after, id}}
      {nil, nil, nil} -> {:error, "give exactly one of: top, bottom, before_id, after_id"}
      _ -> {:error, "give exactly one of: top, bottom, before_id, after_id"}
    end
  end

  defp present(nil), do: nil
  defp present(str) when is_binary(str), do: if(String.trim(str) == "", do: nil, else: str)

  # ---- target resolution -----------------------------------------------------

  defp resolve_target({kind, nil}, _workspace_id) when kind in [:top, :bottom], do: {:ok, nil}

  defp resolve_target({kind, id}, workspace_id) when kind in [:before, :after] do
    case Ash.get(Issue, id) do
      {:ok, %Issue{workspace_id: ^workspace_id} = target} ->
        {:ok, target}

      {:ok, %Issue{}} ->
        {:error, "cannot rank before/after a ticket in a different workspace"}

      {:error, _} ->
        {:error, "target ticket #{id} not found"}
    end
  end

  # ---- rank computation -------------------------------------------------------

  defp apply_move(changeset, spec, target) do
    workspace_id = changeset.data.workspace_id
    issue_id = changeset.data.id
    siblings = siblings(workspace_id, issue_id)

    case new_rank(spec, target, siblings) do
      {:ok, rank} ->
        Changeset.force_change_attribute(changeset, :rank, rank)

      :renumber ->
        rank = renumber!(siblings, issue_id, spec, target)
        Changeset.force_change_attribute(changeset, :rank, rank)
    end
  end

  defp siblings(workspace_id, issue_id) do
    Issue
    |> Ash.Query.filter(workspace_id == ^workspace_id and id != ^issue_id)
    |> Ash.Query.select([:id, :rank])
    |> Ash.Query.sort(rank: :asc, created_at: :asc, id: :asc)
    |> Ash.read!()
  end

  defp new_rank({:top, nil}, nil, []), do: {:ok, AssignRank.step()}
  defp new_rank({:top, nil}, nil, [%{rank: rank} | _]), do: {:ok, rank - AssignRank.step()}

  defp new_rank({:bottom, nil}, nil, []), do: {:ok, AssignRank.step()}

  defp new_rank({:bottom, nil}, nil, siblings) do
    %{rank: rank} = List.last(siblings)
    {:ok, rank + AssignRank.step()}
  end

  defp new_rank({:before, _id}, target, siblings) do
    case previous_sibling(siblings, target) do
      nil -> {:ok, target.rank - AssignRank.step()}
      prev -> gap(prev.rank, target.rank)
    end
  end

  defp new_rank({:after, _id}, target, siblings) do
    case next_sibling(siblings, target) do
      nil -> {:ok, target.rank + AssignRank.step()}
      next -> gap(target.rank, next.rank)
    end
  end

  defp gap(low, high) when high - low >= 2, do: {:ok, low + div(high - low, 2)}
  defp gap(_low, _high), do: :renumber

  defp previous_sibling(siblings, target) do
    siblings
    |> Enum.take_while(&(&1.id != target.id))
    |> List.last()
  end

  defp next_sibling(siblings, target) do
    case Enum.drop_while(siblings, &(&1.id != target.id)) do
      [_target | rest] -> List.first(rest)
      [] -> nil
    end
  end

  # ---- renumbering -------------------------------------------------------------

  # Rebuilds the workspace's whole rank order — every other ticket keeps its
  # relative order, and the moved ticket is spliced into its requested slot —
  # then persists every row with fresh, evenly-spaced ranks in one query per
  # row inside the surrounding action transaction. Returns the moved ticket's
  # own new rank.
  defp renumber!(siblings, issue_id, spec, target) do
    ordered_ids = splice(siblings, issue_id, spec, target)
    step = AssignRank.step()

    ordered_ids
    |> Enum.with_index(1)
    |> Enum.reduce(nil, fn {id, position}, moved_rank ->
      rank = position * step
      Arbiter.Repo.query!("UPDATE issues SET rank = ?1 WHERE id = ?2", [rank, id])
      if id == issue_id, do: rank, else: moved_rank
    end)
  end

  defp splice(siblings, issue_id, {:top, nil}, nil) do
    [issue_id | Enum.map(siblings, & &1.id)]
  end

  defp splice(siblings, issue_id, {:bottom, nil}, nil) do
    Enum.map(siblings, & &1.id) ++ [issue_id]
  end

  defp splice(siblings, issue_id, {:before, _}, target) do
    insert_relative(siblings, issue_id, target.id, :before)
  end

  defp splice(siblings, issue_id, {:after, _}, target) do
    insert_relative(siblings, issue_id, target.id, :after)
  end

  defp insert_relative(siblings, issue_id, target_id, where) do
    Enum.flat_map(siblings, fn sibling ->
      cond do
        sibling.id == target_id and where == :before -> [issue_id, sibling.id]
        sibling.id == target_id and where == :after -> [sibling.id, issue_id]
        true -> [sibling.id]
      end
    end)
  end
end
