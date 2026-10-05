defmodule Arbiter.Agents.Routing.CompetenceTest do
  @moduledoc """
  bd-biycyw (R6): hand competence matrix tests:
  - Baseline seeded values match design §3.6 within rounding.
  - Fallback ladder lookup (Rungs 0..3).
  - Operator override in installation settings takes precedence.
  - δ by side calculation and reviewer projection.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Routing.Competence
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  describe "default_rows/0 matches design doc §3.6 baseline within rounding" do
    test "contains all 12 baseline rows with matching figures" do
      rows = Competence.default_rows()

      # 1. agy flash-low, D0
      r1 = find_row(rows, "antigravity", "gemini-3.8-flash-low", 0)
      assert r1["n"] == 11
      assert r1["round_1_approve"] == 1.0
      assert r1["reviewed_n"] == 4
      assert r1["review_rounds"] == 0.36
      assert r1["fix_passes"] == 0.00
      assert r1["attempts"] == 1.36
      assert r1["difficulty_raised"] == 0.0
      assert r1["time_to_close_mean_hours"] == 5.1
      assert r1["time_to_close_median_hours"] == 0.4
      assert r1["cost_usd_mean"] == 0.04
      assert r1["cost_usd_median"] == 0.00

      # 2. haiku, D0
      r2 = find_row(rows, "claude", "haiku", 0)
      assert r2["n"] == 14
      assert r2["round_1_approve"] == 0.80
      assert r2["reviewed_n"] == 10
      assert r2["review_rounds"] == 1.07
      assert r2["fix_passes"] == 0.21
      assert r2["attempts"] == 1.14
      assert r2["difficulty_raised"] == 0.14
      assert r2["time_to_close_mean_hours"] == 0.3
      assert r2["time_to_close_median_hours"] == 0.2
      assert r2["cost_usd_mean"] == 0.93
      assert r2["cost_usd_median"] == 0.46

      # 3. agy flash-low, D1
      r3 = find_row(rows, "antigravity", "gemini-3.8-flash-low", 1)
      assert r3["n"] == 13
      assert r3["round_1_approve"] == 0.50
      assert r3["reviewed_n"] == 8
      assert r3["review_rounds"] == 1.69
      assert r3["fix_passes"] == 0.46
      assert r3["attempts"] == 2.23
      assert r3["difficulty_raised"] == 0.15
      assert r3["time_to_close_mean_hours"] == 11.0
      assert r3["time_to_close_median_hours"] == 1.1
      assert r3["cost_usd_mean"] == 2.00
      assert r3["cost_usd_median"] == 0.37

      # 4. haiku, D1
      r4 = find_row(rows, "claude", "haiku", 1)
      assert r4["n"] == 80
      assert r4["round_1_approve"] == 0.41
      assert r4["reviewed_n"] == 79
      assert r4["review_rounds"] == 2.27
      assert r4["fix_passes"] == 0.78
      assert r4["attempts"] == 1.68
      assert r4["difficulty_raised"] == 0.18
      assert r4["time_to_close_mean_hours"] == 1.4
      assert r4["time_to_close_median_hours"] == 0.7
      assert r4["cost_usd_mean"] == 2.68
      assert r4["cost_usd_median"] == 1.77

      # 5. agy flash-medium, D2
      r5 = find_row(rows, "antigravity", "gemini-3.8-flash-medium", 2)
      assert r5["n"] == 6
      assert r5["round_1_approve"] == 0.33
      assert r5["reviewed_n"] == 6
      assert r5["review_rounds"] == 2.83
      assert r5["fix_passes"] == 1.50
      assert r5["attempts"] == 2.67
      assert r5["difficulty_raised"] == 0.17
      assert r5["time_to_close_mean_hours"] == 9.1
      assert r5["time_to_close_median_hours"] == 1.8
      assert r5["cost_usd_mean"] == 6.93
      assert r5["cost_usd_median"] == 6.34

      # 6. sonnet-5, D2
      r6 = find_row(rows, "claude", "claude-sonnet-5", 2)
      assert r6["n"] == 258
      assert r6["round_1_approve"] == 0.32
      assert r6["reviewed_n"] == 240
      assert r6["review_rounds"] == 2.36
      assert r6["fix_passes"] == 1.07
      assert r6["attempts"] == 1.46
      assert r6["difficulty_raised"] == 0.05
      assert r6["time_to_close_mean_hours"] == 6.2
      assert r6["time_to_close_median_hours"] == 1.2
      assert r6["cost_usd_mean"] == 10.57
      assert r6["cost_usd_median"] == 7.84

      # 7. sonnet-5-5, D2
      r7 = find_row(rows, "claude", "claude-sonnet-5-5", 2)
      assert r7["n"] == 38
      assert r7["round_1_approve"] == 0.58
      assert r7["reviewed_n"] == 36
      assert r7["review_rounds"] == 1.66
      assert r7["fix_passes"] == 0.58
      assert r7["attempts"] == 1.24
      assert r7["difficulty_raised"] == 0.0
      assert r7["time_to_close_mean_hours"] == 1.6
      assert r7["time_to_close_median_hours"] == 1.1
      assert r7["cost_usd_mean"] == 2.75
      assert r7["cost_usd_median"] == 2.20

      # 8. opus-5, D3
      r8 = find_row(rows, "claude", "claude-opus-5", 3)
      assert r8["n"] == 159
      assert r8["round_1_approve"] == 0.45
      assert r8["reviewed_n"] == 143
      assert r8["review_rounds"] == 1.87
      assert r8["fix_passes"] == 0.57
      assert r8["attempts"] == 1.55
      assert r8["difficulty_raised"] == 0.03
      assert r8["time_to_close_mean_hours"] == 8.8
      assert r8["time_to_close_median_hours"] == 2.0
      assert r8["cost_usd_mean"] == 20.82
      assert r8["cost_usd_median"] == 16.81

      # 9. opus-5-5, D3
      r9 = find_row(rows, "claude", "claude-opus-5-5", 3)
      assert r9["n"] == 100
      assert r9["round_1_approve"] == 0.84
      assert r9["reviewed_n"] == 96
      assert r9["review_rounds"] == 1.32
      assert r9["fix_passes"] == 0.10
      assert r9["attempts"] == 1.51
      assert r9["difficulty_raised"] == 0.0
      assert r9["time_to_close_mean_hours"] == 9.0
      assert r9["time_to_close_median_hours"] == 2.4
      assert r9["cost_usd_mean"] == 10.66
      assert r9["cost_usd_median"] == 8.76

      # 10. sonnet-5-5, D3
      r10 = find_row(rows, "claude", "claude-sonnet-5-5", 3)
      assert r10["n"] == 8
      assert r10["round_1_approve"] == 0.88
      assert r10["reviewed_n"] == 8
      assert r10["review_rounds"] == 1.50
      assert r10["fix_passes"] == 0.00
      assert r10["attempts"] == 1.88
      assert r10["difficulty_raised"] == 0.0
      assert r10["time_to_close_mean_hours"] == 1.8
      assert r10["time_to_close_median_hours"] == 1.7
      assert r10["cost_usd_mean"] == 5.08
      assert r10["cost_usd_median"] == 4.72

      # 11. opus-5, D4
      r11 = find_row(rows, "claude", "claude-opus-5", 4)
      assert r11["n"] == 9
      assert r11["round_1_approve"] == 0.78
      assert r11["reviewed_n"] == 9
      assert r11["review_rounds"] == 1.44
      assert r11["fix_passes"] == 0.11
      assert r11["attempts"] == 1.33
      assert r11["difficulty_raised"] == 0.0
      assert r11["time_to_close_mean_hours"] == 24.1
      assert r11["time_to_close_median_hours"] == 2.2
      assert r11["cost_usd_mean"] == 33.15
      assert r11["cost_usd_median"] == 24.72

      # 12. opus-5-5, D4
      r12 = find_row(rows, "claude", "claude-opus-5-5", 4)
      assert r12["n"] == 6
      assert r12["round_1_approve"] == 0.83
      assert r12["reviewed_n"] == 6
      assert r12["review_rounds"] == 1.17
      assert r12["fix_passes"] == 0.17
      assert r12["attempts"] == 1.17
      assert r12["difficulty_raised"] == 0.0
      assert r12["time_to_close_mean_hours"] == 22.2
      assert r12["time_to_close_median_hours"] == 6.4
      assert r12["cost_usd_mean"] == 55.30
      assert r12["cost_usd_median"] == 31.51
    end
  end

  describe "fallback ladder lookup/2" do
    test "falls back from Rung 0 to Rung 1 when issue_type is not matched" do
      found =
        Competence.lookup(Competence.default_rows(), %{
          provider: "claude",
          model: "claude-sonnet-5",
          difficulty: 2,
          issue_type: "bug"
        })

      assert found.rung == 1
      assert found.basis == :model_difficulty
      assert found.author_runs == 2.53
      assert found.review_runs == 2.36
    end

    test "matches Rung 0 when issue_type is present in matrix" do
      custom_rows =
        [
          %{
            "match" => %{
              "provider" => "claude",
              "model" => "claude-sonnet-5",
              "difficulty" => 2,
              "issue_type" => "bug"
            },
            "n" => 15,
            "rung" => 0,
            "author_runs" => 1.9,
            "review_runs" => 1.2,
            "time_to_close_median_hours" => 0.8
          }
        ] ++ Competence.default_rows()

      found =
        Competence.lookup(custom_rows, %{
          provider: "claude",
          model: "claude-sonnet-5",
          difficulty: 2,
          issue_type: "bug"
        })

      assert found.rung == 0
      assert found.basis == :cell
      assert found.author_runs == 1.9
      assert found.time_h == 0.8
    end

    test "falls back to Rung 2 (family, tier, difficulty) when model has no row" do
      custom_rows =
        [
          %{
            "match" => %{
              "family" => "anthropic",
              "tier" => "flagship",
              "difficulty" => 4
            },
            "n" => 20,
            "rung" => 2,
            "author_runs" => 1.5,
            "review_runs" => 1.2,
            "time_to_close_median_hours" => 15.0
          }
        ] ++ Competence.default_rows()

      found =
        Competence.lookup(custom_rows, %{
          provider: "claude",
          model: "claude-future-model",
          tier: "flagship",
          difficulty: 4
        })

      assert found.rung == 2
      assert found.basis == :family_tier_difficulty
      assert found.author_runs == 1.5
    end

    test "falls back to Rung 3 prior when unmeasured" do
      found =
        Competence.lookup(Competence.default_rows(), %{
          provider: "codex",
          model: "o3-mini",
          difficulty: 2
        })

      assert found.rung == 3
      assert found.basis == :prior
      assert found.author_runs > 0
    end
  end

  describe "rows/0 and installation override" do
    test "installation override takes precedence over default rows" do
      override = [
        %{
          "match" => %{"provider" => "claude", "model" => "claude-sonnet-5", "difficulty" => 2},
          "n" => 500,
          "rung" => 1,
          "author_runs" => 1.1,
          "review_runs" => 0.9,
          "time_to_close_median_hours" => 0.5
        }
      ]

      assert {:ok, _} = Settings.set_competence_matrix(override)

      found =
        Competence.lookup(Competence.rows(), %{
          provider: "claude",
          model: "claude-sonnet-5",
          difficulty: 2
        })

      assert found.author_runs == 1.1
      assert found.review_runs == 0.9
      assert found.time_h == 0.5
      assert found.n == 500
    end
  end

  describe "estimate/4" do
    test "without reviewer coupling, returns author draw and nil reviewer windows" do
      ws = %Workspace{id: "ws-1", config: %{}}

      entry = %{
        agent_type: "antigravity",
        model: "gemini-3.8-flash-low",
        family: :google,
        pool: "gemini"
      }

      task = %Issue{id: "t-1", difficulty: 1}

      res = Competence.estimate(ws, entry, task)
      assert res.draw == 2.69
      assert res.sides == %{author: 2.69, review: 1.69}
      assert res.reviewer_windows == nil
      assert res.time_h == 1.1
      assert %{"rung" => 1, "n" => 13} = res.cell
    end
  end

  defp find_row(rows, provider, model, difficulty) do
    Enum.find(rows, fn %{"match" => m} ->
      m["provider"] == provider and m["model"] == model and m["difficulty"] == difficulty
    end)
  end
end
