defmodule ArbiterWeb.ResearchTierTest do
  @moduledoc """
  bd-6ircwr: a worker whose ticket was granted `research_read` reads Arbiter's
  own run, usage and review-round data over `/api` — for its own workspace only,
  with no mutating route — and a worker without the grant still gets the
  coordinator-only refusal.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run
  alias ArbiterWeb.ApiPolicy

  @research_routes [
    {:get, "/api/workers"},
    {:get, "/api/workers/history"},
    {:get, "/api/workers/history/:id"},
    {:get, "/api/workers/:task_id"},
    {:get, "/api/workers/:task_id/log"},
    {:get, "/api/workers/:task_id/run_log_list"},
    {:get, "/api/usage"},
    {:get, "/api/usage/events"},
    {:get, "/api/review_gate_rounds"}
  ]

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "res-ws-#{n}", prefix: "rw"})
    {:ok, other_ws} = Ash.create(Workspace, %{name: "res-other-#{n}", prefix: "ro"})
    {:ok, task} = Ash.create(Issue, %{title: "research", workspace_id: ws.id, issue_type: :task})
    {:ok, foreign} = Ash.create(Issue, %{title: "elsewhere", workspace_id: other_ws.id})

    own_run = run!(ws, task.id)
    foreign_run = run!(other_ws, foreign.id)

    {:ok,
     ws: ws,
     other_ws: other_ws,
     task: task,
     foreign: foreign,
     own_run: own_run,
     foreign_run: foreign_run,
     research: Scope.mint_worker(task, nil, permissions: ["research_read"]),
     plain: Scope.mint_worker(task)}
  end

  defp run!(ws, task_id) do
    Ash.create!(Run, %{
      task_id: task_id,
      workspace_id: ws.id,
      repo: "r",
      started_at: DateTime.utc_now()
    })
  end

  defp usage!(ws, task_id) do
    Ash.create!(Arbiter.Usage.Event, %{
      task_id: task_id,
      source: :task,
      repo: "r",
      workspace_id: ws.id,
      step: :work,
      occurred_at: DateTime.utc_now()
    })
  end

  defp read(token, path, params \\ %{}) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Phoenix.ConnTest.dispatch(@endpoint, :get, path <> query(params))
  end

  defp query(params) when params == %{}, do: ""
  defp query(params), do: "?" <> URI.encode_query(params)

  defp send_as(token, verb, path) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Phoenix.ConnTest.dispatch(@endpoint, verb, path, "{}")
  end

  defp ids(conn), do: for(r <- json_response(conn, 200)["data"], do: r["id"])

  describe "the policy table" do
    test "the research routes are exactly the read-only run, usage and review-round reads" do
      classified =
        for {key, :research_read} <- ApiPolicy.policies(), do: key

      assert Enum.sort(classified) == Enum.sort(@research_routes)
    end

    test "no research route mutates" do
      assert for({{verb, _}, :research_read} <- ApiPolicy.policies(), verb != :get, do: verb) ==
               []
    end
  end

  describe "a worker token holding research_read" do
    test "lists run history for its own workspace only", ctx do
      conn = read(ctx.research, "/api/workers/history")
      assert ctx.own_run.id in ids(conn)
      refute ctx.foreign_run.id in ids(conn)
    end

    test "cannot name another workspace (403)", ctx do
      for path <- ["/api/workers/history", "/api/usage", "/api/usage/events", "/api/workers"] do
        conn = read(ctx.research, path, %{"workspace" => ctx.other_ws.id})
        assert conn.status == 403, "#{path} -> #{conn.status}"
      end
    end

    test "shows a run of its own workspace, and another's is a 404", ctx do
      assert read(ctx.research, "/api/workers/history/#{ctx.own_run.id}").status == 200
      assert read(ctx.research, "/api/workers/history/#{ctx.foreign_run.id}").status == 404
    end

    test "worker show, log and run_log_list work for its workspace's tasks, not another's", ctx do
      for suffix <- ["", "/log", "/run_log_list"] do
        own = read(ctx.research, "/api/workers/#{ctx.task.id}#{suffix}")
        assert own.status == 200, "own #{suffix} -> #{own.status}"

        foreign = read(ctx.research, "/api/workers/#{ctx.foreign.id}#{suffix}")
        assert foreign.status in [403, 404], "foreign #{suffix} -> #{foreign.status}"
      end
    end

    test "reads usage summaries and events of its own workspace only", ctx do
      usage!(ctx.ws, ctx.task.id)
      usage!(ctx.other_ws, ctx.foreign.id)

      events = read(ctx.research, "/api/usage/events")
      assert [%{"task_id" => task_id}] = json_response(events, 200)["data"]
      assert task_id == ctx.task.id

      summary = read(ctx.research, "/api/usage", %{"by" => "task"})
      assert [%{} = row] = json_response(summary, 200)["data"]
      assert inspect(row) =~ ctx.task.id
      refute inspect(json_response(summary, 200)) =~ ctx.foreign.id
    end

    test "reads review-gate rounds of its own workspace's ticket, not another's", ctx do
      own = read(ctx.research, "/api/review_gate_rounds", %{"task_id" => ctx.task.id})
      assert own.status == 200

      foreign = read(ctx.research, "/api/review_gate_rounds", %{"task_id" => ctx.foreign.id})
      assert foreign.status == 404
    end

    test "each read is audited with the task, workspace and route", ctx do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert read(ctx.research, "/api/workers/history").status == 200
        end)

      assert log =~ "research_read: #{ctx.task.id} (workspace #{ctx.ws.id}) GET /api/workers/history"
    end

    test "is refused (403) on every route that is not a research read", ctx do
      allowed =
        for route <- ArbiterWeb.Router.__routes__(),
            String.starts_with?(route.path, "/api/"),
            ApiPolicy.policy(route.verb, route.path) in [:coordinator, :dispatch, :operator],
            path = route.path |> String.replace(~r/:[a-z_]+/, ctx.task.id),
            conn = send_as(ctx.research, route.verb, path),
            conn.status != 403,
            do: {route.verb, route.path, conn.status}

      assert allowed == []
    end

    test "cannot reach the routes the research grant does not name", ctx do
      for path <- ["/api/usage/calibration", "/api/workers/#{ctx.task.id}/prompt"] do
        assert read(ctx.research, path).status == 403, path
      end

      assert send_as(ctx.research, :post, "/api/workers/#{ctx.task.id}/stop").status == 403
      assert send_as(ctx.research, :post, "/api/workers/dispatch").status == 403
    end
  end

  describe "without the grant" do
    test "a plain worker token keeps the coordinator-only refusal on every research route", ctx do
      for {:get, pattern} <- @research_routes do
        path = String.replace(pattern, ~r/:[a-z_]+/, ctx.task.id)
        conn = read(ctx.plain, path)
        assert conn.status == 403, "#{path} -> #{conn.status}"
      end
    end

    test "a refine token never gets it", ctx do
      refine = %Scope{tier: :refine, workspace_id: ctx.ws.id, issue_id: ctx.task.id, permissions: ["research_read"]}

      for {:get, _} <- @research_routes do
        assert {:error, :forbidden, _} = ApiPolicy.authorize(:research_read, refine, %{})
      end
    end

    test "a different permission does not open it", ctx do
      token = Scope.mint_worker(ctx.task, nil, permissions: ["tracker_write"])
      assert read(token, "/api/workers/history").status == 403
    end
  end
end
