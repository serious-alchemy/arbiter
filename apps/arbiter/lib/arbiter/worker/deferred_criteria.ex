defmodule Arbiter.Worker.DeferredCriteria do
  @moduledoc """
  Approves a review whose ONLY unmet criteria are post-merge, deferring them to
  the ticket's `deployment_notes` instead of parking `review_gate_not_converged`
  (bd-49r9ns, #955).

  ## The gap this closes

  `Arbiter.Worker.CoordinatorOnlyFindings` ends a review loop whose every
  `[NOT MET]` criterion needs the coordinator, but it parks: the coordinator
  must `resolve --accept-as-is` (which only PERMITS a merge) and then
  hand-merge. On 2026-10-18 that happened to three tickets for criteria that
  were simply "observe this after the deploy" — a deterministic chore, so it is
  a gate, not another paragraph of instructions.

  ## The rule (fail-closed)

  `classify/1` returns `{:defer, criteria}` only when ALL of these hold,
  otherwise `:park`:

    * at least one deferred criterion exists: standalone
      (`- [DEFERRED] <criterion> — <why>`, the form the prompts document) or the
      legacy `- [NOT MET] [DEFERRED] ...`;
    * EVERY `[NOT MET]` line carries `tag/0` directly after the outcome
      bracket (any other `[NOT MET]` line parks);
    * no `[NEEDS-COORDINATOR-PREMERGE]` or bare `[NEEDS-COORDINATOR]` tag
      appears anywhere in the findings (a pre-merge coordinator-only criterion
      must still park, and the bare tag does not say which side of the merge it
      is on, so it stays ambiguous → parks);
    * the reviewer did not disclose a `VERIFICATION: PARTIAL` gap.

  `Arbiter.Worker.ReviewGate` additionally requires CI green on the reviewed
  head and `enabled?/2`, and applies the deferral only to a reviewer's
  `VERDICT: APPROVE`. A `REQUEST_CHANGES` still parks as before — the reviewer
  asserted a blocker, and we do not second-guess that.

  ## The setting

  `review.defer_post_merge_criteria` (workspace) with a per-repo override at
  `review.repos.<repo>.defer_post_merge_criteria`. Default on; `false` restores
  the old behaviour (every `[DEFERRED]` line parks like `[NEEDS-COORDINATOR]`).
  """

  alias Arbiter.Tasks.{RepoConfig, Workspace}
  alias Arbiter.Worker.ReviewVerification

  @tag "[DEFERRED]"
  @premerge_tag "[NEEDS-COORDINATOR-PREMERGE]"
  @ambiguous_tag "[NEEDS-COORDINATOR]"
  @setting "defer_post_merge_criteria"

  @not_met_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*NOT\s+MET\s*\]/im
  @deferred_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*NOT\s+MET\s*\]\s*\[DEFERRED\]\s*(?<text>.*)$/i
  # #958: the standalone form the reviewer prompts document (`example_line/2`):
  # `[DEFERRED]` IS the outcome bracket.
  @standalone_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*DEFERRED\s*\]\s*(?<text>.*)$/i
  @park_tag_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*NOT\s+MET\s*\]\s*\[NEEDS-COORDINATOR(?:-PREMERGE)?\]/i

  @doc """
  The one canonical standalone deferred criteria line. Every reviewer prompt
  renders its example from this and `classify/1` parses it, so they can't drift.
  """
  @spec example_line(String.t(), String.t()) :: String.t()
  def example_line(criterion \\ "<criterion>", why \\ "<why it cannot be checked pre-merge>"),
    do: "- #{@tag} #{criterion} — #{why}"

  @doc "Whether `findings` has a standalone `- [DEFERRED] ...` criteria line."
  @spec deferred_present?(String.t() | nil) :: boolean()
  def deferred_present?(findings) when is_binary(findings),
    do: findings |> String.split("\n") |> Enum.any?(&Regex.match?(@standalone_line, &1))

  def deferred_present?(_), do: false

  @doc "The tag a reviewer puts on a `[NOT MET]` criterion that can only be verified after the merge."
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc "The tag for a coordinator-only criterion that must be resolved BEFORE the merge."
  @spec premerge_tag() :: String.t()
  def premerge_tag, do: @premerge_tag

  @doc "The workspace/repo config key (under `review`) that toggles the deferral."
  @spec setting() :: String.t()
  def setting, do: @setting

  @doc """
  Whether `findings` can be approved with its unmet criteria deferred. Returns
  the criterion texts (tag and outcome bracket stripped) or `:park`.
  """
  @spec classify(String.t() | nil) :: {:defer, [String.t()]} | :park
  def classify(findings) when is_binary(findings) do
    unmet = findings |> String.split("\n") |> Enum.filter(&Regex.match?(@not_met_line, &1))
    legacy = Enum.flat_map(unmet, &deferred_text(&1, @deferred_line))

    standalone =
      findings |> String.split("\n") |> Enum.flat_map(&deferred_text(&1, @standalone_line))

    deferred = legacy ++ standalone

    cond do
      deferred == [] -> :park
      length(legacy) != length(unmet) -> :park
      park_tag_on_criterion?(findings) -> :park
      ReviewVerification.partial?(findings) -> :park
      true -> {:defer, deferred}
    end
  end

  def classify(_), do: :park

  # The park tags only count in the CRITERIA outcome position (right after the
  # `[NOT MET]` bracket), not when review prose or a criterion's text merely
  # mentions them.
  defp park_tag_on_criterion?(findings) do
    findings |> String.split("\n") |> Enum.any?(&Regex.match?(@park_tag_line, &1))
  end

  defp deferred_text(line, regex) do
    case Regex.named_captures(regex, line) do
      %{"text" => text} -> [String.trim(text)]
      _ -> []
    end
  end

  @doc """
  Whether deferral is enabled for `repo` of `workspace`. On unless a per-repo
  entry, else the workspace `review` block, sets `defer_post_merge_criteria`
  to `false`. An absent workspace fails closed (off).
  """
  @spec enabled?(Workspace.t() | nil, String.t() | nil) :: boolean()
  def enabled?(%Workspace{config: config}, repo) do
    review = Map.get(config || %{}, "review")

    case setting_value(review, repo) do
      bool when is_boolean(bool) -> bool
      nil -> true
    end
  rescue
    _ -> false
  end

  def enabled?(_workspace, _repo), do: false

  defp setting_value(review, repo) when is_map(review) do
    per_repo =
      with true <- is_binary(repo),
           %{} = repos <- Map.get(review, "repos"),
           %{} = entry <- RepoConfig.find_entry(repos, repo) do
        boolean_setting(Map.get(entry, @setting))
      else
        _ -> nil
      end

    if is_nil(per_repo), do: boolean_setting(Map.get(review, @setting)), else: per_repo
  end

  defp setting_value(_review, _repo), do: nil

  defp boolean_setting(true), do: true
  defp boolean_setting("true"), do: true
  defp boolean_setting(false), do: false
  defp boolean_setting("false"), do: false
  defp boolean_setting(_), do: nil

  @doc """
  `existing` deployment notes with `criteria` appended as a block marked
  "deferred from acceptance by ReviewGate round `round`". A criterion already
  present in `existing` is not repeated, so a re-review never duplicates it.
  """
  @spec append_notes(String.t() | nil, [String.t()], non_neg_integer()) :: String.t()
  def append_notes(existing, criteria, round) do
    existing = existing || ""
    fresh = Enum.reject(criteria, &String.contains?(existing, "- " <> &1))

    if fresh == [] do
      existing
    else
      block =
        "Criteria deferred from acceptance by ReviewGate round #{round} " <>
          "(post-merge; verify after deploy):\n" <>
          Enum.map_join(fresh, "\n", &("- " <> &1))

      if String.trim(existing) == "",
        do: block,
        else: String.trim_trailing(existing) <> "\n\n" <> block
    end
  end

  @doc """
  Appended alongside `ReviewVerification.criteria_block/0` in the review prompt:
  how to tag a `[NOT MET]` criterion that can only be verified after merge.
  """
  @spec prompt_block() :: String.t()
  def prompt_block do
    """
    If a criterion can ONLY be verified after this change is merged and deployed
    (e.g. "observe the live dashboard after a restart") and every other criterion
    is `[MET]`, mark it #{@tag} right after the outcome bracket and give
    `VERDICT: APPROVE`; ReviewGate then merges and records it for post-deploy
    verification:

        #{example_line()}

    (the older `- [NOT MET] #{@tag} <criterion>` form is also accepted).

    If instead a coordinator/operator must act BEFORE the merge (e.g. "register
    a runner first"), tag it #{@premerge_tag}; that parks the review for a human.
    When unsure which side of the merge it is on, use #{@premerge_tag}.
    """
  end
end
