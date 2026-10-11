defmodule Arbiter.Tasks.BulkRead do
  @moduledoc """
  Batch reads for ticket lists (`GET /api/issues`, MCP `ticket_list`).

  A coordinator that wants "every open ticket with its parent epic and
  dependency edges" must not fetch each ticket separately (bd-7sxpln). Both
  functions here cost a constant number of queries however many tickets are
  passed:

    * `load/1` — epics get `child_total` / `child_closed` (one batch load,
      epic rows only).
    * `edges/1` — `%{ticket_id => %{parent_id, depends_on, blocks}}` from a
      single edge query: `parent_id` is the `from` end of the ticket's
      `:parent_of` edge (or nil), `depends_on` the ids gating it (its own
      `:depends_on` targets plus the sources of `:blocks` edges into it) and
      `blocks` the ids it gates.
  """

  require Ash.Query

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue

  @gating [:parent_of, :depends_on, :blocks]

  @doc "Load the child progress calculations onto the epics in `issues`, keeping order."
  @spec load([Issue.t()]) :: [Issue.t()]
  def load(issues) do
    epics = Enum.filter(issues, &(&1.issue_type == :epic))

    if epics == [] do
      issues
    else
      by_id =
        epics
        |> Ash.load!([:child_total, :child_closed])
        |> Map.new(&{&1.id, &1})

      Enum.map(issues, &Map.get(by_id, &1.id, &1))
    end
  end

  @doc "Parent and gating edges for every issue in `issues`, in one query."
  @spec edges([Issue.t()]) :: %{
          String.t() => %{
            parent_id: String.t() | nil,
            depends_on: [String.t()],
            blocks: [String.t()]
          }
        }
  def edges([]), do: %{}

  def edges(issues) do
    ids = Enum.map(issues, & &1.id)

    deps =
      Dependency
      |> Ash.Query.filter(type in ^@gating and (from_issue_id in ^ids or to_issue_id in ^ids))
      |> Ash.read!()

    base = Map.new(ids, &{&1, %{parent_id: nil, depends_on: [], blocks: []}})

    deps
    |> Enum.sort_by(&{&1.created_at, &1.id})
    |> Enum.reduce(base, fn %{type: type, from_issue_id: from, to_issue_id: to}, acc ->
      case type do
        :parent_of ->
          update(acc, to, &%{&1 | parent_id: from})

        :depends_on ->
          acc |> update(from, &add(&1, :depends_on, to)) |> update(to, &add(&1, :blocks, from))

        :blocks ->
          acc |> update(to, &add(&1, :depends_on, from)) |> update(from, &add(&1, :blocks, to))
      end
    end)
  end

  @includes %{"parent" => :parent, "deps" => :deps}

  @doc """
  Parse an `include` option — a comma-separated string or a list — into
  `[:parent | :deps]`. `{:error, message}` for an unknown name.
  """
  @spec parse_include(term()) :: {:ok, [:parent | :deps]} | {:error, String.t()}
  def parse_include(nil), do: {:ok, []}

  def parse_include(raw) when is_binary(raw),
    do: raw |> String.split(",", trim: true) |> parse_include()

  def parse_include(raw) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn name, {:ok, acc} ->
      case Map.fetch(@includes, name |> to_string() |> String.trim()) do
        {:ok, inc} -> {:cont, {:ok, Enum.uniq(acc ++ [inc])}}
        :error -> {:halt, {:error, "invalid include #{inspect(name)} (expected parent, deps)"}}
      end
    end)
  end

  def parse_include(_), do: {:error, "include must be a string or a list"}

  @doc """
  The extra fields one list row carries: the edge fields asked for in
  `include`, and `child_closed` / `child_total` on an epic loaded by `load/1`.
  """
  @spec row_extras(Issue.t(), [:parent | :deps], map()) :: map()
  def row_extras(%Issue{} = issue, include, edges) do
    entry = Map.get(edges, issue.id, %{parent_id: nil, depends_on: [], blocks: []})

    %{}
    |> put_progress(issue)
    |> then(&if(:parent in include, do: Map.put(&1, :parent_id, entry.parent_id), else: &1))
    |> then(
      &if(:deps in include,
        do: Map.merge(&1, %{depends_on: entry.depends_on, blocks: entry.blocks}),
        else: &1
      )
    )
  end

  defp put_progress(map, %Issue{child_total: t, child_closed: c})
       when is_integer(t) and is_integer(c),
       do: Map.merge(map, %{child_total: t, child_closed: c})

  defp put_progress(map, _issue), do: map

  @doc """
  Fetch `ids` in one query: `{issues, not_found}`, issues in the order asked.
  `keep?` decides whether a fetched issue is visible to the caller (workspace
  isolation); one it rejects is reported as not found, like an unknown id.
  """
  @spec fetch_many([String.t()], (Issue.t() -> boolean())) :: {[Issue.t()], [String.t()]}
  def fetch_many(ids, keep? \\ fn _ -> true end) do
    ids = Enum.uniq(ids)
    found = Issue |> Ash.Query.filter(id in ^ids) |> Ash.read!() |> Enum.filter(keep?)
    by_id = Map.new(found, &{&1.id, &1})

    {for(id <- ids, is_map_key(by_id, id), do: by_id[id]),
     Enum.reject(ids, &is_map_key(by_id, &1))}
  end

  defp update(acc, id, fun) do
    case acc do
      %{^id => entry} -> %{acc | id => fun.(entry)}
      _ -> acc
    end
  end

  defp add(entry, key, id), do: Map.update!(entry, key, &(&1 ++ [id]))
end
