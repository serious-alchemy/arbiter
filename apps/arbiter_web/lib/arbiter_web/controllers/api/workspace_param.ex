defmodule ArbiterWeb.Api.WorkspaceParam do
  @moduledoc """
  The REST adapter for `Arbiter.Tasks.Workspaces.resolve/3` (parity audit P-04):
  every workspace-scoped route reads the caller's workspace through here, so
  REST answers "which workspace?" exactly as MCP does.

    * `workspace` (id **or name**) and its alias `workspace_id` are both
      accepted on every route (`workspace` wins when both are present);
    * an unknown reference is a 404, never an empty result;
    * a token bound to one workspace — a worker, or a coordinator minted for a
      workspace — is confined to it: naming another is a 403 (`unauthorized`),
      and naming nothing means its own workspace;
    * `:read` with nothing named is `{:ok, nil}` — ALL workspaces (echo
      `workspace_id` in the response); `:write` with nothing named is the sole
      workspace, else a 422 listing the candidates. A write never lands in the
      workspace that merely happens to be called `default`.
  """

  alias Arbiter.Tasks.Workspaces

  @doc "Resolve the workspace a request names (see the moduledoc)."
  @spec resolve(Plug.Conn.t(), map(), Workspaces.mode()) ::
          {:ok, String.t() | nil} | {:error, Workspaces.error()}
  def resolve(%Plug.Conn{} = conn, params, mode) when mode in [:read, :write] do
    Workspaces.resolve(conn.assigns[:mcp_scope], Workspaces.arg(params), mode: mode)
  end

  @doc """
  Resolve a workspace named in the route path (`/api/workspaces/:id`,
  `/api/workspaces/:workspace_id/…`) to its row — id **or name**, 404 when
  unknown, 403 when the token is bound to a different workspace.
  """
  @spec resolve_ref(Plug.Conn.t(), String.t()) ::
          {:ok, Arbiter.Tasks.Workspace.t()} | {:error, Workspaces.error()}
  def resolve_ref(%Plug.Conn{} = conn, ref) when is_binary(ref) do
    case Workspaces.resolve_workspace(conn.assigns[:mcp_scope], ref, mode: :write) do
      {:ok, %Arbiter.Tasks.Workspace{} = ws} -> {:ok, ws}
      {:error, _} = error -> error
    end
  end

  @doc """
  Echo the resolved scope into a response body: `workspace_id` is the id the
  read was scoped to, or `null` for "all workspaces". Only added when the
  controller resolved one (the render assigns carry a `:workspace_id` key), so
  a list that never resolved a scope is not mislabelled "all".
  """
  @spec echo(map(), map()) :: map()
  def echo(body, assigns) when is_map(body) and is_map(assigns) do
    if Map.has_key?(assigns, :workspace_id),
      do: Map.put(body, :workspace_id, assigns.workspace_id),
      else: body
  end
end
