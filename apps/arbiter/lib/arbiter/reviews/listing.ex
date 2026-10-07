defmodule Arbiter.Reviews.Listing do
  @moduledoc """
  The one read of `Arbiter.Reviews.Record` rows behind
  `external_review_list` (MCP) and `GET /api/external_reviews` (REST/CLI)
  (parity audit P-12, D-W-20): the same filters (`workspace`, `status`,
  `since`), the same ordering (newest first) and the same limit cap on both.
  """

  require Ash.Query

  alias Arbiter.Params
  alias Arbiter.Reviews.Record

  @default_limit 20
  @max_limit 200

  @doc "Rows returned when no `limit` is given."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc "The most rows one call returns, whatever `limit` asks for."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc "Coerce a raw `limit` argument (`nil`/`\"\"` → the default; clamped to the cap)."
  @spec parse_limit(term()) :: {:ok, pos_integer()} | {:error, {:invalid, String.t()}}
  def parse_limit(raw) do
    case Params.limit(raw, @default_limit, @max_limit) do
      {:ok, n} -> {:ok, n}
      {:error, _} -> {:error, {:invalid, "limit must be a positive integer (max #{@max_limit})"}}
    end
  end

  @doc "Coerce a raw `status` argument to a `Record` status atom (`nil`/`\"\"` → no filter)."
  @spec parse_status(term()) :: {:ok, atom() | nil} | {:error, {:invalid, String.t()}}
  def parse_status(raw) when raw in [nil, ""], do: {:ok, nil}

  def parse_status(raw) when is_binary(raw) do
    case Enum.find(Record.statuses(), &(Atom.to_string(&1) == raw)) do
      nil -> {:error, {:invalid, "status must be one of: #{statuses_label()}"}}
      status -> {:ok, status}
    end
  end

  def parse_status(_), do: {:error, {:invalid, "status must be one of: #{statuses_label()}"}}

  @doc "Coerce a raw `since` argument (ISO 8601; `nil`/`\"\"` → no filter)."
  @spec parse_since(term()) :: {:ok, DateTime.t() | nil} | {:error, {:invalid, String.t()}}
  def parse_since(raw) when raw in [nil, ""], do: {:ok, nil}

  def parse_since(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, {:invalid, "since must be ISO8601 (e.g. 2026-06-01T00:00:00Z)"}}
    end
  end

  def parse_since(_),
    do: {:error, {:invalid, "since must be ISO8601 (e.g. 2026-06-01T00:00:00Z)"}}

  @doc """
  Records newest-first. Options: `workspace_id` (nil = all workspaces), `status`,
  `since`, `limit` (already coerced by `parse_limit/1`).
  """
  @spec list(keyword()) :: [Record.t()]
  def list(opts) do
    Record
    |> filter_workspace(opts[:workspace_id])
    |> filter_status(opts[:status])
    |> filter_since(opts[:since])
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(opts[:limit] || @default_limit)
    |> Ash.read!()
  end

  @doc "One record by id."
  @spec fetch(String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def fetch(id) when is_binary(id) do
    case Ash.get(Record, id) do
      {:ok, %Record{} = record} -> {:ok, record}
      _ -> {:error, :not_found}
    end
  end

  defp statuses_label, do: Record.statuses() |> Enum.map_join(", ", &Atom.to_string/1)

  defp filter_workspace(query, nil), do: query
  defp filter_workspace(query, ws), do: Ash.Query.filter(query, workspace_id == ^ws)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = dt), do: Ash.Query.filter(query, started_at >= ^dt)
end
