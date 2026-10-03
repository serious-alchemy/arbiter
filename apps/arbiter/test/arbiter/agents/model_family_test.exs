defmodule Arbiter.Agents.ModelFamilyTest do
  @moduledoc """
  bd-40pzpj AC1: the pure (provider, model) → (model family, quota pool)
  mapping provider routing selects accounts by, and the per-family
  tier → model map difficulty routes within.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Agents.ModelFamily

  describe "classify/2" do
    test "claude is anthropic on the claude pool, whatever the model" do
      assert ModelFamily.classify(:claude, "opus") == %{family: :anthropic, pool: "claude"}
      assert ModelFamily.classify("claude", nil) == %{family: :anthropic, pool: "claude"}
    end

    test "agy gemini-* models are google on agy's Gemini pool" do
      assert ModelFamily.classify(:antigravity, "gemini-3.8-flash-low") ==
               %{family: :google, pool: "antigravity:gemini_models"}
    end

    test "agy claude-* models are anthropic on agy's claude_and_gpt_models pool" do
      assert ModelFamily.classify(:antigravity, "claude-opus-4-6-thinking") ==
               %{family: :anthropic, pool: "antigravity:claude_and_gpt_models"}
    end

    test "agy gpt-* models are openai on the same claude_and_gpt_models pool" do
      assert ModelFamily.classify(:antigravity, "gpt-5.5-high") ==
               %{family: :openai, pool: "antigravity:claude_and_gpt_models"}
    end

    test "an agy account with no resolved model reads as its default Gemini pool" do
      assert ModelFamily.classify(:antigravity, nil) ==
               %{family: :google, pool: "antigravity:gemini_models"}
    end

    test "codex family follows the resolved model, not the provider string (bd-5sfn7v)" do
      pool = "codex"
      assert ModelFamily.classify(:codex, nil) == %{family: :openai, pool: pool}
      assert ModelFamily.classify("codex", "gpt-5.6-terra").family == :openai
      assert ModelFamily.classify("codex", "o4-mini").family == :openai

      assert ModelFamily.classify("codex", "claude-sonnet-4-5") == %{
               family: :anthropic,
               pool: pool
             }

      assert ModelFamily.classify("codex", "gemini-2.5-pro").family == :google
      assert ModelFamily.classify("codex", "grok-4").family == :xai
      # a Codex + Ollama (or other Responses-API) backend runs open-weights models
      assert ModelFamily.classify("codex", "qwen3-coder:30b").family == :local
      assert ModelFamily.classify("codex", "").family == :openai
    end

    test "codex is openai on the codex pool" do
      assert ModelFamily.classify(:codex, "gpt-5-codex") == %{family: :openai, pool: "codex"}
    end

    test "the removed upstream gemini CLI provider has no family (bd-ac53wz)" do
      assert ModelFamily.classify(:gemini_cli, "gemini-2.5-pro") == %{family: nil, pool: nil}
    end

    test "a run's recorded adapter type classifies by its model" do
      assert ModelFamily.classify("gemini", "claude-opus-4-6-thinking").family == :anthropic
      assert ModelFamily.classify("gemini", "gemini-3.1-pro-high").family == :google
    end

    test "later providers: grok is xai and ollama is local" do
      assert ModelFamily.classify(:grok, "grok-4") == %{family: :xai, pool: "grok"}
      assert ModelFamily.classify(:ollama, "qwen3") == %{family: :local, pool: "ollama"}
    end

    test "an unknown provider has no family" do
      assert ModelFamily.classify(:nonesuch, "x") == %{family: nil, pool: nil}
      assert ModelFamily.classify(nil, nil) == %{family: nil, pool: nil}
    end
  end

  describe "model_for_tier/3" do
    test "each family resolves a tier through its adapter's built-in map" do
      assert ModelFamily.model_for_tier(:claude, "economy", %{}) == "haiku"
      assert ModelFamily.model_for_tier(:claude, "premium", %{}) == "opus"
      assert ModelFamily.model_for_tier(:codex, "economy", %{}) == "gpt-5.6-luna"
      assert ModelFamily.model_for_tier(:codex, "premium", %{}) == "gpt-5.6-terra"
      assert ModelFamily.model_for_tier(:antigravity, "premium", %{}) == "gemini-3.1-pro-high"

      assert ModelFamily.model_for_tier(:antigravity, "flagship", %{}) ==
               "claude-opus-4-6-thinking"

      # bd-ac53wz: the upstream Gemini CLI provider is gone.
      assert ModelFamily.model_for_tier(:gemini_cli, "premium", %{}) == nil
    end

    test "a provider-scoped tier_models override wins over the flat one and the default" do
      config = %{
        "tier_models" => %{"premium" => "flat-model"},
        "codex" => %{"tier_models" => %{"premium" => "gpt-5.5"}}
      }

      assert ModelFamily.model_for_tier(:codex, "premium", config) == "gpt-5.5"
      assert ModelFamily.model_for_tier(:claude, "premium", config) == "flat-model"
    end

    test "agy reads the gemini adapter's scoped overrides" do
      config = %{"gemini" => %{"tier_models" => %{"flagship" => "gpt-5.5-high"}}}
      assert ModelFamily.model_for_tier(:antigravity, "flagship", config) == "gpt-5.5-high"
    end

    test "an unknown tier or provider resolves to nil" do
      assert ModelFamily.model_for_tier(:claude, "flagship", %{}) == nil
      assert ModelFamily.model_for_tier(:claude, nil, %{}) == nil
      assert ModelFamily.model_for_tier(:nonesuch, "premium", %{}) == nil
    end
  end
end
