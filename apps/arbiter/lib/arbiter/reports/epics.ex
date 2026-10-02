defmodule Arbiter.Reports.Epics do
  @moduledoc """
  The epic filter of `/reports` (bd-836iuz): an epic's tickets are the targets
  of its `parent_of` edges (direct children only, design
  `docs/design/reports-design-v2.md` §5.7), read straight from `dependencies`.
  """

  import Ecto.Query

  alias Arbiter.Repo

  @doc "Subquery of the ticket ids that hang directly under `epic_id`."
  @spec children_query(String.t()) :: Ecto.Query.t()
  def children_query(epic_id) do
    from(d in "dependencies",
      where: d.type == "parent_of" and d.from_issue_id == ^epic_id,
      select: d.to_issue_id
    )
  end

  @doc """
  The ids under `epic_id`. An epic has a bounded number of children, so the
  list is safe to bind into an `id in ^ids` filter (no expression-tree blowup).
  """
  @spec child_ids(String.t()) :: [String.t()]
  def child_ids(epic_id), do: epic_id |> children_query() |> Repo.all()

  @doc "Every epic as `%{id, title}`, newest first, for the filter dropdown."
  @spec list() :: [%{id: String.t(), title: String.t()}]
  def list do
    from(i in "issues",
      where: i.issue_type == "epic",
      order_by: [desc: i.created_at],
      select: %{id: i.id, title: i.title}
    )
    |> Repo.all()
  end
end
