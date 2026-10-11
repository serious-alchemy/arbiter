defmodule Arbiter.Loop.Replay.PromptTest do
  @moduledoc """
  bd-c7lx65 (R15): the replayed model gets the ticket and the live work
  prompt's operating rules, never the ticket's id or PR; the scoring reviewer
  gets the live ReviewGate prompt, pointed at the replay's base and never at
  the merged PR.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Replay.Prompt
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.PromptBuilder

  @base String.duplicate("b", 40)

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "replay-prompt-#{System.unique_integer([:positive])}"})

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Add the feature",
        description: "Feature.answer/0 should return 42.",
        acceptance: "- Feature.answer/0 returns 42",
        difficulty: 2,
        workspace_id: ws.id
      })

    subject = %{
      task_id: issue.id,
      issue: issue,
      workspace: ws,
      base_sha: @base,
      target_branch: "main"
    }

    %{subject: subject}
  end

  describe "implement/2" do
    test "the ticket, the base, and the no-remote rule", %{subject: subject} do
      prompt = Prompt.implement(subject, :claude)

      assert prompt =~ "Title: Add the feature"
      assert prompt =~ "Feature.answer/0 should return 42."
      assert prompt =~ "- Feature.answer/0 returns 42"
      assert prompt =~ @base
      assert prompt =~ "branch `work`"
      assert prompt =~ "no remote"
      assert prompt =~ "arb done"
    end

    test "the live work prompt's async-tools rules, for the replayed model's adapter",
         %{subject: subject} do
      block =
        PromptBuilder.async_tools_section(
          Arbiter.Agents.Codex,
          "`arb done`",
          "the work is incomplete until every tool you launched has\nfinished and you have read its result"
        )

      assert Prompt.implement(subject, :codex) =~ block
    end

    test "names neither the ticket nor a PR", %{subject: subject} do
      prompt = Prompt.implement(subject, :claude)

      refute prompt =~ subject.task_id
      refute prompt =~ "pull/"
      refute prompt =~ "replay"
    end
  end

  describe "review/2" do
    test "the live ReviewGate prompt, diffing against the replay's base", %{subject: subject} do
      prompt = Prompt.review(subject, :claude)

      assert prompt =~ "You are a REVIEWER worker"
      assert prompt =~ "- Feature.answer/0 returns 42"
      assert prompt =~ "git diff #{@base}..HEAD"
      assert prompt =~ "VERDICT: APPROVE"
      assert prompt =~ "[NOT MET]"
    end

    test "never points the reviewer at the merged PR", %{subject: subject} do
      Arbiter.Repo.query!("UPDATE issues SET pr_ref = '7' WHERE id = ?1", [subject.task_id])

      prompt = Prompt.review(subject, :claude)

      refute prompt =~ "gh pr"
      refute prompt =~ "PR #7"
    end
  end
end
