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
    3. **Confinement** (the runner's `layout/2`). A replayed model is
       untrusted, so every model a replay runs is OS-confined (a container, or
       a provider's own network jail; a permission layer alone is not one), or
       the replay is refused here, before admission, with no record.
    4. **Admission** (`Arbiter.Loop.Replay.Admission`): only into expiring
       headroom. Both pools must have room in their exploration budget (half of
       what would reset unused, in seats) beside the replays already running
       there, or the replay is refused before anything runs. Admission is
       serialised, and the record it writes (`:running`, with the deadline it
       must be done by) holds the seats.
    5. **The checkout** at the base commit, seeded with dependencies as a
       dispatch's worktree is, before any model runs in it: on the host the
       sandbox (`Arbiter.Loop.Replay.Sandbox`), a repository of its own with no
       remote and nothing after the base in it; for a container a read-only
       `Arbiter.Worker.PrivateClone` whose `origin` leads nowhere.
    6. **The replayed model** implements the ticket (`Arbiter.Loop.Replay.Runner`).
    7. **The score** (`Arbiter.Loop.Replay.Score`): what it changed against the
       base, the repo's pre-push recipe as its tests (in the replayed model's
       container, never on the host: they run its code), and the overlap with
       the merged change. Unless it changed nothing (scored without a review),
       the reviewer's pool is admitted again, and the live ReviewGate prompt
       gets one round-1 verdict, read by the live gate's `converged` rule.
    8. **The record** (`Arbiter.Loop.ReplayRun`) is finished, and the checkout
       removed, whatever happened. A replay whose node stopped mid-run cannot
       clean up after itself, so each replay first sweeps: a record still
       `:running` past its deadline is finished as abandoned, and the checkout
       of any replay not running now is removed.

  ## Host git in a checkout a model ran in

  The models can write the checkout's `.git`, and git runs programs a
  repository's own config names. Host git runs there only while the checkout
  is as the harness left it (`Sandbox.verify/2`; for a clone,
  `PrivateClone.verify/1` and its `arbiter.*` markers): a replay whose
  checkout is not is failed, unscored. A clone goes with
  `PrivateClone.discard/2`, never `remove/1`, whose sync-back trusts those
  markers.

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
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Config.Paths
  alias Arbiter.Loop.Replay.Admission
  alias Arbiter.Loop.Replay.Prompt
  alias Arbiter.Loop.Replay.Sandbox
  alias Arbiter.Loop.Replay.Score
  alias Arbiter.Loop.Replay.Subject
  alias Arbiter.Loop.ReplayRun
  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.PrepushCheck
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.ReviewVerification
  alias Arbiter.Worker.SeedPaths
  alias Arbiter.Worker.Worktree

  @implement_timeout_ms 60 * 60_000
  @review_timeout_ms 30 * 60_000

  # On top of the runs' timeouts and the tests' budget, for the rest of a
  # replay (the checkout and its dependencies, starting containers): a replay
  # still `:running` past all of it died with its node.
  @slack_ms 30 * 60_000

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
  up: an ineligible task, an unknown or unattached account, no runner, or a
  side the runner cannot confine (`{:unconfined, role, type}`, or
  `{:layout_failed, message}` when it could not say).

  Options:

    * `:task_id` (required) — the closed task.
    * `:account` (required) — the account the replayed model runs on (an id,
      `"provider:slug"` or a bare slug), attached to the task's workspace.
    * `:model` (required) — the model to replay with.
    * `:reviewer`, `:reviewer_model` — the scoring reviewer's account and model;
      by default the fleet's reviewer for the replayed model's family, at the
      task's reviewer tier.
    * `:thinking`, `:reviewer_thinking` — the level each side runs at; by
      default the one a dispatch would use (the `by_difficulty` rule for the
      task's difficulty; the reviewer slot's config, or a cross-family
      selection's own).
    * `:tests` — run the repo's pre-push recipe as the tests signal (default
      `true`). It runs only where the replayed model ran in a container, in a
      container again; a replay on the host, or a repo with no recipe, is
      `:not_run`.
    * `:timeout_ms` (default 60 min), `:review_timeout_ms` (default 30 min).
    * `:root` — where sandboxes live (default `<scratch_root>/replays`).
    * `:runner` — an `Arbiter.Loop.Replay.Runner` module or a two-arity
      function (which runs on the host); default
      `config :arbiter, :loop_replay_runner`.
    * `:layout` — `:sandbox` or `:private_clone` for both sides, in place of
      the runner's `layout/2` (tests).
    * `:budget_fun` — `(account_id, pool -> budget | nil)`; default the budgets
      the live node publishes (`Admission.published/3`).
    * `:now`, and `:keep_sandbox` (default `false`) for debugging.
  """
  @spec run(keyword()) :: result()
  def run(opts) do
    with {:ok, ctx} <- prepare(opts), do: admit_and_run(ctx)
  end

  @doc """
  `run/1` under `Arbiter.TaskSupervisor`, returning at once: for `bin/arbiter
  rpc`, whose caller need not stay attached for the hour a replay can take.
  What `run/1` would refuse before admission (`{:error, reason}`: an
  ineligible task, an account, a model the runner cannot confine) is refused
  here, before anything starts. Follow one that starts with
  `Arbiter.Release.replay_report/1`.
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts) do
    with {:ok, ctx} <- prepare(opts) do
      Task.Supervisor.start_child(Arbiter.TaskSupervisor, fn ->
        result = admit_and_run(ctx)
        Logger.info("Loop.Replay: #{inspect(ctx.subject.task_id)}: #{describe_result(result)}")
      end)
    end
  end

  @doc """
  The replays running at `now`: `:running` and not yet past their deadline.
  Each holds a seat on both its pools.
  """
  @spec running(DateTime.t()) :: [ReplayRun.t()]
  def running(now \\ DateTime.utc_now()) do
    ReplayRun
    |> Ash.Query.filter(state == :running and deadline_at > ^now)
    |> Ash.read!()
  end

  # ---- setup -------------------------------------------------------------------

  # Everything decided before admission. An `{:error, reason}` here leaves no
  # record and spends nothing.
  defp prepare(opts) do
    opts = Map.new(opts)
    now = Map.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, runner} <- runner(opts),
         {:ok, task_id} <- required(opts, :task_id),
         {:ok, subject} <- Subject.resolve(task_id),
         {:ok, author} <- author(opts, subject),
         {:ok, reviewer} <- reviewer(opts, subject, author, now),
         ctx = %{
           subject: subject,
           author: author,
           reviewer: reviewer,
           runner: runner,
           recipe: recipe(opts, subject),
           budget_fun: budget_fun(opts, subject),
           now: now,
           opts: opts
         },
         {:ok, layouts} <- layouts(ctx) do
      {:ok, Map.put(ctx, :layouts, layouts)}
    end
  end

  defp admit_and_run(ctx) do
    :ok = sweep(ctx.opts, ctx.now)

    case admit(ctx) do
      {:running, run} -> execute(run, ctx)
      {:refused, run} -> {:refused, run}
      {:error, _} = error -> error
    end
  end

  defp runner(opts) do
    case Map.get(opts, :runner) || Application.get_env(:arbiter, :loop_replay_runner) ||
           Arbiter.Loop.Replay.CliRunner do
      :disabled -> {:error, :runner_disabled}
      fun when is_function(fun, 2) -> {:ok, %{run: fun, layout: &host_layout/2}}
      module when is_atom(module) -> {:ok, %{run: &module.run/2, layout: &module.layout/2}}
    end
  end

  defp host_layout(_role, _spec), do: {:ok, :sandbox}

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
         :ok <- attached(account, subject.workspace),
         {:ok, side} <- side(account, model) do
      {:ok, Map.put(side, :thinking, Map.get(opts, :thinking) || dispatch_thinking(subject))}
    end
  end

  defp reviewer(opts, subject, author, now) do
    with {:ok, side, selected_thinking} <- reviewer_side(opts, subject, author, now) do
      thinking =
        Map.get(opts, :reviewer_thinking) || selected_thinking ||
          reviewer_block(subject.workspace)["thinking"]

      {:ok, Map.put(side, :thinking, thinking)}
    end
  end

  defp reviewer_side(opts, subject, author, now) do
    case Map.get(opts, :reviewer) do
      nil ->
        fleet_reviewer(subject, author, Map.get(opts, :reviewer_model), now)

      ref ->
        with {:ok, account} <- account(ref),
             :ok <- attached(account, subject.workspace),
             model =
               Map.get(opts, :reviewer_model) ||
                 predicted_model(subject, adapter(account.provider)),
             {:ok, side} <- side(account, model) do
          {:ok, side, nil}
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
        {:ok, %{account_id: id, model: projected_model} = selection} when is_binary(id) ->
          {id, model || projected_model, Map.get(selection, :thinking)}

        _ ->
          type = Agents.reviewer_type(ws)
          {Resolver.account_id(ws.id, type), model || predicted_model(subject, type), nil}
      end

    case projected do
      {nil, _model, _thinking} ->
        {:error, :no_reviewer_account}

      {id, model, thinking} ->
        with {:ok, account} <- account(id),
             {:ok, side} <- side(account, model),
             do: {:ok, side, thinking}
    end
  end

  # The thinking level a dispatch of the task would run at: the `by_difficulty`
  # rule for its difficulty (never a canary's overlay; a replay is in no arm),
  # else the worker block's (`agent.config`), as `Arbiter.Agents.Routing` reads
  # them. The policy itself is not asked: one can keep state (a round-robin
  # cursor) that a replay must not move.
  defp dispatch_thinking(%{workspace: ws, difficulty: difficulty}) do
    block = Routing.default_choice(ws).config["thinking"]

    if Routing.policy_for_workspace(ws) == ByDifficulty do
      d = ByDifficulty.effective_difficulty(difficulty)
      rule = get_in(ws.config || %{}, ["routing", "rules", "D#{d}"]) || %{}
      rule["thinking"] || ByDifficulty.default_mapping()[d]["thinking"] || block
    else
      block
    end
  end

  # The reviewer slot's own config, as the live gate reads it.
  defp reviewer_block(ws) do
    get_in(ws.config || %{}, ["review_agent", "config"]) ||
      get_in(ws.config || %{}, ["agent", "config"]) || %{}
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

  # The repo's pre-push recipe, the tests signal: `nil` with none, or `tests: false`.
  defp recipe(opts, subject) do
    if Map.get(opts, :tests, true), do: PrepushCheck.resolve(subject.workspace, subject.repo)
  end

  # Where each side runs, from the runner, before admission: a side it cannot
  # confine refuses the replay with nothing spent and no record.
  defp layouts(ctx) do
    case Map.get(ctx.opts, :layout) do
      layout when layout in [:sandbox, :private_clone] ->
        {:ok, %{implement: layout, review: layout}}

      _ ->
        with {:ok, implement} <- layout(ctx, :implement),
             {:ok, review} <- layout(ctx, :review),
             do: {:ok, %{implement: implement, review: review}}
    end
  end

  defp layout(ctx, role) do
    case ctx.runner.layout.(role, spec(ctx, role)) do
      {:ok, layout} when layout in [:sandbox, :private_clone] -> {:ok, layout}
      {:error, _} = error -> error
      other -> {:error, {:layout_failed, "#{role}: #{inspect(other)}"}}
    end
  rescue
    error -> {:error, {:layout_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:layout_failed, Exception.format_banner(kind, reason)}}
  end

  # ---- admission ---------------------------------------------------------------

  defp admit(%{subject: subject, author: author, reviewer: reviewer, now: now} = ctx) do
    pools = [{author.account_id, author.pool}, {reviewer.account_id, reviewer.pool}]

    serialised(fn ->
      running = now |> running() |> Admission.running()

      {state, reason, entries} =
        case Admission.check(pools, ctx.budget_fun, running) do
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
          deadline_at: deadline(ctx),
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

  # When the replay must be done by, whatever it runs into: both runs'
  # timeouts, its tests' budget, and slack for the rest. Its seats are held
  # until then, and past it the replay is taken for dead.
  defp deadline(ctx) do
    tests_ms = if tests?(ctx), do: budget_s(ctx.recipe) * 1000, else: 0
    ms = timeout(ctx.opts, :implement) + timeout(ctx.opts, :review) + tests_ms + @slack_ms
    DateTime.add(ctx.now, ms, :millisecond)
  end

  defp budget_s(recipe),
    do: Map.get(recipe, :budget_seconds) || Map.get(recipe, :timeout_seconds) || 0

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
      thinking: author.thinking,
      reviewer_provider: to_string(reviewer.provider),
      reviewer_account_id: reviewer.account_id,
      reviewer_model: reviewer.model,
      reviewer_pool: reviewer.pool,
      reviewer_thinking: reviewer.thinking
    }
  end

  # ---- the replay ----------------------------------------------------------------

  # Whatever happens from here on, the record is finished: a raise anywhere is
  # a failure, never a replay left `:running`.
  defp execute(run, ctx) do
    ctx = Map.merge(ctx, %{dir: Path.join(root(ctx.opts), run.id), run: run})

    outcome =
      try do
        ctx |> place() |> replay_in_place()
      rescue
        error -> {:failed, %{reason: Exception.message(error)}}
      catch
        kind, reason -> {:failed, %{reason: Exception.format_banner(kind, reason)}}
      end

    finish(run, outcome)
  end

  # One checkout for both sides: a private clone when either runs in a
  # container (which can mount nothing else), else the sandbox.
  defp place(ctx) do
    layout = if :private_clone in Map.values(ctx.layouts), do: :private_clone, else: :sandbox
    Map.merge(ctx, %{layout: layout, checkout: checkout_path(layout, ctx)})
  end

  # The checkout and the scratch dir go whatever the replay did.
  defp replay_in_place(ctx) do
    replay(ctx)
  after
    unless Map.get(ctx.opts, :keep_sandbox, false), do: remove(ctx)
  end

  defp root(opts), do: Map.get(opts, :root) || Path.join(Paths.scratch_root(), "replays")

  # A private clone lives where every clone does, as a leaf of the worktree root.
  defp checkout_path(:private_clone, ctx),
    do: Path.join(Paths.worktree_root(), "replay-" <> ctx.run.id)

  defp checkout_path(:sandbox, ctx), do: Path.join(ctx.dir, "checkout")

  defp remove(%{layout: :private_clone} = ctx) do
    discard_clone(ctx.checkout, ctx.subject.repo_path)
    Sandbox.remove(ctx.dir)
  end

  defp remove(ctx), do: Sandbox.remove(ctx.dir)

  # Never `PrivateClone.remove/1`: its sync-back trusts the clone's own
  # markers, which a model that ran in it could have rewritten. The pins go
  # from the main repo the caller knows (`nil`: left to the worktree sweeper).
  defp discard_clone(path, repo) do
    case PrivateClone.discard(path, repo) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Loop.Replay: removing #{path}: #{inspect(reason)}")
    end
  end

  # A replay whose node stopped mid-run left its record `:running` and its
  # checkout on disk: nothing ran its cleanup. Before each replay, a record
  # still `:running` past its deadline is finished as abandoned, and the
  # checkout of every replay not running now is removed (a private clone's pins
  # with it, in the main repo its record names). The checkouts are listed
  # before the running replays are read: a replay's record is `:running` before
  # its checkout exists, so a live replay's is never taken for a leftover.
  defp sweep(opts, now) do
    abandon(now)
    root = root(opts)
    worktree_root = Paths.worktree_root()
    sandboxes = uuids(root)
    clones = uuids(worktree_root, "replay-")
    live = now |> running() |> MapSet.new(& &1.id)

    for id <- sandboxes, not MapSet.member?(live, id), do: Sandbox.remove(Path.join(root, id))

    for "replay-" <> id = leaf <- clones, not MapSet.member?(live, id) do
      discard_clone(Path.join(worktree_root, leaf), recorded_repo_path(id))
    end

    :ok
  end

  defp abandon(now) do
    ReplayRun
    |> Ash.Query.filter(state == :running and deadline_at <= ^now)
    |> Ash.read!()
    |> Enum.each(fn run ->
      Ash.update!(
        run,
        %{
          state: :failed,
          reason:
            "abandoned: still running past its deadline (its node stopped before it finished)",
          finished_at: DateTime.utc_now()
        },
        action: :finish
      )
    end)
  end

  # The main repo a replay's clone borrows from, as its record says (never as
  # the clone's own markers do).
  defp recorded_repo_path(id) do
    with {:ok, %ReplayRun{workspace_id: ws_id, repo: repo}} when is_binary(ws_id) <-
           Ash.get(ReplayRun, id),
         {:ok, ws} <- Ash.get(Workspace, ws_id) do
      LocalCompare.repo_path(ws, repo)
    else
      _ -> nil
    end
  end

  # The entries of `dir` named `prefix` and a replay id.
  defp uuids(dir, prefix \\ "") do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.filter(entries, fn entry ->
          String.starts_with?(entry, prefix) and
            match?({:ok, _}, Ecto.UUID.cast(String.replace_prefix(entry, prefix, "")))
        end)

      {:error, _} ->
        []
    end
  end

  defp replay(%{subject: subject} = ctx) do
    with :ok <- File.mkdir_p(scratch(ctx)),
         {:ok, branch} <- checkout(ctx),
         ctx = Map.merge(ctx, %{subject: Map.put(subject, :branch, branch), seal: seal(ctx)}),
         {:ok, known_good} <-
           Sandbox.known_good(subject.repo_path, subject.base_sha, subject.known_good_sha),
         {:ok, implemented} <-
           call(ctx, :implement, Prompt.implement(ctx.subject, adapter(ctx.author.provider))) do
      score_change(ctx, known_good, %{"implement" => run_summary(implemented)})
    else
      {:error, reason} -> {:failed, %{reason: describe(reason)}}
    end
  end

  defp score_change(ctx, known_good, runs) do
    with :ok <- untampered(ctx),
         {:ok, change} <- Sandbox.change(ctx.checkout, ctx.subject.base_sha) do
      measured = %{
        files: Enum.take(change.files, @max_files),
        overlap: Score.overlap(change, known_good),
        runs: runs
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
      {:error, reason} -> {:failed, %{reason: describe(reason), runs: runs}}
    end
  end

  defp scratch(%{dir: dir}), do: Path.join(dir, "scratch")
  defp scratch(_ctx), do: nil

  # The checkout at the base commit, and the branch it is on, seeded with
  # dependencies as a dispatch's worktree is before any model runs in it
  # (seeding can run `mix deps.get` there, which must never load a model's
  # `mix.exs`). On the host: the sandbox. For a container: a read-only private
  # clone with nothing after the base checked out, whose `origin` (the forge,
  # for a review clone) is pointed nowhere so the merged change cannot be
  # fetched.
  defp checkout(%{layout: :sandbox, checkout: checkout, subject: subject}) do
    with {:ok, _} <- Sandbox.create(subject.repo_path, subject.base_sha, checkout),
         :ok <- seed(subject, checkout) do
      {:ok, Sandbox.branch()}
    end
  end

  defp checkout(%{layout: :private_clone, checkout: checkout, subject: subject}) do
    with {:ok, _} <-
           PrivateClone.create_review(subject.repo_path, subject.base_sha, path: checkout),
         :ok <- Sandbox.disconnect(checkout),
         :ok <- seed(subject, checkout) do
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

  # What host git holds the checkout to once a model has run in it, taken when
  # the harness is done with it: the sandbox's config; a clone's `arbiter.*`
  # markers, which `PrivateClone.verify/1` does not check.
  defp seal(%{layout: :sandbox, checkout: checkout}), do: Sandbox.seal(checkout)
  defp seal(%{layout: :private_clone, checkout: checkout}), do: markers(checkout)

  defp markers(clone),
    do:
      {PrivateClone.main_repo(clone), PrivateClone.branch(clone), PrivateClone.read_only?(clone)}

  defp untampered(%{layout: :sandbox, checkout: checkout, seal: seal}),
    do: Sandbox.verify(checkout, seal)

  defp untampered(%{layout: :private_clone, checkout: checkout, seal: sealed}) do
    case PrivateClone.verify(checkout) do
      :ok ->
        if markers(checkout) == sealed,
          do: :ok,
          else: {:error, {:tampered, "the clone's arbiter.* markers were changed"}}

      {:error, :not_a_private_clone} ->
        {:error, {:tampered, ".git names no main repo"}}

      {:error, _} = error ->
        error
    end
  end

  # The tests run the replayed model's code, so only where it ran in a
  # container, in one again (the runner's `run(:test, …)`): on the host, never.
  defp tests?(ctx), do: ctx.recipe != nil and ctx.layouts.implement == :private_clone

  defp tests(ctx) do
    if tests?(ctx) do
      spec =
        ctx
        |> spec(:implement)
        |> Map.merge(%{recipe: ctx.recipe, base_sha: ctx.subject.base_sha})

      case ctx.runner.run.(:test, spec) do
        {:ok, %{result: result, steps: steps}} ->
          %{tests: tests_outcome(result), tests_run: %{"steps" => Enum.map(steps, &step/1)}}

        {:error, reason} ->
          %{tests: :error, tests_run: %{"error" => describe(reason)}}

        other ->
          %{tests: :error, tests_run: %{"error" => describe({:bad_runner_result, other})}}
      end
    else
      %{tests: :not_run}
    end
  end

  defp step(step), do: Map.take(step, [:name, :status, :exit_status, :duration_ms])

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

        case call(ctx, :review, prompt) do
          {:ok, reviewed} -> score(put_run(measured, "review", reviewed), reviewed, ctx)
          {:error, reason} -> {:failed, Map.put(measured, :reason, describe(reason))}
        end
    end
  end

  defp score(measured, reviewed, ctx) do
    with :ok <- untampered(ctx),
         {:ok, empty?} <- Sandbox.committed_empty?(ctx.checkout, ctx.subject.base_sha) do
      {verdict, findings} = Score.verdict(reviewed.output)
      {total, unmet} = ReviewVerification.criteria_counts(findings)

      {:scored,
       Map.merge(measured, %{
         verdict: verdict,
         criteria_total: total,
         criteria_unmet: unmet,
         converged:
           Score.converged?(%{
             verdict: verdict,
             findings: findings,
             acceptance: ctx.subject.issue.acceptance,
             net_diff_empty?: empty?
           })
       })}
    else
      {:error, reason} -> {:failed, Map.put(measured, :reason, describe(reason))}
    end
  end

  defp put_run(measured, name, result), do: put_in(measured, [:runs, name], run_summary(result))

  defp call(ctx, role, prompt) do
    case ctx.runner.run.(role, Map.put(spec(ctx, role), :prompt, prompt)) do
      {:ok, %{output: output} = result} when is_list(output) -> {:ok, result}
      {:error, reason} -> {:error, {role, reason}}
      other -> {:error, {role, {:bad_runner_result, other}}}
    end
  end

  # What a runner is told about one side's run (the prompt aside). Before
  # admission (`layout/2`) there is no replay or checkout yet.
  defp spec(ctx, role) do
    side = if role == :review, do: ctx.reviewer, else: ctx.author

    %{
      replay_id: replay_id(ctx),
      dir: Map.get(ctx, :checkout),
      scratch: scratch(ctx),
      prompt: nil,
      provider: side.provider,
      account_id: side.account_id,
      model: side.model,
      thinking: side.thinking,
      workspace: ctx.subject.workspace,
      repo: ctx.subject.repo,
      timeout_ms: timeout(ctx.opts, role)
    }
    |> Map.merge(Map.take(ctx.opts, [:container_opts]))
  end

  defp replay_id(%{run: %ReplayRun{id: id}}), do: id
  defp replay_id(_ctx), do: nil

  defp timeout(opts, :review), do: Map.get(opts, :review_timeout_ms, @review_timeout_ms)
  defp timeout(opts, _implement), do: Map.get(opts, :timeout_ms, @implement_timeout_ms)

  defp run_summary(result) do
    Map.take(result, [:exit_status, :timed_out, :duration_ms, :usage])
  end

  defp adapter(:antigravity), do: :gemini
  defp adapter(provider), do: provider

  # ---- the record ------------------------------------------------------------------

  defp finish(run, {state, fields}) do
    overlap = Map.get(fields, :overlap, %{})

    runs =
      case Map.get(fields, :tests_run) do
        nil -> Map.get(fields, :runs, %{})
        tests -> Map.put(Map.get(fields, :runs, %{}), "tests", tests)
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

  defp describe({:tampered, why}),
    do: "the checkout's git was tampered with, so host git did not run in it: " <> why

  defp describe({role, reason}) when role in [:implement, :review],
    do: "#{role} run failed: #{describe(reason)}"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp describe_result({tag, %ReplayRun{} = run}),
    do: "#{tag} #{run.id} (#{run.state}#{if run.reason, do: ": " <> run.reason})"

  defp describe_result(other), do: inspect(other)
end
