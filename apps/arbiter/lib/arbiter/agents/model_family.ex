defmodule Arbiter.Agents.ModelFamily do
  @moduledoc """
  Which **model family** a (provider, model) pair belongs to, and which
  **quota pool** it draws on (bd-40pzpj). Pure: no config, no database.

  Provider routing spreads implementer work across families, so it needs to
  know that an agy account running `claude-opus-4-6-thinking` is Anthropic
  work metered on agy's `claude_and_gpt_models` pool, not Google work on its
  Gemini one:

  | provider               | model                  | family       | pool                                  |
  |------------------------|------------------------|--------------|---------------------------------------|
  | `claude`               | any                    | `:anthropic` | `"claude"`                            |
  | `antigravity` (agy)    | `gemini-*` / unknown   | `:google`    | `"antigravity:gemini_models"`         |
  | `antigravity` (agy)    | `claude-*`             | `:anthropic` | `"antigravity:claude_and_gpt_models"` |
  | `antigravity` (agy)    | `gpt-*`                | `:openai`    | `"antigravity:claude_and_gpt_models"` |
  | `codex`                | `gpt-*` / `o<n>*` / unset | `:openai` | `"codex"`                             |
  | `codex`                | `claude-*` / `gemini-*` / `grok-*` | their family | `"codex"`                |
  | `codex`                | any other (Ollama etc.) | `:local`    | `"codex"`                             |
  | `grok` (later)         | any                    | `:xai`       | `"grok"`                              |
  | `ollama` (later)       | any                    | `:local`     | `"ollama"`                            |

  The agy split mirrors `Arbiter.Quota.Gate.Snapshot`'s bucket grouping, so a
  pool named here is exactly the one the gate reads. The adapter type
  `"gemini"` — what a `worker_runs.provider` records, without saying which
  Google CLI ran — classifies by its model's prefix the same way.

  ## The tier → model map

  Difficulty routing (`Arbiter.Agents.Routing.ByDifficulty`) emits an
  abstract `model_tier`; each family turns it into a concrete model through
  its **adapter's** built-in map, which is where it already lived:
  `Arbiter.Agents.Claude.Config.default_tier_models/0`,
  `Arbiter.Agents.Codex.Config.default_tier_models/0` and
  `Arbiter.Agents.Gemini.Config.default_tier_models/1` (`:agy` or
  `:gemini`). A workspace overrides it under `agent.config.tier_models`, or
  per adapter under `agent.config.<adapter>.tier_models`
  (`Arbiter.Agents.ProviderConfig`). `model_for_tier/3` resolves it the same
  way the adapter will at spawn, so routing can know the model — and so the
  pool — before it picks an account.

  ## The reviewer tier → model map (bd-a1ke2c)

  A cross-family reviewer (`review_agent.cross_family`,
  `Arbiter.Agents.ReviewerRouting`) runs its family's **strongest reviewer
  tier** for the task's difficulty. The tier starts as the ReviewGate's own
  reviewer tier (the task's tier bumped one step, bd-3xultf) and is then
  raised to the family's reviewer floor here, `reviewer_tier/2`; the concrete
  model is that tier through the same adapter map as above
  (`model_for_tier/3`). Today only Google has a floor: its economy/standard
  tiers are flash models, fine for implementation but not for judging another
  family's work, so a Google reviewer always runs `premium` — agy's
  `gemini-3.1-pro-high`, the gemini CLI's `gemini-2.5-pro` — at `high`
  effort (`reviewer_thinking/2`) unless the workspace configured one.
  """

  alias Arbiter.Agents.Claude.Config, as: ClaudeConfig
  alias Arbiter.Agents.Codex.Config, as: CodexConfig
  alias Arbiter.Agents.Gemini.Config, as: GeminiConfig
  alias Arbiter.Agents.ProviderConfig

  @type family :: :anthropic | :google | :openai | :xai | :local
  @type t :: %{family: family() | nil, pool: String.t() | nil}

  @reviewer_tier_floor %{google: "premium"}
  @reviewer_thinking %{google: "high"}
  @tier_ladder ~w(economy standard premium)

  @agy_gemini_pool "antigravity:gemini_models"
  @agy_claude_gpt_pool "antigravity:claude_and_gpt_models"

  @doc "The (family, pool) a `provider` running `model` belongs to. See the moduledoc."
  @spec classify(atom() | String.t() | nil, String.t() | nil) :: t()
  def classify(provider, model) when is_atom(provider) and not is_nil(provider),
    do: classify(Atom.to_string(provider), model)

  def classify("claude", _model), do: %{family: :anthropic, pool: "claude"}
  def classify("codex", model), do: %{family: codex_family(model), pool: "codex"}
  def classify("grok", _model), do: %{family: :xai, pool: "grok"}
  def classify("ollama", _model), do: %{family: :local, pool: "ollama"}

  def classify(agy, model) when agy in ["antigravity", "agy"] do
    case model_family(model) do
      :google -> %{family: :google, pool: @agy_gemini_pool}
      family -> %{family: family, pool: @agy_claude_gpt_pool}
    end
  end

  def classify("gemini", model), do: %{family: model_family(model), pool: "gemini"}
  def classify(_provider, _model), do: %{family: nil, pool: nil}

  # bd-5sfn7v: the Codex CLI is a Responses-API client, so the provider string
  # says nothing about the model family — a custom `model_provider` backend
  # (Ollama, ...) runs whatever model it names. No model (the CLI default on
  # the ChatGPT/OpenAI backend) and OpenAI ids are `:openai`; a recognisable
  # foreign id gets its own family; any other id is open-weights, `:local`.
  defp codex_family(model) when is_binary(model) and model != "" do
    case model do
      "gpt-" <> _ -> :openai
      "o" <> <<d, _::binary>> when d in ?0..?9 -> :openai
      "codex-" <> _ -> :openai
      "claude-" <> _ -> :anthropic
      "gemini-" <> _ -> :google
      "grok-" <> _ -> :xai
      _ -> :local
    end
  end

  defp codex_family(_model), do: :openai

  # agy's two pools split on the model id's prefix, exactly as
  # `Arbiter.Quota.Gate.Snapshot`'s bucket group does: `claude-*` / `gpt-*`
  # are the Claude-and-GPT pool, anything else is Gemini.
  defp model_family("claude-" <> _), do: :anthropic
  defp model_family("gpt-" <> _), do: :openai
  defp model_family(_), do: :google

  @doc """
  The concrete model `provider` runs for `tier`, resolved as its adapter will:
  `agent_config[<adapter>]["tier_models"]`, then the flat
  `agent_config["tier_models"]`, then the adapter's built-in map. `nil` when
  nothing names one (the CLI's own default then applies).
  """
  @spec model_for_tier(atom() | String.t() | nil, String.t() | nil, map() | nil) ::
          String.t() | nil
  def model_for_tier(provider, tier, agent_config)
      when is_binary(tier) and tier != "" do
    case builtin(provider) do
      nil ->
        nil

      {adapter, defaults} ->
        overrides =
          (agent_config || %{})
          |> ProviderConfig.apply_overrides(adapter)
          |> Map.get("tier_models")

        present(overrides, tier) || present(defaults, tier)
    end
  end

  def model_for_tier(_provider, _tier, _agent_config), do: nil

  @doc """
  The tier a `family` reviewer runs for a task whose reviewer tier is `tier`:
  `tier` raised to the family's reviewer floor (see the moduledoc). A tier off
  the economy → premium ladder (e.g. agy's `flagship`) is left alone.
  """
  @spec reviewer_tier(family() | nil, String.t() | nil) :: String.t() | nil
  def reviewer_tier(family, tier) do
    case Map.get(@reviewer_tier_floor, family) do
      nil -> tier
      floor -> higher_tier(tier, floor)
    end
  end

  defp higher_tier(tier, floor) do
    case {Enum.find_index(@tier_ladder, &(&1 == tier)),
          Enum.find_index(@tier_ladder, &(&1 == floor))} do
      {nil, _} when is_binary(tier) and tier != "" -> tier
      {nil, _} -> floor
      {t, f} when t >= f -> tier
      _ -> floor
    end
  end

  @doc """
  The reasoning effort a `family` reviewer runs at: the workspace's own
  `thinking` when it set one, else the family's reviewer default (Google:
  `"high"`), else `nil` (the CLI default).
  """
  @spec reviewer_thinking(family() | nil, String.t() | nil) :: String.t() | nil
  def reviewer_thinking(_family, thinking) when is_binary(thinking) and thinking != "",
    do: thinking

  def reviewer_thinking(family, _thinking), do: Map.get(@reviewer_thinking, family)

  defp builtin(provider) when is_atom(provider) and not is_nil(provider),
    do: builtin(Atom.to_string(provider))

  defp builtin("claude"), do: {"claude", ClaudeConfig.default_tier_models()}
  defp builtin("codex"), do: {"codex", CodexConfig.default_tier_models()}

  defp builtin(agy) when agy in ["antigravity", "agy"],
    do: {"gemini", GeminiConfig.default_tier_models(:agy)}

  defp builtin("gemini"), do: {"gemini", GeminiConfig.default_tier_models(:gemini)}

  defp builtin(_), do: nil

  defp present(%{} = map, tier) do
    case Map.get(map, tier) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  defp present(_, _tier), do: nil
end
