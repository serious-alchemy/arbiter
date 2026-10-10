defmodule Arbiter.Agents.Grok.NotionalCostTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Agents.Grok.Stream
  alias Arbiter.Usage
  alias Arbiter.Usage.Event

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        task_id: "bd-notional-#{System.unique_integer([:positive])}",
        repo: "arbiter",
        workspace_id: "ws-notional",
        step: :work,
        occurred_at: DateTime.utc_now(),
        provider: "grok",
        cost_usd: 0.627564,
        cost_note: nil,
        raw: nil
      },
      extra
    )
  end

  test "free-tier grok cost moves into a notional note and raw, out of cost_usd" do
    out = Stream.mark_notional_cost(attrs(), "free")
    assert out.cost_usd == nil
    assert out.cost_note =~ "notional"
    assert out.cost_note =~ "0.627564"
    assert out.raw["notional_cost_usd"] == 0.627564
  end

  test "paid, unknown plans, other providers and cost-less rows are untouched" do
    row = attrs()
    for plan <- ["pro", nil], do: assert(Stream.mark_notional_cost(row, plan) == row)

    claude = attrs(%{provider: "claude"})
    assert Stream.mark_notional_cost(claude, "free") == claude
    nocost = attrs(%{cost_usd: nil})
    assert Stream.mark_notional_cost(nocost, "free") == nocost
  end

  test "a persisted notional row has a note and does not count in spend totals" do
    {:ok, account} =
      Ash.create(Arbiter.Accounts.ProviderAccount, %{provider: :grok, slug: "notional-free"})

    free = Stream.mark_notional_cost(attrs(%{provider_account_id: account.id}), "free")

    paid =
      Stream.mark_notional_cost(attrs(%{provider_account_id: account.id, cost_usd: 2.0}), "pro")

    {:ok, free_row} = Ash.create(Event, free)
    {:ok, paid_row} = Ash.create(Event, paid)

    assert free_row.cost_usd == nil
    assert free_row.cost_note =~ "notional"
    assert paid_row.cost_usd == 2.0
    assert paid_row.cost_note == nil

    totals = Usage.spend_by_account()

    assert totals[account.id] == %{"grok" => 2}
  end
end
