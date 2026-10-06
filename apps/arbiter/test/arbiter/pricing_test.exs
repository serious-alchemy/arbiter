defmodule Arbiter.PricingTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Gemini.Pricing, as: GeminiPricing
  alias Arbiter.Pricing
  alias Arbiter.Usage.ClaudePricing

  defmodule Flat do
    @behaviour Arbiter.Pricing
    @impl true
    def cost_usd(_provider, _model, _usage), do: 42.0
  end

  defmodule Boom do
    @behaviour Arbiter.Pricing
    @impl true
    def cost_usd(_provider, _model, _usage), do: raise("boom")
  end

  setup do
    prev = Application.get_env(:arbiter, :pricing)
    on_exit(fn -> restore(prev) end)
    Application.delete_env(:arbiter, :pricing)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:arbiter, :pricing)
  defp restore(v), do: Application.put_env(:arbiter, :pricing, v)

  @buckets %{tokens_in: 1000, tokens_out: 500}
  @stats %{
    "models" => %{"gemini-2.5-pro" => %{"tokens" => %{"input" => 1000, "candidates" => 10}}}
  }

  test "default matches the per-provider tables" do
    model = ClaudePricing.price_table() |> Map.keys() |> hd()
    assert Pricing.cost_usd(:claude, model, @buckets) == ClaudePricing.cost_usd(model, @buckets)
    assert Pricing.cost_usd(:gemini, nil, @stats) == GeminiPricing.cost_usd(@stats)
    assert Pricing.cost_usd(:codex, "x", %{}) == nil
  end

  test "configured implementation is used" do
    Application.put_env(:arbiter, :pricing, Flat)
    assert Pricing.cost_usd(:claude, "any", @buckets) == 42.0
  end

  test "raising implementation yields nil" do
    Application.put_env(:arbiter, :pricing, Boom)
    assert Pricing.cost_usd(:claude, "any", @buckets) == nil
  end
end
