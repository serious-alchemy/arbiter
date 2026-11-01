defmodule Arbiter.Quota.Budget7dOnlyTest do
  @moduledoc """
  bd-9q51ze (5H C5): Anthropic retired the 5h window, so the admission budget
  for Claude is sized off the 7d window alone. Covers the absent-window
  handling in `Arbiter.Quota.Budget` (a nil-label primary is skipped and never
  reaches a reason string), the unchanged primary fallback length for windows
  with no fixed length (Codex `session`, agy `used`), and the bound the budget
  keeps when 7d is the only window.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.BudgetCalibration
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  @now ~U[2026-11-01 12:00:00Z]
  @week 7 * 86_400

  defp account(max_concurrent \\ 3),
    do: %ProviderAccount{
      provider: :claude,
      quota_config: %{"threshold_mode" => "paced"},
      max_concurrent: max_concurrent
    }

  defp long_only(attrs \\ []) do
    struct!(
      %Snapshot{
        provider: "claude",
        utilization: nil,
        status: nil,
        reset_at: nil,
        window_label: nil,
        captured_at: @now,
        capture_source: "oauth_poll",
        secondary_utilization: 0.30,
        secondary_status: "allowed",
        secondary_reset_at: DateTime.add(@now, 3 * 86_400, :second),
        secondary_window_label: "7d"
      },
      attrs
    )
  end

  defp compute(overrides) do
    [account: account(), pool: "claude", quota: long_only(), now: @now, seats: 1, horizon: 2.0]
    |> Keyword.merge(overrides)
    |> Budget.compute()
  end

  describe "a snapshot with no primary window (AC1, AC2)" do
    test "the nil-label primary is skipped: 7d is the only window and the binding" do
      b = compute([])

      assert Enum.map(b.windows, & &1.window) == ["7d"]
      assert Enum.map(b.windows, & &1.side) == [:long]
      assert b.quota_binding == "7d"
    end

    test "the reason names 7d and no primary entry" do
      b = compute(rates: %{"7d" => %{rho: 0.02}}, account: account(nil))

      assert b.binding == {:window, "7d"}
      assert b.reason =~ "7d binds"
      refute b.reason =~ "5h"
      refute b.reason =~ "primary"
      refute b.reason =~ "nil"
      refute b.reason =~ ~r/window:\s*,/
      assert Budget.binding_text(b.binding) == "window:7d"
    end

    test "no primary entry in the JSON either" do
      json = Budget.to_json(compute([]))

      assert Enum.map(json.windows, & &1.window) == ["7d"]
      assert json.quota_binding == "7d"
    end

    test "a Claude row with both windows still evaluates both (5h not dropped when present)" do
      both =
        long_only(
          utilization: 0.1,
          status: "allowed",
          window_label: "5h",
          reset_at: DateTime.add(@now, 3 * 3600, :second)
        )

      b = compute(quota: both)
      assert Enum.map(b.windows, & &1.window) == ["5h", "7d"]
    end
  end

  describe "the primary fallback length (AC5)" do
    test "a primary window with no fixed length (Codex `session`) still priors at 5h" do
      snap = %Snapshot{
        provider: "codex",
        utilization: 0.1,
        status: "allowed",
        reset_at: nil,
        window_label: "session",
        captured_at: @now,
        capture_source: "codex_poll"
      }

      b =
        Budget.compute(
          account: %ProviderAccount{provider: :codex, quota_config: %{}, max_concurrent: 4},
          pool: "codex",
          quota: snap,
          now: @now,
          seats: 1,
          horizon: 2.0
        )

      assert [%{window: "session", side: :primary} = w] = b.windows
      assert Gate.window_seconds("session", nil) == nil
      assert_in_delta w.rho, BudgetCalibration.prior(5 * 3600, 4), 1.0e-12
      assert w.rho_source == :prior
    end

    test "an agy `used` primary window also priors at 5h" do
      snap = %Snapshot{
        provider: "agy",
        utilization: 0.1,
        status: "allowed",
        reset_at: nil,
        window_label: "used",
        captured_at: @now,
        capture_source: "agy_poll"
      }

      b =
        Budget.compute(
          account: %ProviderAccount{provider: :agy, quota_config: %{}, max_concurrent: 2},
          pool: "agy",
          quota: snap,
          now: @now,
          seats: 1,
          horizon: 2.0
        )

      assert [%{window: "used", side: :primary} = w] = b.windows
      assert_in_delta w.rho, BudgetCalibration.prior(5 * 3600, 2), 1.0e-12
    end

    test "the long side still priors at 7d" do
      b = compute(account: account(2))
      assert [%{side: :long, rho: rho}] = b.windows
      assert_in_delta rho, BudgetCalibration.prior(@week, 2), 1.0e-12
    end
  end

  describe "7d is the only window (AC6)" do
    property "the budget never exceeds (line(t+H) - u) / (rho * H)" do
      check all(
              used <- float(min: 0.0, max: 1.0),
              seats <- integer(0..20),
              rho <- float(min: 0.0001, max: 0.2),
              b_rate <- float(min: 0.0, max: 0.05),
              horizon <- float(min: 1.0, max: 4.0),
              # reset at least H + epsilon away, so the plain (no-reset) branch applies
              reset_in_h <- float(min: 4.5, max: 160.0),
              lag_s <- integer(0..3600)
            ) do
        reset = DateTime.add(@now, round(reset_in_h * 3600), :second)

        snap =
          long_only(
            secondary_utilization: used,
            secondary_reset_at: reset,
            captured_at: DateTime.add(@now, -lag_s, :second)
          )

        acct = account(nil)

        b =
          compute(
            account: acct,
            quota: snap,
            seats: seats,
            horizon: horizon,
            background: b_rate,
            rates: %{"7d" => %{rho: rho}}
          )

        assert Enum.map(b.windows, & &1.window) == ["7d"]

        floor_rho = BudgetCalibration.rho_floor(BudgetCalibration.prior(@week, nil))
        rho_used = max(rho, floor_rho)

        line_end =
          {acct, nil}
          |> Gate.pace(:long, "7d", used, reset,
            now: DateTime.add(b.computed_at, round(horizon * 3_600_000), :millisecond)
          )
          |> Map.fetch!(:ceiling)

        bound = (line_end - used) / (rho_used * horizon)

        assert b.raw <= bound + 1.0e-9
        assert b.budget <= max(floor(bound + 1.0e-9), 0)
      end
    end
  end
end
