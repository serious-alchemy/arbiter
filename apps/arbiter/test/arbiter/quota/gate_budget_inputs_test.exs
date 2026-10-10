defmodule Arbiter.Quota.GateBudgetInputsTest do
  @moduledoc """
  The two additions `Arbiter.Quota.Budget` (bd-6c8g4t, DC3) needs from the gate
  (design `provider-dynamic-concurrency.md` E1): the paced line of the *fresh*
  window after a reset, and the gate's status-only rules on their own. Both
  reuse the gate's own rules, so there is still one definition of the line.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  @now ~U[2026-10-10 04:10:00Z]
  @five_hours 18_000

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

  defp paced,
    do: %ProviderAccount{provider: :claude, quota_config: %{"threshold_mode" => "paced"}}

  describe "pace/6 with a what-if now:" do
    test "the line rises with the clock" do
      reset = DateTime.add(@now, 1800, :second)

      at_now = Gate.pace(paced(), :primary, "5h", 0.5, reset, now: @now)

      later =
        Gate.pace(paced(), :primary, "5h", 0.5, reset, now: DateTime.add(@now, 900, :second))

      assert_in_delta at_now.ceiling, 1 - 1800 / @five_hours, 1.0e-9
      assert_in_delta later.ceiling, 1 - 900 / @five_hours, 1.0e-9
    end
  end

  describe "fresh_pace/5" do
    test "is the next window's line: the floor right after the reset, then rising" do
      reset = DateTime.add(@now, 1800, :second)

      at_reset = Gate.fresh_pace(paced(), :primary, "5h", reset, now: reset)
      assert at_reset.ceiling == 0.35
      assert at_reset.verdict == :sampling

      # 4 hours into the fresh window: elapsed 0.8 beats the 0.35 floor.
      four_in =
        Gate.fresh_pace(paced(), :primary, "5h", reset,
          now: DateTime.add(reset, 4 * 3600, :second)
        )

      assert_in_delta four_in.ceiling, 0.8, 1.0e-9
    end

    test "reads used = 0, so the verdict never holds" do
      reset = DateTime.add(@now, 60, :second)
      assert Gate.fresh_pace(paced(), :primary, "5h", reset, now: reset).verdict != :holding
    end

    test "a flat side is flat in the fresh window too" do
      account = %ProviderAccount{provider: :claude, quota_config: %{"throttle_threshold" => 0.7}}
      reset = DateTime.add(@now, 60, :second)
      assert Gate.fresh_pace(account, :primary, "5h", reset, now: reset).ceiling == 0.7
    end

    test "a window with no length falls back to the flat side" do
      account = %ProviderAccount{
        provider: :codex,
        quota_config: %{"threshold_mode" => "paced", "throttle_threshold" => 0.6}
      }

      assert Gate.fresh_pace(account, :primary, "session", @now, now: @now).ceiling == 0.6
    end
  end

  describe "hard_stop/3" do
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

    test "nil when the provider is accepting" do
      assert Gate.hard_stop(snapshot([]), paced(), now: @now) == nil
    end

    test "a past-plan primary status is a stop" do
      assert %{signal: :status, window: "5h"} =
               Gate.hard_stop(snapshot(status: "rejected"), paced(), now: @now)
    end

    test "a rejected long window is a stop" do
      assert %{signal: :status, window: "7d"} =
               Gate.hard_stop(snapshot(secondary_status: "rejected"), paced(), now: @now)
    end

    test "allowed_warning stops only under weekly_warning_policy: hold" do
      snap = snapshot(secondary_status: "allowed_warning")
      assert Gate.hard_stop(snap, paced(), now: @now) == nil

      hold = %ProviderAccount{
        provider: :claude,
        quota_config: %{"threshold_mode" => "paced", "weekly_warning_policy" => "hold"}
      }

      assert %{signal: :warning} = Gate.hard_stop(snap, hold, now: @now)
    end

    test "utilization past the line is not a hard stop" do
      assert Gate.hard_stop(snapshot(utilization: 0.99), paced(), now: @now) == nil
    end

    test "a stale primary window drops its status rule, as the gate does" do
      stale = snapshot(status: "rejected", reset_at: DateTime.add(@now, -60, :second))
      assert Gate.hard_stop(stale, paced(), now: @now) == nil
    end

    test "nil quota is no stop" do
      assert Gate.hard_stop(nil, paced(), now: @now) == nil
    end
  end
end
