defmodule Arbiter.Loop.SubjectStatsTest do
  @moduledoc """
  bd-2aw8zg (R1, paced-quota-routing-signals §3.1–3.2): per
  `(provider, model, difficulty_at_dispatch, issue_type)` task-level
  measurements, and the fallback ladder.

  Every expected number below is hand-computed from the fixture rows inserted
  by `seed/0`, not read back from the module under test. The fixture is laid
  out as a table in the comments so each figure can be re-derived by eye.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Scarcity
  alias Arbiter.Loop.SubjectStats
  alias Arbiter.Repo
  alias Arbiter.Tasks.Workspace

  @from ~U[2026-08-24 00:00:00.000000Z]
  @until ~U[2026-10-01 12:00:00.000000Z]

  # Equal weights: the hand figures are plain means. Recency weighting has its
  # own test.
  @opts [from: @from, until: @until, half_life_days: nil]

  @sonnet "claude-sonnet-5-5"
  @flash_med "gemini-3.8-flash-medium"
  @flash_low "gemini-3.8-flash-low"

  describe "sample/1 and cell summaries (hand-computed)" do
    setup do
      seed()
      %{tasks: SubjectStats.sample(@opts)}
    end

    test "only closed-completed tasks whose first attempt is in the window are sampled", %{
      tasks: tasks
    } do
      ids = tasks |> Enum.map(& &1.task_id) |> Enum.sort()

      # t-open (still active), t-early (first attempt before `from`), t-wontfix
      # (closed, but not completed) and t-late (first attempt after `until`)
      # are all absent.
      assert ids == ~w(t-agy-low t-agy-med t-bug t-d3 t-nomodel t1 t2 t3)
    end

    test "round-1 approve rate, R, F, A, difficulty raised and time to merge", %{tasks: tasks} do
      cell =
        SubjectStats.summarize(
          Enum.filter(
            tasks,
            &(&1.model == @sonnet and &1.issue_type == "feature" and &1.difficulty == 2)
          )
        )

      # t1: 2 review rounds (first not converged), 1 impl round, 1 attempt, T=4h
      # t2: 1 review round (converged), 0 impl, 2 attempts, T=10h, D2 -> D3
      # t3: no review rounds, 0 impl, 1 attempt, T=1h
      assert cell.n == 3
      assert cell.reviewed_n == 2
      assert_in_delta cell.q, 1 / 2, 1.0e-9
      assert_in_delta cell.review_rounds, 3 / 3, 1.0e-9
      assert_in_delta cell.fix_passes, 1 / 3, 1.0e-9
      assert_in_delta cell.attempts, 4 / 3, 1.0e-9
      assert_in_delta cell.difficulty_raised, 1 / 3, 1.0e-9
      assert cell.time_to_merge_hours.median == 4.0
      assert_in_delta cell.time_to_merge_hours.mean, 5.0, 1.0e-9
    end

    test "runs by pool and side, per task", %{tasks: tasks} do
      cell = SubjectStats.summarize(Enum.filter(tasks, &(&1.task_id in ~w(t1 t2 t3))))

      # author runs: t1 1 base; t2 2 base; t3 1 base + 1 fix_pass = 5 over 3
      # review runs: t1 2 (claude); t2 1 (claude); t3 0 = 3 over 3
      assert_in_delta cell.runs[{"claude", :author}], 5 / 3, 1.0e-9
      assert_in_delta cell.runs[{"claude", :review}], 3 / 3, 1.0e-9
      refute Map.has_key?(cell.runs, {"gemini", :author})
    end

    test "a cross-pool task puts author runs on its own pool and reviews on the reviewer's", %{
      tasks: tasks
    } do
      t = Enum.find(tasks, &(&1.task_id == "t-agy-med"))

      assert t.provider == "gemini"
      assert t.model == @flash_med
      assert t.pool == "gemini"
      # 2 base attempts + 1 conflict pass author-side on gemini; 1 review on claude
      assert t.runs == %{{"gemini", :author} => 3, {"claude", :review} => 1}
      assert t.attempts == 2
    end

    test "a run with no model is placed on its pool by its usage_events provider", %{
      tasks: tasks
    } do
      t = Enum.find(tasks, &(&1.task_id == "t-nomodel"))

      # base run has a model, the review run has none; its usage row says claude
      assert t.runs == %{{"claude", :author} => 1, {"claude", :review} => 1}
    end

    test "provider is inferred from the model when the run and its events carry none", %{
      tasks: tasks
    } do
      t = Enum.find(tasks, &(&1.task_id == "t-d3"))
      assert t.provider == "claude"
      assert t.family == :anthropic
      assert t.tier == "premium"
      assert t.difficulty == 3
    end

    test "unrated dispatches key on the routing default difficulty (D2)", %{tasks: tasks} do
      t = Enum.find(tasks, &(&1.task_id == "t-bug"))
      assert t.difficulty == 2
      assert t.issue_type == "bug"
    end

    test "draw is weighted tokens per (pool, side); cost is the priced sum", %{tasks: tasks} do
      t1 = Enum.find(tasks, &(&1.task_id == "t1"))

      author = Scarcity.weighted_tokens(%{tokens_in: 1000, tokens_out: 100})
      review = Scarcity.weighted_tokens(%{tokens_in: 500, tokens_out: 50}) * 2

      assert_in_delta t1.draw[{"claude", :author}], author, 1.0e-6
      assert_in_delta t1.draw[{"claude", :review}], review, 1.0e-6
      assert_in_delta t1.cost_usd, 0.75, 1.0e-9

      # Unpriced rows are absent, not zero.
      t3 = Enum.find(tasks, &(&1.task_id == "t3"))
      assert t3.cost_usd == nil
    end

    test "events after the cutoff are not counted", %{tasks: tasks} do
      t1 = Enum.find(tasks, &(&1.task_id == "t1"))
      # a post-cutoff review round + review run exist for t1; neither counts
      assert t1.review_rounds == 2
      assert t1.runs[{"claude", :review}] == 2
    end

    test "synthetic ids fold to the base task (review rounds, impl rounds, usage)", %{
      tasks: tasks
    } do
      t1 = Enum.find(tasks, &(&1.task_id == "t1"))
      assert t1.review_rounds == 2
      assert t1.fix_passes == 1
    end

    test "time to merge reads the close transition, not the issue's later edits", %{tasks: tasks} do
      t2 = Enum.find(tasks, &(&1.task_id == "t2"))
      assert_in_delta t2.hours_to_close, 10.0, 1.0e-9
    end

    test "with no transition rows, the issue's closed_at is the close time" do
      Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = 't3'")
      t3 = @opts |> SubjectStats.sample() |> Enum.find(&(&1.task_id == "t3"))
      assert_in_delta t3.hours_to_close, 1.0, 1.0e-9
    end

    test "a task whose first attempt predates the window is not re-admitted by a later attempt",
         %{tasks: tasks} do
      refute Enum.any?(tasks, &(&1.task_id == "t-early"))
    end

    test "cells/2 groups by rung", %{tasks: tasks} do
      rung0 = tasks |> SubjectStats.cells(0) |> Map.new(&{&1.key, &1})
      rung1 = tasks |> SubjectStats.cells(1) |> Map.new(&{&1.key, &1})

      assert rung0[{"claude", @sonnet, 2, "feature"}].n == 3
      assert rung0[{"claude", @sonnet, 2, "bug"}].n == 1
      assert rung1[{"claude", @sonnet, 2}].n == 5
    end

    test "the median of an even number of tasks is the mean of the middle two" do
      tasks =
        for {h, i} <- Enum.with_index([1.0, 2.0, 4.0, 10.0]),
            do: task(%{task_id: "m#{i}", hours_to_close: h})

      assert SubjectStats.summarize(tasks).time_to_merge_hours.median == 3.0
    end

    test "a heavy recent task pulls the weighted median to itself" do
      tasks = [
        task(%{task_id: "a", hours_to_close: 1.0, weight: 0.1}),
        task(%{task_id: "b", hours_to_close: 5.0, weight: 0.1}),
        task(%{task_id: "c", hours_to_close: 9.0, weight: 1.0})
      ]

      assert SubjectStats.summarize(tasks).time_to_merge_hours.median == 9.0
    end

    test "an empty summary is nil-valued, never zero" do
      cell = SubjectStats.summarize([])
      assert cell.n == 0
      assert cell.q == nil
      assert cell.review_rounds == nil
      assert cell.time_to_merge_hours == nil
      assert cell.runs == %{}
    end

    test "sampling is read-only" do
      before = row_counts()
      _ = SubjectStats.sample(@opts)
      assert row_counts() == before
    end

    # G18 reads the first attempt back: `Arbiter.Loop.Trust` attributes a task's
    # round-1 quality to the subject that run was dispatched as.
    test "each task names its first attempt: run id, start and repo", %{tasks: tasks} do
      %{rows: [[first_id]]} =
        Repo.query!(
          "SELECT id FROM worker_runs WHERE task_id = 't2' AND kind = 'implement' ORDER BY started_at LIMIT 1"
        )

      t2 = Enum.find(tasks, &(&1.task_id == "t2"))
      assert t2.run_id == first_id
      assert t2.started_at == ~U[2026-09-02 10:00:00.000000Z]
      assert t2.repo == "arbiter"
    end
  end

  describe "recency weighting" do
    test "a 30-day half-life halves the weight of a task closed 30 days earlier" do
      seed()
      now = ~U[2026-10-01 12:00:00.000000Z]
      tasks = SubjectStats.sample(from: @from, until: @until, now: now)

      t1 = Enum.find(tasks, &(&1.task_id == "t1"))
      # t1 closed 2026-09-01 14:00; age = 29d 22h
      age = DateTime.diff(now, ~U[2026-09-01 14:00:00Z], :second) / 86_400
      assert_in_delta t1.weight, :math.pow(0.5, age / 30), 1.0e-9

      # Weighted mean of A over the t1/t2/t3 cell leans toward the newer t3.
      cell =
        SubjectStats.summarize(Enum.filter(tasks, &(&1.task_id in ~w(t1 t2 t3))))

      w = Map.new(tasks, &{&1.task_id, &1.weight})
      expected = (1 * w["t1"] + 2 * w["t2"] + 1 * w["t3"]) / (w["t1"] + w["t2"] + w["t3"])
      assert_in_delta cell.attempts, expected, 1.0e-9
    end

    test "the default window is 60 days back from now" do
      seed()
      now = ~U[2026-10-01 12:00:00.000000Z]
      # 60d back = 2026-08-02: the eight tasks plus t-early (first attempt 08-20)
      assert length(SubjectStats.sample(now: now, until: @until)) == 9
      # 20d back = 2026-09-11; every seeded first attempt is earlier
      assert SubjectStats.sample(now: now, until: @until, window_days: 20) == []
    end
  end

  describe "workspace scoping" do
    test "workspace_id restricts to that workspace's runs" do
      ws = seed()
      assert SubjectStats.sample([workspace_id: Ecto.UUID.generate()] ++ @opts) == []
      assert length(SubjectStats.sample([workspace_id: ws] ++ @opts)) == 8
    end
  end

  describe "lookup/3 fallback ladder" do
    setup do
      seed()
      %{tasks: SubjectStats.sample(@opts)}
    end

    test "rung 0 when the exact cell has enough tasks", %{tasks: tasks} do
      found =
        SubjectStats.lookup(
          tasks,
          %{
            provider: "claude",
            model: @sonnet,
            difficulty: 2,
            issue_type: "feature",
            tier: "standard"
          },
          min_n: 3
        )

      assert found.rung == 0
      assert found.basis == :cell
      assert found.n == 3
      assert found.key == {"claude", @sonnet, 2, "feature"}
      assert_in_delta found.stats.attempts, 4 / 3, 1.0e-9
    end

    test "rung 1 drops issue_type when the cell is thin", %{tasks: tasks} do
      found =
        SubjectStats.lookup(
          tasks,
          %{
            provider: "claude",
            model: @sonnet,
            difficulty: 2,
            issue_type: "bug",
            tier: "standard"
          },
          min_n: 3
        )

      assert found.rung == 1
      assert found.basis == :model_difficulty
      assert found.n == 5
      assert found.key == {"claude", @sonnet, 2}
    end

    test "rung 2 pools the family and tier at that difficulty", %{tasks: tasks} do
      # Two google/economy/D2 tasks on different models: neither model alone has
      # 2 tasks, together they do.
      found =
        SubjectStats.lookup(
          tasks,
          %{
            provider: "gemini",
            model: @flash_low,
            difficulty: 2,
            issue_type: "feature",
            tier: "economy"
          },
          min_n: 2
        )

      assert found.rung == 2
      assert found.basis == :family_tier_difficulty
      assert found.n == 2
      assert found.key == {:google, "economy", 2}
    end

    test "rung 2 is skipped without a tier", %{tasks: tasks} do
      found =
        SubjectStats.lookup(
          tasks,
          %{
            provider: "gemini",
            model: @flash_low,
            difficulty: 2,
            issue_type: "feature"
          },
          min_n: 2
        )

      assert found.rung == 3
    end

    test "rung 3 is the hand prior, with no stats and n = 0", %{tasks: tasks} do
      found =
        SubjectStats.lookup(tasks, %{
          provider: "codex",
          model: "gpt-5.5",
          difficulty: 4,
          issue_type: "feature",
          tier: "premium"
        })

      assert found == %{
               rung: 3,
               basis: :prior,
               n: 0,
               key: {:openai, "premium", 4},
               stats: nil
             }
    end

    test "the default threshold is 10 tasks per rung", %{tasks: tasks} do
      assert SubjectStats.min_n() == 10

      found =
        SubjectStats.lookup(tasks, %{
          provider: "claude",
          model: @sonnet,
          difficulty: 2,
          issue_type: "feature",
          tier: "standard"
        })

      assert found.rung == 3
    end

    test "a coarse rung reports its own n, so coarse reads as coarse" do
      tasks =
        for i <- 1..12 do
          task(%{
            task_id: "x#{i}",
            model: @sonnet,
            issue_type: if(i <= 4, do: "feature", else: "bug")
          })
        end

      found =
        SubjectStats.lookup(tasks, %{
          provider: "claude",
          model: @sonnet,
          difficulty: 2,
          issue_type: "feature",
          tier: "standard"
        })

      assert found.rung == 1
      assert found.n == 12
    end

    test "issue_type may be an atom" do
      tasks = for i <- 1..10, do: task(%{task_id: "y#{i}", model: @sonnet})

      found =
        SubjectStats.lookup(tasks, %{
          provider: "claude",
          model: @sonnet,
          difficulty: 2,
          issue_type: :feature
        })

      assert found.rung == 0
      assert found.n == 10
    end
  end

  describe "measurement only (§9)" do
    test "no routing, quota or dispatch module references SubjectStats" do
      lib = Path.expand("../../../lib/arbiter", __DIR__)

      offenders =
        ~w(agents quota worker/dispatch.ex worker/driver.ex)
        |> Enum.flat_map(fn rel ->
          Path.wildcard(Path.join([lib, rel, "**", "*.ex"])) ++ Path.wildcard(Path.join(lib, rel))
        end)
        |> Enum.filter(&File.regular?/1)
        |> Enum.filter(&(&1 |> File.read!() |> String.contains?("SubjectStats")))

      assert offenders == []
    end
  end

  # ---- fixtures -----------------------------------------------------------
  #
  # | task       | first model         | D@disp | type    | rounds (review/impl) | base runs | closed (completed)     |
  # |------------|---------------------|--------|---------|----------------------|-----------|------------------------|
  # | t1         | sonnet-5-5          | 2      | feature | 2 (first no) / 1     | 1         | 09-01 14:00 (T = 4h)   |
  # | t2         | sonnet-5-5          | 2      | feature | 1 (first yes) / 0    | 2         | 09-02 20:00 (T = 10h)  |
  # | t3         | sonnet-5-5          | 2      | feature | none                 | 1 + fixpass | 09-03 11:00 (T = 1h) |
  # | t-bug      | sonnet-5-5          | nil→2  | bug     | none                 | 1         | 09-04 11:00            |
  # | t-d3       | claude-opus-5-5     | 3      | feature | none                 | 1         | 09-05 11:00            |
  # | t-agy-med  | gemini-3.8-flash-medium | 2  | feature | none                 | 2 + conflict + 1 claude review | 09-06 |
  # | t-agy-low  | gemini-3.8-flash-low| 2      | feature | none                 | 1         | 09-07 11:00            |
  # | t-nomodel  | sonnet-5-5          | 2      | task    | none                 | 1 + review w/o model | 09-08 |
  #
  # Excluded: t-open (active), t-early (first attempt 08-20), t-wontfix
  # (closed not_planned), t-late (first attempt 10-02).
  defp seed do
    {:ok, workspace} = Ash.create(Workspace, %{name: "stats-ws", prefix: "ss"})
    ws = workspace.id

    # t1
    issue("t1", ws, "feature", 2, closed: ~U[2026-09-01 14:00:00Z])

    run(
      "t1",
      "t1",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-01 10:00:00Z]
    )

    run(
      "t1#review",
      "t1",
      ws,
      "review",
      "review",
      @sonnet,
      "claude",
      nil,
      nil,
      ~U[2026-09-01 11:00:00Z]
    )

    run(
      "t1#review#v2",
      "t1",
      ws,
      "review",
      "review",
      @sonnet,
      "claude",
      nil,
      nil,
      ~U[2026-09-01 13:00:00Z]
    )

    # past the cutoff: must not count
    run(
      "t1#review#v3",
      "t1",
      ws,
      "review",
      "review",
      @sonnet,
      "claude",
      nil,
      nil,
      ~U[2026-10-02 13:00:00Z]
    )

    round("t1#review", "review", 1, false, ~U[2026-09-01 11:30:00Z])
    round("t1#review#impl1", "impl", 1, true, ~U[2026-09-01 12:00:00Z])
    round("t1#review", "review", 2, true, ~U[2026-09-01 13:30:00Z])
    round("t1#review", "review", 3, true, ~U[2026-10-02 13:30:00Z])
    usage("t1", "t1", "base", "claude", @sonnet, 1000, 100, 0.5, ~U[2026-09-01 10:30:00Z])

    usage(
      "t1#review",
      "t1",
      "review",
      "claude",
      @sonnet,
      500,
      50,
      0.125,
      ~U[2026-09-01 11:20:00Z]
    )

    usage(
      "t1#review#v2",
      "t1",
      "review",
      "claude",
      @sonnet,
      500,
      50,
      0.125,
      ~U[2026-09-01 13:20:00Z]
    )

    usage(
      "t1#review#v3",
      "t1",
      "review",
      "claude",
      @sonnet,
      9999,
      999,
      9.0,
      ~U[2026-10-02 13:20:00Z]
    )

    # t2: two attempts; the issue is re-rated D3 afterwards; a later edit moves
    # updated_at but the close transition is what T reads.
    issue("t2", ws, "feature", 3,
      closed: ~U[2026-09-02 20:00:00Z],
      edited: ~U[2026-09-20 00:00:00Z]
    )

    run(
      "t2",
      "t2",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-02 10:00:00Z]
    )

    run(
      "t2",
      "t2",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-02 12:00:00Z]
    )

    run(
      "t2#review",
      "t2",
      ws,
      "review",
      "review",
      @sonnet,
      "claude",
      nil,
      nil,
      ~U[2026-09-02 18:00:00Z]
    )

    round("t2#review", "review", 1, true, ~U[2026-09-02 18:30:00Z])

    # t3
    issue("t3", ws, "feature", 2, closed: ~U[2026-09-03 11:00:00Z])

    run(
      "t3",
      "t3",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-03 10:00:00Z]
    )

    run(
      "t3:fixpass",
      "t3",
      ws,
      "fix_pass",
      "fix_pass",
      @sonnet,
      "claude",
      nil,
      nil,
      ~U[2026-09-03 10:30:00Z]
    )

    usage("t3", "t3", "base", "claude", @sonnet, 10, 1, nil, ~U[2026-09-03 10:40:00Z])

    # t-bug: no difficulty recorded at dispatch
    issue("t-bug", ws, "bug", 2, closed: ~U[2026-09-04 11:00:00Z])

    run(
      "t-bug",
      "t-bug",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      nil,
      "standard",
      ~U[2026-09-04 10:00:00Z]
    )

    # t-d3: no provider on the run or its events; inferred from the model
    issue("t-d3", ws, "feature", 3, closed: ~U[2026-09-05 11:00:00Z])

    run(
      "t-d3",
      "t-d3",
      ws,
      "implement",
      "base",
      "claude-opus-5-5",
      nil,
      3,
      "premium",
      ~U[2026-09-05 10:00:00Z]
    )

    # t-agy-med: agy author side, Claude review side
    issue("t-agy-med", ws, "feature", 2, closed: ~U[2026-09-06 11:00:00Z])

    run(
      "t-agy-med",
      "t-agy-med",
      ws,
      "implement",
      "base",
      @flash_med,
      "gemini",
      2,
      "economy",
      ~U[2026-09-06 08:00:00Z]
    )

    run(
      "t-agy-med",
      "t-agy-med",
      ws,
      "implement",
      "base",
      @flash_med,
      "gemini",
      2,
      "economy",
      ~U[2026-09-06 09:00:00Z]
    )

    run(
      "t-agy-med:conflict",
      "t-agy-med",
      ws,
      "conflict",
      "conflict",
      @flash_med,
      "gemini",
      nil,
      nil,
      ~U[2026-09-06 09:30:00Z]
    )

    run(
      "t-agy-med#review",
      "t-agy-med",
      ws,
      "review",
      "review",
      "claude-opus-5",
      "claude",
      nil,
      nil,
      ~U[2026-09-06 10:00:00Z]
    )

    # t-agy-low
    issue("t-agy-low", ws, "feature", 2, closed: ~U[2026-09-07 11:00:00Z])

    run(
      "t-agy-low",
      "t-agy-low",
      ws,
      "implement",
      "base",
      @flash_low,
      "gemini",
      2,
      "economy",
      ~U[2026-09-07 10:00:00Z]
    )

    # t-nomodel: the review run has no model and no provider; its usage row names claude
    issue("t-nomodel", ws, "task", 2, closed: ~U[2026-09-08 11:00:00Z])

    run(
      "t-nomodel",
      "t-nomodel",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-08 10:00:00Z]
    )

    review_run =
      run(
        "t-nomodel#review",
        "t-nomodel",
        ws,
        "review",
        "review",
        nil,
        nil,
        nil,
        nil,
        ~U[2026-09-08 10:30:00Z]
      )

    usage(
      "t-nomodel#review",
      "t-nomodel",
      "review",
      "claude",
      nil,
      5,
      1,
      0.01,
      ~U[2026-09-08 10:40:00Z],
      review_run
    )

    # excluded tasks
    issue("t-open", ws, "feature", 2, state: "active")

    run(
      "t-open",
      "t-open",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-09 10:00:00Z]
    )

    issue("t-early", ws, "feature", 2, closed: ~U[2026-09-10 11:00:00Z])

    run(
      "t-early",
      "t-early",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-08-20 10:00:00Z]
    )

    run(
      "t-early",
      "t-early",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-10 09:00:00Z]
    )

    issue("t-wontfix", ws, "feature", 2,
      closed: ~U[2026-09-11 11:00:00Z],
      close_reason: "not_planned"
    )

    run(
      "t-wontfix",
      "t-wontfix",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-09-11 10:00:00Z]
    )

    issue("t-late", ws, "feature", 2, closed: ~U[2026-10-03 11:00:00Z])

    run(
      "t-late",
      "t-late",
      ws,
      "implement",
      "base",
      @sonnet,
      "claude",
      2,
      "standard",
      ~U[2026-10-02 10:00:00Z]
    )

    ws
  end

  # An in-memory task record shaped like `sample/1`'s output, for ladder tests
  # that need many tasks cheaply.
  defp task(attrs) do
    Map.merge(
      %{
        task_id: "t",
        provider: "claude",
        model: @sonnet,
        family: :anthropic,
        pool: "claude",
        tier: "standard",
        difficulty: 2,
        issue_type: "feature",
        weight: 1.0,
        reviewed?: true,
        first_round_approved?: true,
        review_rounds: 1,
        fix_passes: 0,
        attempts: 1,
        difficulty_raised?: false,
        hours_to_close: 1.0,
        runs: %{{"claude", :author} => 1, {"claude", :review} => 1},
        draw: %{},
        cost_usd: nil
      },
      attrs
    )
  end

  defp row_counts do
    for t <- ~w(worker_runs review_gate_rounds usage_events issues ticket_transitions),
        into: %{} do
      %{rows: [[n]]} = Repo.query!("SELECT COUNT(*) FROM #{t}")
      {t, n}
    end
  end

  defp iso(%DateTime{} = dt),
    do: dt |> Map.put(:microsecond, {elem(dt.microsecond, 0), 6}) |> DateTime.to_iso8601()

  defp id, do: Ecto.UUID.generate()

  # An issue. `closed:` walks it active -> closed through real UPDATEs so the
  # `ticket_transitions` triggers write the rows production would; `edited:`
  # then touches the issue again without changing its state.
  defp issue(task_id, ws, type, difficulty, opts) do
    created = ~U[2026-08-01 00:00:00.000000Z]

    Repo.query!(
      """
      INSERT INTO issues (id, workspace_id, title, issue_type, difficulty, priority,
                          tracker_type, state, created_at, updated_at)
      VALUES (?1, ?2, ?1, ?3, ?4, 2, 'none', 'active', ?5, ?5)
      """,
      [task_id, ws, type, difficulty, iso(created)]
    )

    case Keyword.get(opts, :closed) do
      nil ->
        if state = opts[:state] do
          Repo.query!("UPDATE issues SET state = ?2 WHERE id = ?1", [task_id, state])
        end

      closed_at ->
        Repo.query!(
          """
          UPDATE issues SET state = 'closed', close_reason = ?2, closed_at = ?3, updated_at = ?3
          WHERE id = ?1
          """,
          [task_id, Keyword.get(opts, :close_reason, "completed"), iso(closed_at)]
        )
    end

    if edited = opts[:edited] do
      # `closed_at` is moved too, so the close transition is the only place the
      # real close time survives.
      Repo.query!("UPDATE issues SET updated_at = ?2, closed_at = ?2 WHERE id = ?1", [
        task_id,
        iso(edited)
      ])
    end
  end

  defp run(task_id, base, ws, kind, role, model, provider, difficulty, tier, started_at) do
    run_id = id()

    Repo.query!(
      """
      INSERT INTO worker_runs (id, task_id, base_task_id, workspace_id, repo, kind, role, model,
                               provider, difficulty_at_dispatch, model_tier, state, outcome,
                               started_at, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, 'arbiter', ?5, ?6, ?7, ?8, ?9, ?10, 'finished', 'succeeded', ?11, ?11, ?11)
      """,
      [run_id, task_id, base, ws, kind, role, model, provider, difficulty, tier, iso(started_at)]
    )

    run_id
  end

  defp round(task_id, role, round, converged, at) do
    Repo.query!(
      """
      INSERT INTO review_gate_rounds (id, task_id, round, role, converged, inserted_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [id(), task_id, round, role, if(converged, do: 1, else: 0), iso(at)]
    )
  end

  defp usage(task_id, base, role, provider, model, tin, tout, cost, at, run_id \\ nil) do
    Repo.query!(
      """
      INSERT INTO usage_events (id, task_id, base_task_id, role, source, step, provider, model,
                                tokens_in, tokens_out, cost_usd, worker_run_id,
                                occurred_at, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, 'task', 'run', ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11, ?11)
      """,
      [id(), task_id, base, role, provider, model, tin, tout, cost, run_id, iso(at)]
    )
  end
end
