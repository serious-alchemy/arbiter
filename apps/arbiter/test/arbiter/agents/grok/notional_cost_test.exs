defmodule Arbiter.Agents.Grok.NotionalCostTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Grok.Stream

  test "grok cost moves into a notional note and out of cost_usd" do
    out = Stream.mark_notional_cost(%{provider: "grok", cost_usd: 0.627564, cost_note: nil})
    assert out.cost_usd == nil
    assert out.cost_note =~ "notional"
    assert out.cost_note =~ "0.627564"
  end

  test "other providers and cost-less rows are untouched" do
    claude = %{provider: "claude", cost_usd: 1.5, cost_note: nil}
    assert Stream.mark_notional_cost(claude) == claude
    nocost = %{provider: "grok", cost_usd: nil, cost_note: nil}
    assert Stream.mark_notional_cost(nocost) == nocost
  end
end
