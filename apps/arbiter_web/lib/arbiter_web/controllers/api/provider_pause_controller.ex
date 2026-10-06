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
         {:ok, _entry} <- pause_ref(ref, params) do
      stopped = if stop_running?, do: Pause.stop_running(ref), else: []
      json(conn, %{paused: Pause.to_json(), stopped: stopped})
    end
  end

  def pause(_conn, _params), do: {:error, {:invalid_request, "`ref` is required"}}

  defp pause_ref(ref, params) do
    case Pause.pause(ref, reason: params["reason"], by: "api") do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, failure(reason, ref)}
    end
  end

  def resume(conn, %{"ref" => ref}) when is_binary(ref) and ref != "" do
    case Pause.resume(ref, by: "api") do
      {:ok, _entry} -> json(conn, %{paused: Pause.to_json()})
      {:error, reason} -> {:error, failure(reason, ref)}
    end
  end

  def resume(_conn, _params), do: {:error, {:invalid_request, "`ref` is required"}}

  defp failure(:not_found, _ref), do: :not_found

  defp failure(:ambiguous, ref),
    do: {:invalid_request, "`#{ref}` matches several accounts — use provider:slug"}

  defp failure(:not_paused, ref), do: {:invalid_request, "`#{ref}` is not paused"}
  defp failure(other, _ref), do: {:invalid_request, "failed: #{inspect(other)}"}
end
