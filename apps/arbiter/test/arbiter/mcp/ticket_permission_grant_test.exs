defmodule Arbiter.MCP.TicketPermissionGrantTest do
  @moduledoc """
  bd-lozakf (G15b): the coordinator-tier `ticket_permission_grant` tool. It
  answers a worker's request through `Arbiter.Tasks.PermissionDecision`, with the
  token's authority: an operator-only binding is refused over MCP (no operator
  proof), and the worker never reaches the tool at all.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Mailbox
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PermissionRequest
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace

  @guardrails %{
    "bindings" => %{
      "prod_read" => %{"grant_by" => "coordinator", "enforced_read_only" => true},
      "prod_ssh" => %{"grant_by" => "operator", "hosts" => ["prod.internal:22"]}
    }
  }

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "tpg-#{System.unique_integer([:positive])}",
        prefix: "tp",
        config: %{"guardrails" => @guardrails}
      })

    {:ok, task} = Ash.create(Issue, %{title: "needs reach", workspace_id: ws.id})
    task = put_state!(task, :active)

    for permission <- ["prod_read", "prod_ssh"],
        do: {:ok, _} = PermissionRequest.submit(task, permission, "need it", actor: "worker")

    %{
      ws: ws,
      task: task,
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id},
      operator: %Scope{tier: :coordinator, workspace_id: ws.id, operator: true},
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id}
    }
  end

  defp grant(scope, args), do: Catalog.call(scope, "ticket_permission_grant", args)

  test "is a coordinator-tier tool: a worker may not call it", ctx do
    assert {:rpc_error, _, message} =
             grant(ctx.worker, %{"id" => ctx.task.id, "permission" => "prod_read"})

    assert message =~ "not permitted"
    assert "prod_read" in Permissions.pending(ctx.task)
  end

  test "a coordinator grants a coordinator-grant permission, recorded with the actor", ctx do
    assert {:ok, data} =
             grant(ctx.coordinator, %{"id" => ctx.task.id, "permission" => "prod_read"})

    assert %{permission: "prod_read", decision: "granted", effect: "next_spawn"} = data
    assert "prod_read" in data.permissions
    assert data.pending_permissions == ["prod_ssh"]

    assert %{event: :granted, actor: actor} =
             ctx.task.id |> Permissions.events() |> List.last()

    assert is_binary(actor)
  end

  test "an operator-only binding is refused over MCP and stays pending", ctx do
    assert {:tool_error, message, "forbidden"} =
             grant(ctx.coordinator, %{"id" => ctx.task.id, "permission" => "prod_ssh"})

    assert message =~ "operator"
    assert message =~ "arb ticket permit"
    assert "prod_ssh" in Permissions.pending(ctx.task)
    refute "prod_ssh" in Ash.get!(Issue, ctx.task.id).permissions
  end

  test "a denial needs a reason and reaches the worker's inbox", ctx do
    assert {:tool_error, message, "validation_error"} =
             grant(ctx.coordinator, %{
               "id" => ctx.task.id,
               "permission" => "prod_read",
               "deny" => true
             })

    assert message =~ "reason"

    assert {:ok, %{decision: "denied"}} =
             grant(ctx.coordinator, %{
               "id" => ctx.task.id,
               "permission" => "prod_read",
               "deny" => true,
               "reason" => "use the dump"
             })

    assert [%{body: body}] = Mailbox.list(to_ref: ctx.task.id, state: :any)
    assert body =~ "use the dump"

    assert %{event: :denied, reason: "use the dump"} =
             ctx.task.id |> Permissions.events() |> List.last()
  end

  test "nothing pending is a conflict", ctx do
    assert {:tool_error, _, "conflict"} =
             grant(ctx.coordinator, %{"id" => ctx.task.id, "permission" => "secrets:other"})
  end
end
