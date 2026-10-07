defmodule Arbiter.MCP.Tools.Worker do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the worker lifecycle: `worker_dispatch` /
  `worker_resume` / `worker_review` / `worker_stop` / `worker_list` /
  `worker_show` / `worker_runs` / `worker_log` / `worker_prompt` /
  `run_log_list` / `transcript_capture_stats`. Split out of
  `Arbiter.MCP.Tools` (see its moduledoc) — called back into for the generic
  arg/serialization helpers, `ensure_can_dispatch/1`, and `parse_bounded_limit/4`
  it still owns (the latter two are shared with `review_greenlight` /
  `external_review_list`, which stayed in `Arbiter.MCP.Tools`).
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Reviews.Guard
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.Dispatch.Params
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workers.Current

  require Ash.Query
  require Logger

  @corpus_start_date ~U[2026-06-20 00:00:00Z]

  # ---- worker_dispatch ------------------------------------------------------

  @doc """
  Dispatch a worker to work a task in the scope's workspace. **Coordinator only,
  and the strongest-gated tool.** It enforces the dispatch-recursion guardrail
  (`docs/mcp-server-design.md` §4.3):

    1. The scope must carry `can_dispatch` — a coordinator minted without it (and
       every worker, which never carries it) is refused.
    2. The scope's `depth` must be below the configured `Arbiter.MCP.max_depth/0`
       — cheap insurance against a misconfigured coordinator fan-out.

  The slung worker's own scope token is minted one level deeper (`depth + 1`),
  so a chain of dispatches is tracked. When `provider` is omitted, the workspace's
  `agent.type` config is consulted and the first healthy provider is selected via
  `ProviderPool` — identical to the REST dispatch default. Pass an explicit
  `provider` (any of `Arbiter.Agents.valid_agent_types/0`, or the deprecated
  `with_claude` / `with_gemini` aliases) to override. Set `no_agent: true` to move
  the task to `:active` without spawning a worker (hand-off / manual-attach path);
  it cannot be combined with a provider. An unknown provider or argument is an
  error, never a silent fall-through to the workspace default
  (`Arbiter.Worker.Dispatch.Params`).
  Backs onto `Arbiter.Worker.Dispatch.dispatch/2`.
  """
  @spec worker_dispatch(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_dispatch(%Scope{} = scope, args) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         {:ok, opts} <- normalize(:dispatch, scope, args),
         {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id) do
      case Dispatch.dispatch(task_id, opts) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> dispatch_error(reason, task_id)
      end
    end
  end

  # ---- worker_resume -----------------------------------------------------

  @doc """
  Resume a stopped worker (`arb worker resume`): continue the task's PRIOR
  session (`claude --resume <session_id>`) in its **preserved** worktree — the same
  operation as `POST /api/workers/:task_id/resume`, `Dispatch.resume_session/2`.
  `mode: "briefing"` is the explicit opt-in for the other variant, a fresh agent
  briefed from the worktree's git state (`Dispatch.resume/2`). Coordinator only,
  and — like `worker_dispatch` — gated by the
  dispatch-recursion guardrail (`can_dispatch` + `depth`): resume spawns a worker, so
  the same recursion concerns apply. The child worker's scope is minted one
  level deeper. Backs onto `Arbiter.Worker.Dispatch.resume_task/2`.

  bd-92mx1m: a task that released its slot (parked for a human, stopped,
  completed) re-acquires one like a new admission. At a full cap the resume is
  refused with a message naming the cap and the tasks holding it; `force:
  true` goes over the cap, and the override is recorded
  (`Arbiter.Worker.ResumeSlot`).
  """
  @spec worker_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_resume(%Scope{} = scope, args) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         {:ok, opts} <- normalize(:resume, scope, args),
         {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id) do
      case Dispatch.resume_task(task_id, opts) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> dispatch_error(reason, task_id)
      end
    end
  end

  # ---- worker_review -----------------------------------------------------

  @doc """
  Dispatch a **review-only** worker (`arb review`): no worktree, no per-task
  branch, no route through the merge queue/merger. Coordinator only, and gated
  by the dispatch-recursion guardrail (`can_dispatch` + `depth`) — a review
  spawns an agent.

  Two shapes:

    * `task_id` → review the PR/MR linked to a task. Backs onto
      `Arbiter.Worker.Dispatch.dispatch/2` with `review: true`; the child
      worker's scope is minted one level deeper.
    * `pr` (URL or number, + optional `repo`/`workspace`) → review an
      **external / non-arbiter PR** through the MR adapter
      (`Arbiter.Reviews.ExternalReview`): no task, no branch. Findings + a
      verdict are posted to the PR.
  """
  @spec worker_review(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_review(%Scope{} = scope, args) do
    case Tools.fetch_string(args, "pr") do
      pr when is_binary(pr) -> worker_review_external(scope, args, pr)
      _ -> worker_review_task(scope, args)
    end
  end

  defp worker_review_task(%Scope{} = scope, args) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         {:ok, opts} <- normalize(:review, scope, args),
         {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, task} <- Tools.fetch_task(scope, args, task_id),
         {:ok, force} <- Tools.fetch_bool(args, "force", false),
         # The guard reads the TASK's workspace config (never the caller's
         # bound workspace, nil for a normal coordinator token) and refuses
         # before anything is written or spawned — see `Arbiter.Reviews.Guard`.
         {:ok, _task} <- Guard.prepare(task, args, force) do
      case Dispatch.dispatch(task_id, opts) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> dispatch_error(reason, task_id)
      end
    end
  end

  # External PR review: same dispatch gating (it spawns a reviewer), but resolves
  # the MR provider from the (scope-bound or named) workspace rather than a task.
  #
  # `follow_up` (Option A, bd-2ovun1) makes the review adopt the PR into
  # ReviewPatrol by opening a review_only engagement after the verdict posts.
  # When the arg is omitted, ExternalReview engages by default only if the
  # workspace has a ReviewPatrol running. `automation` / `tracker_context_*`
  # mirror the task-review path and are carried onto that engagement.
  defp worker_review_external(%Scope{} = scope, args, pr) do
    with :ok <- Tools.ensure_can_dispatch(scope),
         :ok <- Params.ensure_depth(scope),
         {:ok, ws_ref} <- Tools.authorized_workspace(scope, args),
         {:ok, follow_up} <- Tools.fetch_optional_bool(args, "follow_up"),
         {:ok, force} <- Tools.fetch_optional_bool(args, "force") do
      opts =
        [
          pr: pr,
          repo: Tools.fetch_string(args, "repo"),
          workspace: ws_ref,
          automation: Tools.fetch_string(args, "automation"),
          tracker_context_ref: Tools.fetch_string(args, "tracker_context_ref"),
          tracker_context_type: Tools.fetch_string(args, "tracker_context_type"),
          dispatched_by: "mcp"
        ]
        |> Tools.maybe_put_kw(:follow_up, follow_up)
        |> Tools.maybe_put_kw(:force, force)
        |> Tools.maybe_put_kw(:scope, Tools.fetch_string(args, "scope"))

      case Arbiter.Reviews.ExternalReview.dispatch(opts) do
        {:ok, ack} ->
          {:ok, ack}

        {:error, reason} ->
          {:error, {:invalid, Arbiter.Reviews.ExternalReview.describe_error(reason)}}
      end
    end
  end

  # ---- worker_stop -------------------------------------------------------

  @doc """
  Stop the worker currently working a task (`arb worker stop`). Coordinator
  only. The task is resolved through `fetch_task`, so a coordinator can only
  stop workers for tasks in its own workspace; a task with no live worker is
  reported as not-found. Stopping is teardown — it never spawns — so it does not
  require `can_dispatch`. Backs onto `Arbiter.Worker.stop/2`.
  """
  @spec worker_stop(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_stop(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id) do
      case Worker.operator_stop(task_id) do
        :ok -> {:ok, %{task_id: task_id, stopped: true}}
        {:error, :not_found} -> {:error, {:not_found, "no running worker for task #{task_id}"}}
      end
    end
  end

  # ---- worker_list -------------------------------------------------------

  @doc """
  List the scope's workspace's tickets with a live run, each as its current
  run (bd-1uu19b). Coordinator only. Backs onto
  `Arbiter.Workers.Current.list/1` — the same read `worker_show` makes —
  scoped to the workspace's tickets so a coordinator never sees workers
  running in other workspaces. A ReviewGate reviewer's run is its ticket's,
  so it is listed under the ticket's workspace.

  A workspace-agnostic coordinator that names no `workspace` lists ALL
  workspaces (`Arbiter.Tasks.Workspaces`, `:read` mode) — it is never silently
  narrowed to a guessed one (bd-45tkhq). The response always echoes the
  `workspace_id` it scoped to (`nil` for all) so the scope is never silent.
  """
  @spec worker_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args) do
      runs = Current.list(workspace_id: ws_id)

      # bd-8vnuy3: the task's settled + in-flight spend — the issue page's
      # figure, so a row never disagrees with the page for the same task.
      costs = worker_costs(runs)

      workers = Enum.map(runs, &serialize_worker_summary(&1, Map.get(costs, &1.task_id)))

      {:ok, %{workers: workers, count: length(workers), workspace_id: ws_id}}
    end
  end

  # ---- worker_show --------------------------------------------------------

  @doc """
  The ticket's current run (`arb worker show <task-id>`) — the same read
  `worker_list` makes (`Arbiter.Workers.Current`, bd-1uu19b) — in full
  detail (kind / state / outcome, activity, recent output lines, ...), plus
  its recent runs, each labelled with its kind. A live run is read from its
  worker, a finished one from its `Arbiter.Workers.Run` row, in the same
  vocabulary. Not-found only when the ticket never had a run.
  """
  @spec worker_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_show(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, task_id),
         {:ok, lines} <- Tools.optional_integer(args, "lines"),
         {:ok, lines} <- validate_positive_integer(lines, "lines") do
      case Current.show(task_id) do
        %{current: current, runs: runs} ->
          {:ok,
           current
           |> serialize_worker_snapshot(lines)
           |> Map.put(:runs, Enum.map(runs, &serialize_recent_run/1))}

        nil ->
          {:error, {:not_found, "no worker found for task #{task_id}"}}
      end
    end
  end

  # Best-effort, like every cost read on these surfaces: a failed ledger read
  # costs the row its cost fields, never the listing.
  defp worker_costs(runs) do
    Arbiter.Usage.LiveSpend.by_worker_task(runs)
  rescue
    e ->
      Logger.warning("worker_list: live spend read failed: #{Exception.message(e)}")
      %{}
  end

  defp task_cost_fields(task_id) do
    task_id
    |> Arbiter.Usage.Estimate.fold_task_id()
    |> Arbiter.Usage.LiveSpend.for_task()
    |> Arbiter.Usage.LiveSpend.cost_fields()
  rescue
    e ->
      Logger.warning("worker_show: live spend read failed: #{Exception.message(e)}")
      Arbiter.Usage.LiveSpend.cost_fields(nil)
  end

  defp latest_run(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # ---- worker_runs ----------------------------------------------------------

  @doc """
  List every historical `Arbiter.Workers.Run` recorded for a task, newest
  first (`arb worker runs <task-id>`). Mirrors `GET /api/workers/history?task_id=`:
  each entry is a run summary (no `output_lines` — fetch a single run's full
  output via `worker_log` for the transcript). Optional `limit` (default 20,
  max 200).

  `task_id` may be a synthetic ReviewGate id (`<base>#review`, `#r<N>`,
  `#impl<N>`, `#v<N>`, `#t<N>`) — those are not `issues` rows, so the
  authorization check resolves to the base task while the run lookup keeps
  the full synthetic id, surfacing the reviewer/re-prompt corpus.
  """
  @spec worker_runs(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_runs(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)),
         {:ok, limit} <- Tools.parse_bounded_limit(args, "limit", 20, 200) do
      runs =
        Arbiter.Workers.Run
        |> Ash.Query.filter(task_id == ^task_id)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      {:ok, %{runs: Enum.map(runs, &serialize_worker_run_summary/1)}}
    end
  end

  # ---- worker_log ------------------------------------------------------------

  @doc """
  Full, uncapped durable transcript of one run — the audit source of record,
  retaining every line however long the run. Two ways to select the run:

    * `run_id:` — that exact run, independent of which run is latest for its
      task. This is the only way to reach a superseded/failed attempt once a
      later run exists for the same task.
    * `task_id:` (no `run_id`) — the task's most recent run (`arb worker log
      <task-id>`), unchanged from prior behaviour. `task_id` may be a
      synthetic ReviewGate id (`<base>#review`, `#r<N>`, `#impl<N>`, `#v<N>`,
      `#t<N>`); the authorization check resolves it to the base task while
      the run lookup keeps the full synthetic id.

  `exists` distinguishes "no file yet / never captured" (false, empty
  `lines`) from "captured but empty" (true, empty `lines`). Not-found when no
  matching run exists (or, for `run_id`, when it belongs to another workspace).
  """
  @spec worker_log(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_log(%Scope{} = scope, args) do
    case Tools.fetch_string(args, "run_id") do
      nil -> worker_log_by_task(scope, args)
      run_id -> worker_log_by_run_id(scope, args, run_id)
    end
  end

  defp worker_log_by_task(scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)) do
      case latest_run(task_id) do
        %Arbiter.Workers.Run{} = run -> {:ok, serialize_worker_log(run)}
        nil -> {:error, {:not_found, "no worker run found for task #{task_id}"}}
      end
    end
  end

  defp worker_log_by_run_id(scope, args, run_id) do
    with {:ok, run} <- fetch_run(scope, args, run_id) do
      {:ok, serialize_worker_log(run)}
    end
  end

  defp serialize_worker_log(%Arbiter.Workers.Run{} = run) do
    {exists, lines} =
      case Arbiter.Worker.OutputLog.read_lines(run.id) do
        {:ok, lines} -> {true, lines}
        {:error, _} -> {false, []}
      end

    %{
      task_id: run.task_id,
      run_id: run.id,
      path: Arbiter.Worker.OutputLog.path_for(run.id),
      exists: exists,
      line_count: length(lines),
      lines: lines
    }
  end

  # Fetch a single `Arbiter.Workers.Run` by id, enforcing workspace isolation
  # the same way `fetch_task/3` does for `issues` rows. Not-found (rather than
  # unauthorized) on a cross-workspace hit so existence doesn't leak.
  defp fetch_run(scope, args, run_id) do
    with {:ok, target_ws} <- Tools.authorized_workspace(scope, args) do
      case Ash.get(Arbiter.Workers.Run, run_id) do
        {:ok, %Arbiter.Workers.Run{} = run} ->
          if Tools.workspace_match?(run.workspace_id, target_ws),
            do: {:ok, run},
            else: {:error, {:not_found, "run #{run_id} not found"}}

        _ ->
          {:error, {:not_found, "run #{run_id} not found"}}
      end
    end
  end

  defp serialize_worker_run_summary(%Arbiter.Workers.Run{} = run) do
    %{
      id: run.id,
      task_id: run.task_id,
      task_title: run.task_title,
      repo: run.repo,
      workspace_id: run.workspace_id,
      kind: Tools.to_str(run.kind),
      state: Tools.to_str(run.state),
      outcome: Tools.to_str(run.outcome),
      model: run.model,
      provider: run.provider,
      provider_fallback: run.provider_fallback,
      # bd-40pzpj: what provider routing chose and why (nil when not routed).
      provider_account_id: run.provider_account_id,
      model_family: run.model_family,
      routing_decision: run.routing_decision,
      session_id: run.session_id,
      resumed_from_run_id: run.resumed_from_run_id,
      started_at: Tools.iso(run.started_at),
      completed_at: Tools.iso(run.completed_at),
      exit_code: run.exit_code,
      failure_reason: run.failure_reason,
      failure_summary: run.failure_summary,
      resolved_skills: run.resolved_skills || [],
      standing_orders_digest: run.standing_orders_digest,
      routing_policy: run.routing_policy,
      model_tier: run.model_tier,
      thinking: run.thinking,
      difficulty_at_dispatch: run.difficulty_at_dispatch
    }
  end

  # ---- worker_prompt ----------------------------------------------------

  @doc """
  The composed prompt one run was spawned with (bd-9rdwe4, #1017 gap G5),
  redacted through the same choke-point as transcript lines. Sibling of
  `worker_log/2` — same `run_id`/`task_id` selection rule, same
  synthetic-id-aware task resolution.

  `exists` distinguishes "no prompt was ever persisted for this run" (false,
  `prompt` nil) from a captured one — including a run whose prompt redacted
  down to something shorter than what was typed, which is still "exists".
  """
  @spec worker_prompt(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_prompt(%Scope{} = scope, args) do
    case Tools.fetch_string(args, "run_id") do
      nil -> worker_prompt_by_task(scope, args)
      run_id -> worker_prompt_by_run_id(scope, args, run_id)
    end
  end

  defp worker_prompt_by_task(scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)) do
      case latest_run(task_id) do
        %Arbiter.Workers.Run{} = run -> {:ok, serialize_worker_prompt(run)}
        nil -> {:error, {:not_found, "no worker run found for task #{task_id}"}}
      end
    end
  end

  defp worker_prompt_by_run_id(scope, args, run_id) do
    with {:ok, run} <- fetch_run(scope, args, run_id) do
      {:ok, serialize_worker_prompt(run)}
    end
  end

  defp serialize_worker_prompt(%Arbiter.Workers.Run{} = run) do
    {exists, prompt} =
      case Arbiter.Worker.PromptLog.read(run.id) do
        {:ok, content} -> {true, content}
        {:error, _} -> {false, nil}
      end

    %{
      task_id: run.task_id,
      run_id: run.id,
      path: Arbiter.Worker.PromptLog.path_for(run.id),
      exists: exists,
      prompt: prompt,
      prompt_sha256: run.prompt_sha256
    }
  end

  # ---- run_log_list -----------------------------------------------------

  @doc """
  Enumerate every run recorded for a task **and its ReviewGate synthetic
  children** (`<task_id>#review`, `#r<N>`, `#impl<N>`, `#v<N>`, `#t<N>`),
  newest first — the whole retrievable transcript corpus for a task in one
  call. Unlike `worker_runs` (exact `task_id` match only), this matches the
  task id itself plus anything prefixed `<task_id>#`, so a single call
  surfaces the reviewer/re-prompt corpus alongside the author's own runs.

  Each entry reports `transcript_exists` so a missing durable log is
  distinguishable from an empty one without a separate `worker_log` call.
  `task_id` must be the base task (a plain `issues` id) — pass it
  un-suffixed even to reach synthetic runs.
  """
  @spec run_log_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def run_log_list(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- Tools.fetch_task(scope, args, ReviewGate.base_task_id(task_id)),
         {:ok, limit} <- Tools.parse_bounded_limit(args, "limit", 200, 1000) do
      prefix = task_id <> "#"

      runs =
        Arbiter.Workers.Run
        |> Ash.Query.filter(task_id == ^task_id or string_starts_with(task_id, ^prefix))
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      {:ok, %{runs: Enum.map(runs, &serialize_run_log_entry/1)}}
    end
  end

  defp serialize_run_log_entry(%Arbiter.Workers.Run{} = run) do
    %{
      run_id: run.id,
      task_id: run.task_id,
      kind: Tools.to_str(run.kind),
      state: Tools.to_str(run.state),
      outcome: Tools.to_str(run.outcome),
      model: run.model,
      started_at: Tools.iso(run.started_at),
      transcript_exists: File.regular?(Arbiter.Worker.OutputLog.path_for(run.id)),
      line_count: run.id |> Arbiter.Worker.OutputLog.read_lines() |> line_count_of()
    }
  end

  defp line_count_of({:ok, lines}), do: length(lines)
  defp line_count_of({:error, _}), do: 0

  # ---- transcript_capture_stats -------------------------------------------

  # 2026-06-19 rename (commit 8181cfc) moved the durable-transcript root from
  # the retired `arbiter-polecat-logs` to `arbiter-worker-logs`; `path_for/1`
  # only ever looks in the current root. That's an accepted loss (bd-9wotbo,
  # operator decision 2026-07-28) — no migration, no legacy-root fallback — so
  # every run before this date is definitionally unreachable and must be
  # excluded from the denominator rather than counted as a capture failure.

  @doc """
  Transcript-capture health for a workspace (bd-9wotbo, gap G4): what fraction
  of Claude-driven runs actually produced a durable transcript, scoped to
  `started_at >= #{@corpus_start_date}` (the `arbiter-worker-logs` corpus
  start date — see the module note on `@corpus_start_date` and
  `Arbiter.Worker.OutputLog`'s moduledoc for the accepted pre-rename loss).

  A workflow-mode (bookkeeping-only) run never opens a Claude session — see
  `Arbiter.Worker.Driver`'s "workflow mode" — so it carries no `session_id`
  and, by design, no transcript. Counting those as capture failures would
  make the rate look broken when nothing is wrong, so they're reported
  separately as `workflow_only_runs` and excluded from `claude_sessions` /
  `capture_rate_pct`. `capture_rate_pct` is `nil` when there are no
  Claude-driven runs in the window (avoids a divide-by-zero misread as 0%).

  ## Two artifacts, two rates (bd-db0p38)

  The rendered transcript is only half the story, and the cheaper half: it
  truncates every tool result to 40 lines and keeps no thinking blocks, tool
  inputs or per-message usage. The full-fidelity record is the agent CLI's own
  session JSONL, archived per-run by `Arbiter.Worker.SessionArchive`. The two
  losses are independent — a run can have neither — so they are counted
  separately rather than folded into one number that hides the richer
  artifact's absence:

    * `claude_sessions` / `transcript_missing` / `capture_rate_pct` — the
      rendered `<run_id>.log`, over every session-bearing run (all providers
      write one).
    * `jsonl_sessions` / `jsonl_archived` / `jsonl_missing` /
      `jsonl_archive_rate_pct` — the `<run_id>.jsonl.gz` archive, over
      `provider == "claude"` runs only.
    * `gemini_db_sessions` / `gemini_db_archived` / `gemini_db_missing` /
      `gemini_db_archive_rate_pct` — the `<run_id>.db.gz` archive
      (`Arbiter.Worker.SessionArchive.db_archived?/1`), over
      `provider == "gemini"` (agy) runs only (bd-6nupvc T9). Since agy runs
      also record `config_dir` (their effective `$HOME`), splitting by
      provider rather than by "has a `config_dir`" is what keeps these two
      counts from double-counting or manufacturing loss for the other.
      `non_claude_sessions` is everything that is neither — providers with no
      archive branch at all today.

  Coordinator only. Optional `workspace` (resolved the same way as
  `worker_list` / `ticket_ready`).
  """
  @spec transcript_capture_stats(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def transcript_capture_stats(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args) do
      runs =
        Arbiter.Workers.Run
        |> Ash.Query.filter(started_at >= ^@corpus_start_date)
        |> then(fn q -> if ws_id, do: Ash.Query.filter(q, workspace_id == ^ws_id), else: q end)
        |> Ash.read!()

      {agent_sessions, workflow_only} =
        Enum.split_with(runs, &(&1.session_id not in [nil, ""]))

      missing =
        Enum.count(agent_sessions, fn run ->
          not File.regular?(Arbiter.Worker.OutputLog.path_for(run.id))
        end)

      # bd-db0p38: the JSONL archive has its own denominator, and it must be
      # split by `provider` rather than by "has a `config_dir`" — since
      # bd-6nupvc T9, a gemini (agy) run records `config_dir` too (its
      # effective `$HOME`), so that no longer distinguishes "has a Claude
      # JSONL to lose" from "archives into agy's own SQLite branch instead".
      # Folding gemini runs into `jsonl_sessions` would recreate the phantom
      # loss bd-db0p38 removed: every one would show up in `jsonl_missing`
      # because `SessionArchive.archived?/1` only ever checks `.jsonl.gz`.
      {claude_provider_sessions, other_provider_sessions} =
        Enum.split_with(agent_sessions, &(&1.provider == "claude"))

      {gemini_sessions, non_claude} =
        Enum.split_with(other_provider_sessions, &(&1.provider == "gemini"))

      jsonl_missing =
        Enum.count(
          claude_provider_sessions,
          &(not Arbiter.Worker.SessionArchive.archived?(&1.id))
        )

      db_missing =
        Enum.count(gemini_sessions, &(not Arbiter.Worker.SessionArchive.db_archived?(&1.id)))

      {:ok,
       %{
         workspace_id: ws_id,
         corpus_start_date: Date.to_iso8601(DateTime.to_date(@corpus_start_date)),
         total_runs: length(runs),
         claude_sessions: length(agent_sessions),
         transcript_missing: missing,
         workflow_only_runs: length(workflow_only),
         capture_rate_pct: capture_rate_pct(agent_sessions, missing),
         non_claude_sessions: length(non_claude),
         jsonl_sessions: length(claude_provider_sessions),
         jsonl_archived: length(claude_provider_sessions) - jsonl_missing,
         jsonl_missing: jsonl_missing,
         jsonl_archive_rate_pct: capture_rate_pct(claude_provider_sessions, jsonl_missing),
         gemini_db_sessions: length(gemini_sessions),
         gemini_db_archived: length(gemini_sessions) - db_missing,
         gemini_db_missing: db_missing,
         gemini_db_archive_rate_pct: capture_rate_pct(gemini_sessions, db_missing)
       }}
    end
  rescue
    e -> {:error, {:internal, "transcript_capture_stats failed: #{Exception.message(e)}"}}
  end

  defp capture_rate_pct([], _missing), do: nil

  defp capture_rate_pct(claude_sessions, missing) do
    total = length(claude_sessions)
    Float.round((total - missing) / total * 100, 1)
  end

  # ---- dispatch opts ------------------------------------------------------

  # Every dispatch-shaped tool (dispatch / resume / review) normalises its
  # arguments through `Arbiter.Worker.Dispatch.Params`, the same function the
  # REST controller calls: the same provider list, the same unknown-argument
  # refusal, the same recursion-depth guard (child scope minted at depth + 1)
  # and the same quota-bypass attribution.
  defp normalize(verb, %Scope{} = scope, args),
    do: Params.normalize(args, verb: verb, scope: scope, surface: :mcp)

  # One kind per refusal (`Dispatch.refusal_kind/1`, shared with the REST
  # controller), so a client can tell busy / conflict / invalid / not_found apart.
  defp dispatch_error(reason, task_id),
    do: {:error, {Dispatch.refusal_kind(reason), dispatch_error_message(reason, task_id)}}

  defp dispatch_error_message({:task_not_found, id}), do: "task #{id} not found"

  defp dispatch_error_message({:pending_migrations, count}),
    do:
      "#{count} pending migration(s) — the server is applying schema changes; retry " <>
        "once the deployment completes"

  defp dispatch_error_message(:no_session),
    do: "no prior session recorded for this task — nothing to resume; dispatch it fresh instead"

  # bd-asxw4e: a Backlog or Blocked ticket, dispatched without `force`.
  defp dispatch_error_message({:not_dispatchable, id, hold}),
    do: Dispatch.refusal_message(id, hold)

  defp dispatch_error_message({:task_closed, id}),
    do: "task #{id} is closed; reopen it before dispatching"

  defp dispatch_error_message(:no_repo_configured), do: "no repos configured for this workspace"

  defp dispatch_error_message({:repo_not_found, repo}),
    do: "repo #{inspect(repo)} is not configured"

  defp dispatch_error_message({:ambiguous_repo, repos}),
    do:
      "multiple repos available (#{Enum.join(repos, ", ")}); pass `repo` explicitly, or set " <>
        "`default_repo` in the workspace config via workspace_config_set"

  defp dispatch_error_message({:task_awaiting_review, id}),
    do: "task #{id} is already awaiting review"

  # bd-2aslx6 (#1428): without a named message this surfaced as a raw tuple, and
  # the refusal reads as a failure rather than "your first dispatch is still
  # working". Say which worker holds the session and what to do about it.
  defp dispatch_error_message({:agent_session_active, id}),
    do:
      "task #{id} already has a live agent session; a second dispatch would open " <>
        "another paid CLI in the same worker run. Wait for it, or stop the worker " <>
        "(`arb worker stop #{id}`) before dispatching again"

  # Resume-specific (`Dispatch.resume/2`).
  defp dispatch_error_message(:no_outpost),
    do: "no preserved worktree for this task — nothing to resume; dispatch it fresh instead"

  defp dispatch_error_message(:repo_unknown),
    do: "could not resolve the repo for this task; pass `repo` explicitly"

  # bd-92mx1m: the task released its slot and the cap is full.
  defp dispatch_error_message({:slot_cap_full, info}),
    do: Arbiter.Worker.ResumeSlot.refusal_message(info)

  # bd-8suxac: a fresh dispatch onto a provider account with no free slot.
  defp dispatch_error_message({:account_at_capacity, info}),
    do: Arbiter.Accounts.Admission.refusal_message(info)

  # RW8: no node had a free slot (`remote_only`), or the primary's own cap held
  # a local run. Held, not failed — it starts when capacity frees.
  defp dispatch_error_message({:no_node_capacity, info}),
    do: Arbiter.Nodes.Placement.refusal_message(info)

  # bd-13pqcp: the ticket's provider constraint refused the provider (or left
  # none eligible with capacity). The phrase already reads `held — provider
  # constraint (<detail>)`.
  defp dispatch_error_message({:provider_constraint, _provider, phrase}),
    do:
      "#{phrase} — the ticket never runs on an excluded provider; wait for an eligible " <>
        "account to free up, or change the ticket's constraint (`ticket_update`)"

  # bd-57uzkl: the provider this dispatch would run on lacks a capability the
  # role or the repo requires. The phrase already reads `held — capability
  # missing (<detail>)`.
  defp dispatch_error_message({:capability_missing, _provider, phrase}),
    do:
      "#{phrase} — dispatch refused; waiting will not fix it. Attach an account on a " <>
        "capable provider, or change the repo's `routing.repos.<repo>.requires`"

  # bd-c675ny: the model this dispatch would run is below the repo's routing
  # floor. The phrase already reads `held — below floor (<detail>)`.
  defp dispatch_error_message({:below_floor, _provider, phrase}),
    do:
      "#{phrase} — dispatch refused; waiting will not fix it. Raise the model, or change the " <>
        "repo's `routing.floors.repos.<repo>.min_model_tier` (operator-owned)"

  defp dispatch_error_message(other), do: "dispatch failed: #{inspect(other)}"

  # bd-8lq2g7: `{:worker_active, …}` is rendered from the /2 arity so the message
  # can name the parked worker and its subordinate passes, rather than issuing
  # the generic (and, at a review park, destructive) "stop it before resuming".
  defp dispatch_error_message({:worker_active, run}, task_id),
    do: Dispatch.worker_active_message(run, task_id)

  defp dispatch_error_message(other, _task_id), do: dispatch_error_message(other)

  defp validate_positive_integer(nil, _key) do
    {:ok, nil}
  end

  defp validate_positive_integer(value, _key) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp validate_positive_integer(_value, key) do
    {:error, {:invalid, "`#{key}` must be a positive integer"}}
  end

  # ---- serializers (JSON-friendly, mirroring the REST shapes) -------------

  # The dispatch result carries live pids/ports; render the JSON-safe subset (pids
  # inspected to strings), mirroring `ArbiterWeb.Api.WorkerJSON.dispatch/1`. `depth`
  # is the slung worker's scope depth (parent + 1).
  defp serialize_dispatch(result, depth) do
    %{
      task: Tools.serialize_task_summary(result.task),
      worker: %{task_id: result.task.id, pid: inspect(result.worker_pid)},
      machine: %{id: result.machine_id, pid: inspect(result.machine_pid)},
      worktree_path: result.worktree_path,
      claude_started: not is_nil(result.claude_port),
      depth: depth
    }
  end

  # bd-1uu19b: one run, as `worker_list` and `worker_show` both report it, in
  # the one run vocabulary. `task_id` is the ticket; `run_task_id` is the id
  # the run itself runs under (a ReviewGate reviewer: `<ticket>#review`).
  defp run_fields(view) do
    %{
      task_id: view.ticket_id,
      run_task_id: view.task_id,
      run_id: Map.get(view, :run_id),
      source: Tools.to_str(view.source),
      kind: Tools.to_str(view.kind),
      state: Tools.to_str(view.state),
      outcome: Tools.to_str(view.outcome),
      waiting_on: Tools.to_str(Map.get(view, :waiting_on)),
      # bd-8lq2g7: without these two fields a merge-queue pass (role
      # `fix_pass` / `conflict_resolver`, under the ticket id since bd-741sid)
      # is indistinguishable from the task's own run.
      registry_key: Map.get(view, :registry_key),
      role: Tools.to_str(Map.get(view, :role)),
      # bd-aw2cyt: what the work is actually doing, and whether a process
      # actually exists behind this row.
      phase: Tools.to_str(Map.get(view, :phase)),
      phase_label: Arbiter.Worker.Phase.label(Map.get(view, :phase)),
      # bd-6omte4: the dispatch the quota gate is holding for the ticket.
      held: Arbiter.Workflows.DispatchQueue.serialize_held(Map.get(view, :held)),
      agent_live: Map.get(view, :agent_live),
      workspace_id: view.workspace_id,
      repo: view.repo,
      started_at: Tools.iso(view.started_at),
      completed_at: Tools.iso(Map.get(view, :completed_at))
    }
  end

  @doc """
  A ticket's current run as the slim `current_run` object `GET /api/issues/:id`
  and `ticket_show full:true` carry (kind / state / outcome / phase, no
  transcript), from an `Arbiter.Workers.Current` view.
  """
  @spec current_run_payload(map()) :: map()
  def current_run_payload(view) do
    view
    |> run_fields()
    |> Map.take([
      :run_id,
      :run_task_id,
      :source,
      :kind,
      :state,
      :outcome,
      :waiting_on,
      :role,
      :phase,
      :phase_label,
      :started_at,
      :completed_at
    ])
    |> Map.put(:failure_reason, stringify_reason(Map.get(view, :failure_reason)))
  end

  defp serialize_worker_summary(view, spend) do
    meta = Map.get(view, :meta, %{}) || %{}
    routing = Map.get(meta, :routing_config) || %{}
    model_id = Map.get(meta, :model) || Map.get(routing, :model)
    {resumable, blocked_reason} = Dispatch.resumable_status(view.ticket_id)

    view
    |> run_fields()
    |> Map.merge(%{
      activity: Map.get(meta, :activity),
      provider: Map.get(meta, :provider) || Map.get(routing, :provider),
      model: Arbiter.Worker.Stats.short_model_name(model_id),
      resumable: resumable,
      blocked_reason: blocked_reason
    })
    |> Map.merge(Arbiter.Usage.LiveSpend.cost_fields(spend))
  end

  defp serialize_worker_snapshot(view, lines) do
    meta = Map.get(view, :meta, %{}) || %{}
    run = Map.get(view, :run)
    {resumable, blocked_reason} = Dispatch.resumable_status(view.ticket_id)

    output_lines = Map.get(meta, :output_lines, [])
    output_lines = if lines, do: Enum.take(output_lines, -lines), else: output_lines

    view
    |> run_fields()
    |> Map.merge(%{
      task_title: task_title(run),
      current_step: Map.get(view, :current_step),
      claude_session: Map.get(meta, :claude_session, false),
      activity: Map.get(meta, :activity),
      step_started_at: Tools.iso(Map.get(view, :step_started_at)),
      mr_ref: Map.get(view, :mr_ref),
      merger_url: Map.get(view, :merger_url),
      last_merger_status: Map.get(meta, :last_merger_status),
      last_checked_at: Tools.iso(Map.get(meta, :last_checked_at)),
      pid: view |> Map.get(:pid) |> inspect_pid(),
      output_lines: output_lines,
      exit_status: Map.get(meta, :exit_status),
      exited_at: Tools.iso(Map.get(meta, :exited_at)),
      result: Map.get(meta, :result),
      failure_reason: stringify_reason(Map.get(view, :failure_reason)),
      failure_summary: Map.get(meta, :failure_summary),
      resumable: resumable,
      blocked_reason: blocked_reason
    })
    |> Map.merge(routing_fields(run, meta))
    |> Map.merge(task_cost_fields(view.ticket_id))
  end

  # bd-40pzpj: the model and provider, and what provider routing chose and
  # why — off the run's row when the view was read from one, else the live
  # worker's meta.
  defp routing_fields(%Arbiter.Workers.Run{} = run, _meta) do
    Map.take(run, [
      :model,
      :provider,
      :provider_fallback,
      :provider_account_id,
      :model_family,
      :routing_decision
    ])
  end

  defp routing_fields(nil, meta) do
    %{
      model: Map.get(meta, :model),
      provider: Arbiter.Worker.provider(meta),
      provider_fallback: Map.get(meta, :provider_fallback),
      provider_account_id: Map.get(meta, :provider_account_id),
      model_family: Map.get(meta, :model_family),
      routing_decision: Map.get(meta, :routing_decision)
    }
  end

  # A recent run in `worker_show`'s `runs` list: the same vocabulary, no
  # transcript.
  defp serialize_recent_run(view) do
    view
    |> run_fields()
    |> Map.take([
      :run_id,
      :run_task_id,
      :source,
      :kind,
      :state,
      :outcome,
      :role,
      :started_at,
      :completed_at
    ])
    |> Map.merge(%{
      failure_reason: stringify_reason(Map.get(view, :failure_reason)),
      current: Map.get(view, :current, false)
    })
  end

  defp task_title(%Arbiter.Workers.Run{task_title: title}), do: title
  defp task_title(nil), do: nil

  defp inspect_pid(nil), do: nil
  defp inspect_pid(pid), do: inspect(pid)

  defp stringify_reason(nil), do: nil
  defp stringify_reason(v) when is_binary(v), do: v
  defp stringify_reason(v), do: inspect(v)
end
