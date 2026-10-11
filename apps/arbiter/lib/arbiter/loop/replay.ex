defmodule Arbiter.Loop.Replay do
  @moduledoc """
  The offline replay harness (R15, bd-c7lx65;
  `docs/design/paced-quota-routing-signals.md` §7.2-§7.3): re-run a closed task
  on another model, in an isolated checkout at the task's base commit, with no
  PR and no merge, and score the result against the change that merged. The
  design's first step for any new model: evidence with no production exposure,
  for the difficulty and type mix the operator picks.

  ## One replay (`run/1`)

    1. **The subject** (`Arbiter.Loop.Replay.Subject`): a closed, completed
       task with no permissions, its base commit and its known-good change.
    2. **Who runs.** The replayed model on an account attached to the task's
       workspace (so it is held to that workspace's policy and spends that
       account's credential); and the scoring reviewer, by default the one the
       fleet would use for that implementer (the cross-family projection, else
       the workspace's reviewer). Each draws on one pool.
    3. **Admission** (`Arbiter.Loop.Replay.Admission`): only into expiring
       headroom. Both pools must have room in their exploration budget (half of
       what would reset unused, in seats) beside the replays already running
       there, or the replay is refused before anything runs. Admission is
       serialised, and the record it writes (`:running`) holds the seats.
    4. **The sandbox** (`Arbiter.Loop.Replay.Sandbox`): a repository of its own
       at the base commit, borrowing the main repo's objects, with no remote
       and nothing after the base in it; seeded with dependencies as a
       dispatch's worktree is.
    5. **The replayed model** implements the ticket (`Arbiter.Loop.Replay.Runner`).
    6. **The score** (`Arbiter.Loop.Replay.Score`): what it changed against the
       base, the repo's pre-push recipe as its tests, and the overlap with the
       merged change. Unless it changed nothing (scored without a review), the
       reviewer's pool is admitted again, and the live ReviewGate prompt gets
       one round-1 verdict, read by the live gate's `converged` rule.
    7. **The record** (`Arbiter.Loop.ReplayRun`) is finished, and the sandbox
       removed, whatever happened.

  ## What it never does

  It never merges, pushes, opens or touches a PR, and never writes to the
  ticket, `worker_runs`, `review_gate_rounds`, `usage_events` or the
  competence matrix: replay evidence is its own source
  (`Arbiter.Loop.Replay.Evidence`), and only an operator, through a canary, may
  ever act on it. `Arbiter.Loop.ReplayIsolationTest` pins that structurally and
  that nothing on a live dispatch, routing, gate or budget path calls it.

  ## Where it runs

  Admission reads the budgets the live node publishes, so a replay runs there:

      bin/arbiter rpc 'Arbiter.Release.replay(task_id: "bd-…", account: "claude:default", model: "claude-sonnet-5-5")'

  Anywhere else nothing is published, and every replay is refused.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ReviewerRouting
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Config.Paths
  alias Arbiter.Loop.Replay.Admission
  alias Arbiter.Loop.Replay.Prompt
  alias Arbiter.Loop.Replay.Sandbox
  alias Arbiter.Loop.Replay.Score
  alias Arbiter.Loop.Replay.Subject
  alias Arbiter.Loop.ReplayRun
  alias Arbiter.Worker.PrepushCheck
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.ReviewVerification
  alias Arbiter.Worker.SeedPaths
  alias Arbiter.Worker.Worktree

  @implement_timeout_ms 60 * 60_000
  @review_timeout_ms 30 * 60_000

  # A replay still `:running` this long after it started died with its node (a
  # finished one is always finished): its seats are free again. Longer than
  # the implement, review and test budgets put together.
  @stale_after_s 6 * 3600

  @max_files 200

  @type side :: %{
          provider: atom(),
          account_id: String.t(),
          model: String.t(),
          pool: String.t()
        }

  @type result ::
          {:ok, ReplayRun.t()}
          | {:refused, ReplayRun.t()}
          | {:failed, ReplayRun.t()}
          | {:error, term()}

  @doc """
  Replay one closed task. Returns the finished record: `{:ok, run}` when it was
  scored (or ran but its scoring review was not admitted: `state: :unscored`),
  `{:refused, run}` when it was not admitted, `{:failed, run}` when it broke
  after admission. `{:error, reason}`, with no record, when it could not be set
  up: an ineligible task, an unknown or unattached account, no runner.

  Options:

    * `:task_id` (required) — the closed task.
    * `:account` (required) — the account the replayed model runs on (an id,
      `"provider:slug"` or a bare slug), attached to the task's workspace.
    * `:model` (required) — the model to replay with.
    * `:reviewer`, `:reviewer_model` — the scoring reviewer's account and model;
      by default the fleet's reviewer for the replayed model's family, at the
      task's reviewer tier.
    * `:tests` — run the repo's pre-push recipe as the tests signal (default
      `true`; nothing runs when the repo has no recipe).
    * `:timeout_ms` (default 60 min), `:review_timeout_ms` (default 30 min).
    * `:root` — where sandboxes live (default `<scratch_root>/replays`).
    * `:runner` — an `Arbiter.Loop.Replay.Runner` module or a two-arity
      function; default `config :arbiter, :loop_replay_runner`.
    * `:budget_fun` — `(account_id, pool -> budget | nil)`; default the budgets
      the live node publishes (`Admission.published/3`).
    * `:now`, and `:keep_sandbox` (default `false`) for debugging.
  """
  @spec run(keyword()) :: result()
  def run(opts) do
    opts = Map.new(opts)
    now = Map.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, runner} <- runner(opts),
         {:ok, task_id} <- required(opts, :task_id),
         {:ok, subject} <- Subject.resolve(task_id),
         {:ok, author} <- author(opts, subject),
         {:ok, reviewer} <- reviewer(opts, subject, author, now) do
      budget_fun = budget_fun(opts, subject)

      case admit(subject, author, reviewer, budget_fun, now) do
        {:running, run} ->
          execute(run, %{
            subject: subject,
            author: author,
            reviewer: reviewer,
            runner: runner,
            budget_fun: budget_fun,
            now: now,
            opts: opts
          })

        {:refused, run} ->
          {:refused, run}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Run `run/1` under `Arbiter.TaskSupervisor` and return at once: for
  `bin/arbiter rpc`, whose caller need not stay attached for the hour a replay
  can take. Follow it with `Arbiter.Release.replay_report/1`.
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts) do
    Task.Supervisor.start_child(Arbiter.TaskSupervisor, fn ->
      result = run(opts)

      Logger.info(
        "Loop.Replay: #{inspect(Keyword.get(opts, :task_id))} → #{describe_result(result)}"
      )
    end)
  end

  @doc """
  The replays running at `now`: `:running` and started within the last
  #{div(@stale_after_s, 3600)} hours. Each holds a seat on both its pools.
  """
  @spec running(DateTime.t()) :: [ReplayRun.t()]
  def running(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@stale_after_s, :second)

    ReplayRun
    |> Ash.Query.filter(state == :running and started_at > ^cutoff)
    |> Ash.read!()
  end

  # ---- setup -------------------------------------------------------------------

  defp runner(opts) do
    case Map.get(opts, :runner) || Application.get_env(:arbiter, :loop_replay_runner) ||
           Arbiter.Loop.Replay.CliRunner do
      :disabled -> {:error, :runner_disabled}
      fun when is_function(fun, 2) -> {:ok, %{run: fun, layout: &host_layout/2}}
      module when is_atom(module) -> {:ok, %{run: &module.run/2, layout: layout_fun(module)}}
    end
  end

  defp layout_fun(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :layout, 2),
      do: &module.layout/2,
      else: &host_layout/2
  end

  defp host_layout(_role, _spec), do: :sandbox

  defp required(opts, key) do
    case Map.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp author(opts, subject) do
    with {:ok, model} <- required(opts, :model),
         {:ok, ref} <- required(opts, :account),
         {:ok, account} <- account(ref),
         :ok <- attached(account, subject.workspace) do
      side(account, model)
    end
  end

  defp reviewer(opts, subject, author, now) do
    case Map.get(opts, :reviewer) do
      nil ->
        fleet_reviewer(subject, author, Map.get(opts, :reviewer_model), now)

      ref ->
        with {:ok, account} <- account(ref),
             :ok <- attached(account, subject.workspace) do
          model =
            Map.get(opts, :reviewer_model) ||
              predicted_model(subject, adapter(account.provider))

          side(account, model)
        end
    end
  end

  # The reviewer the fleet would put on this implementer: the cross-family
  # projection where that applies (a read, `pin: false`), else the workspace's
  # reviewer on the workspace's account for it.
  defp fleet_reviewer(subject, author, model, now) do
    ws = subject.workspace
    family = ModelFamily.classify(author.provider, author.model).family

    projected =
      case ReviewerRouting.project(ws, family, tier: reviewer_tier(subject), now: now) do
        {:ok, %{account_id: id, model: projected_model}} when is_binary(id) ->
          {id, model || projected_model}

        _ ->
          type = Agents.reviewer_type(ws)
          {Resolver.account_id(ws.id, type), model || predicted_model(subject, type)}
      end

    case projected do
      {nil, _model} ->
        {:error, :no_reviewer_account}

      {id, model} ->
        with {:ok, account} <- account(id), do: side(account, model)
    end
  end

  defp reviewer_tier(subject),
    do: ByDifficulty.reviewer_tier(subject.workspace.config, subject.difficulty)

  defp predicted_model(subject, type),
    do: ReviewerRouting.predicted_model(subject.workspace, type, tier: reviewer_tier(subject))

  defp account(ref) do
    case Accounts.get_account(ref) do
      {:ok, %ProviderAccount{enabled: true, deleted_at: nil} = account} -> {:ok, account}
      {:ok, %ProviderAccount{}} -> {:error, {:account_disabled, ref}}
      {:error, _} -> {:error, {:unknown_account, ref}}
    end
  end

  # The run spends the workspace's credential for the account's provider, so
  # the account must be the one the workspace is attached to: otherwise the
  # draw lands on a pool other than the one admitted.
  defp attached(%ProviderAccount{} = account, ws) do
    if Resolver.account_id(ws.id, account.provider) == account.id,
      do: :ok,
      else: {:error, {:account_not_in_workspace, account.id}}
  end

  defp side(account, model) when is_binary(model) and model != "" do
    case ModelFamily.classify(account.provider, model).pool do
      nil ->
        {:error, {:no_pool, account.provider, model}}

      pool ->
        {:ok, %{provider: account.provider, account_id: account.id, model: model, pool: pool}}
    end
  end

  defp side(account, _model), do: {:error, {:no_model, account.id}}

  defp budget_fun(opts, subject) do
    Map.get(opts, :budget_fun) ||
      fn account_id, pool -> Admission.published(account_id, pool, subject.workspace.id) end
  end

  # ---- admission ---------------------------------------------------------------

  defp admit(subject, author, reviewer, budget_fun, now) do
    pools = [{author.account_id, author.pool}, {reviewer.account_id, reviewer.pool}]

    serialised(fn ->
      running = now |> running() |> Admission.running()

      {state, reason, entries} =
        case Admission.check(pools, budget_fun, running) do
          {:ok, entries} -> {:running, nil, entries}
          {:refused, reason, entries} -> {:refused, reason, entries}
        end

      attrs =
        subject
        |> record_attrs(author, reviewer)
        |> Map.merge(%{
          state: state,
          reason: reason,
          admission: entries,
          started_at: now,
          finished_at: if(state == :refused, do: DateTime.utc_now())
        })

      case Ash.create(ReplayRun, attrs) do
        {:ok, run} -> {state, run}
        {:error, error} -> {:error, {:record_failed, error}}
      end
    end)
  end

  # Two replays admitted at once must not both count the other as absent.
  defp serialised(fun), do: :global.trans({__MODULE__, self()}, fun)

  defp record_attrs(subject, author, reviewer) do
    %{
      task_id: subject.task_id,
      workspace_id: subject.workspace.id,
      repo: subject.repo,
      difficulty: subject.difficulty,
      issue_type: subject.issue_type,
      live_provider: subject.live_provider,
      live_model: subject.live_model,
      base_sha: subject.base_sha,
      known_good_sha: subject.known_good_sha,
      provenance: subject.provenance,
      provider: to_string(author.provider),
      account_id: author.account_id,
      model: author.model,
      pool: author.pool,
      reviewer_provider: to_string(reviewer.provider),
      reviewer_account_id: reviewer.account_id,
      reviewer_model: reviewer.model,
      reviewer_pool: reviewer.pool
    }
  end

  # ---- the replay ----------------------------------------------------------------

  defp execute(run, ctx) do
    ctx = Map.merge(ctx, %{dir: Path.join(root(ctx.opts), run.id), run: run})
    layout = layout(ctx)
    ctx = Map.merge(ctx, %{layout: layout, checkout: checkout_path(layout, ctx)})

    outcome =
      try do
        replay(ctx)
      rescue
        error -> {:failed, %{reason: Exception.message(error)}}
      catch
        kind, reason -> {:failed, %{reason: Exception.format_banner(kind, reason)}}
      after
        unless Map.get(ctx.opts, :keep_sandbox, false), do: remove(ctx)
      end

    finish(run, outcome)
  end

  defp root(opts), do: Map.get(opts, :root) || Path.join(Paths.scratch_root(), "replays")

  # The checkout the runs need: a container can only be handed a private clone
  # (`layout/2` of the runner, for either side), anything else runs on the host
  # in the sandbox. `:layout` overrides it (tests).
  defp layout(ctx) do
    case Map.get(ctx.opts, :layout) do
      layout when layout in [:sandbox, :private_clone] ->
        layout

      _ ->
        if Enum.any?(
             [:implement, :review],
             &(ctx.runner.layout.(&1, spec(ctx, &1)) == :private_clone)
           ),
           do: :private_clone,
           else: :sandbox
    end
  end

  # A private clone lives where every clone does, as a leaf of the worktree root.
  defp checkout_path(:private_clone, ctx),
    do: Path.join(Paths.worktree_root(), "replay-" <> ctx.run.id)

  defp checkout_path(:sandbox, ctx), do: Path.join(ctx.dir, "checkout")

  defp remove(%{layout: :private_clone} = ctx) do
    case PrivateClone.remove(ctx.checkout) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Loop.Replay: removing #{ctx.checkout}: #{inspect(reason)}")
    end

    Sandbox.remove(ctx.dir)
  end

  defp remove(ctx), do: Sandbox.remove(ctx.dir)

  defp replay(%{subject: subject} = ctx) do
    with :ok <- File.mkdir_p(scratch(ctx)),
         {:ok, branch} <- checkout(ctx),
         ctx = %{ctx | subject: Map.put(subject, :branch, branch)},
         {:ok, known_good} <-
           Sandbox.known_good(subject.repo_path, subject.base_sha, subject.known_good_sha),
         {:ok, implemented} <-
           call(ctx, :implement, Prompt.implement(ctx.subject, adapter(ctx.author.provider))),
         {:ok, change} <- Sandbox.change(ctx.checkout, subject.base_sha) do
      measured = %{
        files: Enum.take(change.files, @max_files),
        overlap: Score.overlap(change, known_good),
        runs: %{"implement" => run_summary(implemented)}
      }

      if change.files == [] do
        {:scored,
         Map.merge(measured, %{
           converged: false,
           tests: :not_run,
           reason: "no change: the replay left the checkout as it found it"
         })}
      else
        measured
        |> Map.merge(tests(ctx))
        |> review(ctx)
      end
    else
      {:error, reason} -> {:failed, %{reason: describe(reason)}}
    end
  end

  defp scratch(ctx), do: Path.join(ctx.dir, "scratch")

  # The checkout at the base commit, and the branch it is on. On the host: the
  # sandbox, seeded with dependencies as a dispatch's worktree is. For a
  # container: a read-only private clone with nothing after the base in it,
  # whose `origin` (the forge, for a review clone) is pointed nowhere so the
  # merged change cannot be fetched; the container brings its own dependencies.
  defp checkout(%{layout: :sandbox, checkout: checkout, subject: subject}) do
    with {:ok, _} <- Sandbox.create(subject.repo_path, subject.base_sha, checkout),
         :ok <- seed(subject, checkout) do
      {:ok, Sandbox.branch()}
    end
  end

  defp checkout(%{layout: :private_clone, checkout: checkout, subject: subject}) do
    with {:ok, _} <-
           PrivateClone.create_review(subject.repo_path, subject.base_sha, path: checkout),
         :ok <- Sandbox.disconnect(checkout) do
      Sandbox.current_branch(checkout)
    end
  end

  # The dependency trees a dispatch's worktree is seeded with, and excluded from
  # the change: the built-in set (`deps`, `_build`) records nothing, a
  # configured one records what it copied.
  defp seed(subject, checkout) do
    paths = SeedPaths.resolve(subject.workspace, subject.repo)
    :ok = Worktree.seed_worktree(subject.repo_path, checkout, paths)
    seeded = if paths == nil, do: ["deps", "_build"], else: Worktree.seeded_paths(checkout)
    Sandbox.exclude(checkout, seeded)
  end

  defp tests(%{subject: subject, checkout: checkout, opts: opts} = ctx) do
    spec = Map.get(opts, :tests, true) && PrepushCheck.resolve(subject.workspace, subject.repo)

    if spec do
      # The recipe runs on the host: a private clone gets the host's
      # dependencies now, after the container (and the change) are done with it.
      if ctx.layout == :private_clone, do: seed(subject, checkout)

      %{result: result, steps: steps} =
        PrepushCheck.run_steps(spec, checkout, target: subject.base_sha)

      %{
        tests: tests_outcome(result),
        tests_steps: Enum.map(steps, &Map.take(&1, [:name, :status, :exit_status, :duration_ms]))
      }
    else
      %{tests: :not_run}
    end
  end

  defp tests_outcome(:ok), do: :passed
  defp tests_outcome({:failed, _status, _output}), do: :failed
  defp tests_outcome({:timeout, _output}), do: :timeout
  defp tests_outcome(_error), do: :error

  # The scoring review spends the reviewer's pool, so it is admitted again: the
  # implement run may have taken an hour, and the pool's expiring headroom with
  # it. This replay already holds a seat there, so only the others count.
  defp review(measured, %{reviewer: reviewer, run: run} = ctx) do
    others = ctx.now |> running() |> Enum.reject(&(&1.id == run.id)) |> Admission.running()

    case Admission.check([{reviewer.account_id, reviewer.pool}], ctx.budget_fun, others) do
      {:refused, reason, _entries} ->
        {:unscored, Map.put(measured, :reason, "scoring review not admitted: " <> reason)}

      {:ok, _entries} ->
        prompt = Prompt.review(ctx.subject, adapter(reviewer.provider))

        with {:ok, reviewed} <- call(ctx, :review, prompt),
             {:ok, empty?} <- Sandbox.committed_empty?(ctx.checkout, ctx.subject.base_sha) do
          {:scored,
           measured |> score(reviewed, empty?, ctx.subject) |> put_run("review", reviewed)}
        else
          {:error, reason} -> {:failed, Map.put(measured, :reason, describe(reason))}
        end
    end
  end

  defp score(measured, reviewed, empty?, subject) do
    {verdict, findings} = Score.verdict(reviewed.output)
    {total, unmet} = ReviewVerification.criteria_counts(findings)

    Map.merge(measured, %{
      verdict: verdict,
      criteria_total: total,
      criteria_unmet: unmet,
      converged:
        Score.converged?(%{
          verdict: verdict,
          findings: findings,
          acceptance: subject.issue.acceptance,
          net_diff_empty?: empty?
        })
    })
  end

  defp put_run(measured, name, result), do: put_in(measured, [:runs, name], run_summary(result))

  defp call(ctx, role, prompt) do
    case ctx.runner.run.(role, Map.put(spec(ctx, role), :prompt, prompt)) do
      {:ok, %{output: output} = result} when is_list(output) -> {:ok, result}
      {:error, reason} -> {:error, {role, reason}}
      other -> {:error, {role, {:bad_runner_result, other}}}
    end
  end

  # What a runner is told about one side's run (the prompt aside).
  defp spec(ctx, role) do
    side = if role == :implement, do: ctx.author, else: ctx.reviewer

    timeout =
      if role == :implement,
        do: Map.get(ctx.opts, :timeout_ms, @implement_timeout_ms),
        else: Map.get(ctx.opts, :review_timeout_ms, @review_timeout_ms)

    %{
      replay_id: ctx.run.id,
      dir: Map.get(ctx, :checkout),
      scratch: scratch(ctx),
      prompt: nil,
      provider: side.provider,
      account_id: side.account_id,
      model: side.model,
      workspace: ctx.subject.workspace,
      repo: ctx.subject.repo,
      timeout_ms: timeout
    }
    |> Map.merge(Map.take(ctx.opts, [:container_opts]))
  end

  defp run_summary(result) do
    Map.take(result, [:exit_status, :timed_out, :duration_ms])
  end

  defp adapter(:antigravity), do: :gemini
  defp adapter(provider), do: provider

  # ---- the record ------------------------------------------------------------------

  defp finish(run, {state, fields}) do
    overlap = Map.get(fields, :overlap, %{})

    runs =
      case Map.get(fields, :tests_steps) do
        nil -> Map.get(fields, :runs, %{})
        steps -> Map.put(Map.get(fields, :runs, %{}), "tests", steps)
      end

    attrs = %{
      state: state,
      reason: Map.get(fields, :reason),
      verdict: Map.get(fields, :verdict),
      converged: if(state == :scored, do: Map.get(fields, :converged)),
      criteria_total: Map.get(fields, :criteria_total),
      criteria_unmet: Map.get(fields, :criteria_unmet),
      tests: Map.get(fields, :tests),
      file_overlap: Map.get(overlap, :files),
      line_overlap: Map.get(overlap, :lines),
      files: Map.get(fields, :files, []),
      runs: runs,
      finished_at: DateTime.utc_now()
    }

    case Ash.update(run, attrs, action: :finish) do
      {:ok, finished} -> {tag(state), finished}
      {:error, error} -> {:error, {:record_failed, error}}
    end
  end

  defp tag(:failed), do: :failed
  defp tag(_scored_or_unscored), do: :ok

  defp describe({role, reason}) when role in [:implement, :review],
    do: "#{role} run failed: #{describe(reason)}"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp describe_result({tag, %ReplayRun{} = run}),
    do: "#{tag} #{run.id} (#{run.state}#{if run.reason, do: ": " <> run.reason})"

  defp describe_result(other), do: inspect(other)
end
