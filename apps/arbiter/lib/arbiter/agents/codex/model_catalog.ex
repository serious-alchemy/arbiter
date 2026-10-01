defmodule Arbiter.Agents.Codex.ModelCatalog do
  @moduledoc """
  Pre-flight model validation for the Codex adapter (bd-2s755v).

  A Codex tier map is only useful if every model in it is one the account can
  actually call. On a ChatGPT *free* account (probed for bd-7tgosa) the old
  built-ins failed before any work started:

    * `gpt-5.4-mini`, `gpt-5-codex`, `gpt-5-codex-mini` → 400 "The '<m>' model
      is not supported when using Codex with a ChatGPT account."
    * `gpt-5.5` → 404 "The model `gpt-5.5` does not exist or you do not have
      access to it" — even though `models_cache.json` lists it.

  Three inputs decide whether a model is usable, all read from where the
  `codex` CLI itself keeps them:

    * **Backend** (`backend/2`). Only the ChatGPT backend is validated. A
      custom `model_provider` (Ollama, any other Responses-API server) and an
      API-key backend have their own model namespaces, so nothing here
      applies to them.
    * **Catalog** (`read/2`). `$CODEX_HOME/models_cache.json`, which the CLI
      fetches for the logged-in account. A model absent from a fresh catalog
      is rejected. A missing or stale catalog proves nothing; the first
      turn's 400/404 is then classified as `:model_unavailable` by
      `Arbiter.Worker.StopReason`.
    * **Plan** (`plan/1`). The `plan` on the account's stored
      `Arbiter.Quota.CodexQuota` snapshot. It catches models the catalog
      lists but the plan cannot call (`@unavailable_by_plan`).
  """

  alias Arbiter.Quota

  @cache_file "models_cache.json"
  @stale_after_days 7

  # Models the catalog lists that a plan still cannot call, from the
  # bd-7tgosa free-tier probes.
  @unavailable_by_plan %{"free" => ["gpt-5.5"]}

  @type catalog :: %{slugs: [String.t()], listed: [String.t()], fetched_at: DateTime.t()}
  @type backend :: :chatgpt | :openai_api | :custom | :unknown
  @type context :: %{
          backend: backend(),
          catalog: {:ok, catalog()} | {:error, :missing | :invalid | :stale},
          plan: String.t() | nil
        }

  @doc "The codex home the CLI reads: test/app config, then `$CODEX_HOME`, then `~/.codex`."
  @spec codex_home() :: String.t()
  def codex_home do
    configured = Keyword.get(Application.get_env(:arbiter, :codex_model_catalog, []), :codex_home)

    case configured || System.get_env("CODEX_HOME") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.expand("~/.codex")
    end
  end

  @doc """
  Read `models_cache.json` under `home`. `slugs` is every model in it
  (hidden ones included — they are callable); `listed` is the
  `visibility: "list"` ones ordered by the CLI's own `priority`, the order a
  fallback is picked in.
  """
  @spec read(String.t(), DateTime.t()) ::
          {:ok, catalog()} | {:error, :missing | :invalid | :stale}
  def read(home, now \\ DateTime.utc_now()) do
    with {:ok, body} <- read_file(Path.join(home, @cache_file)),
         {:ok, %{"models" => models} = decoded} when is_list(models) <- Jason.decode(body),
         {:ok, fetched_at, _} <- DateTime.from_iso8601(to_string(decoded["fetched_at"])) do
      if DateTime.diff(now, fetched_at, :day) > @stale_after_days do
        {:error, :stale}
      else
        {:ok, to_catalog(models, fetched_at)}
      end
    else
      {:error, :missing} -> {:error, :missing}
      _ -> {:error, :invalid}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, _} -> {:error, :missing}
    end
  end

  defp to_catalog(models, fetched_at) do
    models = Enum.filter(models, &(is_map(&1) and is_binary(&1["slug"])))

    listed =
      models
      |> Enum.filter(&(&1["visibility"] == "list"))
      |> Enum.sort_by(&(&1["priority"] || 1_000_000))
      |> Enum.map(& &1["slug"])

    %{slugs: Enum.map(models, & &1["slug"]), listed: listed, fetched_at: fetched_at}
  end

  @doc """
  Which backend the CLI under `home` talks to. `api_key?` is whether Arbiter
  exports an `OPENAI_API_KEY` to the spawn (the same test the adapter's
  `auth_probe/1` uses to skip the ChatGPT usage probe).
  """
  @spec backend(String.t(), boolean()) :: backend()
  def backend(home, api_key?) do
    cond do
      custom_provider?(home) -> :custom
      api_key? -> :openai_api
      auth_mode(home) == "chatgpt" -> :chatgpt
      auth_mode(home) == "apikey" -> :openai_api
      true -> :unknown
    end
  end

  # Only a top-level `model_provider` (before the first `[table]`) selects the
  # provider; one inside `[profiles.x]` applies only under `--profile x`.
  defp custom_provider?(home) do
    case File.read(Path.join(home, "config.toml")) do
      {:ok, toml} ->
        toml
        |> String.split("\n")
        |> Enum.take_while(&(not String.starts_with?(String.trim_leading(&1), "[")))
        |> Enum.find_value(fn line ->
          case Regex.run(~r/^\s*model_provider\s*=\s*["']([^"']+)["']/, line) do
            [_, provider] -> provider
            _ -> nil
          end
        end)
        |> case do
          nil -> false
          "openai" -> false
          _ -> true
        end

      {:error, _} ->
        false
    end
  end

  defp auth_mode(home) do
    with {:ok, body} <- File.read(Path.join(home, "auth.json")),
         {:ok, %{"auth_mode" => mode}} when is_binary(mode) <- Jason.decode(body) do
      mode
    else
      _ -> nil
    end
  end

  @doc "The plan on the latest stored Codex quota snapshot for `workspace_id`'s account."
  @spec plan(String.t() | nil) :: String.t() | nil
  def plan(workspace_id) when is_binary(workspace_id) do
    case Quota.Codex.latest(Quota.account_id(workspace_id, :codex)) do
      %{plan: plan} when is_binary(plan) and plan != "" -> plan
      _ -> nil
    end
  end

  def plan(_), do: nil

  @doc "Gather the validation inputs for `workspace_id` (nil for a bare config map)."
  @spec context(String.t() | nil, boolean()) :: context()
  def context(workspace_id, api_key?) do
    home = codex_home()

    case backend(home, api_key?) do
      :chatgpt -> %{backend: :chatgpt, catalog: read(home), plan: plan(workspace_id)}
      other -> %{backend: other, catalog: {:error, :missing}, plan: nil}
    end
  end

  @doc "Is `model` usable under `ctx`? Anything off the ChatGPT backend is."
  @spec check(String.t(), context()) :: :ok | {:error, String.t()}
  def check(model, %{backend: :chatgpt} = ctx) do
    cond do
      model in Map.get(@unavailable_by_plan, ctx.plan, []) ->
        {:error, "not available on the Codex #{ctx.plan} plan"}

      match?({:ok, _}, ctx.catalog) and model not in elem(ctx.catalog, 1).slugs ->
        {:error, "not in this account's #{@cache_file}"}

      true ->
        :ok
    end
  end

  def check(_model, _ctx), do: :ok

  @doc """
  `model` when `check/2` accepts it, else the first usable of `preferred`
  then the catalog's listed models; nil when nothing is usable.
  """
  @spec usable(String.t(), [String.t()], context()) :: String.t() | nil
  def usable(model, preferred, ctx) do
    listed =
      case ctx.catalog do
        {:ok, catalog} -> catalog.listed
        _ -> []
      end

    Enum.find([model | preferred] ++ listed, &(check(&1, ctx) == :ok))
  end
end
