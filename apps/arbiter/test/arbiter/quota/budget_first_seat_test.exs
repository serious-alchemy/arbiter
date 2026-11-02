defmodule Arbiter.Quota.BudgetFirstSeatTest do
  @moduledoc """
  The first-seat rule (bd-22w64f; `docs/design/provider-dynamic-concurrency.md`
  §3.10): a pool with no seats in use whose usage is below its line on every
  trusted window publishes a budget of at least 1, whatever `raw` says, through
  `compute/1`, `hysteresis/3` and `publish/3`. Hard zeros and a ceiling of 0
  still win; a pool with no trusted reading and a pool with `raw >= 1` are
  unchanged.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Gate.Snapshot

  @now ~U[2026-10-10 01:40:27Z]
  @paced %{"threshold_mode" => "paced"}

  defp account(config \\ @paced, max_concurrent \\ nil),
    do: %ProviderAccount{provider: :claude, quota_config: config, max_concurrent: max_concurrent}

  # A fresh window: 10% used on both windows, the 5h line at its 35% floor now
  # and 40% in the 2 h horizon, the 7d line past 55%.
  defp snapshot(overrides \\ []) do
    struct!(
      %Snapshot{
        provider: "claude",
        utilization: 0.10,
        status: "allowed",
        reset_at: DateTime.add(@now, 5 * 3600, :second),
        captured_at: @now,
        capture_source: "oauth_poll",
        window_label: "5h",
        secondary_utilization: 0.10,
        secondary_status: "allowed",
        secondary_reset_at: DateTime.add(@now, 3 * 86_400, :second),
        secondary_window_label: "7d"
      },
      overrides
    )
  end

  # rho 0.25/seat-h puts the 5h window at raw (0.40 - 0.10) / (0.25 * 2) = 0.6.
  defp compute(overrides) do
    base = [
      account: account(),
      pool: "claude",
      quota: snapshot(),
      now: @now,
      seats: 0,
      horizon: 2.0,
      rates: %{"5h" => %{rho: 0.25}}
    ]

    base |> Keyword.merge(overrides) |> Budget.compute()
  end

  defp publish(computed, state \\ Budget.new_hysteresis(), now \\ @now),
    do: Budget.publish(computed, state, now)

  describe "AC1: the rule in compute/1" do
    test "an idle pool under its line with raw in (0, 1) gets one seat, and says so" do
      b = compute([])

      assert_in_delta b.raw, 0.6, 1.0e-6
      assert b.budget == 1
      assert b.free == 1
      assert b.binding == {:window, "5h"}
      assert b.quota_binding == "5h"
      assert b.reason =~ "first-seat rule"
      assert b.reason =~ "raw 0.60"
      assert b.reason =~ "5h binds"
    end

    test "raw at or below 0 still gets the seat when usage is under the line" do
      b = compute(rates: %{"5h" => %{rho: 0.25}}, background: 0.5)

      assert b.raw < 0
      assert b.budget == 1
      assert b.reason =~ "first-seat rule"
    end

    test "a pool with a seat in use is not touched" do
      b = compute(seats: 1)

      assert b.budget == max(floor(b.raw), 0)
      refute b.reason =~ "first-seat"
    end
  end

  describe "AC2: through hysteresis and publish" do
    test "a stream of raw 0.6 recomputes publishes 1 on the first publish and every later one" do
      {first, s1} = publish(compute([]), Budget.new_hysteresis(), @now)
      assert first.budget == 1

      {second, s2} = publish(compute([]), s1, DateTime.add(@now, 5, :second))
      assert second.budget == 1

      {third, _s3} = publish(compute([]), s2, DateTime.add(@now, 120, :second))
      assert third.budget == 1
      assert third.reason =~ "first-seat rule"
    end

    test "a pool published at 0 earlier rises to 1 at once, not after the dwell" do
      held = Budget.hysteresis(Budget.new_hysteresis(), 0.2, @now)
      assert held.budget == 0

      {published, next} = publish(compute([]), held, DateTime.add(@now, 1, :second))
      assert published.budget == 1
      assert next.budget == 1
    end

    test "raw just over 1 does not wait on the rise margin from a published 0" do
      # raw 1.1 is inside [B + 1, B + 1.25): hysteresis alone would hold 0
      b = compute(rates: %{"5h" => %{rho: 0.25 * 0.6 / 1.1}})
      assert_in_delta b.raw, 1.1, 1.0e-6

      held = %{budget: 0, pending: nil}
      assert Budget.hysteresis(held, b.raw, @now).budget == 0

      {published, _} = publish(b, held)
      assert published.budget == 1
    end

    test "a fall from a high published budget lands on 1, not 0" do
      high = %{budget: 5, pending: nil}
      {published, next} = publish(compute([]), high)
      assert published.budget == 1
      assert next.budget == 1
    end

    test "once the seat is taken the next recompute no longer applies the rule" do
      {_, s1} = publish(compute([]))
      {taken, _} = publish(compute(seats: 1), s1, DateTime.add(@now, 30, :second))

      assert taken.free == 0
      refute taken.reason =~ "first-seat"
      assert taken.budget <= 1
    end
  end

  describe "AC4: no first seat at or above the line" do
    test "5h usage at its line" do
      b = compute(quota: snapshot(utilization: 0.35))
      assert b.budget == 0
      refute b.reason =~ "first-seat"
    end

    test "5h usage above its line" do
      b = compute(quota: snapshot(utilization: 0.60))
      assert b.budget == 0
    end

    test "the 7d window above its line while the 5h window has headroom" do
      b = compute(quota: snapshot(secondary_utilization: 0.90))

      assert b.budget == 0
      refute b.reason =~ "first-seat"
    end

    test "the 5h window above its line while the 7d window has headroom" do
      b = compute(quota: snapshot(utilization: 0.50), rates: %{"5h" => %{rho: 0.25}})
      assert b.budget == 0
    end

    test "publish does not lift it either" do
      {published, _} = publish(compute(quota: snapshot(utilization: 0.50)))
      assert published.budget == 0
    end
  end

  describe "AC5: hard zeros and ceilings win" do
    for {hard, binding} <- [paused: :paused, quota_stop: :quota_stop, unavailable: :unavailable] do
      test "#{hard} stays at 0" do
        {published, _} = publish(compute(hard: unquote(hard)))
        assert published.budget == 0
        assert published.binding == unquote(binding)
        assert published.exempt_budget in [nil, 0]
      end
    end

    test "the provider refusing stays at 0" do
      {published, _} = publish(compute(quota: snapshot(status: "rejected")))
      assert published.budget == 0
      assert published.binding == :provider_refusing
    end

    test "max_concurrent 0 stays at 0" do
      b = compute(account: account(@paced, 0))
      assert b.budget == 0
      {published, _} = publish(b)
      assert published.budget == 0
    end

    test "a share of 0 stays at 0" do
      b = compute(share: 0)
      assert b.budget == 0
      {published, _} = publish(b)
      assert published.budget == 0
    end

    test "a positive ceiling is still the cap" do
      {published, _} = publish(compute(account: account(@paced, 1)))
      assert published.budget == 1
    end
  end

  describe "AC6: no trusted reading" do
    test "behaves as before, with and without a previous budget" do
      assert %{budget: 1, binding: :no_reading} = compute(quota: nil)

      held =
        compute(
          quota: nil,
          previous: %{budget: 0, trusted_at: DateTime.add(@now, -60, :second)}
        )

      assert held.budget == 0
      assert held.binding == :no_reading
      {published, _} = publish(held)
      assert published.budget == 0
    end

    test "windows without a reading do not make a first seat" do
      b = compute(quota: snapshot(utilization: nil, secondary_utilization: nil))
      assert b.binding == :no_reading
      refute b.reason =~ "first-seat"
    end
  end

  describe "AC7: exempt_budget" do
    test "follows the rule and never falls below the budget" do
      exempt = account(%{"threshold_mode" => "paced", "pace_exempt_priority" => 0})
      b = compute(account: exempt)

      assert b.budget == 1
      assert is_integer(b.exempt_budget)
      assert b.exempt_budget >= b.budget

      {published, _} = publish(b)
      assert published.exempt_budget >= published.budget
    end

    test "an exempt account with max_concurrent 0 keeps the budget at 0" do
      exempt = account(%{"threshold_mode" => "paced", "pace_exempt_priority" => 0}, 0)
      b = compute(account: exempt)
      assert b.budget == 0
      assert b.exempt_budget >= b.budget
    end
  end

  describe "AC9: raw >= 1 is unchanged" do
    test "compute and publish give floor(raw) as before" do
      b = compute(rates: %{"5h" => %{rho: 0.05}}, seats: 0)
      assert b.raw >= 1

      {published, _} = publish(b)
      assert published.budget == floor(b.raw)
      refute published.reason =~ "first-seat"
      assert published.reason =~ "quota allows #{floor(b.raw)}"
    end

    test "hysteresis/3 itself is untouched" do
      assert %{budget: 0} = Budget.hysteresis(Budget.new_hysteresis(), 0.6, @now)
    end
  end
end
