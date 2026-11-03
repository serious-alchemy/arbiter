defmodule Arbiter.Quota.ScopedBudgetTest do
  @moduledoc """
  bd-e0b7so AC3, AC7, AC8 through `Budget.compute/1`: a scoped weekly window
  is an extra long window of the `claude` pool, sized with the `weekly_*` keys
  and the account's `pace_curve`. A card on the scoped model is held while the
  same account serves other models, and the first-seat rule includes the
  card's scoped window in "below the line on every trusted window".
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Gate.Snapshot

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
      active?: false
    }
  end

  defp snapshot(scoped, base_util \\ 0.10) do
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

  defp compute(snapshot, model, overrides \\ []) do
    [
      account: account(),
      pool: "claude",
      quota: snapshot,
      model: model,
      now: @now,
      seats: 0,
      horizon: 2.0,
      rates: %{"7d" => %{rho: 0.2}}
    ]
    |> Keyword.merge(overrides)
    |> Budget.compute()
  end

  describe "two predicted models on one account (AC3)" do
    test "the card on the scoped model is held while the other model is served" do
      s = snapshot([fable(0.80)])

      fable_budget = compute(s, @fable, seats: 1)
      opus_budget = compute(s, @opus, seats: 1)

      assert fable_budget.budget == 0
      assert fable_budget.quota_binding == "7d (Fable)"
      assert fable_budget.binding == {:window, "7d (Fable)"}
      assert opus_budget.budget >= 1
      assert opus_budget.quota_binding == "7d"
    end

    test "both models share the one claude pool and the same seats" do
      s = snapshot([fable(0.80)])
      assert compute(s, @fable, seats: 2).pool == "claude"
      assert compute(s, @opus, seats: 2).seats == 2
      assert compute(s, @fable, seats: 2).seats == 2
    end

    test "the scoped window is listed beside the base one, evaluated like it" do
      b = compute(snapshot([fable(0.30)]), @fable, seats: 1)

      assert ["7d", "7d (Fable)"] = Enum.map(b.windows, & &1.window)
      assert Enum.all?(b.windows, &(&1.side == :long and &1.status == :ok))
      [base, scoped] = b.windows
      assert_in_delta base.line_now, scoped.line_now, 1.0e-9
      assert scoped.rho == base.rho
    end

    test "the scoped window follows the account's pace_curve" do
      s = snapshot([fable(0.55)])

      # elapsed 0.5, floor 0.20: plateau line 0.5, ramp 0.6
      plateau = compute(s, @fable, seats: 1)
      ramp = compute(s, @fable, seats: 1, account: account(%{"pace_curve" => "ramp"}))

      line = fn b ->
        b.windows |> Enum.find(&(&1.window == "7d (Fable)")) |> Map.fetch!(:line_now)
      end

      assert plateau.budget == 0
      assert line.(plateau) < 0.55
      assert line.(ramp) > 0.55
      assert ramp.raw > plateau.raw
    end

    test "a nil model is the worst of all" do
      b = compute(snapshot([fable(0.80)]), nil, seats: 1)
      assert b.budget == 0
      assert b.quota_binding == "7d (Fable)"
    end

    test "a rejected scoped window is a hard zero for its model only" do
      s = snapshot([fable(1.0, status: "rejected")])

      assert %{budget: 0, binding: :provider_refusing} = fable = compute(s, @fable, seats: 1)
      assert fable.reason =~ "7d (Fable) rejected"
      assert compute(s, @opus, seats: 1).budget >= 1
    end
  end

  describe "the first-seat rule (AC7)" do
    test "an idle account gets a seat on another model while the scoped window is at its line" do
      s = snapshot([fable(0.80)])

      other = compute(s, @opus)
      assert other.first_seat? or other.raw >= 1
      assert other.budget >= 1

      scoped = compute(s, @fable)
      refute scoped.first_seat?
      assert scoped.budget == 0
    end

    test "the rule admits the scoped model too once its window is below the line" do
      scoped = compute(snapshot([fable(0.20)]), @fable, background: 1.0)
      assert scoped.first_seat?
      assert scoped.budget == 1
      assert scoped.reason =~ "first-seat rule"
    end

    test "a scoped window exactly at its line is not below it" do
      b = compute(snapshot([fable(0.50)]), @fable, background: 1.0)
      refute b.first_seat?
      assert b.budget == 0
    end
  end

  describe "hold reasons (AC8)" do
    test "the reason names the scoped window" do
      b = compute(snapshot([fable(0.80)]), @fable, seats: 1)
      assert b.reason =~ "7d (Fable) binds"
    end

    test "the reason of another model names the base window" do
      b = compute(snapshot([fable(0.80)], 0.30), @opus, seats: 1)
      assert b.reason =~ "7d binds"
      refute b.reason =~ "Fable"
    end
  end

  describe "no scoped limits (AC6)" do
    test "the budget is the same with and without a model, and with an empty scoped list" do
      s = snapshot([], 0.30)
      expected = compute(s, nil, seats: 1)

      for model <- [@fable, @opus, :unscoped] do
        b = compute(s, model, seats: 1)
        assert b.budget == expected.budget
        assert b.raw == expected.raw
        assert Enum.map(b.windows, & &1.window) == ["7d"]
      end
    end
  end
end
