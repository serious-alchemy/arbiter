defmodule Arbiter.Tasks.CreateTest do
  @moduledoc """
  The one ticket-create path (P-14): dedup, the upstream-failure drain, the
  `parent_of` / `blocks` edges and the acceptance warning all live in
  `Arbiter.Tasks.Create.run/2`, so REST, MCP and the dashboard cannot drift.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Create
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @env_var "TASKS_CREATE_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-github-token")
    on_exit(fn -> System.delete_env(@env_var) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "create-ws-#{System.unique_integer([:positive])}",
        prefix: "cr"
      })

    %{ws: ws}
  end

  defp github_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "create-gh-#{System.unique_integer([:positive])}",
        prefix: "cg",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{"owner" => "o", "repo" => "r", "credentials_ref" => "env:#{@env_var}"}
          }
        }
      })

    ws
  end

  describe "run/2 — plain create" do
    test "creates the ticket and warns when a gated type has no acceptance", %{ws: ws} do
      assert {:ok, %Issue{} = issue, warnings} =
               Create.run(
                 %{"title" => "plain", "issue_type" => :bug, "workspace_id" => ws.id},
                 []
               )

      assert issue.title == "plain"
      assert [warning] = warnings
      assert warning =~ "No acceptance criteria"
    end

    test "no warning once acceptance is present", %{ws: ws} do
      assert {:ok, _issue, []} =
               Create.run(
                 %{"title" => "ac", "acceptance" => "it works", "workspace_id" => ws.id},
                 []
               )
    end

    test "accepts atom-keyed attrs (the dashboard's shape)", %{ws: ws} do
      assert {:ok, %Issue{title: "atoms"}, _} =
               Create.run(%{title: "atoms", workspace_id: ws.id}, [])
    end

    test "an Ash validation failure is passed through", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Create.run(%{"title" => "bad", "priority" => 99, "workspace_id" => ws.id}, [])
    end
  end

  describe "run/2 — dedup" do
    test "refuses a duplicate open title unless forced", %{ws: ws} do
      attrs = %{"title" => "Same Title", "workspace_id" => ws.id}
      assert {:ok, first, _} = Create.run(attrs, [])

      assert {:duplicate, {:local_dup, [match]}} =
               Create.run(%{attrs | "title" => " same title "}, [])

      assert match.id == first.id

      assert {:ok, second, _} = Create.run(attrs, force: true)
      refute second.id == first.id
    end
  end

  describe "run/2 — edges" do
    test "parent_id attaches a parent_of edge in the same call", %{ws: ws} do
      {:ok, parent, _} = Create.run(%{"title" => "parent", "workspace_id" => ws.id}, [])

      assert {:ok, child, _} =
               Create.run(
                 %{"title" => "child", "workspace_id" => ws.id, "parent_id" => parent.id},
                 created_by: "tester"
               )

      assert {:ok, [%{edge: edge}]} = Dependencies.list(issue_id: child.id)
      assert edge.type == :parent_of
      assert edge.from_issue_id == parent.id
      assert edge.created_by == "tester"
    end

    test "deps attach blocks edges from each named ticket", %{ws: ws} do
      {:ok, a, _} = Create.run(%{"title" => "a", "workspace_id" => ws.id}, [])
      {:ok, b, _} = Create.run(%{"title" => "b", "workspace_id" => ws.id}, [])

      assert {:ok, child, _} =
               Create.run(%{"title" => "blocked", "workspace_id" => ws.id}, deps: [a.id, b.id])

      assert {:ok, edges} = Dependencies.list(issue_id: child.id)
      assert Enum.sort(Enum.map(edges, & &1.edge.from_issue_id)) == Enum.sort([a.id, b.id])
      assert Enum.all?(edges, &(&1.edge.type == :blocks))
    end

    test "an unknown parent or dep refuses before anything is created", %{ws: ws} do
      assert {:error, {:not_found, msg}} =
               Create.run(
                 %{"title" => "orphan", "workspace_id" => ws.id, "parent_id" => "cr-nope"},
                 []
               )

      assert msg =~ "cr-nope"

      assert {:error, {:not_found, _}} =
               Create.run(%{"title" => "orphan", "workspace_id" => ws.id}, deps: ["cr-nope"])

      assert [] = Arbiter.Tasks.Dedup.local_matches("orphan", ws.id)
    end

    test "a parent in another workspace refuses before anything is created", %{ws: ws} do
      {:ok, other} =
        Ash.create(Workspace, %{name: "other-#{System.unique_integer([:positive])}", prefix: "ot"})

      {:ok, foreign, _} = Create.run(%{"title" => "foreign", "workspace_id" => other.id}, [])

      assert {:error, {:invalid, msg}} =
               Create.run(
                 %{"title" => "child", "workspace_id" => ws.id, "parent_id" => foreign.id},
                 []
               )

      assert msg =~ "workspace"
      assert [] = Arbiter.Tasks.Dedup.local_matches("child", ws.id)
    end

    test "an edge that fails after the create keeps the ticket and reports its id", %{ws: ws} do
      {:ok, parent, _} = Create.run(%{"title" => "parent", "workspace_id" => ws.id}, [])

      # The parent vanishes between the preflight and the edge write.
      assert {:partial, %Issue{} = issue, [failure]} =
               Create.run(
                 %{"title" => "child", "workspace_id" => ws.id, "parent_id" => parent.id},
                 edge_writer: fn _from, _to, _type, _opts -> {:error, {:not_found, "gone"}} end
               )

      assert failure.kind == :edge_failed
      assert failure.message =~ "gone"
      assert failure.message =~ issue.id
      assert Ash.get!(Issue, issue.id).title == "child"
    end
  end

  describe "run/2 — upstream mirror failure" do
    test "is drained and returned with the created ticket" do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
      end)

      ws = github_workspace()

      assert {:partial, %Issue{} = issue, [failure]} =
               Create.run(%{"title" => "mirror me", "workspace_id" => ws.id}, [])

      assert failure.kind == :upstream_create_failed
      assert failure.task_id == issue.id
      assert is_binary(failure.message)
      # drained: a second create on this process sees no stale error
      assert {:ok, _, _} =
               Create.run(
                 %{"title" => "second", "workspace_id" => ws.id, "tracker_ref" => "9"},
                 []
               )
    end
  end
end
