defmodule Arbiter.Agents.Routing do
  @moduledoc """
  Routing dispatcher: resolves `workspace.config["routing"]["policy"]` to a
  `Arbiter.Agents.Routing.Policy` implementation and delegates `choose/3`.

  Mirrors the trackers / mergers / agents dispatcher shape. Today's
  policies:

    * `:static` (default) — always return the workspace's `agent` config.
    * `:by_priority` — map `task.priority` to a rule under
      `routing.rules["P0".."P4"]`, falling back to the workspace default.
    * `:by_difficulty` — map `task.difficulty` to abstract
      `{model_tier, thinking}` under `routing.rules["D0".."D5"]`, falling
      back to a default mapping. Provider-agnostic: each adapter resolves
      the tier + thinking abstractions to its own knobs.
    * `:by_budget` — `:by_priority` (or `:by_difficulty`, see the
      `routing.base_policy` option) until the ledger says the workspace
      has blown its daily budget; then degrade one tier (premium →
      standard → economy, or Opus → Sonnet → Haiku for legacy
      concrete-model configs).
    * `:round_robin` — cycle through `routing.adapters` per dispatch.

  The dispatch path makes one decision per dispatch (`decide/3`) with a real
  ledger snapshot (`ledger_snapshot/1`), so `:by_budget` and `:round_robin`
  see consistent input. `Arbiter.Agents.Routing.choose/3` returns the same
  `%{type:, config:}` shape regardless of which policy is active.
  """

  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.Routing.{Policy, Static}
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @doc """
  Choose an agent for `task`, handing the policy `ledger_snapshot`.

  A pure dispatch to the workspace's policy: it runs the policy every time it
  is called. Anything on the dispatch path must go through `decide/3` instead,
  so a stateful policy (`:round_robin`'s cursor, a learning policy) is asked
  once per dispatch rather than once per question the dispatch has about it.
  """
  @spec choose(Issue.t(), Workspace.t() | nil, Policy.ledger_snapshot()) :: Policy.choice()
  def choose(%Issue{} = task, workspace, ledger_snapshot) do
    policy = policy_for_workspace(workspace)
    policy.choose(task, workspace, ledger_snapshot)
  end

  @doc """
  `choose/3` with the real ledger snapshot for `workspace` (see
  `ledger_snapshot/1`).
  """
  @spec choose(Issue.t(), Workspace.t() | nil) :: Policy.choice()
  def choose(%Issue{} = task, workspace), do: choose(task, workspace, ledger_snapshot(workspace))

  @doc """
  The one routing decision for a dispatch: the `:routing_choice` already
  carried in `opts` (made once by `Arbiter.Worker.Dispatch` and threaded to
  every step that needs it), else a fresh `choose/2`.
  """
  @spec decide(Issue.t(), Workspace.t() | nil, keyword()) :: Policy.choice()
  def decide(%Issue{} = task, workspace, opts) do
    case Keyword.get(opts, :routing_choice) do
      %{type: _, config: _} = choice -> choice
      _ -> choose(task, workspace)
    end
  end

  @doc """
  The ledger snapshot handed to policies:

    * `:cost_usd_today` — the workspace's priced ledger spend since 00:00 UTC.

  `%{}` when there is no workspace or the ledger cannot be read — a policy
  must treat a missing key as "no usage data" (`:by_budget` then behaves
  exactly like its base policy).
  """
  @spec ledger_snapshot(Workspace.t() | nil) :: Policy.ledger_snapshot()
  def ledger_snapshot(%Workspace{id: id}) when is_binary(id) do
    since = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    %{cost_usd_today: Arbiter.Usage.cost_since(id, since)}
  rescue
    _ -> %{}
  end

  def ledger_snapshot(_workspace), do: %{}

  @doc """
  Returns the policy module for the given workspace, resolved from
  `config["routing"]["policy"]`. Defaults to `Static` when unset or
  malformed.
  """
  @spec policy_for_workspace(Workspace.t() | nil) :: module()
  def policy_for_workspace(nil), do: Static

  def policy_for_workspace(%Workspace{config: config}) do
    case get_in(config || %{}, ["routing", "policy"]) do
      p when is_binary(p) ->
        case Arbiter.Extensions.fetch(:routing_policy, p) do
          {:ok, policy} -> policy
          :error -> Static
        end

      _ ->
        Static
    end
  end

  @doc "Returns the map of policy atom → module."
  @spec policies() :: %{atom() => module()}
  def policies, do: Arbiter.Extensions.registry(:routing_policy)

  @doc "Valid routing policy strings (for workspace-config validation)."
  @spec valid_policies() :: [String.t()]
  def valid_policies, do: Arbiter.Extensions.keys(:routing_policy)

  @doc """
  Default choice — the workspace's worker-agent config, with no per-task
  override applied. Policies fall back to this when they have no rule
  for a task.
  """
  @spec default_choice(Workspace.t() | nil) :: Policy.choice()
  def default_choice(nil), do: %{type: :claude, config: %{}}

  def default_choice(%Workspace{config: config}) do
    raw = get_in(config || %{}, ["agent"]) || %{}

    %{
      type: agent_type_atom(raw),
      config: raw["config"] || %{}
    }
  end

  @doc false
  def agent_type_atom(%{"type" => t}) when is_binary(t) do
    String.to_existing_atom(t)
  rescue
    ArgumentError -> :claude
  end

  def agent_type_atom(%{"type" => list}) when is_list(list) do
    list
    |> Enum.map(&safe_to_atom/1)
    |> Enum.reject(&is_nil/1)
    |> ProviderPool.pick() || :claude
  end

  def agent_type_atom(_), do: :claude

  defp safe_to_atom(t) when is_binary(t) do
    String.to_existing_atom(t)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_atom(_), do: nil
end
