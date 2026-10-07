defmodule Arbiter.MCP.TicketCreateSharedPathTest do
  @moduledoc """
  P-14: MCP `ticket_create` runs through `Arbiter.Tasks.Create`, so it gains
  what REST and the dashboard already had — the duplicate-title refusal (with a
  `force` escape hatch) and an error response, carrying the created id, when
  the upstream tracker mirror fails — plus the typed `ticket_resume_review`
  and the defence-in-depth subtree gate on the lifecycle tools.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @env_var "TICKET_CREATE_SHARED_PATH_TOKEN"

  setup do
    System.put_env(@env_var, "test-token")
    on_exit(fn -> System.delete_env(@env_var) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "shared-#{System.unique_integer([:positive])}", prefix: "sh"})

    %{ws: ws, scope: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  defp github_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "shared-gh-#{System.unique_integer([:positive])}",
        prefix: "sg",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{"owner" => "o", "repo" => "r", "credentials_ref" => "env:#{@env_var}"}
          }
        }
      })

    ws
  end

  describe "ticket_create dedup" do
    test "a duplicate open title is refused unless force", %{scope: scope} do
      assert {:ok, %{id: first}} =
               Catalog.call(scope, "ticket_create", %{"title" => "Fix the thing"})

      assert {:tool_error, msg, "conflict"} =
               Catalog.call(scope, "ticket_create", %{"title" => "fix the thing"})

      assert msg =~ first
      assert msg =~ "force"

      assert {:ok, %{id: second}} =
               Catalog.call(scope, "ticket_create", %{"title" => "fix the thing", "force" => true})

      refute second == first
    end

    test "force must be a boolean", %{scope: scope} do
      assert {:tool_error, msg, _} =
               Catalog.call(scope, "ticket_create", %{"title" => "x", "force" => "maybe"})

      assert msg =~ "force"
    end

    test "the schema advertises force" do
      tool = Enum.find(Catalog.all(), &(&1.name == "ticket_create"))
      assert %{"type" => "boolean"} = tool.input_schema["properties"]["force"]
    end
  end

  describe "ticket_create upstream mirror failure" do
    test "is an error response that names the created ticket" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "upstream down"})
      end)

      ws = github_workspace()
      scope = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

      assert {:tool_error, msg, "bad_gateway"} =
               Catalog.call(scope, "ticket_create", %{"title" => "mirror me"})

      [created] = Arbiter.Tasks.Dedup.local_matches("mirror me", ws.id)
      assert msg =~ created.id
      assert msg =~ "tracker"
    end
  end

  describe "ticket_create parent edge" do
    test "still attaches parent_of and reports parent_id", %{scope: scope} do
      {:ok, parent} = Ash.create(Issue, %{title: "p", workspace_id: scope.workspace_id})

      assert {:ok, %{id: id, parent_id: pid}} =
               Catalog.call(scope, "ticket_create", %{"title" => "kid", "parent_id" => parent.id})

      assert pid == parent.id
      assert id in Enum.map(Dependencies.for_issue(parent.id).children, & &1.issue_id)
    end

    test "an unknown parent refuses before anything is filed", %{scope: scope, ws: ws} do
      assert {:tool_error, _msg, "not_found"} =
               Catalog.call(scope, "ticket_create", %{
                 "title" => "orphan",
                 "parent_id" => "sh-nope00"
               })

      assert [] = Arbiter.Tasks.Dedup.local_matches("orphan", ws.id)
    end
  end

  describe "ticket_resume_review" do
    test "clears a tripped breaker", %{scope: scope, ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "tripped", workspace_id: ws.id})

      {:ok, _} =
        Ash.update(issue, %{
          circuit_breaker_tripped: true,
          circuit_breaker_reason: "loop",
          circuit_breaker_sha: "cafe"
        })

      assert {:ok, %{id: id}} = Catalog.call(scope, "ticket_resume_review", %{"id" => issue.id})
      assert id == issue.id

      reloaded = Ash.get!(Issue, issue.id)
      refute reloaded.circuit_breaker_tripped
      assert reloaded.circuit_breaker_cleared_sha == "cafe"
    end

    test "is coordinator-only and refused to a refine session", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      refine = %Scope{tier: :refine, workspace_id: ws.id, issue_id: issue.id, session_id: "s"}

      assert {:rpc_error, _, _} =
               Catalog.call(refine, "ticket_resume_review", %{"id" => issue.id})
    end
  end

  describe "subtree defence in depth (D-T-22)" do
    # RefinePolicy already denies these tools to a refine session; the handlers
    # carry their own subtree check so a policy slip cannot become a write.
    test "lifecycle handlers refuse an id outside a refine scope's subtree", %{ws: ws} do
      {:ok, bound} = Ash.create(Issue, %{title: "bound", workspace_id: ws.id})
      {:ok, outsider} = Ash.create(Issue, %{title: "outsider", workspace_id: ws.id})
      refine = %Scope{tier: :refine, workspace_id: ws.id, issue_id: bound.id, session_id: "s"}

      for {fun, args} <- [
            {:task_close, %{}},
            {:task_reopen, %{}},
            {:task_verify, %{"observed" => "x"}},
            {:task_sync_upstream_close, %{}},
            {:epic_floor, %{"floor_priority" => "P1"}},
            {:ticket_handoff, %{"note" => "n"}},
            {:ticket_handback, %{}},
            {:ticket_resume_review, %{}}
          ] do
        assert {:error, {:unauthorized, _}} =
                 apply(Arbiter.MCP.Tools, fun, [refine, Map.put(args, "id", outsider.id)]),
               "#{fun} must gate on the subtree"
      end

      assert Ash.get!(Issue, outsider.id).state == :backlog
    end
  end
end
