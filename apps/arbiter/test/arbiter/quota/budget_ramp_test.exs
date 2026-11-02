defmodule Arbiter.Quota.BudgetRampTest do
  @moduledoc """
  `Budget` reads the paced line only through `Gate` (invariant I6), so
  `pace_curve: "ramp"` (bd-bq0gi8) must reach `line_now`, `line_at_h`, `n`,
  `n_before` and `n_after` with no change to `Budget`. Every expected value
  below is computed by hand from `line = floor + (1 - floor) * elapsed`, floor
  0.10, and checked against the same case on the default `"plateau"` curve.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Gate.Snapshot

  @now ~U[2026-10-10 01:40:27Z]

  defp account(curve) do
    config =
      %{"threshold_mode" => "paced", "paced_floor" => 0.10, "weekly_paced_floor" => 0.10}
      |> then(&if(curve, do: Map.put(&1, "pace_curve", curve), else: &1))

    %ProviderAccount{provider: :claude, quota_config: config, max_concurrent: nil}
  end

  defp snapshot(overrides) do
    struct(
      %Snapshot{
        provider: "claude",
        utilization: 0.19,
        status: "allowed",
        reset_at: ~U[2026-10-10 04:40:00Z],
        captured_at: ~U[2026-10-10 01:38:49Z],
        capture_source: "oauth_poll",
        window_label: "5h",
        secondary_utilization: 0.49,
        secondary_status: "allowed",
        secondary_reset_at: ~U[2026-10-12 16:00:00Z],
        secondary_window_label: "7d"
      },
      overrides
    )
  end

  defp compute(curve, quota, overrides \\ []) do
    base = [
      account: account(curve),
      pool: "claude",
      quota: quota,
      now: @now,
      seats: 3,
      horizon: 2.0,
      rates: %{"5h" => %{rho: 1 / 15}}
    ]

    Budget.compute(Keyword.merge(base, overrides))
  end

  defp window(budget, label), do: Enum.find(budget.windows, &(&1.window == label))

  describe "mid-window (5h, 2h59m33s to the reset: elapsed 0.4015, 0.8015 at the horizon)" do
    test "line_now, line_at_h and n follow the ramp" do
      w = window(compute("ramp", snapshot([])), "5h")

      # 0.10 + 0.9 * 0.4015 and 0.10 + 0.9 * 0.8015
      assert_in_delta w.line_now, 0.46135, 1.0e-4
      assert_in_delta w.line_at_h, 0.82135, 1.0e-4
      # u_now = 0.19 + 3 seats * (1/15) * 98 s of lag = 0.195444
      assert_in_delta w.used_now, 0.195444, 1.0e-5
      # n = (0.82135 - 0.195444) / (1/15 * 2)
      assert_in_delta w.n, 4.6943, 1.0e-3
      assert w.n_before == nil
    end

    test "the default curve is unchanged: the same case on max(floor, elapsed)" do
      w = window(compute(nil, snapshot([])), "5h")

      assert_in_delta w.line_now, 0.4015, 1.0e-4
      assert_in_delta w.line_at_h, 0.8015, 1.0e-4
      assert_in_delta w.n, 4.5454, 1.0e-3
    end

    test "the 7d line follows the ramp too" do
      ramp = window(compute("ramp", snapshot([])), "7d")
      plateau = window(compute("plateau", snapshot([])), "7d")

      # plateau == elapsed here (above the 0.10 floor)
      assert_in_delta ramp.line_now, 0.10 + 0.90 * plateau.line_now, 1.0e-9
      assert_in_delta ramp.line_at_h, 0.10 + 0.90 * plateau.line_at_h, 1.0e-9
    end
  end

  describe "reset inside the horizon (30 min to the reset, 1.5h of the next window in H)" do
    @b_now ~U[2026-10-10 04:10:00Z]

    defp near_reset(curve),
      do:
        curve
        |> compute(
          snapshot(%{
            utilization: 0.70,
            captured_at: @b_now,
            secondary_reset_at: ~U[2026-10-14 04:10:00Z],
            secondary_utilization: 0.10
          }),
          now: @b_now
        )
        |> window("5h")

    test "n_before reaches 1.0 at the reset, n_after starts the fresh window at floor + ramp" do
      w = near_reset("ramp")

      # line(reset) = 1.0 on either curve: (1.0 - 0.70) / (1/15 * 0.5)
      assert_in_delta w.n_before, 9.0, 1.0e-6
      # fresh line at x = 1.5h: 0.10 + 0.90 * (1.5 / 5) = 0.37; 0.37 / (1/15 * 1.5)
      assert_in_delta w.n_after, 3.7, 1.0e-6
      assert_in_delta w.n, 3.7, 1.0e-6
    end

    test "the default curve gives the old numbers: floor 0.10 < elapsed 0.30, so 0.30" do
      w = near_reset(nil)
      assert_in_delta w.n_before, 9.0, 1.0e-6
      assert_in_delta w.n_after, 3.0, 1.0e-6
    end
  end

  describe "after the reset (the window is evaluated fresh)" do
    test "u = 0 plus the draw since, against the fresh ramp line" do
      snap =
        snapshot(%{reset_at: ~U[2026-10-10 01:20:27Z], captured_at: ~U[2026-10-10 01:00:00Z]})

      w = window(compute("ramp", snap, rates: %{"5h" => %{rho: 0.1}}), "5h")

      assert w.fresh?
      # 20 minutes into the fresh window: 0.10 + 0.90 * (1/3 / 5) = 0.16
      assert_in_delta w.line_now, 0.16, 1.0e-6
      # 2h later: elapsed (1/3 + 2) / 5 -> 0.10 + 0.90 * 0.466667 = 0.52
      assert_in_delta w.line_at_h, 0.52, 1.0e-6
      # u_now = 3 seats * 0.1 * 1/3 h = 0.1; n = (0.52 - 0.1) / (0.1 * 2)
      assert_in_delta w.n, 2.1, 1.0e-6
    end
  end
end
