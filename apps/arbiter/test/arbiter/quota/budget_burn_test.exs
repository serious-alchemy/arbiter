defmodule Arbiter.Quota.BudgetBurnTest do
  @moduledoc """
  The Budget's `24h` window under `daily_burn_cap_mode: enforce` (bd-cklotu): its
  line is the cap, its draw the 7d window's `ρ`, and the P0 exemption leaves it
  out of the exempt budget. Hand-computed: h = 2, ρ = 0.01 per seat-hour.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-11-02 12:00:00Z]

  defp account(extra) do
    config = Map.merge(%{"weekly_threshold" => 0.90, "pace_exempt_priority" => 0}, extra)
    %ProviderAccount{provider: :claude, quota_config: config, max_concurrent: nil}
  end

  defp snapshot(overrides \\ %{}) do
    struct(
      %Snapshot{
        provider: "claude",
        captured_at: @now,
        capture_source: "oauth_poll",
        secondary_utilization: 0.30,
        secondary_status: "allowed",
        secondary_reset_at: DateTime.add(@now, 3 * 86_400, :second),
        secondary_window_label: "7d",
        burn_24h: 0.20,
        burn_24h_at: @now
      },
      overrides
    )
  end

  defp compute(account, quota, extra \\ []) do
    Budget.compute(
      Keyword.merge(
        [
          account: account,
          pool: "claude",
          quota: quota,
          now: @now,
          seats: 0,
          horizon: 2.0,
          rates: %{"7d" => %{rho: 0.01}}
        ],
        extra
      )
    )
  end

  defp window(budget, label), do: Enum.find(budget.windows, &(&1.window == label))

  @enforce %{"daily_burn_cap" => 0.25, "daily_burn_cap_mode" => "enforce"}

  test "enforce: the 24h entry binds with n = (cap - burn) / (rho * h)" do
    b = compute(account(@enforce), snapshot())

    w = window(b, "24h")
    assert w.status == :ok
    assert_in_delta w.used, 0.20, 1.0e-9
    assert_in_delta w.line_now, 0.25, 1.0e-9
    assert_in_delta w.rho, 0.01, 1.0e-9
    assert_in_delta w.n, 2.5, 1.0e-6

    assert b.quota_binding == "24h"
    assert b.budget == 2
    assert b.reason =~ "24h binds"
  end

  test "seats in flight draw down the 24h headroom at the 7d rho" do
    b =
      compute(account(@enforce), snapshot(%{captured_at: DateTime.add(@now, -3600, :second)}),
        seats: 2
      )

    # one hour of lag at 2 seats * 0.01 = 0.02 more burn: (0.25 - 0.22) / 0.02
    assert_in_delta window(b, "24h").n, 1.5, 1.0e-6
  end

  test "a burn over the cap gives a budget of 0" do
    b = compute(account(@enforce), snapshot(%{burn_24h: 0.30}))
    assert b.budget == 0
    assert b.quota_binding == "24h"
  end

  test "the P0 exemption leaves the 24h window out of the exempt budget" do
    b = compute(account(@enforce), snapshot(%{burn_24h: 0.30}))
    assert b.budget == 0
    assert b.exempt_budget > 0
  end

  test "shadow, no cap, an unmeasured or stale burn add no 24h window" do
    for {acct, quota} <- [
          {account(%{"daily_burn_cap" => 0.25}), snapshot()},
          {account(%{"daily_burn_cap_mode" => "enforce"}), snapshot()},
          {account(@enforce), snapshot(%{burn_24h: nil, burn_24h_at: nil})},
          {account(@enforce), snapshot(%{burn_24h_at: DateTime.add(@now, -7200, :second)})}
        ] do
      assert window(compute(acct, quota), "24h") == nil
    end
  end

  test "a workspace cap tightens the account's" do
    ws = %Workspace{id: "ws", config: %{"quota" => %{"daily_burn_cap" => 0.21}}}
    b = compute(account(@enforce), snapshot(), workspace: ws)
    assert_in_delta window(b, "24h").n, 0.5, 1.0e-6
    # raw 0.5 floors to 0, but an idle pool under every line still gets its first seat
    assert b.budget == 1
    assert b.first_seat?
  end
end
