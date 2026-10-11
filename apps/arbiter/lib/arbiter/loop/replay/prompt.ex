defmodule Arbiter.Loop.Replay.Prompt do
  @moduledoc """
  The two prompts of an offline replay (R15, bd-c7lx65;
  `docs/design/paced-quota-routing-signals.md` §7.2).

    * `implement/2`: the ticket (title, description, acceptance criteria) for
      the replayed model, with the live work prompt's async-tools rules for its
      adapter, and the one thing a replay must add: the checkout has no remote,
      so the work is committed, never pushed. It names neither the ticket's id
      nor its PR, and does not say the work was done before.
    * `review/2`: the live ReviewGate's own reviewer prompt
      (`Arbiter.Worker.ReviewGate.review_prompt/1`), so the verdict and the
      CRITERIA breakdown are asked for exactly as for the round-1 verdicts live
      competence is measured from. It is told to diff against the replay's
      base, and is never given the ticket's PR: that would point the reviewer
      at the merged change (`gh pr diff`), and invite it to post to the forge.
  """

  alias Arbiter.Agents
  alias Arbiter.Loop.Replay.Sandbox
  alias Arbiter.Worker.PromptBuilder
  alias Arbiter.Worker.ReviewGate

  @doc """
  The replayed model's prompt for `subject` (an `Arbiter.Loop.Replay.Subject`),
  run by the `adapter` agent type (`:claude`, `:codex`, `:gemini`, …).
  """
  @spec implement(map(), atom()) :: String.t()
  def implement(subject, adapter) do
    issue = subject.issue

    """
    You are implementing a ticket in the repository checked out in your current
    directory.

    Title: #{issue.title}

    Description:
    #{text(issue.description)}

    Acceptance criteria:
    #{text(issue.acceptance)}

    The checkout is on branch `#{branch(subject)}`, at commit #{subject.base_sha} of
    `#{subject.target_branch}`. Make the change the ticket asks for, run the tests
    that cover it, and commit your work on this branch with git. The checkout has
    no remote: do not push and do not open a pull request; your commits are
    collected from this checkout when you finish. Work only inside it.

    #{async_tools(adapter)}

    When you are done, print `arb done` on a line by itself.
    """
  end

  @doc """
  The scoring reviewer's prompt for `subject`, for a reviewer spawned with the
  `reviewer_adapter` agent type (`:claude`, `:codex`, `:gemini`, …), which
  picks the adapter's own instructions.
  """
  @spec review(map(), atom()) :: String.t()
  def review(subject, reviewer_adapter) do
    ReviewGate.review_prompt(%{
      task_id: subject.task_id,
      branch: branch(subject),
      target_branch: subject.target_branch,
      base_sha: subject.base_sha,
      workspace_id: subject.workspace.id,
      reviewer_provider: reviewer_adapter
    })
  end

  # The live work prompt's async-tools block for this adapter, byte for byte
  # (`PromptBuilder`'s own completion signal and coda): the replayed model works
  # under the same operating rules a dispatch would give it.
  defp async_tools(adapter) do
    PromptBuilder.async_tools_section(
      Map.get(Agents.adapters(), adapter),
      "`arb done`",
      "the work is incomplete until every tool you launched has\nfinished and you have read its result"
    )
  end

  # The branch the checkout is on: the harness records it; the sandbox's by default.
  defp branch(subject), do: Map.get(subject, :branch) || Sandbox.branch()

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "(none)"
      trimmed -> trimmed
    end
  end

  defp text(_value), do: "(none)"
end
