defmodule Arbiter.Usage.Events do
  @moduledoc """
  The raw usage-event list behind `GET /api/usage/events`, `arb usage events`
  and the MCP `usage_events_list` tool (newest first), as one context function
  rather than a query built inline in the controller.
  """

  require Ash.Query

  alias Arbiter.Usage.Event
  alias Arbiter.Usage.Params

  @doc """
  Events newest first. Options, each ignored when `nil`/blank:
  `:workspace_id`, `:provider_account_id`, `:task_id` (also matches a
  synthetic child `<id>#…`), `:session_id`, `:step`, `:source`, `:since`
  (a `DateTime`), and `:limit` (default `Arbiter.Usage.Params.default_event_limit/0`).
  """
  @spec list(keyword()) :: [Event.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit) || Params.default_event_limit()

    Event
    |> filter(:workspace_id, opts[:workspace_id])
    |> filter(:provider_account_id, opts[:provider_account_id])
    |> filter(:task_id, opts[:task_id])
    |> filter(:session_id, opts[:session_id])
    |> filter(:step, opts[:step])
    |> filter(:source, opts[:source])
    |> filter_since(opts[:since])
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
  end

  defp filter(query, _field, value) when value in [nil, ""], do: query
  defp filter(query, :workspace_id, v), do: Ash.Query.filter(query, workspace_id == ^v)

  defp filter(query, :provider_account_id, v),
    do: Ash.Query.filter(query, provider_account_id == ^v)

  defp filter(query, :task_id, v) do
    prefix = v <> "#%"
    Ash.Query.filter(query, task_id == ^v or like(task_id, ^prefix))
  end

  defp filter(query, :session_id, v), do: Ash.Query.filter(query, session_id == ^v)
  defp filter(query, :step, v), do: Ash.Query.filter(query, step == ^v)
  defp filter(query, :source, v), do: Ash.Query.filter(query, source == ^v)

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = dt), do: Ash.Query.filter(query, occurred_at >= ^dt)
end
