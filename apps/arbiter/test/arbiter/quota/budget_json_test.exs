defmodule Arbiter.Quota.BudgetJsonTest do
  @moduledoc """
  DC5 (bd-2c2a4g; `docs/design/provider-dynamic-concurrency.md` §9):
  `Budget.to_json/1`, the one JSON-safe rendering of a published budget that
  `arb scheduler status`, `scheduler_status`, `quota_get` and the board's
  popups share.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Gate.Snapshot

  @now ~U[2026-10-10 01:40:27Z]

  defp snapshot do
    %Snapshot{
      provider: "claude",
      utilization: 0.19,
      status: "allowed",
      reset_at: ~U[2026-10-10 04:40:00Z],
      captured_at: ~U[2026-10-10 01:38:49Z],
      capture_source: "oauth_poll",
      window_label: "5h",
      secondary_utilization: 0.49,
      secondary_status: "allowed",
      secondary_reset_at: ~U[2026-10-12 16:00:00Z],
      secondary_window_label: "7d"
    }
  end

  defp compute(overrides \\ []) do
    base = [
      account: %ProviderAccount{
        provider: :claude,
        quota_config: %{"threshold_mode" => "paced"},
        max_concurrent: 3
      },
      pool: "claude",
      quota: snapshot(),
      now: @now,
      seats: 3,
      horizon: 2.0
    ]

    base |> Keyword.merge(overrides) |> Budget.compute()
  end

  test "renders the integer, the reason and every window's numbers, JSON-encodable" do
    json = compute() |> Budget.to_json()

    assert json.budget == 3
    assert json.seats == 3
    assert json.free == 0
    assert json.binding == "ceiling"
    assert json.reason =~ "ceiling max_concurrent 3"
    assert json.ceiling == %{max_concurrent: 3, share: nil}
    assert json.horizon_h == 2.0

    five = Enum.find(json.windows, &(&1.window == "5h"))
    assert five.rho_source == "prior"
    assert_in_delta five.line_now, 0.4015, 1.0e-3
    assert_in_delta five.line_at_h, 0.8015, 1.0e-3
    assert five.status == "ok"

    assert {:ok, _} = Jason.encode(json)
  end

  test "a window binding is rendered as {window, label} text and a hard zero by its name" do
    assert %{binding: "ceiling"} = Budget.to_json(compute())
    assert %{budget: 0, binding: "paused"} = Budget.to_json(compute(hard: :paused))

    quota = %{snapshot() | utilization: 0.7}

    {published, _} = Budget.publish(compute(quota: quota), Budget.new_hysteresis(), @now)
    json = Budget.to_json(published)
    assert json.binding =~ "window:"
  end

  test "an unlimited budget renders as the string \"unlimited\"" do
    assert %{budget: "unlimited", free: "unlimited"} =
             Budget.to_json(%Budget{budget: :unlimited, free: :unlimited, binding: :unmetered})
  end

  test "carries the pending rise and the exempt budget" do
    since = ~U[2026-10-10 01:30:00Z]

    json =
      Budget.to_json(%Budget{
        budget: 3,
        exempt_budget: 5,
        binding: :ceiling,
        pending_rise: %{raw: 4.6, since: since}
      })

    assert json.exempt_budget == 5
    assert json.pending_rise == %{raw: 4.6, since: since}
  end
end
