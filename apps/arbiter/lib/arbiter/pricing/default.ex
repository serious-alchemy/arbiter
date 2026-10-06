defmodule Arbiter.Pricing.Default do
  @moduledoc "Core's built-in price tables behind the `Arbiter.Pricing` behaviour."

  @behaviour Arbiter.Pricing

  alias Arbiter.Agents.Gemini.Pricing, as: GeminiPricing
  alias Arbiter.Usage.ClaudePricing

  @impl true
  def cost_usd(:claude, model, buckets) when is_map(buckets),
    do: ClaudePricing.cost_usd(model, buckets)

  def cost_usd(:gemini, _model, stats), do: GeminiPricing.cost_usd(stats)
  def cost_usd(_provider, _model, _usage), do: nil
end
