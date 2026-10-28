defmodule Arbiter.MCP.ToolMarkupGuardTest do
  @moduledoc """
  A worker's tool-call markup leaked into a text field (`qa_notes` ended with
  `</qa_notes>\\n<parameter name="deployment_notes">…`) and the server stored
  it, leaving `deployment_notes` null. The write is refused instead: a stored
  corrupt value would silently satisfy the tracker gate on the wrong field,
  whereas a refusal names the field and lets the caller retry at once.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "guard-#{System.unique_integer([:positive])}", prefix: "tmg"})

    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})

    {:ok,
     task: task,
     worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id},
     coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  @bled "verified in browser, not 58.</qa_notes>\n<parameter name=\"deployment_notes\">None."

  test "ticket_update_progress refuses markup in qa_notes, naming the field", ctx do
    assert {:error, {:invalid, msg}} =
             Tools.task_update_progress(ctx.worker, %{"qa_notes" => @bled})

    assert msg =~ "qa_notes"
    assert msg =~ "tool-call markup"

    {:ok, full} = Tools.task_show(ctx.worker, %{"full" => true})
    assert full.qa_notes in [nil, ""]
  end

  test "ticket_update_progress refuses a bare <parameter name= in deployment_notes", ctx do
    assert {:error, {:invalid, msg}} =
             Tools.task_update_progress(ctx.worker, %{
               "deployment_notes" => "x <parameter name=\"pr_body\">y"
             })

    assert msg =~ "deployment_notes"
  end

  test "ticket_update refuses markup too", ctx do
    assert {:error, {:invalid, msg}} =
             Tools.task_update(ctx.coordinator, %{"id" => ctx.task.id, "notes" => @bled})

    assert msg =~ "notes"
  end

  test "ordinary notes (even mentioning HTML) are still stored", ctx do
    assert {:ok, _} =
             Tools.task_update_progress(ctx.worker, %{
               "qa_notes" => "Check the <div> renders; run `mix test`."
             })
  end
end
