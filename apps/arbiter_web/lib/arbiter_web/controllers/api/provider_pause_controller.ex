defmodule ArbiterWeb.Api.ProviderPauseController do
  @moduledoc """
  REST endpoints for provider / account pause (bd-5ef587). Back `arb provider`.

    * `GET /api/providers/paused` — every active pause
    * `POST /api/providers/pause` — `{"ref", "reason"?, "stop_running"?}`
    * `POST /api/providers/resume` — `{"ref"}`

  Every route answers `{"paused": [...]}` (`Arbiter.Providers.Pause.to_json/0`);
  pause also carries `stopped` — the task ids `stop_running` stopped.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Params
  alias Arbiter.Providers.Pause

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, _params), do: json(conn, %{paused: Pause.to_json()})

  def pause(conn, %{"ref" => ref} = params) when is_binary(ref) and ref != "" do
    with {:ok, stop_running?} <-
           params |> Params.fetch_bool("stop_running", false) |> Params.to_rest(),
         {:ok, reason} <- params |> Params.fetch_string("reason") |> Params.to_rest(),
         {:ok, stopped} <-
           ref
           |> Pause.pause_and_stop(
             reason: reason,
             by: by(conn),
             stop_running: stop_running?
           )
           |> failure(ref) do
      json(conn, %{paused: Pause.to_json(), stopped: stopped})
    end
  end

  def pause(_conn, _params), do: {:error, {:invalid_request, "`ref` is required"}}

  def resume(conn, %{"ref" => ref}) when is_binary(ref) and ref != "" do
    with {:ok, _entry} <- ref |> Pause.resume(by: by(conn)) |> failure(ref) do
      json(conn, %{paused: Pause.to_json()})
    end
  end

  def resume(_conn, _params), do: {:error, {:invalid_request, "`ref` is required"}}

  defp by(conn),
    do: Pause.attribution(Params.actor_label(conn.assigns[:mcp_scope]), "api")

  defp failure({:error, reason}, ref) do
    case Pause.error_message(reason, ref) do
      {:not_found, _} -> {:error, :not_found}
      {:invalid, msg} -> {:error, {:invalid_request, msg}}
      {:internal, msg} -> {:error, {:server_error, msg, %{reason: inspect(reason)}}}
    end
  end

  defp failure(ok, _ref), do: ok
end
