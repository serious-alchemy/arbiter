defmodule Arbiter.Pricing do
  @moduledoc """
  Behaviour for turning token usage into a dollar figure.

  Every price read goes through `cost_usd/3`. Select an implementation with

      config :arbiter, :pricing, MyPackage.Pricing

  The default, `Arbiter.Pricing.Default`, uses core's built-in per-provider
  tables (`Arbiter.Usage.ClaudePricing`, `Arbiter.Agents.Gemini.Pricing`). A
  raising implementation is logged and treated as "no price" (`nil`).
  """

  require Logger

  @doc """
  Cost in USD, or `nil` when unpriced. For `:claude`, `usage` is the token
  bucket map; for `:gemini`, `model` is `nil` and `usage` is the CLI's
  `result.stats` map.
  """
  @callback cost_usd(provider :: atom(), model :: String.t() | nil, usage :: map()) ::
              float() | nil

  @spec cost_usd(atom(), String.t() | nil, map()) :: float() | nil
  def cost_usd(provider, model, usage) do
    impl().cost_usd(provider, model, usage)
  rescue
    e ->
      Logger.warning("Pricing #{inspect(impl())} ignored: #{Exception.message(e)}")
      nil
  end

  defp impl, do: Application.get_env(:arbiter, :pricing) || Arbiter.Pricing.Default
end
