defmodule Arbiter.Quota.PaceTest do
  @moduledoc """
  The per-window pace verdict (bd-clzkvp) — the one definition of "ahead of
  pace" shared by the paced dispatch gate and the quota bars. Pure, so every
  case states its inputs outright.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Quota.Pace

  @five_hours 18_000
  @seven_days 604_800

  # The gate's defaults with the account in paced mode: 5h floor 0.35, 7d
  # floor 0.20, and the flat ceilings a paced side falls back to when the
  # window's elapsed fraction is unknown.
  @paced_5h %{sides: [{:paced, 0.35, nil}], default: 0.85}
  @paced_7d %{sides: [{:paced, 0.20, nil}], default: 0.90}
  @flat_5h %{sides: [], default: 0.85}

  defp at(u, elapsed, window, thresholds),
    do: Pace.evaluate(u, elapsed * window, window, thresholds)

  defp verdict(u, elapsed, window, thresholds), do: at(u, elapsed, window, thresholds).verdict

  describe "5h window, paced (floor 0.35, margin #{Pace.approaching_margin()})" do
    test "holding starts exactly at the ceiling" do
      # 30% elapsed: the 0.35 floor is the ceiling.
      assert verdict(0.35, 0.3, @five_hours, @paced_5h) == :holding
      assert verdict(0.3499, 0.3, @five_hours, @paced_5h) == :approaching
    end

    test "approaching starts exactly one margin below the ceiling" do
      assert verdict(0.25, 0.3, @five_hours, @paced_5h) == :approaching
      assert verdict(0.2499, 0.3, @five_hours, @paced_5h) == :ok
    end

    test "past the floor the ceiling is elapsed" do
      assert %{verdict: :holding, ceiling: 0.6, mode: :paced, elapsed: 0.6} =
               at(0.6, 0.6, @five_hours, @paced_5h)

      assert verdict(0.59, 0.6, @five_hours, @paced_5h) == :approaching
      assert verdict(0.49, 0.6, @five_hours, @paced_5h) == :ok
    end

    test "sampling: under 5% of the window elapsed or under 5% used, when otherwise ok" do
      # 5% of 5h is 15 minutes.
      assert verdict(0.10, 0.049, @five_hours, @paced_5h) == :sampling
      assert verdict(0.10, 0.05, @five_hours, @paced_5h) == :ok
      assert verdict(0.049, 0.5, @five_hours, @paced_5h) == :sampling
      assert verdict(0.05, 0.5, @five_hours, @paced_5h) == :ok
    end

    test "holding and approaching outrank sampling — the gate holds however early" do
      assert verdict(0.40, 0.01, @five_hours, @paced_5h) == :holding
      assert verdict(0.30, 0.01, @five_hours, @paced_5h) == :approaching
    end

    test "in the last minute of the window 0.99 is approaching, not holding" do
      assert verdict(0.99, 1 - 30 / @five_hours, @five_hours, @paced_5h) == :approaching
    end
  end

  describe "7d window, paced (floor 0.20)" do
    test "holding starts exactly at the ceiling" do
      assert verdict(0.20, 0.1, @seven_days, @paced_7d) == :holding
      assert verdict(0.1999, 0.1, @seven_days, @paced_7d) == :approaching
      assert verdict(0.0999, 0.1, @seven_days, @paced_7d) == :ok
    end

    test "35% used at 29% elapsed is 1.2x pace — over the paced ceiling" do
      assert %{verdict: :holding, ceiling: c} = at(0.35, 0.29, @seven_days, @paced_7d)
      assert_in_delta c, 0.29, 1.0e-9
    end

    test "the same reading under a looser weekly floor is only approaching" do
      thresholds = %{@paced_7d | sides: [{:paced, 0.40, nil}]}
      assert verdict(0.35, 0.29, @seven_days, thresholds) == :approaching
    end

    test "sampling floor is 5% of the window — about 8.4 hours for 7d" do
      assert verdict(0.06, 8 * 3600 / @seven_days, @seven_days, @paced_7d) == :sampling
      assert verdict(0.06, 9 * 3600 / @seven_days, @seven_days, @paced_7d) == :ok
    end
  end

  describe "flat and fallback thresholds" do
    test "flat: a fixed ceiling, independent of elapsed" do
      assert %{verdict: :holding, ceiling: 0.85, mode: :flat} =
               at(0.85, 0.99, @five_hours, @flat_5h)

      assert verdict(0.75, 0.01, @five_hours, @flat_5h) == :approaching
      assert verdict(0.74, 0.5, @five_hours, @flat_5h) == :ok
    end

    test "a paced side with no known elapsed falls back to its own flat ceiling" do
      thresholds = %{sides: [{:paced, 0.35, 0.6}], default: 0.85}

      assert %{verdict: :holding, ceiling: 0.6, mode: :flat, elapsed: nil} =
               Pace.evaluate(0.6, nil, nil, thresholds)
    end

    test "... or to the default when it has none" do
      assert %{verdict: :approaching, ceiling: 0.85, mode: :flat} =
               Pace.evaluate(0.8, 100, nil, @paced_5h)
    end

    test "the strictest side at the moment of the check binds" do
      thresholds = %{sides: [{:paced, 0.35, nil}, {:flat, 0.6}], default: 0.85}

      assert %{ceiling: 0.35, mode: :paced} = at(0.1, 0.1, @five_hours, thresholds)
      assert %{ceiling: 0.6, mode: :flat} = at(0.1, 0.9, @five_hours, thresholds)
    end

    test "elapsed is clamped to the window" do
      assert %{elapsed: +0.0} = Pace.evaluate(0.1, -60, @five_hours, @paced_5h)
      assert %{elapsed: 1.0} = Pace.evaluate(0.1, @five_hours + 60, @five_hours, @paced_5h)
    end

    test "no utilization reading is ok, never holding" do
      assert %{verdict: :ok} = at(nil, 0.5, @five_hours, @paced_5h)
    end
  end

  describe "side_ceiling/2 under the ramp curve" do
    test "is floor + (1 - floor) * elapsed at 0, 0.5 and 1.0, on the primary and long floors" do
      for floor <- [0.10, 0.35, 0.20] do
        side = {:paced, floor, nil, :ramp}

        assert {c0, :paced} = Pace.side_ceiling(side, 0.0)
        assert_in_delta c0, floor, 1.0e-9

        assert {c5, :paced} = Pace.side_ceiling(side, 0.5)
        assert_in_delta c5, floor + (1 - floor) * 0.5, 1.0e-9

        assert {c1, :paced} = Pace.side_ceiling(side, 1.0)
        assert_in_delta c1, 1.0, 1.0e-9
      end
    end

    test "has no plateau: strictly rising from the first instant" do
      side = {:paced, 0.10, nil, :ramp}
      {a, _} = Pace.side_ceiling(side, 0.01)
      {b, _} = Pace.side_ceiling(side, 0.02)
      {c, _} = Pace.side_ceiling(side, 0.10)
      assert a < b and b < c
    end

    test "matches the ruled 7d and 5h reference points at floor 0.10" do
      side = {:paced, 0.10, nil, :ramp}

      for {hours, window, expected} <- [
            {24, 168, 0.23},
            {84, 168, 0.55},
            {120, 168, 0.74},
            {1, 5, 0.28},
            {2.5, 5, 0.55},
            {4, 5, 0.82}
          ] do
        {c, :paced} = Pace.side_ceiling(side, hours / window)
        assert_in_delta c, expected, 0.01
      end
    end

    test "the plateau curve (named or implicit) stays max(floor, elapsed)" do
      for side <- [{:paced, 0.35, nil}, {:paced, 0.35, nil, :plateau}] do
        assert {0.35, :paced} = Pace.side_ceiling(side, 0.1)
        assert {0.5, :paced} = Pace.side_ceiling(side, 0.5)
      end
    end

    test "falls back to the flat ceiling without an elapsed fraction, like the plateau curve" do
      assert {0.6, :flat} = Pace.side_ceiling({:paced, 0.10, 0.6, :ramp}, nil)
      assert nil == Pace.side_ceiling({:paced, 0.10, nil, :ramp}, nil)
    end

    test "exempt: max(ramp line, cap), reported :exempt only when the cap lifts it" do
      # the ramp line at 0.5 with floor 0.10 is 0.55
      assert {0.7, :exempt} = Pace.side_ceiling({:paced_exempt, 0.10, nil, 0.7, :ramp}, 0.5)
      assert {c, :paced} = Pace.side_ceiling({:paced_exempt, 0.10, nil, 0.4, :ramp}, 0.5)
      assert_in_delta c, 0.55, 1.0e-9
      # the plateau line at 0.5 is 0.5, so a 0.52 cap lifts it there but not on the ramp
      assert {0.52, :exempt} = Pace.side_ceiling({:paced_exempt, 0.10, nil, 0.52}, 0.5)
      assert {c2, :paced} = Pace.side_ceiling({:paced_exempt, 0.10, nil, 0.52, :ramp}, 0.5)
      assert_in_delta c2, 0.55, 1.0e-9
    end

    test "evaluate/4 holds on the ramp line" do
      thresholds = %{sides: [{:paced, 0.10, nil, :ramp}], default: 0.85}
      # 50% elapsed: the line is 0.55
      assert verdict(0.55, 0.5, @seven_days, thresholds) == :holding
      assert verdict(0.54, 0.5, @seven_days, thresholds) == :approaching
      assert %{ceiling: c, mode: :paced} = at(0.2, 0.5, @seven_days, thresholds)
      assert_in_delta c, 0.55, 1.0e-9
    end

    test "min of mixed curves picks the lower at the moment of the check" do
      mixed = %{
        sides: [{:paced, 0.35, nil, :plateau}, {:paced, 0.10, nil, :ramp}],
        default: 0.85
      }

      # elapsed 0.1: plateau 0.35 vs ramp 0.19 -> ramp binds
      assert %{ceiling: c1} = at(0.0, 0.1, @five_hours, mixed)
      assert_in_delta c1, 0.19, 1.0e-9
      # elapsed 0.9: plateau 0.9 vs ramp 0.91 -> plateau binds
      assert %{ceiling: c2} = at(0.0, 0.9, @five_hours, mixed)
      assert_in_delta c2, 0.9, 1.0e-9
    end

    test "floor 0 makes the two curves identical (the spend side)" do
      for e <- [0.0, 0.25, 0.5, 1.0] do
        assert Pace.side_ceiling({:paced, 0.0, 1.0}, e) ==
                 Pace.side_ceiling({:paced, 0.0, 1.0, :ramp}, e)
      end
    end
  end

  describe "elapsed_seconds/3" do
    test "how far into the window `now` is" do
      now = ~U[2026-09-23 12:00:00Z]
      assert Pace.elapsed_seconds(DateTime.add(now, 3600, :second), @five_hours, now) == 14_400.0
    end

    test "nil without a reset or a window length" do
      now = ~U[2026-09-23 12:00:00Z]
      assert Pace.elapsed_seconds(nil, @five_hours, now) == nil
      assert Pace.elapsed_seconds(now, nil, now) == nil
    end
  end
end
