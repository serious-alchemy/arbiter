defmodule Arbiter.MCP.SelfGrantAuditTest do
  # G17: a worker's attempt to widen its own authority through MCP is refused
  # AND leaves a critical guardrail event.
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Events
  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope

  defp worker_scope(task_id),
    do: %Scope{tier: :worker, task_id: task_id, workspace_id: Ash.UUID.generate()}

  test "a worker writing guardrails config is refused and recorded" do
    scope = worker_scope("bd-sg-mcp")

    assert {:rpc_error, _code, _msg} =
             Catalog.call(scope, "workspace_config_set", %{
               "key" => "guardrails.cap.egress",
               "value" => "open"
             })

    assert [%{kind: :self_grant_attempt, severity: :critical, tool: "workspace_config_set"}] =
             Events.for_run("bd-sg-mcp")
  end

  test "a worker adding permissions to a ticket is recorded" do
    scope = worker_scope("bd-sg-mcp2")

    assert {:rpc_error, _, _} =
             Catalog.call(scope, "ticket_update", %{
               "id" => "bd-sg-mcp2",
               "add_permissions" => ["prod_ssh"]
             })

    assert [%{kind: :self_grant_attempt}] = Events.for_run("bd-sg-mcp2")
  end

  test "ordinary worker calls and coordinator config writes leave no event" do
    worker = worker_scope("bd-sg-mcp3")
    Catalog.call(worker, "workspace_config_get", %{})
    Catalog.call(worker, "workspace_config_set", %{"key" => "merge.auto_merge", "value" => true})
    assert Events.for_run("bd-sg-mcp3") == []

    coordinator = %Scope{tier: :coordinator}
    Catalog.call(coordinator, "workspace_config_get", %{})
    assert Events.for_run("unknown") == []
  end
end
