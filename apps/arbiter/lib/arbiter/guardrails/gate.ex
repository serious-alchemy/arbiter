defmodule Arbiter.Guardrails.Gate do
  @moduledoc """
  The guardrail hard gate at a spawn site (G13, bd-atll60;
  `docs/design/guardrail-profiles.md` §8, §9): the DB-facing half of
  `Arbiter.Guardrails.Eligibility`, the way `Arbiter.Worker.Withholding` is of
  `Arbiter.Guardrails.Projection`.

  `ProviderRouting` and `ReviewerRouting` drop an ineligible candidate before
  they rank anything, but routing is not the only way a provider gets picked.
  An explicit `arb dispatch --provider`, a resume's resolution, the legacy
  `agent.type` failover of a workspace not routed by quota, `ProviderRouting`'s
  own `no_candidate` fall-through to the pre-routing provider, the fix-pass and
  conflict-resolver spawns and the ReviewGate's reviewer/implementer rounds all
  name a provider **without** having asked routing. Each of them asks this
  module instead, with the provider and model it is about to spawn, so no
  dispatch path is a way around a tier.

  `check/5` is the final gate, mirroring `Arbiter.Agents.ProviderConstraint.check/2`:
  `:ok`, or `{:error, {:guardrail_ineligible, provider, phrase}}`. `partition/4`
  is the same question over a list of providers (the legacy pool pick).

  ## Unguarded, and fail-closed

  With no subject rule configured every call answers `:ok` without reading the
  ticket: an install that never configures a rule behaves exactly as before.
  With guardrails on, a ticket that cannot be read is **refused**
  (`Arbiter.Worker.Withholding` fails closed the same way): this is a security
  gate, and "I couldn't tell" must not mean "go ahead".
  """

  alias Arbiter.Accounts.Resolver
  alias Arbiter.Guardrails.Eligibility
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Worker.ReviewGate

  @type role :: Eligibility.role()
  @type refusal :: {:guardrail_ineligible, atom() | String.t() | nil, String.t()}

  @doc "The card / refusal phrase: `held — guardrail (<detail>)`."
  @spec phrase(String.t()) :: String.t()
  def phrase(detail), do: "held — guardrail (#{detail})"

  @doc """
  May `provider` running `model` take `task` (an `Issue`, a task id, or a
  ReviewGate synthetic id) in `workspace`? Options: `:role` (`:implementer`,
  the default, or `:reviewer`), `:repo` (default: the ticket's), `:rules`
  (default: the installation's) and `:account` (default: the workspace's account
  for the provider, which is what holds the data agreement).
  """
  @spec check(
          Issue.t() | String.t() | nil,
          map() | nil,
          atom() | String.t() | nil,
          String.t() | nil,
          keyword()
        ) ::
          :ok | {:error, refusal()}
  def check(task, workspace, provider, model, opts \\ []) do
    case evaluate(task, workspace, provider, model, opts) do
      {:ok, _info} -> :ok
      {:error, detail} -> {:error, {:guardrail_ineligible, provider, phrase(detail)}}
    end
  end

  @doc """
  `check/5`'s verdict with what it learned: `{:ok, %{profile:, permission_fallback:}}`
  (`profile` is `nil` when unguarded) or `{:error, detail}`.
  """
  @spec evaluate(
          Issue.t() | String.t() | nil,
          map() | nil,
          atom() | String.t() | nil,
          String.t() | nil,
          keyword()
        ) ::
          Eligibility.verdict()
  def evaluate(task, workspace, provider, model, opts \\ []) do
    case Keyword.get_lazy(opts, :rules, &Rules.all/0) do
      [] ->
        {:ok, %{profile: nil, permission_fallback: []}}

      rules ->
        case load(task) do
          %Issue{} = issue ->
            judge(issue, workspace, provider, model, rules, opts)

          nil ->
            {:error,
             "#{provider || "provider"}: the ticket could not be read to check its guardrails"}
        end
    end
  end

  defp judge(issue, workspace, provider, model, rules, opts) do
    Eligibility.evaluate(
      %{
        provider: provider,
        model: model,
        role: Keyword.get(opts, :role, :implementer),
        account: Keyword.get_lazy(opts, :account, fn -> account(workspace, provider) end),
        difficulty: issue.difficulty,
        permissions: Permissions.in_force(issue),
        workspace: workspace,
        repo: Keyword.get(opts, :repo) || issue.repo
      },
      rules: rules
    )
  end

  @doc """
  Split `providers` (adapter types) into `{eligible, [{ineligible, detail}]}` for
  `task`, in the order given. `model_fun` maps a provider to the model it would
  run (`nil` for the default). Unguarded, everything is eligible.
  """
  @spec partition(
          Issue.t() | String.t() | nil,
          map() | nil,
          [atom() | String.t()],
          (term() -> String.t() | nil),
          keyword()
        ) ::
          {[atom() | String.t()], [{atom() | String.t(), String.t()}]}
  def partition(task, workspace, providers, model_fun, opts \\ []) do
    results =
      Enum.map(providers, fn provider ->
        {provider, evaluate(task, workspace, provider, model_fun.(provider), opts)}
      end)

    {for({p, {:ok, _}} <- results, do: p), for({p, {:error, detail}} <- results, do: {p, detail})}
  end

  defp load(%Issue{} = issue), do: issue

  defp load(id) when is_binary(id) do
    case Ash.get(Issue, ReviewGate.base_task_id(id)) do
      {:ok, %Issue{} = issue} -> issue
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp load(_), do: nil

  defp account(%{id: ws_id}, provider) when is_binary(ws_id) do
    Resolver.account(ws_id, provider)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp account(_workspace, _provider), do: nil
end
