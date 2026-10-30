defmodule Arbiter.MCP.AcceptanceLintToolsTest do
  @moduledoc "#1146: `ticket_create` / `ticket_update` lint acceptance lines; `no_lint` silences."
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @bad "- `mix test` passes\n- After deploy, the dashboard shows the metric"

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "lint-tools-ws", prefix: "ltw"})
    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
    %{task: task, scope: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  test "ticket_create warns, naming the line and deployment_notes", ctx do
    assert {:ok, data} =
             Tools.task_create(ctx.scope, %{
               "title" => "lint me",
               "issue_type" => "feature",
               "acceptance" => @bad
             })

    assert [w] = data.warnings
    assert w =~ "After deploy, the dashboard shows the metric"
    assert w =~ "deployment_notes"
  end

  test "ticket_create no_lint suppresses", ctx do
    assert {:ok, data} =
             Tools.task_create(ctx.scope, %{
               "title" => "lint me",
               "acceptance" => @bad,
               "no_lint" => true
             })

    refute Map.has_key?(data, :warnings)
  end

  test "ticket_update warns, and no_lint suppresses", ctx do
    assert {:ok, data} =
             Tools.task_update(ctx.scope, %{"id" => ctx.task.id, "acceptance" => @bad})

    assert [w] = data.warnings
    assert w =~ "deployment_notes"

    assert {:ok, data} =
             Tools.task_update(ctx.scope, %{
               "id" => ctx.task.id,
               "acceptance" => @bad,
               "no_lint" => true
             })

    refute Map.has_key?(data, :warnings)
  end

  test "ticket_update without acceptance does not lint", ctx do
    assert {:ok, data} = Tools.task_update(ctx.scope, %{"id" => ctx.task.id, "notes" => "n"})
    refute Map.has_key?(data, :warnings)
  end
end
