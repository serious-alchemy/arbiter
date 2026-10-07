defmodule ArbiterWeb.Api.ReleaseDeployController do
  @moduledoc """
  Operator-triggered self-update over REST (bd-6umf7z). **Operator only**
  (`:operator` in `ArbiterWeb.ApiPolicy`): a coordinator session, a worker and
  anonymous callers are refused before this runs.

    * `POST /api/release/deploy` — launch `arb server deploy --version <tag>
      --json` in its own `arbiter-deploy-<tag>` systemd user unit
      (`Arbiter.Release.SelfDeploy`), outside this BEAM, because the deploy
      restarts it. Body `{"version": "vX.Y.Z"}`, or empty for the latest
      release when `update_available`. `202` with the unit; `409` when a deploy
      is already running, nothing is newer, or systemd cannot be reached; `422`
      for a version that is not a release tag.
    * `GET /api/release/deploy` — `{running, status}`: the deploy's own record
      (`<data-home>/deploy-status.json`), which survives the restart.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Release.{DeployStatus, SelfDeploy, UpdateCheck}

  action_fallback ArbiterWeb.Api.FallbackController

  def create(conn, params) do
    with {:ok, tag} <- SelfDeploy.resolve_tag(params["version"], UpdateCheck.state()),
         {:ok, %{unit: unit}} <- SelfDeploy.start(tag) do
      conn
      |> put_status(:accepted)
      |> json(%{tag: tag, unit: unit, status_path: DeployStatus.path()})
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def show(conn, _params) do
    status = DeployStatus.read()
    json(conn, %{running: SelfDeploy.running?(), status: status})
  end

  @doc false
  # Shared with the dashboard's button (`ArbiterWeb.DashboardUpdateController`):
  # one wording for each refusal.
  @spec error(term()) :: {atom(), String.t()}
  def error(:invalid_tag),
    do: {:invalid, "version must be a release tag like v1.2.3"}

  def error(:no_update),
    do: {:conflict, "no update available; pass \"version\" to deploy a specific release"}

  def error(:already_running),
    do: {:conflict, "a deploy is already running; wait for it to finish"}

  def error(:systemd_unavailable),
    do: {:conflict, "cannot reach the systemd user manager to launch the deploy"}

  def error({:cli_missing, path}),
    do: {:conflict, "the arb CLI is not installed at #{path}; install it first"}

  def error({:launch_failed, message}),
    do: {:conflict, "could not launch the deploy: #{message}"}
end
