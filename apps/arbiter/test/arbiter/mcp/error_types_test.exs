defmodule Arbiter.MCP.ErrorTypesTest do
  @moduledoc """
  bd-5fc29i: an MCP tool refusal carries the `Arbiter.Errors` type — the same
  vocabulary REST's `{error: {type}}` uses — so a client can branch on it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-error-types-#{System.unique_integer([:positive])}",
        prefix: "met#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    %{ws: ws, coordinator: coordinator}
  end

  test "an unknown ticket is not_found", ctx do
    assert {:tool_error, _message, "not_found"} =
             Catalog.call(ctx.coordinator, "ticket_show", %{"id" => "nope-1"})
  end

  test "a bad argument is validation_error", ctx do
    assert {:tool_error, _message, "validation_error"} =
             Catalog.call(ctx.coordinator, "alert_list", %{"kind" => "nope"})
  end

  test "a dispatch refused by the ticket's state is a conflict", ctx do
    {:ok, task} = Ash.create(Issue, %{title: "unrefined", workspace_id: ctx.ws.id})

    assert {:tool_error, _message, "conflict"} =
             Catalog.call(ctx.coordinator, "worker_dispatch", %{
               "task_id" => task.id,
               "repo" => "test/repo",
               "no_agent" => true
             })
  end

  test "a dispatch while migrations are pending is busy", ctx do
    Application.put_env(:arbiter, :migrations_module, Arbiter.Test.PendingMigrations)
    on_exit(fn -> Application.delete_env(:arbiter, :migrations_module) end)

    {:ok, task} = Ash.create(Issue, %{title: "migrating", workspace_id: ctx.ws.id})

    assert {:tool_error, message, "busy"} =
             Catalog.call(ctx.coordinator, "worker_dispatch", %{
               "task_id" => task.id,
               "force" => true,
               "repo" => "test/repo",
               "no_agent" => true
             })

    assert message =~ "pending migration"
  end

  test "a scope violation stays a JSON-RPC error, not a typed tool error" do
    worker = %Scope{tier: :worker, workspace_id: nil, task_id: "x"}
    assert {:rpc_error, _code, _message} = Catalog.call(worker, "worker_dispatch", %{})
  end
end
