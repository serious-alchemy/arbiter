defmodule ArbiterWeb.Api.DependencyController do
  @moduledoc """
  REST endpoints for `Arbiter.Tasks.Dependency`.

  Routes:

    * `GET    /api/dependencies[?workspace=&type=&issue_id=]` — :index
    * `POST   /api/dependencies` — :create  (from_issue_id, to_issue_id, type)
    * `GET    /api/dependencies/:issue_id[?workspace=&type=]` — :show
    * `DELETE /api/dependencies/:from/:to[?type=...]` — :delete

  `create` and `delete` go through `Arbiter.Tasks.Dependencies` (bd-apj0gq).
  This used to be the *unvalidated* write path — a raw `Ash.create` with no
  workspace check — and it is the one `arb dep add`, `arb dep rm` and
  `arb create --deps/--parent` call, so operators got the weakest guarantees
  of any surface. It now enforces exactly what MCP does: both endpoints
  resolve, both live in one workspace, no gating cycle, and a `parent_of`
  write re-evaluates the parent's `auto_close`.

  Facade guard failures (`:invalid_type`, `:cross_workspace`, `:cyclic`) render
  as 400 `invalid_request` carrying the facade's message verbatim — the named
  cycle or the two workspace names are the whole point of the error. A missing
  endpoint is 404; resource-level rejections (self-reference, duplicate edge)
  stay 422, unchanged.

  `index` / `show` (bd-1defgu) go through `Arbiter.Tasks.Dependencies.list/1`.
  `workspace` (id or name; `workspace_id` is its alias) narrows either read to
  one workspace; naming neither lists every workspace (the body echoes the
  resolved `workspace_id`, `null` for all, and each edge carries its own).
  Passing a workspace with an `issue_id` requires the issue to actually live in
  that workspace — a mismatch renders 400 `invalid_request`, the read-side
  analogue of `create`'s cross-workspace rejection. A token bound to one
  workspace is confined to it (naming another is 403).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback ArbiterWeb.Api.FallbackController

  def index(conn, params) do
    with {:ok, opts} <- list_opts(conn, params) do
      render_list(conn, opts)
    end
  end

  def show(conn, %{"issue_id" => issue_id} = params) do
    with {:ok, opts} <- list_opts(conn, Map.put(params, "issue_id", issue_id)) do
      render_list(conn, opts)
    end
  end

  def create(conn, params) do
    with {:ok, from} <- require_param(params, "from_issue_id"),
         {:ok, to} <- require_param(params, "to_issue_id"),
         {:ok, type} <- require_param(params, "type"),
         {:ok, dep} <- Dependencies.add(from, to, type, edge_opts(conn, params)) do
      conn
      |> put_status(:created)
      |> render(:show, dependency: dep)
    else
      {:error, reason} -> {:error, translate(reason)}
    end
  end

  def delete(conn, %{"from" => from, "to" => to} = params) do
    case Dependencies.remove(from, to, params["type"]) do
      # A removal that matched nothing keeps its historical 404: the CLI and any
      # other HTTP client have always read it as "there was no such edge", and
      # the facade's `{:ok, 0}` is about the *domain* call being a no-op, not
      # about what a REST client should be told.
      {:ok, 0} ->
        {:error, :not_found}

      {:ok, _removed} ->
        conn
        |> put_status(:no_content)
        |> send_resp(:no_content, "")

      {:error, reason} ->
        {:error, translate(reason)}
    end
  end

  defp render_list(conn, opts) do
    case Dependencies.list(opts) do
      {:ok, edges} ->
        render(conn, :index, dependencies: edges, workspace_id: Keyword.get(opts, :workspace_id))

      {:error, reason} ->
        {:error, translate(reason)}
    end
  end

  defp list_opts(conn, params) do
    issue_id = blank_to_nil(params["issue_id"])

    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         :ok <- require_issue_exists(issue_id),
         :ok <- require_same_workspace(ws_id, issue_id) do
      opts =
        []
        |> put_opt(:workspace_id, ws_id)
        |> put_opt(:issue_id, issue_id)
        |> put_opt(:type, blank_to_nil(params["type"]))

      {:ok, opts}
    end
  end

  defp require_issue_exists(nil), do: :ok

  defp require_issue_exists(issue_id) do
    case Ash.get(Issue, issue_id) do
      {:ok, %Issue{}} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp require_same_workspace(nil, _issue_id), do: :ok
  defp require_same_workspace(_ws_id, nil), do: :ok

  defp require_same_workspace(ws_id, issue_id) do
    case Ash.get(Issue, issue_id) do
      {:ok, %Issue{workspace_id: ^ws_id}} ->
        :ok

      {:ok, %Issue{} = issue} ->
        {:error,
         {:invalid_request,
          "ticket #{issue_id} is in workspace #{issue.workspace_id}, not #{ws_id}"}}

      _ ->
        {:error, :not_found}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp require_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_param, "#{key} is required"}}
    end
  end

  defp edge_opts(conn, params) do
    []
    |> put_opt(:notes, params["notes"])
    |> put_opt(:created_by, Arbiter.Params.actor_label(conn.assigns[:mcp_scope]))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # The facade's guards all carry a message written for a human; hand it
  # straight to the fallback rather than flattening it to "validation failed".
  defp translate({:not_found, _message}), do: :not_found

  defp translate({reason, message}) when is_atom(reason) and is_binary(message),
    do: {:invalid_request, message}

  defp translate(other), do: other
end
