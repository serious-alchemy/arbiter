defmodule Arbiter.Quota.BurnTest do
  use ExUnit.Case, async: true

  alias Arbiter.Quota.Burn

  @now ~U[2026-11-02 12:00:00Z]
  @reset ~U[2026-11-06 00:00:00Z]

  defp sample(hours_ago, util, reset \\ @reset) do
    %{
      utilization: util,
      resets_at: reset,
      captured_at: DateTime.add(@now, -round(hours_ago * 3600), :second)
    }
  end

  # One sample per hour from `from` hours ago to now, utilization rising by `step`.
  defp hourly(from, start_util, step) do
    for h <- from..0//-1, do: sample(h, start_util + (from - h) * step)
  end

  describe "burn_24h/2" do
    test "is the 7d utilization gained over the last 24h" do
      samples = hourly(24, 0.30, 0.005)
      assert_in_delta Burn.burn_24h(samples, @now), 0.12, 1.0e-9
    end

    test "uses the last sample at or before the 24h mark as the baseline" do
      samples = [sample(25, 0.10), sample(23, 0.12) | hourly(22, 0.13, 0.01)]
      # 0.10 -> 0.12 -> 0.13 ... 0.35: the growth counts from the baseline sample
      assert_in_delta Burn.burn_24h(samples, @now), 0.35 - 0.10, 1.0e-9
    end

    test "a window reset inside the 24h restarts the baseline at zero" do
      new_reset = DateTime.add(@reset, 7 * 86_400, :second)

      before_reset = for h <- 24..13//-1, do: sample(h, 0.80 + (24 - h) * 0.01)
      # 12h ago the window rolled over: usage restarts near zero
      after_reset = for h <- 12..0//-1, do: sample(h, 0.02 + (12 - h) * 0.01, new_reset)

      # before: 0.80 -> 0.91 (+0.11); the reset adds the fresh window's 0.02; then +0.12
      assert_in_delta Burn.burn_24h(before_reset ++ after_reset, @now), 0.11 + 0.02 + 0.12, 1.0e-9
    end

    test "a utilization drop with an unchanged reset time is also read as a reset" do
      samples = [sample(24, 0.90), sample(12, 0.05), sample(0, 0.15)]
      samples = Enum.map(samples, &Map.put(&1, :resets_at, nil))
      # gaps are too wide for a trustworthy reading
      assert Burn.burn_24h(samples, @now) == nil

      dense =
        for h <- 24..0//-1, do: sample(h, if(h > 12, do: 0.90, else: 0.05 + (12 - h) * 0.01))

      dense = Enum.map(dense, &Map.put(&1, :resets_at, nil))
      assert_in_delta Burn.burn_24h(dense, @now), 0.05 + 0.12, 1.0e-9
    end

    test "jitter in resets_at is not a reset" do
      samples =
        for h <- 24..0//-1 do
          sample(h, 0.30 + (24 - h) * 0.005, DateTime.add(@reset, rem(h, 2), :second))
        end

      assert_in_delta Burn.burn_24h(samples, @now), 0.12, 1.0e-9
    end

    test "sparse samples give nil" do
      assert Burn.burn_24h([], @now) == nil
      assert Burn.burn_24h([sample(0, 0.5)], @now) == nil
      # history only spans 6h
      assert Burn.burn_24h(hourly(6, 0.3, 0.01), @now) == nil
      # a 10h hole in the middle
      assert Burn.burn_24h([sample(24, 0.3), sample(14, 0.4), sample(0, 0.5)], @now) == nil
    end

    test "a stale newest sample gives nil" do
      samples = for h <- 30..5//-1, do: sample(h, 0.3 + (30 - h) * 0.002)
      assert Burn.burn_24h(samples, @now) == nil
    end

    test "never negative" do
      samples = for h <- 24..0//-1, do: sample(h, 0.5)
      assert Burn.burn_24h(samples, @now) == 0.0
    end
  end

  describe "deltas/2" do
    test "evaluates the rolling burn on an hourly grid" do
      samples = hourly(72, 0.0, 0.004)
      deltas = Burn.deltas(samples)
      assert deltas != []
      # the first points sit inside the start slack (22-24h of history) and read a little low
      full = Enum.filter(deltas, &(DateTime.diff(&1.at, hd(deltas).at) >= 2 * 3600))
      assert Enum.all?(full, &(abs(&1.burn - 0.096) < 1.0e-9))
      assert Enum.all?(deltas, &(&1.burn <= 0.096 + 1.0e-9))
    end

    test "returns [] when the history is too short" do
      assert Burn.deltas(hourly(10, 0.0, 0.01)) == []
    end
  end

  describe "percentiles/1" do
    test "p50/p90/p99 of a list" do
      values = Enum.map(1..100, &(&1 / 100))
      assert %{p50: p50, p90: p90, p99: p99, n: 100} = Burn.percentiles(values)
      assert_in_delta p50, 0.505, 0.011
      assert_in_delta p90, 0.90, 0.011
      assert_in_delta p99, 0.99, 0.011
    end

    test "empty" do
      assert Burn.percentiles([]) == %{n: 0, p50: nil, p90: nil, p99: nil}
    end
  end
end
