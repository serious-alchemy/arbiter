defmodule Arbiter.Quota.PolicyFieldsBurnTest do
  @moduledoc "The burn governor in the account policy `arb quota` / `quota_get` show (bd-cklotu)."
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota
  alias Arbiter.Quota.AnthropicQuota

  defp account!(config) do
    Ash.create!(ProviderAccount, %{
      provider: :claude,
      slug: "burn-#{System.unique_integer([:positive])}",
      quota_config: config
    })
  end

  test "an account without a cap keeps the summary it always had" do
    account = account!(%{})
    summary = Quota.policy_fields(account, nil).account_policy
    refute Map.has_key?(summary, :daily_burn_cap)
    refute Map.has_key?(summary, :burn_24h)
  end

  test "a capped account reports the cap, its mode and the latest burn reading" do
    account = account!(%{"daily_burn_cap" => 0.25})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_7d: 0.4,
      reset_7d_at: DateTime.add(now, 86_400, :second),
      status_7d: "allowed",
      captured_at: now,
      capture_source: "oauth_poll"
    })
    |> Ash.Changeset.for_update(:record_burn_24h, %{burn_24h: 0.18, burn_24h_at: now})
    |> Ash.update!()

    assert %{daily_burn_cap: 0.25, daily_burn_cap_mode: "shadow", burn_24h: 0.18} =
             Quota.policy_fields(account, nil).account_policy
  end

  test "enforce is reported as such, and no reading is nil" do
    account = account!(%{"daily_burn_cap" => 0.25, "daily_burn_cap_mode" => "enforce"})

    assert %{daily_burn_cap_mode: "enforce", burn_24h: nil} =
             Quota.policy_fields(account, nil).account_policy
  end
end
