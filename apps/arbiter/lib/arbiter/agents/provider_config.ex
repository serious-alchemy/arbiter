defmodule Arbiter.Agents.ProviderConfig do
  @moduledoc """
  Per-provider namespacing for a workspace's shared `agent.config` map.

  A workspace's `agent.config` (the raw map each adapter's `Config` seeds into
  its process dictionary via `put_active/2`) is **shared across every provider
  in a multi-provider pool**. When `agent.type` is a list such as
  `["claude", "gemini"]`, all three adapters read the identical raw map. A flat
  override like `tier_models` therefore applies to *every* adapter — a
  `tier_models` map meant for Codex is also read by Claude and Gemini, which
  then try to launch with a model name they don't recognise (bd-a6vu3c: setting
  a Codex-intended `tier_models` broke Claude dispatch, which picked up the
  Codex model `gpt-5.5` and failed to start).

  To scope an override to a single provider, nest it under the provider's own
  name — the same string used in `agent.type` (`"claude"` | `"gemini"` |
  `"codex"`):

      agent.config = %{
        "codex"  => %{"tier_models" => %{"standard" => "gpt-5-codex"}},
        "claude" => %{"tier_models" => %{"standard" => "opus"}}
      }

  `apply_overrides/2` shallow-merges the provider's own sub-map over the flat
  keys, so precedence (highest wins, key-by-key) is:

      provider-scoped   agent.config[provider][key]
        over flat/shared agent.config[key]           # backward compat

  Existing single-provider workspaces that set only flat keys keep working
  unchanged (no provider sub-map ⇒ the merge is a no-op). A multi-provider pool
  can pin per-provider overrides that no longer collide.

  Applying the merge once at `put_active/2` means every downstream reader
  (`model_for_tier/1`, `thinking_argv/1`, `active_model/0`, credential
  resolution) transparently sees the provider-scoped values without any
  per-key call-site change. The leftover provider sub-map keys in the merged
  map are harmless — readers only look up their specific flat keys.
  """

  @doc """
  Merge `raw`'s provider-scoped sub-map (`raw[provider]`) over its flat keys.

  Returns `raw` unchanged when there is no map nested under `provider` (the
  common single-provider / flat-config case). Non-map inputs are returned
  as-is.
  """
  @spec apply_overrides(term(), String.t()) :: term()
  def apply_overrides(raw, provider) when is_map(raw) and is_binary(provider) do
    case Map.get(raw, provider) do
      sub when is_map(sub) and not is_struct(sub) -> Map.merge(raw, sub)
      _ -> raw
    end
  end

  def apply_overrides(raw, _provider), do: raw

  @doc """
  The ordered model ids a `tier_models` value names (R9, bd-3go56q): a string is
  a one-element list, a list keeps its order, and anything that is not a
  non-empty string is dropped. `[]` when nothing usable is left.
  """
  @spec model_ids(term()) :: [String.t()]
  def model_ids(value) when is_binary(value) and value != "", do: [value]

  def model_ids(value) when is_list(value),
    do: Enum.filter(value, &(is_binary(&1) and &1 != ""))

  def model_ids(_value), do: []

  @doc """
  A `tier_models` map with every list collapsed to its first model id, the
  entry an adapter spawns with (the rest are routing's alternatives, see
  `Arbiter.Agents.ModelFamily.models_for_tier/3`). Entries that name no usable
  model are dropped, as the adapters' own filter did for non-strings.
  """
  @spec first_models(term()) :: %{String.t() => String.t()}
  def first_models(%{} = map) when not is_struct(map) do
    for {tier, value} <- map,
        is_binary(tier),
        [first | _] <- [model_ids(value)],
        into: %{},
        do: {tier, first}
  end

  def first_models(_), do: %{}
end
