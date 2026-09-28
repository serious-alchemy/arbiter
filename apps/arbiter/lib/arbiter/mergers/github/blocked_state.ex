defmodule Arbiter.Mergers.Github.BlockedState do
  @moduledoc """
  Explains *why* GitHub reports a PR's merge state as `blocked` (bd-ati3cp /
  #2149).

  `mergeable_state: "blocked"` means some branch rule is unmet, and nothing
  more: a required status check that is still running blocks a PR exactly as a
  missing required review does. `Arbiter.Mergers.Github` used to read the bare
  state as a review block, so on a repo whose ruleset required status checks
  (and 0 approvals) every fleet-authored PR the Watchdog polled mid-CI parked
  as `:needs_nonauthor_approval`.

  This module reads the forge's own signals instead, fetched by the adapter:

    * the PR's GraphQL `reviewDecision` plus its head commit's status-check
      rollup (each context's `isRequired`) — covers both rulesets and classic
      branch protection;
    * the branch's effective rules (`GET /repos/{o}/{r}/rules/branches/{b}`) —
      rulesets only; used to name a non-review block, and as the review
      source when GraphQL can't be read.

  Pure: the adapter does the HTTP, and passes the rules lookup as a thunk so it
  is only made when the rollup and `reviewDecision` don't already settle it.
  """

  @typedoc "The GraphQL read: `reviewDecision` + rollup contexts, or `:error`."
  @type signals :: {:ok, %{review_decision: String.t() | nil, contexts: [map()]}} | :error

  @typedoc "The branch rules read, or `:error`."
  @type rules :: {:ok, [map()]} | :error

  @type verdict ::
          :pending
          | :review_required
          | :changes_requested
          | {:blocked_other, String.t() | nil}
          | :unknown

  # Rule types that never hold an open PR's merge state at "blocked", or that
  # are described separately (`required_status_checks` by the checks it is
  # still missing, `pull_request` by its non-review parameters).
  @unnamed_rule_types ~w(deletion non_fast_forward creation required_linear_history
                         required_status_checks pull_request)

  @successful_check_run_conclusions ["SUCCESS", "NEUTRAL", "SKIPPED"]
  @unsettled_status_context_states ["PENDING", "EXPECTED"]

  @doc """
  Classify a `blocked` PR.

    * `:pending` — a required check has not concluded yet (running, or not
      reported while CI has not started). Not a block: keep polling.
    * `:review_required` — the PR's review policy demands an approval it
      doesn't have (`reviewDecision: REVIEW_REQUIRED`, or, without GraphQL, a
      `pull_request` rule requiring approvals on an unapproved PR).
    * `:changes_requested` — `reviewDecision: CHANGES_REQUESTED`.
    * `{:blocked_other, detail}` — some other rule; `detail` names it (nil when
      nothing nameable was found, e.g. classic protection's own rules).
    * `:unknown` — neither signal could be read.
  """
  @spec classify(signals(), (-> rules()), atom() | nil, boolean()) :: verdict()
  def classify(signals, rules_fun, pipeline, approved) when is_function(rules_fun, 0) do
    contexts = contexts(signals)

    cond do
      Enum.any?(contexts, &required_unsettled?/1) -> :pending
      review_decision(signals) == "REVIEW_REQUIRED" -> :review_required
      review_decision(signals) == "CHANGES_REQUESTED" -> :changes_requested
      true -> classify_rules(signals, rules_fun.(), pipeline, approved)
    end
  end

  defp classify_rules(:error, :error, _pipeline, _approved), do: :unknown

  defp classify_rules(signals, rules, pipeline, approved) do
    rules = if match?({:ok, list} when is_list(list), rules), do: elem(rules, 1), else: []
    missing = unsatisfied_checks(signals, rules)

    cond do
      signals == :error and approvals_required?(rules) and not approved -> :review_required
      missing != [] and pipeline == :not_started -> :pending
      true -> {:blocked_other, describe(rules, missing)}
    end
  end

  defp contexts({:ok, %{contexts: contexts}}) when is_list(contexts),
    do: Enum.filter(contexts, &is_map/1)

  defp contexts(_), do: []

  defp review_decision({:ok, %{review_decision: decision}}), do: decision
  defp review_decision(_), do: nil

  defp required_unsettled?(%{"isRequired" => true, "__typename" => "CheckRun"} = ctx),
    do: Map.get(ctx, "status") != "COMPLETED"

  defp required_unsettled?(%{"isRequired" => true, "__typename" => "StatusContext"} = ctx),
    do: Map.get(ctx, "state") in @unsettled_status_context_states

  defp required_unsettled?(_), do: false

  defp approvals_required?(rules) do
    Enum.any?(rules, fn rule ->
      Map.get(rule, "type") == "pull_request" and
        (get_in(rule, ["parameters", "required_approving_review_count"]) || 0) > 0
    end)
  end

  # Required checks that have not passed: those a rule requires that the
  # rollup doesn't show as successful, plus rollup contexts flagged required
  # (which also covers classic branch protection) that settled unsuccessfully.
  # Unknowable without the rollup, so none are claimed then.
  defp unsatisfied_checks(:error, _rules), do: []

  defp unsatisfied_checks(signals, rules) do
    contexts = contexts(signals)
    passed = for ctx <- contexts, successful?(ctx), do: context_name(ctx)

    required_by_rules =
      for %{"type" => "required_status_checks"} = rule <- rules,
          check <- List.wrap(get_in(rule, ["parameters", "required_status_checks"])),
          is_map(check),
          name = Map.get(check, "context"),
          is_binary(name),
          do: name

    failed_required =
      for %{"isRequired" => true} = ctx <- contexts, not successful?(ctx), do: context_name(ctx)

    (Enum.reject(required_by_rules, &(&1 in passed)) ++ failed_required)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp successful?(%{"__typename" => "CheckRun"} = ctx),
    do:
      Map.get(ctx, "status") == "COMPLETED" and
        Map.get(ctx, "conclusion") in @successful_check_run_conclusions

  defp successful?(%{"__typename" => "StatusContext"} = ctx),
    do: Map.get(ctx, "state") == "SUCCESS"

  defp successful?(_), do: false

  defp context_name(%{"__typename" => "StatusContext"} = ctx), do: Map.get(ctx, "context")
  defp context_name(ctx), do: Map.get(ctx, "name")

  defp describe(rules, missing) do
    checks =
      if missing == [], do: [], else: ["required_status_checks (#{Enum.join(missing, ", ")})"]

    (checks ++ Enum.flat_map(rules, &describe_rule/1))
    |> Enum.uniq()
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  # A `pull_request` rule's approval count is already settled by the time this
  # runs (`reviewDecision` would have said REVIEW_REQUIRED), so only its
  # conversation-resolution requirement can still be what blocks.
  defp describe_rule(%{"type" => "pull_request"} = rule) do
    if get_in(rule, ["parameters", "required_review_thread_resolution"]) == true,
      do: ["pull_request (required_review_thread_resolution)"],
      else: []
  end

  defp describe_rule(%{"type" => "required_deployments"} = rule) do
    case List.wrap(get_in(rule, ["parameters", "required_deployment_environments"])) do
      [] -> ["required_deployments"]
      envs -> ["required_deployments (#{Enum.join(envs, ", ")})"]
    end
  end

  defp describe_rule(%{"type" => type}) when is_binary(type) and type not in @unnamed_rule_types,
    do: [type]

  defp describe_rule(_), do: []
end
