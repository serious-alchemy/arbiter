defmodule Arbiter.Loop.SubjectStats do
  @moduledoc """
  What a first routing choice costs by the time its task merges: per
  `(provider, model, difficulty_at_dispatch, issue_type)` task-level
  measurements, and the fallback ladder that turns them into an estimate
  (bd-2aw8zg, R1; `docs/design/paced-quota-routing-signals.md` §3.1–3.2).

  **Measurement only.** Nothing in routing, the quota gate or dispatch calls
  this module (§9): `sample/1` reads, `summarize/1`, `cells/2` and `lookup/3`
  are pure. It is the one module shared with the guardrails' trust records
  (G18), so a second consumer reads these same figures rather than re-deriving
  them.

  Everything comes from records Arbiter already writes — `worker_runs`,
  `review_gate_rounds`, `usage_events`, `ticket_transitions` and `issues` — and
  nothing is instrumented or migrated for it. Reads follow the
  `Arbiter.Loop.Canary.Metrics` discipline: raw `Repo.query!/2`, bound
  parameters, `IN` lists chunked, `usage_events.raw` never selected.

  ## One record per task

  Every figure is attributed to the task's **first** routing choice: the
  earliest `kind = implement, role = base` run that recorded a model. It
  includes whatever that choice led to — re-dispatches, an escalated attempt, a
  difficulty correction. `sample/1` returns one map per **closed, completed**
  task whose first attempt started in the window:

    * `:run_id`, `:started_at`, `:repo` — the first attempt itself, so the
      guardrails' trust records (G18) attribute the task to that run's subject;
    * `:provider`, `:model`, `:family`, `:pool`, `:tier`, `:difficulty`
      (`difficulty_at_dispatch`, not the corrected one; a dispatch with none
      recorded keys as the routing default, D2), `:issue_type` (a string);
    * `:attempts` (`A`) — base implement runs;
    * `:review_rounds` (`R`) and `:fix_passes` (`F`) — `review_gate_rounds`
      with `role = 'review'` and `role = 'impl'`. CI fix passes
      (`worker_runs.kind = 'fix_pass'`) are *runs*, counted in `:runs`;
    * `:reviewed?` / `:first_round_approved?` — the `q` definition
      `Canary.Metrics` and the guardrail "clean run" use: the first review
      round (earliest `inserted_at`) has `converged = 1`;
    * `:difficulty_raised?` — the issue's current difficulty is above the
      difficulty at dispatch;
    * `:hours_to_close` — the last `close` transition to a `completed` close at
      or before the cutoff (the issue's `closed_at` when the task has no
      transition rows) minus the first attempt's `started_at`;
    * `:runs` — every run of the task by `{pool, side}`; side is `:author`
      (implement, fix pass, conflict) or `:review`. A run with no model is
      placed by the provider on its `usage_events` rows;
    * `:draw` — `Arbiter.Loop.Scarcity.weighted_tokens/1` per `{pool, side}`;
      `:cost_usd` — the priced `source = 'task'` sum, `nil` when no row was
      priced (unpriced is absent, never zero);
    * `:weight` — recency weight, see below.

  Synthetic ids (`#review`, `#impl2`, `:fixpass`, …) fold to the base task with
  `Arbiter.Usage.Estimate.fold_task_id/1`. A task whose first attempt
  predates the window is not admitted by a later attempt inside it. Events at
  or after the cutoff are not counted.

  A run's provider is its own `provider` column, else its `usage_events`
  provider, else inferred from the model prefix (`claude-` → `claude`,
  `gemini-` → `gemini`, `gpt-` / `o<n>` → `codex`). Older rows carry no provider
  at all. The pool is `Arbiter.Agents.ModelFamily.classify/2` of that, so a
  `worker_runs.provider = "gemini"` row (the adapter type, which does not say
  which Google CLI ran) lands on the `gemini` pool.

  ## Window and weighting

  Options for `sample/1`: `:now`, `:window_days` (60), `:from` / `:until`
  (default `now - window_days` / `now`; fixing both makes a re-run reproducible,
  as the design's Appendix A does), `:workspace_id`, and `:half_life_days` (30;
  `nil` for equal weights). A task's weight is `0.5 ^ (age / half_life)` with
  `age` measured from its close. Means, `q` and the median are weighted;
  `:n` is always the unweighted task count.

  ## The fallback ladder (`lookup/3`)

  At least `min_n/0` (10) tasks per rung, finest first:

  | rung | key | `basis` |
  |---|---|---|
  | 0 | `{provider, model, difficulty, issue_type}` | `:cell` |
  | 1 | `{provider, model, difficulty}` | `:model_difficulty` |
  | 2 | `{family, tier, difficulty}` | `:family_tier_difficulty` |
  | 3 | the hand prior for `{family, tier, difficulty}` | `:prior` |

  The result always names the rung and the `n` behind it, so a coarse estimate
  reads as coarse. Rung 3 carries `stats: nil` and `n: 0`: the matrix's own row
  (R6) is the answer there, never an invented number. Rung 2 needs the `:tier`
  the caller is routing at; without one it is skipped.

  The key uses the difficulty at dispatch, not the corrected one: the router
  predicts from what it sees when it dispatches, so a systematic under-rating
  is absorbed by the cell instead of amplified (§3.2).
  """

  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Loop.Scarcity
  alias Arbiter.Repo
  alias Arbiter.Usage.Estimate

  @window_days 60
  @half_life_days 30
  @min_n 10

  # SQLite's default parameter ceiling is 999; 200 leaves room for the fixed
  # params, as in `Canary.Metrics`.
  @chunk 200

  @author_kinds ~w(implement fix_pass conflict)

  @type side :: :author | :review
  @type pool_side :: {String.t(), side()}

  @type task :: %{
          task_id: String.t(),
          run_id: String.t(),
          started_at: DateTime.t() | nil,
          repo: String.t() | nil,
          provider: String.t() | nil,
          model: String.t(),
          family: ModelFamily.family() | nil,
          pool: String.t() | nil,
          tier: String.t() | nil,
          difficulty: 0..5,
          issue_type: String.t() | nil,
          weight: float(),
          attempts: non_neg_integer(),
          review_rounds: non_neg_integer(),
          fix_passes: non_neg_integer(),
          reviewed?: boolean(),
          first_round_approved?: boolean() | nil,
          difficulty_raised?: boolean(),
          hours_to_close: float() | nil,
          runs: %{pool_side() => pos_integer()},
          draw: %{pool_side() => float()},
          cost_usd: float() | nil
        }

  @type summary :: %{
          n: non_neg_integer(),
          weight: float(),
          reviewed_n: non_neg_integer(),
          q: float() | nil,
          review_rounds: float() | nil,
          fix_passes: float() | nil,
          attempts: float() | nil,
          difficulty_raised: float() | nil,
          time_to_merge_hours: %{median: float(), mean: float()} | nil,
          runs: %{pool_side() => float()},
          draw: %{pool_side() => float()},
          cost_usd: float() | nil
        }

  @type found :: %{
          rung: 0..3,
          basis: :cell | :model_difficulty | :family_tier_difficulty | :prior,
          n: non_neg_integer(),
          key: tuple(),
          stats: summary() | nil
        }

  @doc "Closed tasks a rung needs before its own figures are trusted."
  @spec min_n() :: pos_integer()
  def min_n, do: @min_n

  # ---- the sample ---------------------------------------------------------

  @doc "One record per closed task in the window. See the moduledoc for the shape and options."
  @spec sample(keyword()) :: [task()]
  def sample(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    until = Keyword.get(opts, :until, now)
    window = Keyword.get(opts, :window_days, @window_days)
    from = Keyword.get_lazy(opts, :from, fn -> DateTime.add(now, -window * 86_400, :second) end)
    half_life = Keyword.get(opts, :half_life_days, @half_life_days)
    workspace_id = Keyword.get(opts, :workspace_id)

    bounds = %{from: iso(from), until: iso(until), workspace_id: workspace_id}

    firsts = first_attempts(bounds)

    if firsts == %{} do
      []
    else
      ids = Map.keys(firsts)
      issues = issues(ids)
      closes = closes(bounds)

      events = usage_events(bounds)

      ctx = %{
        runs: runs_by_task(bounds, ids),
        rounds: rounds_by_task(bounds, ids),
        usage: usage_by_task(events, ids),
        run_providers: run_providers(events),
        now: now,
        half_life: half_life
      }

      firsts
      |> Enum.flat_map(fn {id, first} ->
        issue = Map.get(issues, id)
        closed_at = issue && close_time(issue, Map.get(closes, id), until)

        if closed_at, do: [build_task(id, first, issue, closed_at, ctx)], else: []
      end)
      |> Enum.sort_by(& &1.task_id)
    end
  end

  # The first base attempt of every task whose first attempt started in the
  # window: the earliest base run with a model, with nothing earlier. A task
  # with a base run before `from` is not admitted by a later one.
  defp first_attempts(bounds) do
    {ws_sql, ws_params} = workspace_clause(bounds, 3)

    in_window =
      query(
        """
        SELECT id, task_id, base_task_id, model, model_tier, provider,
               difficulty_at_dispatch, started_at, repo
        FROM worker_runs
        WHERE kind = 'implement' AND COALESCE(role, 'base') = 'base'
          AND model IS NOT NULL
          AND started_at >= ?1 AND started_at < ?2#{ws_sql}
        ORDER BY started_at, id
        """,
        [bounds.from, bounds.until] ++ ws_params
      )
      |> Enum.reject(&is_nil(&1["task_id"]))
      |> Enum.group_by(&fold_run_task/1)
      |> Map.new(fn {id, rows} -> {id, hd(rows)} end)

    earlier = ids_with_base_run_before(Map.keys(in_window), bounds.from)
    Map.drop(in_window, earlier)
  end

  defp ids_with_base_run_before([], _from), do: []

  defp ids_with_base_run_before(ids, from) do
    ids
    |> in_chunks(fn chunk, placeholders ->
      query(
        """
        SELECT task_id, base_task_id
        FROM worker_runs
        WHERE kind = 'implement' AND COALESCE(role, 'base') = 'base'
          AND started_at < ?#{length(chunk) + 1}
          AND COALESCE(base_task_id, task_id) IN (#{placeholders})
        """,
        chunk ++ [from]
      )
    end)
    |> Enum.map(&fold_run_task/1)
    |> Enum.uniq()
  end

  defp runs_by_task(bounds, ids) do
    wanted = MapSet.new(ids)
    {ws_sql, ws_params} = workspace_clause(bounds, 3)

    query(
      """
      SELECT id, task_id, base_task_id, kind, role, model, provider
      FROM worker_runs
      WHERE started_at >= ?1 AND started_at < ?2#{ws_sql}
      """,
      [bounds.from, bounds.until] ++ ws_params
    )
    |> Enum.reject(&is_nil(&1["task_id"]))
    |> Enum.filter(&MapSet.member?(wanted, fold_run_task(&1)))
    |> Enum.group_by(&fold_run_task/1)
  end

  defp rounds_by_task(bounds, ids) do
    wanted = MapSet.new(ids)

    query(
      """
      SELECT task_id, round, role, converged, inserted_at
      FROM review_gate_rounds
      WHERE role IN ('review', 'impl')
        AND inserted_at >= ?1 AND inserted_at < ?2
      """,
      [bounds.from, bounds.until]
    )
    |> Enum.reject(&is_nil(&1["task_id"]))
    |> Enum.group_by(&Estimate.fold_task_id(&1["task_id"]))
    |> Map.filter(fn {id, _} -> MapSet.member?(wanted, id) end)
  end

  defp usage_events(bounds) do
    {ws_sql, ws_params} = workspace_clause(bounds, 3)

    query(
      """
      SELECT task_id, base_task_id, role, provider, model, worker_run_id,
             tokens_in, tokens_out, cache_creation_tokens, cache_read_tokens, cost_usd
      FROM usage_events
      WHERE source = 'task'
        AND occurred_at >= ?1 AND occurred_at < ?2#{ws_sql}
      """,
      [bounds.from, bounds.until] ++ ws_params
    )
  end

  defp usage_by_task(events, ids) do
    wanted = MapSet.new(ids)

    events
    |> Enum.reject(&(is_nil(&1["task_id"]) and is_nil(&1["base_task_id"])))
    |> Enum.group_by(&fold_run_task/1)
    |> Map.filter(fn {id, _} -> MapSet.member?(wanted, id) end)
  end

  # run id => the provider its usage rows name, for runs that recorded neither
  # a provider nor a model of their own.
  defp run_providers(events) do
    events
    |> Enum.filter(&(&1["worker_run_id"] && present(&1["provider"])))
    |> Enum.reduce(%{}, fn e, acc -> Map.put_new(acc, e["worker_run_id"], e["provider"]) end)
  end

  defp issues(ids) do
    ids
    |> in_chunks(fn chunk, placeholders ->
      query(
        """
        SELECT id, issue_type, difficulty, state, close_reason, closed_at
        FROM issues
        WHERE id IN (#{placeholders})
        """,
        chunk
      )
    end)
    |> Map.new(&{&1["id"], &1})
  end

  # Every close transition before the cutoff, newest per ticket. `legacy:close`
  # is the backfill's name for the same event.
  defp closes(bounds) do
    query(
      """
      SELECT ticket_id, at
      FROM ticket_transitions
      WHERE to_state = 'closed' AND close_reason = 'completed'
        AND at >= ?1 AND at < ?2
      ORDER BY at
      """,
      [bounds.from, bounds.until]
    )
    |> Map.new(&{&1["ticket_id"], &1["at"]})
  end

  # A task counts if it is closed as completed *now*; the time it closed is the
  # last completed close in the window, else the issue's own `closed_at`.
  defp close_time(%{"state" => "closed", "close_reason" => "completed"} = issue, at, until) do
    case parse(at || issue["closed_at"]) do
      %DateTime{} = dt -> if DateTime.compare(dt, until) == :lt, do: dt
      nil -> nil
    end
  end

  defp close_time(_issue, _at, _until), do: nil

  # ---- one task -----------------------------------------------------------

  defp build_task(id, first, issue, closed_at, ctx) do
    runs = Map.get(ctx.runs, id, [])
    rounds = Map.get(ctx.rounds, id, [])
    events = Map.get(ctx.usage, id, [])

    provider = resolve_provider(first["provider"], first["model"], nil)
    %{family: family, pool: pool} = classify(provider, first["model"])
    difficulty = ByDifficulty.effective_difficulty(first["difficulty_at_dispatch"])

    review =
      rounds
      |> Enum.filter(&(&1["role"] == "review"))
      |> Enum.sort_by(&{&1["inserted_at"], int(&1["round"])})

    first_round = List.first(review)
    started = parse(first["started_at"])

    {draw, cost} = draw_and_cost(events, ctx.run_providers, runs)

    %{
      task_id: id,
      run_id: first["id"],
      started_at: started,
      repo: first["repo"],
      provider: provider,
      model: first["model"],
      family: family,
      pool: pool,
      tier: first["model_tier"],
      difficulty: difficulty,
      issue_type: issue["issue_type"],
      weight: weight(closed_at, ctx.now, ctx.half_life),
      attempts: Enum.count(runs, &base_attempt?/1),
      review_rounds: length(review),
      fix_passes: Enum.count(rounds, &(&1["role"] == "impl")),
      reviewed?: first_round != nil,
      first_round_approved?: first_round && truthy?(first_round["converged"]),
      difficulty_raised?: raised?(issue["difficulty"], difficulty),
      hours_to_close: DateTime.diff(closed_at, started, :microsecond) / 3_600_000_000,
      runs: count_runs(runs, ctx.run_providers),
      draw: draw,
      cost_usd: cost
    }
  end

  defp base_attempt?(run),
    do: run["kind"] == "implement" and (run["role"] || "base") == "base"

  defp count_runs(runs, run_providers) do
    runs
    |> Enum.map(fn r ->
      provider = resolve_provider(r["provider"], r["model"], run_providers[r["id"]])
      {classify(provider, r["model"]).pool || "unknown", side(r["kind"])}
    end)
    |> Enum.frequencies()
  end

  defp draw_and_cost(events, run_providers, runs) do
    run_pools =
      Map.new(runs, fn r ->
        provider = resolve_provider(r["provider"], r["model"], run_providers[r["id"]])
        {r["id"], classify(provider, r["model"]).pool}
      end)

    draw =
      events
      |> Enum.group_by(fn e ->
        provider = resolve_provider(e["provider"], e["model"], nil)
        pool = classify(provider, e["model"]).pool || run_pools[e["worker_run_id"]] || "unknown"
        {pool, if(e["role"] == "review", do: :review, else: :author)}
      end)
      |> Map.new(fn {key, rows} ->
        {key, rows |> Enum.map(&Scarcity.weighted_tokens(counts(&1))) |> Enum.sum()}
      end)

    priced = for e <- events, is_number(e["cost_usd"]), do: e["cost_usd"] / 1
    cost = if priced == [], do: nil, else: Enum.sum(priced)

    {draw, cost}
  end

  defp counts(e) do
    %{
      tokens_in: e["tokens_in"],
      tokens_out: e["tokens_out"],
      cache_creation_tokens: e["cache_creation_tokens"],
      cache_read_tokens: e["cache_read_tokens"]
    }
  end

  defp side(kind) when kind in @author_kinds, do: :author
  defp side(_), do: :review

  defp raised?(current, at_dispatch) when is_integer(current), do: current > at_dispatch
  defp raised?(_, _), do: false

  defp weight(_closed_at, _now, nil), do: 1.0

  defp weight(closed_at, now, half_life) do
    age_days = max(DateTime.diff(now, closed_at, :second), 0) / 86_400
    :math.pow(0.5, age_days / half_life)
  end

  # ---- provider, family, pool --------------------------------------------

  defp resolve_provider(provider, model, event_provider) do
    present(provider) || present(event_provider) || infer_provider(model)
  end

  defp infer_provider("claude-" <> _), do: "claude"
  defp infer_provider("gemini-" <> _), do: "gemini"
  defp infer_provider("gpt-" <> _), do: "codex"
  defp infer_provider("o" <> <<d, _::binary>>) when d in ?0..?9, do: "codex"
  defp infer_provider(_), do: nil

  defp classify(nil, _model), do: %{family: nil, pool: nil}
  defp classify(provider, model), do: ModelFamily.classify(provider, model)

  # ---- summaries ----------------------------------------------------------

  @doc """
  Summarise a list of `t:task/0` records: the cell's figures.

  `q` is over the **reviewed** tasks; `R`, `F`, `A`, the raised rate, `:runs`,
  `:draw` and `:cost_usd` are per task over all of them. An empty list summarises
  to `n: 0` with every figure `nil` (or an empty map) — an absent measurement,
  never a zero.
  """
  @spec summarize([task()]) :: summary()
  def summarize([]) do
    %{
      n: 0,
      weight: 0.0,
      reviewed_n: 0,
      q: nil,
      review_rounds: nil,
      fix_passes: nil,
      attempts: nil,
      difficulty_raised: nil,
      time_to_merge_hours: nil,
      runs: %{},
      draw: %{},
      cost_usd: nil
    }
  end

  def summarize(tasks) do
    reviewed = Enum.filter(tasks, & &1.reviewed?)
    timed = Enum.reject(tasks, &is_nil(&1.hours_to_close))
    priced = Enum.reject(tasks, &is_nil(&1.cost_usd))

    %{
      n: length(tasks),
      weight: tasks |> Enum.map(& &1.weight) |> Enum.sum(),
      reviewed_n: length(reviewed),
      q: wmean(reviewed, &if(&1.first_round_approved?, do: 1.0, else: 0.0)),
      review_rounds: wmean(tasks, & &1.review_rounds),
      fix_passes: wmean(tasks, & &1.fix_passes),
      attempts: wmean(tasks, & &1.attempts),
      difficulty_raised: wmean(tasks, &if(&1.difficulty_raised?, do: 1.0, else: 0.0)),
      time_to_merge_hours: time_to_merge(timed),
      runs: wmean_map(tasks, & &1.runs),
      draw: wmean_map(tasks, & &1.draw),
      cost_usd: wmean(priced, & &1.cost_usd)
    }
  end

  defp time_to_merge([]), do: nil

  defp time_to_merge(tasks) do
    %{
      median: wmedian(tasks, & &1.hours_to_close),
      mean: wmean(tasks, & &1.hours_to_close)
    }
  end

  defp wmean([], _fun), do: nil

  defp wmean(tasks, fun) do
    total = tasks |> Enum.map(& &1.weight) |> Enum.sum()
    if total > 0, do: Enum.sum(for t <- tasks, do: fun.(t) * t.weight) / total
  end

  # Per-task mean of a `%{key => number}` field over *all* the tasks: a task
  # that never ran in a pool contributes zero to that key.
  defp wmean_map(tasks, fun) do
    total = tasks |> Enum.map(& &1.weight) |> Enum.sum()

    if total > 0 do
      tasks
      |> Enum.flat_map(fn t -> for {k, v} <- fun.(t), do: {k, v * t.weight} end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {k, vs} -> {k, Enum.sum(vs) / total} end)
    else
      %{}
    end
  end

  # The weighted median: the first value whose running weight reaches half the
  # total. Where the running weight lands exactly on half, the median sits
  # between that value and the next, so it is their mean: with equal weights
  # this is the ordinary median, and the design's tables (§3.5) use it.
  defp wmedian(tasks, fun) do
    sorted = Enum.sort_by(tasks, fun)
    half = (sorted |> Enum.map(& &1.weight) |> Enum.sum()) / 2

    {value, _} =
      sorted
      |> Enum.with_index()
      |> Enum.reduce_while(0.0, fn {t, i}, acc ->
        acc = acc + t.weight

        cond do
          abs(acc - half) <= 1.0e-9 and i + 1 < length(sorted) ->
            {:halt, {(fun.(t) + fun.(Enum.at(sorted, i + 1))) / 2, i}}

          acc >= half ->
            {:halt, {fun.(t), i}}

          true ->
            {:cont, acc}
        end
      end)

    value
  end

  # ---- cells and the ladder ----------------------------------------------

  @doc """
  Every cell at `rung` (0, 1 or 2) as `%{key:, n:, ...summary}`. Rung 2 skips
  tasks with no recorded tier.
  """
  @spec cells([task()], 0..2) :: [map()]
  def cells(tasks, rung) when rung in 0..2 do
    tasks
    |> Enum.flat_map(fn t -> if k = rung_key(rung, t), do: [{k, t}], else: [] end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {key, ts} -> Map.put(summarize(ts), :key, key) end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  The estimate for one candidate choice, by the ladder in the moduledoc.

  `choice` is `%{provider:, model:, difficulty:, issue_type:}` plus an optional
  `:tier`. Options: `:min_n` (default `min_n/0`).
  """
  @spec lookup([task()], map(), keyword()) :: found()
  def lookup(tasks, choice, opts \\ []) do
    min_n = Keyword.get(opts, :min_n, @min_n)
    d = ByDifficulty.effective_difficulty(choice[:difficulty])
    provider = to_string(choice.provider)
    type = choice[:issue_type] && to_string(choice.issue_type)
    %{family: family} = classify(provider, choice[:model])
    tier = choice[:tier]

    keys = [
      {0, :cell, {provider, choice[:model], d, type}},
      {1, :model_difficulty, {provider, choice[:model], d}},
      {2, :family_tier_difficulty, tier && {family, tier, d}}
    ]

    Enum.find_value(keys, prior(family, tier, d), fn
      {_rung, _basis, nil} ->
        nil

      {rung, basis, key} ->
        matched = Enum.filter(tasks, &(rung_key(rung, &1) == key))
        if length(matched) >= min_n, do: found(rung, basis, key, matched)
    end)
  end

  defp found(rung, basis, key, matched),
    do: %{rung: rung, basis: basis, n: length(matched), key: key, stats: summarize(matched)}

  defp prior(family, tier, d),
    do: %{rung: 3, basis: :prior, n: 0, key: {family, tier, d}, stats: nil}

  defp rung_key(0, t), do: {t.provider, t.model, t.difficulty, t.issue_type}
  defp rung_key(1, t), do: {t.provider, t.model, t.difficulty}
  defp rung_key(2, %{tier: nil}), do: nil
  defp rung_key(2, t), do: {t.family, t.tier, t.difficulty}

  # ---- plumbing -----------------------------------------------------------

  defp fold_run_task(row), do: Estimate.fold_task_id(row["base_task_id"] || row["task_id"])

  defp workspace_clause(%{workspace_id: nil}, _n), do: {"", []}
  defp workspace_clause(%{workspace_id: ws}, n), do: {" AND workspace_id = ?#{n}", [ws]}

  # Microsecond precision, so the string comparison against SQLite's stored
  # ISO-8601 text agrees at second boundaries.
  defp iso(%DateTime{microsecond: {us, _}} = dt),
    do: dt |> Map.put(:microsecond, {us, 6}) |> DateTime.to_iso8601()

  defp parse(nil), do: nil

  defp parse(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp present(v) when is_binary(v) and v != "", do: v
  defp present(_), do: nil

  # SQLite has no boolean type: `converged` comes back as 1/0.
  defp truthy?(1), do: true
  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  defp in_chunks(values, fun) do
    values
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      placeholders = Enum.map_join(1..length(chunk), ", ", &"?#{&1}")
      fun.(chunk, placeholders)
    end)
  end

  # The only interpolations reaching this helper are the `?1, ?2, …` placeholder
  # list `in_chunks/2` builds from `1..length(chunk)` and the workspace clause
  # above — text this module generated. Every value is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  defp query(sql, params) do
    %{columns: cols, rows: rows} = Repo.query!(sql, params)
    Enum.map(rows, fn row -> cols |> Enum.zip(row) |> Map.new() end)
  end
end
