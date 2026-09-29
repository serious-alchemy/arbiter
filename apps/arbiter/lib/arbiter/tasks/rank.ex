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
end
