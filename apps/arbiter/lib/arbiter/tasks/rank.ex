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

  @spec move(Arbiter.Tasks.Issue.t(), map()) ::
          {:ok, Arbiter.Tasks.Issue.t()} | {:error, term()}
  def move(issue, args) do
    Repo.transaction(fn ->
      case Ash.update(issue, args, action: :set_rank) do
        {:ok, ranked} -> ranked
        {:error, error} -> Repo.rollback(error)
      end
    end)
  rescue
    error -> {:error, error}
  end

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
