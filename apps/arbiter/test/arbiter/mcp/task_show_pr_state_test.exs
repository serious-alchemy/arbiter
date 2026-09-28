defmodule Arbiter.MCP.TaskShowPrStateTest do
  @moduledoc """
  bd-741sid: `task_show` is the coordinator's main surface, and the ticket now
  owns its open PR — so the full view carries the PR's URL, the forge's last
  answer and when it was read, and the `pr_closed` cause, as
  `GET /api/issues/:id` does.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "tspr-#{System.unique_integer([:positive])}", prefix: "tp"})

    {:ok, task} = Ash.create(Issue, %{title: "show my PR", workspace_id: ws.id})
    {:ok, task} = Ash.update(task, %{status: :in_progress})

    %{task: task, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id}}
  end

  test "the full view carries the ticket's PR state", ctx do
    {:ok, _} = Issue.pr_opened(ctx.task.id, "#7", merger_url: "https://forge.test/pull/7")
    :ok = PullRequest.record_merger_status(ctx.task.id, %{status: :open, pipeline: :running})

    assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => true})

    assert %{
             state: "merging",
             pr_ref: "#7",
             merger_url: "https://forge.test/pull/7",
             merger_status: %{"status" => "open", "pipeline" => "running"},
             attention_cause: nil
           } = data

    assert is_binary(data.merger_checked_at)
  end

  test "the full view carries the pr_closed cause", ctx do
    {:ok, _} = Issue.pr_opened(ctx.task.id, "#8")
    {:ok, _} = Issue.pr_closed(ctx.task.id, "#8")

    assert {:ok, data} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => true})

    assert %{state: "active", attention_cause: "pr_closed"} = data
    assert data.attention_detail =~ "#8"
    assert is_binary(data.attention_since)
  end
end
