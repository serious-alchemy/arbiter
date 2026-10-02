defmodule Arbiter.MCP.ProviderConstraintToolsTest do
  @moduledoc """
  bd-13pqcp: `ticket_create` / `ticket_update` carry the per-ticket provider
  constraint; it is coordinator/operator authority, so a worker token (no such
  tools) and a refine token (not a writable field) are refused.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "pc-tools-ws", prefix: "pct"})
    {:ok, task} = Ash.create(Issue, %{title: "the bound task", workspace_id: ws.id})

    %{
      ws: ws,
      task: task,
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true},
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id, repo: "shipyard"},
      refine: %Scope{tier: :refine, workspace_id: ws.id, task_id: task.id, issue_id: task.id}
    }
  end

  test "ticket_create sets an exclude constraint, canonicalized", ctx do
    assert {:ok, data} =
             Tools.task_create(ctx.coordinator, %{
               "title" => "no agy",
               "provider_constraint" => %{"exclude" => ["agy"]}
             })

    assert Ash.get!(Issue, data.id).provider_constraint == %{"exclude" => ["gemini"]}
  end

  test "ticket_update sets, changes and clears it; ticket_show reports it", ctx do
    assert {:ok, _} =
             Tools.task_update(ctx.coordinator, %{
               "id" => ctx.task.id,
               "provider_constraint" => %{"require" => ["claude", "codex"]}
             })

    assert Ash.get!(Issue, ctx.task.id).provider_constraint ==
             %{"require" => ["claude", "codex"]}

    assert {:ok, shown} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => true})
    assert shown.provider_constraint == %{"require" => ["claude", "codex"]}

    assert {:ok, _} =
             Tools.task_update(ctx.coordinator, %{
               "id" => ctx.task.id,
               "provider_constraint" => nil
             })

    assert Ash.get!(Issue, ctx.task.id).provider_constraint == nil
  end

  test "a bad constraint is an invalid-argument error and writes nothing", ctx do
    for bad <- [
          %{"require" => ["nope"]},
          %{"require" => ["claude"], "exclude" => ["codex"]},
          "claude"
        ] do
      assert {:error, {:invalid, _}} =
               Tools.task_update(ctx.coordinator, %{
                 "id" => ctx.task.id,
                 "provider_constraint" => bad
               })
    end

    assert Ash.get!(Issue, ctx.task.id).provider_constraint == nil
  end

  test "a worker token is refused ticket_create and ticket_update", ctx do
    for {tool, args} <- [
          {"ticket_create",
           %{"title" => "x", "provider_constraint" => %{"exclude" => ["claude"]}}},
          {"ticket_update",
           %{"id" => ctx.task.id, "provider_constraint" => %{"exclude" => ["claude"]}}}
        ] do
      assert {:rpc_error, -32_003, message} = Catalog.call(ctx.worker, tool, args)
      assert message =~ "not permitted"
    end

    assert Ash.get!(Issue, ctx.task.id).provider_constraint == nil
  end

  test "ticket_update_progress ignores the field for a worker — it is not a progress field",
       ctx do
    assert {:error, {:invalid, _}} =
             Tools.task_update_progress(ctx.worker, %{
               "provider_constraint" => %{"exclude" => ["claude"]}
             })

    assert Ash.get!(Issue, ctx.task.id).provider_constraint == nil
  end

  test "a refine token may not write it, on update or create", ctx do
    assert {:rpc_error, -32_003, message} =
             Catalog.call(ctx.refine, "ticket_update", %{
               "id" => ctx.task.id,
               "provider_constraint" => %{"exclude" => ["claude"]}
             })

    assert message =~ "provider_constraint"

    assert {:error, {:unauthorized, create_message}} =
             Tools.task_create(ctx.refine, %{
               "title" => "child",
               "provider_constraint" => %{"exclude" => ["claude"]}
             })

    assert create_message =~ "provider_constraint"
    assert Ash.get!(Issue, ctx.task.id).provider_constraint == nil
  end
end
