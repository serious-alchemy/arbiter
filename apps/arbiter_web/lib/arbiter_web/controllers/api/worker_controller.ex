defmodule ArbiterWeb.Api.WorkerController do
  @moduledoc """
  REST endpoints for worker lifecycle. The arb CLI calls `dispatch/2` to
  start work on a task; future LiveView dashboards will use the same
  endpoints + `list/2` to introspect running workers.

  Routes:

    * `POST /api/workers/dispatch`           — :dispatch (body: `task_id`, optional `repo`, `provider`).
      `provider` is any of `Arbiter.Agents.valid_agent_types/0` (deprecated
      aliases: `with_claude` / `with_gemini` booleans). With a provider a worker
      subprocess works the task and the Driver closes it on `arb done`; with
      `no_agent` the task parks in `:active` (no Driver) — and `no_agent` plus a
      provider is a 400, never half-honoured. Every dispatch/resume/review
      parameter goes through `Arbiter.Worker.Dispatch.Params`, shared with the MCP
      tools: an unknown argument is a 400, the recursion-depth limit applies, and
      a `force_quota` bypass is attributed to the token's actor.
    * `POST /api/workers/review`          — :review.
      Two shapes: (a) `task_id` (+ optional `repo`) dispatches a review-only
      worker against the PR/MR linked to a task — no worktree, no per-task
      branch, no merge-queue route, always claude-driven. (b) `pr` (URL or
      number, + optional `repo`/`workspace`) reviews an **external / non-arbiter
      PR** via the MR adapter (`Arbiter.Reviews.ExternalReview`): no task, no
      branch — findings + a verdict are posted to that PR.
    * `GET  /api/workers`                 — :index. Every ticket with a live run,
      as its current run (`Arbiter.Workers.Current.list/1`). Optional
      `workspace_id` scopes it to the tickets of one workspace — a ReviewGate
      reviewer's run included, though its worker carries no workspace itself.
    * `GET  /api/workers/:task_id`        — :show. The ticket's current run
      (full detail inc. recent output) plus its recent runs, each labelled with
      its kind (`Arbiter.Workers.Current.show/2`). The current run is read by
      the same function `:index` reads, in the same vocabulary — kind / state /
      outcome (`Arbiter.Workers.RunState`) — live or not. `?lines=N` bounds the
      output tail. Both render through `Arbiter.Workers.Serializer`, as MCP does.
    * `POST /api/workers/:task_id/resume` — :resume (bd-1z7624, #472).
      Session-level resume: re-spawns the worker continuing the task's PRIOR
      Claude session (`claude --print --resume <session_id>`) in the SAME
      preserved worktree. Refuses (pointing at `arb dispatch`) when no prior
      session/worktree exists — never silently starts fresh. `mode: "briefing"`
      opts into a fresh agent briefed from the worktree's git state instead.
    * `POST /api/workers/:task_id/stop`   — :stop (terminate worker cleanly)
    * `GET  /api/workers/:task_id/log`    — :log (full, uncapped durable
      transcript of the task's most recent run; the audit source of record).
      `task_id` may be a ReviewGate synthetic id (`<base>#review`, `#r<N>`,
      `#impl<N>`, `#v<N>`, `#t<N>`, percent-encoded in the path). `?tail=N` keeps
      only the last N lines. Pass
      `?run_id=` to read that exact run instead of the task's latest.
    * `GET  /api/workers/:task_id/prompt`  — :prompt (bd-9rdwe4). The composed
      prompt the run's most recent (or `?run_id=`-selected) session was spawned
      with, redacted the same way the transcript is. Sibling of `:log`.
    * `GET  /api/workers/:task_id/run_log_list` — :run_log_list. Every run
      for `task_id` plus its ReviewGate synthetic children, newest first,
      with `transcript_exists`/`line_count` (no full transcript — use
      `:log` for that).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Params
  alias Arbiter.Reviews.ExternalReview
  alias Arbiter.Reviews.Guard
  alias Arbiter.Reviews.Params, as: ReviewParams
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.Dispatch.Params, as: DispatchParams

  alias Arbiter.Workers.Current
  alias Arbiter.Workers.Run
  alias Arbiter.Workers.Runs
  alias Arbiter.Workers.Serializer
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  def dispatch(conn, params) do
    with :ok <- ensure_dispatch_allowed(conn) do
      case params do
        %{"task_id" => task_id} when is_binary(task_id) and task_id != "" ->
          with {:ok, opts} <- normalize(conn, :dispatch, params) do
            dispatch_task(conn, task_id, opts)
          end

        _ ->
          {:error, {:invalid_request, "task_id is required", %{}}}
      end
    end
  end

  # Who may dispatch, review or resume is decided before this runs, by
  # `ArbiterWeb.ApiPolicy`'s `:dispatch` rule: a coordinator-tier token with
  # `can_dispatch`, the same guardrail as `Arbiter.MCP.Tools.ensure_can_dispatch/1`
  # on the MCP tools, so a session denied dispatch over MCP cannot curl these
  # routes with its own token instead (bd-5b5hq7). This repeats it in the
  # controller as defense in depth. An anonymous caller never reaches here
  # since bd-asawcq; if one somehow did, it is refused, not waved through.
  defp ensure_dispatch_allowed(conn) do
    case conn.assigns[:mcp_scope] do
      %Arbiter.MCP.Scope{tier: :coordinator, can_dispatch: true} ->
        :ok

      _ ->
        {:error, {:unauthorized, "this token may not dispatch (can_dispatch is not set)"}}
    end
  end

  defp dispatch_task(conn, task_id, opts) do
    case Dispatch.dispatch(task_id, opts) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> render(:dispatch, result: result)

      {:error, reason} ->
        refusal(reason, task_id, :dispatch)
    end
  end

  @doc """
  Dispatch a review-only issue. The task is slung with `review: true`,
  which forces the `CodeReview` workflow, skips worktree provisioning, swaps
  the work prompt for the review prompt, and tags the worker as
  `review_only` so completion does not fan out to the merge queue/merger.

  Always claude-driven (`start_claude: true`) — a review without an agent has
  nothing to do.
  """
  # Pre-existing complexity 12 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def review(conn, params) do
    with :ok <- ensure_dispatch_allowed(conn) do
      case params do
        # External / non-arbiter PR review (bd-d4ealy): no task, no branch — point
        # the reviewer at an arbitrary PR by URL/number through the MR adapter.
        %{"pr" => pr} when is_binary(pr) and pr != "" ->
          review_external(conn, params)

        %{"task_id" => task_id} when is_binary(task_id) and task_id != "" ->
          review_task(conn, task_id, params)

        _ ->
          {:error, {:invalid_request, "task_id or pr is required", %{}}}
      end
    end
  end

  # Task-shaped review. Runs the same `review_automation` guard as the
  # `worker_review` MCP tool (`Arbiter.Reviews.Guard`, resolved from the TASK's
  # workspace): an `off` repo is refused unless `force` is set, nothing is
  # written or spawned on a refusal. An unknown task skips the guard and falls
  # through to `Dispatch`, which answers 404 as it always has.
  defp review_task(conn, task_id, params) do
    with {:ok, opts} <- normalize(conn, :review, params),
         {:ok, _task} <- guard_task_review(task_id, params) do
      case Dispatch.dispatch(task_id, opts) do
        {:ok, result} ->
          conn
          |> put_status(:created)
          |> render(:dispatch, result: result)

        {:error, reason} ->
          refusal(reason, task_id, :review)
      end
    end
  end

  defp guard_task_review(task_id, params) do
    case Ash.get(Arbiter.Tasks.Issue, task_id) do
      {:ok, task} -> Guard.prepare(task, params, truthy(params["force"]) == true)
      {:error, _} -> {:ok, nil}
    end
  end

  # External / non-arbiter PR review (bd-d4ealy). Validates synchronously
  # (workspace + MR adapter + PR ref) so a bad PR / unsupported strategy 422s
  # immediately, then runs the CodeReview adapter workflow in the background and
  # acks with the resolved mr_ref + link. `repo`/`workspace` are optional.
  defp review_external(conn, params) do
    with :ok <- DispatchParams.ensure_depth(conn.assigns[:mcp_scope]),
         {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      do_review_external(conn, params, ws_id)
    end
  end

  defp do_review_external(conn, params, ws_id) do
    # One normaliser behind MCP and REST (P-12, D-W-6): `force`, `follow_up`,
    # `scope`, `report_only` and `tracker_context_*` reach ExternalReview from
    # here exactly as they do from `worker_review pr:`. `report_only` (propose)
    # / `automation` resolve whether the review posts to the PR or only reports
    # (bd-36qzgx).
    with {:ok, opts} <-
           params
           |> ReviewParams.dispatch_opts(workspace: ws_id, dispatched_by: "http_api")
           |> Params.to_rest() do
      case ExternalReview.dispatch(opts) do
        {:ok, ack} ->
          conn
          |> put_status(:created)
          |> json(%{data: ack})

        {:error, reason} ->
          {:error, {:invalid_request, ExternalReview.describe_error(reason), %{pr: params["pr"]}}}
      end
    end
  end

  @doc """
  Resume a stopped worker at the SESSION level (bd-1z7624, #472). Re-spawns the
  worker continuing the task's PRIOR Claude session via `claude --print --resume
  <session_id>` in the SAME preserved worktree, so the original mind picks up
  where it left off — distinct from `arb dispatch` (a fresh session + worktree).

  Backed by `Arbiter.Worker.Dispatch.resume_session/2`, which looks up the
  task's most-recent captured `session_id` + preserved worktree and re-spawns
  through the bd-t9uq25 resume path. Refuses with a clear error (pointing at
  `arb dispatch`) when there is no resumable prior session or worktree — it
  never silently starts fresh. Always claude-driven; renders the same payload
  as `dispatch/2`.
  """
  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def resume(conn, %{"task_id" => task_id} = params)
      when is_binary(task_id) and task_id != "" do
    with :ok <- ensure_dispatch_allowed(conn),
         {:ok, opts} <- normalize(conn, :resume, params) do
      resume_task(conn, task_id, opts)
    end
  end

  def resume(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # `opts[:resume_mode]` is `:session` unless the caller asked for `mode:
  # "briefing"`, so the default is the same `--resume <session>` MCP runs.
  defp resume_task(conn, task_id, opts) do
    case Dispatch.resume_task(task_id, opts) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> render(:dispatch, result: result)

      {:error, reason} ->
        refusal(reason, task_id, :resume)
    end
  end

  # One mapping for every refusal `Dispatch.dispatch/2` and `resume_session/2`
  # return (bd-5fc29i). The kind comes from `Dispatch.refusal_kind/1` — the
  # same classifier the MCP tools use — so a closed ticket, a live session or a
  # full account is a 409 `conflict` whichever verb hit it, a bad repo is a 422,
  # a migrating server is a 503 `busy`, and nothing falls to a bare 500 with the
  # real reason hidden in `details`.
  defp refusal({:task_not_found, _}, _task_id, _verb), do: {:error, :not_found}

  defp refusal(reason, task_id, verb) do
    case refusal_text(reason, task_id, verb) do
      {message, details} ->
        {:error, {Dispatch.refusal_kind(reason), message, details}}

      nil ->
        {:error, {:server_error, "#{verb_label(verb)} failed", %{reason: inspect(reason)}}}
    end
  end

  defp verb_label(:dispatch), do: "dispatch"
  defp verb_label(:review), do: "review dispatch"
  defp verb_label(:resume), do: "resume"

  defp gerund(:dispatch), do: "dispatching"
  defp gerund(:review), do: "reviewing"
  defp gerund(:resume), do: "resuming"

  # A review is a dispatch as far as "refused" reads.
  defp noun(:resume), do: "resume"
  defp noun(_verb), do: "dispatch"

  defp refusal_text({:task_closed, _}, task_id, verb),
    do: {"task is closed; reopen it before #{gerund(verb)}", %{task_id: task_id}}

  # bd-asxw4e: a Backlog or Blocked ticket, dispatched without `force`.
  defp refusal_text({:not_dispatchable, _, hold}, task_id, _verb),
    do:
      {Dispatch.refusal_message(task_id, hold),
       %{task_id: task_id, reason: Arbiter.Tasks.Lifecycle.describe_hold(hold)}}

  defp refusal_text({:task_awaiting_review, _}, task_id, :review),
    do:
      {"task is already awaiting review; a Watchdog is active and will close it on MR merge",
       %{task_id: task_id}}

  defp refusal_text({:task_awaiting_review, _}, task_id, _verb),
    do:
      {"task is already awaiting review; the Watchdog will close it on MR merge",
       %{task_id: task_id}}

  # bd-aw325c: the pause gate or the quota gate held it; the message names which
  # and carries the window/used/threshold numbers.
  defp refusal_text({:quota_held, _}, task_id, _verb),
    do: {Dispatch.quota_held_message(task_id), %{task_id: task_id}}

  # bd-8suxac: the provider account the run would use has no free slot — the
  # request is fine, the fleet's state refuses it. `over_cap`
  # (`arb dispatch --over-cap`) overrides.
  defp refusal_text({:account_at_capacity, info}, task_id, _verb),
    do:
      {Arbiter.Accounts.Admission.refusal_message(info),
       %{task_id: task_id, account: info.account, cap: info.cap, holders: info.holders}}

  # RW8: no node has a free slot (`remote_only`), or the primary's own cap holds
  # a local run. Held, not failed — it starts when capacity frees.
  defp refusal_text({:no_node_capacity, info}, task_id, _verb),
    do:
      {Arbiter.Nodes.Placement.refusal_message(info),
       %{
         task_id: task_id,
         node: info[:node],
         mode: info[:mode] && to_string(info.mode),
         cap: info[:cap],
         holders: info[:holders] || []
       }}

  # bd-13pqcp: the ticket's provider constraint leaves no eligible provider (or
  # the one named is excluded).
  defp refusal_text({:provider_constraint, provider, phrase}, task_id, verb),
    do:
      {"#{phrase} — #{noun(verb)} refused; it never runs on an excluded provider",
       %{task_id: task_id, provider: provider && to_string(provider)}}

  # bd-atll60 (G13): no model is eligible for the ticket under its guardrails.
  defp refusal_text({:guardrail_ineligible, provider, phrase}, task_id, verb),
    do:
      {"#{phrase} — #{noun(verb)} refused; it never runs on a model its guardrails rule out",
       %{task_id: task_id, provider: provider && to_string(provider)}}

  # bd-57uzkl: the provider lacks a capability the role or repo requires.
  defp refusal_text({:capability_missing, provider, phrase}, task_id, verb),
    do:
      {"#{phrase} — #{noun(verb)} refused",
       %{task_id: task_id, provider: provider && to_string(provider)}}

  # bd-c675ny: the model it would run is below the repo's routing floor.
  defp refusal_text({:below_floor, provider, phrase}, task_id, verb),
    do:
      {"#{phrase} — #{noun(verb)} refused",
       %{task_id: task_id, provider: provider && to_string(provider)}}

  # bd-2aslx6 (#1428): a second agent-spawning dispatch onto a task whose worker
  # is mid-session is refused, naming the live session so a retrying caller can
  # tell "still busy" from a bad request.
  defp refusal_text({:agent_session_active, _}, task_id, verb),
    do:
      {"task already has a live agent session; wait for it to finish or stop the " <>
         "worker before " <>
         if(verb == :review, do: "dispatching a review", else: "dispatching again"),
       %{task_id: task_id}}

  defp refusal_text(:no_repo_configured, task_id, _verb),
    do:
      {"no repos configured — add at least one repo to your workspace config " <>
         "(repo_paths) or application env (:arbiter, :repo_paths), " <>
         "or pass a repo explicitly: `arb ticket dispatch #{task_id} <repo>`",
       %{task_id: task_id}}

  defp refusal_text({:repo_not_found, repo}, task_id, _verb),
    do:
      {"repo #{inspect(repo)} is not in :repo_paths — check your workspace config or " <>
         "application env (:arbiter, :repo_paths)", %{task_id: task_id, repo: repo}}

  defp refusal_text({:ambiguous_repo, repos}, task_id, _verb),
    do:
      {"multiple repos available (#{Enum.join(repos, ", ")}) — specify one: " <>
         "`arb ticket dispatch #{task_id} <repo>`", %{task_id: task_id, available_repos: repos}}

  # The server is applying schema changes: transient, so a 503 `busy`.
  defp refusal_text({:pending_migrations, count}, task_id, _verb),
    do:
      {"#{count} pending migration(s) — the server is currently applying schema changes. " <>
         "Wait for the deployment to complete before dispatching work.",
       %{task_id: task_id, pending_migrations: count}}

  # The migration check itself failed (database unreachable, odd shape): the
  # dispatcher fails closed, and so is a retryable `busy`, not a bug.
  defp refusal_text({:migrations_check_failed, reason}, task_id, _verb),
    do:
      {"could not verify the database schema is current — retry shortly",
       %{task_id: task_id, reason: inspect(reason)}}

  defp refusal_text(:no_outpost, task_id, _verb),
    do:
      {"no preserved worktree for this task — nothing to resume; start fresh with " <>
         "`arb dispatch #{task_id}`", %{task_id: task_id}}

  defp refusal_text(:no_session, task_id, _verb),
    do:
      {"no prior Claude session recorded for this task — nothing to resume at the " <>
         "session level; start fresh with `arb dispatch #{task_id}`", %{task_id: task_id}}

  defp refusal_text(:repo_unknown, task_id, _verb),
    do:
      {"could not resolve the repo for this task; pass it explicitly: `arb worker resume <task> <repo>`",
       %{task_id: task_id}}

  defp refusal_text({:worker_active, status}, task_id, _verb),
    do: {Dispatch.worker_active_message(status, task_id), %{task_id: task_id}}

  # bd-92mx1m: the task released its slot and the cap is full; `force`
  # (`arb worker resume --force`) overrides.
  defp refusal_text({:slot_cap_full, info}, task_id, _verb),
    do:
      {Arbiter.Worker.ResumeSlot.refusal_message(info),
       %{task_id: task_id, cap: info.cap, holders: info.holders}}

  defp refusal_text(_reason, _task_id, _verb), do: nil

  # ---- read side ---------------------------------------------------------
  #
  # Payloads are `Arbiter.Workers.Serializer`'s, the module MCP renders with;
  # run queries and caps are `Arbiter.Workers.Runs`. A token bound to one
  # workspace reads only that workspace's tasks and runs (D-W-25): another's is
  # a 404, never a 403, so existence does not leak.

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      runs = Current.list(workspace_id: ws_id)
      # bd-8vnuy3: settled + in-flight spend, per task — the issue page's figure.
      render(conn, :index, runs: runs, costs: Serializer.costs(runs), workspace_id: ws_id)
    end
  end

  def show(conn, %{"task_id" => task_id} = params) when is_binary(task_id) and task_id != "" do
    with {:ok, lines} <- positive(params["lines"], "lines"),
         :ok <- authorize_task(conn, task_id) do
      case Current.show(task_id) do
        %{current: current, runs: runs} ->
          render(conn, :show,
            current: current,
            runs: runs,
            lines: lines,
            cost: Serializer.task_cost(task_id)
          )

        nil ->
          {:error, :not_found}
      end
    end
  end

  def show(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  def stop(conn, %{"task_id" => task_id}) when is_binary(task_id) and task_id != "" do
    with :ok <- authorize_task(conn, task_id) do
      case Worker.operator_stop(task_id) do
        :ok ->
          conn
          |> put_status(:ok)
          |> json(%{task_id: task_id, stopped: true})

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  def stop(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # Durable transcript of one run (the audit source of record): the task's most
  # recent run, or — with `?run_id=` — that exact run, the only way to reach a
  # superseded/failed attempt once a later run exists. A `run_id` that is not an
  # attempt at the path task is a 404 (D-W-12). The whole transcript unless
  # `?tail=N` asks for the last N lines (`line_count` is the true total,
  # `truncated` says whether `lines` is shorter). `exists` distinguishes "no file
  # yet / never captured" (false, lines []) from "captured but empty" (true,
  # lines []). 404 when no matching run exists.
  def log(conn, %{"task_id" => task_id} = params) when is_binary(task_id) and task_id != "" do
    with {:ok, tail} <- positive(params["tail"], "tail"),
         {:ok, run} <- select_run(conn, task_id, params["run_id"]) do
      json(conn, %{data: Serializer.log(run, tail: tail)})
    end
  end

  def log(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # The composed prompt one run was spawned with (bd-9rdwe4, #1017 gap G5),
  # redacted through the same choke-point as transcript lines. Sibling of
  # `:log` — identical `run_id`/`task_id` selection rule. `exists`
  # distinguishes "no prompt was ever persisted for this run" (false, `prompt`
  # nil) from a captured one. 404 when no matching run exists.
  def prompt(conn, %{"task_id" => task_id} = params) when is_binary(task_id) and task_id != "" do
    with {:ok, run} <- select_run(conn, task_id, params["run_id"]) do
      json(conn, %{data: Serializer.prompt(run)})
    end
  end

  def prompt(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # Every run recorded for `task_id` AND its ReviewGate synthetic children
  # (`<task_id>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`), newest first
  # — the whole retrievable transcript corpus for a task in one call.
  # `transcript_exists` distinguishes a missing durable log from an empty one
  # without a separate `:log` call.
  def run_log_list(conn, %{"task_id" => task_id} = params)
      when is_binary(task_id) and task_id != "" do
    with {:ok, limit} <- params["limit"] |> Runs.corpus_limit() |> Params.to_rest(),
         :ok <- authorize_task(conn, task_id) do
      json(conn, %{data: task_id |> Runs.corpus(limit) |> Enum.map(&Serializer.run_log_entry/1)})
    end
  end

  def run_log_list(_conn, _params), do: {:error, {:invalid_request, "task_id is required", %{}}}

  # The run `log` / `prompt` serve: the task's latest, or `run_id` when it is an
  # attempt at the path task and lives where the caller may read.
  defp select_run(conn, task_id, run_id) when run_id in [nil, ""] do
    with :ok <- authorize_task(conn, task_id) do
      case Runs.latest(task_id) do
        %Run{} = run -> {:ok, run}
        nil -> {:error, :not_found}
      end
    end
  end

  defp select_run(conn, task_id, run_id) do
    with {:ok, %Run{} = run} <- Runs.get(run_id),
         true <- Runs.belongs_to_task?(run, task_id),
         :ok <- authorize_workspace(conn, run.workspace_id) do
      {:ok, run}
    else
      _ -> {:error, :not_found}
    end
  end

  # D-W-25: confine a workspace-bound token to its own workspace. An unbound
  # coordinator (`{:ok, nil}`) reads everywhere.
  defp authorize_task(conn, task_id) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, %{}, :read) do
      if is_nil(ws_id) or Runs.task_workspace_id(task_id) == ws_id,
        do: :ok,
        else: {:error, :not_found}
    end
  end

  defp authorize_workspace(conn, run_workspace_id) do
    case WorkspaceParam.resolve(conn, %{}, :read) do
      {:ok, nil} -> :ok
      {:ok, ^run_workspace_id} -> :ok
      _ -> {:error, :not_found}
    end
  end

  defp positive(raw, _name) when raw in [nil, ""], do: {:ok, nil}

  defp positive(raw, name) do
    case Params.integer(raw) do
      {:ok, n} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "#{name} must be a positive integer"}}
    end
  end

  # The one dispatch/resume/review param normaliser, shared with the MCP tools
  # (`Arbiter.Worker.Dispatch.Params`): unknown arguments, a junk boolean, an
  # unknown provider, `no_agent` combined with a provider, the recursion-depth
  # limit — all refused here, before anything is written or spawned.
  defp normalize(conn, verb, params) do
    case DispatchParams.normalize(params,
           verb: verb,
           scope: conn.assigns[:mcp_scope],
           surface: :rest
         ) do
      {:ok, opts} -> {:ok, opts}
      {:error, {:invalid, message}} -> {:error, {:invalid_request, message, %{}}}
      {:error, {:unauthorized, _message}} = err -> err
    end
  end

  defp truthy(value) do
    case Params.boolean(value) do
      {:ok, bool} -> bool
      :error -> nil
    end
  end
end
