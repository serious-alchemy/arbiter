defmodule Arbiter.Workflows.CIFailureFollowUp do
  @moduledoc """
  Shared "required-check failure triage protocol" instructions text
  (bd-ayetel), folded into the briefing of an author-side follow-up
  `Arbiter.Workflows.PRPatrol` files against a PR whose required check(s)
  settled to a failing conclusion.

  A failing required check must not trigger a blind "push something until
  it's green" response — flaky tests are common (the motivating case:
  apex-client#3260/#3263, both the same flaky `call-details.spec`
  transcript-scroll test), and a real regression needs a minimal fix, not a
  workaround. This mirrors `Arbiter.Workflows.ReviewThreadFollowUp`'s
  reply/resolve/escalate shape, but for the CI-triage decision tree instead
  of the review-thread protocol.
  """

  @doc """
  Renders the protocol instructions block for a follow-up dispatch briefing.

  `check_names` is the list of failing required check names, folded into the
  instructions so the dispatched worker knows exactly which job(s) to triage.
  """
  @spec instructions([String.t()], [map()]) :: String.t()
  def instructions(check_names, failing_checks \\ []) when is_list(check_names) do
    """
    ## Required-check failure triage protocol (bd-ayetel)

    Failing required check(s): #{Enum.join(check_names, ", ")}.
    #{render_logs(failing_checks)}
    A CI failure needs triage BEFORE a fix — do not blindly push a change to
    make it green. For each failing check:

      1. Pull the failed job's logs (e.g. `gh run view --log-failed`, or the
         check's own details URL) and determine which of these applies:
           - FLAKE: re-running the same job with no code change passes →
             re-run the failed job(s) and note in the PR that it was a flake.
           - PRE-EXISTING ON BASE: the failure also reproduces on the PR's
             base branch (unrelated to this diff) → report it (a PR comment
             plus an escalation to the coordinator mailbox) rather than
             trying to fix it here.
           - REAL REGRESSION caused by this diff → make the minimal fix and
             commit + push it (a sandboxed run with no forge credential
             cannot push; Arbiter pushes for it).

      2. Never fabricate a green: do not skip/disable the check, do not claim
         a fix worked without observing the actual re-run result, and do not
         report a check as resolved unless it is actually passing.

    If triage is inconclusive, escalate to the coordinator mailbox naming the
    PR and the failing check(s) rather than guessing.
    """
  end

  @log_limit 4_000

  # The host-fetched failing jobs and their log excerpts (bd-8r2iat), so a
  # worker with no forge CLI or CI tools can still triage.
  defp render_logs([]), do: ""

  defp render_logs(checks) do
    body =
      Enum.map_join(checks, "\n\n", fn check ->
        url = Map.get(check, :url)
        summary = check |> Map.get(:summary, "") |> to_string() |> String.slice(0, @log_limit)
        header = "### #{Map.get(check, :name)}" <> if(url, do: " (#{url})", else: "")
        header <> "\n```\n" <> summary <> "\n```"
      end)

    "\nFailing job logs (fetched by Arbiter; a sandboxed run has no CI tools):\n\n" <>
      body <> "\n"
  end
end
