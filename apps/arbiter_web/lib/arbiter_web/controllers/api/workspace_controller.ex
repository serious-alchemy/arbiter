defmodule ArbiterWeb.Api.WorkspaceController do
  @moduledoc """
  REST endpoints for `Arbiter.Tasks.Workspace`.

  Routes:

    * `POST  /api/workspaces`            — :create
    * `GET   /api/workspaces`            — :index
    * `GET   /api/workspaces/:id`        — :show (`:id` is an id or a name)
    * `PATCH /api/workspaces/:id`        — :update (also `PUT`)
    * `PATCH /api/workspaces/:id/config` — :patch_config (deep-merge / unset)
  """

  use ArbiterWeb, :controller

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback ArbiterWeb.Api.FallbackController

  def index(conn, _params) do
    case Ash.read(Workspace) do
      {:ok, workspaces} -> render_list(conn, workspaces)
      {:error, _} = err -> err
    end
  end

  # bd-asawcq: a worker or refine token is bound to one workspace and sees
  # only that one (`arb message` resolves `ARB_WORKSPACE` through this list).
  # D-C-22: and only its summary (id / name / prefix / tracker type), the same
  # disclosure level MCP `workspace_list` gives — the full record (config,
  # security posture) is `GET /api/workspaces/:id`, a coordinator read.
  defp render_list(conn, workspaces) do
    case conn.assigns[:mcp_scope] do
      %Arbiter.MCP.Scope{tier: tier, workspace_id: ws_id} when tier in [:worker, :refine] ->
        render(conn, :summaries, workspaces: Enum.filter(workspaces, &(&1.id == ws_id)))

      _ ->
        render(conn, :index, workspaces: workspaces)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, ws} <- WorkspaceParam.resolve_ref(conn, id) do
      render(conn, :show, workspace: ws)
    end
  end

  def create(conn, params) do
    # `secrets` is a write-only action argument (merge-patched then encrypted
    # via ash_cloak); it is never read back in any response. See WorkspaceJSON.
    attrs = Map.take(params, ["name", "description", "prefix", "config", "secrets"])

    case Ash.create(Workspace, attrs, context: guardrail_context(conn)) do
      {:ok, ws} ->
        conn
        |> put_status(:created)
        |> render(:show, workspace: ws)

      {:error, _} = err ->
        err
    end
  end

  def update(conn, %{"id" => id} = params) do
    # `secrets`, when present, is merge-patched into the existing encrypted
    # secrets (a key with a null value removes it); omitting it leaves them
    # untouched. Write-only — never serialised back. See WorkspaceJSON.
    attrs = Map.take(params, ["name", "description", "prefix", "config", "secrets"])

    with {:ok, ws} <- WorkspaceParam.resolve_ref(conn, id),
         {:ok, updated} <- Ash.update(ws, attrs, context: guardrail_context(conn)) do
      render(conn, :show, workspace: updated)
    end
  end

  @doc """
  Field-level config update. Body shape:

      {
        "patch": {"merge": {"auto_merge": true}},
        "unset_paths": ["tracker.config.host"]
      }

  Both keys are optional. The existing `config` is read, `unset_paths` are
  removed, then `patch` is deep-merged in (siblings preserved). The result
  is validated; on failure the existing config is untouched.
  """
  def patch_config(conn, %{"id" => id} = params) do
    patch = Map.get(params, "patch") || %{}
    unset_paths = Map.get(params, "unset_paths") || []

    args = %{patch: patch, unset_paths: unset_paths}

    with {:ok, ws} <- WorkspaceParam.resolve_ref(conn, id),
         {:ok, updated} <-
           Ash.update(ws, args, action: :patch_config, context: guardrail_context(conn)) do
      render(conn, :show, workspace: updated)
    end
  end

  # G11: loosening `guardrails.*` / `agent.security` is operator-only
  # (`Arbiter.Guardrails.Authority`). The caller's token decides who they are:
  # operator proof, a plain coordinator, or neither.
  defp guardrail_context(conn),
    do: %{guardrail_authority: Authority.from_scope(conn.assigns[:mcp_scope])}
end
