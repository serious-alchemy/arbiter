defmodule ArbiterWeb.ApiPolicy do
  @moduledoc """
  Who may call which `/api` route (bd-asawcq) — one explicit table, with no
  implicit default.

  Loopback is not an identity. Every worker runs on the server's host as the
  operator's own Unix user, so an anonymous loopback caller could be any of
  them. Before this, `ArbiterWeb.Plugs.ApiAuth` let any such caller through
  without a token, and every write in `/api` (dispatch, workspace config,
  ticket close, Loop apply, …) was coordinator-equivalent for a plain `curl`.
  Now every route needs a bearer token unless this table says `:anonymous`,
  and the token's tier and scope are checked against the route the same way
  `Arbiter.MCP` checks a tool call.

  `ArbiterWeb.ApiPolicyTest` iterates the router: a route missing from this
  table fails it, and so does an anonymous loopback request to any write.

  ## Policies

    * `:anonymous` — reachable with no token. Read-only, no secrets, no
      workspace data. Reserved for what `arb server doctor` and monitoring
      need before any token exists.
    * `:coordinator` — a `:coordinator`-tier token (the operator's minted
      token, an `ARB_TOKEN`, a coordinator session's own token).
    * `:dispatch` — `:coordinator` plus `can_dispatch` (the recursion
      guardrail; mirrors `Arbiter.MCP.Tools.ensure_can_dispatch/1` on the
      `worker_dispatch` / `worker_resume` / `worker_review` tools).
    * `:any_token` — any valid token; the controller decides by tier itself
      (`POST /api/mcp/tokens` refuses worker and refine callers).
    * `:issue_read` — coordinator; or a worker/refine token whose bound
      workspace owns the issue in the path. What a worker's
      `arb ticket show <sibling>` needs, and no more.
    * `:workspace_list` — any token; `WorkspaceController.index/2` lists only
      a worker/refine token's own workspace (`arb message` resolves
      `ARB_WORKSPACE` through it).
    * `:issue_progress` — coordinator; or a worker token updating **its own
      task**, with only the progress fields (`notes`, `qa_notes`,
      `deployment_notes`, `pr_body`, `verify_after_deploy`) — the REST twin
      of the `ticket_update_progress` MCP tool.
    * `:issue_create` — coordinator; or a worker filing a follow-up as a
      child of **its own task** (`parent_id`), in its own workspace, with only
      descriptive fields. `arb create <title> --parent <own id>` is how a
      worker defers review-thread work and cites the filed key (bd-7ezcqb).
      A new ticket starts in Backlog, so nothing a worker files dispatches.
    * `:dependency_add` — coordinator; or a worker adding the `parent_of`
      edge from its own task to a ticket in its workspace that has no parent
      yet — the second half of `arb create --parent`.
    * `:mailbox` — coordinator; or a worker reading its own mailbox
      (`to_ref` must be its own task).
    * `:message_send` — coordinator; or a worker. `MessageController.create/2`
      pins a worker's `from_ref` and `workspace_id` to its own task, like the
      `message_send` MCP tool.
    * `:message_mark_read` — coordinator; or a worker marking a message
      addressed to its own task.

  A `:refine` token gets `:issue_read` and `:workspace_list` and nothing else over REST: its writes
  are subtree-gated and only exist as MCP tools (`Arbiter.MCP.RefinePolicy`).
  """

  alias Arbiter.MCP.Scope

  @type policy ::
          :anonymous
          | :coordinator
          | :dispatch
          | :any_token
          | :issue_read
          | :workspace_list
          | :issue_progress
          | :issue_create
          | :dependency_add
          | :mailbox
          | :message_send
          | :message_mark_read

  # The REST twin of `ticket_update_progress` (`Arbiter.MCP.Tools.Task`'s
  # `@progress_fields ++ @progress_flags`). "id" is the path param.
  @progress_params ~w(id notes qa_notes deployment_notes pr_body verify_after_deploy)

  # What a worker may set on a follow-up it files (`arb create`'s descriptive
  # flags). No `repo` / `target_branch` / `tracker_ref` / `auto_close` /
  # `verify_after_deploy`: where and how work ships stays coordinator authority.
  @worker_create_params ~w(title description acceptance workspace_id parent_id issue_type
                           priority difficulty skip_upstream_create force)

  @policies %{
    # ---- issues -----------------------------------------------------------
    {:get, "/api/issues/ready"} => :coordinator,
    {:get, "/api/issues/lifecycle"} => :coordinator,
    {:get, "/api/issues"} => :coordinator,
    {:post, "/api/issues"} => :issue_create,
    {:get, "/api/issues/:id"} => :issue_read,
    {:patch, "/api/issues/:id"} => :issue_progress,
    {:put, "/api/issues/:id"} => :issue_progress,
    {:post, "/api/issues/:id/close"} => :coordinator,
    {:post, "/api/issues/:id/reopen"} => :coordinator,
    {:post, "/api/issues/:id/promote"} => :coordinator,
    {:post, "/api/issues/:id/demote"} => :coordinator,
    {:patch, "/api/issues/:id/rank"} => :coordinator,
    {:patch, "/api/issues/:id/floor"} => :coordinator,
    {:post, "/api/issues/:id/verify"} => :coordinator,
    {:post, "/api/issues/:id/resolve"} => :coordinator,
    {:post, "/api/issues/:id/handoff"} => :coordinator,
    {:post, "/api/issues/:id/handback"} => :coordinator,

    # ---- dependencies -----------------------------------------------------
    {:get, "/api/dependencies"} => :coordinator,
    {:post, "/api/dependencies"} => :dependency_add,
    {:get, "/api/dependencies/:issue_id"} => :issue_read,
    {:delete, "/api/dependencies/:from/:to"} => :coordinator,

    # ---- loop ---------------------------------------------------------------
    {:get, "/api/loop/analyze"} => :coordinator,
    {:post, "/api/loop/propose"} => :coordinator,
    {:post, "/api/loop/propose/repo_doc_patch"} => :coordinator,
    {:post, "/api/loop/propose/routing"} => :coordinator,
    {:get, "/api/loop/canary"} => :coordinator,
    {:get, "/api/loop/pending"} => :coordinator,
    {:get, "/api/loop/pending/:id"} => :coordinator,
    {:post, "/api/loop/pending/:id/apply"} => :coordinator,
    {:post, "/api/loop/pending/:id/reject"} => :coordinator,

    # ---- repos / skills ---------------------------------------------------
    {:get, "/api/repos"} => :coordinator,
    {:get, "/api/skills"} => :coordinator,
    {:post, "/api/skills"} => :coordinator,
    {:get, "/api/skills/:id"} => :coordinator,
    {:patch, "/api/skills/:id"} => :coordinator,
    {:put, "/api/skills/:id"} => :coordinator,
    {:delete, "/api/skills/:id"} => :coordinator,

    # ---- providers / accounts (credential-bearing) -------------------------
    {:get, "/api/providers/paused"} => :coordinator,
    {:post, "/api/providers/pause"} => :coordinator,
    {:post, "/api/providers/resume"} => :coordinator,
    {:get, "/api/accounts"} => :coordinator,
    {:post, "/api/accounts"} => :coordinator,
    {:get, "/api/accounts/:ref"} => :coordinator,
    {:patch, "/api/accounts/:ref"} => :coordinator,
    {:post, "/api/accounts/:ref/attach"} => :coordinator,
    {:post, "/api/accounts/:ref/rotate"} => :coordinator,
    {:post, "/api/accounts/:ref/merge"} => :coordinator,
    {:delete, "/api/accounts/:ref"} => :coordinator,

    # ---- workspaces / tracker bridge --------------------------------------
    {:get, "/api/workspaces"} => :workspace_list,
    {:post, "/api/workspaces"} => :coordinator,
    {:get, "/api/workspaces/:id"} => :coordinator,
    {:patch, "/api/workspaces/:id"} => :coordinator,
    {:put, "/api/workspaces/:id"} => :coordinator,
    {:patch, "/api/workspaces/:id/config"} => :coordinator,
    {:post, "/api/workspaces/:workspace_id/claim"} => :coordinator,
    {:get, "/api/workspaces/:workspace_id/sync/plan"} => :coordinator,
    {:post, "/api/workspaces/:workspace_id/sync"} => :coordinator,
    {:get, "/api/workspaces/:workspace_id/tracker/issues"} => :coordinator,
    {:post, "/api/workspaces/:workspace_id/tracker/tickets"} => :coordinator,

    # ---- messages -----------------------------------------------------------
    {:get, "/api/messages"} => :mailbox,
    {:post, "/api/messages"} => :message_send,
    {:post, "/api/messages/:id/read"} => :message_mark_read,
    {:delete, "/api/messages"} => :coordinator,

    # ---- MCP tokens ---------------------------------------------------------
    {:post, "/api/mcp/tokens"} => :any_token,
    {:post, "/api/mcp/tokens/verify"} => :any_token,

    # ---- version / server health -------------------------------------------
    {:get, "/api/version"} => :anonymous,
    {:get, "/api/server/migrations"} => :anonymous,
    {:get, "/api/server/bind_address"} => :coordinator,
    {:get, "/api/server/agy_write_jail"} => :coordinator,
    {:get, "/api/server/egress_jail"} => :coordinator,
    {:get, "/api/server/claude_credentials"} => :coordinator,
    {:get, "/api/server/provider_accounts"} => :coordinator,
    {:get, "/api/server/merge_routing"} => :coordinator,
    {:get, "/api/server/tmux"} => :coordinator,

    # ---- install-wide settings (the REST twin of installation_config_*) ------
    # Coordinator for both: `set` is coordinator-only over MCP, and reads match
    # `/api/server/*` and `/api/scheduler/*` (workers read via the MCP tool).
    {:get, "/api/installation/config"} => :coordinator,
    {:patch, "/api/installation/config"} => :coordinator,

    # ---- usage / reviews / quota ------------------------------------------
    {:get, "/api/usage"} => :coordinator,
    {:get, "/api/usage/events"} => :coordinator,
    {:get, "/api/usage/calibration"} => :coordinator,
    {:get, "/api/external_reviews"} => :coordinator,
    {:get, "/api/external_reviews/:id/transcript"} => :coordinator,
    {:get, "/api/review_gate_rounds"} => :coordinator,
    {:get, "/api/quota"} => :coordinator,
    {:get, "/api/coverage_shadow/preflip_gate"} => :coordinator,

    # ---- workers ------------------------------------------------------------
    {:post, "/api/workers/dispatch"} => :dispatch,
    {:post, "/api/workers/review"} => :dispatch,
    {:post, "/api/workers/:task_id/resume"} => :dispatch,
    {:get, "/api/workers/history"} => :coordinator,
    {:get, "/api/workers/history/:id"} => :coordinator,
    {:get, "/api/workers"} => :coordinator,
    {:get, "/api/workers/:task_id"} => :coordinator,
    {:get, "/api/workers/:task_id/log"} => :coordinator,
    {:get, "/api/workers/:task_id/prompt"} => :coordinator,
    {:get, "/api/workers/:task_id/run_log_list"} => :coordinator,
    {:post, "/api/workers/:task_id/stop"} => :coordinator,

    # ---- queue / alerts / breakers / scheduler ----------------------------
    {:post, "/api/queue/:task_id/retry_auto_resolve"} => :coordinator,
    {:post, "/api/queue/:task_id/restart_watchdog"} => :coordinator,
    {:post, "/api/queue/:task_id/rerun_ci"} => :coordinator,
    {:post, "/api/queue/:task_id/mark_ci_external"} => :coordinator,
    {:get, "/api/alerts"} => :coordinator,
    {:get, "/api/breakers"} => :coordinator,
    {:post, "/api/breakers/reset"} => :coordinator,
    {:post, "/api/scheduler/pause"} => :coordinator,
    {:post, "/api/scheduler/resume"} => :coordinator,
    {:get, "/api/scheduler/status"} => :coordinator
  }

  @doc "Every classified route, as `{verb, route_pattern} => policy`."
  @spec policies() :: %{{atom(), String.t()} => policy()}
  def policies, do: @policies

  @doc """
  The policy for a route, by verb and router pattern (`"/api/issues/:id"`).
  `:unclassified` for a route missing from the table, which `authorize/3`
  refuses.
  """
  @spec policy(atom(), String.t()) :: policy() | :unclassified
  def policy(verb, route), do: Map.get(@policies, {verb, route}, :unclassified)

  @doc """
  Decide one request. `scope` is the caller's decoded token, or `nil` for a
  caller that presented none.

  Returns `:ok`, `{:error, :unauthenticated, message}` (401: present a
  token) or `{:error, :forbidden, message}` (403: this token may not).
  """
  @spec authorize(policy() | :unclassified, Scope.t() | nil, map()) ::
          :ok | {:error, :unauthenticated | :forbidden, String.t()}
  def authorize(:anonymous, _scope, _params), do: :ok

  def authorize(_policy, nil, _params) do
    {:error, :unauthenticated,
     "Authorization: Bearer <token> required. On the server host, run `arb` from your own " <>
       "shell: it mints a token over the operator socket (as `arb mcp token mint` does). " <>
       "Elsewhere, set ARB_TOKEN."}
  end

  def authorize(:unclassified, _scope, _params),
    do: {:error, :forbidden, "this route has no access policy (ArbiterWeb.ApiPolicy)"}

  def authorize(policy, %Scope{}, _params) when policy in [:any_token, :workspace_list],
    do: :ok

  def authorize(:coordinator, %Scope{tier: :coordinator}, _params), do: :ok

  def authorize(:dispatch, %Scope{tier: :coordinator, can_dispatch: true}, _params), do: :ok

  def authorize(:dispatch, %Scope{tier: :coordinator}, _params),
    do: {:error, :forbidden, "this token may not dispatch (can_dispatch is not set)"}

  def authorize(policy, %Scope{tier: :coordinator}, _params)
      when policy in [
             :issue_read,
             :issue_progress,
             :issue_create,
             :dependency_add,
             :mailbox,
             :message_send,
             :message_mark_read
           ],
      do: :ok

  def authorize(:issue_read, %Scope{tier: tier} = scope, params)
      when tier in [:worker, :refine] do
    issue_id = params["id"] || params["issue_id"]

    if issue_in_workspace?(issue_id, scope.workspace_id),
      do: :ok,
      else: forbidden(scope, "may only read tickets in its own workspace")
  end

  def authorize(:issue_progress, %Scope{tier: :worker, task_id: task_id} = scope, params) do
    extra = params |> Map.keys() |> Enum.reject(&(&1 in @progress_params))

    cond do
      params["id"] != task_id ->
        forbidden(scope, "may only update its own task")

      extra != [] ->
        forbidden(
          scope,
          "may only set progress fields (notes, qa_notes, deployment_notes, pr_body, " <>
            "verify_after_deploy), not #{Enum.join(extra, ", ")}"
        )

      true ->
        :ok
    end
  end

  def authorize(:issue_create, %Scope{tier: :worker} = scope, params) do
    extra = params |> Map.keys() |> Enum.reject(&(&1 in @worker_create_params))

    cond do
      params["parent_id"] != scope.task_id ->
        forbidden(scope, "may only file a ticket as a child of its own task (parent_id)")

      params["workspace_id"] != scope.workspace_id ->
        forbidden(scope, "may only file a ticket in its own workspace")

      extra != [] ->
        forbidden(scope, "may not set #{Enum.join(extra, ", ")} on a ticket it files")

      true ->
        :ok
    end
  end

  def authorize(:dependency_add, %Scope{tier: :worker} = scope, params) do
    cond do
      params["from_issue_id"] != scope.task_id or params["type"] != "parent_of" ->
        forbidden(scope, "may only add a parent_of edge from its own task")

      not issue_in_workspace?(params["to_issue_id"], scope.workspace_id) ->
        forbidden(scope, "may only adopt a ticket in its own workspace")

      has_parent?(params["to_issue_id"]) ->
        forbidden(scope, "may only adopt a ticket that has no parent yet")

      true ->
        :ok
    end
  end

  def authorize(:mailbox, %Scope{tier: :worker, task_id: task_id} = scope, params) do
    if params["to_ref"] == task_id,
      do: :ok,
      else: forbidden(scope, "may only read its own mailbox (to_ref=#{task_id})")
  end

  def authorize(:message_send, %Scope{tier: :worker}, _params), do: :ok

  def authorize(:message_mark_read, %Scope{tier: :worker, task_id: task_id} = scope, params) do
    case Ash.get(Arbiter.Messages.Message, params["id"]) do
      {:ok, %{to_ref: ^task_id}} -> :ok
      {:ok, _} -> forbidden(scope, "may only mark its own mail read")
      # Unknown id: let the controller answer 404 as it always has.
      {:error, _} -> :ok
    end
  end

  def authorize(_policy, %Scope{} = scope, _params),
    do: forbidden(scope, "may not call this route (coordinator only)")

  defp forbidden(%Scope{tier: tier}, why), do: {:error, :forbidden, "a #{tier}-tier token #{why}"}

  # An issue the caller cannot see is "not yours" — but an id that does not
  # exist at all falls through to the controller's own 404.
  defp issue_in_workspace?(issue_id, workspace_id) when is_binary(issue_id) do
    case Ash.get(Arbiter.Tasks.Issue, issue_id) do
      {:ok, %{workspace_id: ws}} -> ws == workspace_id
      {:error, _} -> true
    end
  end

  defp issue_in_workspace?(_issue_id, _workspace_id), do: false

  defp has_parent?(issue_id) do
    case Arbiter.Tasks.Dependencies.list(issue_id: issue_id) do
      {:ok, deps} ->
        Enum.any?(deps, &(&1.edge.type == :parent_of and &1.edge.to_issue_id == issue_id))

      _ ->
        true
    end
  end
end
