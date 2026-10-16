defmodule Arbiter.Worker.ReviewGateTrackerSpecTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.ReviewGate

  defp state(task) do
    %{
      task_id: task.id,
      branch: "feature/rev",
      target_branch: "main",
      worktree_path: nil,
      round: 1,
      head_sha: nil,
      base_sha: "abc1234"
    }
  end

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "rg-spec", prefix: "rgs"})
    {:ok, ws: ws}
  end

  defp task(ws, attrs) do
    {:ok, t} =
      Ash.create(
        Issue,
        Map.merge(
          %{
            title: "t",
            description: "The story body",
            workspace_id: ws.id,
            issue_type: :feature
          },
          attrs
        )
      )

    t
  end

  test "tracker-spec waiver tells the reviewer to review against the description", %{ws: ws} do
    t = task(ws, %{acceptance_waived: Issue.tracker_spec_waiver()})
    prompt = ReviewGate.review_prompt(state(t))
    assert prompt =~ "no separate acceptance criteria"
    assert prompt =~ "review against the Description"
  end

  test "an ordinary task gets no such note", %{ws: ws} do
    t = task(ws, %{acceptance: "- [ ] x"})
    refute ReviewGate.review_prompt(state(t)) =~ "review against the Description"

    t2 = task(ws, %{acceptance_waived: "some manual reason"})
    refute ReviewGate.review_prompt(state(t2)) =~ "review against the Description"
  end
end
