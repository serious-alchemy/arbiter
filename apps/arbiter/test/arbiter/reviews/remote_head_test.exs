defmodule Arbiter.Reviews.RemoteHeadTest do
  @moduledoc """
  bd-6ao60c (#1203): the remote head Arbiter last pushed or observed for a
  ticket's own branch is recorded durably on the ticket, so a later run — on
  any node, after an interrupted pass — can pin its `--force-with-lease` to it.
  """
  use Arbiter.DataCase, async: true

  alias Arbiter.Reviews.RemoteHead
  alias Arbiter.Tasks.{Issue, Workspace}

  @sha1 String.duplicate("a", 40)
  @sha2 String.duplicate("b", 40)

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "remote-head-#{System.unique_integer([:positive])}",
        prefix: "rh"
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "remote head", workspace_id: ws.id, issue_type: :bug})

    %{task: task}
  end

  test "nothing is recorded for a fresh ticket", %{task: task} do
    assert RemoteHead.recorded(task.id, "feature/x") == nil
  end

  test "a recorded head reads back for its branch and the latest write wins", %{task: task} do
    assert :ok = RemoteHead.record(task.id, "feature/x", @sha1)
    assert RemoteHead.recorded(task.id, "feature/x") == @sha1

    assert :ok = RemoteHead.record(task.id, "feature/x", @sha2)
    assert RemoteHead.recorded(task.id, "feature/x") == @sha2
  end

  test "a head recorded for one branch is never offered for another", %{task: task} do
    :ok = RemoteHead.record(task.id, "feature/x", @sha1)
    assert RemoteHead.recorded(task.id, "feature/other") == nil
    assert RemoteHead.recorded(task.id, "main") == nil
  end

  test "recording keeps the rest of the ReviewGate round state", %{task: task} do
    :ok = Arbiter.Tasks.PullRequest.record_review_gate(task.id, %{round: 2})
    :ok = RemoteHead.record(task.id, "feature/x", @sha1)
    assert Ash.get!(Issue, task.id).review_gate_state["round"] == 2
  end

  test "unknown task, non-sha and nil arguments are tolerated" do
    assert :ok = RemoteHead.record("nope-123", "feature/x", @sha1)
    assert RemoteHead.recorded("nope-123", "feature/x") == nil
    assert RemoteHead.recorded(nil, "feature/x") == nil
    assert :ok = RemoteHead.record(nil, "feature/x", @sha1)
    assert :ok = RemoteHead.record("nope-123", "feature/x", "not a sha")
  end
end
