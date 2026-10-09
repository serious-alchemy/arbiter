defmodule Arbiter.Worker.Dispatch do
  @moduledoc """
  Spawn a worker for a task and attach it to the `Arbiter.Workflows.Work`
  workflow via `Arbiter.Workflows.Machine`.

  This is the "go work this task" entry point — called by:

    * the `arb dispatch <task-id>` CLI command (via the REST API),
    * the `MergeQueue` GenServer (when re-dispatching follow-ups),
    * Phoenix LiveView dashboards that have a "send worker" button.

  Single responsibility: orchestrate the three steps needed to start a
  worker working on a task, in the right order, with the right cleanup if
  anything fails.

  ## Steps

  1. Load the task and ask the one dispatch-eligibility predicate,
     `Arbiter.Tasks.Lifecycle.dispatchable/2` (bd-asxw4e), with its open
     blockers. A closed ticket is always refused. A Backlog or Blocked ticket
     is refused with the reason (`{:not_dispatchable, id, hold}`,
     `refusal_message/2`) unless `force: true`, which is recorded as a
     `dispatch_forced` event. Autopilot's dispatch (`dispatched_by:
     "autopilot"`) must still find the ticket Ready and is never forced. A
     resume, a review, or a re-dispatch of work already In progress is not an
     admission and passes.
  2. Transition the ticket to `:active` (`Issue.start_work/2`; a resumed
     Merging ticket goes back to work).
  3. Provision a git worktree on a per-task branch — skipped when the
     repo isn't in `:arbiter, :repo_paths` or `provision_worktree: false`.
  4. Start a worker under `Arbiter.Worker.Supervisor` for the task.
  5. **Optionally** spawn a Claude subprocess in the worktree via
     `ClaudeSession.start/1`. Opt-in via `start_claude: true` — defaults
     to `false` to avoid silent paid-API invocations. Requires a worktree.
  6. Attach `Arbiter.Workflows.Work` via `Workflows.Machine.attach/3`
     and start the machine.
  7. Start a `Arbiter.Worker.Driver` under the same supervisor — it
     ticks the machine forward and closes the task when the workflow
     completes. Skipped when `start_driver: false`.

  ## Returns

  ```
  {:ok, %{
    task: %Issue{},              # updated, state: :active
    worker_pid: pid(),
    machine_id: String.t(),
    machine_pid: pid(),
    driver_pid: pid() | nil,     # nil if start_driver: false
    worktree_path: String.t() | nil,  # nil if repo unconfigured / opted out
    review_checkout: map() | nil,     # reviewer's throwaway checkout, if any
    claude_port: port() | nil    # nil unless start_claude: true
  }}
  ```

  A review dispatch's `:review_checkout` is normally reclaimed by the Driver
  when the run ends. With `start_driver: false` there is no Driver, so the
  caller owns it and must `Arbiter.Reviews.Checkout.teardown/1` its `:path`.

  Or `{:error, reason}` for any step that fails. On error, partial work is
  best-effort-rolled-back (started worker is stopped; task state revert is
  NOT attempted because the user may want to inspect what happened).
  """

  alias Arbiter.Accounts.Admission
  alias Arbiter.Agents
  alias Arbiter.Agents.CapabilityMatrix
  alias Arbiter.Agents.Claude.CredentialCheck
  alias Arbiter.Agents.Floors
  alias Arbiter.Agents.Gemini.Config, as: GeminiConfig
  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Drain
  alias Arbiter.CircuitBreaker
  alias Arbiter.Guardrails
  alias Arbiter.MCP.AgentConfig.Codex
  alias Arbiter.MCP.AgentConfig.Gemini, as: GeminiMCP
  alias Arbiter.Mergers.Github.RepoResolver
  alias Arbiter.Mergers.PendingMerge
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Nodes.LocalCapacity
  alias Arbiter.Nodes.Placement
  alias Arbiter.Reviews.Checkout
  alias Arbiter.Tasks.EdgeGate
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueRepo
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Driver
  alias Arbiter.Worker.GitLayout
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.PromptBuilder
  alias Arbiter.Worker.ResumeContext
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Worker.RunProvenance
  alias Arbiter.Worker.Sandbox
  alias Arbiter.Worker.SeedPaths
  alias Arbiter.Worker.StopReason
  alias Arbiter.Worker.TargetBranch
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunState
  alias Arbiter.Workflows.CodeReview
  alias Arbiter.Workflows.DispatchQueue
  alias Arbiter.Workflows.Machine
  alias Arbiter.Workflows.Work

  require Ash.Query
  require Logger

  @type dispatch_opts :: [
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          workflow_module: module(),
          start_driver: boolean(),
          start_claude: boolean(),
          claude_command: [String.t()] | nil,
          cleanup_worktree: boolean(),
          model: String.t() | nil,
          agent_type: atom() | nil,
          review: boolean(),
          security: map() | nil,
          security_mode: String.t() | atom() | nil,
          preflight: boolean(),
          agent_adapter: module() | nil,
          depth: non_neg_integer(),
          # bd-asxw4e: dispatch a Backlog or Blocked ticket anyway; recorded.
          force: boolean(),
          dispatched_by: String.t() | nil,
          # bd-92mx1m, resume/2 and resume_session/2 only — see ResumeSlot.
          resume_origin: :human | :automatic,
          force_slot: boolean(),
          slot_override_actor: String.t() | nil,
          slot_admitted: boolean(),
          defer_resume: (String.t(), :resume | :resume_session, keyword() -> :ok | term())
        ]

  @typedoc """
  What `resume/2` / `resume_session/2` return in place of a dispatch result
  when an automatic resume was deferred until a slot frees (bd-92mx1m).
  """
  @type deferred_result :: %{
          deferred: true,
          task_id: String.t(),
          cap: non_neg_integer(),
          holders: [String.t()]
        }

  @type dispatch_result :: %{
          task: Issue.t(),
          worker_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          driver_pid: pid() | nil,
          worktree_path: String.t() | nil,
          # The reviewer's throwaway checkout, if one was provisioned
          # (bd-199giy). Owned by the Driver, which tears it down when the run
          # ends — EXCEPT under `start_driver: false`, where no Driver exists
          # and teardown is the caller's job: `Checkout.teardown(result.review_checkout.path)`.
          review_checkout: Checkout.branch_checkout() | nil,
          claude_port: port() | nil
        }

  @spec dispatch(String.t(), dispatch_opts()) :: {:ok, dispatch_result()} | {:error, term()}
  def dispatch(task_id, opts \\ []) when is_binary(task_id) do
    case Keyword.pop(opts, :quota_resume) do
      {true, rest} ->
        quota_resume(task_id, rest)

      {_, _} ->
        # bd-9fgg04: until `Worker.start/1` registers, a dispatch in progress is
        # invisible to the worker supervisor — track it so a drain report sees it.
        # This covers every caller: `arb dispatch`, the Conductor's DispatchQueue,
        # Watchdog auto-resume and the autopilot's promotion task.
        Drain.track(:dispatch_pending, %{task_id: task_id}, fn -> do_dispatch(task_id, opts) end)
    end
  end

  # bd-a6vh2x: the replay of a run that stopped on its provider's quota
  # (`Arbiter.Worker` holds it in the DispatchQueue with `quota_resume: true`).
  # It is the same thing `arb worker resume` does: continue the stopped
  # session in the preserved worktree — on whichever provider routing now
  # picks, so a hold that outlasts a sibling's headroom reroutes (a different
  # provider has no use for the old session id and is briefed from the
  # worktree's git state instead, see `resolve_session_resume_provider/3`). A
  # task with no captured session id has nothing to continue, so it gets the
  # git-derived briefing outright rather than a fresh start.
  defp quota_resume(task_id, opts) do
    case resume_task(task_id, opts) do
      {:error, :no_session} -> resume(task_id, Keyword.delete(opts, :resume_mode))
      other -> other
    end
  end

  # bd-8suxac: an account admission (`ensure_account_capacity/2`) reserves its
  # slot from this process until the dispatch returns — by then the worker,
  # if one started, is registered and counted in its place.
  defp do_dispatch(task_id, opts) do
    dispatch_steps(task_id, opts)
  after
    Admission.release(task_id)
    LocalCapacity.release(task_id)
  end

  defp dispatch_steps(task_id, opts) do
    opts = normalize_opts(opts)

    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_dispatchable(task, opts),
         opts = apply_issue_repo_default(task, opts),
         opts = put_security_policy(task, opts),
         :ok <- ensure_not_awaiting_review(task, opts),
         :ok <- ensure_no_live_agent_session(task_id, opts),
         opts = put_routing_choice(task, opts),
         opts = route_implementer(task, opts),
         :ok <- ensure_provider_constraint(task, opts),
         :ok <- ensure_sandbox_backend(task, opts),
         :ok <- ensure_capability(task, opts),
         :ok <- ensure_floor(task, opts),
         :ok <- maybe_pause_gate(task, opts),
         :ok <- maybe_quota_gate(task, opts),
         :ok <- ensure_account_capacity(task, opts),
         {:ok, opts} <- ensure_node_capacity(task, opts),
         :ok <- ensure_migrations_up_to_date(),
         {:ok, opts} <- maybe_resolve_repo_for_real_work(task, opts),
         opts = put_security_policy(task, opts),
         :ok <- maybe_preflight(task, opts),
         {:ok, task} <- transition_to_active(task, opts),
         {:ok, worktree_path} <- maybe_provision_worktree(task, opts),
         {:ok, worker_pid} <- start_worker(task, worktree_path, opts) do
      task
      |> finish_dispatch(worker_pid, worktree_path, opts)
      |> drop_superseded_hold(task)
    else
      err -> err
    end
  end

  # bd-6omte4: a dispatch that went ahead supersedes whatever the quota gate
  # was still holding for the task — on bd-aro53b a held agy fix round
  # outlived a manual re-dispatch on Claude. The drain also refuses a held
  # intent for a task that has moved on; this just cancels it at the source.
  defp drop_superseded_hold({:ok, _} = ok, %Issue{id: id, workspace_id: ws_id}) do
    DispatchQueue.drop(ws_id, id, "the task was dispatched again")
    ok
  end

  defp drop_superseded_hold(other, _task), do: other

  # Everything after `start_worker/3` succeeds — the worker is already
  # registered `:starting`, so a failure here must not be swallowed silently
  # (bd-bi5pn0). A step failing partway (e.g. a transient network/VPN outage
  # during the Claude subprocess spawn, or a workflow-machine attach failure)
  # previously left that `:starting` registration stranded forever: no retry, no
  # escalation, and the task stuck `:active` — which also permanently
  # blackholed PRPatrol dedup for the underlying PR (it treats any non-closed
  # follow-up as "already handled"). On error, explicitly fail the worker
  # (`:starting` -> finished `:failed` is a valid FSM transition) with a `:spawn_failed`
  # `StopReason` and escalate to the coordinator, mirroring the
  # `realign_task_if_orphaned/2` pattern (bd-cgmidt) above.
  defp finish_dispatch(task, worker_pid, worktree_path, opts) do
    # `maybe_start_claude/4` hands back the opts it resolved the agent's cwd
    # with — the seam where a review dispatch's throwaway checkout (bd-199giy)
    # is provisioned and recorded, so the Driver can tear it down and the
    # caller can see it.
    #
    # An outer `case` around the inner `with` chain rather than one flat
    # chain, deliberately: a `with`-clause binding does NOT leak into that
    # `with`'s own `else`. With a single chain the error branch would read the
    # *outer* `opts` — the function parameter, which never carries
    # `:review_checkout` (it is added inside `resolve_agent_cwd/3`) — so its
    # teardown was a guaranteed no-op and the throwaway worktree leaked on
    # every post-spawn failure. Splitting the first step out puts the rebound
    # `opts` in scope for the inner `else`, which is the branch that actually
    # needs it.
    case maybe_start_claude(task, worker_pid, worktree_path, opts) do
      {:ok, claude_port, opts} ->
        with {:ok, machine_id, machine_pid} <-
               attach_and_start_machine(task, worktree_path, opts),
             {:ok, driver_pid} <-
               maybe_start_driver(task, worker_pid, machine_id, machine_pid, worktree_path, opts),
             # bd-cgmidt: `ensure_dispatchable/2` above is a front-of-pipeline check. An
             # async close (in production, the MergeQueue direct-strategy close of an
             # in-flight `{:worker_done}` from the just-stopped run) can land in the
             # window between that guard and `start_worker/3`, flipping the task to
             # `:closed` AFTER the guard passed but as/just before the new worker is
             # attached — leaving a live worker orphaned on a `:closed` task (the
             # close's own StopWorker found no worker to stop). Re-assert here, now
             # that the worker is live, and realign a raced-closed task.
             {:ok, task} <- realign_task_if_orphaned(task.id, worker_pid) do
          {:ok,
           %{
             task: task,
             worker_pid: worker_pid,
             machine_id: machine_id,
             machine_pid: machine_pid,
             driver_pid: driver_pid,
             worktree_path: worktree_path,
             review_checkout: Keyword.get(opts, :review_checkout),
             claude_port: claude_port
           }}
        else
          {:error, reason} = err ->
            # A checkout provisioned moments ago has no Driver to reclaim it once
            # the spawn fails, so tear it down here rather than leak it.
            Checkout.teardown(review_checkout_path(opts))
            fail_spawned_worker(worker_pid, reason)
            err
        end

      # `maybe_start_claude/4` is the frame that provisioned the checkout and
      # tears it down on its own failure path, so there is nothing left to
      # reclaim here — and nothing reachable to reclaim it with.
      {:error, reason} = err ->
        fail_spawned_worker(worker_pid, reason)
        err
    end
  end

  defp review_checkout_path(opts) do
    case Keyword.get(opts, :review_checkout) do
      %{path: path} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  # Fail the just-started worker's run `:failed` with a `:spawn_failed`
  # StopReason and raise a coordinator escalation, so the caller's error return
  # is never the *only* signal — the task is not left silently stranded.
  # Best-effort: a dead worker (already terminated some other way) or a
  # notification hiccup must never mask the original dispatch error.
  defp fail_spawned_worker(worker_pid, reason) when is_pid(worker_pid) do
    if Process.alive?(worker_pid) do
      stop_reason = StopReason.spawn_failed(reason)
      snapshot = safe_worker_snapshot(worker_pid)

      _ = Worker.fail(worker_pid, stop_reason)
      CoordinatorNotifier.spawn_failed(snapshot, stop_reason)
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp fail_spawned_worker(_worker_pid, _reason), do: :ok

  defp safe_worker_snapshot(pid) do
    Worker.state(pid)
  rescue
    _ -> %{task_id: nil}
  catch
    :exit, _ -> %{task_id: nil}
  end

  @doc """
  Resume a stopped worker (bd-auma3z): re-attach a **fresh** agent to the
  task's **preserved** worktree, briefed with a git-derived summary of
  the prior worker's committed + uncommitted work, so it continues from where
  the stopped run left off instead of restarting from scratch.

  Since bd-a9hqfb this is the explicit **opt-in** variant (`mode: "briefing"` on
  every surface, via `resume_task/2`); the default manual resume is
  `resume_session/2`. It also serves the automatic-resume and revise paths. It carries no Claude/Gemini
  session-resume id; the continuity comes from the preserved worktree state
  plus a `Arbiter.Worker.ResumeContext` briefing prepended to the standard
  work prompt (coordinator sign-off 2026-06-05, approach (b)). It is NOT
  provider-agnostic, though: unless the caller passes an explicit
  `:agent_type`, the fresh agent defaults to whichever provider the task's
  most recent usage-ledger row ran on (bd-b7e33c AC5), so resuming an agy run
  doesn't silently switch to Claude and spend quota the operator dispatched
  to agy specifically to conserve.

  ## Steps

  1. Load + validate the task (must not be `:closed`).
  2. Refuse if a worker is still **actively** working the task — resume only
     applies to a stopped/failed/dead worker. Stop the active one first.
  3. Resolve the repo (explicit opt, else the task's most recent run's repo).
  4. Require the worktree to still exist on disk — `{:error,
     :no_outpost}` if it was cleaned up (nothing to resume; re-`dispatch` instead).
  5. Build the resume briefing from the worktree's git state.
  6. Stop any prior (failed) worker still resident for the task so a fresh
     `worker_run` starts cleanly rather than the new dispatch attaching to the
     dead one (which would skip the run row and collide on the registry key —
     the same class of bug fixed in the conflict-resolver).
  7. Delegate to `dispatch/2` with the resume markers set: it reuses the existing
     worktree (idempotent `Worktree.create`), prepends the briefing, links the
     new run to the prior via `resumed_from_run_id`, and passes the task's
     existing `pr_ref` so completion reuses any open PR rather than duplicating.

  Returns the same `{:ok, dispatch_result()}` / `{:error, reason}` shape as
  `dispatch/2`. Resume-specific errors: `{:error, :no_outpost}`,
  `{:error, {:worker_active, status}}`, `{:error, :repo_unknown}`.
  """
  @spec resume(String.t(), dispatch_opts()) ::
          {:ok, dispatch_result() | deferred_result()} | {:error, term()}
  def resume(task_id, opts \\ []) when is_binary(task_id) do
    # bd-9fgg04: until `Worker.start/1` registers, a dispatch in progress is
    # invisible to the worker supervisor — track it so a drain report sees it.
    Drain.track(:dispatch_pending, %{task_id: task_id}, fn -> do_resume(task_id, opts) end)
  end

  defp do_resume(task_id, opts) do
    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_dispatchable(task, resume: true),
         :ok <- ensure_not_active(task_id),
         {:ok, repo} <- resolve_resume_repo(task, opts),
         {:ok, worktree_path} <- resume_worktree(task, repo),
         target_branch <- resolve_target_branch(task, Keyword.put(opts, :repo, repo)),
         {:ok, context} <- ResumeContext.build(task, worktree_path, target_branch),
         {:ok, opts} <- resume_slot(task, :resume, opts) do
      prior_run_id = latest_run_id(task_id)

      # bd-95lsjb: an auto-revise dispatch passes `:revise_feedback` — the
      # reviewer's PR-side feedback. Prepend it to the git-derived resume
      # briefing so the fresh worker addresses the feedback first, then
      # continues from the preserved worktree.
      context = prepend_revise_feedback(context, opts)

      # Free the registry slot: a stopped worker lingers `:finished`,
      # still registered under task_id. Without stopping it, dispatch/2's
      # start_worker would hit {:already_started, pid} and attach to the dead
      # one — no fresh run, no resumed_from_run_id. Stopping it does NOT touch
      # the worktree (terminate/2 never cleans up), so the worktree is preserved.
      _ = stop_prior_worker(task_id)

      {provider, fallback_reason, decision} =
        resolve_resume_provider(task, opts, Keyword.get(opts, :routing_role, :resume))

      resume_opts =
        opts
        |> Keyword.put(:agent_type, provider)
        |> put_opt_if_present(:provider_fallback, fallback_reason)
        |> put_routing_decision(decision)
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:start_claude, true)
        |> Keyword.put(:resume, true)
        |> Keyword.put(:resume_context, context)
        |> Keyword.put(:resumed_from_run_id, prior_run_id)
        |> Keyword.put(:existing_pr_ref, task.pr_ref)

      # Already inside this resume's Drain.track — skip dispatch/2's own.
      do_dispatch(task_id, resume_opts)
    else
      {:deferred, result} -> {:ok, result}
      other -> other
    end
  end

  defp prepend_revise_feedback(context, opts) do
    case Keyword.get(opts, :revise_feedback) do
      briefing when is_binary(briefing) and briefing != "" -> briefing <> (context || "")
      _ -> context
    end
  end

  @doc """
  Session-level resume (bd-1z7624, #472): re-spawn the worker continuing the
  task's PRIOR Claude session via `claude --print --resume <session_id>` in the
  SAME preserved worktree — NOT a fresh agent. This is the manual trigger for
  the automatic session-resume machinery from bd-t9uq25: it looks up the task's
  most-recent captured `session_id` (from the usage ledger) and threads it into
  the spawn, so the worker's first session opens with `--resume` and the prior
  session's full context is preserved.

  Distinct from `resume/2` (bd-auma3z), which attaches a *fresh* agent briefed
  with a git-derived summary. Session resume keeps the original mind; use it
  when the prior run stopped mid-task (token exhaustion, kill, crash-exit) and
  you want it to literally pick up where it left off — the same thing the
  `:exited_without_done` auto-resume does, triggered manually for a task.

  ## Steps

  1. Load + validate the task (must not be `:closed`).
  2. Refuse if a worker is still actively working the task — stop it first.
  3. Resolve the repo (explicit opt, else the task's most recent run's repo).
  4. Require the preserved worktree to still exist on disk (`{:error,
     :no_outpost}` if it was cleaned up — nothing to resume; dispatch fresh).
  5. Look up the most-recent captured `session_id` for the task. No session id
     on record → `{:error, :no_session}` (nothing to resume at the session
     level; dispatch fresh instead). We never silently start a fresh session.
  6. Stop any lingering prior worker so a fresh run row starts cleanly.
  7. Delegate to `dispatch/2` with `:resume_session_id` set — the worker injects
     `--resume <session_id>` into its first spawn and stashes the *pristine*
     argv, so the bd-t9uq25 auto-resume keeps working correctly on top.
     If the resolved provider doesn't match the provider that captured the
     session id (bd-b7e33c AC5 — e.g. an explicit `--agent` override that
     lands on a different CLI than the one owning the conversation), the
     foreign session id is dropped and `dispatch/2` gets a git-derived
     `ResumeContext.build/3` briefing instead, the same one `resume/2` uses —
     never a silent fresh start with no continuity at all.

  Returns the same `{:ok, dispatch_result()}` / `{:error, reason}` shape as
  `dispatch/2`. Session-resume-specific errors: `{:error, :no_outpost}`,
  `{:error, :no_session}`, `{:error, {:worker_active, status}}`,
  `{:error, :repo_unknown}`.
  """
  @spec resume_session(String.t(), dispatch_opts()) ::
          {:ok, dispatch_result() | deferred_result()} | {:error, term()}
  def resume_session(task_id, opts \\ []) when is_binary(task_id) do
    # bd-9fgg04: until `Worker.start/1` registers, a dispatch in progress is
    # invisible to the worker supervisor — track it so a drain report sees it.
    Drain.track(:dispatch_pending, %{task_id: task_id}, fn -> do_resume_session(task_id, opts) end)
  end

  @doc """
  The manual-resume entry point every surface calls (`arb worker resume`,
  `POST /api/workers/:task_id/resume`, MCP `worker_resume`). `opts` carries the
  `:resume_mode` `Arbiter.Worker.Dispatch.Params` normalised: `:session`
  (default) continues the prior session via `resume_session/2`; `:briefing` is
  the explicit opt-in for `resume/2`'s fresh agent briefed from git state.
  """
  @spec resume_task(String.t(), dispatch_opts()) ::
          {:ok, dispatch_result() | deferred_result()} | {:error, term()}
  def resume_task(task_id, opts \\ []) when is_binary(task_id) do
    case Keyword.pop(opts, :resume_mode, :session) do
      {:briefing, rest} -> resume(task_id, rest)
      {:session, rest} -> resume_session(task_id, rest)
    end
  end

  defp do_resume_session(task_id, opts) do
    with {:ok, task} <- load_task(task_id),
         :ok <- ensure_dispatchable(task, resume: true),
         :ok <- ensure_not_active(task_id),
         {:ok, repo} <- resolve_resume_repo(task, opts),
         {:ok, worktree_path} <- resume_worktree(task, repo),
         {:ok, session_id, session_provider} <- latest_session_id(task_id),
         {:ok, opts} <- resume_slot(task, :resume_session, opts) do
      prior_run_id = latest_run_id(task_id)

      # Free the registry slot the same way resume/2 does: a stopped worker
      # lingers `:finished`, still registered under task_id, and would make
      # dispatch/2 attach to the dead one instead of starting a fresh run.
      # Stopping it never touches the worktree, so it stays preserved.
      _ = stop_prior_worker(task_id)

      {provider, fallback_reason, decision} =
        resolve_session_resume_provider(task, opts, session_provider)

      base_opts =
        opts
        |> Keyword.put(:agent_type, provider)
        |> put_opt_if_present(:provider_fallback, fallback_reason)
        |> put_routing_decision(decision)
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:start_claude, true)
        |> Keyword.put(:resume, true)

      # bd-b7e33c finding 2 (round 1 re-review) / finding 1 (round 2): only
      # carry resume_session_id when the resolved provider still matches the
      # one that captured it — otherwise it's a bogus invocation, e.g.
      # `claude --resume <agy-conversation-uuid>`. Degrade to resume/2's real
      # git-derived briefing instead of silently dropping both (round-2 fix:
      # the old fallback dropped resume_session_id but never built the
      # briefing it claimed to fall back to).
      resume_opts =
        if provider == session_provider and session_history_present?(provider, session_id) do
          Keyword.put(base_opts, :resume_session_id, session_id)
        else
          require Logger

          target_branch = resolve_target_branch(task, Keyword.put(opts, :repo, repo))

          case ResumeContext.build(task, worktree_path, target_branch) do
            {:ok, context} ->
              Logger.info(
                "Dispatch.resume_session: dropping session_id for #{task.id} — " <>
                  "#{no_resume_reason(provider, session_provider, session_id)}; " <>
                  "degrading to a git-derived resume briefing instead"
              )

              Keyword.put(base_opts, :resume_context, context)

            {:error, reason} ->
              Logger.warning(
                "Dispatch.resume_session: dropping session_id for #{task.id} — " <>
                  "#{no_resume_reason(provider, session_provider, session_id)}; failed to build a git-derived resume briefing " <>
                  "(#{inspect(reason)}), proceeding with no briefing"
              )

              base_opts
          end
        end

      resume_opts =
        resume_opts
        |> Keyword.put(:resumed_from_run_id, prior_run_id)
        |> Keyword.put(:existing_pr_ref, task.pr_ref)

      # Already inside this resume's Drain.track — skip dispatch/2's own.
      do_dispatch(task_id, resume_opts)
    else
      {:deferred, result} -> {:ok, result}
      other -> other
    end
  end

  # bd-atsde3: `claude --resume <sid>` only works when the session's JSONL can
  # be put in the new run's config dir (podman runs get a fresh one). A Claude
  # session whose history is neither on disk nor archived would fail with "No
  # conversation found" — resume it as a briefing instead. Other providers
  # keep their own session stores and are not checked.
  defp session_history_present?(:claude, session_id),
    do: Arbiter.Worker.SessionHistory.available?(session_id)

  defp session_history_present?(_provider, _session_id), do: true

  defp no_resume_reason(provider, session_provider, session_id) do
    if provider == session_provider do
      "session #{session_id} has no history on disk or in the run archive " <>
        "(--resume would fail with \"No conversation found\")"
    else
      "session provider #{inspect(session_provider)} does not match resolved provider " <>
        inspect(provider)
    end
  end

  # bd-92mx1m: may this resume re-enter the task at all, given the cap? Asked
  # after every check that could refuse the resume on its own merits (a missing
  # worktree is a better answer than a full cap) and before the prior worker is
  # stopped, so a refusal or a deferral leaves the task exactly as it was. See
  # `Arbiter.Worker.ResumeSlot` for the rule.
  defp resume_slot(%Issue{} = task, kind, opts) do
    admit_opts = [
      origin: Keyword.get(opts, :resume_origin, :human),
      force: Keyword.get(opts, :force_slot) == true,
      actor: Keyword.get(opts, :slot_override_actor),
      slot_admitted: Keyword.get(opts, :slot_admitted) == true
    ]

    case ResumeSlot.admit(task, admit_opts) do
      {:ok, :forced} -> {:ok, Keyword.put(opts, :slot_cap_override, true)}
      {:ok, _admitted} -> {:ok, opts}
      {:defer, info} -> defer_resume(task, kind, opts, info)
      {:error, _} = error -> error
    end
  end

  # `:arbiter, :resume_deferrer` — a module with `defer_resume/3`. The board
  # autopilot everywhere but the test env, which records instead (see
  # config/test.exs).
  defp configured_deferrer do
    module = Application.get_env(:arbiter, :resume_deferrer, Autopilot)
    &module.defer_resume/3
  end

  # An automatic resume at a full cap waits for a slot rather than failing or
  # going over: the board autopilot replays it with the caller's own options
  # the moment one frees, ahead of any new Ready dispatch. A scheduler that
  # cannot take it is a refusal — never a bypass.
  defp defer_resume(%Issue{id: task_id}, kind, opts, info) do
    require Logger

    defer = Keyword.get_lazy(opts, :defer_resume, &configured_deferrer/0)

    case defer.(task_id, kind, Keyword.delete(opts, :defer_resume)) do
      :ok ->
        Logger.info(
          "Dispatch: deferred #{kind} of #{task_id} until a worker slot frees " <>
            "(#{ResumeSlot.limit_phrase(info)})"
        )

        {:deferred, Map.put(info, :deferred, true)}

      other ->
        Logger.warning(
          "Dispatch: could not defer #{kind} of #{task_id} (#{inspect(other)}); refusing it " <>
            "at the full cap instead"
        )

        {:error, {:slot_cap_full, info}}
    end
  end

  @doc """
  Operator-facing explanation for an `{:error, {:worker_active, run}}`
  refusal, where `run` is the live run's `%{state:, waiting_on:}`
  (bd-1uu19b). Single source of truth for the MCP tool and the HTTP API.

  bd-8lq2g7: a run waiting on the review gate needs its own wording. The
  generic "stop it before resuming" is sound advice for a worker that is
  genuinely mid-run, but destructive for one the ReviewGate is judging right
  now: stopping it discards that in-flight review, and the re-dispatch re-runs
  the review gate from round 1. (The other park that wording once covered — a
  worker resident on its open MR — no longer exists since bd-741sid: the
  ticket's Watchdog holds the PR, `Arbiter.Worker.Watchdog.restart_refusal/2`.)

  bd-7xtz6w: that refusal is only ever issued with positive evidence the gate
  is live (`review_in_flight/2`), and it names the evidence it saw. It no longer
  sends the operator to `arb worker list` for a wedged pass: a ReviewGate's
  passes are not ticket-scoped workers, and a wait with no live gate is not
  refused at all.
  """
  @spec worker_active_message(map() | atom(), String.t()) :: String.t()
  def worker_active_message(%{waiting_on: :review_gate} = run, task_id) do
    evidence =
      case Map.get(run, :review_evidence) do
        [_ | _] = seen -> " (#{Enum.join(seen, "; ")})"
        _ -> ""
      end

    "#{task_id}'s run is waiting on the review gate, and the gate is live#{evidence}. " <>
      "Stopping it now discards the review in flight and the next dispatch restarts the " <>
      "gate from round 1. Wait for the verdict: every pass is bounded by the workspace's " <>
      "`review_gate.timeout_ms`, and a gate that stalls with nothing in flight is stopped " <>
      "and the task parked (its attention cause names why), after which `arb worker resume " <>
      "#{task_id}` re-runs the review."
  end

  def worker_active_message(%{state: run_state} = run, _task_id) do
    "a worker is still active for this task (#{RunState.label(run_state, Map.get(run, :outcome))}); " <>
      "stop it before resuming"
  end

  def worker_active_message(run_state, task_id) when is_atom(run_state),
    do: worker_active_message(%{state: run_state}, task_id)

  @doc """
  Check if a task can be safely resumed. Returns a tuple of {resumable, blocked_reason}.
  resumable is true if the worker can be resumed (no live worker, or worker in terminal state).
  blocked_reason is a human-readable string if resumable is false, nil otherwise.
  """
  def resumable_status(task_id) do
    case Worker.whereis(task_id) do
      nil ->
        {true, nil}

      pid ->
        case active_run(pid, task_id) do
          nil -> {true, nil}
          run -> {false, worker_active_message(run, task_id)}
        end
    end
  end

  # Resume only applies to a stopped/failed/dead worker. If a worker is still
  # live in a working state, refuse rather than stomp in-flight work — the
  # operator should `arb worker stop` it first. A `:finished` run, or no
  # worker at all, is resumable.
  defp ensure_not_active(task_id) do
    case Worker.whereis(task_id) do
      nil ->
        :ok

      pid ->
        case active_run(pid, task_id) do
          nil -> :ok
          run -> {:error, {:worker_active, run}}
        end
    end
  end

  # The run that makes a resume unsafe, or nil when there is none: no answer,
  # a `:finished` run, or — bd-7xtz6w — a run waiting on a review gate that
  # nothing shows to be alive.
  defp active_run(pid, task_id) do
    case safe_worker_run(pid) do
      nil ->
        nil

      %{state: :finished} ->
        nil

      %{waiting_on: :review_gate} = run ->
        case review_in_flight(task_id, run) do
          [] ->
            require Logger

            Logger.warning(
              "Dispatch: #{task_id}'s run is waiting on the review gate but no gate process " <>
                "or review pass is live; treating it as stalled and resumable (bd-7xtz6w)"
            )

            nil

          evidence ->
            Map.put(run, :review_evidence, evidence)
        end

      run ->
        run
    end
  end

  @doc """
  Positive evidence that the review gate a run is waiting on is actually live,
  as human-readable lines — `[]` when there is none (bd-7xtz6w).

  The run's own `waiting_on: :review_gate` is NOT evidence: it is exactly the
  state that outlives a gate that died (bd-45tkhq sat in it for 3+ hours with
  no gate, no reviewer and no timer left). What counts:

    * the ReviewGate process the author spawned (`meta.review_gate_pid`) is
      alive — its per-pass timers are then still armed, and the author's own
      liveness check bounds a gate that stalls;
    * a reviewer or implementer pass for the task is registered and not
      finished (`meta.reviews` / `meta.revises`, as `Arbiter.Reviews.GateActivity`
      reads it).
  """
  @spec review_in_flight(String.t(), map()) :: [String.t()]
  def review_in_flight(task_id, run) when is_binary(task_id) do
    gate =
      case Map.get(run, :review_gate_pid) do
        pid when is_pid(pid) ->
          if Process.alive?(pid), do: ["ReviewGate process #{inspect(pid)} is alive"], else: []

        _ ->
          []
      end

    gate ++ Enum.map(live_review_passes(task_id), &"review pass #{&1} is running")
  end

  defp live_review_passes(task_id) do
    Worker.list_children()
    |> Enum.filter(fn worker ->
      meta = Map.get(worker, :meta) || %{}

      (Map.get(meta, :reviews) == task_id or Map.get(meta, :revises) == task_id) and
        Map.get(worker, :state) != :finished
    end)
    |> Enum.map(&(Map.get(&1, :registry_key) || Map.get(&1, :task_id)))
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # The live run's state, as `%{state:, waiting_on:, review_gate_pid:}`, or nil
  # for a worker that could not answer.
  defp safe_worker_run(pid) do
    case Worker.state(pid) do
      %{state: run_state} = snap ->
        %{
          state: run_state,
          waiting_on: Map.get(snap, :waiting_on),
          review_gate_pid: Map.get(Map.get(snap, :meta) || %{}, :review_gate_pid)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp finished_worker?(pid), do: match?(%{state: :finished}, safe_worker_run(pid))

  # The repo: an explicit opt wins; otherwise inherit the task's most recent run's
  # repo so `arb resume <task>` works without re-specifying it. No run + no opt is
  # an error — we can't resolve the worktree without knowing the repo.
  defp resolve_resume_repo(%Issue{id: task_id}, opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" ->
        {:ok, repo}

      _ ->
        case latest_run(task_id) do
          %Run{repo: repo} when is_binary(repo) and repo != "" -> {:ok, repo}
          _ -> {:error, :repo_unknown}
        end
    end
  end

  # Resolve the preserved worktree path for the task's per-task branch and require
  # it to exist on disk AND be on a branch. A missing worktree — or a detached one
  # — means there's nothing to resume.
  #
  # The detached check matters because `ResumeContext.build/3` renders whatever it
  # finds there as "the commits the prior worker made … DO NOT start over"
  # (bd-9r1tta). A detached checkout holds no prior work at all: its `<base>..HEAD`
  # diff is the *upstream* commits it was cut from (the local `<base>` ref being
  # the parent repo's, possibly stale, one), which the briefing would then present
  # to a fresh agent as its predecessor's output. Refuse the resume instead,
  # exactly as `arb resume` did before a task-type dispatch had any checkout.
  #
  # Only detached is rejected, not "any branch other than the derived one": a
  # worktree on some other branch still has commits that plausibly *are* the prior
  # worker's, and refusing there would throw away a resumable run.
  defp resume_worktree(%Issue{} = task, repo) do
    case resolve_repo_path(task, repo) do
      repo_path when is_binary(repo_path) ->
        path = Worktree.worktree_path(BranchNamer.derive(task))

        cond do
          not File.dir?(path) -> {:error, :no_outpost}
          Worktree.detached?(path) == {:ok, true} -> {:error, :no_outpost}
          true -> {:ok, path}
        end

      _ ->
        {:error, :repo_unknown}
    end
  end

  # By pid: stopping by task id also cancels the task's held dispatch
  # (bd-6omte4), and this resume is about to replace that intent itself.
  defp stop_prior_worker(task_id) do
    case Worker.whereis(task_id) do
      nil -> :ok
      pid -> Worker.stop(pid, :normal)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp latest_run_id(task_id) do
    case latest_run(task_id) do
      %Run{id: id} -> id
      _ -> nil
    end
  end

  defp latest_run(nil), do: nil

  defp latest_run(task_id) when is_binary(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # The most-recent captured upstream session id for the task, newest first,
  # PLUS the provider recorded on that SAME row. Drawn from the usage ledger
  # (`Arbiter.Usage.Event`), where the worker persists each session's
  # `session_id` on its terminal `result` event. The task_id filter is exact,
  # so ReviewGate reviewer rows (which carry a `#review` suffix) are excluded
  # — we resume the author's session, not a reviewer's. `{:error, :no_session}`
  # when none was ever captured: the task was never worked by a
  # session-capable agent, so there is nothing to resume at the session level
  # (the caller must dispatch fresh).
  #
  # bd-b7e33c post-merge finding (2026-09-19): this used to return only the
  # session_id, and callers paired it with a SEPARATE `latest_provider/1`
  # query. The two queries can pick different rows — e.g. a newer row from a
  # failed attempt on a different provider that never got far enough to
  # capture a session_id — pinning `:agent_type` to a provider that doesn't
  # own the conversation id being resumed. Returning the provider off the
  # exact row the session_id came from makes that mismatch impossible.
  defp latest_session_id(task_id) when is_binary(task_id) do
    Event
    |> Ash.Query.filter(task_id == ^task_id and not is_nil(session_id))
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Event{session_id: sid, provider: p} when is_binary(sid) and sid != "" ->
        {:ok, sid, safe_provider_atom(p)}

      _ ->
        {:error, :no_session}
    end
  rescue
    _ -> {:error, :no_session}
  end

  defp safe_provider_atom(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp safe_provider_atom(_), do: nil

  # bd-2exkl0: resume passes inherit the provider of the authoring run being
  # resumed via Agents.resolve_revision_provider/2, with escalation to the
  # coordinator if an unexpected provider fallback occurs.
  #
  # bd-40pzpj: under `routing.provider_selection: most_quota` the task's
  # implementer pin decides instead (`ProviderRouting.implementer_provider/4`),
  # and the third element is the routing decision to record. Off, it is
  # exactly the resolution above, with a `nil` decision. A caller's explicit
  # `:agent_type` still wins — routed, it is recorded as an override.
  defp resolve_resume_provider(%Issue{} = task, opts, role) do
    override = caller_override(opts)
    workspace = load_workspace(task)

    {provider, fallback_reason, decision} =
      ProviderRouting.implementer_provider(task, workspace, role,
        override: override,
        security: routing_security(workspace, opts),
        repo: Keyword.get(opts, :repo)
      )

    if fallback_reason && is_nil(override) && ProviderRouting.escalate_fallback?(decision) do
      orig = Run.latest_authoring_provider(task.id)

      CoordinatorNotifier.provider_fallback(
        %{workspace_id: task.workspace_id, task_id: task.id},
        orig,
        provider,
        fallback_reason
      )
    end

    {provider, ProviderRouting.truncate_fallback(fallback_reason), decision}
  end

  defp caller_override(opts) do
    case Keyword.get(opts, :agent_type) do
      p when is_atom(p) and not is_nil(p) -> p
      _ -> nil
    end
  end

  # A routed provider is recorded with the decision; `:routed_agent_type`
  # marks `:agent_type` as routing's own choice rather than a caller's
  # override, so a held dispatch replays unrouted (`unroute/1`).
  defp put_routing_decision(opts, nil), do: opts

  defp put_routing_decision(opts, decision) do
    opts = Keyword.put(opts, :routing_decision, decision)

    if decision["outcome"] == "override",
      do: opts,
      else: Keyword.put(opts, :routed_agent_type, Keyword.get(opts, :agent_type))
  end

  # bd-b7e33c AC5 post-merge finding: `resolve_resume_provider/2` picks the
  # provider off the most recent AUTHORING run, which is a separate query from
  # `latest_session_id/1`'s "most recent row with a session_id" — a newer row
  # on a different provider (e.g. a failed fallback attempt that never
  # captured a session) would win there and pin `:agent_type` to a provider
  # that doesn't own the `--resume`/`--conversation` id being threaded through
  # resume_session/2. Prefer the provider carried on the SAME row the
  # session_id came from when it's still available; only fall through to the
  # general authoring-provider/fallback resolution (with its escalation) when
  # the caller forced a provider, or the session's own provider is unknown or
  # no longer usable.
  #
  # bd-40pzpj: a routed workspace resolves through the implementer pin
  # instead; a session on a different provider then degrades to the
  # git-derived briefing like any other mismatch (see `do_resume_session/2`).
  defp resolve_session_resume_provider(%Issue{} = task, opts, session_provider) do
    role = Keyword.get(opts, :routing_role, :resume_session)

    cond do
      not is_nil(caller_override(opts)) ->
        resolve_resume_provider(task, opts, role)

      ProviderRouting.enabled?(load_workspace(task)) ->
        resolve_resume_provider(task, opts, role)

      not is_nil(session_provider) and Agents.provider_available?(session_provider) and
          ProviderConstraint.allows?(task, session_provider) ->
        {session_provider, nil, nil}

      true ->
        resolve_resume_provider(task, opts, role)
    end
  end

  defp put_opt_if_present(opts, _key, nil), do: opts
  defp put_opt_if_present(opts, _key, ""), do: opts
  defp put_opt_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  # `review: true` is the convenience hook used by `arb review`: it forces the
  # review-only defaults so the caller doesn't have to spell out four flags in
  # tandem (and so the CLI/REST surface can't accidentally request, say, a
  # worktree on a review). Explicit opts still win — tests and advanced callers
  # can opt back out of any individual default.
  defp normalize_opts(opts) do
    case Keyword.get(opts, :review, false) do
      true ->
        opts
        |> Keyword.put_new(:workflow_module, CodeReview)
        |> Keyword.put_new(:provision_worktree, false)

      _ ->
        opts
    end
  end

  defp load_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, _} -> {:error, {:task_not_found, task_id}}
    end
  end

  # ---- admission (bd-asxw4e) ----------------------------------------------

  # The one dispatch-eligibility predicate, `Lifecycle.dispatchable/2`, asked
  # with the ticket's own blockers and none of the scheduler's holds: a
  # dispatch that reaches here has either been planned by the scheduler
  # (which asked with every hold) or is a person overriding it. What the
  # answer means depends on who is asking — `admit/3`.
  defp ensure_dispatchable(%Issue{} = task, opts) do
    case Lifecycle.dispatchable(task, %{blocked_by: EdgeGate.blockers_of(task)}) do
      :ok -> :ok
      {:held, hold} -> admit(task, hold, opts)
    end
  end

  # A closed ticket is reopened, never dispatched — force or not.
  defp admit(%Issue{id: id}, {:column, :closed}, _opts), do: {:error, {:task_closed, id}}

  defp admit(%Issue{id: id} = task, hold, opts) do
    cond do
      # A resume re-enters work that was admitted once (`ResumeSlot` gates its
      # slot), and a review reads a PR rather than starting work.
      Keyword.get(opts, :resume) == true or Keyword.get(opts, :review) == true ->
        :ok

      # Autopilot planned the ticket as Ready; anything else now means the
      # plan went stale (a demotion, a new blocker, a manual dispatch that got
      # there first) — bd-a1bmyx's re-check, and it is never forced.
      Keyword.get(opts, :dispatched_by) == "autopilot" ->
        {:error, {:task_not_ready, id}}

      # A re-dispatch of work already under way is not an admission.
      under_way?(hold) ->
        :ok

      Keyword.get(opts, :force) == true ->
        record_forced_dispatch(task, hold, opts)

      true ->
        {:error, {:not_dispatchable, id, hold}}
    end
  end

  defp under_way?({:column, column}), do: column in [:in_progress, :merging, :verifying]
  defp under_way?(_hold), do: false

  defp record_forced_dispatch(%Issue{id: id, workspace_id: ws_id}, hold, opts) do
    require Logger

    bypassed = Lifecycle.describe_hold(hold)
    Logger.info("Dispatch: #{id} dispatched by force although #{bypassed}")

    Arbiter.Events.broadcast(ws_id, "dispatch_forced", %{
      "task_id" => id,
      "bypassed" => bypassed,
      "column" => forced_column(hold),
      "blocked_by" => forced_blockers(hold),
      "dispatched_by" => Keyword.get(opts, :dispatched_by)
    })

    :ok
  end

  defp forced_column({:column, column}), do: to_string(column)
  defp forced_column({:blocked_by, _}), do: "blocked"

  defp forced_blockers({:blocked_by, ids}), do: ids
  defp forced_blockers(_hold), do: []

  @doc """
  Which `Arbiter.Errors` kind a `dispatch/2` / `resume/2` / `resume_session/2`
  refusal is (bd-5fc29i). One classifier for REST and MCP so the same refusal is
  the same status and `type` on both:

    * `:not_found` — the task does not exist;
    * `:conflict` — the request is fine, the task's or the fleet's state refuses
      it (closed, parked, a live session, a full account/node/slot cap, a
      provider rule);
    * `:invalid` — an argument names no usable repo;
    * `:busy` — the server is applying migrations (or cannot check); retry shortly;
    * `:internal` — anything this classifier does not know.
  """
  @spec refusal_kind(term()) :: Arbiter.Errors.kind()
  def refusal_kind(reason) when is_tuple(reason), do: reason |> elem(0) |> refusal_kind()
  def refusal_kind(:task_not_found), do: :not_found

  def refusal_kind(reason) when reason in [:pending_migrations, :migrations_check_failed],
    do: :busy

  def refusal_kind(reason)
      when reason in [:no_repo_configured, :repo_not_found, :ambiguous_repo, :repo_unknown],
      do: :invalid

  def refusal_kind(reason)
      when reason in [
             :task_closed,
             :not_dispatchable,
             :task_awaiting_review,
             :agent_session_active,
             :worker_active,
             :no_outpost,
             :no_session,
             :account_at_capacity,
             :quota_held,
             :no_node_capacity,
             :provider_constraint,
             :sandbox_backend,
             :capability_missing,
             :below_floor,
             :slot_cap_full
           ],
      do: :conflict

  def refusal_kind(_reason), do: :internal

  @doc """
  `quota_held_message/2` with the hold read from the task's workspace queue —
  what the MCP tool and the REST API render for `{:quota_held, task_id}`.
  """
  @spec quota_held_message(String.t()) :: String.t()
  def quota_held_message(task_id) do
    reason =
      with {:ok, %Issue{workspace_id: ws_id}} <- load_task(task_id),
           %{reason: reason} <- DispatchQueue.held_item(ws_id, task_id) do
        reason
      else
        _ -> nil
      end

    quota_held_message(task_id, reason)
  end

  @doc """
  The operator-facing refusal for `{:error, {:quota_held, task_id}}`
  (bd-aw325c). Two gates answer `:quota_held` — the provider/account **pause**
  gate (`reason.gate == :pause`) and the **quota** gate — and the bare
  `{:quota_held, id}` named neither. `reason` is the hold recorded in the
  workspace's `DispatchQueue` (`nil` when it could not be read); the quota
  gate's reason carries its window and numbers.
  """
  @spec quota_held_message(String.t(), term()) :: String.t()
  def quota_held_message(task_id, %{gate: :pause} = reason) do
    "#{task_id} was refused by the pause gate: #{Map.get(reason, :phrase)}. " <>
      "`force`/`force_quota` does not lift a pause; resume the provider or account " <>
      "(`arb provider resume`) and retry"
  end

  def quota_held_message(task_id, reason) do
    "#{task_id} was held by the quota gate" <>
      quota_hold_detail(reason) <>
      ". It is queued and starts when the window has headroom; to dispatch past the " <>
      "gate now pass `force_quota: true` (`force` only bypasses the Ready check)"
  end

  defp quota_hold_detail(%{window: window} = reason) when is_binary(window) do
    numbers =
      [
        reason[:utilization] && "used #{pct(reason.utilization)}",
        reason[:threshold] && "threshold #{pct(reason.threshold)}",
        reason[:status] && "status=#{reason.status}",
        reason[:mode] && "mode=#{reason.mode}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    phrase = if is_binary(reason[:phrase]), do: " (#{reason.phrase})", else: ""
    ": #{window} window" <> if(numbers == "", do: "", else: " — #{numbers}") <> phrase
  end

  defp quota_hold_detail(%{phrase: phrase}) when is_binary(phrase), do: ": #{phrase}"
  defp quota_hold_detail(_), do: " (hold details unavailable)"

  defp pct(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"
  defp pct(value), do: to_string(value)

  @doc """
  The operator-facing refusal for `{:error, {:not_dispatchable, task_id, hold}}`
  (bd-asxw4e). One source of truth for MCP, the REST API (and so the CLI) and
  the task page.
  """
  @spec refusal_message(String.t(), Lifecycle.Dispatchable.hold()) :: String.t()
  def refusal_message(task_id, hold) do
    "#{task_id} is #{Lifecycle.describe_hold(hold)}, so it is not Ready to dispatch. " <>
      next_step(hold) <>
      " To dispatch it anyway, pass force (`arb dispatch --force`, MCP `force: true`) " <>
      "— the bypass is recorded as a `dispatch_forced` event."
  end

  defp next_step({:column, :backlog}), do: "Promote it to Ready (`arb promote`) first."
  defp next_step({:blocked_by, _}), do: "It goes once its blockers merge."
  defp next_step(_hold), do: ""

  # Invariant backstop for the dispatch window (bd-cgmidt): when a live worker has
  # just been attached to `task_id`, guarantee the task is not `:closed`. A close
  # can land asynchronously between `ensure_dispatchable/2` (checked once, at the
  # front of `dispatch/2`) and `start_worker/3` — e.g. the MergeQueue's
  # direct-strategy close of an in-flight `{:worker_done}` from the run the
  # operator just stopped. Because that close's `StopWorker` after-action fires
  # when no worker is registered yet (the old one torn down, the new one not
  # started), the freshly-started worker would otherwise be orphaned on a
  # `:closed` task — the 2026-07-08 lt-c9td4r failure.
  #
  # When the task raced to `:closed` and the worker is still alive, atomically
  # reopen it (`:reopen` → `:queued`, then `:start` → `:active`) so the live
  # worker is realigned rather than orphaned — the same recovery the operator
  # had to perform by hand (`ticket_reopen`). Otherwise the task is returned
  # unchanged. Public (`@doc false`) so the invariant is unit-testable in
  # isolation.
  @doc false
  @spec realign_task_if_orphaned(String.t(), pid() | nil) ::
          {:ok, Issue.t()} | {:error, term()}
  def realign_task_if_orphaned(task_id, worker_pid) when is_binary(task_id) do
    with {:ok, task} <- load_task(task_id) do
      cond do
        task.state != :closed ->
          {:ok, task}

        not (is_pid(worker_pid) and Process.alive?(worker_pid)) ->
          # No live worker to realign — leave the legitimate close intact.
          {:ok, task}

        true ->
          require Logger

          Logger.warning(
            "Dispatch: task #{task_id} raced to :closed inside the dispatch window " <>
              "(a close landed after the not-closed guard); reopening to realign the " <>
              "live worker and avoid orphaning it on a closed task (bd-cgmidt)"
          )

          with {:ok, reopened} <- reopen_task(task) do
            transition_to_active(reopened, [])
          end
      end
    end
  end

  defp reopen_task(%Issue{} = task) do
    case Ash.update(task, %{}, action: :reopen) do
      {:ok, reopened} -> {:ok, reopened}
      {:error, e} -> {:error, {:reopen_failed, e}}
    end
  end

  # Guard against re-dispatching a ticket whose PR is open (bd-appwsh): it is
  # Merging and its Watchdog owns the PR (bd-741sid). A fresh run would start
  # on the PR's branch holding no slot, and the Watchdog could merge the PR
  # underneath it. A resume is the way back to work from Merging — it takes
  # the ticket back to In progress first (`resume_back_to_work/2`) — so only a
  # plain dispatch is refused.
  defp ensure_not_awaiting_review(%Issue{state: :merging, id: task_id}, opts) do
    if Keyword.get(opts, :resume) == true,
      do: :ok,
      else: {:error, {:task_awaiting_review, task_id}}
  end

  defp ensure_not_awaiting_review(_task, _opts), do: :ok

  # bd-2aslx6 (#1428): refuse to open a SECOND paid agent session on a task
  # whose worker is already running one.
  #
  # `start_worker/3` deliberately hands back a live worker's pid on
  # `{:already_started, pid}` — attaching to a running worker is the correct
  # behaviour for a no-agent dispatch. But `maybe_start_claude/4` then spawns a
  # whole new CLI subprocess into that same worker: same `worker_run_id`, a
  # second `usage_events` row, and (when the two dispatches named different
  # providers) two providers billed against one run. That is how bd-f7j7eh
  # ended up with an `agy` session and a `claude-haiku` session racing inside
  # run d71ea5d5; the Claude one was killed unfinished at worker teardown after
  # ~127k tokens, its `worker_runs.model` overwriting the agy run's.
  #
  # Scoped to agent-spawning dispatches: a `start_claude: false` dispatch (the
  # hand-off / park path) spends nothing and keeps today's attach semantics.
  #
  # A worker whose run has already finished is exempt: `start_worker/3`
  # evicts it (bd-d70whv) and `Worker.stop/2` kills every still-open session port
  # on the way out (`terminate/2`, bd-bmmj4w), so the re-dispatch cannot inherit a
  # live agent. Guarding it here would do the opposite of this task's intent — a
  # terminal worker that still holds a session (`complete_now/2` and
  # `fail_missing_worktree/1` mark the run terminal WITHOUT calling
  # `terminate_live_sessions/1`, unlike `fail_now/2`) would refuse re-dispatch
  # forever and leave the stray, spending session alive with nothing able to reap
  # it short of a manual `worker_stop`.
  defp ensure_no_live_agent_session(task_id, opts) do
    cond do
      not Keyword.get(opts, :start_claude, false) -> :ok
      terminal_worker?(task_id) -> :ok
      Worker.agent_session_live?(task_id) -> {:error, {:agent_session_active, task_id}}
      true -> :ok
    end
  end

  defp terminal_worker?(task_id) do
    case Worker.whereis(task_id) do
      nil -> false
      pid -> finished_worker?(pid)
    end
  end

  defp ensure_migrations_up_to_date do
    migrations_module = Application.get_env(:arbiter, :migrations_module, Arbiter.Migrations)

    case migrations_module.count_pending() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        {:error, {:pending_migrations, count}}

      {:error, reason} ->
        # Block on migration check failure (unreachable DB, invalid shape, etc).
        # This prevents the same silent failure mode as bd-44gk10, where pending
        # migrations were not detected and workers silently 503'd. Failing closed
        # on unknown is a safer default than failing open.
        {:error, {:migrations_check_failed, reason}}
    end
  end

  # Quota-aware dispatch gate (bd-7cd38f). The single choke point where the fleet
  # dispatcher consults quota state before mutating any task/worktree/preflight
  # state. Placed after ensure_not_awaiting_review and before
  # maybe_resolve_repo_for_real_work so a HOLD costs nothing and covers every
  # dispatch path at once.
  #
  #   * `:allow`       → dispatch proceeds (headroom, or fail-open).
  #   * `{:hold, r}`   → enqueue the intent in the workspace's DispatchQueue and
  #                      return `{:error, {:quota_held, task_id}}` WITHOUT
  #                      transitioning the task — it drains later in priority
  #                      order. If the queue can't be reached, fail open (allow)
  #                      rather than drop the work.
  #   * `{:overage, s}`→ dispatch proceeds past the cap (`:continue`); record the
  #                      windowed overage spend + fire one alert per threshold
  #                      crossing, then allow.
  #
  # The gate is provider-aware (bd-2mpo3f): it consults the quota snapshot of the
  # provider this dispatch will ACTUALLY run on — `AnthropicQuota` for Claude,
  # `CodexQuota` for Codex, `GoogleQuota` for Antigravity — so an
  # out-of-quota Codex or Gemini dispatch is held exactly like an out-of-quota
  # Anthropic one instead of being spawned into a rate-limited CLI.
  #
  # Fail-open guards: skipped on the drain re-dispatch (`skip_quota_gate: true`)
  # and for a task with no workspace. A nil snapshot (e.g., in test where polling
  # has not run yet) is handled uniformly inside each gate impl.
  # bd-40pzpj: under `routing.provider_selection: most_quota`, route a fresh
  # implementer dispatch to the attached account with the most quota
  # headroom (`Arbiter.Agents.ProviderRouting`) — before the quota gate, so
  # the gate reads the account the worker will actually run on. A caller's
  # `:agent_type` is an override: it still wins, and is recorded as one.
  # Resumes arrive already routed (`:routing_decision` set); a review, a
  # ReviewGate synthetic id and the `:agent_adapter` test seam are not
  # implementer dispatches. Off — the default — this is a no-op.
  defp route_implementer(%Issue{} = task, opts) do
    cond do
      Keyword.has_key?(opts, :routing_decision) -> opts
      Keyword.get(opts, :review, false) == true -> opts
      not is_nil(Keyword.get(opts, :agent_adapter)) -> opts
      Arbiter.Worker.ReviewGate.base_task_id(task.id) != task.id -> opts
      true -> maybe_route(task, load_workspace(task), opts)
    end
  rescue
    e ->
      require Logger
      Logger.warning("Dispatch: provider routing crashed for #{task.id}: #{Exception.message(e)}")
      opts
  end

  # Seams #7: the routing policy is asked once per dispatch. The choice rides
  # in `opts` (`:routing_choice`) to every step that needs it — the provider
  # router, the pause / quota gates and account admission, and the spawn — so
  # a stateful policy cannot gate on one adapter config and spawn on another.
  # `unroute/1` drops it from a held intent, so the drain decides afresh.
  defp put_routing_choice(%Issue{} = task, opts) do
    Keyword.put(opts, :routing_choice, Routing.decide(task, load_workspace(task), opts))
  end

  defp maybe_route(task, workspace, opts) do
    cond do
      grok_routed?(task, workspace, opts) ->
        # bd-dpv4vt: the operator's opt-in (`routing.grok`) is the routed
        # override; quota/scored provider routing must not swap it back out.
        opts
        |> Keyword.put(:agent_type, :grok)
        |> Keyword.put(:routed_agent_type, :grok)

      ProviderRouting.enabled?(workspace) ->
        route_by_provider(task, workspace, opts)

      true ->
        constrain_unrouted(task, workspace, opts)
    end
  end

  defp grok_routed?(task, workspace, opts) do
    Keyword.get(opts, :routing_role, :main) == :main and is_nil(caller_override(opts)) and
      GrokRouting.route?(workspace, ByDifficulty.effective_difficulty(task.difficulty),
        task: task
      ) and
      match?(%{type: :grok}, Keyword.get(opts, :routing_choice))
  end

  defp route_by_provider(task, workspace, opts) do
    role = Keyword.get(opts, :routing_role, :main)
    override = caller_override(opts)

    routing_opts = [
      override: override,
      security: routing_security(workspace, opts),
      routing_choice: Keyword.get(opts, :routing_choice),
      repo: Keyword.get(opts, :repo)
    ]

    case ProviderRouting.select(workspace, task, role, routing_opts) do
      {:ok, selection} ->
        opts
        |> Keyword.put(:agent_type, selection.agent_type)
        |> put_opt_if_present(
          :provider_fallback,
          ProviderRouting.truncate_fallback(selection.decision["fallback"])
        )
        |> put_routing_decision(selection.decision)

      {:legacy, decision} ->
        # No routed candidates: the pool pick still applies, filtered by the
        # ticket's constraint (bd-13pqcp), so dispatch and board agree.
        opts
        |> Keyword.put(:routing_decision, decision)
        |> then(&constrain_unrouted(task, workspace, &1))
        |> then(&backend_unrouted(task, workspace, &1))
    end
  end

  # The no-candidate fall-through picks from the `agent.type` pool, which knows
  # nothing about the sandbox backend. When that pick is one the backend cannot
  # run, take the first pool provider it can (and the ticket's constraint
  # allows); with none, leave it for `ensure_sandbox_backend/2` to hold.
  defp backend_unrouted(task, workspace, opts) do
    policy = routing_security(workspace, opts)

    with %SecurityPolicy{} <- policy,
         nil <- caller_override(opts),
         provider = quota_gate_provider(task, workspace, opts),
         detail when is_binary(detail) <- ProviderRouting.backend_refusal(policy, provider),
         constraint = ProviderConstraint.from(task),
         pool = ProviderConstraint.filter(constraint, Agents.agent_pool(workspace)),
         allowed = Enum.filter(pool, &is_nil(ProviderRouting.backend_refusal(policy, &1))),
         alt when not is_nil(alt) <- ProviderPool.pick(allowed) do
      opts
      |> Keyword.put(:agent_type, alt)
      |> Keyword.put(:routed_agent_type, alt)
      |> put_opt_if_present(:provider_fallback, "fell back from #{provider}: #{detail}")
    else
      _ -> opts
    end
  end

  # The sandbox backend's refusal as the last word before any state moves:
  # the provider this dispatch will run on must be runnable by it, or the
  # dispatch is held with the reason instead of burning a slot on a spawn
  # that `Sandbox.module/2` refuses. Reviews pick theirs in `ReviewerRouting`.
  defp ensure_sandbox_backend(%Issue{} = task, opts) do
    workspace = load_workspace(task)
    policy = routing_security(workspace, opts)

    with false <- Keyword.get(opts, :review, false) == true,
         %SecurityPolicy{} <- policy,
         provider = quota_gate_provider(task, workspace, opts),
         detail when is_binary(detail) <- ProviderRouting.backend_refusal(policy, provider) do
      {:error, {:sandbox_backend, provider, "held — " <> detail}}
    else
      _ -> :ok
    end
  end

  # bd-13pqcp: a workspace not routed by quota still picks its implementer from
  # the `agent.type` pool (`Routing.choose/3`'s ProviderPool.pick), which knows
  # nothing about the ticket. A constrained ticket picks from that pool
  # filtered by its constraint instead, recorded like routing's own choice
  # (`:routed_agent_type`, so a replay re-picks). A caller's explicit provider
  # stands — `ensure_provider_constraint/2` refuses it if it violates — and an
  # unconstrained ticket is untouched.
  defp constrain_unrouted(task, workspace, opts) do
    with constraint when not is_nil(constraint) <- ProviderConstraint.from(task),
         nil <- caller_override(opts),
         {:ok, provider} <- ProviderConstraint.pick(workspace, task) do
      opts
      |> Keyword.put(:agent_type, provider)
      |> Keyword.put(:routed_agent_type, provider)
    else
      _ -> opts
    end
  end

  # bd-13pqcp: the ticket's provider constraint, as the last word before any
  # state moves. The provider this dispatch will run on (routing's pick, a
  # resume's resolution or a caller's override) must be allowed; and a
  # fresh admission with no caller-named provider must have *some* eligible
  # account with capacity, or it is held — `{:provider_constraint, provider,
  # "held — provider constraint (<detail>)"}` — never run on an excluded
  # provider. Reviews (a PR read; the reviewer is not constrained) and
  # ReviewGate synthetic ids are not implementer dispatches.
  defp ensure_provider_constraint(%Issue{} = task, opts) do
    cond do
      is_nil(ProviderConstraint.from(task)) -> :ok
      Keyword.get(opts, :review, false) == true -> :ok
      Arbiter.Worker.ReviewGate.base_task_id(task.id) != task.id -> :ok
      true -> constraint_verdict(task, opts)
    end
  end

  defp constraint_verdict(task, opts) do
    workspace = load_workspace(task)

    # A fresh admission that names no provider must have an eligible account
    # (`ProviderConstraint.pick/3`, the read the board's card also uses); held
    # with that reason when it does not, rather than refused on whatever
    # provider the unrouted default would have been.
    held =
      if fresh_admission?(task, opts) and is_nil(caller_override(opts)),
        do: ProviderConstraint.pick(workspace, task)

    case held do
      {:hold, detail} ->
        {:error, {:provider_constraint, nil, ProviderConstraint.phrase(detail)}}

      _ ->
        ProviderConstraint.check(task, quota_gate_provider(task, workspace, opts))
    end
  end

  # bd-57uzkl (design §6.2, E17): the capability hard gate on the provider this
  # dispatch will actually run on. The routers already drop a candidate that
  # lacks a required capability; this is the same check on what they cannot
  # see — the `no_candidate` fall-through to the pre-routing provider, an
  # unrouted (`failover`) workspace, a caller's explicit provider and a
  # resume's resolution — or the gate would only be advisory. Off
  # (`routing.capability_gates` unset) `CapabilityMatrix.gate/3` is `nil` and
  # nothing is read or recorded. Refused rather than held: a missing capability
  # is not a quota condition, so waiting cannot fix it.
  defp ensure_capability(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :review, false) == true -> :ok
      Arbiter.Worker.ReviewGate.base_task_id(task.id) != task.id -> :ok
      true -> capability_verdict(task, opts)
    end
  end

  defp capability_verdict(task, opts) do
    workspace = load_workspace(task)
    repo = Keyword.get(opts, :repo) || task.repo

    case CapabilityMatrix.gate(workspace, capability_role(opts), repo) do
      nil ->
        :ok

      gate ->
        provider = quota_gate_provider(task, workspace, opts)
        code = CapabilityMatrix.provider_code(provider, Arbiter.Quota.provider_code("gemini"))

        case CapabilityMatrix.check(gate.rows, gate.requires, code, capability_model(opts)) do
          :ok ->
            :ok

          {:missing, _capability, detail} ->
            {:error, {:capability_missing, provider, "held — capability missing (#{detail})"}}
        end
    end
  rescue
    e ->
      require Logger
      Logger.warning("Dispatch: capability check crashed for #{task.id}: #{Exception.message(e)}")
      :ok
  end

  # bd-c675ny (design §6.4, E17): the floor hard gate on the model this
  # dispatch will actually run. The clamp already raised the tier the policy
  # chose, and the router drops a below-floor candidate; this is the same check
  # on what they cannot see — the `no_candidate` fall-through, an unrouted
  # workspace, a resume — where a *pinned* model (a legacy `agent.config.model`,
  # a rule's `"model"`) can still sit below the floor. Off (no `routing.floors`
  # config) `Floors.gate/2` is `nil` and nothing is read. An operator's explicit
  # `model:` is an override, not routing (§10), and is left alone. Refused
  # rather than held: waiting cannot raise a model's tier.
  defp ensure_floor(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :review, false) == true -> :ok
      Arbiter.Worker.ReviewGate.base_task_id(task.id) != task.id -> :ok
      explicit_model?(opts) -> :ok
      true -> floor_verdict(task, opts)
    end
  end

  defp explicit_model?(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> true
      _ -> false
    end
  end

  defp floor_verdict(task, opts) do
    workspace = load_workspace(task)

    case Floors.gate(workspace, Keyword.get(opts, :repo) || task.repo) do
      nil ->
        :ok

      gate ->
        provider = quota_gate_provider(task, workspace, opts)
        routed = Routing.decide(task, workspace, opts)
        agent_config = get_in(workspace.config || %{}, ["agent", "config"]) || %{}
        model = floor_model(routed, provider, agent_config)

        case Floors.check(gate, routed, provider, model, agent_config) do
          :ok -> :ok
          {:below, detail} -> {:error, {:below_floor, provider, "held — below floor (#{detail})"}}
        end
    end
  rescue
    e ->
      require Logger
      Logger.warning("Dispatch: floor check crashed for #{task.id}: #{Exception.message(e)}")
      :ok
  end

  # The model the spawn would run: the routed config's pin when the provider is
  # the routed adapter (a different adapter drops it, `apply_agent_type_override/2`),
  # else the tier through the provider's own map.
  defp floor_model(%{type: type, config: config}, provider, agent_config) do
    pinned = config["model"]

    if is_binary(pinned) and pinned != "" and to_string(type) == to_string(provider) do
      pinned
    else
      ModelFamily.model_for_tier(provider, config["model_tier"], agent_config)
    end
  end

  defp capability_role(opts) do
    cond do
      Keyword.get(opts, :resume) == true -> :resume
      role = Keyword.get(opts, :routing_role) -> role
      true -> :main
    end
  end

  defp capability_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> model
      _ -> get_in(Keyword.get(opts, :routing_decision) || %{}, ["model"])
    end
  end

  # The scope the spawn will run under, for the `:strict` write-confinement
  # drop — resolved exactly as `build_agent_session_opts/4` resolves it.
  defp routing_security(nil, _opts), do: nil

  defp routing_security(workspace, opts), do: dispatch_policy(workspace, opts)

  # bd-d0sgb6: a dispatch reads the security policy once. The worktree layout
  # (`git_layout/2`), node placement and the spawn all take their sandbox
  # backend from this one resolution, so a `sandbox.backend` flip mid-dispatch
  # cannot give a bwrap-shaped checkout to a podman spawn. It rides in opts
  # keyed by the repo it was scoped to; a dispatch that later settles on a
  # different repo re-resolves (the posture is per-repo scoped).
  defp put_security_policy(%Issue{} = task, opts) do
    repo = Keyword.get(opts, :repo)

    case Keyword.get(opts, :resolved_policy) do
      {^repo, %SecurityPolicy{}} ->
        opts

      _ ->
        policy = SecurityPolicy.resolve(load_workspace(task), security_override(opts), repo)
        Keyword.put(opts, :resolved_policy, {repo, policy})
    end
  end

  defp dispatch_policy(workspace, opts) do
    repo = Keyword.get(opts, :repo)

    case Keyword.get(opts, :resolved_policy) do
      {^repo, %SecurityPolicy{} = policy} -> policy
      _ -> SecurityPolicy.resolve(workspace, security_override(opts), repo)
    end
  end

  # A held dispatch is replayed verbatim on drain; strip routing's own choice
  # so the replay routes afresh instead of reading it as a caller override.
  defp unroute(opts) do
    routed = Keyword.get(opts, :routed_agent_type)

    opts =
      Keyword.drop(opts, [
        :routing_decision,
        :routing_choice,
        :routed_agent_type,
        :resolved_policy
      ])

    if routed && Keyword.get(opts, :agent_type) == routed,
      do: Keyword.drop(opts, [:agent_type, :provider_fallback]),
      else: opts
  end

  # bd-5ef587: a paused provider (or the paused account this dispatch would be
  # metered under) is held with "held — <provider> paused: <reason>", as a
  # quota hold is; the drain releases it once routing can pick another
  # candidate or the pause is lifted. Routing has already dropped paused
  # accounts, so this only bites when nothing else can take the work, or on the
  # unrouted (legacy) path. Fails open only when the pause cannot be looked up:
  # once found, a hold that cannot be recorded refuses the dispatch.
  defp maybe_pause_gate(%Issue{workspace_id: ws_id} = task, opts) when is_binary(ws_id) do
    # Deliberately NOT bypassed by `skip_quota_gate`: the drain replay and MCP
    # `force_quota` override a quota hold, never an operator's pause.
    case lookup_pause(task, ws_id, opts) do
      nil ->
        :ok

      {provider, pause} ->
        phrase = "held — #{provider} paused: #{pause.reason || "no reason given"}"

        case safe_pause_hold(ws_id, task.id, opts, phrase, provider) do
          :ok -> {:error, {:quota_held, task.id}}
          _ -> {:error, {:provider_paused, provider, phrase}}
        end
    end
  end

  defp maybe_pause_gate(_task, _opts), do: :ok

  defp lookup_pause(task, ws_id, opts) do
    workspace = load_workspace(task)
    provider = quota_gate_provider(task, workspace, opts)

    case pause_for_dispatch(ws_id, provider, opts) do
      nil -> nil
      pause -> {provider, pause}
    end
  rescue
    _ -> nil
  end

  defp safe_pause_hold(ws_id, task_id, opts, phrase, provider) do
    DispatchQueue.hold(ws_id, task_id, unroute(opts), %{gate: :pause, phrase: phrase}, provider)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp pause_for_dispatch(ws_id, provider, opts) do
    Arbiter.Providers.Pause.for_provider(provider) ||
      if is_nil(Keyword.get(opts, :routing_decision)) do
        case safe_gate_account(ws_id, provider) do
          %Arbiter.Accounts.ProviderAccount{} = account ->
            Arbiter.Providers.Pause.for_account(account)

          _ ->
            nil
        end
      end
  end

  defp maybe_quota_gate(%Issue{workspace_id: ws_id} = task, opts) do
    cond do
      Keyword.get(opts, :skip_quota_gate, false) == true ->
        require Logger

        Logger.warning(
          "quota gate bypassed for task=#{task.id} — quota_gate was skipped via explicit override"
        )

        # Record the quota gate bypass in the audit log
        record_quota_gate_bypass(task, opts)

        :ok

      not is_binary(ws_id) ->
        :ok

      true ->
        run_quota_gate(task, opts)
    end
  end

  defp record_quota_gate_bypass(%Issue{id: task_id, workspace_id: ws_id} = task, opts) do
    workspace = load_workspace(task)
    provider = quota_gate_provider(task, workspace, opts)
    quota = safe_quota_latest(safe_gate_account(ws_id, provider), provider)

    payload = %{
      "task_id" => task_id,
      "actor" => Keyword.get(opts, :quota_bypass_actor),
      "reason" => Keyword.get(opts, :quota_bypass_reason),
      "quota_state" => %{
        "provider" => provider,
        "quota" => format_quota_state(quota)
      }
    }

    Arbiter.Events.broadcast(ws_id, "quota_gate_bypass", payload)
  rescue
    e ->
      require Logger

      Logger.error(
        "Failed to record quota gate bypass audit event for task #{task_id}: #{Exception.message(e)}"
      )
  end

  defp format_quota_state(nil), do: nil

  defp format_quota_state(quota) do
    %{
      "available_spending_usd" => quota.available_spending_usd,
      "snapshot_at" => DateTime.to_iso8601(quota.snapshot_at)
    }
  rescue
    _ -> nil
  end

  defp run_quota_gate(%Issue{workspace_id: ws_id} = task, opts) do
    workspace = load_workspace(task)
    provider = quota_gate_provider(task, workspace, opts)

    apply_quota_gate(task, workspace, provider, ws_id, opts)
  rescue
    e ->
      # A bug in the gate must never wedge dispatch — fail open.
      require Logger
      Logger.warning("Dispatch: quota gate crashed for #{task.id}: #{Exception.message(e)}")
      :ok
  end

  # Antigravity's dispatch gate reads one of four sub-buckets keyed by model
  # family (bd-7qj58o AC4) — "Claude and GPT models" vs "Gemini Models" — but
  # the gate runs before `start_agent/4`'s own model tiering, so it doesn't
  # otherwise know the model. Best-effort hint: an explicit `opts[:model]`
  # override wins as-is; otherwise resolve the same routing choice the real
  # dispatch will use and mirror `Gemini.resolve_model/2`'s own precedence —
  # an explicit `config["model"]` pin wins over `model_tier` (routing
  # policies such as `ByPriority`/`ByBudget` routinely set `"model"`
  # directly). An unresolvable hint leaves `opts` untouched — the gate then
  # falls back to its conservative worst-of-both-groups reading rather than
  # holding on the wrong bucket.
  defp maybe_add_gemini_model_hint(:gemini, task, workspace, opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        opts

      _ ->
        case gemini_model_tier_hint(task, workspace, opts) do
          model when is_binary(model) and model != "" -> Keyword.put(opts, :model, model)
          _ -> opts
        end
    end
  end

  defp maybe_add_gemini_model_hint(_provider, _task, _workspace, opts), do: opts

  defp gemini_model_tier_hint(task, workspace, opts) do
    config = Routing.decide(task, workspace, opts).config

    case config["model"] do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        overrides =
          ((workspace && workspace.config["agent"]["config"]) || %{})
          |> Arbiter.Agents.ProviderConfig.apply_overrides("gemini")
          |> Map.get("tier_models", %{})

        base = GeminiConfig.default_tier_models(:agy)
        Map.get(overrides, config["model_tier"]) || Map.get(base, config["model_tier"])
    end
  rescue
    _ -> nil
  end

  # Which provider this dispatch will run on. Mirrors `start_agent/4`'s
  # resolution order so the gate reads the same provider the worker is spawned
  # with: the `:agent_adapter` test seam, then an explicit `:agent_type`
  # override, then the workspace's routing policy. Falls back to :claude — the
  # historical (Anthropic-only) behaviour — if resolution raises.
  # bd-8suxac: a fresh admission must find headroom on the provider account it
  # will run on — the routed account when routing picked one, else the one the
  # workspace is metered under for the resolved provider. Asked by every
  # caller, Autopilot included (its plan can be stale by now); `force_slot`
  # goes over the cap, recorded. See `Arbiter.Accounts.Admission`.
  defp ensure_account_capacity(%Issue{} = task, opts) do
    if fresh_admission?(task, opts) do
      provider = quota_gate_provider(task, load_workspace(task), opts)

      case Admission.admit(task, provider, admission_opts(opts)) do
        {:ok, _admitted} -> :ok
        {:error, _} = refused -> refused
      end
    else
      :ok
    end
  end

  # RW8 (bd-3igo6h): the second admission gate, after the provider account's.
  # Where does this run go — a node, or the primary — and has that place room?
  # `{:error, {:no_node_capacity, info}}` holds the card (never fails it): a
  # `remote_only` workspace with no node free, or the primary's own cap
  # (`Arbiter.Nodes.LocalCapacity`) at 0 / full for a run that has to stay local.
  # A placed node rides in `opts[:node]` for `maybe_provision_worktree/2`
  # (RW9). The slot reserved here is released when the dispatch returns, by
  # which point the worker is registered and counted in its place.
  #
  # With `worker.placement` unset (`local_only`) and no override of the
  # primary's cap there is nothing to decide, and nothing is read: dispatch is
  # exactly what it was.
  defp ensure_node_capacity(%Issue{} = task, opts) do
    workspace = load_workspace(task)

    if Placement.mode(workspace) == :local_only and not LocalCapacity.cap().enforced? do
      {:ok, opts}
    else
      request = node_request(task, workspace, opts)

      case LocalCapacity.gate(request, node_gate_opts(opts)) do
        {:ok, {:node, node}} -> {:ok, Keyword.put(opts, :node, node)}
        {:ok, :local} -> {:ok, opts}
        {:error, _} = held -> held
      end
    end
  rescue
    e ->
      Logger.warning("Dispatch: node placement crashed for #{task.id}: #{Exception.message(e)}")
      {:ok, opts}
  end

  defp node_request(%Issue{} = task, workspace, opts) do
    %{
      task_id: task.id,
      workspace_id: task.workspace_id,
      kind: node_kind(task, opts),
      provider: quota_gate_provider(task, workspace, opts),
      layout: git_layout(task, opts),
      no_pr?: no_private_clone?(task, opts),
      mode: Placement.mode(workspace)
    }
  end

  # The spawn kind the primary's cap sees (`LocalCapacity.kinds/0`).
  defp node_kind(%Issue{id: id, state: state}, opts) do
    cond do
      Keyword.get(opts, :resume) == true -> :resume
      Keyword.get(opts, :review) == true -> :review
      Arbiter.Worker.ReviewGate.base_task_id(id) != id -> :reviewer
      state == :active -> :redispatch
      true -> :implementer
    end
  end

  defp no_private_clone?(%Issue{} = task, opts) do
    Keyword.get(opts, :provision_worktree, true) == false or
      (Issue.no_pr_type?(task.issue_type) and Keyword.get(opts, :provision_worktree) != true)
  end

  defp node_gate_opts(opts) do
    [
      force: Keyword.get(opts, :force_slot) == true,
      actor: Keyword.get(opts, :slot_override_actor) || Keyword.get(opts, :dispatched_by)
    ]
  end

  # Not admissions: a ticket already In progress (a re-dispatch or resume of
  # work holding its slot — `ResumeSlot`'s rule), a resume, a review, and a
  # ReviewGate synthetic id.
  defp fresh_admission?(%Issue{id: id, state: state}, opts) do
    state != :active and
      Keyword.get(opts, :resume) != true and
      Keyword.get(opts, :review) != true and
      Arbiter.Worker.ReviewGate.base_task_id(id) == id
  end

  defp admission_opts(opts) do
    admission = [
      force: Keyword.get(opts, :force_slot) == true,
      actor: Keyword.get(opts, :slot_override_actor) || Keyword.get(opts, :dispatched_by)
    ]

    case Keyword.get(opts, :routing_decision) do
      %{"account_id" => account_id} when is_binary(account_id) ->
        Keyword.put(admission, :account, Arbiter.Accounts.Resolver.get(account_id))

      _ ->
        admission
    end
  end

  defp quota_gate_provider(%Issue{} = task, workspace, opts) do
    case Keyword.get(opts, :agent_adapter) do
      mod when is_atom(mod) and not is_nil(mod) ->
        String.to_existing_atom(mod.provider())

      _ ->
        case Keyword.get(opts, :agent_type) do
          type when is_atom(type) and not is_nil(type) -> type
          _ -> Routing.decide(task, workspace, opts).type
        end
    end
  rescue
    _ -> :claude
  end

  # The provider account this dispatch is metered under (P7,
  # `docs/provider-account-design.md` §4.2 / §5 rows 4, 9). It is both the key
  # the snapshot is read by and the account half of the gate's threshold
  # policy, so it is resolved once. `nil` when the workspace has no link —
  # the gate then reads no snapshot and fails open, exactly as it did before.
  defp safe_gate_account(ws_id, provider) do
    Arbiter.Accounts.Resolver.get(Arbiter.Quota.account_id(ws_id, provider))
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp apply_quota_gate(%Issue{} = task, workspace, provider, ws_id, opts) do
    gate = Arbiter.Quota.gate_for_workspace(workspace)
    account = safe_gate_account(ws_id, provider)
    quota = safe_quota_latest(account, provider)
    # The model hint (bd-7qj58o AC4) is scoped to this `gate.check/4` call
    # only — `opts` itself (used below for `DispatchQueue.hold/5`, replayed
    # verbatim on drain) must stay exactly what the caller passed, or a
    # best-effort Antigravity bucket guess would silently override the real
    # dispatch's model resolution later.
    gate_opts =
      provider
      |> maybe_add_gemini_model_hint(task, workspace, opts)
      |> Keyword.put(:account, account)

    case gate.check(task, quota, workspace, gate_opts) do
      :allow ->
        # Not past this provider's plan cap: its overage alert's condition has
        # cleared (bd-7gt8rm). One indexed read when none is active. No
        # snapshot is not evidence either way, so it leaves the alert alone.
        if quota, do: CoordinatorNotifier.overage_cleared(ws_id, provider)
        record_pace_exempt(task, ws_id, provider, account, quota, workspace, gate_opts)
        :ok

      {:hold, reason} ->
        case DispatchQueue.hold(ws_id, task.id, unroute(opts), reason, provider) do
          :ok ->
            {:error, {:quota_held, task.id}}

          {:error, hold_err} ->
            # The queue is unreachable — fail open so the work is not dropped.
            require Logger

            Logger.warning(
              "Dispatch: quota gate held #{task.id} but enqueue failed " <>
                "(#{inspect(hold_err)}); allowing dispatch to avoid dropping work"
            )

            :ok
        end

      {:overage, spend_usd} ->
        _ = DispatchQueue.record_overage(ws_id, task, spend_usd, provider)
        :ok
    end
  end

  # The P0 pace exemption (bd-6bxv7h, design §4.2): a dispatch the gate let
  # through only because its own priority is exempt is audited — the same
  # `pace_exempt` the routing decision carries, as a `quota_pace_exempt` event
  # next to `quota_gate_bypass`. Best-effort: the audit must never fail a
  # dispatch the gate allowed.
  defp record_pace_exempt(
         %Issue{priority: priority} = task,
         ws_id,
         provider,
         account,
         quota,
         workspace,
         gate_opts
       )
       when is_integer(priority) do
    case Arbiter.Quota.Gate.pace_exemption(
           quota,
           {account, workspace},
           Keyword.put(gate_opts, :priority, priority)
         ) do
      nil ->
        :ok

      exemption ->
        Arbiter.Events.broadcast(ws_id, "quota_pace_exempt", %{
          "task_id" => task.id,
          "priority" => priority,
          "provider" => to_string(provider),
          "account" => account && account.slug,
          "pace_exempt" => %{
            "window" => exemption.window,
            "used" => exemption.used,
            "paced" => exemption.paced,
            "cap" => exemption.cap
          }
        })
    end
  rescue
    e ->
      require Logger
      Logger.warning("Dispatch: pace-exempt audit failed for #{task.id}: #{Exception.message(e)}")
      :ok
  end

  defp record_pace_exempt(_task, _ws_id, _provider, _account, _quota, _workspace, _gate_opts),
    do: :ok

  # bd-cwq8b0: grok has no provider account (the free tier's cap belongs to the
  # one xAI account), so its ledger snapshot is served whatever `account` is.
  defp safe_quota_latest(_account, :grok), do: safe_grok_snapshot()

  defp safe_quota_latest(nil, _provider), do: nil

  defp safe_quota_latest(%{id: account_id}, provider) do
    Arbiter.Quota.latest_for_provider(account_id, provider)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_grok_snapshot do
    Arbiter.Quota.latest_for_provider(nil, :grok)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # bd-842qio: the `start` transition (queued → active) — see
  # `Issue.start_work/2`, which also covers a manual dispatch from Backlog and
  # leaves a ticket already at work alone.
  defp transition_to_active(%Issue{} = task, opts) do
    # bd-6xaaam: stamp review_only: true so SyncTracker/SyncFields skip
    # write-back for the start transition and any later field update.
    attrs = if Keyword.get(opts, :review, false), do: %{review_only: true}, else: %{}

    case Issue.start_work(task, attrs) do
      {:ok, updated} -> resume_back_to_work(updated, opts)
      {:error, e} -> {:error, {:transition_failed, e}}
    end
  end

  # bd-asxw4e: a resume of a Merging ticket (a revise round on its open PR) was
  # admitted into a slot by `ResumeSlot`, and a slot is a ticket In progress —
  # so the ticket goes back to work, or the round would run holding nothing
  # and the scheduler would fill its slot behind it.
  #
  # bd-741sid: the PR leaves the merge path first. Its Watchdog belongs to the
  # ticket, so nothing else stops it. Left running, it would merge the very
  # head this round was resumed to revise, and once it was gone the sweeper
  # would re-arm the pending merge it stamped. The round's own approved PR open
  # starts a fresh Watchdog on the new head. The Watchdog is stopped before the
  # ticket moves, so a merge its last poll landed is seen: a ticket that
  # finished meanwhile is not resumed.
  defp resume_back_to_work(%Issue{state: :merging, id: id} = task, opts) do
    if Keyword.get(opts, :resume) == true do
      :ok = Watchdog.stop(id)
      _ = PendingMerge.clear(id)
      :ok = Issue.back_to_work(id)

      with {:ok, task} <- load_task(id) do
        case task.state do
          :active -> {:ok, task}
          state -> {:error, {:transition_failed, {:not_back_to_work, state}}}
        end
      end
    else
      {:ok, task}
    end
  end

  defp resume_back_to_work(task, _opts), do: {:ok, task}

  defp start_worker(%Issue{id: id, workspace_id: ws_id} = task, worktree_path, opts) do
    repo = Keyword.get(opts, :repo) || "unknown"
    meta = build_worker_meta(task, worktree_path, opts)

    case Worker.start(task_id: id, repo: repo, workspace_id: ws_id, meta: meta) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # A worker for this task is already registered. If its run finished
        # — the re-dispatch-a-failed-run scenario (bd-d70whv) — stop the stale
        # process so the registry slot is freed, then start a fresh one.
        # Without this, the new Claude session runs inside a finished worker
        # and the "arb done" marker is silently dropped by the FSM guard that
        # excludes `:finished`. A live worker is left as-is.
        case safe_worker_run(pid) do
          %{state: :finished} ->
            _ = Worker.stop(pid, :normal)

            case Worker.start(task_id: id, repo: repo, workspace_id: ws_id, meta: meta) do
              {:ok, new_pid} -> {:ok, new_pid}
              {:error, reason} -> {:error, {:worker_start_failed, reason}}
            end

          _ ->
            {:ok, pid}
        end

      {:error, reason} ->
        {:error, {:worker_start_failed, reason}}
    end
  end

  # Seed the worker's :meta with everything its completion path needs to
  # integrate the branch when the worker finishes (see the arb-done handler in
  # `Arbiter.Worker`).
  #
  # When a worktree was provisioned we know the per-task branch and the repo
  # path (the local checkout where the target branch lives — the `repo_path`
  # the `Direct` merger runs `git merge --no-ff` inside). With no worktree
  # (repo unconfigured, or `provision_worktree: false`) there is nothing to
  # merge, so `:branch` stays absent and completion is a plain task close.
  defp build_worker_meta(%Issue{} = task, worktree_path, opts) do
    base =
      case Keyword.get(opts, :review, false) do
        true -> %{worktree_path: worktree_path, review_only: true}
        _ -> %{worktree_path: worktree_path}
      end

    # bd-5lc99r: stamp the directive's issue_type so the worker's completion path
    # can route a `task` type through the notes gate (no commit/review gate, no
    # PR) instead of the commit/review/merge path.
    base = Map.put(base, :issue_type, task.issue_type)

    # bd-dzz6ly: capture difficulty HERE, before the worker ever starts — not
    # read later off `issues.difficulty`, which can be edited after dispatch
    # (bd-7rspia was corrected D1 -> D2) and would then silently relabel this
    # run's provenance to the corrected estimate instead of the one it ran under.
    base = Map.put(base, :difficulty_at_dispatch, task.difficulty)

    base =
      base
      |> put_if_present(
        :provider,
        Keyword.get(opts, :agent_type) && to_string(Keyword.get(opts, :agent_type))
      )
      |> put_if_present(:provider_fallback, Keyword.get(opts, :provider_fallback))
      # bd-40pzpj: the routing decision, account and family the run records.
      |> Map.merge(ProviderRouting.run_meta(Keyword.get(opts, :routing_decision)))
      # bd-9fgg04: who asked for this dispatch (the board autopilot stamps
      # "autopilot"), so a drain report can name a board dispatch as one.
      |> put_if_present(:dispatched_by, Keyword.get(opts, :dispatched_by))

    base = maybe_put_resume_meta(base, opts)

    case worktree_path && resolve_repo_path(task, Keyword.get(opts, :repo)) do
      repo_path when is_binary(repo_path) ->
        Map.merge(base, %{
          branch: BranchNamer.derive(task),
          repo_path: repo_path,
          target_branch: resolve_target_branch(task, opts),
          merge_title: merge_title(task)
        })

      _ ->
        base
    end
  end

  # bd-auma3z: stamp the resume markers into the worker's :meta so (1) the
  # dashboard/CLI can tell a resumed run from a fresh dispatch, (2) `record_run_started`
  # links the new run to the prior one via `resumed_from_run_id`, and (3) the
  # completion path can reuse an already-open PR (`existing_pr_ref`) instead of
  # opening a duplicate. No-op on a normal fresh dispatch.
  defp maybe_put_resume_meta(base, opts) do
    case Keyword.get(opts, :resume, false) do
      true ->
        base
        |> Map.put(:resume, true)
        |> put_if_present(:resumed_from_run_id, Keyword.get(opts, :resumed_from_run_id))
        |> put_if_present(:existing_pr_ref, Keyword.get(opts, :existing_pr_ref))
        # bd-1z7624: session-level resume threads the prior session id so the
        # worker's first spawn opens with `claude --print --resume <id>`. nil on
        # a fresh dispatch or the bd-auma3z fresh-agent resume.
        |> put_if_present(:resume_session_id, Keyword.get(opts, :resume_session_id))
        # bd-8eheb6: how many times the Watchdog has auto-resumed this task out
        # of an `{:awaiting_review_timeout, _}`. Each auto-resume mints a fresh
        # worker AND a fresh Watchdog, so the counter has to ride the worker's
        # meta to survive the handoff — otherwise the next Watchdog starts from
        # 0 and the retry cap never binds. Absent on every other resume path.
        |> put_if_present(
          :awaiting_review_resume_attempts,
          Keyword.get(opts, :awaiting_review_resume_attempts)
        )
        # bd-a9zb7w: the same trick for the ReviewGate fix-round budget. A
        # `request_changes` verdict auto-dispatches an implementer fix round, and
        # each round mints a fresh worker — so both the attempt counter and the
        # digest of the findings that round was dispatched against have to ride
        # the worker's meta, or neither the cap nor the convergence check can
        # bind. Absent on every other resume path.
        |> put_if_present(
          :review_gate_fix_round_attempts,
          Keyword.get(opts, :review_gate_fix_round_attempts)
        )
        |> put_if_present(
          :review_gate_findings_digest,
          Keyword.get(opts, :review_gate_findings_digest)
        )
        # bd-92mx1m: this resume went over a full concurrency cap by an
        # explicit `force` (also written to the audit log as a
        # `slot_cap_override` event by `ResumeSlot`).
        |> put_if_present(:slot_cap_override, Keyword.get(opts, :slot_cap_override))

      _ ->
        base
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp merge_title(%Issue{id: id, title: title}) when is_binary(title) and title != "",
    do: "Merge #{id}: #{title}"

  defp merge_title(%Issue{id: id}), do: "Merge #{id}"

  defp attach_and_start_machine(%Issue{id: id}, worktree_path, opts) do
    workflow = Keyword.get(opts, :workflow_module, Work)
    vars = %{task_id: id, worktree_path: worktree_path, repo: Keyword.get(opts, :repo)}

    with {:ok, machine_id} <- Machine.attach(workflow, id, vars),
         {:ok, pid} <- Machine.start(machine_id) do
      {:ok, machine_id, pid}
    else
      err -> {:error, {:machine_start_failed, err}}
    end
  end

  # Provision a fresh git worktree on a per-task branch, cut from the upstream
  # tip of the resolved target branch (`origin/<target>`).
  #
  # The arbiter — not the worker — fetches from origin before creating the
  # worktree. The worker then starts on a clean, current branch with no git
  # plumbing in its context.
  #
  # Behaviour:
  #   - `provision_worktree: false` in opts → skip, return `{:ok, nil}`.
  #   - repo has no mapping in workspace config or Application env → skip,
  #     return `{:ok, nil}` (the default no-op stance).
  #   - Otherwise, derive a branch name and call `Worktree.create/3`, which
  #     `git fetch origin <target>` + `git worktree add -b <branch>
  #     origin/<target>`. A fetch or ref-resolve failure aborts with a clear
  #     error rather than silently falling back to a stale local base.
  #
  # ## Repo path lookup order
  #
  #   1. Task's workspace config (`workspace.config["repo_paths"][repo]`)
  #      — per-workspace, runtime-settable, owns the source of truth.
  #   2. Application env (`:arbiter, :repo_paths`) — global fallback,
  #      configured in `config/dev.exs` for dev convenience.
  #
  # First hit wins. This lets workspaces override the global default
  # without changing application config.
  #
  # `resume/2` and `resume_session/2` both always set `:resume` to `true`
  # before delegating to `dispatch/2` (`resume_session_id` is only set on top
  # of that, never on its own) — so `:resume` alone is a reliable signal that
  # this dispatch is re-attaching to a preserved worktree rather than cutting
  # a fresh one.
  defp resuming?(opts), do: Keyword.get(opts, :resume) == true

  # Pre-existing complexity 15 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp maybe_provision_worktree(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :provision_worktree, true) == false ->
        {:ok, nil}

      # bd-5lc99r / bd-9s9dqz: `task` (operational action) and `research`
      # (findings in `notes`) are the no-PR types — no code change, so no branch
      # to merge. Skip worktree provisioning by default. An explicit
      # `provision_worktree: true` still forces one for the rare ticket that
      # genuinely needs a repo checkout to inspect.
      Issue.no_pr_type?(task.issue_type) and Keyword.get(opts, :provision_worktree) != true ->
        {:ok, nil}

      true ->
        repo = Keyword.get(opts, :repo)

        case resolve_repo_path(task, repo) do
          nil ->
            {:ok, nil}

          repo_path when is_binary(repo_path) ->
            branch = BranchNamer.derive(task)
            target_branch = resolve_target_branch(task, opts)
            layout = git_layout(task, opts)
            # RW11: the home clone of a run placed on a node is thin (no deps seeding):
            # the node's shadow clone is what the container works in.
            seed_paths = if Keyword.get(opts, :node), do: false, else: seed_paths(task, repo)

            # bd-8ssxap: a redispatch can find its OLD per-task branch still on
            # disk with commits that are already merged upstream (a prior round
            # verified-failed post-merge, or was simply reopened after merge).
            # `create/3` alone would reuse that branch as-is — the worker gets
            # nothing new to add and can submit an empty PR. Reset it to current
            # upstream first; a branch with genuine unmerged work is left alone.
            #
            # `force: true` when the task's last transition was a failed
            # verification: this repo's default GitHub merge method is squash
            # (`lib/arbiter/mergers/github/config.ex`), which produces a brand
            # new commit on the base branch that the old per-task branch tip is
            # NEVER an ancestor of — plain merge-base ancestry (still used for
            # every other redispatch) would never catch that case, which is
            # exactly the bd-96mn8i incident this exists to prevent.
            #
            # A resume (`opts[:resume]`) skips this reset entirely rather than
            # passing `force: true` through: `Dispatch.resume/2` exists to
            # preserve a stopped worker's committed *and* uncommitted worktree
            # state, and this branch's whole point on a resume is continuity,
            # not a clean slate.
            reset_result =
              if resuming?(opts) do
                {:ok, :kept}
              else
                Worktree.reset_if_merged(repo_path, branch, target_branch,
                  force: task.verification_outcome == :failed
                )
              end

            case reset_result do
              {:ok, _} ->
                case Worktree.create(repo_path, branch, target_branch,
                       layout: layout,
                       seed_paths: seed_paths
                     ) do
                  {:ok, path} ->
                    {:ok, path}

                  {:error, {:git_failed, msg}} when is_binary(msg) ->
                    cond do
                      String.contains?(msg, "already exists") ->
                        # Pre-existing nesting 5 — baselined when bd-4x2yhq first
                        # wired Credo up. Thresholds stay at the tool's own default so new
                        # code is held to it; see the note in .credo.exs.
                        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
                        case Worktree.attach(repo_path, branch,
                               layout: layout,
                               base: target_branch,
                               seed_paths: seed_paths
                             ) do
                          {:ok, path} -> {:ok, path}
                          {:error, reason} -> {:error, {:worktree_failed, reason}}
                        end

                      String.contains?(msg, "different branch") ->
                        recover_from_detached_worktree(
                          repo_path,
                          branch,
                          target_branch,
                          msg,
                          layout,
                          seed_paths
                        )

                      true ->
                        {:error, {:worktree_failed, {:git_failed, msg}}}
                    end

                  {:error, reason} ->
                    {:error, {:worktree_failed, reason}}
                end

              {:error, reason} ->
                {:error, {:worktree_failed, reason}}
            end
        end
    end
  end

  # A branch dispatch found a *detached* worktree sitting at the branch leaf.
  # Since bd-9r1tta an inspect checkout uses its own leaf, so this only happens
  # for a task whose inspect tree predates that split — but the failure it caused
  # was permanent (`create/3` refuses, the `already exists` → `attach/2` recovery
  # doesn't match "different branch", and nothing else reclaims the directory), so
  # recover instead of stranding the dispatch. Safe by inspection: a detached tree
  # has no branch and therefore no commits only reachable from it.
  defp recover_from_detached_worktree(repo_path, branch, target_branch, msg, layout, seed_paths) do
    require Logger

    path = Worktree.worktree_path(branch)

    case Worktree.detached?(path) do
      {:ok, true} ->
        Logger.info(
          "Dispatch: reclaiming detached inspect worktree at #{path} so branch " <>
            "#{branch} can be provisioned there"
        )

        _ = Worktree.cleanup(path)

        case Worktree.create(repo_path, branch, target_branch,
               layout: layout,
               seed_paths: seed_paths
             ) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, {:worktree_failed, reason}}
        end

      _ ->
        {:error, {:worktree_failed, {:git_failed, msg}}}
    end
  end

  # bd-2jerqw: `worker.repos.<repo>.seed_paths` for this task's workspace, or
  # nil for the built-in seed set (`SeedPaths.resolve/2`).
  defp seed_paths(%Issue{} = task, repo), do: SeedPaths.resolve(load_workspace(task), repo)

  # bd-4wy1w1 (P5): the checkout's git layout follows the sandbox the spawn will
  # run in, resolved from the same policy layers `build_agent_session_opts/4`
  # resolves: a container (`sandbox.backend: podman`) gets a private clone.
  defp git_layout(%Issue{} = task, opts),
    do: task |> load_workspace() |> dispatch_policy(opts) |> GitLayout.for_policy()

  defp resolve_repo_path(_task, nil), do: nil

  defp resolve_repo_path(%Issue{workspace_id: ws_id}, repo) when is_binary(repo) do
    workspace_repo_path(ws_id, repo) || application_repo_path(repo) ||
      slug_repo_path(ws_id, repo)
  end

  # Reverse resolution (bd-49ajyt): PRPatrol/ReviewPatrol dispatch a follow-up
  # with the PR's GitHub `owner/repo` slug as the `:repo` opt, but a multi-repo
  # workspace's `repo_paths` map is keyed by *repo name* (e.g.
  # "client"), not by slug — so the direct + normalized key lookups above miss
  # (a repo name never normalizes to an `owner/repo` slug) and dispatch used to
  # fail `{:repo_not_found}`, spinning PRPatrol in a 1/min escalation loop.
  #
  # When the requested repo looks like an `owner/repo` slug that no key
  # matched, resolve it the same way `PRPatrolSupervisor` derives its patrol
  # repos: read each registered repo's `origin` remote and match its derived
  # slug. This only runs on the miss path (both direct lookups returned nil)
  # and only for slug-shaped repos, so a normal repo-name dispatch never pays
  # the git cost. Covers client↔apex-client, server↔apex_server, and the
  # other acme repos where repo name ≠ slug.
  defp slug_repo_path(_ws_id, repo) when not is_binary(repo), do: nil

  defp slug_repo_path(ws_id, repo) do
    if String.contains?(repo, "/") do
      target = RepoConfig.normalize_slug(repo)

      ws_id
      |> candidate_repo_paths()
      |> Enum.find_value(fn path ->
        case RepoResolver.from_remote(path) do
          {:ok, {owner, name}} ->
            # Pre-existing nesting 4 — baselined when bd-4x2yhq first
            # wired Credo up. Thresholds stay at the tool's own default so new
            # code is held to it; see the note in .credo.exs.
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            if RepoConfig.normalize_slug("#{owner}/#{name}") == target, do: path

          _ ->
            nil
        end
      end)
    end
  end

  # All locally-checked-out repo paths registered for this workspace (config
  # `repo_paths`) plus the global Application `:repo_paths`, deduplicated.
  # The values are paths to git checkouts whose `origin` remote
  # `slug_repo_path/2` can resolve.
  defp candidate_repo_paths(ws_id) do
    ws_paths =
      case load_workspace_config(ws_id) do
        %{} = config ->
          config_repo_paths(get_in(config, ["repo_paths"]))

        _ ->
          []
      end

    app_paths =
      :arbiter
      |> Application.get_env(:repo_paths, %{})
      |> config_repo_paths()

    (ws_paths ++ app_paths) |> Enum.uniq()
  end

  defp config_repo_paths(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.map(&repo_path_from_config/1)
    |> Enum.reject(&is_nil/1)
  end

  defp config_repo_paths(_), do: []

  # Resolve the integration branch — the branch the worktree is cut from and
  # the one the completed branch merges back into. Delegates to the shared
  # `Arbiter.Worker.TargetBranch` resolver so the worktree base computed here
  # and the PR base computed by the `MergeQueue` can never diverge (bd-b6rzoc).
  defp resolve_target_branch(%Issue{} = task, opts) do
    TargetBranch.resolve(task,
      base_branch: Keyword.get(opts, :base_branch),
      repo: Keyword.get(opts, :repo)
    )
  end

  defp workspace_repo_path(nil, _repo), do: nil

  defp workspace_repo_path(ws_id, repo) do
    case load_workspace_config(ws_id) do
      %{} = config ->
        find_repo_path(get_in(config, ["repo_paths"]), repo)

      _ ->
        nil
    end
  end

  defp repo_path_from_config(raw), do: RepoConfig.repo_path_from_config(raw)

  defp application_repo_path(repo) do
    find_repo_path(Application.get_env(:arbiter, :repo_paths, %{}), repo)
  end

  # Exact key match first (the common case). When that misses, fall back to a
  # normalized match (case-insensitive, underscore/hyphen-insensitive) — a
  # forge slug derived from a repo's actual GitHub name (e.g.
  # "owner/apex_server") must still resolve against a `repo_paths` entry
  # registered under a differently-separated key (e.g. "owner/apex-server").
  # See bd-6rioa4.
  defp find_repo_path(map, repo), do: RepoConfig.find_path(map, repo)

  defp load_workspace_config(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{config: %{} = config}} -> config
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # An issue that declares its own repo (bd-2jum8j) supplies the default for
  # EVERY dispatch of it, not just `start_claude: true` ones — a dry dispatch
  # of an assigned task should provision a worktree from that repo rather than
  # park with none. A caller's explicit `repo:` opt is left untouched.
  defp apply_issue_repo_default(%Issue{repo: repo}, opts)
       when is_binary(repo) and repo != "" do
    case Keyword.get(opts, :repo) do
      given when is_binary(given) and given != "" -> opts
      _ -> Keyword.put(opts, :repo, repo)
    end
  end

  defp apply_issue_repo_default(_task, opts), do: opts

  # Real-work repo resolution (bd-1ziw04): when start_claude: true the dispatch
  # MUST bind a repo — a no-repo idle stub does nothing and looks dispatched.
  #
  # Contract (approach b):
  #   * Explicit repo that resolves in :repo_paths → proceed.
  #   * Explicit repo that does NOT resolve     → {:error, {:repo_not_found, repo}}.
  #   * No repo, exactly one repo in :repo_paths  → auto-select, update opts.
  #   * No repo, zero repos in :repo_paths        → {:error, :no_repo_configured}.
  #   * No repo, multiple repos, workspace config
  #     `default_repo` set to one of them (bd-5pctey) → auto-select it.
  #   * No repo, multiple repos, no usable default → {:error, {:ambiguous_repo, repos}}.
  #
  # The check fires only for `start_claude: true` dispatches; a dry/manual dispatch
  # (no agent) is allowed to park without a repo.
  defp maybe_resolve_repo_for_real_work(%Issue{} = task, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false -> {:ok, opts}
      true -> resolve_repo_for_dispatch(task, opts)
    end
  end

  # `opts[:repo]` here has already absorbed the issue's own `repo` assignment
  # (see `apply_issue_repo_default/2`), so the precedence this enforces is:
  # explicit per-dispatch override > the issue's stored repo > sole-configured
  # repo auto-select > `{:ambiguous_repo, _}`. A named repo that doesn't
  # resolve is an error either way — a stale assignment must not silently
  # dispatch the work into some other checkout.
  defp resolve_repo_for_dispatch(%Issue{} = task, opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" ->
        case resolve_repo_path(task, repo) do
          nil -> {:error, {:repo_not_found, repo}}
          _path -> {:ok, opts}
        end

      _ ->
        case all_available_repos(task) do
          [] -> {:error, :no_repo_configured}
          [sole] -> {:ok, Keyword.put(opts, :repo, sole)}
          repos -> resolve_via_default_repo(task, opts, repos)
        end
    end
  end

  # bd-5pctey: a multi-repo workspace can declare a `default_repo` in its
  # `config` (same precedent as `agent`/`merge`/`tracker`) so an otherwise
  # ambiguous dispatch — e.g. Autopilot auto-dispatching a standalone task
  # with no explicit repo — has a fallback instead of always erroring. Only
  # used if the configured value actually resolves in :repo_paths; an unset
  # or dangling default_repo falls through to the pre-existing ambiguous
  # error rather than silently picking something else.
  defp resolve_via_default_repo(%Issue{workspace_id: ws_id}, opts, repos) do
    with %{"default_repo" => default_repo} when is_binary(default_repo) and default_repo != "" <-
           load_workspace_config(ws_id) || %{},
         true <- default_repo in repos do
      {:ok, Keyword.put(opts, :repo, default_repo)}
    else
      _ -> {:error, {:ambiguous_repo, repos}}
    end
  end

  @doc """
  Enumerate all repo names this task could be dispatched against — every name
  that has a **resolvable** path, drawn from:

    1. The task's workspace config `repo_paths` map.
    2. The global Application env `:repo_paths` map.

  Both sources are combined, de-duplicated, and sorted. Entries whose
  configured path doesn't resolve (moved or deleted directory) are dropped, so
  a caller offering these as choices can't offer one that would later fail
  with `{:repo_not_found, repo}`.

  Public so the dashboard's dispatch modal can populate its repo select from
  the same list dispatch itself resolves against (bd-2cv4ws). Also accepts a
  bare workspace id, for the create form (bd-2jum8j) — which has to offer repo
  choices before any `Issue` exists to ask.
  """
  @spec all_available_repos(Issue.t() | String.t() | nil) :: [String.t()]
  def all_available_repos(%Issue{workspace_id: ws_id}), do: all_available_repos(ws_id)

  # bd-9dwbvt: one enumeration, shared with the create-time resolver
  # (`Arbiter.Tasks.IssueRepo`) — the set of repos an issue may be created
  # against and the set dispatch resolves against must not be able to drift.
  def all_available_repos(ws_id) when is_binary(ws_id) or is_nil(ws_id) do
    IssueRepo.configured_repos(ws_id)
  end

  # Pre-flight auth guard (bd-awi4nw, retired to a guard-only check by bd-2jgs2h):
  # before transitioning the task and dispatching a (paid, autonomous) worker,
  # refuse immediately if `CredentialWatchdog` already knows this adapter's
  # credentials are expired.
  #
  # THIS NO LONGER RUNS A LIVE PROBE. Measured 2026-09-18: 10 auth-failed worker
  # runs in 90 days (half of them mid-run, where no pre-flight probe could have
  # helped anyway) against ~760 billed probes/day (~$23/week for Claude alone)
  # spent asking "are you logged in?" before every single dispatch and resume.
  # A rejected spawn bills nothing at the provider and the CLI exits in 3-5s, so
  # the cheaper policy is: dispatch, and let a dead credential fail fast. What
  # still has to be bounded is a *wave* of those fast failures against the same
  # dead credential — that is what this guard does, for free, off state
  # `Arbiter.Worker.fail_stopped/2` already writes: each `:auth_expired` death
  # feeds `Arbiter.Agents.AuthHold`, which opens (and marks the
  # CredentialWatchdog) after N consecutive deaths (bd-21bmdh). See both
  # moduledocs for the full posture, including how an open hold and an expired
  # mark clear without a live probe.
  #
  # Only runs on the real-agent path: skipped unless `start_claude: true`.
  # Opt out entirely with `preflight: false`.
  defp maybe_preflight(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :preflight, true) == false ->
        :ok

      not Keyword.get(opts, :start_claude, false) ->
        :ok

      true ->
        guard_known_expired(task, opts)
    end
  end

  defp guard_known_expired(%Issue{} = task, opts) do
    workspace = load_workspace(task)
    adapter = preflight_adapter(task, workspace, opts)

    # bd-21bmdh: an open `AuthHold` (N consecutive auth deaths on this
    # provider) refuses first. Its read is fail-closed — an unreadable hold
    # refuses too — and it is pure bookkeeping, so it never blocks.
    #
    # bd-5wchp1: if the CredentialWatchdog already knows this adapter's creds are
    # expired, refuse immediately — a plain state lookup, no process spawn. The
    # guard is skipped when the watchdog isn't running (returns false by default).
    cond do
      Arbiter.Agents.AuthHold.open?(adapter) ->
        refuse_known_expired(task, opts, auth_hold_stop_reason(adapter))

      Arbiter.Agents.CredentialWatchdog.expired?(adapter) ->
        refuse_known_expired(task, opts, known_expired_stop_reason(adapter))

      true ->
        guard_setup_token(task, workspace, adapter, opts)
    end
  end

  # bd-80ecol: a Claude worker with no setup token of its own used to be
  # handed a copy of the operator's `.credentials.json` (mode B) — a second
  # holder of a refresh token Claude rotates on every refresh, so whichever
  # side refreshed first locked the other out. `ConfigDir` no longer copies
  # it, which leaves such a spawn with no login at all; refuse it here, before
  # the task transitions or a worktree is provisioned, and page the coordinator
  # once per workspace with the command that fixes it
  # (`CoordinatorNotifier.setup_token_missing/2` dedupes).
  #
  # Its own error tag rather than `:auth_check_failed`: the escalation is owned
  # here, so `Arbiter.Board.Autopilot` must not add a `dispatch_stuck` page of
  # its own for the same refusal.
  # `:claude_command` swaps the claude binary for a test double, which needs no
  # Claude login — and the invariant this guard fronts for (no operator
  # credentials in a worker) lives in `ConfigDir`, not here, so standing down
  # for a non-claude spawn cannot re-open it.
  defp guard_setup_token(%Issue{} = task, workspace, Arbiter.Agents.Claude, opts) do
    if Keyword.get(opts, :claude_command), do: :ok, else: check_setup_token(task, workspace)
  end

  defp guard_setup_token(_task, _workspace, _adapter, _opts), do: :ok

  defp check_setup_token(task, workspace) do
    case CredentialCheck.check(workspace) do
      :ok ->
        :ok

      {:missing, missing} ->
        CoordinatorNotifier.setup_token_missing(
          %{task_id: task.id, workspace_id: task.workspace_id},
          missing
        )

        {:error, {:setup_token_missing, setup_token_stop_reason(missing)}}
    end
  end

  defp setup_token_stop_reason(missing) do
    %StopReason{
      category: :auth_expired,
      summary: "Claude dispatch held: " <> missing.summary,
      remediation:
        missing.fix <>
          " Arbiter never copies the operator's ~/.claude/.credentials.json into a " <>
          "worker (bd-80ecol); the task stays Ready and dispatches once a credential resolves.",
      exit_status: nil,
      signal: nil
    }
  end

  defp refuse_known_expired(task, opts, %StopReason{} = reason) do
    escalate_preflight_failure(preflight_snapshot(task, opts), reason)
    {:error, {:auth_check_failed, reason}}
  end

  defp auth_hold_stop_reason(adapter) do
    provider = adapter |> Module.split() |> List.last()

    %StopReason{
      category: :auth_expired,
      summary: "#{provider} dispatch is held: consecutive workers died on auth (AuthHold open)",
      remediation:
        "Re-authenticate the #{provider} CLI. The hold clears when the free credential " <>
          "check or the CredentialWatchdog probe next passes; to clear it by hand, " <>
          "`arb breaker reset --auth-hold <provider>`. Reopened tasks then dispatch again.",
      exit_status: nil,
      signal: nil
    }
  end

  defp known_expired_stop_reason(adapter) do
    %StopReason{
      category: :auth_expired,
      summary: "credentials known-expired (CredentialWatchdog flagged expiry)",
      remediation:
        "#{reauth_hint(adapter)} If this is a false positive, `arb breaker reset --auth-hold " <>
          "#{provider_key(adapter)}` clears the mark without a restart. Check `arb inbox` for " <>
          "the original expiry escalation.",
      exit_status: nil,
      signal: nil
    }
  end

  # bd-3kg53c: this used to say "Gemini: refresh GEMINI_API_KEY" for every
  # provider, which is wrong for agy — it has no such env var. agy resolves
  # its credential from the keyring/ADC/WIF chain (bd-svczq4), via
  # `Arbiter.Agents.Gemini.Config.resolve_api_key/0`'s workspace credentials
  # ref, not an environment variable an operator could "refresh".
  defp reauth_hint(Arbiter.Agents.Claude), do: "Re-authenticate the Claude CLI (`claude` login)."

  defp reauth_hint(Arbiter.Agents.Codex), do: "Re-authenticate the Codex CLI (`codex login`)."

  defp reauth_hint(Arbiter.Agents.Gemini),
    do:
      "Re-authenticate Gemini/Antigravity — run `agy` once on this host to sign in " <>
        "(agy's own keyring/ADC/WIF chain), or check the workspace's Gemini credentials " <>
        "ref (`Arbiter.Agents.Gemini.Config.resolve_api_key/0`). This is not always a " <>
        "`GEMINI_API_KEY` env var to refresh."

  defp reauth_hint(adapter), do: "Re-authenticate the #{provider_key(adapter)} CLI."

  defp provider_key(adapter) do
    case Enum.find(Arbiter.Agents.adapters(), fn {_type, mod} -> mod == adapter end) do
      {type, _} -> Atom.to_string(type)
      nil -> adapter |> Module.split() |> List.last() |> String.downcase()
    end
  end

  # Resolve the workspace's worker adapter so we probe the CLI that will
  # actually be slung. Resolution order:
  #   1. `:agent_adapter` test override — lets tests stub the adapter.
  #   2. `:agent_type` explicit override — probe the forced provider.
  #   3. Workspace default — `Agents.for_workspace` reads `agent.type`.
  defp preflight_adapter(_task, workspace, opts) do
    case Keyword.get(opts, :agent_adapter) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      _ ->
        case Keyword.get(opts, :agent_type) do
          type when is_atom(type) and not is_nil(type) -> Agents.for_type(type)
          _ -> Agents.for_workspace(workspace)
        end
    end
  end

  @doc """
  Page the coordinator about a refused pre-flight auth guard, behind the shared
  circuit breaker (bd-5jr49o).

  `guard_known_expired/2`'s refusal — the CredentialWatchdog's known-expired
  short circuit — funnels through here, which is the choke point bd-8lnnnt's
  own fix picked for the same reason: the breaker must be independent of
  *which* caller retried. `Arbiter.Workflows.DispatchQueue`'s held-intent
  drain would otherwise re-run this same refusal on `CloudProbe`'s ~5-minute
  cadence, so one task stuck behind a known-expired credential produced 14
  identical pages in 75 minutes.

  The breaker is keyed on task + refusal category, NOT on the reason summary,
  which carries the elapsed time and attempt number. Returns `:ok` when the
  page was attempted and `:suppressed` when the breaker is open.

  Public only so the adoption test can drive the exact code the call sites run.
  """
  @spec escalate_preflight_failure(map(), StopReason.t()) :: :ok | :suppressed
  def escalate_preflight_failure(snapshot, %StopReason{} = reason) do
    result =
      CircuitBreaker.guard(
        :preflight_auth_failed,
        [Map.get(snapshot, :task_id), reason.category],
        [
          workspace_id: Map.get(snapshot, :workspace_id),
          task_ref: Map.get(snapshot, :task_id),
          detail:
            "The CredentialWatchdog's known-expired guard kept refusing dispatch for " <>
              "this task. Only an operator can clear it — re-authenticate the agent " <>
              "CLI, then re-dispatch."
        ],
        fn -> CoordinatorNotifier.preflight_failed(snapshot, reason) end
      )

    case result do
      {:ok, _} -> :ok
      {:suppressed, _info} -> :suppressed
    end
  end

  defp preflight_snapshot(%Issue{id: id, workspace_id: ws_id}, opts) do
    %{
      task_id: id,
      workspace_id: ws_id,
      repo: Keyword.get(opts, :repo),
      meta: %{}
    }
  end

  # Spawn a Claude subprocess in the worktree, attached to the worker.
  #
  # **Opt-in only.** Defaults to `start_claude: false` so callers must
  # explicitly authorize the (paid, autonomous) agent invocation. The CLI
  # surfaces this via the `--with-claude` flag on `arb dispatch`.
  #
  # Requires a worktree (Layer 3) — returns `{:error, :missing_worktree}`
  # if start_claude is true but worktree_path is nil. This prevents
  # silently launching Claude with `cd: nil`.
  #
  # The `:claude_command` opt is the test escape hatch: when set, it
  # overrides the default streaming `claude` argv so tests can spawn `echo`
  # or a script instead of the real Claude CLI.
  defp maybe_start_claude(_task, _worker_pid, _worktree_path, opts)
       when not is_list(opts) do
    {:ok, nil, []}
  end

  defp maybe_start_claude(%Issue{} = task, worker_pid, worktree_path, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false ->
        {:ok, nil, opts}

      true ->
        # Dispatches that provision no branch worktree (task-type audits,
        # reviews) still need a real cwd for the agent port. `resolve_agent_cwd/3`
        # owns that fallback — and, since bd-9r1tta, owns making sure it isn't a
        # stale one.
        case resolve_agent_cwd(task, worktree_path, opts) do
          {:error, reason} ->
            {:error, reason}

          {:ok, path, opts} when is_binary(path) ->
            # Inject the per-spawn MCP config (.mcp.json) into the *isolated*
            # worktree so the agent can read its task / mailbox and write
            # completion notes as typed tool calls. Best-effort: never blocks
            # the spawn.
            #
            # Pass `worktree_path`, NOT `path` (bd-dlv3no): a review dispatch has
            # no worktree, so `path` falls back to the repo's shared checkout
            # (`resolve_agent_cwd/3`). Writing the token-bearing `.mcp.json`
            # there leaks it into the canonical checkout the live server +
            # operator share — the exact "worker leaks into the main worktree"
            # class this fixes. With a nil worktree the helper is a no-op, so
            # reviews never touch the repo's working tree.
            #
            # bd-9r1tta note: a task-type dispatch's `path` is now an *isolated*
            # detached worktree, so injecting there would be safe. Left keyed to
            # `worktree_path` deliberately — enabling MCP tools for audit
            # dispatches is a behavior change beyond that fix's scope.
            #
            # bd-7e8ezw: the returned `mcp_config:` path is threaded to the
            # adapter so Claude is handed the file explicitly (`--mcp-config`)
            # rather than trusting cwd auto-load — see `inject_mcp_config/3`.
            opts = Keyword.merge(opts, inject_mcp_config(task, worktree_path, opts))

            # Resolve the layered effective skill set and materialize ONLY it
            # into the isolated worktree (bd-d5hy7y), under a provider-aware
            # directory resolved the same way as the MCP config write above
            # (bd-bbbxvp / agy-parity T8): `.claude/skills` for claude,
            # `.agents/skills` for gemini, nothing for codex (inlined). Threaded
            # onto opts so the work prompt can auto-invoke always-on skills and
            # advertise situational ones (DECISION C). No-op without a worktree
            # (review / task-type dispatch) — skills only ever land in an
            # isolated tree.
            skills_provider = resolve_mcp_provider(task, opts)
            resolved_skills = resolve_skills(task, worktree_path, opts)

            _ =
              Arbiter.Skills.Materializer.materialize(
                worktree_path,
                resolved_skills,
                skills_provider
              )

            skills_materialized? = skills_discoverable?(skills_provider, opts)

            opts =
              opts
              |> Keyword.put(:resolved_skills, resolved_skills)
              |> Keyword.put(:skills_materialized?, skills_materialized?)

            with {:ok, session_opts} <-
                   build_agent_session_opts(task, worker_pid, path, opts),
                 {:ok, port} <- ClaudeSession.start(session_opts) do
              # Move the run out of :starting so UI/CLI report a meaningful
              # state while Claude works. In claude_driven mode the Driver
              # never ticks the Machine, so without this nudge the run would
              # remain :starting until "arb done" finished it.
              _ = Worker.advance(worker_pid, :claude)
              {:ok, port, opts}
            else
              {:error, reason} ->
                Checkout.teardown(review_checkout_path(opts))
                {:error, {:claude_start_failed, reason}}
            end
        end
    end
  end

  # Resolve the agent's cwd.
  #
  # A provisioned worktree is already cut from `origin/<target>` by
  # `Worktree.create/3`, so it is current by construction — use it as-is.
  #
  # Without one there are two cases, and before bd-9r1tta both got the repo's
  # *shared* local checkout verbatim:
  #
  #   - task-type issues — ops/research/audit work whose deliverable is notes
  #   - review dispatches (`review: true`) — read-only code review, no branch
  #
  # On a developer host that shared checkout is a human contributor's working
  # directory. Nothing kept it current: the `tonic` checkout that produced this
  # bug was 72 commits and a full month behind `origin/main`, its HEAD predating
  # the very merge the audit was asked about. The audit read that tree, found no
  # encryption, and reported "PHI is stored in plaintext" as a release-gating
  # critical finding with file:line citations. Every word of it was true about a
  # month-old tree and false about the repo.
  #
  # So: a task-type dispatch now gets its own detached checkout at
  # `origin/<target>` (`Worktree.create_detached/3`), and a review dispatch — since
  # bd-199giy — gets its OWN throwaway detached checkout at the reviewed branch's
  # current `origin` head, falling back to the (refreshed) shared checkout when
  # that can't be provisioned. Neither path writes to the contributor's HEAD,
  # index, or working tree.
  #
  # Regular feature/bug/chore dispatches without a worktree still surface
  # `:missing_worktree` rather than silently running from the main checkout.
  #
  # Returns the resolved cwd AND the opts it was resolved with: a review
  # checkout is recorded on them (`:review_checkout`) so the prompt can describe
  # it, `build_agent_session_opts/4` can harden the spawn's tool access, and the
  # Driver can tear it down.
  @spec resolve_agent_cwd(Issue.t(), String.t() | nil, keyword()) ::
          {:ok, String.t(), keyword()} | {:error, term()}
  defp resolve_agent_cwd(_task, worktree_path, opts) when is_binary(worktree_path),
    do: {:ok, worktree_path, opts}

  defp resolve_agent_cwd(%Issue{} = task, nil_worktree, opts) do
    if Issue.no_pr_type?(task.issue_type),
      do: resolve_no_pr_cwd(task, opts),
      else: resolve_review_or_missing_cwd(task, nil_worktree, opts)
  end

  # bd-9s9dqz: a no-PR ticket (`:task` / `:research`) with no worktree still
  # gets a detached, branch-free checkout to inspect and run `gh`/`git` from.
  defp resolve_no_pr_cwd(%Issue{} = task, opts) do
    case resolve_repo_path(task, Keyword.get(opts, :repo)) do
      nil ->
        {:error, :missing_worktree}

      repo_path when is_binary(repo_path) ->
        with {:ok, path} <- provision_inspect_worktree(task, repo_path, opts) do
          {:ok, path, opts}
        end
    end
  end

  defp resolve_review_or_missing_cwd(%Issue{} = task, _nil_worktree, opts) do
    with true <- Keyword.get(opts, :review, false),
         repo_path when is_binary(repo_path) <-
           resolve_repo_path(task, Keyword.get(opts, :repo)) do
      target = resolve_target_branch(task, opts)

      # Best-effort: a review that can't reach `origin` is still a useful review
      # of the local branches, and refreshing remote-tracking refs is the only
      # thing that could have failed — nothing was mutated. It also gives the
      # provisioned checkout below a current `origin/<target>` to diff against.
      _ = Worktree.fetch_origin(repo_path, target)

      case provision_review_checkout(task, repo_path, target, opts) do
        %{path: path} = checkout ->
          {:ok, path, Keyword.put(opts, :review_checkout, checkout)}

        nil ->
          {:ok, repo_path, opts}
      end
    else
      _ -> {:error, :missing_worktree}
    end
  end

  # bd-199giy: give the internal reviewer the same fidelity the external Tier-2
  # reviewer has had since bd-6onexk — a real, disposable checkout at the exact
  # commit under review, instead of the repo's *shared* local checkout plus a
  # `gh pr diff`.
  #
  # Diff-only review is a strictly weaker review: it cannot open a caller the
  # diff doesn't show, grep for other uses of a changed function, or run the
  # test suite against the tree as the branch actually left it. And the shared
  # checkout it ran from is a human contributor's working directory, sitting on
  # whatever branch they last touched — so even the file reads it *could* do
  # were against the wrong tree.
  #
  # Best-effort, and deliberately so: this returns `nil` on every failure (no
  # derivable branch, branch never pushed, no `origin`, git error) and the
  # caller falls straight back to today's diff-only path. A review that can't
  # get a worktree is still worth running.
  defp provision_review_checkout(%Issue{} = task, repo_path, target, opts) do
    require Logger

    case review_branch(task) do
      nil ->
        nil

      branch ->
        # bd-4wy1w1: a branch held in a private clone (git layout B) reaches
        # the main repo, where the checkout's never-pushed fallback looks,
        # only through a sync-back.
        _ = Worktree.sync_branch(repo_path, branch)

        case Checkout.provision_branch(repo_path, branch, prefix: "review") do
          {:ok, %{path: path, head_sha: sha}} ->
            seed_review_checkout(task, repo_path, branch, path, opts)
            %{path: path, branch: branch, head_sha: sha, base_branch: target}

          {:error, reason} ->
            Logger.info(
              "Dispatch: no review checkout for task #{task.id} (branch #{branch}): " <>
                "#{inspect(reason)}; reviewing from #{repo_path} diff-only"
            )

            nil
        end
    end
  end

  # The reviewer runs tests here, so it gets the same seeded deps/_build (and
  # `worker.repos.<repo>.seed_paths`) ReviewGate's own `gate-review-*` checkout
  # gets. The source is the task's implementer worktree when one exists (the
  # tree that was seeded and compiled), else the repo checkout. Best-effort and
  # a no-op when the source has nothing to copy.
  defp seed_review_checkout(%Issue{} = task, repo_path, branch, path, opts) do
    implementer_wt = Worktree.worktree_path(branch)
    source = if File.dir?(implementer_wt), do: implementer_wt, else: repo_path
    :ok = Worktree.seed_compiled_deps(source, path, seed_paths(task, Keyword.get(opts, :repo)))
  end

  # `BranchNamer.derive/1` raises for an issue with no recognisable type or ref
  # (a review-only issue minted for an arbitrary PR can be either) — that is a
  # "no checkout" answer, not a dispatch failure.
  defp review_branch(%Issue{} = task) do
    BranchNamer.derive(task)
  rescue
    _ -> nil
  end

  # An isolated, detached checkout at the tip of `origin/<target>`, at the task's
  # *inspect* leaf (`Worktree.inspect_name/1` — the branch name plus a suffix, so
  # it can never collide with a branch worktree for the same task).
  # `Issue.Changes.CleanupWorktree` reclaims that leaf on close exactly as it does
  # a code worktree.
  #
  # A repo with no `origin` cannot be stale — there is no upstream to be behind —
  # so that one case falls back to the local checkout instead of failing a
  # dispatch that works fine today. Every other failure (fetch failed, the target
  # branch is gone upstream, `git worktree add` failed) is surfaced: handing the
  # agent the shared checkout after a failed refresh is precisely the
  # silently-wrong-answer path this fix closes.
  defp provision_inspect_worktree(%Issue{} = task, repo_path, opts) do
    require Logger

    name = Worktree.inspect_name(BranchNamer.derive(task))
    base_branch = resolve_target_branch(task, opts)

    case Worktree.create_detached(repo_path, name, base_branch,
           seed_paths: seed_paths(task, Keyword.get(opts, :repo))
         ) do
      {:ok, path} ->
        {:ok, path}

      {:error, {:missing_origin_remote, _msg}} ->
        Logger.info(
          "Dispatch: #{repo_path} has no origin remote; task #{task.id} runs from the local " <>
            "checkout (nothing upstream to be stale against)"
        )

        {:ok, repo_path}

      {:error, reason} ->
        Logger.warning(
          "Dispatch: could not provision an up-to-date checkout for task #{task.id} from " <>
            "#{repo_path} (#{inspect(reason)}); refusing to run the agent against a possibly " <>
            "stale local tree"
        )

        {:error, {:inspect_worktree_failed, reason}}
    end
  end

  @doc """
  Harden a review dispatch's security policy once the reviewer has a real
  checkout to stand in (bd-199giy).

  A diff-only reviewer had nothing to write to, so nothing to deny. A
  worktree-backed one does: it is holding the branch's actual files, and
  nothing about reviewing needs `Edit`/`Write`/`NotebookEdit`. Denying them
  makes "you are not the author; do not modify the branch" a property of the
  spawn rather than a line in a prompt.

  Network stays ON, unlike the external Tier-2 reviewer (`CodeReview.Checks`):
  this reviewer posts its own inline comments and verdict through `gh`/`glab`,
  so cutting the network would cut the review's whole output path.

  Public so the posture is assertable without reaching into a spawned
  session's argv — and so the in-gate ReviewGate reviewer, which runs in its
  round's own detached checkout, gets this exact posture rather than a copy of
  it (`Arbiter.Worker.ReviewGate.session_security_policy/3`, bd-a22hib).
  """
  @spec review_security_policy(SecurityPolicy.t(), keyword()) :: SecurityPolicy.t()
  def review_security_policy(%SecurityPolicy{} = policy, opts) do
    policy
    |> review_backend_policy(opts)
    |> review_write_denied(opts)
  end

  # bd-4rvf98: a review spawn (a `review: true` dispatch, or any reviewer holding
  # a checkout) runs under `sandbox.review_backend`, not the implement backend:
  # `sandbox.backend: podman` wraps only the task worker's private clone, so a
  # review keeping it was refused outright. `review_backend` is bwrap unless the
  # operator set it, and one with no implementation is still refused downstream.
  #
  # bd-7ays3v: a ReviewGate reviewer that names its `:provider` and stands in a
  # private clone keeps a podman `sandbox.backend` for Claude
  # (`SecurityPolicy.for_review_spawn/2`).
  defp review_backend_policy(policy, opts) do
    if Keyword.get(opts, :review, false) or review_checkout_path(opts) != nil,
      do:
        SecurityPolicy.for_review_spawn(policy,
          provider: Keyword.get(opts, :provider),
          private_clone: PrivateClone.clone?(review_checkout_path(opts))
        ),
      else: policy
  end

  defp review_write_denied(policy, opts) do
    case review_checkout_path(opts) do
      nil ->
        policy

      _path ->
        SecurityPolicy.merge(policy, %{
          "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]}
        })
    end
  end

  # Resolve the agent for this task through the `Arbiter.Agents` dispatcher
  # and the configured `Arbiter.Agents.Routing` policy, then assemble the
  # `ClaudeSession.start/1` options. This is the seam where model-tiering
  # and key-rotation enter the spawn — both default off, so a workspace
  # that hasn't opted in sees today's argv + env unchanged.
  #
  # The `:claude_command` opt (used by tests to spawn an echo script
  # instead of the real Claude CLI) bypasses the adapter entirely — it's a
  # raw argv override and the routing policy has nothing to add.
  defp build_agent_session_opts(%Issue{} = task, worker_pid, worktree_path, opts) do
    base = [owner: worker_pid, worktree_path: worktree_path]

    case Keyword.get(opts, :claude_command) do
      cmd when is_list(cmd) ->
        {:ok, base ++ [command: cmd]}

      _ ->
        workspace = load_workspace(task)
        :ok = Agents.prepare(workspace, :agent)

        # Order matters: apply the provider (agent_type) override first so it
        # can strip the routed, provider-specific model, then the bd-8cn795
        # thrash auto-escalation (a *default*, not an override), then let an
        # explicit `--model` override win on top of everything.
        agent_type = resolve_session_agent_type(opts, task, workspace)

        choice =
          task
          |> Routing.decide(workspace, opts)
          |> apply_agent_type_override(agent_type)
          |> maybe_escalate_context_window(task.id)
          |> apply_model_override(Keyword.get(opts, :model))

        # Resolve the spawn's security posture from the workspace (per-domain),
        # with an optional per-dispatch override from dispatch opts and the
        # resolved repo name so a multi-repo workspace can scope a different
        # posture to this repo (bd-3gc18m). Threaded into the adapter so it
        # bakes the right permission-mode + deny/allow into the argv — no
        # inheritance of the operator's ~/.claude (bd-9u10op).
        #
        # bd-anwb0u (G11): `base_policy` is the resolved posture before the
        # guardrail floor. The floor depends on the (provider, model) subject, so
        # it is applied per candidate provider (`guardrail_floor/4`) — here for
        # the routed one, again below if the strict gate swaps it.
        base_policy =
          workspace
          |> dispatch_policy(opts)
          |> review_security_policy(opts)

        policy = guardrail_floor(base_policy, workspace, choice, opts)

        # bd-1abj7u: fail closed on a `:strict` scope that a chosen provider
        # cannot keep — never silently downgrade the mode or dispatch anyway.
        # `agent_type` is non-nil only when the caller named a provider
        # directly (`arb dispatch --provider`, a resumed/revision provider
        # pin); that case is refused rather than swapped out from under the
        # caller. Automatic routing (`agent_type` nil) instead tries the next
        # configured provider in `Agents.agent_pool/1` and only refuses when
        # none of them can confine writes.
        #
        # bd-btcdrf: a `sandbox.backend` with no implementation is refused here,
        # before any provider is chosen or a worktree session built, so the
        # operator sees it at dispatch rather than as a late spawn error.
        #
        # bd-13pqcp: the swap pool is filtered by the ticket's provider
        # constraint, so a strict-policy swap never lands on an excluded one.
        swap_pool = ProviderConstraint.filter(task, Agents.agent_pool(workspace))

        checked =
          choice.type
          |> sandbox_checked_provider(policy, swap_pool, explicit: not is_nil(agent_type))
          |> guardrail_checked(base_policy, workspace, choice, opts)

        case checked do
          {:error, reason} ->
            {:error, provider_refusal(reason, choice.type, policy, workspace, opts)}

          {:ok, effective_type} ->
            choice = apply_agent_type_override(choice, effective_type)
            policy = guardrail_floor(base_policy, workspace, choice, opts)
            adapter = Agents.for_type(choice.type)

            # `workspace:` is carried for the adapter's `spawn_env/1` — it resolves
            # the worker OAuth token from this workspace's `worker_env` before
            # falling back to the server env (bd-bw3466).
            #
            # `worktree_path:` is carried for the same reason on the agy side: it
            # keys the per-spawn isolated `$HOME`
            # (`Arbiter.Agents.Gemini.ConfigDir`, bd-7s29yq). It must be the SAME
            # value `maybe_write_mcp_config/3` above was given, or the spawn would
            # read a different HOME than the one the MCP config was written into.
            agent_opts =
              agent_opts_from_choice(choice) ++
                [
                  security: policy,
                  workspace: workspace,
                  worktree_path: worktree_path,
                  owner: worker_pid,
                  task_id: task.id,
                  # bd-d2o3xb: this dispatch hands the spawn to `ClaudeSession`
                  # with `policy`, which is what wraps it under `podman`.
                  sandbox_wrap: true
                ] ++
                Keyword.take(opts, [:mcp_config, :arb_token])

            tracker_context = fetch_tracker_context(task, workspace)

            prompt =
              opts
              |> Keyword.put(:worktree_path, worktree_path)
              |> Keyword.put(:tracker_context, tracker_context)
              |> Keyword.put(:adapter, adapter)
              |> Keyword.put(:sandbox_backend, SecurityPolicy.sandbox_backend(policy))
              |> then(&prompt_for_task(task, &1))

            provider = Atom.to_string(choice.type)

            # Concrete model the adapter will dispatch with, if it can name one ahead
            # of the stream (Gemini, whose CLI emits no `init` event). nil for Claude,
            # which learns the exact model from its stream-json `init` — we must NOT
            # thread the routed tier alias ("sonnet") onto a Claude session, or the
            # ledger would record the alias when the stream is the source of truth.
            session_model = resolved_model_for(adapter, agent_opts)

            routing_config = %{
              provider: provider,
              # For live display the routed model is a fine pre-stream stand-in.
              model: session_model || Keyword.get(agent_opts, :model),
              model_tier: Keyword.get(agent_opts, :model_tier),
              thinking: Keyword.get(agent_opts, :thinking)
            }

            Worker.report(worker_pid, :routing_config, routing_config)

            # bd-dzz6ly: everything that GOVERNED this run — the effective
            # post-layering skill set (already threaded onto opts by
            # maybe_start_claude), the routing policy that produced `choice`, and
            # the workspace's standing_orders digest — backfilled onto the Run
            # row the same way :model's late arrival already is above.
            Worker.report(worker_pid, :run_provenance, %{
              resolved_skills: RunProvenance.skills(Keyword.get(opts, :resolved_skills, [])),
              standing_orders_digest: RunProvenance.standing_orders_digest(workspace),
              routing_policy: RunProvenance.routing_policy_string(workspace),
              model_tier: Keyword.get(agent_opts, :model_tier),
              thinking: Keyword.get(agent_opts, :thinking),
              # bd-c675ny (R8): a floor-clamped dispatch did not get the rule its
              # policy/canary arm assigned; Canary.Metrics leaves it out.
              floor_clamped: Floors.clamped?(choice)
            })

            # Stamp the resolved model onto the worker's meta at dispatch time so
            # worker_list can show the model before any session output lands.
            if model = Map.get(routing_config, :model) do
              Worker.report(worker_pid, :model, model)
            end

            case adapter.default_argv(prompt, agent_opts) do
              {:ok, argv} ->
                # Skill guard (bd-d5hy7y, spike findings): a worker carrying
                # materialized skills must not be spawned with `--bare` (skips skill
                # discovery) or `--disable-slash-commands` (blocks `/name`
                # invocation), or the skills silently do nothing. We never add these
                # flags — this catches a future regression loudly rather than
                # shipping dead skills.
                _ = guard_skill_flags(argv, Keyword.get(opts, :resolved_skills, []))

                env = safe_spawn_env(adapter, agent_opts)
                # Thread provider (+ pre-resolved model, when the adapter has one)
                # onto the session so the usage ledger and dashboards attribute the
                # run correctly even when the CLI stream carries no model/provider
                # (bd-guegdl).
                session_meta = [provider: provider, model: session_model]
                # bd-9rdwe4: `prompt:` alongside `command:` plays no role in argv
                # resolution (that's `command:`'s job) — it's carried purely so
                # `Arbiter.Worker` can persist what this worker was actually told.
                #
                # bd-asawcq: `:arb_token` (from `inject_mcp_config/3`) becomes the
                # agent's ARB_TOKEN, so its own `arb` authenticates as this task.
                {:ok,
                 base ++
                   [command: argv, prompt: prompt, env: env] ++
                   session_meta ++
                   sandbox_session_opts(policy, workspace, opts) ++
                   Keyword.take(opts, [:arb_token])}

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  # The inputs `ClaudeSession` needs to wrap a `sandbox.backend: podman` spawn;
  # none for any other backend, so a bwrap or unsandboxed spawn is unchanged.
  defp sandbox_session_opts(policy, workspace, opts),
    do: ContainerSpawn.session_opts(policy, workspace, Keyword.take(opts, [:repo, :node]))

  defp resolve_session_agent_type(opts, %Issue{id: id} = task, workspace) do
    Keyword.get(opts, :agent_type) || revision_or_resume_provider(opts, task, id, workspace)
  end

  defp revision_or_resume_provider(opts, task, id, workspace) do
    if Keyword.get(opts, :resume) || Arbiter.Worker.ReviewGate.base_task_id(id) != id do
      elem(Agents.resolve_revision_provider(id, workspace, ProviderConstraint.from(task)), 0)
    end
  end

  # Translate a Routing.Policy.choice() config map (JSON string-keyed) into
  # the keyword opts the Agent behaviour expects (`:model`, `:model_tier`,
  # `:thinking`, ...). Unknown keys are passed through under `:config` so
  # future adapters can read adapter-specific keys without growing this
  # function.
  defp agent_opts_from_choice(%{config: config}) when is_map(config) do
    [
      model: Map.get(config, "model"),
      model_tier: Map.get(config, "model_tier"),
      thinking: Map.get(config, "thinking"),
      config: config
    ]
  end

  # A `:model` opt on `Dispatch.dispatch/2` is a one-shot, per-dispatch override —
  # the task might be P2 (routing → sonnet) but the caller wants to try it
  # on Opus once. We splat the override on top of the routed config so it
  # wins over both the workspace default and any routing rule. A `nil` /
  # empty override is a no-op (the routed choice stands).
  defp apply_model_override(choice, override) when is_binary(override) and override != "" do
    %{choice | config: Map.put(choice.config || %{}, "model", override)}
  end

  defp apply_model_override(choice, _), do: choice

  # bd-8cn795: a task whose most recent run died with `:context_thrash` (the
  # Claude CLI's "Autocompact is thrashing" loop detector) will die identically
  # on a plain retry — the working set that overflowed the window hasn't
  # changed. Auto-escalate the redispatch to a 1M-context model so the
  # coordinator doesn't have to remember to pass a manual `model:`
  # override every time. This is a *default*, not an override: it's applied
  # before `apply_model_override/2`, so an explicit `opts[:model]` still wins.
  @context_window_escalation_model "claude-sonnet-5[1m]"

  defp maybe_escalate_context_window(choice, task_id) do
    if thrashed_last_run?(task_id) do
      %{choice | config: Map.put(choice.config || %{}, "model", @context_window_escalation_model)}
    else
      choice
    end
  end

  # The dispatch call that's asking has already created ITS OWN live Run row
  # for this attempt (the worker creates it on init, before
  # `build_agent_session_opts` ever runs) — so "the last run" as of this check
  # is always the in-flight one, never the prior failure we're trying to
  # detect. Look at the most recent *failed* run instead.
  defp thrashed_last_run?(task_id) do
    case latest_failed_run(task_id) do
      %Run{} = run -> thrashed?(run)
      nil -> false
    end
  end

  # bd-apwfmy: the run already classified itself the moment it died and stored
  # the answer in `stop_category`. Prefer it. Re-deriving from `output_lines`
  # is not merely redundant — those lines are capped, so on a long run the
  # thrash banner has scrolled out of the window and the re-derivation quietly
  # returns "not thrash", losing the escalation. The scan stays only as the
  # fallback for runs that predate the column.
  defp thrashed?(%Run{stop_category: "context_thrash"}), do: true
  defp thrashed?(%Run{stop_category: category}) when is_binary(category), do: false

  defp thrashed?(%Run{} = run),
    do:
      StopReason.classify(run.exit_code, Arbiter.Workers.OutputOffload.output_lines(run)).category ==
        :context_thrash

  defp latest_failed_run(task_id) when is_binary(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id and outcome == :failed)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  defp latest_failed_run(_), do: nil

  # A `:agent_type` opt on `Dispatch.dispatch/2` is an explicit per-dispatch provider
  # override — the workspace may default to :claude but the caller wants :gemini
  # (or vice versa). Splatting the type onto the routed choice lets it win over
  # both the workspace default and any routing rule.
  #
  # When the override switches to a *different* provider than the one the
  # routing policy chose, the routed `"model"` is provider-specific (e.g. a
  # Claude `"sonnet"`) and meaningless to the new adapter, so we drop it — the
  # new adapter resolves its own default. The abstract `model_tier` / `thinking`
  # knobs are provider-agnostic and stay. An explicit `--model` override is
  # re-applied after this step (see build_agent_session_opts) and still wins.
  defp apply_agent_type_override(%{type: type} = choice, type), do: choice

  defp apply_agent_type_override(choice, type) when is_atom(type) and not is_nil(type) do
    config = Map.drop(choice.config || %{}, ["model"])
    %{choice | type: type, config: config}
  end

  defp apply_agent_type_override(choice, _), do: choice

  # Optional per-dispatch (per-task) security override. Accepts a raw map under
  # the `:security` dispatch opt (same shape as `workspace.config["agent"]["security"]`)
  # or the `:security_mode` shorthand for the common "just change the mode" case.
  # Returns `%{}` (no override) when neither is set.
  defp security_override(opts) do
    base =
      case Keyword.get(opts, :security) do
        %{} = map -> map
        _ -> %{}
      end

    case Keyword.get(opts, :security_mode) do
      mode when is_binary(mode) or (is_atom(mode) and not is_nil(mode)) ->
        Map.update(base, "permissions", %{"mode" => mode}, fn perms ->
          Map.put(perms, "mode", mode)
        end)

      _ ->
        base
    end
  end

  # bd-1abj7u: the fail-closed refusal for a `:strict` dispatch whose chosen
  # provider can't confine writes to the worktree (`docs/design/agy-strict-write-isolation.md`).
  # Names the provider, which config layer set `:strict` (so the operator
  # knows what to change), and the two ways out — switch the workspace/repo
  # to claude, or wait for the bwrap jail (bd-5gvqgc) to make this provider
  # eligible.
  #
  # Public (not `defp`) so `Arbiter.Worker.ReviewGate`'s own write-confinement
  # gates (the reviewer and revision-implementer spawn paths) raise the
  # identical, actionable message rather than inventing a second wording of
  # the same refusal.
  @spec strict_write_confinement_error(atom(), SecurityPolicy.t(), map() | nil, keyword()) ::
          {:strict_write_confinement_unavailable, String.t()}
  def strict_write_confinement_error(provider_type, %SecurityPolicy{} = policy, workspace, opts) do
    {resolved_mode, source} =
      SecurityPolicy.mode_source(workspace, security_override(opts), Keyword.get(opts, :repo))

    # G11: a mode the resolved layers did not ask for is the guardrail floor's.
    source = if policy.permissions.mode == resolved_mode, do: source, else: :guardrail_floor

    {:strict_write_confinement_unavailable,
     "Refusing to dispatch to #{provider_type} under :strict write isolation " <>
       "(#{policy.permissions.mode} scoped by #{mode_source_label(source)}): #{provider_type} " <>
       "cannot confine its writes to the worktree — the model's own tools can still write " <>
       "anywhere the host user can (see docs/design/agy-strict-write-isolation.md). " <>
       "Use claude for this dispatch instead, or install bubblewrap once the OS jail " <>
       "(bd-5gvqgc) ships and makes #{provider_type} :strict-eligible."}
  end

  # bd-anwb0u (G11): the tighten-only guardrail floor (design §7.2) over the
  # resolved `policy`, for the (provider, model) this `choice` will run. A no-op
  # unless subject rules are configured (`Arbiter.Guardrails.effective/4`).
  defp guardrail_floor(%SecurityPolicy{} = policy, workspace, choice, opts) do
    provider = choice.type
    config = choice.config || %{}

    model =
      Map.get(config, "model") ||
        ModelFamily.model_for_tier(provider, Map.get(config, "model_tier"), config)

    Guardrails.apply_to_policy(policy, workspace, provider, model, repo: Keyword.get(opts, :repo))
  end

  # A guardrail profile states what must hold and the adapter says whether it
  # can hold on this host (design §3.4). When it cannot, the dispatch is refused
  # rather than spawned under a weaker posture, the bd-1abj7u rule generalised
  # to egress.
  defp guardrail_checked({:ok, type} = ok, base_policy, workspace, choice, opts) do
    choice = apply_agent_type_override(choice, type)
    policy = guardrail_floor(base_policy, workspace, choice, opts)

    profile =
      Guardrails.effective(
        Guardrails.subject(choice.type, Map.get(choice.config || %{}, "model")),
        workspace,
        Keyword.get(opts, :repo)
      )

    case Guardrails.enforceable(Agents.for_type(choice.type), policy, profile) do
      :ok ->
        ok

      {:error, reason} ->
        {:error,
         {:guardrail_unenforceable,
          "Refusing to dispatch to #{choice.type}: its guardrail tier (#{profile.tier}) needs " <>
            "#{guardrail_need(reason, policy)}, which #{choice.type} cannot provide on this host " <>
            "(#{reason}). Route this ticket to a provider that can, or have the operator " <>
            "change the subject's tier."}}
    end
  end

  defp guardrail_checked(other, _base_policy, _workspace, _choice, _opts), do: other

  defp guardrail_need(:write_confinement_none, _policy), do: "write confinement (:strict)"

  defp guardrail_need(:egress_unenforceable, policy),
    do: "network egress confinement (egress: #{SecurityPolicy.egress(policy)})"

  # bd-d2o3xb (P7), bd-50d5j6 (P8): `sandbox.backend: podman` has a wrap point
  # for Claude and Codex only, so under it the pool is those two or nothing. An
  # explicit `--provider` with no wrap point is refused; automatic routing falls
  # to Claude when it is in the pool. Anything else would run unsandboxed under
  # a backend the operator chose precisely so that it would not.
  defp sandbox_checked_provider(preferred, policy, pool, opts) do
    case Sandbox.module(policy, preferred) do
      {:ok, _sandbox} ->
        Agents.strict_eligible_provider(preferred, policy, sandbox_pool(policy, pool), opts)

      {:error, _refusal} ->
        if :claude in pool and not Keyword.get(opts, :explicit, false) and
             match?({:ok, _}, Sandbox.module(policy, :claude)),
           do: Agents.strict_eligible_provider(:claude, policy, [], opts),
           else: {:error, :ineligible}
    end
  end

  defp sandbox_pool(policy, pool) do
    if ContainerSpawn.podman?(policy),
      do: Enum.filter(pool, &match?({:ok, _}, Sandbox.module(policy, &1))),
      else: pool
  end

  # Why no provider was eligible: the sandbox/strict gate (`:ineligible`), or a
  # guardrail tier no candidate can enforce on this host (G11).
  defp provider_refusal(:ineligible, provider_type, policy, workspace, opts),
    do: ineligible_provider_error(provider_type, policy, workspace, opts)

  defp provider_refusal({:guardrail_unenforceable, _} = refusal, _type, _policy, _ws, _opts),
    do: refusal

  # Why `sandbox_checked_provider/4` found no eligible provider: a sandbox
  # backend with no implementation for it, else the `:strict` write-confinement
  # gap.
  defp ineligible_provider_error(provider_type, policy, workspace, opts) do
    case Sandbox.module(policy, provider_type) do
      {:error, refusal} -> refusal
      {:ok, _sandbox} -> strict_write_confinement_error(provider_type, policy, workspace, opts)
    end
  end

  defp mode_source_label(:dispatch_override), do: "this dispatch's own override"
  defp mode_source_label(:repo), do: "a repos.<repo> override"
  defp mode_source_label(:workspace), do: "the workspace default"
  defp mode_source_label(:install_default), do: "the install-wide default"
  defp mode_source_label(:guardrail_floor), do: "this subject's guardrail tier"

  defp safe_spawn_env(adapter, agent_opts) do
    if function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(agent_opts)
    else
      []
    end
  end

  # The concrete model the adapter will dispatch with, if it can name one ahead
  # of the stream (optional `resolved_model/1` callback). Returns nil for
  # adapters that don't implement it (e.g. Claude, whose model arrives in the
  # stream-json `init` event) — the caller then falls back to the routed model.
  defp resolved_model_for(adapter, agent_opts) do
    if function_exported?(adapter, :resolved_model, 1) do
      adapter.resolved_model(agent_opts)
    end
  end

  # Write the per-spawn Arbiter.MCP config into the worktree (bd-dem49g). Hands
  # the narrow `:worker`-tier scope token `inject_mcp_config/3` minted (bound to
  # this task/repo/workspace) to the agent-specific config adapter (Phase 1:
  # Claude `.mcp.json`). The token *is* the worker's capability — it can only
  # read/progress its own task.
  #
  # Gated by `Arbiter.MCP.inject_config?/0` (off in test by default) and fully
  # best-effort: a missing signing secret or write failure is logged and swallowed
  # so MCP config never blocks a dispatch.
  # No isolated worktree (e.g. a review dispatch running in the repo's shared
  # checkout) → never write the token-bearing `.mcp.json`. Injecting it into the
  # canonical checkout would leak the scope token into the working tree the live
  # server and operator share (bd-dlv3no).
  #
  # Returns `{provider, write_result}` when it attempted a write, `:skipped`
  # otherwise.
  defp maybe_write_mcp_config(_task, nil, _opts, _token), do: :skipped
  defp maybe_write_mcp_config(_task, _worktree_path, _opts, nil), do: :skipped

  defp maybe_write_mcp_config(%Issue{} = task, worktree_path, opts, token)
       when is_binary(worktree_path) do
    if Arbiter.MCP.inject_config?() do
      provider = resolve_mcp_provider(task, opts)

      write_opts =
        [
          mcp_url: Arbiter.MCP.server_url(),
          scope_token: token,
          server_name: Arbiter.MCP.server_name()
        ]
        |> maybe_add_codex_bearer_token_env_var(provider)

      result = Arbiter.MCP.AgentConfig.write(provider, worktree_path, write_opts)
      _ = surface_unsupported_mcp_config(task, provider, result)
      _ = maybe_verify_codex_mcp_connection(task, provider, result, write_opts, worktree_path)
      {provider, result}
    else
      :skipped
    end
  rescue
    e ->
      require Logger
      Logger.warning("Arbiter.Worker.Dispatch: MCP config injection failed: #{inspect(e)}")
      :skipped
  end

  # For Codex, default to env-var mode (bearer_token_env_var) to keep the token off disk.
  # Callers must set this env var in the spawn's environment.
  defp maybe_add_codex_bearer_token_env_var(write_opts, :codex) do
    Keyword.put(write_opts, :bearer_token_env_var, "ARBITER_MCP_TOKEN")
  end

  defp maybe_add_codex_bearer_token_env_var(write_opts, _provider), do: write_opts

  @doc """
  Mint a worker scope token for `task`, write the provider's MCP config into
  `worktree_path`, and return the agent opts that point the spawn at it.

  Returns `[mcp_config: path]` when a Claude `.mcp.json` was written — callers
  merge that into the adapter opts so `Arbiter.Agents.Claude.default_argv/2`
  passes it with `--mcp-config` — and no `:mcp_config` otherwise (injection
  disabled, no isolated worktree, another provider, a failed write).
  Best-effort: never raises, never blocks a spawn.

  Also returns `arb_token: token`, the same worker token, whether or not a
  config file was written (bd-asawcq). `/api` needs a bearer token, so the
  spawn sets it as the agent's `ARB_TOKEN` (`Arbiter.Worker.ClaudeSession`'s
  `:arb_token` opt) and the worker's own `arb` (`arb inbox`, `arb message`,
  `arb ticket update`) authenticates as that one task — never as the
  coordinator.

  Every spawn path that hands an agent an isolated worktree must call this
  (bd-7e8ezw). `FixPassDispatcher` used to skip it, so a CI fix pass ran with
  no MCP config, or with the original run's `.mcp.json` whose 4h worker lease
  had long expired, and reported the `arbiter` server "not connected".

  `opts` honours `:repo`, `:depth`, `:agent_type` and `:agent_adapter` (the
  provider the config is written for; see `resolve_mcp_provider/2`).
  """
  @spec inject_mcp_config(Issue.t(), Path.t() | nil, keyword()) :: keyword()
  def inject_mcp_config(%Issue{} = task, worktree_path, opts) do
    token = mint_worker_token(task, opts)
    mcp_config_opts(task, worktree_path, opts, token) ++ arb_token_opts(token)
  end

  defp arb_token_opts(nil), do: []
  defp arb_token_opts(token), do: [arb_token: token]

  # `:depth` carries the dispatch-recursion depth (Phase 2 guardrail): a worker
  # slung *by a coordinator* via `worker_dispatch` is minted one level deeper, so
  # a chain of dispatches is tracked. Defaults to 0 for a plain operator dispatch.
  # A missing signing secret is logged and swallowed: never blocks a spawn.
  defp mint_worker_token(%Issue{} = task, opts) do
    Arbiter.MCP.Scope.mint_worker(task, Keyword.get(opts, :repo),
      depth: Keyword.get(opts, :depth, 0)
    )
  rescue
    e ->
      require Logger
      Logger.warning("Arbiter.Worker.Dispatch: minting the worker token failed: #{inspect(e)}")
      nil
  end

  defp mcp_config_opts(task, worktree_path, opts, token) do
    case maybe_write_mcp_config(task, worktree_path, opts, token) do
      {:claude, :ok} ->
        [mcp_config: Path.join(worktree_path, Arbiter.MCP.AgentConfig.Claude.filename())]

      # A write was attempted and failed (agy with no isolated `$HOME` →
      # `{:error, :unsupported}`): the session has no Arbiter MCP tools, so the
      # prompt must give it the `arb` CLI fallback for notes/progress. `:skipped`
      # (injection off, no worktree) stays silent — MCP may still arrive via
      # the operator's own config.
      {_provider, {:error, _}} ->
        [mcp_tools?: false]

      _ ->
        []
    end
  end

  # bd-m8geh4: some provider CLIs have no worktree-local MCP config file at all
  # — the `agy` (Antigravity) fork reads MCP servers only from `$HOME`, so a
  # per-spawn scope token has nowhere to live. Its adapter refuses with
  # `{:error, :unsupported}` rather than writing a `.gemini/settings.json` only
  # the *upstream* `gemini` CLI would read. Surface that at dispatch time: a
  # silent no-op is what let agy workers run for weeks with no Arbiter MCP tools
  # and nobody noticing, because the fallback (`arb` CLI) works well enough to
  # hide it.
  #
  # Deliberately NOT fatal: an agy worker without MCP still completes its task
  # through the `arb` CLI. The refusal is a loud capability downgrade, not a
  # dispatch failure.
  defp surface_unsupported_mcp_config(%Issue{id: task_id}, provider, {:error, :unsupported}) do
    require Logger

    Logger.error(
      "Arbiter.Worker.Dispatch: MCP config injection is UNSUPPORTED for provider=#{inspect(provider)} " <>
        "task=#{task_id} (cli=#{inspect(mcp_cli_flavour(provider))}) — this agent's CLI reads MCP " <>
        "config only from $HOME, so no per-spawn scope token can be injected into the worktree. " <>
        "The worker will fall back to the `arb` CLI and will have NO typed Arbiter MCP tools. " <>
        "See Arbiter.MCP.AgentConfig.Gemini's moduledoc."
    )

    :ok
  end

  defp surface_unsupported_mcp_config(_task, _provider, _result), do: :ok

  # Best-effort detail for the log line above: which concrete binary the
  # provider resolved to, when the adapter can tell us.
  defp mcp_cli_flavour(:gemini), do: GeminiMCP.cli_flavour()
  defp mcp_cli_flavour(provider), do: provider

  # Codex MCP support has reports of *silent* connect failures (its own
  # moduledoc: `Arbiter.MCP.AgentConfig.Codex`) — the process starts, the config
  # file is on disk, but the session never actually reaches Arbiter's MCP
  # server, e.g. because the wrong bearer token landed in `.codex/config.toml`.
  # Fire the module's own `verify_connection/1` off the dispatch path right
  # after a successful write so that failure surfaces as a loud log line
  # immediately, instead of only showing up later as a credential-watchdog
  # false positive that requires live debugging to explain (bd-bi5t54).
  defp maybe_verify_codex_mcp_connection(
         %Issue{id: task_id},
         :codex,
         :ok,
         write_opts,
         worktree_path
       ) do
    Task.Supervisor.start_child(Arbiter.Worker.MCPVerifySupervisor, fn ->
      require Logger

      case Codex.verify_connection(write_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Arbiter.Worker.Dispatch: Codex MCP connect check failed for task=#{task_id}: " <>
              inspect(reason) <>
              " — .codex/config.toml was written but the session may never reach Arbiter's MCP server"
          )
      end

      worker_env =
        Arbiter.Agents.Codex.spawn_env(
          arb_token: Keyword.fetch!(write_opts, :scope_token),
          worktree_path: worktree_path
        )

      case Codex.check_worker_config(worktree_path,
             env: worker_env,
             cli_args:
               Arbiter.Agents.Codex.mcp_argv(arb_token: Keyword.fetch!(write_opts, :scope_token)),
             server_name: Keyword.get(write_opts, :server_name, "arbiter")
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Arbiter.Worker.Dispatch: Codex worker-side MCP config check failed for task=#{task_id}: " <>
              inspect(reason)
          )
      end
    end)

    :ok
  end

  defp maybe_verify_codex_mcp_connection(_task, _provider, _write_result, _write_opts, _wt),
    do: :ok

  # Resolve the layered effective skill set for this dispatch (workspace → repo
  # → per-task, with opt-out and code-awareness — see `Arbiter.Skills.Selection`).
  # Only meaningful when an isolated worktree exists: skills materialize into
  # `.claude/skills/` in the worktree, so a nil worktree (review / task-type
  # dispatch) resolves to the empty set. Best-effort — a resolver error must
  # never block a dispatch, so we log and fall back to no skills.
  defp resolve_skills(_task, nil, _opts), do: []

  defp resolve_skills(%Issue{} = task, worktree_path, opts) when is_binary(worktree_path) do
    Arbiter.Skills.Selection.resolve(
      task: task,
      workspace: load_workspace(task),
      repo: Keyword.get(opts, :repo)
    )
  rescue
    e ->
      require Logger
      Logger.warning("Arbiter.Worker.Dispatch: skill resolution failed: #{inspect(e)}")
      []
  end

  # Whether a materialized skill set actually becomes discoverable to the
  # resolved provider's CLI, for `prompt_section/2`'s honesty check
  # (bd-bbbxvp / agy-parity T8). `:gemini` covers two CLIs with different
  # discovery behaviour (`Arbiter.MCP.AgentConfig.Gemini`'s moduledoc): the
  # upstream `gemini` CLI does read a worktree-local skills directory, but
  # `agy` — the CLI Arbiter actually spawns whenever both are on `PATH` — was
  # verified live to discover NOTHING worktree-local in `--print` (headless)
  # mode, including a `.agents/skills/<name>/SKILL.md` planted for that exact
  # probe. So only the non-agy Gemini-family CLI counts as discoverable.
  # `:codex` reads no skills directory at all (bd-89z02x), so it takes the
  # inline path too.
  defp skills_discoverable?(:codex, _opts), do: false
  defp skills_discoverable?(:gemini, opts), do: GeminiMCP.cli_flavour(opts) == :gemini
  defp skills_discoverable?(_provider, _opts), do: true

  @skill_blocking_flags ~w(--bare --disable-slash-commands)

  # Warn loudly if a skill-bearing spawn's argv carries a flag that would make
  # the materialized skills inert (`--bare` skips skill discovery;
  # `--disable-slash-commands` blocks `/name` invocation — spike findings). We
  # never add these flags; this catches a future regression rather than blocking
  # the dispatch, since a warning beats a wedged worker.
  defp guard_skill_flags(_argv, []), do: :ok

  defp guard_skill_flags(argv, _resolved) when is_list(argv) do
    case Enum.filter(@skill_blocking_flags, &(&1 in argv)) do
      [] ->
        :ok

      offending ->
        require Logger

        Logger.warning(
          "Arbiter.Worker.Dispatch: dispatching a skill-bearing worker with " <>
            "#{Enum.join(offending, ", ")} — materialized skills will not be " <>
            "discovered/invocable. This should never happen; check argv assembly."
        )
    end
  end

  defp guard_skill_flags(_argv, _resolved), do: :ok

  # Resolve which agent-config adapter to inject (.mcp.json vs .gemini/settings.json
  # vs .codex/config.toml). Resolution mirrors `preflight_adapter/3` so a dispatch that
  # forces a provider (`--provider gemini` / `agent_type: :gemini`) writes *that*
  # provider's config rather than the workspace default:
  #   1. `:agent_adapter` test override.
  #   2. `:agent_type` explicit provider override.
  #   3. Workspace default via `Agents.for_workspace`.
  # Falls back to :claude on any error so a misconfigured workspace never blocks a
  # dispatch — but logs the real exception first (bd-bi5t54): a bare `rescue _ ->
  # :claude` here previously swallowed whatever actually raised, so an explicit
  # `agent_type: :codex` dispatch that hit this clause would silently write
  # Claude's `.mcp.json` into the worktree with zero signal as to why, and Codex
  # would then 401 on its MCP handshake with nothing pointing back here.
  defp resolve_mcp_provider(%Issue{} = task, opts) do
    adapter =
      case Keyword.get(opts, :agent_adapter) do
        mod when is_atom(mod) and not is_nil(mod) ->
          mod

        _ ->
          case Keyword.get(opts, :agent_type) do
            type when is_atom(type) and not is_nil(type) -> Agents.for_type(type)
            _ -> Agents.for_workspace(load_workspace(task))
          end
      end

    String.to_existing_atom(adapter.provider())
  rescue
    e ->
      require Logger

      Logger.error(
        "Arbiter.Worker.Dispatch: resolve_mcp_provider fell back to :claude for task=#{task.id} " <>
          "(opts agent_type=#{inspect(Keyword.get(opts, :agent_type))}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      :claude
  end

  defp load_workspace(%Issue{workspace_id: nil}), do: nil

  defp load_workspace(%Issue{workspace_id: ws_id}) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def prompt_for(%Issue{} = task), do: PromptBuilder.prompt_for(task)

  @doc false
  def prompt_for_task(%Issue{} = task, opts), do: PromptBuilder.prompt_for_task(task, opts)

  @doc """
  Briefing for a **conflict-resolve** worker (#354, Phase 2b). See
  `Arbiter.Worker.PromptBuilder.conflict_resolve_briefing/3`.
  """
  @spec conflict_resolve_briefing(Issue.t(), String.t(), String.t()) :: String.t()
  def conflict_resolve_briefing(%Issue{} = task, branch, target_branch)
      when is_binary(branch) and is_binary(target_branch) do
    PromptBuilder.conflict_resolve_briefing(task, branch, target_branch)
  end

  # Fetch acceptance-criteria context from a tracker issue referenced by
  # `tracker_context_type` + `tracker_context_ref` on the task. Read-only:
  # no assignment check, no write-back, no claim. Returns a map with
  # `:ref`, `:type`, `:title`, `:description` on success, or `nil` when the
  # task has no context ref or the fetch fails (failures are logged and
  # swallowed — context is best-effort).
  defp fetch_tracker_context(
         %Issue{tracker_context_type: type, tracker_context_ref: ref} = _task,
         workspace
       )
       when type not in [nil, :none] and is_binary(ref) and ref != "" do
    adapter = Trackers.for_type(type)

    Trackers.with_workspace(type, workspace, fn ->
      case adapter.fetch(ref) do
        {:ok, raw} ->
          %{
            ref: ref,
            type: type,
            title: adapter.extract_title(raw),
            description: adapter.extract_description(raw)
          }

        {:error, reason} ->
          require Logger

          Logger.warning(
            "Dispatch: failed to fetch tracker context #{type}:#{ref}: #{inspect(reason)}"
          )

          nil
      end
    end)
  rescue
    e ->
      require Logger
      Logger.warning("Dispatch: error fetching tracker context: #{Exception.message(e)}")
      nil
  end

  defp fetch_tracker_context(_task, _workspace), do: nil

  defp maybe_start_driver(
         %Issue{id: id},
         worker_pid,
         machine_id,
         machine_pid,
         worktree_path,
         opts
       ) do
    case Keyword.get(opts, :start_driver, true) do
      false ->
        {:ok, nil}

      true ->
        # When Claude is in charge of doing the real work, the Driver
        # waits on the worker's completion instead of ticking the
        # bookkeeping Machine to closure. This avoids the race where the
        # no-op workflow's 5 steps finish in ~500ms and close the task
        # before Claude has time to respond.
        claude_driven =
          Keyword.get(opts, :claude_driven, Keyword.get(opts, :start_claude, false))

        driver_opts =
          [
            task_id: id,
            worker_pid: worker_pid,
            machine_id: machine_id,
            machine_pid: machine_pid,
            worktree_path: worktree_path,
            cleanup_worktree: Keyword.get(opts, :cleanup_worktree, true),
            # bd-199giy: the reviewer's throwaway checkout, if one was
            # provisioned. The Driver owns its teardown because it is the
            # component that outlives the agent session.
            review_checkout_path: review_checkout_path(opts),
            claude_driven: claude_driven
          ]
          |> maybe_put_opt(opts, :interval_ms)
          |> maybe_put_opt(opts, :max_ticks)

        case Driver.start(driver_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, reason} -> {:error, {:driver_start_failed, reason}}
        end
    end
  end

  defp maybe_put_opt(driver_opts, dispatch_opts, key) do
    case Keyword.fetch(dispatch_opts, key) do
      {:ok, val} -> Keyword.put(driver_opts, key, val)
      :error -> driver_opts
    end
  end
end
