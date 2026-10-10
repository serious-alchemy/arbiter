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
    * `:operator` — a `:coordinator`-tier token carrying **operator proof**
      (`Arbiter.MCP.Scope.operator?/1`: minted over the operator socket, the
      human's own `arb`). Node administration over REST (join-token minting,
      drain, revoke, remove — `docs/design/remote-workers.md` §5.3): a
      coordinator *session* (an LLM) is refused, so it cannot enrol machines
      that will receive provider tokens. Used by every `/api/nodes` route: the list, minting, edits, drain, revoke, remove, upgrade;
      by every `/api/memory` route (P-25: the shared memory layer is operator authority,
      reads included; a coordinator *session* is refused);
      by `POST /api/dashboard/login_tokens` (P-28: a dashboard login is an operator
      grant, so an LLM coordinator session must not mint one;
      `docs/design/tier-proof-boundaries.md`);
      by `POST /api/trust/promote` (G18: promoting a subject loosens its
      guardrails, so only the operator does it, from `arb trust promote`);
      and by `/api/release/deploy`, which restarts the server onto a new release.
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
    * `:quota_read` — coordinator; or a worker token reading the quota of its
      own (bound) workspace, the REST twin of the worker-callable `quota_get`
      MCP tool (P-18, D-A-6). `?account=` reaches past the workspace, so it
      stays coordinator-only.
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
    * `:own_task` — coordinator; or a worker acting on **its own task** (the
      `:task_id` path param). The REST twin of the worker-tier `ci_rerun` /
      `ci_mark_external` MCP tools: a worker files them from its own CI failure,
      and `Arbiter.MCP.Tools.resolve_task_id/3` pins the MCP side to the same
      rule (bd-dtfe9x).
    * `:mailbox` — coordinator; or a worker reading its own mailbox
      (`to_ref` must be its own task) or the notification feed
      (`kind=notification` with no `to_ref`; always its own workspace).
    * `:message_send` — coordinator; or a worker. `MessageController.create/2`
      pins a worker's `from_ref` to its own task (`Mailbox.send_message/2`, shared
      with the `message_send` MCP tool).
    * `:message_show` — coordinator; or a worker reading, by id, a message
      addressed to its own task (whoever sent it). Anything else is a 403 that
      names the scope rule, never a silent miss.
    * `:message_mark_read` — coordinator; or a worker marking a message
      addressed to its own task.
    * `:research_read` — coordinator; or a worker token whose ticket was granted
      `research_read` (bd-6ircwr; `Arbiter.Worker.ResearchGrant`, off unless the
      workspace binds it). Only on the read-only run, usage and review-round `GET`s
      a research run needs to study Arbiter's own behaviour: `arb worker
      runs|show|log`, `arb usage show|events`, `arb review rounds`. The controllers
      confine a workspace-bound token to its own workspace, and no mutating route
      carries this policy, so the grant opens no write. A worker without the claim,
      and a refine token, get the coordinator-only refusal.
    * `:grok_token` — coordinator or worker. `POST /api/grok/token` hands a grok
      worker a short-lived access token (`Arbiter.Grok.CredentialBroker`); the
      refresh token never leaves the server. A refine token has no use for it.

  A `:refine` token gets `:issue_read` and `:workspace_list` and nothing else over REST: its writes
  are subtree-gated and only exist as MCP tools (`Arbiter.MCP.RefinePolicy`).
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.WorkerFiling

  @type policy ::
          :anonymous
          | :coordinator
          | :operator
          | :dispatch
          | :any_token
          | :issue_read
          | :workspace_list
          | :quota_read
          | :issue_progress
          | :issue_create
          | :dependency_add
          | :own_task
          | :mailbox
          | :message_send
          | :message_show
          | :message_mark_read
          | :research_read
          | :grok_token

  # The REST twin of `ticket_update_progress` (`Arbiter.MCP.Tools.Task`'s
  # `@progress_fields ++ @progress_flags`). "id" is the path param.
  @progress_params ~w(id notes append_notes qa_notes deployment_notes pr_body verify_after_deploy)

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
    {:post, "/api/issues/:id/sync_upstream_close"} => :coordinator,
    {:post, "/api/issues/:id/resume_review"} => :coordinator,
    {:patch, "/api/issues/:id/rank"} => :coordinator,
    {:patch, "/api/issues/:id/floor"} => :coordinator,
    {:post, "/api/issues/:id/verify"} => :coordinator,
    {:post, "/api/issues/:id/resolve"} => :coordinator,
    {:post, "/api/issues/:id/handoff"} => :coordinator,
    {:post, "/api/issues/:id/handback"} => :coordinator,
    {:post, "/api/issues/:id/permission"} => :coordinator,

    # ---- dependencies -----------------------------------------------------
    {:get, "/api/dependencies"} => :coordinator,
    {:post, "/api/dependencies"} => :dependency_add,
    {:get, "/api/dependencies/:issue_id"} => :issue_read,
    {:delete, "/api/dependencies/:from/:to"} => :coordinator,

    # ---- loop ---------------------------------------------------------------
    {:get, "/api/loop/analyze"} => :coordinator,
    {:post, "/api/loop/analyze"} => :coordinator,
    {:post, "/api/loop/propose"} => :coordinator,
    {:post, "/api/loop/propose/repo_doc_patch"} => :coordinator,
    {:post, "/api/loop/propose/routing"} => :coordinator,
    {:get, "/api/loop/canary"} => :coordinator,
    {:get, "/api/loop/pending"} => :coordinator,
    {:get, "/api/loop/pending/:id"} => :coordinator,
    {:post, "/api/loop/pending/:id/apply"} => :coordinator,
    {:post, "/api/loop/pending/:id/reject"} => :coordinator,

    # ---- earned trust (G18) --------------------------------------------------
    # A promotion loosens a subject's guardrails: operator proof only. The
    # coordinator reads, and confirms or dismisses an automatic suspension.
    {:get, "/api/trust"} => :coordinator,
    {:post, "/api/trust/promote"} => :operator,
    {:post, "/api/trust/confirm"} => :coordinator,
    {:post, "/api/trust/dismiss"} => :coordinator,

    # ---- repos / skills ---------------------------------------------------
    {:get, "/api/repos"} => :coordinator,
    {:get, "/api/repos/:name"} => :coordinator,
    {:get, "/api/skills"} => :coordinator,
    {:post, "/api/skills"} => :coordinator,
    {:get, "/api/skills/:id"} => :coordinator,
    {:patch, "/api/skills/:id"} => :coordinator,
    {:put, "/api/skills/:id"} => :coordinator,
    {:delete, "/api/skills/:id"} => :coordinator,

    # ---- providers / accounts (credential-bearing) -------------------------
    {:get, "/api/providers/paused"} => :coordinator,

    # ---- memory (P-25): the shared layer every future session mounts ----------
    {:get, "/api/memory/pending"} => :operator,
    {:get, "/api/memory/pending/diff"} => :operator,
    {:post, "/api/memory/pending/apply"} => :operator,
    {:post, "/api/memory/pending/reject"} => :operator,
    {:get, "/api/memory/quarantine"} => :operator,
    {:post, "/api/memory/quarantine/restore"} => :operator,
    {:post, "/api/memory/distill"} => :operator,

    # ---- nodes (RW4, RW7): operator-proof only, reads included ---------------
    {:post, "/api/nodes/join-tokens"} => :operator,
    {:get, "/api/nodes/pairings"} => :operator,
    {:post, "/api/nodes/pairings/:ref/approve"} => :operator,
    {:post, "/api/nodes/pairings/:ref/deny"} => :operator,
    {:get, "/api/nodes"} => :operator,
    {:get, "/api/nodes/:ref"} => :operator,
    {:get, "/api/nodes/:ref/events"} => :operator,
    {:patch, "/api/nodes/:ref"} => :operator,
    {:post, "/api/nodes/:ref/drain"} => :operator,
    {:post, "/api/nodes/:ref/undrain"} => :operator,
    {:post, "/api/nodes/:ref/revoke"} => :operator,
    {:post, "/api/nodes/:ref/upgrade"} => :operator,
    {:delete, "/api/nodes/:ref"} => :operator,

    # ---- operator self-update (bd-6umf7z): launches `arb server deploy` -------
    {:post, "/api/release/deploy"} => :operator,
    {:get, "/api/release/deploy"} => :operator,
    {:post, "/api/providers/pause"} => :coordinator,
    {:post, "/api/providers/resume"} => :coordinator,
    {:get, "/api/accounts"} => :coordinator,
    {:post, "/api/accounts"} => :coordinator,
    {:get, "/api/accounts/:ref"} => :coordinator,
    {:patch, "/api/accounts/:ref"} => :coordinator,
    {:post, "/api/accounts/:ref/attach"} => :coordinator,
    {:delete, "/api/accounts/:ref/attach/:workspace_id"} => :coordinator,
    {:post, "/api/accounts/:ref/rotate"} => :coordinator,
    {:post, "/api/accounts/:ref/merge"} => :coordinator,
    {:delete, "/api/accounts/:ref"} => :coordinator,
    {:post, "/api/accounts/:ref/login"} => :coordinator,
    {:get, "/api/account_logins/:id"} => :coordinator,
    {:post, "/api/account_logins/:id/paste"} => :coordinator,
    {:post, "/api/account_logins/:id/cancel"} => :coordinator,

    # ---- workspaces / tracker bridge --------------------------------------
    {:get, "/api/workspaces"} => :workspace_list,
    {:post, "/api/workspaces"} => :coordinator,
    # The key reference is static documentation, readable by any token (the
    # MCP `workspace_config_schema` tool is both-tier).
    {:get, "/api/workspaces/config_schema"} => :any_token,
    {:get, "/api/workspaces/:id"} => :coordinator,
    {:patch, "/api/workspaces/:id"} => :coordinator,
    {:put, "/api/workspaces/:id"} => :coordinator,
    {:patch, "/api/workspaces/:id/config"} => :coordinator,
    {:post, "/api/workspaces/:id/standing_orders"} => :coordinator,
    {:post, "/api/workspaces/:id/standing_orders/remove"} => :coordinator,
    {:post, "/api/workspaces/:workspace_id/claim"} => :coordinator,
    {:get, "/api/workspaces/:workspace_id/sync/plan"} => :coordinator,
    {:post, "/api/workspaces/:workspace_id/sync"} => :coordinator,
    {:get, "/api/workspaces/:workspace_id/tracker/issues"} => :coordinator,
    {:post, "/api/workspaces/:workspace_id/tracker/tickets"} => :coordinator,

    # ---- messages -----------------------------------------------------------
    {:get, "/api/messages"} => :mailbox,
    {:post, "/api/messages"} => :message_send,
    {:get, "/api/messages/:id"} => :message_show,
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
    {:get, "/api/server/guardrails"} => :coordinator,
    {:get, "/api/server/claude_credentials"} => :coordinator,
    {:get, "/api/server/grok_auth"} => :coordinator,
    {:get, "/api/server/provider_accounts"} => :coordinator,
    {:get, "/api/server/merge_routing"} => :coordinator,
    {:get, "/api/server/tmux"} => :coordinator,
    {:get, "/api/server/worker_tmp"} => :coordinator,
    {:get, "/api/server/podman_sandbox"} => :coordinator,
    {:get, "/api/server/worker_memory"} => :coordinator,
    {:get, "/api/server/dashboard_auth"} => :coordinator,
    {:get, "/api/server/doctor_scope"} => :coordinator,
    {:get, "/api/server/spawn_canary"} => :coordinator,
    {:post, "/api/server/spawn_canary"} => :coordinator,
    {:post, "/api/dashboard/login_tokens"} => :operator,

    # ---- attention queue (the coordinator's triage read) ---------------------
    {:get, "/api/attention"} => :coordinator,

    # ---- install-wide settings (the REST twin of installation_config_*) ------
    # Coordinator for both: `set` is coordinator-only over MCP, and reads match
    # `/api/server/*` and `/api/scheduler/*` (workers read via the MCP tool).
    {:get, "/api/installation/config"} => :coordinator,
    {:patch, "/api/installation/config"} => :coordinator,

    # ---- usage / reviews / quota ------------------------------------------
    {:get, "/api/usage"} => :research_read,
    {:get, "/api/usage/events"} => :research_read,
    {:get, "/api/usage/calibration"} => :coordinator,
    {:get, "/api/external_reviews"} => :coordinator,
    {:get, "/api/external_reviews/:id/transcript"} => :coordinator,
    {:get, "/api/external_reviews/:id"} => :coordinator,
    # Posts to the PR under the fleet's identity: dispatch tier, like the review itself.
    {:post, "/api/external_reviews/:id/greenlight"} => :dispatch,
    {:get, "/api/review_gate_rounds"} => :research_read,
    {:get, "/api/quota"} => :quota_read,
    {:get, "/api/coverage_shadow/preflip_gate"} => :coordinator,

    # ---- workers ------------------------------------------------------------
    {:post, "/api/workers/dispatch"} => :dispatch,
    {:post, "/api/workers/review"} => :dispatch,
    {:post, "/api/workers/:task_id/resume"} => :dispatch,
    # The read half is what a `research_read` grant opens (bd-6ircwr); the prompt
    # (other tasks' composed instructions) and every write stay coordinator-only.
    {:get, "/api/workers/history"} => :research_read,
    {:get, "/api/workers/history/:id"} => :research_read,
    {:get, "/api/workers"} => :research_read,
    {:get, "/api/workers/:task_id"} => :research_read,
    {:get, "/api/workers/:task_id/log"} => :research_read,
    {:get, "/api/workers/:task_id/prompt"} => :coordinator,
    {:get, "/api/workers/:task_id/run_log_list"} => :research_read,
    {:post, "/api/workers/:task_id/stop"} => :coordinator,

    # ---- queue / alerts / breakers / scheduler ----------------------------
    {:post, "/api/queue/:task_id/retry_auto_resolve"} => :coordinator,
    {:post, "/api/queue/:task_id/restart_watchdog"} => :coordinator,
    {:post, "/api/queue/:task_id/rerun_ci"} => :own_task,
    {:post, "/api/queue/:task_id/mark_ci_external"} => :own_task,
    {:get, "/api/alerts"} => :coordinator,
    {:get, "/api/breakers"} => :coordinator,
    {:post, "/api/breakers/reset"} => :coordinator,

    # ---- grok credential broker (bd-9p4lx9) ---------------------------------
    {:post, "/api/grok/token"} => :grok_token,
    # ---- worker images (bd-9r5jdt): operator/coordinator only ---------------
    {:get, "/api/images"} => :coordinator,
    {:post, "/api/images/build"} => :coordinator,
    {:post, "/api/images/refresh"} => :coordinator,
    {:post, "/api/images/prune"} => :coordinator,
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

  def authorize(:quota_read, %Scope{tier: :coordinator}, _params), do: :ok

  def authorize(:quota_read, %Scope{tier: :worker} = scope, params) do
    case params["account"] do
      acct when is_binary(acct) and acct != "" ->
        forbidden(scope, "may only read its own workspace's quota, not ?account=")

      _ ->
        :ok
    end
  end

  def authorize(:operator, %Scope{} = scope, _params) do
    if Scope.operator?(scope),
      do: :ok,
      else:
        forbidden(
          scope,
          "lacks operator proof (this route is operator-only: node administration, dashboard " <>
            "login, trust promotion)"
        )
  end

  def authorize(:research_read, %Scope{tier: :coordinator}, _params), do: :ok

  def authorize(:research_read, %Scope{tier: :worker} = scope, _params) do
    if Scope.permission?(scope, "research_read"),
      do: :ok,
      else:
        forbidden(
          scope,
          "may not call this route (coordinator only; a ticket granted research_read may read it)"
        )
  end

  def authorize(:grok_token, %Scope{tier: tier}, _params) when tier in [:coordinator, :worker],
    do: :ok

  def authorize(:dispatch, %Scope{tier: :coordinator, can_dispatch: true}, _params), do: :ok

  def authorize(:dispatch, %Scope{tier: :coordinator}, _params),
    do: {:error, :forbidden, "this token may not dispatch (can_dispatch is not set)"}

  def authorize(policy, %Scope{tier: :coordinator}, _params)
      when policy in [
             :issue_read,
             :issue_progress,
             :issue_create,
             :dependency_add,
             :own_task,
             :mailbox,
             :message_send,
             :message_show,
             :message_mark_read
           ],
      do: :ok

  def authorize(:issue_read, %Scope{tier: tier} = scope, params)
      when tier in [:worker, :refine] do
    issue_id = params["id"] || params["issue_id"]

    if WorkerFiling.issue_in_workspace?(issue_id, scope.workspace_id),
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

  def authorize(:issue_create, %Scope{tier: :worker} = scope, params),
    do: filing(scope, WorkerFiling.authorize_create(scope, params))

  def authorize(:dependency_add, %Scope{tier: :worker} = scope, params),
    do: filing(scope, WorkerFiling.authorize_dependency(scope, params))

  def authorize(:own_task, %Scope{tier: :worker, task_id: task_id} = scope, params) do
    if params["task_id"] == task_id,
      do: :ok,
      else: forbidden(scope, "may only act on its own task")
  end

  # A worker reads its own mailbox, or the notification feed (`arb notify`, MCP
  # `notify_list`) — a broadcast, not anyone's mail. The controller confines the
  # latter to the worker's own workspace (a bound token resolves to it).
  def authorize(:mailbox, %Scope{tier: :worker, task_id: task_id} = scope, params) do
    cond do
      params["to_ref"] == task_id -> :ok
      params["kind"] == "notification" and params["to_ref"] in [nil, ""] -> :ok
      true -> forbidden(scope, "may only read its own mailbox (to_ref=#{task_id})")
    end
  end

  def authorize(:message_send, %Scope{tier: :worker}, _params), do: :ok

  def authorize(:message_show, %Scope{tier: :worker, task_id: task_id} = scope, params) do
    case Ash.get(Arbiter.Messages.Message, params["id"]) do
      {:ok, %{to_ref: ^task_id}} ->
        :ok

      {:ok, _} ->
        forbidden(scope, "may only read its own mailbox (message not addressed to #{task_id})")

      # Unknown id: let the controller answer 404 as it always has.
      {:error, _} ->
        :ok
    end
  end

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

  defp filing(_scope, :ok), do: :ok
  defp filing(scope, {:error, why}), do: forbidden(scope, why)
end
