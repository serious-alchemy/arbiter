defmodule Arbiter.Quota.BurnGovernorTest do
  @moduledoc """
  The rolling-24h burn governor (bd-cklotu): `daily_burn_cap` + `daily_burn_cap_mode`
  composed `min(account, workspace)`, the Gate's flat rule under `enforce`, the
  P0 pace exemption, and `shadow` never holding.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.BurnGovernor
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-11-02 12:00:00Z]

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
  defp ws(quota), do: %Workspace{id: "ws-burn", config: %{"quota" => quota}}

  defp snap(attrs \\ %{}) do
    struct(
      %Snapshot{
        provider: "claude",
        captured_at: @now,
        secondary_utilization: 0.30,
        secondary_status: "allowed",
        secondary_reset_at: DateTime.add(@now, 3 * 86_400, :second),
        secondary_window_label: "7d",
        burn_24h: 0.30,
        burn_24h_at: @now
      },
      attrs
    )
  end

  defp gate(quota, policy, opts \\ []),
    do: Gate.gating_window(quota, policy, Keyword.merge([now: @now], opts))

  describe "cap/1 and mode/1" do
    test "off by default" do
      assert BurnGovernor.cap({account(%{}), nil}) == nil
      assert BurnGovernor.mode({account(%{}), nil}) == :shadow
    end

    test "min(account, workspace) cap; enforce if either side enforces" do
      acct = account(%{"daily_burn_cap" => 0.25, "daily_burn_cap_mode" => "shadow"})
      assert BurnGovernor.cap({acct, nil}) == 0.25
      assert BurnGovernor.cap({acct, ws(%{"daily_burn_cap" => 0.15})}) == 0.15
      assert BurnGovernor.cap({acct, ws(%{"daily_burn_cap" => 0.40})}) == 0.25
      assert BurnGovernor.cap({nil, ws(%{"daily_burn_cap" => "0.2"})}) == 0.2

      assert BurnGovernor.mode({acct, nil}) == :shadow
      assert BurnGovernor.mode({acct, ws(%{"daily_burn_cap_mode" => "enforce"})}) == :enforce

      assert BurnGovernor.mode({account(%{"daily_burn_cap_mode" => "enforce"}), nil}) ==
               :enforce

      assert BurnGovernor.mode({acct, ws(%{"daily_burn_cap_mode" => "bogus"})}) == :shadow
    end
  end

  describe "the Gate rule" do
    @enforce %{"daily_burn_cap" => 0.25, "daily_burn_cap_mode" => "enforce"}

    test "enforce holds a 7d window whose 24h burn reaches the cap" do
      assert %{window: "24h", signal: :burn, utilization: 0.30, threshold: 0.25} =
               gate(snap(), {account(@enforce), nil})
    end

    test "under the cap does not hold" do
      assert gate(snap(%{burn_24h: 0.24}), {account(@enforce), nil}) == nil
    end

    test "shadow never holds" do
      acct = account(%{"daily_burn_cap" => 0.25})
      assert gate(snap(), {acct, nil}) == nil
    end

    test "no cap, no hold" do
      assert gate(snap(), {account(%{"daily_burn_cap_mode" => "enforce"}), nil}) == nil
    end

    test "a nil or stale burn reading never holds" do
      acct = account(@enforce)
      assert gate(snap(%{burn_24h: nil, burn_24h_at: nil}), {acct, nil}) == nil
      stale = DateTime.add(@now, -3 * 3600, :second)
      assert gate(snap(%{burn_24h_at: stale}), {acct, nil}) == nil
    end

    test "a workspace can tighten the account's cap" do
      acct = account(@enforce)
      assert gate(snap(%{burn_24h: 0.20}), {acct, nil}) == nil

      assert %{signal: :burn, threshold: 0.15} =
               gate(snap(%{burn_24h: 0.20}), {acct, ws(%{"daily_burn_cap" => 0.15})})
    end

    test "the P0 pace exemption lifts it, other priorities are held" do
      acct = account(Map.put(@enforce, "pace_exempt_priority", 0))
      assert gate(snap(), {acct, nil}, priority: 0) == nil
      assert %{signal: :burn} = gate(snap(), {acct, nil}, priority: 1)
      assert %{signal: :burn} = gate(snap(), {acct, nil}, priority: nil)
    end

    test "pace: false (admission enforce) leaves it to the budget" do
      assert gate(snap(), {account(@enforce), nil}, pace: false) == nil
    end

    test "an exhausted 7d window still reports its own, more severe, rule first" do
      quota = snap(%{secondary_status: "rejected"})
      assert %{window: "7d", signal: :status} = gate(quota, {account(@enforce), nil})
    end

    test "hold_phrase says what held" do
      phrase = Gate.hold_phrase(snap(), {account(@enforce), nil}, now: @now)
      assert phrase =~ "24h burn 30% ≥ cap 25%"
    end
  end

  describe "would_hold/4 (shadow)" do
    test "reports the hold that enforce would make, and only in shadow with a reading" do
      acct = account(%{"daily_burn_cap" => 0.25})

      assert %{burn: 0.30, cap: 0.25, mode: :shadow} =
               BurnGovernor.would_hold(snap(), {acct, nil}, @now, nil)

      assert BurnGovernor.would_hold(snap(%{burn_24h: 0.1}), {acct, nil}, @now, nil) == nil

      assert BurnGovernor.would_hold(
               snap(),
               {account(%{"daily_burn_cap" => 0.25, "daily_burn_cap_mode" => "enforce"}), nil},
               @now,
               nil
             ) == nil
    end
  end
end
