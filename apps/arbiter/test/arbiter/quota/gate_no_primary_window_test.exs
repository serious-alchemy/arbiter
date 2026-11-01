defmodule Arbiter.Quota.GateNoPrimaryWindowTest do
  @moduledoc """
  bd-9v8psv (5H C3): Anthropic retired the 5h window, so a Claude row can carry
  no primary reading at all (`utilization_5h` / `status_5h` / `reset_5h_at` all
  nil, bd-93zaej). Absent means nil: the snapshot has no primary window, the
  gate never binds on one, and "7d binds" is the whole story. A `0.0` primary
  with a nil reset would otherwise read as a live window and create a phantom
  cap, so it is covered as well.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Headroom
  alias Arbiter.Quota.Price

  @now ~U[2026-11-01 12:00:00Z]
  @reset_7d ~U[2026-11-04 12:00:00Z]

  defp policy(config \\ %{"threshold_mode" => "paced"}),
    do: {%ProviderAccount{provider: :claude, quota_config: config}, nil}

  defp long_only(attrs \\ []) do
    struct!(
      %AnthropicQuota{
        provider: "claude",
        utilization_5h: nil,
        status_5h: nil,
        reset_5h_at: nil,
        utilization_7d: 0.30,
        status_7d: "allowed",
        reset_7d_at: @reset_7d,
        captured_at: @now,
        capture_source: "oauth_poll"
      },
      attrs
    )
  end

  describe "Snapshot.Anthropic.normalize/2 (AC1)" do
    test "no 5h reading: nil window_label and nil primary fields; 7d carried" do
      assert %Snapshot{} = s = Snapshot.normalize(long_only())

      assert s.window_label == nil
      assert s.utilization == nil
      assert s.status == nil
      assert s.reset_at == nil
      assert s.secondary_window_label == "7d"
      assert s.secondary_utilization == 0.30
      assert s.secondary_reset_at == @reset_7d
    end

    test "a 0.0 primary with no reset is the phantom window: treated as absent" do
      s = Snapshot.normalize(long_only(utilization_5h: 0.0, status_5h: "allowed"))

      assert s.window_label == nil
      assert s.utilization == nil
      assert s.status == nil
    end

    test "a real 5h reading keeps the 5h label" do
      s =
        Snapshot.normalize(
          long_only(
            utilization_5h: 0.4,
            status_5h: "allowed",
            reset_5h_at: DateTime.add(@now, 3600)
          )
        )

      assert s.window_label == "5h"
      assert s.utilization == 0.4
    end
  end

  describe "Gate (AC2, AC3)" do
    test "never binds on the primary of a long-only snapshot" do
      assert Gate.gating_window(long_only(), policy(), now: @now) == nil
      assert Gate.gating_window(long_only(), policy(%{}), now: @now) == nil
    end

    test "a phantom 0.0 primary with nil reset never binds" do
      q = long_only(utilization_5h: 0.0, status_5h: "allowed")
      assert Gate.gating_window(q, policy(%{}), now: @now) == nil
    end

    test "7d binds when it is over its ceiling, and the phrase has no 5h text" do
      q = long_only(utilization_7d: 0.97, status_7d: "allowed_warning")

      assert %{window: "7d", signal: :utilization} =
               Gate.gating_window(q, policy(%{"threshold_mode" => "flat"}), now: @now)

      phrase = Gate.hold_phrase(q, policy(%{"threshold_mode" => "flat"}), now: @now)
      assert is_binary(phrase)
      assert phrase =~ "7d"
      refute phrase =~ "5h"
    end

    test "stale?/2 is false (no crash) for a nil primary, even with an old capture" do
      old = DateTime.add(@now, -86_400)
      refute Gate.stale?(long_only(), @now)
      refute Gate.stale?(long_only(captured_at: old), @now)
    end

    test "long_window_stale?/2 governs: stale-high-7d holds, stale-low allows" do
      old = DateTime.add(@now, -86_400)
      flat = policy(%{"threshold_mode" => "flat"})

      # High 7d, captured a day ago, reset still in the future: not stale, holds.
      high = long_only(utilization_7d: 0.97, captured_at: old)
      refute Gate.long_window_stale?(high, @now)
      assert %{window: "7d"} = Gate.gating_window(high, flat, now: @now)

      # The 7d window's own reset rolled: stale, so the hold lifts.
      rolled = long_only(utilization_7d: 0.97, reset_7d_at: DateTime.add(@now, -60))
      assert Gate.long_window_stale?(rolled, @now)
      assert Gate.gating_window(rolled, flat, now: @now) == nil

      # Low 7d never holds, however old.
      low = long_only(utilization_7d: 0.10, captured_at: old)
      assert Gate.gating_window(low, flat, now: @now) == nil
    end
  end

  describe "Headroom / Price (AC4)" do
    test "windows/3 returns only the 7d window; ranking is deterministic" do
      assert [%{window: "7d"}] = w = Headroom.windows(long_only(), policy(), now: @now)
      assert w == Headroom.windows(long_only(), policy(), now: @now)
      assert %{window: "7d"} = Headroom.binding(long_only(), policy(), now: @now)
    end

    test "a phantom 0.0 primary is not a headroom window" do
      q = long_only(utilization_5h: 0.0, status_5h: "allowed")
      assert [%{window: "7d"}] = Headroom.windows(q, policy(), now: @now)
    end

    test "Price.price/2 prices the 7d window alone" do
      [w7] = Headroom.windows(long_only(), policy(), now: @now)
      assert Price.price([w7]) == Price.window_price(w7.headroom)
      assert Price.price(Headroom.windows(long_only(), policy(), now: @now)) == Price.price([w7])
    end
  end

  describe "Budget (AC6)" do
    test "a 0.0 primary with nil reset creates no Budget window or binding" do
      q = long_only(utilization_5h: 0.0, status_5h: "allowed")

      b =
        Budget.compute(
          account: %ProviderAccount{
            provider: :claude,
            quota_config: %{"threshold_mode" => "paced"},
            max_concurrent: 3
          },
          pool: "claude",
          quota: q,
          now: @now,
          seats: 3,
          horizon: 2.0
        )

      assert Enum.map(b.windows, & &1.window) == ["7d"]
      refute b.binding == {:window, nil}
      refute b.binding == {:window, "5h"}
    end

    test "a nil primary creates no Budget window either" do
      b =
        Budget.compute(
          account: %ProviderAccount{provider: :claude, quota_config: %{}, max_concurrent: 3},
          pool: "claude",
          quota: long_only(),
          now: @now,
          seats: 3,
          horizon: 2.0
        )

      assert Enum.map(b.windows, & &1.window) == ["7d"]
    end
  end
end
