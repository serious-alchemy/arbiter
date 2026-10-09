defmodule ArbiterWeb.Api.RunController do
  @moduledoc """
  REST endpoints for `Arbiter.Workers.Run` — the durable history of worker
  runs (a worker's lifecycle after the GenServer is gone).

  Routes:

    * `GET /api/workers/history`      — :index (filters: task_id, workspace_id,
                                          kind, state, outcome, limit [default
                                          20, max 200], before [ISO8601
                                          started_at cursor])
    * `GET /api/workers/history/:id`  — :show (single run with full output)

  Newest first. Pass `task_id` to list every historical run for a single task
  (the per-task run history surfaced by `arb worker runs <task-id>`).

  The query, its filters and the limit cap are `Arbiter.Workers.Runs`, the same
  module MCP's `worker_runs` calls; the payload is `Arbiter.Workers.Serializer`.

  `kind`, `state` and `outcome` filter on the one run vocabulary
  (`Arbiter.Workers.RunState`, bd-1uu19b). The pre-5/13 `status` filter is
  still accepted and mapped onto it the way the migration mapped the column:
  `running` is `state=working`, `completed` is `outcome=succeeded`, `failed` /
  `review_parked` / `review_not_started` are `outcome=failed`, `interrupted`
  is `outcome=interrupted`.

  A token bound to one workspace only reads that workspace's runs: `index` is
  scoped to it and `show` of another workspace's run is a 404 (D-W-25).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Params
  alias Arbiter.Workers.Runs
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, limit} <- params["limit"] |> Runs.history_limit() |> Params.to_rest(),
         {:ok, filters} <- params |> Runs.parse_filters() |> Params.to_rest() do
      render(conn, :index, runs: Runs.history(filters, workspace_id: ws_id, limit: limit))
    end
  end

  def show(conn, %{"id" => id}) when is_binary(id) and id != "" do
    with {:ok, run} <- Runs.get(id) |> found(),
         {:ok, ws_id} <- WorkspaceParam.resolve(conn, %{}, :read),
         true <- is_nil(ws_id) or ws_id == run.workspace_id do
      render(conn, :show, run: run)
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  def show(_conn, _params), do: {:error, {:invalid_request, "id is required", %{}}}

  defp found({:ok, run}), do: {:ok, run}
  defp found(:error), do: {:error, :not_found}
end
