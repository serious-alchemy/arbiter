defmodule Arbiter.Workflows.MergeQueue.FixPassDispatcher do
  @moduledoc """
  Spawn a short-lived worker to fix a `:ci_failed` PR — diagnose the failing
  checks, fix the root cause, and push back to the **same branch** so CI re-runs
  (#354, Phase 2a).

  Invoked by `Arbiter.Worker.Watchdog` when an approved PR is
  blocked because its required checks are failing. Before this, the Watchdog only
  *escalated* a `:ci_failed` block to the coordinator and parked the PR; the fix-pass
  dispatcher lets the common, mechanically-fixable failures (a broken test, a
  formatting violation, a missing compile fix) unblock themselves.

  ## Job scope

  The worker is given a *narrowly* constrained prompt: read the failing check
  names + log tails (handed to it in the briefing), fix the root cause, commit,
  and push to the existing branch with the existing PR updating in place. It must
  NOT re-implement the change set or open a new PR. When the failure isn't
  something it can fix (an infrastructure/flake failure, or a failure it can't
  reproduce) it escalates via the workspace mailbox rather than thrashing.

  ## An ordinary run (bd-741sid)

  The implementer's run ended when it opened the PR; the ticket's Watchdog is
  what is watching it. So the fix pass is an ordinary run on the ticket: it
  registers under the ticket id — the single-active-run rule (bd-8tjcms) still
  refuses it while another run is working the ticket — and takes the ticket
  back In progress. A Merging ticket holds no slot, so the pass is admitted
  like an automatic resume (`Arbiter.Workflows.MergeQueue.PassAdmission`): it
  starts in a free slot, or waits in the scheduler's fast lane, ahead of every
  Ready ticket, until one frees. When it finishes, the ticket goes back to
  Merging (`Arbiter.Worker`'s pass completion).

  ## Merger/tracker-agnostic

  Like the `ConflictResolver`, this operates on raw git artefacts (a local
  checkout, a branch). The CI signal itself is read one layer up (by the merger
  adapter the Watchdog polls); this module only needs the failing-check briefing.

  ## Behaviour

  `FixPassDispatcher` is a behaviour so the Watchdog accepts a swappable
  implementation (defaults to this module). Tests inject a stub so they don't
  boot a real Claude session or shell out to git.
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Mergers
  alias Arbiter.Mergers.Merger
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.GitLayout
  alias Arbiter.Worker.SeedPaths
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueue.PassAdmission

  require Logger

  # This module both defines the behaviour and ships the default implementation,
  # so it implements itself.
  @behaviour __MODULE__

  @type failing_check :: Merger.failing_check()

  @type dispatch_args :: %{
          required(:task_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:branch) => String.t(),
          optional(:target_branch) => String.t(),
          optional(:repo_path) => String.t(),
          optional(:repo) => String.t() | nil,
          optional(:pr_ref) => term(),
          optional(:checks) => [failing_check()],
          optional(:outside_diff_files) => [String.t()],
          optional(:start_claude) => boolean(),
          # bd-4l7l2n: test seam for the start-time PR/CI re-read.
          optional(:pr_status) => (-> {:ok, map()} | {:error, term()}),
          optional(:claude_command) => [String.t()],
          # bd-741sid: a replay the scheduler already admitted into a slot, and
          # the test seam standing in for the fast lane (`PassAdmission`).
          optional(:slot_admitted) => boolean() | nil,
          optional(:defer_resume) => (String.t(), atom(), keyword() -> term())
        }

  @type dispatch_result ::
          {:ok, %{worker_pid: pid(), worktree_path: String.t(), branch: String.t()}}
          | {:ok,
             %{deferred: true, task_id: String.t(), cap: non_neg_integer(), holders: [String.t()]}}
          | {:error, term()}

  @doc """
  Spawn a worker to fix the failing checks on the task's branch and push.

  Resolves `branch`, `target_branch`, and `repo_path` from the task + workspace
  when not supplied in `args`. Returns `{:ok, info}` once the worker is spawned
  (the fix pass runs asynchronously); the Watchdog picks up the resolution on its
  next poll when CI passes and the PR turns mergeable.

  Returns `{:ok, %{deferred: true, ...}}` when no worker slot is free and the
  pass is waiting in the scheduler's fast lane (bd-741sid).

  Returns `{:error, reason}` when the worker can't be spawned (no local checkout,
  no branch, a fix pass already running). The Watchdog's bounded-retry counter
  handles persistent failure by escalating after N attempts.
  """
  @callback dispatch(args :: dispatch_args()) :: dispatch_result()

  @doc """
  Default implementation of `dispatch/1`. Spawns a real Worker with a
  ClaudeSession running the fix-pass prompt inside the PR's worktree.

  Tests should pass a stub via the Watchdog's `:fix_pass_dispatcher` opt so they
  don't shell out to git or spawn `claude`.
  """
  @impl true
  @spec dispatch(dispatch_args()) :: dispatch_result()
  def dispatch(%{} = args) do
    task_id = Map.get(args, :task_id) || (is_map(args[:task]) && args[:task].id)

    if is_binary(task_id) and task_id != "" do
      with {:ok, task} <- load_task_or_use(task_id, args),
           :ok <- revalidate(task, args),
           {:ok, context} <- resolve_context(task, args),
           :ok <- PassAdmission.admit(task, :fix_pass, args) do
        # bd-842qio: a CI failure takes the ticket back to work (merging →
        # active) — bd-741sid: as soon as the pass is admitted into its slot.
        PassAdmission.with_slot(task, fn -> start_pass(task, context, args) end)
      else
        # bd-741sid: no free slot — the pass waits in the fast lane.
        {:deferred, info} -> {:ok, info}
        other -> other
      end
    else
      {:error, :missing_task_id}
    end
  end

  def dispatch(_), do: {:error, :missing_task_id}

  # bd-4l7l2n: a pass queued for a slot is started long after the Watchdog saw
  # the red CI. By then the PR can have merged and the ticket closed, or the
  # head gone green on a re-run. The ticket check is local and runs always; the
  # forge read runs only on a replay (`slot_admitted`), the one path that
  # waited. An unreadable forge does not hold a pass back.
  defp revalidate(%Issue{} = task, args) do
    cond do
      task.state in [:closed, :verifying] ->
        stale(task, "the ticket is #{task.state}", :task_closed)

      Map.get(args, :slot_admitted) == true ->
        revalidate_pr(task, args)

      true ->
        :ok
    end
  end

  defp revalidate_pr(task, args) do
    case pr_status(task, args) do
      {:ok, %{status: status}} when status in [:merged, :closed] ->
        stale(task, "its PR is #{status}", :pr_not_open)

      {:ok, %{pipeline: pipeline}} when pipeline != :failed ->
        stale(task, "the head's CI is no longer failing (#{inspect(pipeline)})", :ci_not_failing)

      _ ->
        :ok
    end
  end

  defp stale(task, why, error) do
    Logger.info("FixPassDispatcher: fix pass for #{task.id} not started — #{why}")
    {:error, error}
  end

  # `:pr_status` is a test seam: a 0-arity function standing in for the read.
  defp pr_status(task, %{pr_status: read}) when is_function(read, 0), do: safe_read(read, task)

  defp pr_status(task, args) do
    mr_ref = Map.get(args, :pr_ref) || task.pr_ref
    workspace = Map.get(args, :workspace) || maybe_load_workspace(task.workspace_id)

    if is_binary(mr_ref) and mr_ref != "" and not is_nil(workspace) do
      scoped = Mergers.scope(workspace, Map.get(args, :repo))
      adapter = Mergers.for_workspace(scoped)

      safe_read(
        fn ->
          if function_exported?(adapter, :with_workspace, 2),
            do: adapter.with_workspace(scoped, fn -> adapter.get(mr_ref) end),
            else: adapter.get(mr_ref)
        end,
        task
      )
    else
      :skip
    end
  end

  defp safe_read(read, task) do
    read.()
  rescue
    e ->
      Logger.warning(
        "FixPassDispatcher: PR re-check for #{task.id} failed: #{Exception.message(e)}"
      )

      :skip
  catch
    :exit, _ -> :skip
  end

  defp start_pass(task, context, args) do
    # bd-5ef587: the pause is checked before any worktree is created.
    with {provider, fallback_reason, decision} <- resolve_pass_provider(task, context),
         :ok <- ProviderRouting.ensure_unpaused(provider, task.workspace_id),
         :ok <- ProviderConstraint.check(task, provider),
         {:ok, worktree_path} <- create_worktree(context),
         {:ok, worker_pid} <-
           start_worker(task, context, worktree_path, provider, {fallback_reason, decision}),
         {:ok, _port} <- start_agent(worker_pid, worktree_path, context, args, provider) do
      # bd-741sid: a pass the Watchdog queued for a slot is an attempt now.
      Arbiter.Worker.Watchdog.pass_started(task.id, :fix_pass, worker_pid)
      {:ok, %{worker_pid: worker_pid, worktree_path: worktree_path, branch: context.branch}}
    end
  end

  defp start_agent(worker_pid, worktree_path, context, args, provider) do
    case maybe_start_claude(worker_pid, worktree_path, context, args, provider) do
      {:ok, _port} = started ->
        started

      {:error, reason} = failed ->
        PassAdmission.agent_failed(worker_pid, reason)
        failed
    end
  end

  defp load_task_or_use(_task_id, %{task: %Issue{} = task}), do: {:ok, task}
  defp load_task_or_use(task_id, _args), do: load_task(task_id)

  defp resolve_pass_provider(task, context) do
    workspace = context.workspace || maybe_load_workspace(task.workspace_id)

    # bd-40pzpj: the task's implementer pin under `most_quota` routing;
    # otherwise exactly `Agents.resolve_revision_provider/2`.
    {provider, fallback_reason, decision} =
      ProviderRouting.implementer_provider(task, workspace, :fix_pass)

    if fallback_reason && ProviderRouting.escalate_fallback?(decision) do
      CoordinatorNotifier.provider_fallback(
        %{workspace_id: task.workspace_id, task_id: task.id},
        Run.latest_authoring_provider(task.id),
        provider,
        fallback_reason
      )
    end

    {provider, ProviderRouting.truncate_fallback(fallback_reason), decision}
  end

  # ---- context resolution --------------------------------------------------

  defp load_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, task} -> {:ok, task}
      {:error, _} -> {:error, {:task_not_found, task_id}}
    end
  rescue
    e -> {:error, {:task_load_failed, Exception.message(e)}}
  end

  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp resolve_context(%Issue{} = task, args) do
    workspace = Map.get(args, :workspace) || maybe_load_workspace(task.workspace_id)

    branch = Map.get(args, :branch) || derive_branch(task)

    target_branch =
      Map.get(args, :target_branch) || Mergers.base_branch(workspace, Map.get(args, :repo)) ||
        "main"

    repo_path = Map.get(args, :repo_path) || resolve_repo_path(workspace, Map.get(args, :repo))

    cond do
      is_nil(branch) ->
        {:error, :no_branch}

      is_nil(repo_path) ->
        {:error, :no_repo_path}

      not File.dir?(repo_path) ->
        {:error, {:repo_path_missing, repo_path}}

      true ->
        {:ok,
         %{
           task: task,
           workspace: workspace,
           branch: branch,
           target_branch: target_branch,
           repo_path: repo_path,
           repo: Map.get(args, :repo) || resolve_repo_name(workspace),
           checks: Map.get(args, :checks) || [],
           outside_diff_files: Map.get(args, :outside_diff_files) || []
         }}
    end
  end

  defp derive_branch(%Issue{} = task) do
    BranchNamer.derive(task)
  rescue
    _ -> nil
  end

  defp maybe_load_workspace(nil), do: nil

  defp maybe_load_workspace(ws_id) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Repo path lookup mirrors `Arbiter.Workflows.MergeQueue.ConflictResolver`:
  # workspace config first, then application env, then the first configured repo.
  defp resolve_repo_path(workspace, repo) do
    workspace_repo_path(workspace, repo) || application_repo_path(repo) ||
      first_repo_path(workspace) || first_application_repo_path()
  end

  defp workspace_repo_path(_workspace, nil), do: nil

  defp workspace_repo_path(%Workspace{config: %{} = config}, repo) when is_binary(repo) do
    RepoConfig.find_path(get_in(config, ["repo_paths"]), repo)
  end

  defp workspace_repo_path(_, _), do: nil

  defp first_repo_path(%Workspace{config: %{} = config}) do
    case Map.get(config, "repo_paths") do
      %{} = paths -> paths |> Map.values() |> Enum.find_value(&RepoConfig.repo_path_from_config/1)
      _ -> nil
    end
  end

  defp first_repo_path(_), do: nil

  defp application_repo_path(nil), do: nil

  defp application_repo_path(repo) when is_binary(repo) do
    RepoConfig.repo_path_from_config(
      Map.get(Application.get_env(:arbiter, :repo_paths, %{}), repo)
    )
  end

  defp first_application_repo_path do
    case Application.get_env(:arbiter, :repo_paths, %{}) do
      %{} = paths -> paths |> Map.values() |> Enum.find_value(&RepoConfig.repo_path_from_config/1)
      _ -> nil
    end
  end

  defp resolve_repo_name(%Workspace{config: %{} = config}) do
    case Map.get(config, "repo_paths") do
      %{} = paths -> paths |> Map.keys() |> List.first()
      _ -> nil
    end
  end

  defp resolve_repo_name(_), do: nil

  # ---- worktree / worker / claude wiring ---------------------------------

  # Attach a worktree to the (existing) PR branch — the branch already exists
  # because the PR was opened against it, so we must NOT use `Worktree.create/3`
  # (`git worktree add -b`). `Worktree.attach/2` is idempotent on the same branch.
  #
  # bd-4wy1w1: in the git layout its sandbox needs — a private clone under a
  # container backend (`Arbiter.Worker.GitLayout`).
  defp create_worktree(%{repo_path: repo_path, branch: branch} = context) do
    layout = GitLayout.for_workspace(context.workspace, context.repo)

    case Worktree.attach(repo_path, branch,
           layout: layout,
           base: context.target_branch,
           seed_paths: SeedPaths.resolve(context.workspace, context.repo)
         ) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp start_worker(
         %Issue{} = task,
         context,
         worktree_path,
         provider,
         {fallback_reason, decision}
       ) do
    meta = %{
      role: :fix_pass,
      provider: Atom.to_string(provider),
      provider_fallback: fallback_reason,
      worktree_path: worktree_path,
      branch: nil,
      target_branch: context.target_branch,
      fix_pass_branch: context.branch,
      repo_path: context.repo_path
    }

    meta = Map.merge(meta, ProviderRouting.run_meta(decision))

    # bd-741sid: registered under the ticket id, like every run on the ticket.
    opts = [
      task_id: task.id,
      workspace_id: task.workspace_id,
      repo: context.repo || "unknown",
      meta: meta
    ]

    # `start_or_reap_terminal/1`, not `start/1`: an earlier run on the ticket
    # that went terminal (`:failed`) stays alive holding its key, because
    # nothing stops a failed worker. The Watchdog counts that as inactive and
    # re-dispatches, so plain `start/1` would return `:already_started` on
    # every poll from then on — burning the auto-resolve budget without ever
    # running a pass (bd-8lq2g7 / #1204).
    case Worker.start_or_reap_terminal(opts) do
      {:ok, pid} ->
        {:ok, pid}

      # A run is genuinely still working the ticket — this fix pass from a
      # previous tick, or another run. Don't open a second agent session on
      # the same worktree and branch (bd-8tjcms).
      {:error, {:already_started, pid}} ->
        {:error, Worker.live_run_refusal(task.id, pid, :fix_pass, :fix_pass_already_running)}

      # bd-8tjcms / #1511: another worker for this task is already driving an
      # agent (typically the primary, auto-resumed out of an
      # `{:awaiting_review_timeout, _}`). Starting this pass would put two
      # agents on one worktree and branch. Surface it distinctly so the
      # MergeQueue's escalation names the collision instead of a generic
      # spawn failure.
      {:error, {:task_worker_live, info}} ->
        {:error, {:task_worker_live, info}}

      {:error, reason} ->
        {:error, {:worker_start_failed, reason}}
    end
  end

  # `:start_claude` defaults to `true` for production. Tests pass
  # `start_claude: false` (and a `:claude_command` argv) so they can verify the
  # dispatcher was invoked without spawning a real Claude subprocess.
  defp maybe_start_claude(worker_pid, worktree_path, context, args, provider) do
    case Map.get(args, :start_claude, true) do
      false ->
        {:ok, nil}

      true ->
        # bd-7e8ezw: mint this pass its OWN worker token and write a fresh
        # `.mcp.json`. `Worktree.attach/2` may hand back the original run's
        # checkout, whose `.mcp.json` carries a token whose worker lease has
        # long expired, or a re-created one with no config at all. Either way
        # the pass reported the `arbiter` server "not connected" and could not
        # call `ci_mark_external` / `ci_rerun`, which its prompt tells it to use.
        mcp_opts =
          Dispatch.inject_mcp_config(context.task, worktree_path,
            repo: context.repo,
            agent_type: provider
          )

        # bd-asawcq: the worker token doubles as the agent's ARB_TOKEN.
        #
        # bd-7ays3v: under podman, a Claude pass runs in the container, in the
        # private clone `create_worktree/1` gave it, under the policy the task
        # worker resolves; any other pass is spawned exactly as before.
        session_opts =
          ([owner: worker_pid, worktree_path: worktree_path] ++
             Keyword.take(mcp_opts, [:arb_token]) ++ container_opts(context, provider))
          |> add_command_or_prompt(context, args, worktree_path, provider, mcp_opts)

        case ClaudeSession.start(session_opts) do
          {:ok, port} ->
            _ = Worker.advance(worker_pid, :fix_ci)
            {:ok, port}

          {:error, reason} ->
            {:error, {:claude_start_failed, reason}}
        end
    end
  end

  defp container_opts(context, provider) do
    case ContainerSpawn.pass_policy(context.workspace, context.repo, provider) do
      nil -> []
      policy -> ContainerSpawn.session_opts(policy, context.workspace, repo: context.repo)
    end
  end

  @doc false
  # The adapter opts for this pass's agent spawn. `:owner` is the pass's worker
  # (from the session opts): an agy adapter binds its egress run to it, so the
  # proxy lives exactly as long as the pass (bd-cfktou). `:task_id` keys that
  # run's `egress_events` rows. `:security` (`ContainerSpawn.pass_policy/3`,
  # bd-7ays3v) is present when the pass runs in a podman container.
  @spec agent_opts(keyword(), map(), String.t(), keyword()) :: keyword()
  def agent_opts(opts, context, worktree_path, mcp_opts) do
    [
      workspace: context.workspace,
      worktree_path: worktree_path,
      owner: Keyword.get(opts, :owner),
      task_id: context.task.id
    ] ++ mcp_opts ++ ContainerSpawn.pass_agent_opts(Keyword.get(opts, :security))
  end

  defp add_command_or_prompt(opts, context, args, worktree_path, provider, mcp_opts) do
    case Map.get(args, :claude_command) do
      cmd when is_list(cmd) and cmd != [] ->
        opts
        |> Keyword.put(:command, cmd)
        |> Keyword.put(:provider, Atom.to_string(provider))
        |> Keyword.put(:prompt, prompt_for(context))

      _ ->
        if context.workspace do
          :ok = Agents.prepare(context.workspace, :agent)
        end

        adapter = Agents.for_type(provider)
        prompt = prompt_for(context)

        agent_opts = agent_opts(opts, context, worktree_path, mcp_opts)

        case adapter.default_argv(prompt, agent_opts) do
          {:ok, argv} ->
            env = safe_spawn_env(adapter, agent_opts)

            opts
            |> Keyword.put(:command, argv)
            |> Keyword.put(:env, env)
            |> Keyword.put(:provider, Atom.to_string(provider))
            |> Keyword.put(:prompt, prompt)

          {:error, _} ->
            opts
            |> Keyword.put(:prompt, prompt)
            |> Keyword.put(:provider, Atom.to_string(provider))
        end
    end
  end

  defp safe_spawn_env(adapter, agent_opts) do
    if function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(agent_opts)
    else
      []
    end
  end

  @doc """
  Fix-pass prompt. Public for tests + introspection.

  The prompt is intentionally narrow: diagnose the failing checks, fix the root
  cause, commit, exit. It does NOT instruct the worker to re-implement the change
  set or open a new PR. Arbiter runs pre-push checks, pushes to the branch, and
  updates the PR. It is told to escalate via the mailbox when the failure isn't
  something it can fix, rather than thrashing.

  Two non-code outs are spelled out (bd-5mzzww): `ci_rerun` for a failure that a
  rebuild would clear — with the granularity trap named explicitly, because
  re-running only the failed jobs reuses the stale upstream artifact that caused
  the failure — and `ci_mark_external` for an "infra, not my diff" verdict, which
  previously had nowhere to go but free-text chat nobody read.
  """
  @spec prompt_for(map()) :: String.t()
  def prompt_for(%{task: %Issue{id: task_id}, branch: branch, target_branch: target} = context) do
    """
    You are a CI fix-pass worker for task #{task_id}.

    Your branch (#{branch}) has an open, approved PR against #{target}, but it
    cannot merge because its required CI checks are FAILING. Your ONLY job is to
    make those checks pass:

      1. Read the failing checks below and reproduce the failure locally where
         you can (run the failing test / linter / build).
      2. Fix the ROOT CAUSE in the code. Do not paper over a real failure by
         deleting or skipping the test unless the test itself is genuinely wrong.
      3. Commit your fix (do NOT push):
         `git commit -m "<a short message>"`
         Arbiter runs this repo's pre-push checks, pushes to `#{branch}` for you,
         and updates the PR (do NOT open a new PR).
      4. Exit by printing `arb done` on a line by itself.

    Failing checks:
    #{render_checks(Map.get(context, :checks) || [])}
    #{render_outside_diff(Map.get(context, :outside_diff_files) || [])}
    DO NOT:
      * re-implement the change set,
      * open a new PR,
      * touch files unrelated to the failure,
      * disable or skip the check to make it "pass".

    If the check failed for a reason that is NOT in your diff — a stale build
    artifact, a review app an EARLIER job in the same run deployed, a flaky
    external service — you do not have to change code to clear it. Re-run CI
    with the `ci_rerun` MCP tool, and pick the granularity deliberately:

      * `failed_jobs` re-runs ONLY the failed jobs and REUSES every job that
         already succeeded. If the failing check tests something an earlier job
         in the same run produced (a deployed review app, a built image), this
         re-tests the identical stale input and will fail identically. Never use
         it twice in a row — a repeat of an identical re-run tells you nothing.
      * `all_jobs` re-runs the whole run, REBUILDING the upstream jobs. This is
         the right choice for a stale-artifact failure.
      * `workflow` fires a fresh workflow_dispatch and is the only mode that can
         carry inputs (e.g. `{"force_deploy": "true"}`).

    The default mode, `auto`, picks between them for you; override it only when
    you know something it doesn't.

    Whenever you conclude the failure was a FLAKE — you re-ran the job with NO
    code change and it went green — record that with the `flake_record` MCP tool
    BEFORE you exit: pass `ci_job` (the failing check's name) and `signature` (a
    short, distinctive fragment of the failure — a log line, error message, or
    teardown name), and `test_file`/`test_line` when you can identify the
    specific failing test. This is what lets a flake that keeps recurring across
    fix_passes get counted and surfaced, instead of the conclusion living only in
    this run's closing summary. Do this for every flake conclusion, whether or
    not you also call `ci_rerun` or `ci_mark_external`.

    If you conclude the failure is broken infrastructure repo-wide rather than
    anything about this branch — you have evidence, such as the same check
    failing on unrelated branches today, and nothing in this diff touching the
    failing path — record that verdict with the `ci_mark_external` MCP tool
    (`note:` your evidence, in a sentence or two). That reclassifies the park so
    the coordinator escalation reads "CI is broken repo-wide, not on this
    branch" instead of looking like ordinary broken code, and puts your note in
    front of whoever decides to force-merge. Do this INSTEAD of vanishing with
    the diagnosis in your head.

    If the failure is NOT something you can fix and NOT something the above
    covers — a failure you cannot reproduce or understand — STOP and escalate
    by running:

        arb message coordinator "CI fix-pass on #{task_id} needs human review: <one-line explanation>"

    then print `arb done`. Better a loud escalation than a thrashing fix loop.
    """
  end

  def prompt_for(_) do
    "You are a CI fix-pass worker. Diagnose the failing checks, fix the root cause, commit, exit."
  end

  # bd-2l0hzm: the Watchdog re-ran CI because every failing test was outside
  # the diff, and a test that failed before failed again. On #2003 a pass
  # "fixed" an unrelated flaky test on a docs-only branch; this says not to.
  defp render_outside_diff([]), do: ""

  defp render_outside_diff(files) do
    """
    The failing test file(s) below are NOT in this PR's diff:
    #{Enum.map_join(files, "\n", &("  * " <> &1))}
    CI was already re-run once on this head and a test failed again, so the
    failure reproduces. Do not edit those test files. Work out how THIS PR's
    changes break them and fix the PR's own code. If nothing in the diff can
    reach them, it is a flake or a failure repo-wide: record it with
    `flake_record` or `ci_mark_external` (below), not a code change.
    """
  end

  @doc """
  Render the failing-check briefing block. Public for tests + introspection.
  """
  @spec render_checks([failing_check()]) :: String.t()
  def render_checks([]),
    do: "  (No check details were captured — inspect the PR's CI tab for the failing checks.)"

  def render_checks(checks) when is_list(checks) do
    checks
    |> Enum.map_join("\n\n", &render_check/1)
  end

  defp render_check(%{} = check) do
    name = Map.get(check, :name) || Map.get(check, "name") || "check"
    summary = Map.get(check, :summary) || Map.get(check, "summary") || ""
    url = Map.get(check, :url) || Map.get(check, "url")

    [
      "  * #{name}" <> if(url, do: " (#{url})", else: ""),
      summary != "" && indent(summary)
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join("\n")
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("      " <> &1))
  end
end
