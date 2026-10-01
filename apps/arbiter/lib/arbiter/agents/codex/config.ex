defmodule Arbiter.Agents.Codex.Config do
  @moduledoc """
  Reads the Codex agent's configuration from the active workspace.

  Mirrors `Arbiter.Agents.Gemini.Config`. The active workspace config is
  seeded by `Arbiter.Agents.prepare/1` and stored in the process dictionary.

  Codex normally authenticates through the operator's ChatGPT login under
  `$CODEX_HOME` (`~/.codex/auth.json`), so an API key is *optional*: when a
  workspace supplies one (or `OPENAI_API_KEY` is in the ambient env) the
  adapter exports it, otherwise it lets the CLI use the ChatGPT auth already on
  disk.
  """

  require Logger

  alias Arbiter.Agents.Codex.ModelCatalog
  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Agents.ProviderConfig
  alias Arbiter.Tasks.Workspace

  # Provider name used to scope per-provider overrides in a shared
  # multi-provider `agent.config` (see `Arbiter.Agents.ProviderConfig`).
  @provider "codex"

  @pdict_key {__MODULE__, :active_workspace_config}
  @pdict_workspace_key {__MODULE__, :active_workspace_id}
  @pdict_context_key {__MODULE__, :model_validation_context}
  @rotation_key {__MODULE__, :api_key_rotation_index}

  @type t :: %{
          model: String.t() | nil,
          credentials_ref: String.t() | nil,
          api_keys: [String.t()],
          raw: map()
        }

  # Default tier → concrete Codex model. Overridable per-workspace via
  # `agent.config["tier_models"]` (string keys), or — in a multi-provider pool
  # where that flat key is shared — via the Codex-scoped
  # `agent.config["codex"]["tier_models"]` (merged at `put_active/2`; see
  # `Arbiter.Agents.ProviderConfig`).
  #
  # Both models were probed working on a ChatGPT free account (bd-7tgosa) and
  # are listed in its models_cache.json. `flagship` shares premium's model:
  # no larger Codex model is callable on that account. Whatever this map or
  # an override resolves to is still checked by `Codex.ModelCatalog` for the
  # active account's plan and catalog (see `model_for_tier/1`), and none of it
  # applies to a custom `model_provider` backend.
  @default_tier_models %{
    "economy" => "gpt-5.6-luna",
    "standard" => "gpt-5.6-terra",
    "premium" => "gpt-5.6-terra",
    "flagship" => "gpt-5.6-terra"
  }

  @doc "Set the active Codex agent config for the current process."
  @spec put_active(Workspace.t() | map() | nil) :: :ok
  def put_active(thing), do: put_active(thing, :agent)

  @doc """
  Set the active config for either the worker `:agent` or the reviewer
  `:review_agent` role.
  """
  @spec put_active(Workspace.t() | map() | nil, :agent | :review_agent) :: :ok
  def put_active(nil, _role) do
    Process.delete(@pdict_key)
    Process.delete(@pdict_workspace_key)
    Process.delete(@pdict_context_key)
    :ok
  end

  def put_active(%Workspace{config: config, id: workspace_id} = workspace, role)
      when role in [:agent, :review_agent] do
    raw =
      (get_in(config || %{}, [Atom.to_string(role), "config"]) || %{})
      |> ProviderConfig.apply_overrides(@provider)

    Process.put(@pdict_key, CredentialsRef.embed_secrets(raw, Workspace.secrets_map(workspace)))
    Process.put(@pdict_workspace_key, workspace_id)
    Process.delete(@pdict_context_key)
    :ok
  end

  def put_active(%{} = raw, _role) do
    Process.put(@pdict_key, ProviderConfig.apply_overrides(raw, @provider))
    Process.delete(@pdict_workspace_key)
    Process.delete(@pdict_context_key)
    :ok
  end

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    Process.delete(@pdict_workspace_key)
    Process.delete(@pdict_context_key)
    Process.delete(@rotation_key)
    :ok
  end

  @doc "Resolve the active Codex config."
  @spec resolve() :: {:ok, t()}
  def resolve do
    raw = Process.get(@pdict_key) || %{}

    {:ok,
     %{
       model: stringy(Map.get(raw, "model")),
       credentials_ref: stringy(Map.get(raw, "credentials_ref")),
       api_keys: list_of_strings(Map.get(raw, "api_keys")),
       raw: raw
     }}
  end

  @doc """
  Resolve the active API key, rotating through `api_keys` (if present) on each
  call. Falls back to a `credentials_ref` then the ambient `OPENAI_API_KEY`.
  Returns `nil` when nothing is configured — the adapter then relies on the
  ChatGPT auth in `$CODEX_HOME`.
  """
  @spec resolve_api_key() :: String.t() | nil
  def resolve_api_key do
    {:ok, cfg} = resolve()

    case cfg.api_keys do
      [] ->
        case resolve_ref(cfg.credentials_ref, cfg.raw) do
          nil -> ambient_api_key()
          key -> key
        end

      keys ->
        keys
        |> rotate_pick()
        |> resolve_ref(cfg.raw)
    end
  end

  @doc """
  Side-effect-free check for whether an API key is configured. Unlike
  `resolve_api_key/0` it does not advance the `api_keys` rotation counter.
  """
  @spec api_key_configured?() :: boolean()
  def api_key_configured? do
    {:ok, cfg} = resolve()

    key =
      case cfg.api_keys do
        [] ->
          resolve_ref(cfg.credentials_ref, cfg.raw) || ambient_api_key()

        [first | _] ->
          resolve_ref(first, cfg.raw)
      end

    is_binary(key) and key != ""
  end

  @doc "Return the active model name as a string, or `nil` if unset."
  @spec active_model() :: String.t() | nil
  def active_model do
    {:ok, cfg} = resolve()
    cfg.model
  end

  @doc """
  Resolve an abstract `model_tier` (`"economy"` | `"standard"` | `"premium"` |
  `"flagship"`) to a concrete Codex model name. Returns `nil` for an unknown /
  nil tier — the adapter then sends no `-m` and the CLI uses its own default.
  Workspace config can override the mapping under `agent.config["tier_models"]`.

  The resolved model is checked against the active account (see
  `Arbiter.Agents.Codex.ModelCatalog`). One the account provably cannot call
  is replaced, with a warning, by the tier's built-in default or else the
  catalog's top listed model. On a custom `model_provider` backend the
  OpenAI built-ins never apply: only an explicit override resolves.
  """
  @spec model_for_tier(String.t() | nil) :: String.t() | nil
  def model_for_tier(nil), do: nil
  def model_for_tier(""), do: nil

  def model_for_tier(tier) when is_binary(tier) do
    {:ok, cfg} = resolve()
    ctx = validation_context()
    default = if ctx.backend == :custom, do: nil, else: Map.get(@default_tier_models, tier)

    case Map.get(stringy_map(Map.get(cfg.raw, "tier_models")), tier) || default do
      nil -> nil
      model -> usable_for_tier(tier, model, default, ctx)
    end
  end

  def model_for_tier(_), do: nil

  @doc """
  Pre-flight check of a concrete model against the active account. `:ok`
  when usable or when nothing proves otherwise (missing/stale catalog,
  non-ChatGPT backend).
  """
  @spec validate_model(String.t()) :: :ok | {:error, String.t()}
  def validate_model(model) when is_binary(model),
    do: ModelCatalog.check(model, validation_context())

  @doc "Built-in default tier → model map (testing / introspection)."
  def default_tier_models, do: @default_tier_models

  defp usable_for_tier(tier, model, default, ctx) do
    case ModelCatalog.usable(model, List.wrap(default), ctx) do
      ^model ->
        model

      substitute ->
        {:error, why} = ModelCatalog.check(model, ctx)

        Logger.warning(
          "Codex tier #{tier}: model #{model} #{why}; using #{substitute || "the CLI default"}"
        )

        substitute
    end
  end

  # Computed once per `put_active/2`: it reads the codex home and, on the
  # ChatGPT backend, the account's quota snapshot.
  defp validation_context do
    case Process.get(@pdict_context_key) do
      nil ->
        ctx = ModelCatalog.context(Process.get(@pdict_workspace_key), api_key_configured?())
        Process.put(@pdict_context_key, ctx)
        ctx

      ctx ->
        ctx
    end
  end

  # ---- Internals --------------------------------------------------------

  defp ambient_api_key, do: System.get_env("OPENAI_API_KEY")

  defp resolve_ref(nil, _raw), do: nil
  defp resolve_ref("", _raw), do: nil

  defp resolve_ref(ref, raw) do
    case CredentialsRef.resolve(ref, raw) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp rotate_pick(keys) do
    idx = Process.get(@rotation_key, 0)
    key = Enum.at(keys, rem(idx, length(keys)))
    Process.put(@rotation_key, idx + 1)
    key
  end

  defp list_of_strings(list) when is_list(list),
    do: Enum.filter(list, fn v -> is_binary(v) and v != "" end)

  defp list_of_strings(_), do: []

  defp stringy(nil), do: nil
  defp stringy(v) when is_binary(v) and v != "", do: v
  defp stringy(_), do: nil

  defp stringy_map(nil), do: %{}

  defp stringy_map(m) when is_map(m) do
    for {k, v} <- m, is_binary(k), is_binary(v) and v != "", into: %{}, do: {k, v}
  end

  defp stringy_map(_), do: %{}
end
