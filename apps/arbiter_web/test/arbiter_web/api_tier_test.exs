defmodule ArbiterWeb.ApiTierTest do
  @moduledoc """
  bd-asawcq: a token's tier and scope are enforced on `/api` the way
  `Arbiter.MCP` enforces them on tool calls. A worker token reaches its own
  task, its own mailbox and its own workspace's tickets, and nothing a
  coordinator does; a refine token only reads.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.ApiPolicy

  @write_verbs [:post, :put, :patch, :delete]

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "tier-ws-#{n}", prefix: "tw"})
    {:ok, other_ws} = Ash.create(Workspace, %{name: "tier-other-#{n}", prefix: "to"})
    {:ok, task} = Ash.create(Issue, %{title: "the worker's task", workspace_id: ws.id})
    {:ok, sibling} = Ash.create(Issue, %{title: "a sibling", workspace_id: ws.id})
    {:ok, foreign} = Ash.create(Issue, %{title: "elsewhere", workspace_id: other_ws.id})

    worker_token = Scope.mint_worker(task)

    {:ok,
     ws: ws,
     other_ws: other_ws,
     task: task,
     sibling: sibling,
     foreign: foreign,
     worker_token: worker_token}
  end

  defp as(token) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp concrete(path, id) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> id
      seg -> seg
    end)
  end

  defp write_routes_with(policies) do
    for route <- ArbiterWeb.Router.__routes__(),
        String.starts_with?(route.path, "/api/"),
        route.verb in @write_verbs,
        ApiPolicy.policy(route.verb, route.path) in policies,
        do: route
  end

  describe "a worker-tier token" do
    test "is refused (403) on every coordinator-only write route", ctx do
      allowed =
        for route <- write_routes_with([:coordinator, :dispatch]) do
          conn =
            ctx.worker_token
            |> as()
            |> put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.dispatch(
              @endpoint,
              route.verb,
              concrete(route.path, ctx.task.id),
              "{}"
            )

          {route.verb, route.path, conn.status}
        end
        |> Enum.reject(fn {_, _, status} -> status == 403 end)

      assert allowed == []
    end

    test "cannot close, dispatch, or write workspace config", ctx do
      assert ctx.worker_token
             |> as()
             |> post("/api/issues/#{ctx.task.id}/close")
             |> json_response(403)

      assert ctx.worker_token
             |> as()
             |> post("/api/workers/dispatch", %{task_id: ctx.task.id})
             |> json_response(403)

      assert ctx.worker_token
             |> as()
             |> patch("/api/workspaces/#{ctx.ws.id}/config", %{})
             |> json_response(403)
    end

    test "records progress on its own task", ctx do
      conn =
        ctx.worker_token
        |> as()
        |> patch("/api/issues/#{ctx.task.id}", %{notes: "progress", pr_body: "## Summary"})

      assert json_response(conn, 200)
      assert Ash.get!(Issue, ctx.task.id).notes == "progress"
    end

    test "cannot update another task", ctx do
      conn = ctx.worker_token |> as() |> patch("/api/issues/#{ctx.sibling.id}", %{notes: "x"})
      assert json_response(conn, 403)["error"]["message"] =~ "own task"
      assert Ash.get!(Issue, ctx.sibling.id).notes == nil
    end

    test "cannot change anything but progress fields on its own task", ctx do
      conn = ctx.worker_token |> as() |> patch("/api/issues/#{ctx.task.id}", %{priority: 0})
      assert json_response(conn, 403)["error"]["message"] =~ "priority"
    end

    test "reads tickets in its own workspace, not another's", ctx do
      assert ctx.worker_token
             |> as()
             |> get("/api/issues/#{ctx.sibling.id}")
             |> json_response(200)

      assert ctx.worker_token
             |> as()
             |> get("/api/issues/#{ctx.foreign.id}")
             |> json_response(403)

      assert ctx.worker_token
             |> as()
             |> get("/api/dependencies/#{ctx.foreign.id}")
             |> json_response(403)
    end

    test "sees only its own workspace in the workspace list", ctx do
      body = ctx.worker_token |> as() |> get("/api/workspaces") |> json_response(200)
      assert Enum.map(body["data"], & &1["id"]) == [ctx.ws.id]
    end

    test "reads its own mailbox and nobody else's", ctx do
      assert ctx.worker_token
             |> as()
             |> get("/api/messages", %{to_ref: ctx.task.id, unread: "true"})
             |> json_response(200)

      assert ctx.worker_token
             |> as()
             |> get("/api/messages", %{to_ref: "coordinator"})
             |> json_response(403)

      assert ctx.worker_token |> as() |> get("/api/messages") |> json_response(403)
    end

    test "marks its own mail read, not another task's", ctx do
      {:ok, mine} =
        Ash.create(Message, %{
          kind: :direction,
          from_ref: "coordinator",
          to_ref: ctx.task.id,
          body: "hi",
          workspace_id: ctx.ws.id
        })

      {:ok, theirs} =
        Ash.create(Message, %{
          kind: :direction,
          from_ref: "coordinator",
          to_ref: ctx.sibling.id,
          body: "hi",
          workspace_id: ctx.ws.id
        })

      assert ctx.worker_token
             |> as()
             |> post("/api/messages/#{mine.id}/read")
             |> json_response(200)

      assert ctx.worker_token
             |> as()
             |> post("/api/messages/#{theirs.id}/read")
             |> json_response(403)
    end

    # bd-7ezcqb: a worker that defers review-thread work must file the
    # follow-up and cite its key, via `arb create <title> --parent <own id>`
    # (a create carrying `parent_id`, then the `parent_of` edge). That stays
    # possible — but only as a Backlog child of its own task, in its own
    # workspace.
    test "files a follow-up as a child of its own task", ctx do
      conn =
        ctx.worker_token
        |> as()
        |> post("/api/issues", %{
          title: "deferred follow-up",
          workspace_id: ctx.ws.id,
          parent_id: ctx.task.id,
          issue_type: "feature"
        })

      child = json_response(conn, 201)
      assert child["state"] == "backlog"

      conn =
        ctx.worker_token
        |> as()
        |> post("/api/dependencies", %{
          from_issue_id: ctx.task.id,
          to_issue_id: child["id"],
          type: "parent_of"
        })

      assert json_response(conn, 201)
    end

    test "cannot file a ticket that is not its own child, or into another workspace", ctx do
      for body <- [
            %{title: "orphan", workspace_id: ctx.ws.id},
            %{title: "adopted", workspace_id: ctx.ws.id, parent_id: ctx.sibling.id},
            %{title: "abroad", workspace_id: ctx.other_ws.id, parent_id: ctx.task.id},
            %{title: "pinned", workspace_id: ctx.ws.id, parent_id: ctx.task.id, repo: "x"}
          ] do
        assert ctx.worker_token |> as() |> post("/api/issues", body) |> json_response(403),
               inspect(body)
      end
    end

    # bd-13pqcp: where a ticket may run is coordinator/operator authority — a
    # worker may not file a follow-up with a constraint, nor set one on its
    # own task, nor loosen the one it was given.
    test "cannot set a provider constraint, on a follow-up or on its own task", ctx do
      constraint = %{exclude: ["claude"]}

      assert ctx.worker_token
             |> as()
             |> post("/api/issues", %{
               title: "constrained follow-up",
               workspace_id: ctx.ws.id,
               parent_id: ctx.task.id,
               provider_constraint: constraint
             })
             |> json_response(403)

      assert ctx.worker_token
             |> as()
             |> patch("/api/issues/#{ctx.task.id}", %{provider_constraint: constraint})
             |> json_response(403)

      assert Ash.get!(Issue, ctx.task.id).provider_constraint == nil

      # …whereas the progress fields it is allowed still work.
      assert ctx.worker_token
             |> as()
             |> patch("/api/issues/#{ctx.task.id}", %{notes: "progress"})
             |> json_response(200)
    end

    test "cannot add edges other than parent_of from its own task to an unparented ticket", ctx do
      {:ok, parented} = Ash.create(Issue, %{title: "has a parent", workspace_id: ctx.ws.id})
      {:ok, _} = Arbiter.Tasks.Dependencies.add(ctx.sibling.id, parented.id, :parent_of)

      for body <- [
            %{from_issue_id: ctx.sibling.id, to_issue_id: ctx.task.id, type: "parent_of"},
            %{from_issue_id: ctx.task.id, to_issue_id: ctx.sibling.id, type: "blocks"},
            %{from_issue_id: ctx.task.id, to_issue_id: ctx.foreign.id, type: "parent_of"},
            %{from_issue_id: ctx.task.id, to_issue_id: parented.id, type: "parent_of"}
          ] do
        assert ctx.worker_token |> as() |> post("/api/dependencies", body) |> json_response(403),
               inspect(body)
      end
    end

    test "sends mail as itself, pinned to its own workspace — never as the coordinator", ctx do
      conn =
        ctx.worker_token
        |> as()
        |> post("/api/messages", %{
          kind: "direction",
          from_ref: "coordinator",
          to_ref: ctx.sibling.id,
          body: "heads up",
          workspace_id: ctx.other_ws.id
        })

      body = json_response(conn, 201)
      assert body["from_ref"] == ctx.task.id
      assert body["kind"] == "flag"
      assert body["workspace_id"] == ctx.ws.id
    end
  end

  describe "a refine-tier token" do
    setup ctx do
      session = Ash.create!(Arbiter.Sessions.Session, %{cwd: "/tmp/api-tier-refine"})
      {:ok, refine_token: Scope.mint_refine(session.id, ctx.ws.id, ctx.task.id)}
    end

    test "reads tickets in its workspace", ctx do
      assert ctx.refine_token
             |> as()
             |> get("/api/issues/#{ctx.sibling.id}")
             |> json_response(200)

      assert ctx.refine_token
             |> as()
             |> get("/api/issues/#{ctx.foreign.id}")
             |> json_response(403)
    end

    test "writes nothing over REST (its writes are subtree-gated MCP tools)", ctx do
      allowed =
        for route <-
              write_routes_with([
                :coordinator,
                :dispatch,
                :issue_progress,
                :issue_create,
                :dependency_add
              ]) do
          conn =
            ctx.refine_token
            |> as()
            |> put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.dispatch(
              @endpoint,
              route.verb,
              concrete(route.path, ctx.task.id),
              "{}"
            )

          {route.verb, route.path, conn.status}
        end
        |> Enum.reject(fn {_, _, status} -> status == 403 end)

      assert allowed == []
    end
  end

  describe "a coordinator-tier token" do
    test "without can_dispatch cannot dispatch, review or resume", ctx do
      token = Scope.mint_coordinator(nil, can_dispatch: false)

      for path <- [
            "/api/workers/dispatch",
            "/api/workers/review",
            "/api/workers/#{ctx.task.id}/resume"
          ] do
        conn = token |> as() |> post(path, %{task_id: ctx.task.id})
        assert json_response(conn, 403)["error"]["message"] =~ "can_dispatch", path
      end
    end

    test "closes a ticket", ctx do
      conn = Scope.mint_coordinator(nil) |> as() |> post("/api/issues/#{ctx.task.id}/close")
      assert json_response(conn, 200)
    end
  end
end
