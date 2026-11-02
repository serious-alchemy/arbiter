defmodule Arbiter.Quota.BurnPollTest do
  @moduledoc "burn_24h is computed at poll time from the quota_snapshots history (bd-cklotu)."
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Tasks.Workspace

  setup do
    on_exit(fn -> Quota.OAuthUsage.reset_cooldown!("test-token") end)
    :ok
  end

  defp seed!(account_id, hours_ago, util, reset) do
    QuotaSnapshot
    |> Ash.Changeset.for_create(:record, %{
      provider_account_id: account_id,
      provider: "claude",
      bucket: "claude",
      window: "7d",
      utilization: util,
      resets_at: reset,
      captured_at: DateTime.add(DateTime.utc_now(), -hours_ago * 3600 - 30, :second)
    })
    |> Ash.create!()
  end

  defp poll!(account_id, util_pct, reset) do
    body = %{
      "seven_day" => %{"utilization" => util_pct, "resets_at" => DateTime.to_iso8601(reset)}
    }

    Req.Test.stub(Quota.OAuthUsage.HTTP, fn conn -> Req.Test.json(conn, body) end)

    {:ok, quota} =
      Quota.capture_oauth_usage(account_id,
        token: "test-token",
        plug: {Req.Test, Quota.OAuthUsage.HTTP}
      )

    quota
  end

  defp reset_at,
    do: DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.truncate(:second)

  test "the poll stores the 24h burn on the quota row" do
    ws = Ash.create!(Workspace, %{name: "default"})
    id = quota_account_id!(ws.id)
    reset = reset_at()
    for h <- 25..1//-1, do: seed!(id, h, 0.10 + (25 - h) * 0.01, reset)

    quota = poll!(id, 35, reset)

    assert_in_delta quota.burn_24h, 0.35 - 0.11, 0.011
    assert %DateTime{} = quota.burn_24h_at
    assert [%AnthropicQuota{burn_24h: stored}] = Ash.read!(AnthropicQuota)
    assert_in_delta stored, quota.burn_24h, 1.0e-9
  end

  test "a window reset inside the 24h restarts the baseline" do
    ws = Ash.create!(Workspace, %{name: "default"})
    id = quota_account_id!(ws.id)
    old_reset = DateTime.add(reset_at(), -7 * 86_400, :second)
    new_reset = reset_at()

    for h <- 25..13//-1, do: seed!(id, h, 0.80 + (25 - h) * 0.01, old_reset)
    for h <- 12..1//-1, do: seed!(id, h, 0.02 + (12 - h) * 0.01, new_reset)

    quota = poll!(id, 15, new_reset)
    # 0.80 -> 0.92, reset, 0.02 -> 0.15
    assert_in_delta quota.burn_24h, 0.12 + 0.02 + 0.13, 0.011
  end

  test "sparse history leaves burn_24h nil" do
    ws = Ash.create!(Workspace, %{name: "default"})
    id = quota_account_id!(ws.id)
    quota = poll!(id, 35, reset_at())
    assert quota.burn_24h == nil
    assert quota.burn_24h_at == nil
  end

  test "the gate snapshot carries burn_24h" do
    at = ~U[2026-11-02 12:00:00Z]

    quota = %AnthropicQuota{
      provider: "claude",
      utilization_7d: 0.4,
      captured_at: at,
      burn_24h: 0.2,
      burn_24h_at: at
    }

    assert %Snapshot{burn_24h: 0.2, burn_24h_at: ^at} = Snapshot.normalize(quota)
  end
end
