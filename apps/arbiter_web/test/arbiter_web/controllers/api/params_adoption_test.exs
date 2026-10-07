defmodule ArbiterWeb.Api.ParamsAdoptionTest do
  @moduledoc """
  P-07: REST controllers and MCP handlers share `Arbiter.Params` for coercion
  and attribution. Caller-supplied attribution is ignored; junk booleans are
  400s; every list route clamps `limit` to a documented cap.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  require Ash.Query

  @controllers Path.expand("../../../../lib/arbiter_web/controllers/api", __DIR__)
  @mcp Path.expand("../../../../../arbiter/lib/arbiter/mcp", __DIR__)

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "pa-#{System.unique_integer([:positive])}", prefix: "pap"})

    {:ok, task} = Ash.create(Issue, %{title: "p07", workspace_id: ws.id})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), task: task, ws: ws}
  end

  describe "grep guard" do
    test "no controller or MCP handler hand-rolls boolean/limit coercion" do
      files = Path.wildcard(@controllers <> "/*.ex") ++ Path.wildcard(@mcp <> "/**/*.ex")
      refute files == []

      offenders =
        for file <- files,
            src = File.read!(file),
            src =~ "defp truthy(true)" or
              Regex.match?(
                ~r/(params|args|attrs)\["\w+"\] (==|in) (true|\["true", true\])|Map\.get\((params|args), "\w+"\) == true/,
                src
              ) or
              (src =~ "defp parse_limit" and not (src =~ "Params.limit(")),
            do: Path.relative_to(file, @controllers)

      assert offenders == []

      for {file, marker} <- [
            {"worker_controller.ex", "Params."},
            {"issue_controller.ex", "Params."},
            {"message_controller.ex", "Params."},
            {"run_controller.ex", "Params."},
            {"usage_controller.ex", "Params."},
            {"external_review_controller.ex", "Params."},
            {"loop_controller.ex", "Params."}
          ] do
        assert File.read!(Path.join(@controllers, file)) =~ marker, file
      end

      for file <- ["tools.ex"] do
        assert File.read!(Path.join(@mcp, file)) =~ "Arbiter.Params"
      end
    end

    test "no controller reads a caller-asserted attribution param" do
      for file <- Path.wildcard(@controllers <> "/*.ex"),
          key <- ~w(created_by change_origin surface) do
        refute File.read!(file) =~ ~s(params["#{key}"]), "#{file} reads #{key}"
      end
    end
  end

  describe "attribution is derived, never asserted" do
    test "issue create/update drop change_origin", %{conn: conn, task: task} do
      conn = patch(conn, ~p"/api/issues/#{task.id}", %{title: "t2", change_origin: "forged"})
      assert json_response(conn, 200)

      versions =
        Issue.Version
        |> Ash.Query.filter(version_source_id == ^task.id)
        |> Ash.read!()

      refute Enum.any?(versions, &(inspect(&1.version_action_inputs) =~ "forged"))
    end

    test "message from_ref is pinned for a coordinator", %{conn: conn, ws: ws} do
      conn =
        post(conn, ~p"/api/messages", %{
          kind: "mailbox",
          from_ref: "someone-else",
          to_ref: "bd-xyz",
          body: "hi",
          workspace_id: ws.id
        })

      assert %{"from_ref" => "coordinator"} = json_response(conn, 201)
    end

    test "dependency created_by comes from the token", %{conn: conn, task: task, ws: ws} do
      {:ok, other} = Ash.create(Issue, %{title: "other", workspace_id: ws.id})

      conn =
        post(conn, ~p"/api/dependencies", %{
          from_issue_id: task.id,
          to_issue_id: other.id,
          type: "blocks",
          created_by: "forged"
        })

      body = json_response(conn, 201)
      refute inspect(body) =~ "forged"
    end
  end

  describe "boolean coercion" do
    test "close_upstream junk is a 400, not true", %{conn: conn, task: task} do
      conn = post(conn, ~p"/api/issues/#{task.id}/close", %{close_upstream: "no"})
      assert json_response(conn, 400)
    end

    test "issue create `force` junk is a 400", %{conn: conn, ws: ws} do
      conn = post(conn, ~p"/api/issues", %{title: "x", workspace_id: ws.id, force: "maybe"})
      assert json_response(conn, 400)
    end

    test "dispatch force_quota junk is a 400", %{conn: conn, task: task} do
      conn = post(conn, ~p"/api/workers/dispatch", %{task_id: task.id, force_quota: "yes"})
      assert json_response(conn, 400)
    end

    test "provider pause stop_running junk is a 400", %{conn: conn} do
      conn = post(conn, ~p"/api/providers/pause", %{ref: "claude", stop_running: "yes"})
      assert json_response(conn, 400)
    end
  end

  describe "list caps" do
    test "limit above the cap clamps; zero is rejected", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/messages?limit=999999"), 200)
      assert json_response(get(conn, ~p"/api/messages?limit=0"), 400)
      assert json_response(get(conn, ~p"/api/workers/history?limit=999999"), 200)
      assert json_response(get(conn, ~p"/api/usage/events?limit=999999"), 200)
    end
  end
end
