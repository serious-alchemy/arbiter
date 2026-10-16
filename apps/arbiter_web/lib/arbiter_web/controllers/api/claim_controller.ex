defmodule ArbiterWeb.Api.ClaimController do
  @moduledoc """
  REST endpoints for the tracker-issue ↔ task bridge.

  Claim dispatches through the workspace's configured tracker adapter
  (`github`, `jira`, `shortcut`, …), so `ref` is whatever that tracker uses —
  a GitHub issue number (`"42"`), a Jira key (`"AX-1234"`), a Shortcut story
  id, etc. The adapter defines the assignment-as-claim signal; workspaces
  without a claim-capable tracker get a 400.

  Routes:

    * `POST /api/workspaces/:workspace_id/claim` — claim one issue by ref.
      Body: `{"ref": "42", "force": false, "difficulty": 3, "repo": "org/repo"}`.
      Bulk: pass `"epic": "<tracker epic id>"` or `"query": "<tracker search>"`
      instead of `ref` — a dry-run preview unless `"yes": true`; replies
      `{applied, data: [{ref, title, url, status, task_id?, reason?}]}`.
      `difficulty` and `repo` are optional and, when given, override whatever
      `Arbiter.Tasks.Claim.claim/3` would otherwise derive from the issue
      (difficulty from labels) or leave unset (repo). Returns the task JSON.
    * `GET  /api/workspaces/:workspace_id/sync/plan` — dry-run reconcile.
      Returns the list of planned actions without acting.
    * `POST /api/workspaces/:workspace_id/sync` — apply reconcile.
      Returns the per-action results.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Params
  alias Arbiter.Tasks.Claim

  action_fallback ArbiterWeb.Api.FallbackController

  def claim(conn, %{"workspace_id" => workspace_id} = params) do
    with {:ok, workspace} <- get_workspace(conn, workspace_id),
         {:ok, claim_opts} <- Claim.claim_opts(params) do
      case Claim.bulk_selector(params) do
        {:ok, selector} -> bulk_claim(conn, workspace, selector, claim_opts, params)
        :none -> single_claim(conn, workspace, claim_opts, params)
        {:error, _} = err -> err
      end
    end
  end

  defp bulk_claim(conn, workspace, selector, claim_opts, params) do
    opts =
      claim_opts
      |> Keyword.put(:force, truthy?(params["force"]))
      |> Keyword.put(:yes, truthy?(params["yes"]))

    with {:ok, result} <- workspace |> Claim.bulk(selector, opts) |> Claim.typed() do
      json(conn, Claim.serialize_bulk(result))
    end
  end

  defp single_claim(conn, workspace, claim_opts, params) do
    ref = params["ref"]

    with :ok <- require_string(ref, "ref"),
         {:ok, status, task, owner} <-
           workspace
           |> Claim.claim_with_owner(
             ref,
             Keyword.put(claim_opts, :force, truthy?(params["force"]))
           )
           |> Claim.typed() do
      conn
      |> put_status(status_code_for(status))
      |> json(Claim.serialize_claim(status, task, owner))
    end
  end

  def plan(conn, %{"workspace_id" => workspace_id}) do
    with {:ok, workspace} <- get_workspace(conn, workspace_id),
         {:ok, plan} <- Claim.plan(workspace) do
      json(conn, %{data: Enum.map(plan, &Claim.serialize_action/1)})
    end
  end

  def sync(conn, %{"workspace_id" => workspace_id} = params) do
    dry? = truthy?(params["dry"])

    with {:ok, workspace} <- get_workspace(conn, workspace_id),
         {:ok, plan} <- Claim.plan(workspace) do
      if dry? do
        json(conn, Claim.serialize_sync(plan, :dry))
      else
        {:ok, results} = Claim.apply_plan(workspace, plan)
        json(conn, Claim.serialize_sync(plan, results))
      end
    end
  end

  # ---- helpers ----------------------------------------------------------

  defp get_workspace(conn, id), do: ArbiterWeb.Api.WorkspaceParam.resolve_ref(conn, id)

  defp require_string(v, _name) when is_binary(v) and v != "", do: :ok

  defp require_string(_v, name),
    do: {:error, {:invalid_request, "#{name} is required"}}

  defp truthy?(v), do: Params.boolean(v) == {:ok, true}

  defp status_code_for(:created), do: :created
  defp status_code_for(:existing), do: :ok
end
