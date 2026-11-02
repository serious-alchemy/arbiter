defmodule Arbiter.Quota.PolicyFieldsCurveTest do
  @moduledoc """
  `arb quota` / `quota_get` print `Quota.policy_fields/2`'s `effective` block —
  the ceiling in force right now. Under `pace_curve: "ramp"` (bd-bq0gi8) that
  is the ramp line, read off the account's own latest snapshot's reset times.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota
  alias Arbiter.Quota.AnthropicQuota

  @five_hours 18_000
  @seven_days 604_800

  defp account!(config) do
    Ash.create!(ProviderAccount, %{
      provider: :claude,
      slug: "curve-#{System.unique_integer([:positive])}",
      quota_config: config
    })
  end

  defp snapshot!(account) do
    now = DateTime.utc_now()

    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: 0.1,
      reset_5h_at: DateTime.add(now, div(@five_hours, 2), :second),
      status_5h: "allowed",
      utilization_7d: 0.1,
      reset_7d_at: DateTime.add(now, div(@seven_days, 2), :second),
      status_7d: "allowed",
      captured_at: now,
      capture_source: "oauth_poll"
    })
  end

  @paced %{"threshold_mode" => "paced", "paced_floor" => 0.1, "weekly_paced_floor" => 0.1}

  test "effective ceilings follow the ramp at half-elapsed windows" do
    account = account!(Map.put(@paced, "pace_curve", "ramp"))
    snapshot!(account)

    assert %{effective: %{throttle_threshold: t5, weekly_threshold: t7}} =
             Quota.policy_fields(account, nil)

    assert_in_delta t5, 0.55, 0.01
    assert_in_delta t7, 0.55, 0.01
  end

  test "the same account on the default curve reads max(floor, elapsed)" do
    account = account!(@paced)
    snapshot!(account)

    assert %{effective: %{throttle_threshold: t5}} = Quota.policy_fields(account, nil)
    assert_in_delta t5, 0.50, 0.01
  end

  test "account_policy carries the curve" do
    account = account!(%{"pace_curve" => "ramp"})
    assert %{account_policy: %{pace_curve: "ramp"}} = Quota.policy_fields(account, nil)
  end
end
