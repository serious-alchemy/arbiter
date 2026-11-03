defmodule Arbiter.Quota.ScopedGateTest do
  @moduledoc """
  bd-e0b7so AC3, AC8: the gate evaluates a scoped window with the `weekly_*`
  keys and the account's `pace_curve`, holds only a card on the scoped model,
  and names the window in the hold reason. `Headroom` prices the same windows.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Headroom

  @now ~U[2026-11-02 12:00:00Z]
  @week 604_800
  @fable "claude-fable-5-1"
  @opus "claude-opus-5-5"

  defp reset(elapsed), do: DateTime.add(@now, round((1 - elapsed) * @week), :second)

  defp account(extra \\ %{}),
    do: %ProviderAccount{
      provider: :claude,
      slug: "default",
      quota_config: Map.merge(%{"threshold_mode" => "paced"}, extra)
    }

  defp fable(util, opts \\ []) do
    %{
      scope: "Fable",
      label: "7d (Fable)",
      utilization: util,
      status: Keyword.get(opts, :status, "allowed"),
      reset_at: Keyword.get(opts, :reset_at, reset(0.5)),
      active?: Keyword.get(opts, :active, false)
    }
  end

  defp snap(scoped, base_util \\ 0.10) do
    %Snapshot{
      provider: "claude",
      captured_at: @now,
      capture_source: "oauth_poll",
      window_label: nil,
      secondary_utilization: base_util,
      secondary_status: "allowed",
      secondary_reset_at: reset(0.5),
      secondary_window_label: "7d",
      scoped: scoped
    }
  end

  defp window(snapshot, model, policy \\ account()),
    do: Gate.gating_window(snapshot, policy, model: model, now: @now)

  describe "window length of a scoped label" do
    test "\"7d (Fable)\" is a 7d window, so the paced line resolves" do
      assert Gate.window_seconds("7d (Fable)") == @week
      assert Gate.window_seconds("7d") == @week
      assert Gate.window_seconds("nonsense (Fable)") == nil
    end
  end

  describe "gating_window/3 (AC3)" do
    test "a card on the scoped model is held past the scoped line; another model is not" do
      s = snap([fable(0.90)])

      assert %{window: "7d (Fable)", signal: :utilization, utilization: 0.9} = window(s, @fable)
      assert window(s, @opus) == nil
      assert window(s, :unscoped) == nil
    end

    test "a nil model reads the worst of all" do
      assert %{window: "7d (Fable)"} = window(snap([fable(0.90)]), nil)
    end

    test "a rejected scoped window is a status hold on that model only" do
      s = snap([fable(1.0, status: "rejected")])

      assert %{window: "7d (Fable)", signal: :status, status: "rejected"} = window(s, @fable)
      assert window(s, @opus) == nil
    end

    test "the base 7d window still binds every model, and is named first" do
      s = snap([fable(0.90)], 0.95)

      assert %{window: "7d"} = window(s, @fable)
      assert %{window: "7d"} = window(s, @opus)
    end

    test "the scoped window follows the account's pace_curve (plateau vs ramp)" do
      s = snap([fable(0.55)])

      # elapsed 0.5, floor 0.20: plateau line max(0.20, 0.5) = 0.5, ramp 0.2 + 0.8 * 0.5 = 0.6
      assert %{window: "7d (Fable)", mode: :paced} = window(s, @fable, account())

      assert window(s, @fable, account(%{"pace_curve" => "ramp"})) == nil

      assert %{window: "7d (Fable)"} =
               window(snap([fable(0.65)]), @fable, account(%{"pace_curve" => "ramp"}))
    end

    test "the scoped window follows weekly_paced_floor" do
      s = snap([fable(0.65)])
      assert window(s, @fable, account(%{"weekly_paced_floor" => 0.9})) == nil
    end

    test "a scoped window whose own reset has passed is not trusted" do
      s = snap([fable(0.99, reset_at: DateTime.add(@now, -3600, :second))])
      assert window(s, @fable) == nil
    end

    test "a snapshot with no scoped windows is unchanged" do
      s = snap([], 0.90)
      assert %{window: "7d"} = window(s, @fable)
      assert %{window: "7d"} = window(s, nil)
      assert window(snap([], 0.10), @fable) == nil
    end

    test "an unmatched active scope gates every model (account-level)" do
      mythos = %{fable(0.99) | scope: "Mythos", label: "7d (Mythos)", active?: true}
      s = snap([mythos])

      for model <- [@fable, @opus, :unscoped, nil] do
        assert %{window: "7d (Mythos)"} = window(s, model)
      end
    end

    test "an unmatched inactive scope gates nothing" do
      mythos = %{fable(0.99) | scope: "Mythos", label: "7d (Mythos)"}
      for model <- [@fable, nil], do: assert(window(snap([mythos]), model) == nil)
    end
  end

  describe "hold reasons name the scoped window (AC8)" do
    test "utilization hold" do
      phrase = Gate.hold_phrase(snap([fable(0.90)]), account(), model: @fable, now: @now)
      assert phrase =~ "7d (Fable)"
      assert phrase =~ "paced"
    end

    test "status hold" do
      s = snap([fable(1.0, status: "rejected")])
      assert Gate.hold_phrase(s, account(), model: @fable, now: @now) =~ "7d (Fable)"
    end
  end

  describe "hard_stop/3 and pace: false" do
    test "a rejected scoped window is a hard stop for its model only" do
      s = snap([fable(1.0, status: "rejected")])

      assert %{window: "7d (Fable)", signal: :status} =
               Gate.hard_stop(s, account(), model: @fable, now: @now)

      assert Gate.hard_stop(s, account(), model: @opus, now: @now) == nil

      assert %{window: "7d (Fable)"} =
               Gate.gating_window(s, account(), model: @fable, now: @now, pace: false)
    end

    test "a scoped allowed_warning holds under weekly_warning_policy: hold" do
      s = snap([fable(0.30, status: "allowed_warning")])
      policy = account(%{"weekly_warning_policy" => "hold"})

      assert %{window: "7d (Fable)", signal: :warning} =
               Gate.hard_stop(s, policy, model: @fable, now: @now)

      assert Gate.hard_stop(s, policy, model: @opus, now: @now) == nil
    end
  end

  describe "Headroom (AC3)" do
    test "windows/3 lists the scoped window for its model only" do
      s = snap([fable(0.40)])

      assert [%{window: "7d"}, %{window: "7d (Fable)", used: 0.4}] =
               Headroom.windows(s, account(), model: @fable, now: @now)

      assert [%{window: "7d"}] = Headroom.windows(s, account(), model: @opus, now: @now)
    end

    test "binding/3 is the tighter of the base and the scoped window" do
      s = snap([fable(0.40)], 0.10)
      assert %{window: "7d (Fable)"} = Headroom.binding(s, account(), model: @fable, now: @now)
      assert %{window: "7d"} = Headroom.binding(s, account(), model: @opus, now: @now)
    end
  end

  describe "pace_exemption/3" do
    test "an exempt dispatch past the scoped paced line reports the scoped window" do
      policy =
        account(%{
          "pace_exempt_priority" => 0,
          "weekly_threshold" => 0.99,
          "weekly_pace_exempt_threshold" => 0.9
        })

      s = snap([fable(0.80)])

      assert %{window: "7d (Fable)"} =
               Gate.pace_exemption(s, policy, model: @fable, now: @now, priority: 0)

      assert Gate.pace_exemption(s, policy, model: @opus, now: @now, priority: 0) == nil
    end
  end
end
