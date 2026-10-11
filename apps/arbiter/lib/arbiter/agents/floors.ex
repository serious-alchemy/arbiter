defmodule Arbiter.Agents.Floors do
  @moduledoc """
  The routing floors (bd-c675ny, R8 of `docs/design/paced-quota-routing-signals.md`
  §6.4): a tier the router may never choose below. A hard gate, ahead of any
  weighting, and operator-owned.

  ## Two floors

    * **The blast-radius floor** — `routing.floors.repos.<repo>.min_model_tier`,
      a minimum tier for a repo whose failures are expensive whatever the
      model's predicted competence (the control plane, a security boundary).
      It is applied to the tier the routing policy chose, *after* a Stage 3
      canary overlay (`Arbiter.Loop.Canary.overlay/3`), so a canaried rule is
      clamped too: `clamp/3`. Nothing the Loop can write reaches it.
    * **The policy floor** — the tier `Routing.choose/3` assigned. The router
      (`Arbiter.Agents.ProviderRouting`) may move work across accounts, but a
      candidate whose model is below that tier is dropped (`below_floor`):
      scoring can't buy quota with quality. It is armed by
      `routing.floors.policy_floor: true`.

    * **Ticket markers (R14)** — `blast:<name>` entries in the ticket's
      `issues.permissions` (G12) raise the same floor for that ticket alone
      (`marker_floor/2`); the higher of repo and marker floor applies. A ticket
      with no marker behaves exactly as before.

  ## The clamp and the canary

  `clamp/3` raises `config["model_tier"]` to the repo floor and, when it did,
  stamps the choice with `floor: %{tier:, from:, repo:}`. `clamped?/1` reads
  that stamp. A clamped dispatch did not get the rule the policy (or the
  canary) assigned it, so `Arbiter.Worker.Dispatch` records it on the run
  (`worker_runs.floor_clamped`) and `Arbiter.Loop.Canary.Metrics` leaves it out
  of both arms.

  ## Off means identical (§9, I1)

  `gate/2` is `nil`, and `clamp/3` returns its input untouched, for every
  workspace with no `routing.floors` config — which is all of them by default.
  A floor can only raise a tier or drop a candidate; it never adds a candidate
  or lowers anything.

  ## Unknown tiers

  The ladder is `economy < standard < premium < flagship`; a workspace may
  define tiers of its own, which have no rank. A tier or a model with no rank
  is never below a floor (open, not closed): a floor is only enforced where
  both sides are known. `flagship` is on the ladder because the live installs
  define it (see `Arbiter.Agents.Routing.ByDifficulty`).
  """

  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Tasks.Workspace

  @ladder ~w(economy standard premium flagship)

  # A marker with no `guardrails.bindings."blast:<name>".min_model_tier`.
  @default_marker_tier "premium"

  @type gate :: %{repo_floor: String.t() | nil, policy?: boolean()}

  @doc "The tier ladder, lowest first."
  @spec ladder() :: [String.t()]
  def ladder, do: @ladder

  @doc """
  The blast-radius floor for `repo`: `routing.floors.repos.<repo>.min_model_tier`.
  `nil` when unset or not on the ladder (a typo cannot silently act as a floor
  at some other tier; `ValidateConfig` refuses it at write time).
  """
  @spec repo_floor(Workspace.t() | nil, String.t() | nil) :: String.t() | nil
  def repo_floor(%Workspace{config: config}, repo) when is_binary(repo) do
    case get_in(config || %{}, ["routing", "floors", "repos", repo, "min_model_tier"]) do
      tier when tier in @ladder -> tier
      _ -> nil
    end
  end

  def repo_floor(_workspace, _repo), do: nil

  @doc """
  The floor gate for a dispatch in `repo`, or `nil` — the whole off path — when
  neither a repo floor nor `routing.floors.policy_floor` is configured.
  """
  @spec gate(Workspace.t() | nil, String.t() | nil, map() | nil) :: gate() | nil
  def gate(workspace, repo, task \\ nil)

  def gate(%Workspace{config: config} = workspace, repo, task) do
    {repo_floor, _source} = effective_repo_floor(workspace, repo, task)
    policy? = get_in(config || %{}, ["routing", "floors", "policy_floor"]) == true

    if repo_floor || policy?, do: %{repo_floor: repo_floor, policy?: policy?}
  end

  def gate(_workspace, _repo, _task), do: nil

  @doc """
  The per-ticket blast-radius floor (R14, §6.4 phase 2): the highest tier among
  the `blast:<name>` markers `task` carries in `issues.permissions`, as
  `{tier, [marker]}`, or `nil` when it carries none.

  A marker's tier is `guardrails.bindings."blast:<name>".min_model_tier` in the
  workspace, else `#{@default_marker_tier}`. A ticket with no marker reads
  nothing from the workspace at all.
  """
  @spec marker_floor(Workspace.t() | nil, map() | nil) :: {String.t(), [String.t()]} | nil
  def marker_floor(workspace, %{permissions: [_ | _] = permissions}) do
    case Enum.filter(permissions, &Vocabulary.blast_marker?/1) do
      [] ->
        nil

      markers ->
        tier = markers |> Enum.map(&marker_tier(workspace, &1)) |> Enum.max_by(&rank/1)
        {tier, Enum.sort(markers)}
    end
  end

  def marker_floor(_workspace, _task), do: nil

  defp marker_tier(workspace, marker) do
    config = (workspace && Map.get(workspace, :config)) || %{}

    case get_in(config, ["guardrails", "bindings", marker, "min_model_tier"]) do
      tier when tier in @ladder -> tier
      _ -> @default_marker_tier
    end
  end

  # The higher of the repo floor and the ticket's marker floor: `{tier, source}`.
  defp effective_repo_floor(workspace, repo, task) do
    marker_tier =
      case marker_floor(workspace, task) do
        {tier, _markers} -> tier
        nil -> nil
      end

    [{repo_floor(workspace, repo), :repo}, {marker_tier, :marker}]
    |> Enum.filter(fn {tier, _} -> is_binary(tier) end)
    |> Enum.max_by(fn {tier, _} -> rank(tier) end, fn -> {nil, nil} end)
  end

  @doc """
  Clamp the tier `choice` carries to the repo's blast-radius floor.

  Returns `choice` unchanged unless its `"model_tier"` is below the floor. When
  it is raised, a pinned `"model"` that is itself below the floor is dropped
  with it (the pin belonged to the lower tier's rule), and the choice is
  stamped `floor: %{tier:, from:, repo:, source:}` (`source` is `:repo` or
  `:marker`). With `task`, its blast-radius markers (`marker_floor/2`) count
  too: the higher floor wins. Idempotent.
  """
  @spec clamp(map(), Workspace.t() | nil, String.t() | nil, map() | nil) :: map()
  def clamp(choice, workspace, repo, task \\ nil)

  def clamp(%{config: %{"model_tier" => tier}} = choice, workspace, repo, task) do
    with {floor, source} when is_binary(floor) <- effective_repo_floor(workspace, repo, task),
         true <- below?(tier, floor) do
      config =
        choice.config
        |> Map.put("model_tier", floor)
        |> drop_low_pin(choice.type, floor)

      choice
      |> Map.put(:config, config)
      |> Map.put(:floor, %{tier: floor, from: tier, repo: repo, source: source})
    else
      _ -> choice
    end
  end

  def clamp(choice, _workspace, _repo, _task), do: choice

  @doc "Whether `choice` was raised by `clamp/3`."
  @spec clamped?(map() | nil) :: boolean()
  def clamped?(%{floor: %{tier: _}}), do: true
  def clamped?(_choice), do: false

  @doc """
  Check one candidate against the gate: `:ok`, or `{:below, detail}` when the
  model it would run is on a known tier below the effective floor.

    * `routed` — the policy's choice (`Routing.decide/3`);
    * `provider` — the candidate's provider (`:claude`, `"codex"` …);
    * `model` — the concrete model it would run (`nil` is unknown, so passes);
    * `agent_config` — `workspace.config["agent"]["config"]`, the tier maps.
  """
  @spec check(gate(), map(), atom() | String.t() | nil, String.t() | nil, map()) ::
          :ok | {:below, String.t()}
  def check(%{} = gate, routed, provider, model, agent_config) do
    with {floor, source} when is_binary(floor) <- effective_floor(gate, routed, agent_config),
         tier when is_binary(tier) <- tier_of(provider, model, agent_config),
         true <- below?(tier, floor) do
      {:below, "needs ≥ #{floor} (#{source} floor); #{provider}/#{model} is #{tier}"}
    else
      _ -> :ok
    end
  end

  @doc """
  The highest ladder tier whose model `provider` resolves to `model` (through
  its adapter's tier map and any workspace override), or `nil` for a model no
  tier maps to.
  """
  @spec tier_of(atom() | String.t() | nil, String.t() | nil, map() | nil) :: String.t() | nil
  def tier_of(provider, model, agent_config) when is_binary(model) and model != "" do
    @ladder
    |> Enum.reverse()
    |> Enum.find(&(model in ModelFamily.models_for_tier(provider, &1, agent_config)))
  end

  def tier_of(_provider, _model, _agent_config), do: nil

  @doc "Whether `tier` is on the ladder strictly below `floor`. Unknown tiers are never below."
  @spec below?(String.t() | nil, String.t() | nil) :: boolean()
  def below?(tier, floor) do
    case {rank(tier), rank(floor)} do
      {t, f} when is_integer(t) and is_integer(f) -> t < f
      _ -> false
    end
  end

  # The higher of the repo floor and (when armed) the policy's own tier — the
  # tier of its pinned model when the rule pins one, else its `model_tier`.
  defp effective_floor(gate, routed, agent_config) do
    [{gate.repo_floor, :repo}, {gate.policy? && policy_tier(routed, agent_config), :policy}]
    |> Enum.filter(fn {tier, _} -> is_binary(tier) and rank(tier) != nil end)
    |> Enum.max_by(fn {tier, _} -> rank(tier) end, fn -> nil end)
  end

  defp policy_tier(%{config: %{"model" => model} = config, type: type}, agent_config)
       when is_binary(model) and model != "" do
    tier_of(type, model, Map.merge(agent_config || %{}, config))
  end

  defp policy_tier(%{config: %{"model_tier" => tier}}, _agent_config), do: tier
  defp policy_tier(_routed, _agent_config), do: nil

  defp drop_low_pin(%{"model" => model} = config, type, floor) when is_binary(model) do
    if below?(tier_of(type, model, config), floor), do: Map.delete(config, "model"), else: config
  end

  defp drop_low_pin(config, _type, _floor), do: config

  defp rank(tier), do: Enum.find_index(@ladder, &(&1 == tier))
end
