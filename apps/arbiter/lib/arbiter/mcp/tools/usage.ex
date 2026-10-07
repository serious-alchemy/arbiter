defmodule Arbiter.MCP.Tools.Usage do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the usage-ledger reads that were REST/CLI
  only (P-17): `usage_events_list` and `usage_calibration`.

  Read-only and coordinator-only, scoped by the same `workspace` rule as
  `usage_summarize` (omitted → all workspaces, echoed as `workspace_id`; a
  bound token may only name its own). They call the context functions the REST
  controller does (`Arbiter.Usage.list_events/1`, `Arbiter.Usage.calibration/1`)
  and render through `Arbiter.Usage.Serializer`.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Usage
  alias Arbiter.Usage.Params
  alias Arbiter.Usage.Serializer

  @doc """
  Raw ledger rows, newest first. Optional `workspace`, `account`, `task_id`,
  `session_id`, `step`, `source`, `since` (ISO-8601) and `limit` (default 50,
  max 1000). Coordinator only.
  """
  @spec usage_events_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def usage_events_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args),
         {:ok, since} <- Tools.optional_datetime(args, "since"),
         {:ok, step} <- Params.step(Map.get(args, "step")),
         {:ok, source} <- Params.source(Map.get(args, "source")),
         {:ok, limit} <- Params.event_limit(Map.get(args, "limit")),
         {:ok, account_id} <- Params.account_id(Tools.fetch_string(args, "account")) do
      events =
        Usage.list_events(
          workspace_id: ws_id,
          provider_account_id: account_id,
          task_id: Tools.fetch_string(args, "task_id"),
          session_id: Tools.fetch_string(args, "session_id"),
          step: step,
          source: source,
          since: since,
          limit: limit
        )

      {:ok,
       %{
         events: Enum.map(events, &Serializer.event/1),
         count: length(events),
         workspace_id: ws_id
       }}
    end
  end

  @doc """
  The difficulty mis-rating report (`GET /api/usage/calibration`): closed tasks
  whose actual cost lands outside their own tier's p25–p75 but inside an
  adjacent tier's. Optional `workspace`, `window_days`. Coordinator only.
  """
  @spec usage_calibration(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def usage_calibration(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args),
         {:ok, window_days} <- Params.window_days(Map.get(args, "window_days")) do
      opts =
        []
        |> then(&if(ws_id, do: Keyword.put(&1, :workspace_id, ws_id), else: &1))
        |> then(&if(window_days, do: Keyword.put(&1, :window_days, window_days), else: &1))

      {:ok, opts |> Usage.calibration() |> Serializer.calibration(ws_id)}
    end
  end
end
