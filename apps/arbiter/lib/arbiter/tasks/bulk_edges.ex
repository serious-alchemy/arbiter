defmodule Arbiter.Tasks.BulkEdges do
  @moduledoc """
  Bulk `dep_add`: apply a list of dependency edges in one call, with a per-edge
  result. The shared core behind `POST /api/dependencies` (list body),
  `dep_add` with `edges: [...]` and `arb dep add --stdin`.

  An edge is `%{from:, to:, type:}` (optionally `notes:`); `from_issue_id` /
  `to_issue_id` are accepted as aliases for `from` / `to`.

  ## Rejected edges do **not** roll the batch back

  Standalone bulk add is *per-edge*: edges are applied in order, each through
  `Arbiter.Tasks.Dependencies.add/4` (so every single-edge guard — both
  endpoints exist, one workspace, no gating cycle, the resource's own rules —
  applies unchanged), and each gets its own outcome:

      %{index: 0, from: "a", to: "b", type: "blocks", status: "ok"}
      %{index: 1, from: "b", to: "a", type: "blocks", status: "rejected",
        code: "cyclic", reason: "blocks b → a would create a dependency cycle: …"}

  An edge sees the ones before it (a later edge that closes a cycle *with an
  earlier edge of the same batch* is rejected). The response is

      %{results: [outcome, …], counts: %{total: n, ok: n, rejected: n}}

  Contrast `Arbiter.Tasks.BatchCreate`, where the tickets and edges are one
  atomic write: there a bad edge means the batch never happened. Here the
  caller is wiring edges between tickets that already exist, so a partial result
  is cheap to read and to retry; the rejected edges are listed with their reason.

  Batches are capped at `max_batch/0` edges.
  """

  alias Arbiter.Tasks.Dependencies

  @max_batch 200

  @type edge :: %{
          required(:from) => String.t(),
          required(:to) => String.t(),
          required(:type) => String.t(),
          optional(:notes) => String.t()
        }

  @doc "Largest number of edges one bulk call accepts."
  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @doc """
  Read the edge list from request params / tool args: `"edges"`, or — for a REST
  body that is a bare JSON array, which Plug hands over as `"_json"` — that.
  `{:error, message}` for a missing, empty, malformed or over-cap list; a
  malformed entry is named by index.
  """
  @spec fetch_edges(map()) :: {:ok, [edge()]} | {:error, String.t()}
  def fetch_edges(params) when is_map(params) do
    case Map.get(params, "edges") || Map.get(params, "_json") do
      edges when is_list(edges) and edges != [] -> check(edges)
      _ -> {:error, "`edges` must be a non-empty array of {from, to, type} objects"}
    end
  end

  @doc "Whether `params` is a bulk request (carries an `edges` list or a bare array body)."
  @spec bulk?(map()) :: boolean()
  def bulk?(params) when is_map(params),
    do: is_list(Map.get(params, "edges")) or is_list(Map.get(params, "_json"))

  defp check(edges) when length(edges) > @max_batch,
    do: {:error, "too many edges: a bulk call takes at most #{@max_batch}, got #{length(edges)}"}

  defp check(edges) do
    edges
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw, i}, {:ok, acc} ->
      case normalize(raw) do
        {:ok, edge} -> {:cont, {:ok, [edge | acc]}}
        {:error, why} -> {:halt, {:error, "edges[#{i}]: #{why}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp normalize(%{} = raw) do
    from = raw["from"] || raw["from_issue_id"]
    to = raw["to"] || raw["to_issue_id"]
    type = raw["type"]

    cond do
      not present?(from) -> {:error, "`from` is required"}
      not present?(to) -> {:error, "`to` is required"}
      not present?(type) -> {:error, "`type` is required"}
      true -> {:ok, put_notes(%{from: from, to: to, type: type}, raw["notes"])}
    end
  end

  defp normalize(_), do: {:error, "must be an object with `from`, `to` and `type`"}

  defp put_notes(edge, notes) when is_binary(notes), do: Map.put(edge, :notes, notes)
  defp put_notes(edge, _), do: edge

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  @doc """
  Apply `edges` in order and build the response.

  Options:

    * `:created_by` — actor label stamped on each edge.
    * `:authorize` — `(edge -> :ok | {:error, message})`, run before each edge
      (a worker-tier caller's per-edge restriction); a refusal is that edge's
      `rejected` outcome and the edge is not written.
  """
  @spec run([edge()], keyword()) :: %{results: [map()], counts: map()}
  def run(edges, opts \\ []) when is_list(edges) do
    authorize = Keyword.get(opts, :authorize, fn _ -> :ok end)

    results =
      edges
      |> Enum.with_index()
      |> Enum.map(fn {edge, i} -> outcome(i, edge, apply_edge(edge, authorize, opts)) end)

    %{results: results, counts: counts(results)}
  end

  defp apply_edge(edge, authorize, opts) do
    case authorize.(edge) do
      :ok ->
        add_opts =
          [created_by: Keyword.get(opts, :created_by), notes: Map.get(edge, :notes)]
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        Dependencies.add(edge.from, edge.to, edge.type, add_opts)

      {:error, why} ->
        {:error, {:unauthorized, why}}
    end
  end

  defp outcome(i, edge, {:ok, _dep}) do
    %{index: i, from: edge.from, to: edge.to, type: edge.type, status: "ok"}
  end

  defp outcome(i, edge, {:error, reason}) do
    %{
      index: i,
      from: edge.from,
      to: edge.to,
      type: edge.type,
      status: "rejected",
      code: code(reason),
      reason: reason_text(reason)
    }
  end

  defp code({kind, _msg}) when is_atom(kind), do: Atom.to_string(kind)
  defp code(%{__exception__: true}), do: "invalid"
  defp code(_), do: "invalid"

  defp reason_text({_kind, msg}) when is_binary(msg), do: msg
  defp reason_text(%{__exception__: true} = e), do: Exception.message(e)
  defp reason_text(other), do: inspect(other)

  defp counts(results) do
    freq = Enum.frequencies_by(results, & &1.status)

    %{
      total: length(results),
      ok: Map.get(freq, "ok", 0),
      rejected: Map.get(freq, "rejected", 0)
    }
  end
end
