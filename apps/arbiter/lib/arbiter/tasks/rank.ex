defmodule Arbiter.Tasks.Rank do
  @moduledoc """
  The one entry point for reordering a ticket inside its workspace's rank
  order (bd-djapyj) — the space `board/scheduler.ex` and `board/autopilot.ex`
  read (priority, then rank, then age). The CLI (`arb ticket rank`), the API
  (`PATCH /api/issues/:id/rank`) and the MCP `ticket_rank` tool all call
  `move/2` rather than running `Ash.update(issue, args, action: :set_rank)`
  themselves.

  `Changes.SetRank` sometimes renumbers every other ticket in the workspace
  (when the neighbours it needs to land between have no integer gap), and it
  does that with per-row SQL writes rather than through the changeset AshSqlite
  is tracking — `AshSqlite.DataLayer.can?(_, :transact)` is `false`, so the
  surrounding `Ash.update` call opens no transaction of its own. `move/2`
  supplies one explicitly: the renumber and the moved ticket's own write
  either all land or none do.
  """

  alias Arbiter.Repo
  alias Arbiter.Tasks.Issue

  require Ash.Query

  @doc """
  Move and/or pin a ticket. `args` is a move form (`position:`, `before_id:`,
  `after_id:`), optionally with `pinned: boolean`, or `%{pinned: boolean}`
  alone (P-15). A move leaves `rank_pinned` as it was unless `pinned` says
  otherwise: `pinned: true` pins with the move (a board drag), `pinned: false`
  moves and then unpins; `pinned` alone changes the pin without moving.
  """
  @spec move(Arbiter.Tasks.Issue.t(), map()) ::
          {:ok, Arbiter.Tasks.Issue.t()} | {:error, term()}
  def move(issue, args) do
    {pinned, form} = Map.pop(args, :pinned)

    Repo.transaction(fn ->
      case do_move(issue, form, pinned) do
        {:ok, ranked} -> ranked
        {:error, error} -> Repo.rollback(error)
      end
    end)
  rescue
    error -> {:error, error}
  end

  defp do_move(issue, form, pinned) when map_size(form) == 0 and is_boolean(pinned),
    do: Ash.update(issue, %{pinned: pinned}, action: :set_rank_pinned)

  defp do_move(issue, form, true),
    do: Ash.update(issue, Map.put(form, :pin, true), action: :set_rank)

  defp do_move(issue, form, false) do
    with {:ok, moved} <- Ash.update(issue, form, action: :set_rank) do
      Ash.update(moved, %{pinned: false}, action: :set_rank_pinned)
    end
  end

  defp do_move(issue, form, nil), do: Ash.update(issue, form, action: :set_rank)

  @doc """
  Where `issue` sits among the open tickets of its workspace and priority band —
  `%{priority_band_position: <zero-based>, priority_band_size: n}` — in the
  queue order (rank, then age). REST (`PATCH /api/issues/:id/rank`) and the MCP
  `ticket_rank` tool both report it, so a caller no longer has to list the band
  to learn where a ticket landed (P-13, D-T-33).
  """
  @spec band_fields(Issue.t()) :: %{
          priority_band_position: non_neg_integer(),
          priority_band_size: pos_integer()
        }
  def band_fields(%Issue{} = issue) do
    ordered =
      Issue
      |> Ash.Query.filter(
        workspace_id == ^issue.workspace_id and priority == ^issue.priority and state != :closed
      )
      |> Ash.read!()
      |> Enum.sort_by(&{&1.rank, DateTime.to_unix(&1.created_at, :microsecond)})

    %{
      priority_band_position: Enum.find_index(ordered, &(&1.id == issue.id)) || 0,
      priority_band_size: max(length(ordered), 1)
    }
  end
end
