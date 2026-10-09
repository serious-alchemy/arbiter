defmodule Arbiter.MCP.PermissionToolsTest do
  @moduledoc """
  bd-54m4vv (G12): `ticket_create` / `ticket_update` carry the ticket's
  `permissions`. A coordinator declares them (an operator-grant one is only
  `requested`), the operator's proof makes that declaration in force, and a
  worker or refine token never sets them.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "perm-tools-ws", prefix: "ptw"})
    {:ok, task} = Ash.create(Issue, %{title: "the bound task", workspace_id: ws.id})

    %{
      ws: ws,
      task: task,
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true},
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id, repo: "shipyard"},
      refine: %Scope{tier: :refine, workspace_id: ws.id, task_id: task.id, issue_id: task.id}
    }
  end

  test "ticket_create stores canonical permissions; prod_ssh from a coordinator is requested",
       ctx do
    assert {:ok, data} =
             Tools.task_create(ctx.coordinator, %{
               "title" => "needs reach",
               "permissions" => ["tracker_write", "prod_ssh", "network:API.example.com"]
             })

    issue = Ash.get!(Issue, data.id)

    assert issue.permissions ==
             ["network:api.example.com:443", "prod_ssh", "tracker_write"]

    assert Permissions.pending(issue) == ["prod_ssh"]
  end

  test "ticket_update replaces, adds and removes; ticket_show reports pending", ctx do
    assert {:ok, _} =
             Tools.task_update(ctx.coordinator, %{
               "id" => ctx.task.id,
               "permissions" => ["tracker_write"]
             })

    assert Ash.get!(Issue, ctx.task.id).permissions == ["tracker_write"]

    assert {:ok, _} =
             Tools.task_update(ctx.coordinator, %{
               "id" => ctx.task.id,
               "add_permissions" => ["prod_ssh", "prod_read"],
               "remove_permissions" => ["tracker_write"]
             })

    assert Ash.get!(Issue, ctx.task.id).permissions == ["prod_read", "prod_ssh"]

    assert {:ok, shown} = Tools.task_show(ctx.coordinator, %{"id" => ctx.task.id, "full" => true})
    assert shown.permissions == ["prod_read", "prod_ssh"]
    assert shown.pending_permissions == ["prod_read", "prod_ssh"]
    assert Enum.any?(shown.permission_events, &(&1.permission == "prod_ssh"))
  end

  test "a bad permission is an invalid-argument error and writes nothing", ctx do
    for bad <- [["nope"], "tracker_write", [1]] do
      assert {:error, {:invalid, _}} =
               Tools.task_update(ctx.coordinator, %{"id" => ctx.task.id, "permissions" => bad})
    end

    refute "nope" in Ash.get!(Issue, ctx.task.id).permissions
  end

  test "a worker token is refused ticket_update and a create with permissions", ctx do
    assert {:rpc_error, -32_003, message} =
             Catalog.call(ctx.worker, "ticket_update", %{
               "id" => ctx.task.id,
               "permissions" => ["prod_read"]
             })

    assert message =~ "not permitted"

    assert {:rpc_error, -32_003, message} =
             Catalog.call(ctx.worker, "ticket_create", %{
               "title" => "x",
               "parent_id" => ctx.task.id,
               "permissions" => ["prod_read"]
             })

    assert message =~ "permissions"
    refute "prod_read" in Ash.get!(Issue, ctx.task.id).permissions
  end

  test "a refine token may not write them, on update or create", ctx do
    assert {:rpc_error, -32_003, message} =
             Catalog.call(ctx.refine, "ticket_update", %{
               "id" => ctx.task.id,
               "permissions" => ["prod_read"]
             })

    assert message =~ "permissions"

    assert {:error, {:unauthorized, create_message}} =
             Tools.task_create(ctx.refine, %{"title" => "child", "permissions" => ["prod_read"]})

    assert create_message =~ "permissions"
    refute "prod_read" in Ash.get!(Issue, ctx.task.id).permissions
  end
end
