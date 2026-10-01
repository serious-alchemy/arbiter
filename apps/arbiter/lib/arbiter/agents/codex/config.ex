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

  require Ash.Query

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Agents.ProviderConfig
  alias Arbiter.Tasks.Workspace

  # Provider name used to scope per-provider overrides in a shared
  # multi-provider `agent.config` (see `Arbiter.Agents.ProviderConfig`).
  @provider "codex"

  @pdict_key {__MODULE__, :active_workspace_config}
  @pdict_workspace_key {__MODULE__, :active_workspace_id}
  @pdict_detected_plan_key {__MODULE__, :detected_plan}
  @pdict_backend_key {__MODULE__, :detected_backend}
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
  # `Arbiter.Agents.ProviderConfig`). The values are model ids the
  # `codex --model` flag accepts.
  #
  # Economy, standard, and premium tiers have distinct models (gpt-5.6-luna vs
  # gpt-5.6-terra). Flagship shares the premium model since no distinct flagship
  # variant exists on OpenAI's Codex API; it is a routing-tier concept for
  # difficulty-based dispatch and can override per-workspace.
  #
  # These defaults are plan-aware: free-tier accounts (limited to gpt-5.4-mini
  # and gpt-5.5) receive free-tier models; paid-tier and enterprise accounts
  # receive gpt-5.6-luna and gpt-5.6-terra. The plan type is determined by
  # reading the workspace's provider account's plan field.
  #
  # Non-OpenAI backends (e.g., Codex+Ollama) are not forced onto OpenAI model
  # names; they override via agent.config["codex"]["tier_models"].
  @default_tier_models_paid %{
    "economy" => "gpt-5.6-luna",
    "standard" => "gpt-5.6-terra",
    "premium" => "gpt-5.6-terra",
    "flagship" => "gpt-5.6-terra"
  }

  @default_tier_models_free %{
    "economy" => "gpt-5.4-mini",
    "standard" => "gpt-5.5",
    "premium" => "gpt-5.5",
    "flagship" => "gpt-5.5"
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
    :ok
  end

  def put_active(%Workspace{config: config, id: workspace_id} = workspace, role)
      when role in [:agent, :review_agent] do
    raw =
      (get_in(config || %{}, [Atom.to_string(role), "config"]) || %{})
      |> ProviderConfig.apply_overrides(@provider)

    Process.put(@pdict_key, CredentialsRef.embed_secrets(raw, Workspace.secrets_map(workspace)))
    Process.put(@pdict_workspace_key, workspace_id)
    Process.delete(@pdict_detected_plan_key)
    Process.delete(@pdict_backend_key)
    :ok
  end

  def put_active(%{} = raw, _role) do
    Process.put(@pdict_key, ProviderConfig.apply_overrides(raw, @provider))
    :ok
  end

  @doc "Clear the per-process active config."
  @spec clear() :: :ok
  def clear do
    Process.delete(@pdict_key)
    Process.delete(@pdict_workspace_key)
    Process.delete(@pdict_detected_plan_key)
    Process.delete(@pdict_backend_key)
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
  Resolve an abstract `model_tier` (`"economy"` | `"standard"` | `"premium"`)
  to a concrete Codex model name. Returns `nil` for an unknown / nil tier — the
  adapter falls back to the CLI default. Workspace config can override the
  mapping under `agent.config["tier_models"]`.

  Defaults are plan-aware: free-tier accounts receive gpt-5.5, paid-tier and
  enterprise accounts receive gpt-5.6-luna/terra. The plan type is stored in
  the workspace config after auth-probe detection.
  """
  @spec model_for_tier(String.t() | nil) :: String.t() | nil
  def model_for_tier(nil), do: nil
  def model_for_tier(""), do: nil

  def model_for_tier(tier) when is_binary(tier) do
    {:ok, cfg} = resolve()
    overrides = stringy_map(Map.get(cfg.raw, "tier_models"))

    case Map.get(overrides, tier) || Map.get(plan_aware_defaults(cfg.raw), tier) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  def model_for_tier(_), do: nil

  @doc """
  Built-in default tier → model map, adjusted for the account's plan type.

  Attempts to determine the plan from:
  1. `plan_type` in the workspace config (if explicitly set)
  2. The latest CodexQuota for this workspace's provider account (if available)
  3. Defaults to `:paid` if plan cannot be determined
  """
  @spec plan_aware_defaults(map()) :: map()
  def plan_aware_defaults(raw) when is_map(raw) do
    plan = detect_plan(raw)
    if plan == "free", do: @default_tier_models_free, else: @default_tier_models_paid
  end

  # Detect the account's plan by querying the provider account or latest quota.
  # Results are cached in the pdict to avoid repeated database lookups.
  defp detect_plan(_raw) do
    detect_plan_from_quota_cached()
  end

  defp detect_plan_from_quota_cached do
    case Process.get(@pdict_detected_plan_key) do
      {:cached, plan} -> plan
      nil -> detect_plan_from_quota_uncached()
    end
  end

  defp detect_plan_from_quota_uncached do
    plan = detect_plan_from_quota()
    Process.put(@pdict_detected_plan_key, {:cached, plan})
    plan
  end

  # Try to detect plan from the provider account or latest CodexQuota
  defp detect_plan_from_quota do
    with workspace_id when not is_nil(workspace_id) <- Process.get(@pdict_workspace_key),
         {:ok, workspace} <- fetch_workspace(workspace_id),
         provider_acct_id <- get_provider_account_id(workspace),
         provider_acct_id when not is_nil(provider_acct_id) <- provider_acct_id do
      # Try the provider account's plan field first
      case Arbiter.Accounts.ProviderAccount |> Ash.get(provider_acct_id) do
        {:ok, acct} when is_binary(acct.plan) and acct.plan != "" ->
          acct.plan

        _ ->
          # Fall back to latest quota if account plan is not set
          case fetch_latest_quota(provider_acct_id) do
            {:ok, quota} when is_binary(quota.plan) and quota.plan != "" -> quota.plan
            _ -> nil
          end
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_workspace(ws_id) do
    case Workspace |> Ash.Query.filter(id == ^ws_id) |> Ash.read_one() do
      {:ok, workspace} -> {:ok, workspace}
      _ -> :error
    end
  end

  defp get_provider_account_id(workspace) do
    # Query WorkspaceProviderAccount to find the codex account for this workspace
    case Arbiter.Accounts.WorkspaceProviderAccount
         |> Ash.Query.filter(workspace_id == ^workspace.id and provider == :codex)
         |> Ash.Query.load(:provider_account)
         |> Ash.read_one() do
      {:ok, wpa} when not is_nil(wpa) -> wpa.provider_account_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_latest_quota(provider_acct_id) do
    case Arbiter.Quota.CodexQuota
         |> Ash.Query.filter(provider_account_id == ^provider_acct_id)
         |> Ash.Query.sort(captured_at: :desc)
         |> Ash.Query.limit(1)
         |> Ash.read_one() do
      {:ok, quota} -> {:ok, quota}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Built-in default tier → model map for paid-tier accounts (testing / introspection)."
  def default_tier_models, do: @default_tier_models_paid

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
