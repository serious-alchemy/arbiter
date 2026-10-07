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

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, %{"task_id" => task_id} = params)
      when is_binary(task_id) and task_id != "" do
    with {:ok, limit} <-
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
end
