defmodule Arbiter.Agents.Gemini.ModelCheck do
  @moduledoc """
  Audits the configured agy tier models against what `agy models` serves
  (bd-7wx2lh), for `GET /api/server/agy_models` (`arb server doctor`) and the
  boot-time warning.

  The audited set is the built-in agy default map plus, for every workspace
  role (`agent`, `review_agent`) that routes to agy, that role's effective map:
  the default with the workspace's `tier_models` override laid over it. A
  problem is one `{tier, model}` agy no longer serves, naming where it comes
  from (`source`: `"default"` or `"override"`), who uses it (`used_by`) and the
  model a spawn would fall back to (`fallback`, see `ModelCatalog.substitute/3`).

  The listing is read fresh (`ModelCatalog.refresh/1`) — a doctor run is
  exactly when an operator wants to know whether the CLI changed under the
  running server. `status` is `:unknown` when the listing cannot be read: the
  check then says so rather than report either "fine" or invented problems.
  """

  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Agents.Gemini.Config
  alias Arbiter.Agents.Gemini.ModelCatalog
  alias Arbiter.Tasks.Workspace

  require Logger

  # ProviderSettings role -> the workspace config key holding that role's agent config.
  @config_keys %{implementer: "agent", reviewer: "review_agent"}

  @type problem :: %{
          tier: String.t(),
          model: String.t(),
          source: String.t(),
          used_by: [String.t()],
          fallback: String.t() | nil
        }

  @type report :: %{
          status: :ok | :missing | :unknown,
          models: [String.t()] | nil,
          problems: [problem()]
        }

  @doc """
  Options: `:workspaces` (default: all), `:probe` (tests; see `ModelCatalog`).
  """
  @spec report(keyword()) :: report()
  def report(opts \\ []) do
    workspaces = Keyword.get_lazy(opts, :workspaces, fn -> Ash.read!(Workspace) end)

    case ModelCatalog.refresh(Keyword.take(opts, [:probe, :now])) do
      :unknown ->
        %{status: :unknown, models: nil, problems: []}

      {:ok, available} ->
        problems = problems(configs(workspaces), available)

        %{
          status: if(problems == [], do: :ok, else: :missing),
          models: available,
          problems: problems
        }
    end
  end

  @doc """
  Log a warning per missing tier model. Called once from the boot sequence so a
  stale map shows up in the server log, not only when someone runs the doctor.
  Never raises.
  """
  @spec warn_at_boot(keyword()) :: :ok
  def warn_at_boot(opts \\ []) do
    for %{tier: tier, model: model, used_by: used_by, fallback: fallback} <-
          report(opts).problems do
      Logger.warning(
        "Arbiter.Agents.Gemini: agy tier #{inspect(tier)} is configured as #{inspect(model)}," <>
          " which `agy models` does not list (used by #{Enum.join(used_by, ", ")});" <>
          " spawns fall back to #{inspect(fallback)}"
      )
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "Arbiter.Agents.Gemini.ModelCheck: boot check failed: #{Exception.message(e)}"
      )

      :ok
  end

  # [{label, tier_models}] — the defaults, then one per workspace role on agy.
  defp configs(workspaces) do
    roles =
      for ws <- workspaces,
          role <- ProviderSettings.roles(),
          uses_agy?(ws, role) do
        key = Map.fetch!(@config_keys, role)
        raw = get_in(ws.config || %{}, [key, "config"]) || %{}
        {"#{ws.name} (#{key})", Config.effective_tier_models(raw, :agy)}
      end

    [{"default", Config.default_tier_models(:agy)} | roles]
  end

  defp uses_agy?(ws, role),
    do: Enum.any?(ProviderSettings.effective(ws, role).candidates, &(&1.agent_type == "gemini"))

  defp problems(configs, available) do
    defaults = Config.default_tier_models(:agy)

    configs
    |> Enum.flat_map(fn {label, tiers} ->
      for {tier, model} <- ModelCatalog.missing(tiers, available) do
        {{tier, model}, label, tiers}
      end
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {{tier, model}, entries} ->
      [{_, _, tiers} | _] = entries

      %{
        tier: tier,
        model: model,
        source: if(Map.get(defaults, tier) == model, do: "default", else: "override"),
        used_by: entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
        fallback: ModelCatalog.substitute(tier, tiers, available)
      }
    end)
    |> Enum.sort_by(&{Enum.find_index(ModelCatalog.ladder(), fn t -> t == &1.tier end), &1.model})
  end
end
