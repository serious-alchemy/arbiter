defmodule Arbiter.Loop.CompetenceGeneratorTest do
  @moduledoc """
  bd-biycyw (R6): seeding generator for the hand competence matrix.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.CompetenceGenerator
  alias Arbiter.Settings

  defp make_task(id, provider, model, diff, opts \\ []) do
    %{
      task_id: id,
      provider: provider,
      model: model,
      difficulty: diff,
      issue_type: "feature",
      attempts: Keyword.get(opts, :attempts, 1),
      review_rounds: Keyword.get(opts, :review_rounds, 2),
      fix_passes: Keyword.get(opts, :fix_passes, 1),
      reviewed?: Keyword.get(opts, :reviewed?, true),
      first_round_approved?: Keyword.get(opts, :first_round_approved?, true),
      difficulty_raised?: Keyword.get(opts, :difficulty_raised?, false),
      hours_to_close: Keyword.get(opts, :hours_to_close, 2.0),
      cost_usd: Keyword.get(opts, :cost_usd, 5.0)
    }
  end

  describe "generate/1 keys" do
    test "agy runs recorded as the gemini adapter are keyed antigravity, and match the lookup" do
      tasks = for i <- 1..5, do: make_task("g#{i}", "gemini", "gemini-3.8-flash-medium", 2)
      assert [row] = CompetenceGenerator.generate(tasks: tasks)
      assert row["match"]["provider"] == "antigravity"

      found =
        Arbiter.Agents.Routing.Competence.lookup([row], %{
          provider: "gemini",
          model: "gemini-3.8-flash-medium",
          difficulty: 2
        })

      assert %{rung: 1, n: 5} = found
    end

    test "a full haiku id matches a generated row for the alias candidate" do
      tasks = for i <- 1..5, do: make_task("h#{i}", "claude", "claude-haiku-4-5-20251001", 1)
      assert [row] = CompetenceGenerator.generate(tasks: tasks)

      assert %{rung: 1, n: 5} =
               Arbiter.Agents.Routing.Competence.lookup([row], %{
                 provider: "claude",
                 model: "haiku",
                 difficulty: 1
               })
    end
  end

  describe "generate/1 against a §3.6 cell" do
    # A synthetic task set whose aggregates are the design doc's §3.6 row for
    # agy flash-medium, D2 (n 6, 33% approve, 2.83 review rounds, 1.50 fix
    # passes, 2.67 attempts, 17% raised, 9.1 / 1.8 h, $6.93 / $6.34). It pins the
    # generator's arithmetic (means, median, 90th-percentile winsorising,
    # rounding) to the baseline; it is not the measured install data.
    test "reproduces the agy flash-medium D2 baseline row" do
      per_task = [
        {3, 2, 3, false, 1.2, 3.0, true},
        {3, 2, 3, false, 1.5, 5.0, true},
        {3, 2, 3, false, 1.6, 6.0, false},
        {3, 1, 3, false, 2.0, 6.68, false},
        {2, 1, 3, true, 24.15, 9.0, false},
        {2, 1, 2, false, 30.0, 11.9, false}
      ]

      tasks =
        per_task
        |> Enum.with_index()
        |> Enum.map(fn {{att, fix, rev, raised, hours, cost, approved}, i} ->
          make_task("a#{i}", "gemini", "gemini-3.8-flash-medium", 2,
            attempts: att,
            fix_passes: fix,
            review_rounds: rev,
            difficulty_raised?: raised,
            hours_to_close: hours,
            cost_usd: cost,
            first_round_approved?: approved
          )
        end)

      assert [row] = CompetenceGenerator.generate(tasks: tasks, min_n: 5)

      assert row["match"] == %{
               "provider" => "antigravity",
               "model" => "gemini-3.8-flash-medium",
               "difficulty" => 2
             }

      assert row["n"] == 6
      assert row["reviewed_n"] == 6
      assert row["round_1_approve"] == 0.33
      assert row["review_rounds"] == 2.83
      assert row["fix_passes"] == 1.5
      assert row["attempts"] == 2.67
      assert row["difficulty_raised"] == 0.17
      assert row["time_to_close_mean_hours"] == 9.1
      assert row["time_to_close_median_hours"] == 1.8
      assert row["cost_usd_mean"] == 6.93
      assert row["cost_usd_median"] == 6.34

      default =
        Enum.find(Arbiter.Agents.Routing.Competence.default_rows(), fn r ->
          r["match"] == row["match"]
        end)

      for key <- ~w(n round_1_approve review_rounds fix_passes attempts difficulty_raised
                    time_to_close_mean_hours time_to_close_median_hours cost_usd_mean
                    cost_usd_median author_runs review_runs) do
        assert row[key] == default[key],
               "#{key}: #{inspect(row[key])} != #{inspect(default[key])}"
      end
    end
  end

  describe "generate/1" do
    test "proposes rows for cells meeting min_n, with 90th percentile winsorising" do
      # Create 6 tasks for sonnet-5 at D2. One parked task with 100 hours.
      # Times: [1.0, 1.0, 2.0, 2.0, 3.0, 100.0]
      # 90th percentile of 6 items: index 5 is 100.0 or interpolated ~3.0-100.0
      # Winsorising clamps the 100.0 parked task down.
      tasks = [
        make_task("t1", "claude", "claude-sonnet-5", 2,
          hours_to_close: 1.0,
          first_round_approved?: true
        ),
        make_task("t2", "claude", "claude-sonnet-5", 2,
          hours_to_close: 1.0,
          first_round_approved?: false
        ),
        make_task("t3", "claude", "claude-sonnet-5", 2,
          hours_to_close: 2.0,
          first_round_approved?: true
        ),
        make_task("t4", "claude", "claude-sonnet-5", 2,
          hours_to_close: 2.0,
          first_round_approved?: false
        ),
        make_task("t5", "claude", "claude-sonnet-5", 2,
          hours_to_close: 3.0,
          first_round_approved?: true
        ),
        make_task("t6", "claude", "claude-sonnet-5", 2,
          hours_to_close: 100.0,
          first_round_approved?: false
        ),
        # 2 tasks for haiku (below min_n = 5, should be skipped)
        make_task("t7", "claude", "haiku", 1),
        make_task("t8", "claude", "haiku", 1)
      ]

      rows = CompetenceGenerator.generate(tasks: tasks, min_n: 5)
      assert length(rows) == 1

      [row] = rows

      assert row["match"] == %{
               "provider" => "claude",
               "model" => "claude-sonnet-5",
               "difficulty" => 2
             }

      assert row["n"] == 6
      assert row["rung"] == 1
      assert row["round_1_approve"] == 0.5
      # attempts (1) + fix_passes (1)
      assert row["author_runs"] == 2.0
      # review_rounds (2)
      assert row["review_runs"] == 2.0
      assert row["time_to_close_median_hours"] == 2.0

      # Mean with winsorising is clamped well below the un-winsorised mean ((1+1+2+2+3+100)/6 = 18.16)
      assert row["time_to_close_mean_hours"] < 15.0
    end

    test "formats a Markdown report" do
      tasks = for i <- 1..5, do: make_task("t#{i}", "claude", "claude-sonnet-5", 2)
      rows = CompetenceGenerator.generate(tasks: tasks, min_n: 5)
      table = CompetenceGenerator.format(rows)

      assert table =~ "claude-sonnet-5"
      assert table =~ "Round-1 approve"
    end

    test "seed_installation!/1 persists proposed rows into Settings" do
      tasks = for i <- 1..5, do: make_task("t#{i}", "claude", "claude-sonnet-5", 2)
      {:ok, rows} = CompetenceGenerator.seed_installation!(tasks: tasks, min_n: 5)

      assert length(rows) == 1
      assert Settings.competence_matrix() == rows
    end
  end
end
