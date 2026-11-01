defmodule Arbiter.Loop.ScarcityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Loop.Scarcity

  describe "weighted_tokens/1" do
    test "weights each token class by the documented vector" do
      counts = %{
        tokens_in: 1000,
        tokens_out: 100,
        cache_creation_tokens: 400,
        cache_read_tokens: 10_000
      }

      w = Scarcity.weights()

      expected =
        1000 * w.input + 100 * w.output + 400 * w.cache_write + 10_000 * w.cache_read

      assert Scarcity.weighted_tokens(counts) == expected
    end

    test "output tokens draw more than input tokens; cache reads draw least" do
      w = Scarcity.weights()
      assert w.output > w.input
      assert w.cache_read < w.input
      assert w.cache_write >= w.input
    end

    test "nil and missing counts are zero, and string keys are accepted" do
      assert Scarcity.weighted_tokens(%{}) == 0.0
      assert Scarcity.weighted_tokens(%{tokens_in: nil, tokens_out: nil}) == 0.0

      assert Scarcity.weighted_tokens(%{"tokens_in" => 10}) ==
               Scarcity.weighted_tokens(%{tokens_in: 10})
    end
  end

  describe "calibrate/2" do
    test "derives 5h capacity from observed weighted tokens and observed utilization" do
      cal =
        Scarcity.calibrate(1_200_000.0, %{
          utilization_5h: 0.4,
          captured_at: ~U[2026-09-04 10:00:00Z]
        })

      assert cal.status == :calibrated
      assert cal.window == :five_hour
      assert_in_delta cal.capacity_weighted_tokens, 3_000_000.0, 0.001
      assert cal.utilization == 0.4
      assert cal.observed_weighted_tokens == 1_200_000.0
      assert cal.captured_at == ~U[2026-09-04 10:00:00Z]
      assert cal.reason == nil
    end

    test "no snapshot means no calibration, with a machine-readable reason" do
      cal = Scarcity.calibrate(1_200_000.0, nil)
      assert cal.status == :uncalibrated
      assert cal.capacity_weighted_tokens == nil
      assert cal.reason == :no_snapshot
    end

    test "a snapshot without a 5h utilization figure cannot calibrate" do
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: nil})
      assert cal.status == :uncalibrated
      assert cal.reason == :no_utilization
    end

    test "zero utilization cannot calibrate (division by zero, not infinite capacity)" do
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.0})
      assert cal.status == :uncalibrated
      assert cal.reason == :no_utilization
    end

    test "an idle window (no observed tokens) cannot calibrate" do
      cal = Scarcity.calibrate(0.0, %{utilization_5h: 0.4})
      assert cal.status == :uncalibrated
      assert cal.reason == :no_observed_tokens
    end

    # The dangerous case: a reading from a window that has already rolled would
    # otherwise calibrate plausibly — and wrongly — off a utilization figure that
    # describes a different interval than the observed draw.
    test "a stale snapshot is refused, and says so rather than producing a capacity" do
      cal =
        Scarcity.calibrate(1_200_000.0, nil,
          stale: %{utilization_5h: 0.4, captured_at: ~U[2026-09-01 10:00:00Z]}
        )

      assert cal.status == :uncalibrated
      assert cal.reason == :stale_snapshot
      assert cal.capacity_weighted_tokens == nil
      assert Scarcity.window_share(300_000.0, cal) == nil

      # The rejected reading is still cited, so the report can say how blind the
      # window is rather than only that it is blind.
      assert cal.captured_at == ~U[2026-09-01 10:00:00Z]
      assert cal.utilization == nil
    end
  end

  describe "window_share/2" do
    test "a run's share is its weighted draw over one 5h window's capacity" do
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.4})
      assert_in_delta Scarcity.window_share(300_000.0, cal), 0.1, 0.0001
    end

    test "a global scale error in the weights cancels out of the share" do
      # Because capacity is calibrated from the SAME weighting, doubling every
      # weight leaves the share unchanged. Only relative weights matter — the
      # argument that lets the pricing-derived weight vector stand in for
      # Anthropic's unpublished one.
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.4})
      doubled = Scarcity.calibrate(2_400_000.0, %{utilization_5h: 0.4})

      assert_in_delta Scarcity.window_share(300_000.0, cal),
                      Scarcity.window_share(600_000.0, doubled),
                      0.0001
    end

    test "an uncalibrated window yields nil, never a fabricated zero" do
      cal = Scarcity.calibrate(0.0, nil)
      assert Scarcity.window_share(300_000.0, cal) == nil
      assert Scarcity.window_share(300_000.0, nil) == nil
    end
  end

  describe "calibrate/3 on the 7d window (bd-c2v31s)" do
    test "window: :seven_day divides by utilization_7d, not utilization_5h" do
      cal =
        Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.9, utilization_7d: 0.1},
          window: :seven_day
        )

      assert cal.status == :calibrated
      assert cal.window == :seven_day
      assert cal.utilization == 0.1
      assert_in_delta cal.capacity_weighted_tokens, 12_000_000.0, 0.001
    end

    test "a 7d calibration with no 7d utilization is uncalibrated even if 5h is present" do
      cal = Scarcity.calibrate(1_200_000.0, %{utilization_5h: 0.4}, window: :seven_day)
      assert cal.status == :uncalibrated
      assert cal.reason == :no_utilization
      assert cal.window == :seven_day
    end

    test "an uncalibrated frame still names the window it tried" do
      assert Scarcity.calibrate(0.0, nil, window: :seven_day).window == :seven_day
    end
  end

  describe "primary_window/1" do
    test "a snapshot with a 5h primary window calibrates on 5h" do
      q = %Arbiter.Quota.AnthropicQuota{
        provider: "claude",
        utilization_5h: 0.3,
        reset_5h_at: ~U[2026-09-04 12:00:00Z],
        status_5h: "allowed",
        utilization_7d: 0.1
      }

      assert Scarcity.primary_window(q) == :five_hour
    end

    test "Claude with no primary window (5h retired) calibrates on 7d" do
      q = %Arbiter.Quota.AnthropicQuota{
        provider: "claude",
        utilization_5h: nil,
        reset_5h_at: nil,
        status_5h: nil,
        utilization_7d: 0.1,
        reset_7d_at: ~U[2026-09-08 12:00:00Z]
      }

      assert Scarcity.primary_window(q) == :seven_day
    end

    test "no snapshot at all names the 7d window (Claude's remaining window)" do
      assert Scarcity.primary_window(nil) == :seven_day
    end
  end

  describe "window_start/3" do
    test "7d window starts seven days before its future reset" do
      q = %Arbiter.Quota.AnthropicQuota{reset_7d_at: ~U[2026-09-08 12:00:00Z]}
      now = ~U[2026-09-04 10:00:00Z]
      assert Scarcity.window_start(q, :seven_day, now) == ~U[2026-09-01 12:00:00Z]
    end

    test "7d window with no usable reset trails seven days from now" do
      now = ~U[2026-09-04 10:00:00Z]
      assert Scarcity.window_start(nil, :seven_day, now) == ~U[2026-08-28 10:00:00Z]
    end

    test "5h window delegates to the five-hour span" do
      q = %Arbiter.Quota.AnthropicQuota{reset_5h_at: ~U[2026-09-04 12:00:00Z]}
      now = ~U[2026-09-04 10:00:00Z]
      assert Scarcity.window_start(q, :five_hour, now) == ~U[2026-09-04 07:00:00Z]
    end
  end

  describe "normalize_unit/1 (stored-atom alias)" do
    test "the pre-rename :window_share_5h loads as :window_share" do
      assert Scarcity.normalize_unit(:window_share_5h) == :window_share
      assert Scarcity.normalize_unit("window_share_5h") == :window_share
    end

    test "current and dollar units pass through" do
      assert Scarcity.normalize_unit(:window_share) == :window_share
      assert Scarcity.normalize_unit("window_share") == :window_share
      assert Scarcity.normalize_unit(:cost_usd) == :cost_usd
      assert Scarcity.normalize_unit("cost_usd") == :cost_usd
    end

    test "anything else is nil rather than a guessed atom" do
      assert Scarcity.normalize_unit(:bogus) == nil
      assert Scarcity.normalize_unit("bogus") == nil
      assert Scarcity.normalize_unit(nil) == nil
    end
  end

  describe "window_label/1" do
    test "names the window" do
      assert Scarcity.window_label(:five_hour) == "5h"
      assert Scarcity.window_label(:seven_day) == "7d"
    end
  end

  describe "format_share/2" do
    test "names the window actually used" do
      assert Scarcity.format_share(0.25, :seven_day) == "25.0% of one 7d window"
      assert Scarcity.format_share(nil, :seven_day) == "unavailable (7d window uncalibrated)"
    end
  end

  describe "format_share/1" do
    test "renders a share as a percentage of one 5h window" do
      assert Scarcity.format_share(0.1234) == "12.3% of one 5h window"
      assert Scarcity.format_share(0.0) == "0.0% of one 5h window"
    end

    test "renders an unavailable share honestly rather than as zero" do
      assert Scarcity.format_share(nil) =~ "uncalibrated"
    end
  end

  describe "billing_mode/2" do
    test "explicit workspace config wins over inference" do
      config = %{"loop" => %{"billing_mode" => "metered"}}
      assert Scarcity.billing_mode(config, %{utilization_5h: 0.4}) == {:metered, :configured}

      config = %{"loop" => %{"billing_mode" => "subscription"}}
      assert Scarcity.billing_mode(config, nil) == {:subscription, :configured}
    end

    test "a unified-window snapshot infers subscription billing" do
      assert Scarcity.billing_mode(%{}, %{utilization_5h: 0.4}) == {:subscription, :inferred}
      assert Scarcity.billing_mode(nil, %{utilization_5h: 0.0}) == {:subscription, :inferred}
    end

    test "a 7d-only snapshot (5h retired, utilization_5h nil) infers subscription billing" do
      snap = %{utilization_5h: nil, utilization_7d: 0.61}
      assert Scarcity.billing_mode(%{}, snap) == {:subscription, :inferred}
    end

    test "both windows nil is metered" do
      snap = %{utilization_5h: nil, utilization_7d: nil}
      assert Scarcity.billing_mode(%{}, snap) == {:metered, :default}
    end

    test "no window evidence at all falls back to metered — dollars still bind there" do
      assert Scarcity.billing_mode(%{}, nil) == {:metered, :default}
      assert Scarcity.billing_mode(nil, %{utilization_5h: nil}) == {:metered, :default}
    end

    test "an unrecognised configured mode is ignored rather than trusted" do
      config = %{"loop" => %{"billing_mode" => "barter"}}
      assert Scarcity.billing_mode(config, %{utilization_5h: 0.4}) == {:subscription, :inferred}
    end
  end

  describe "primary_metric/1" do
    test "quota denominates the objective under subscription billing" do
      assert Scarcity.primary_metric({:subscription, :inferred}) == :window_share
    end

    test "dollars stay the objective under metered billing" do
      assert Scarcity.primary_metric({:metered, :default}) == :cost_usd
    end
  end
end
