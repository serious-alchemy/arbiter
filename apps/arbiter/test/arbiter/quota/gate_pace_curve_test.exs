defmodule Arbiter.Quota.GatePaceCurveTest do
  @moduledoc """
  The `pace_curve` setting (bd-bq0gi8, operator ruling 2026-11-02): `"ramp"`
  draws the paced line as `floor + (1 - floor) * elapsed`; unset, or anything
  unrecognised, keeps the existing `max(floor, elapsed)` (`"plateau"`). The
  gate resolves it per side, so `min(account, workspace)` compares each side's
  own curve at the moment of the check. Every test pins `opts[:now]`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-11-02 12:00:00Z]
  @five_hours 18_000
  @seven_days 604_800

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

  defp account(config), do: %ProviderAccount{provider: :claude, quota_config: config}
  defp ws(quota), do: %Workspace{id: "ws-curve", config: %{"quota" => quota}}

  defp paced(extra),
    do: account(Map.merge(%{"threshold_mode" => "paced"}, extra))

  defp reset_after(elapsed, seconds),
    do: DateTime.add(@now, round((1 - elapsed) * seconds), :second)

  defp ceiling(policy, window, elapsed, opts \\ []) do
    {label, seconds} = if window == :primary, do: {"5h", @five_hours}, else: {"7d", @seven_days}
    Gate.pace(policy, window, label, 0.0, reset_after(elapsed, seconds), [now: @now] ++ opts)
  end

  defp snap(attrs) do
    struct(
      %Snapshot{
        provider: "claude",
        utilization: 0.01,
        status: "allowed",
        reset_at: reset_after(0.5, @five_hours),
        captured_at: @now,
        window_label: "5h",
        secondary_utilization: 0.01,
        secondary_status: "allowed",
        secondary_reset_at: reset_after(0.5, @seven_days),
        secondary_window_label: "7d"
      },
      attrs
    )
  end

  describe "pace_curve resolution" do
    test "unset is the plateau: max(floor, elapsed), on both windows" do
      acct = paced(%{"paced_floor" => 0.1, "weekly_paced_floor" => 0.1})
      assert_in_delta ceiling({acct, nil}, :primary, 0.05).ceiling, 0.1, 1.0e-6
      assert_in_delta ceiling({acct, nil}, :long, 0.05).ceiling, 0.1, 1.0e-6
      assert_in_delta ceiling({acct, nil}, :long, 0.5).ceiling, 0.5, 1.0e-6
    end

    test "ramp: floor + (1 - floor) * elapsed on the primary and the long window" do
      acct = paced(%{"pace_curve" => "ramp", "paced_floor" => 0.1, "weekly_paced_floor" => 0.1})

      for {e, line} <- [{0.0, 0.1}, {0.2, 0.28}, {0.5, 0.55}, {1.0, 1.0}] do
        assert_in_delta ceiling({acct, nil}, :primary, e).ceiling, line, 1.0e-6
        assert_in_delta ceiling({acct, nil}, :long, e).ceiling, line, 1.0e-6
      end
    end

    test "an unrecognised value in a stored quota_config reads as the plateau" do
      for bad <- ["linear", "RAMP", 1, nil, %{}] do
        acct = paced(%{"pace_curve" => bad, "weekly_paced_floor" => 0.1})
        assert_in_delta ceiling({acct, nil}, :long, 0.05).ceiling, 0.1, 1.0e-6
        assert_in_delta ceiling({acct, nil}, :long, 0.5).ceiling, 0.5, 1.0e-6
      end
    end

    test "an explicit \"plateau\" is the existing behaviour" do
      acct = paced(%{"pace_curve" => "plateau", "weekly_paced_floor" => 0.1})
      assert_in_delta ceiling({acct, nil}, :long, 0.05).ceiling, 0.1, 1.0e-6
    end

    test "flat mode is untouched by the curve" do
      acct = account(%{"pace_curve" => "ramp", "weekly_threshold" => 0.7})
      assert %{ceiling: 0.7, mode: :flat} = ceiling({acct, nil}, :long, 0.5)
    end

    test "a window with no known length or reset falls back to flat under either curve" do
      for curve <- ["ramp", "plateau"] do
        acct = paced(%{"pace_curve" => curve, "weekly_threshold" => 0.66})

        assert %{ceiling: 0.66, mode: :flat} =
                 Gate.pace({acct, nil}, :long, "7d", 0.0, nil, now: @now)

        # an unknown window label has no length either
        assert %{ceiling: 0.66, mode: :flat} =
                 Gate.pace({acct, nil}, :long, "session", 0.0, reset_after(0.5, 100), now: @now)
      end
    end

    test "a workspace in paced mode carries its own pace_curve" do
      w = ws(%{"threshold_mode" => "paced", "weekly_paced_floor" => 0.1, "pace_curve" => "ramp"})
      assert_in_delta ceiling({nil, w}, :long, 0.5).ceiling, 0.55, 1.0e-6
    end

    test "paced_policy/1 keeps the account's curve, so the bars draw the line the gate would use" do
      acct = account(%{"pace_curve" => "ramp", "weekly_paced_floor" => 0.1})
      policy = Gate.paced_policy({acct, nil})
      assert_in_delta ceiling(policy, :long, 0.5).ceiling, 0.55, 1.0e-6
    end
  end

  describe "min(account, workspace) with mixed curves" do
    # account: plateau, floor 0.35; workspace: ramp, floor 0.10. The lower one
    # at the moment of the check binds; which one that is changes through the window.
    @acct %{"weekly_paced_floor" => 0.35}
    @wsq %{"threshold_mode" => "paced", "weekly_paced_floor" => 0.1, "pace_curve" => "ramp"}

    test "early in the window the ramp binds, late in the window the plateau does" do
      policy = {paced(@acct), ws(@wsq)}

      # elapsed 0.1: plateau 0.35 vs ramp 0.19
      assert_in_delta ceiling(policy, :long, 0.1).ceiling, 0.19, 1.0e-6
      # elapsed 0.9: plateau 0.90 vs ramp 0.91
      assert_in_delta ceiling(policy, :long, 0.9).ceiling, 0.9, 1.0e-6
    end

    test "the gate holds at the lower side's number" do
      policy = {paced(@acct), ws(@wsq)}

      early =
        snap(%{secondary_utilization: 0.2, secondary_reset_at: reset_after(0.1, @seven_days)})

      assert %{window: "7d", signal: :utilization} = Gate.gating_window(early, policy, now: @now)

      late =
        snap(%{secondary_utilization: 0.905, secondary_reset_at: reset_after(0.9, @seven_days)})

      assert %{window: "7d", signal: :utilization} = Gate.gating_window(late, policy, now: @now)

      allowed =
        snap(%{secondary_utilization: 0.18, secondary_reset_at: reset_after(0.1, @seven_days)})

      assert nil == Gate.gating_window(allowed, policy, now: @now)
    end

    test "binding_side/3 and effective_threshold/3 compare each side's own curve" do
      policy = {paced(@acct), ws(@wsq)}

      assert :workspace = Gate.binding_side(policy, :weekly_threshold, elapsed: 0.1)
      assert :account = Gate.binding_side(policy, :weekly_threshold, elapsed: 0.9)

      assert_in_delta Gate.effective_threshold(policy, :weekly_threshold, elapsed: 0.1),
                      0.19,
                      1.0e-6

      assert_in_delta Gate.effective_threshold(policy, :weekly_threshold, elapsed: 0.9),
                      0.9,
                      1.0e-6
    end
  end

  describe "the P0 exemption on a ramp" do
    # exempt ceiling = max(ramp line, min(exempt_cap, flat))
    @exempt %{
      "pace_curve" => "ramp",
      "weekly_paced_floor" => 0.1,
      "pace_exempt_priority" => 0,
      "weekly_pace_exempt_threshold" => 0.7,
      "weekly_threshold" => 0.99
    }

    test "the cap lifts a ramp line below it, reported as :exempt" do
      # ramp line at 0.5 is 0.55 < cap 0.7
      assert %{ceiling: 0.7, mode: :exempt} =
               ceiling({paced(@exempt), nil}, :long, 0.5, priority: 0)

      assert_in_delta ceiling({paced(@exempt), nil}, :long, 0.5, priority: 2).ceiling,
                      0.55,
                      1.0e-6
    end

    test "never lowers the ramp line: once the line is above the cap it stays, as :paced" do
      # ramp line at 0.8 is 0.82 > cap 0.7
      assert %{ceiling: c, mode: :paced} = ceiling({paced(@exempt), nil}, :long, 0.8, priority: 0)
      assert_in_delta c, 0.82, 1.0e-6
    end

    test "a cap between the plateau line and the ramp line only lifts the plateau" do
      cap = %{"weekly_pace_exempt_threshold" => 0.52}

      ramp = paced(Map.merge(@exempt, cap))
      plateau = paced(Map.merge(@exempt, Map.put(cap, "pace_curve", "plateau")))

      assert %{mode: :paced} = ceiling({ramp, nil}, :long, 0.5, priority: 0)
      assert %{ceiling: 0.52, mode: :exempt} = ceiling({plateau, nil}, :long, 0.5, priority: 0)
    end

    test "the cap is still bounded by the flat ceiling" do
      acct = paced(%{@exempt | "weekly_threshold" => 0.6})
      assert %{ceiling: 0.6, mode: :exempt} = ceiling({acct, nil}, :long, 0.5, priority: 0)
    end
  end

  describe "the spend side" do
    test "is unchanged by pace_curve: cap x elapsed, floor 0" do
      for curve <- [nil, "ramp", "plateau"] do
        extra = if curve, do: %{"pace_curve" => curve}, else: %{}
        acct = account(Map.merge(%{"spend_mode" => "paced"}, extra))

        for e <- [0.0, 0.25, 0.5, 1.0] do
          reset = reset_after(e, @seven_days)

          result =
            Gate.pace({acct, nil}, :spend, "7d", 0.0, reset,
              now: @now,
              window_seconds: @seven_days
            )

          assert_in_delta result.ceiling, e, 1.0e-6
          assert result.mode == :paced
        end
      end
    end
  end

  describe "account_policy_summary/1" do
    test "reports the curve only when one is set; an unset or unrecognised one adds no key" do
      refute Map.has_key?(Gate.account_policy_summary(account(%{})), :pace_curve)

      assert %{pace_curve: "ramp"} =
               Gate.account_policy_summary(account(%{"pace_curve" => "ramp"}))

      refute Map.has_key?(
               Gate.account_policy_summary(account(%{"pace_curve" => "x"})),
               :pace_curve
             )
    end
  end
end
