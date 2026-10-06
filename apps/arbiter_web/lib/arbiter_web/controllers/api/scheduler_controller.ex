defmodule ArbiterWeb.Api.SchedulerController do
  @moduledoc """
  REST endpoints for board scheduler (autopilot) operations.

  Routes:

    * `POST /api/scheduler/pause` — pause the autopilot
    * `POST /api/scheduler/resume` — resume the autopilot
    * `GET /api/scheduler/status` — get the drain state (`Arbiter.Board.Drain`)

  Every route answers with the same body — `Arbiter.Board.Drain.to_json/1`,
  shared with the `scheduler_status` MCP tool so the two cannot disagree.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Drain

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc """
  Pause the board autopilot.

  Returns the `status/2` body on success — `"paused": true`, `"changed_by":
  "coordinator via api"`, and the drain state (a pause usually lands in `draining`).
  """
  def pause(conn, params) do
    case Autopilot.pause(Autopilot, actor(conn, params)) do
      :ok ->
        json(conn, status_json())

      {:error, reason} ->
        {:error, {:server_error, "pause failed", %{reason: inspect(reason)}}}
    end
  rescue
    e ->
      {:error, {:server_error, "pause failed", %{reason: Exception.message(e)}}}
  catch
    :exit, reason ->
      {:error,
       {:busy, "the scheduler is not responding; retry shortly", %{reason: inspect(reason)}}}
  end

  @doc """
  Resume the board autopilot.

  Returns the `status/2` body on success — `"paused": false`, `"changed_by":
  "coordinator via api"`, and the drain state.
  """
  def resume(conn, params) do
    case Autopilot.resume(Autopilot, actor(conn, params)) do
      :ok ->
        json(conn, status_json())

      {:error, reason} ->
        {:error, {:server_error, "resume failed", %{reason: inspect(reason)}}}
    end
  rescue
    e ->
      {:error, {:server_error, "resume failed", %{reason: Exception.message(e)}}}
  catch
    :exit, reason ->
      {:error,
       {:busy, "the scheduler is not responding; retry shortly", %{reason: inspect(reason)}}}
  end

  @doc """
  Get the scheduler's drain state.

  Returns `{"state": "running"|"draining"|"quiescent", "safe_to_restart":
  bool, "in_flight": [...], "paused": bool, "changed_at": iso8601|null,
  "changed_by": string|null, "slots_used": int, "slot_holders": [...],
  "checked_at": iso8601}`. An idle resident worker is not in flight and is
  not listed.
  """
  def status(conn, _params) do
    json(conn, status_json())
  rescue
    e ->
      {:error, {:server_error, "status check failed", %{reason: Exception.message(e)}}}
  catch
    :exit, reason ->
      {:error,
       {:busy, "the scheduler is not responding; retry shortly", %{reason: inspect(reason)}}}
  end

  # bd-cl6zjn: `arb scheduler` says `"surface": "cli"`; any other caller is the
  # bare API. The actor is the token's scope (`coordinator`, ...).
  defp actor(conn, params) do
    surface = if params["surface"] == "cli", do: "cli", else: "api"
    {Arbiter.PaperTrail.actor_label(conn.assigns[:mcp_scope]) || "unknown", surface}
  end

  defp status_json, do: Drain.status() |> Drain.to_json()
end
