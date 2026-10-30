defmodule Arbiter.Worker.ReviewGateMrBriefTest do
  @moduledoc "#1146: the reviewer prompt carries the MR/PR description + pipeline data."
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.ReviewGate

  defmodule GitHubStub do
    def get(_), do: {:ok, %{body: "GH body: loop 50/50 green", pipeline: "failed"}}

    def failing_check_logs(_),
      do: {:ok, [%{name: "gh-job", summary: "GH-LOG-TAIL", conclusion: "failure"}]}
  end

  defmodule GitLabStub do
    def get(_), do: {:ok, %{body: "GL description", pipeline: "success"}}
    def failing_check_logs(_), do: {:ok, []}
  end

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "rg-brief", prefix: "rgb"})

    {:ok, t} =
      Ash.create(Issue, %{
        title: "t",
        workspace_id: ws.id,
        acceptance: "- x",
        issue_type: :feature
      })

    state = %{
      task_id: t.id,
      workspace_id: ws.id,
      branch: "feature/rev",
      target_branch: "main",
      worktree_path: nil,
      round: 1,
      head_sha: nil,
      base_sha: "abc1234"
    }

    {:ok, state: state}
  end

  test "GitHub stub: description, pipeline and failed-job tail are in the brief", %{state: s} do
    prompt = ReviewGate.review_prompt(Map.merge(s, %{pr_ref: "o/r#1", ci_adapter: GitHubStub}))
    assert prompt =~ "GH body: loop 50/50 green"
    assert prompt =~ "pipeline: failed"
    assert prompt =~ "gh-job"
    assert prompt =~ "GH-LOG-TAIL"
  end

  test "GitLab stub: description and pipeline status", %{state: s} do
    prompt = ReviewGate.review_prompt(Map.merge(s, %{pr_ref: "42", ci_adapter: GitLabStub}))
    assert prompt =~ "GL description"
    assert prompt =~ "pipeline: success"
  end

  test "prompt tells the reviewer to check MR description and pipeline before NOT MET",
       %{state: s} do
    prompt = ReviewGate.review_prompt(s)
    assert prompt =~ "Before you mark a"
    assert prompt =~ "MR/PR description and the pipeline data"
    refute prompt =~ "Head pipeline (fetched by Arbiter)"
  end
end
