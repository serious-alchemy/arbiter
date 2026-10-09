defmodule Arbiter.Guardrails.SelfGrantTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.SelfGrant

  describe "mcp?/2" do
    test "config writes naming guardrails or permissions" do
      assert SelfGrant.mcp?("workspace_config_set", %{
               "key" => "guardrails.cap.egress",
               "value" => "open"
             })

      assert SelfGrant.mcp?("workspace_config_set", %{
               "key" => "agent.security.permissions.mode",
               "value" => "bypass"
             })

      assert SelfGrant.mcp?("workspace_config_set", %{"patch" => %{"guardrails" => %{"a" => 1}}})
      assert SelfGrant.mcp?("workspace_config_unset", %{"key" => "guardrails.cap"})
      assert SelfGrant.mcp?("workspace_config_set", %{"unset_paths" => ["x.permissions"]})
      assert SelfGrant.mcp?("installation_config_set", %{"key" => "guardrails.x", "value" => 1})
    end

    test "ordinary config writes are not" do
      refute SelfGrant.mcp?("workspace_config_set", %{
               "key" => "merge.auto_merge",
               "value" => true
             })

      refute SelfGrant.mcp?("workspace_config_set", %{"patch" => %{"merge" => %{"a" => 1}}})
      refute SelfGrant.mcp?("workspace_config_set", %{})
    end

    test "ticket writes carrying permissions" do
      assert SelfGrant.mcp?("ticket_update", %{"id" => "bd-1", "permissions" => ["prod_ssh"]})
      assert SelfGrant.mcp?("ticket_update", %{"add_permissions" => ["secrets"]})

      assert SelfGrant.mcp?("ticket_create", %{"title" => "t", "permissions" => ["tracker_write"]})

      refute SelfGrant.mcp?("ticket_update", %{"id" => "bd-1", "permissions" => []})
      refute SelfGrant.mcp?("ticket_update", %{"id" => "bd-1", "title" => "x"})
    end

    test "a permission grant tool" do
      assert SelfGrant.mcp?("ticket_permission_grant", %{})
      refute SelfGrant.mcp?("ticket_show", %{"id" => "bd-1"})
    end
  end

  describe "rest?/3" do
    test "token minting" do
      assert SelfGrant.rest?("POST", ["api", "mcp", "tokens"], %{})
      refute SelfGrant.rest?("POST", ["api", "mcp", "tokens", "verify"], %{})
    end

    test "config and issue writes naming permissions or guardrails" do
      assert SelfGrant.rest?("PATCH", ["api", "workspaces", "w1", "config"], %{
               "guardrails" => %{"a" => 1}
             })

      assert SelfGrant.rest?("PATCH", ["api", "workspaces", "w1", "config"], %{
               "key" => "guardrails.x"
             })

      assert SelfGrant.rest?("PATCH", ["api", "installation", "config"], %{
               "patch" => %{"guardrails" => %{}}
             })

      assert SelfGrant.rest?("PATCH", ["api", "issues", "bd-1"], %{"permissions" => ["prod_ssh"]})

      assert SelfGrant.rest?("POST", ["api", "issues"], %{
               "title" => "t",
               "permissions" => ["secrets"]
             })

      assert SelfGrant.rest?("POST", ["api", "issues", "bd-1", "permissions", "grant"], %{})
    end

    test "reads and ordinary writes are not" do
      refute SelfGrant.rest?("GET", ["api", "workspaces", "w1", "config"], %{})
      refute SelfGrant.rest?("PATCH", ["api", "issues", "bd-1"], %{"notes" => "x"})
      refute SelfGrant.rest?("PATCH", ["api", "issues", "bd-1"], %{"permissions" => []})

      refute SelfGrant.rest?("PATCH", ["api", "workspaces", "w1", "config"], %{"key" => "merge.x"})
    end
  end
end
