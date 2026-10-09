defmodule Arbiter.Guardrails.Alternatives do
  @moduledoc """
  "Is there a model the guardrails allow for this ticket, and if not, can
  waiting help?" (G13, bd-atll60; `docs/design/guardrail-profiles.md` §5.7).

  Asked by the dispatcher when the provider it was about to run is ineligible
  (`Arbiter.Worker.Dispatch`), and by the board for a card
  (`Arbiter.Board.Snapshot`), so the two never disagree about whether a Ready
  ticket can go.

  `analyse/3` answers one of:

    * `:stale` — an eligible subject is available now (or the caller named the
      provider): nothing is waiting on anything, the pick was just wrong;
    * `{:held, provider, phrase}` — an eligible subject exists but is unavailable
      for a reason that clears (quota, capacity, auth, a pause). `provider` is the
      eligible one the hold should be drained on; `phrase` names both sides, e.g.
      `held — guardrail (eligible: claude:default (quota held: …); ineligible:
      antigravity:default (guardrail ineligible: …))`. **Never a fallback to the
      ineligible one.**
    * `{:none, detail}` — no subject is eligible at all. Not a quota problem, so
      waiting cannot fix it: `detail` says why per subject (`nil` when the
      workspace has no provider to weigh).

  A workspace routed by quota with attached accounts weighs those candidates
  (`ProviderRouting.availability/3`: the same drop reasons the dispatch used);
  every other workspace weighs its `agent.type` pool.
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Guardrails.Gate

  # Drop reasons that clear on their own, so an eligible subject dropped for one
  # is "waiting", not "ruled out".
  @transient ~w(quota_held at_capacity auth_expired circuit_broken paused)

  @type result :: :stale | {:held, atom(), String.t()} | {:none, String.t() | nil}

  @doc """
  Analyse `task` (an `Issue`, a plain map with an `:id`, or an id) in `workspace`.
  Options: `:routing_opts` (handed to `ProviderRouting.availability/3`), `:repo`,
  and `:model_fun` (`provider -> model`, default `:predicted`).
  """
  @spec analyse(map() | String.t(), map() | nil, keyword()) :: result()
  def analyse(task, workspace, opts \\ []) do
    if ProviderRouting.enabled?(workspace),
      do: routed(task, workspace, opts),
      else: pool(task, workspace, opts)
  end

  defp routed(task, workspace, opts) do
    %{available: available, dropped: dropped} =
      ProviderRouting.availability(workspace, task, Keyword.get(opts, :routing_opts, []))

    {ineligible, rest} = Enum.split_with(dropped, &ProviderRouting.guardrail_drop?/1)
    {waiting, _static} = Enum.split_with(rest, &(&1.reason in @transient))

    cond do
      available != [] ->
        :stale

      dropped == [] ->
        pool(task, workspace, opts)

      waiting != [] ->
        hold =
          "eligible: #{Enum.map_join(waiting, ", ", &ProviderRouting.describe_drop/1)}; " <>
            "ineligible: #{Enum.map_join(ineligible, ", ", &ProviderRouting.describe_drop/1)}"

        {:held, String.to_existing_atom(hd(waiting).agent_type), Gate.phrase(hold)}

      true ->
        {:none, Enum.map_join(ineligible ++ rest, "; ", &ProviderRouting.describe_drop/1)}
    end
  end

  defp pool(task, workspace, opts) do
    constraint = ProviderConstraint.from(task)
    providers = ProviderConstraint.filter(constraint, Agents.agent_pool(workspace))
    model_fun = Keyword.get(opts, :model_fun, fn _provider -> :predicted end)

    {eligible, ineligible} =
      Gate.partition(task, workspace, providers, model_fun, Keyword.take(opts, [:repo]))

    cond do
      eligible != [] -> :stale
      ineligible == [] -> {:none, nil}
      true -> {:none, Enum.map_join(ineligible, "; ", fn {p, detail} -> "#{p}: #{detail}" end)}
    end
  end
end
