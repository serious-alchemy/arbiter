defmodule Arbiter.Quota.OverageTest do
  @moduledoc """
  `Arbiter.Quota.Overage`'s 5h accounting window (bd-2wnkoq, AC 6).

  The window used to be `[reset_5h_at - 5h, now]` whatever `reset_5h_at` was.
  On a snapshot that went stale hours ago, that reset is long past, so the
  "current 5h window" silently stretched back to a window that closed hours
  earlier and summed every dollar since — the figure the overage alert
  compares against its threshold.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Overage
  alias Arbiter.Usage.Event

  @five_hours 5 * 3_600
  @now ~U[2026-09-30 12:00:00Z]

  describe "window_start/2" do
    test "an open window starts 5h before its reset" do
      reset = DateTime.add(@now, 3_600, :second)
      expected = DateTime.add(reset, -@five_hours, :second)

      assert Overage.window_start(%AnthropicQuota{reset_5h_at: reset}, @now) == expected
      assert Overage.window_start(%Snapshot{reset_at: reset}, @now) == expected
    end

    test "a reset hours in the past falls back to the trailing 5h" do
      reset = DateTime.add(@now, -3 * 3_600, :second)
      trailing = DateTime.add(@now, -@five_hours, :second)

      assert Overage.window_start(%AnthropicQuota{reset_5h_at: reset}, @now) == trailing
      assert Overage.window_start(%Snapshot{reset_at: reset}, @now) == trailing
    end

    test "a reset landing exactly now has closed its window" do
      trailing = DateTime.add(@now, -@five_hours, :second)
      assert Overage.window_start(%Snapshot{reset_at: @now}, @now) == trailing
    end

    test "no reset at all is the trailing 5h" do
      trailing = DateTime.add(@now, -@five_hours, :second)

      assert Overage.window_start(%AnthropicQuota{reset_5h_at: nil}, @now) == trailing
      assert Overage.window_start(nil, @now) == trailing
    end
  end

  describe "window_start/1" do
    test "reads the real clock: a reset hours in the past is not the window's start" do
      reset = DateTime.add(DateTime.utc_now(), -3 * 3_600, :second)
      trailing = DateTime.add(DateTime.utc_now(), -@five_hours, :second)

      start = Overage.window_start(%AnthropicQuota{reset_5h_at: reset})

      assert_in_delta DateTime.to_unix(start), DateTime.to_unix(trailing), 5
    end
  end

  describe "windowed_spend/2 on a snapshot whose reset passed hours ago" do
    test "sums the trailing 5h, not everything since the long-closed window opened" do
      n = System.unique_integer([:positive])

      account =
        Ash.create!(ProviderAccount, %{provider: :claude, slug: "overage-#{n}", label: "o #{n}"})

      now = DateTime.utc_now()
      stale = %AnthropicQuota{reset_5h_at: DateTime.add(now, -3 * 3_600, :second)}

      # Inside the stale window's [reset - 5h, now] span, but outside the
      # trailing 5h — the old rule counted it.
      spend!(account, 40.0, DateTime.add(now, -7 * 3_600, :second))
      # Inside the trailing 5h.
      spend!(account, 2.5, DateTime.add(now, -3_600, :second))

      assert_in_delta Overage.windowed_spend(account, stale), 2.5, 0.0001
    end
  end

  defp spend!(account, cost, occurred_at) do
    Ash.create!(Event, %{
      workspace_id: nil,
      task_id: "bd-overage-#{System.unique_integer([:positive])}",
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      cost_usd: cost,
      occurred_at: occurred_at
    })
  end
end
