defmodule Arbiter.Quota.GatePaceOffTest do
  @moduledoc """
  `pace: false` (DC8, design `provider-dynamic-concurrency.md` §4.5, E9, E10):
  under `scheduler_admission: enforce` the quota gate keeps only its hard rules
  for every dispatch — the primary window past plan (rule 1), the long window
  rejected (rule 2) and `allowed_warning` under `weekly_warning_policy: hold`
  (rule 5). The paced line (rules 3 and 4) is the budget's question, answered by
  the seat check. Without the option the gate is exactly what it was.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Gate.Throttle

  @now ~U[2026-10-10 04:10:00Z]

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.drop(prior, [:throttle_threshold, :weekly_threshold, :weekly_warning_policy, :gate])
    )

    :ok
  end

  defp paced(extra \\ %{}),
    do: %ProviderAccount{
      provider: :claude,
      slug: "default",
      quota_config: Map.merge(%{"threshold_mode" => "paced"}, extra)
    }

  defp snapshot(overrides) do
    struct!(
      %Snapshot{
        provider: "claude",
        utilization: 0.1,
        status: "allowed",
        reset_at: DateTime.add(@now, 3600, :second),
        captured_at: @now,
        window_label: "5h",
        secondary_utilization: 0.1,
        secondary_status: "allowed",
        secondary_reset_at: DateTime.add(@now, 86_400, :second),
        secondary_window_label: "7d"
      },
      overrides
    )
  end

  describe "gating_window/3" do
    test "a window past its paced line holds by default, and not with pace: false" do
      ahead = snapshot(utilization: 0.95)

      assert %{signal: :utilization, window: "5h"} =
               Gate.gating_window(ahead, paced(), now: @now)

      assert Gate.gating_window(ahead, paced(), now: @now, pace: false) == nil
    end

    test "a long window past its line is not a hard rule either" do
      ahead = snapshot(secondary_utilization: 0.99)

      assert %{signal: :utilization, window: "7d"} =
               Gate.gating_window(ahead, paced(), now: @now)

      assert Gate.gating_window(ahead, paced(), now: @now, pace: false) == nil
    end

    test "a flat ceiling is pace too: pace: false skips it" do
      flat = %ProviderAccount{provider: :claude, quota_config: %{"throttle_threshold" => 0.5}}
      over = snapshot(utilization: 0.6)

      assert %{signal: :utilization} = Gate.gating_window(over, flat, now: @now)
      assert Gate.gating_window(over, flat, now: @now, pace: false) == nil
    end

    test "the hard rules still hold with pace: false" do
      assert %{signal: :status, window: "5h"} =
               Gate.gating_window(snapshot(status: "rejected"), paced(),
                 now: @now,
                 pace: false
               )

      assert %{signal: :status, window: "7d"} =
               Gate.gating_window(snapshot(secondary_status: "rejected"), paced(),
                 now: @now,
                 pace: false
               )

      warned = snapshot(secondary_status: "allowed_warning")
      hold = paced(%{"weekly_warning_policy" => "hold"})

      assert %{signal: :warning} = Gate.gating_window(warned, hold, now: @now, pace: false)
    end

    test "pace: false agrees with hard_stop/3 on every rule" do
      for overrides <- [
            [],
            [utilization: 0.99],
            [status: "rejected"],
            [secondary_status: "rejected"],
            [secondary_status: "allowed_warning"],
            [status: "rejected", reset_at: DateTime.add(@now, -60, :second)]
          ],
          policy <- [paced(), paced(%{"weekly_warning_policy" => "hold"})] do
        snap = snapshot(overrides)

        assert Gate.gating_window(snap, policy, now: @now, pace: false) ==
                 Gate.hard_stop(snap, policy, now: @now),
               "differs for #{inspect(overrides)}"
      end
    end

    test "pace: true is the default" do
      ahead = snapshot(utilization: 0.95)

      assert Gate.gating_window(ahead, paced(), now: @now, pace: true) ==
               Gate.gating_window(ahead, paced(), now: @now)
    end
  end

  describe "Throttle.check/4" do
    test "holds a dispatch past the line by default, allows it with pace: false" do
      ahead = snapshot(utilization: 0.95)

      assert {:hold, %{signal: :utilization}} =
               Throttle.check(nil, ahead, nil, account: paced(), now: @now)

      assert Throttle.check(nil, ahead, nil, account: paced(), now: @now, pace: false) == :allow
    end

    test "still holds on a hard rule with pace: false, phrased as today" do
      assert {:hold, %{signal: :status, phrase: phrase}} =
               Throttle.check(nil, snapshot(status: "rejected"), nil,
                 account: paced(),
                 now: @now,
                 pace: false
               )

      assert phrase =~ "quota exhausted"
    end
  end

  test "hold_phrase/3 with pace: false names only a hard rule" do
    ahead = snapshot(utilization: 0.95)
    assert is_binary(Gate.hold_phrase(ahead, paced(), now: @now))
    assert Gate.hold_phrase(ahead, paced(), now: @now, pace: false) == nil
  end
end
