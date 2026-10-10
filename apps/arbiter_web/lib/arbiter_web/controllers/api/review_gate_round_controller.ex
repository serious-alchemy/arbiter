defmodule ArbiterWeb.Api.ReviewGateRoundController do
  @moduledoc """
  REST endpoint for structured ReviewGate round outcomes (bd-aqyjuc).

  Route:

    * `GET /api/review_gate_rounds?task_id=...` — list rounds for a task,
      oldest first, wrapped under the "data" key. One row per reviewer or
      implementer pass, so a round-1 rejection and a round-2 approval are
      two distinct rows rather than a single terminal outcome.
      Required query param: `task_id`. Optional: `limit` (the most recent N
      rounds, max 200).

      Beside `data` the body carries the rest of
      `Arbiter.ReviewGate.RoundsReport` — `count`, `total_count`, `outcome`,
      `resolution`, `resolutions` and `conflict_review` — so this is the same
      report `review_gate_rounds_list` returns over MCP (P-12, D-W-21).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Params
  alias Arbiter.ReviewGate.RoundsReport
  alias Arbiter.Workers.Runs
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, %{"task_id" => task_id} = params)
      when is_binary(task_id) and task_id != "" do
    with :ok <- authorize_task(conn, task_id),
         {:ok, limit} <-
           params["limit"]
           |> Params.limit(RoundsReport.max_limit(), RoundsReport.max_limit())
           |> Params.to_rest() do
      {rounds, report} = task_id |> RoundsReport.build(limit) |> Map.pop!(:rounds)
      json(conn, Map.put(report, :data, rounds))
    end
  end

  def index(_conn, _params) do
    {:error, {:invalid_request, "task_id is required"}}
  end

  # A token bound to one workspace (a worker holding `research_read`, bd-6ircwr)
  # reads only its own workspace's tickets; another's is a 404, never a 403, so
  # existence does not leak. An unbound coordinator reads everywhere.
  defp authorize_task(conn, task_id) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, %{}, :read) do
      if is_nil(ws_id) or Runs.task_workspace_id(task_id) == ws_id,
        do: :ok,
        else: {:error, :not_found}
    end
  end
end
