defmodule ArbiterWeb.Api.WorkspaceResolutionTest do
  @moduledoc """
  The one omitted-workspace rule over REST (parity audit P-04, operator ruling
  on bd-26s98f), with `Arbiter.Tasks.Workspaces` behind it:

    * every workspace-scoped route takes the workspace by id **or name**, under
      `workspace` or its alias `workspace_id`, and 404s an unknown one;
    * reads that name nothing cover ALL workspaces and echo `workspace_id`;
    * writes that name nothing never land in the workspace called `default`
      when several exist — they fail, listing the candidates;
    * a coordinator token bound to a workspace is confined to it (403).
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup %{conn: conn} do
    default = Ash.create!(Workspace, %{name: "default", prefix: "df"})
    other = Ash.create!(Workspace, %{name: "emricare", prefix: "em"})

    {:ok, a} = Ash.create(Issue, %{title: "in default", workspace_id: default.id})
    {:ok, b} = Ash.create(Issue, %{title: "in emricare", workspace_id: other.id})

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"),
     default: default,
     other: other,
     a: a,
     b: b}
  end

  defp bound(conn, ws),
    do: put_req_header(conn, "authorization", "Bearer " <> Scope.mint_coordinator(ws.id))

  # {path, extra params, does the body echo `workspace_id` at the top level?}
  @routes [
    {"/api/issues", %{}, true},
    {"/api/issues/ready", %{}, true},
    {"/api/issues/lifecycle", %{}, true},
    {"/api/workers", %{}, true},
    {"/api/workers/history", %{}, false},
    {"/api/usage", %{"by" => "day"}, true},
    {"/api/usage/events", %{}, true},
    {"/api/usage/calibration", %{}, true},
    {"/api/breakers", %{}, true},
    {"/api/alerts", %{}, true},
    {"/api/loop/pending", %{}, true},
    {"/api/external_reviews", %{}, true},
    {"/api/messages", %{}, true},
    {"/api/dependencies", %{}, true}
  ]

  describe "a write that names no workspace (several exist, one called `default`)" do
    test "POST /api/issues fails instead of landing in `default`", %{conn: conn} do
      conn = post(conn, ~p"/api/issues", %{"title" => "orphan"})

      assert %{"error" => %{"type" => "validation_error", "message" => message}} =
               json_response(conn, 422)

      assert message =~ "multiple workspaces; pass workspace (name or id)"
      assert message =~ "default" and message =~ "emricare"
      assert [] = Issue |> Ash.read!() |> Enum.filter(&(&1.title == "orphan"))
    end

    test "naming it by name, id or the `workspace_id` alias lands it there", ctx do
      %{conn: conn, other: other} = ctx

      for {title, params} <- [
            {"by name", %{"workspace" => "emricare"}},
            {"by id", %{"workspace" => other.id}},
            {"by alias", %{"workspace_id" => other.id}},
            {"by alias name", %{"workspace_id" => "emricare"}}
          ] do
        body =
          conn |> post(~p"/api/issues", Map.put(params, "title", title)) |> json_response(201)

        assert body["workspace_id"] == other.id, title
      end
    end

    test "an unknown workspace is a 404, never a silent miss", %{conn: conn} do
      assert %{"error" => %{"type" => "not_found"}} =
               conn
               |> post(~p"/api/issues", %{"title" => "x", "workspace" => "nope"})
               |> json_response(404)
    end

    test "the loop's single-workspace writes refuse too", %{conn: conn} do
      routing = %{"difficulty" => 2, "model_tier" => "standard"}
      doc_patch = %{"repo" => "r", "lesson" => "l"}

      for response <- [
            post(conn, "/api/loop/propose/routing", routing),
            post(conn, "/api/loop/propose/repo_doc_patch", doc_patch),
            get(conn, "/api/loop/canary")
          ] do
        assert %{"error" => %{"message" => message}} = json_response(response, 422)
        assert message =~ "multiple workspaces"
      end
    end

    # P-26 (D-M-3): a task id is unambiguous, so clearing its thread is NOT a
    # write that needs a workspace — it sweeps every workspace, like MCP.
    test "clearing a task's thread needs no workspace", %{conn: conn} do
      conn = delete(conn, ~p"/api/messages", %{"task_id" => "bd-x"})
      assert %{"data" => %{"cleared_count" => 0}} = json_response(conn, 200)
    end
  end

  describe "a read that names no workspace" do
    test "returns every workspace's rows with `workspace_id` echoed per row", ctx do
      %{conn: conn, default: default, other: other, a: a, b: b} = ctx

      body = conn |> get(~p"/api/issues") |> json_response(200)

      assert Map.fetch!(body, "workspace_id") == nil
      rows = Map.new(body["data"], &{&1["id"], &1["workspace_id"]})
      assert rows[a.id] == default.id
      assert rows[b.id] == other.id
    end

    for {path, params, echoes?} <- @routes do
      test "#{path} covers all workspaces#{if echoes?, do: " and echoes null", else: ""}",
           %{conn: conn} do
        body = conn |> get(unquote(path), unquote(Macro.escape(params))) |> json_response(200)
        if unquote(echoes?), do: assert(Map.fetch!(body, "workspace_id") == nil)
      end
    end

    test "dependency edges carry their workspace", %{conn: conn, other: other, b: b} do
      {:ok, c} = Ash.create(Issue, %{title: "c", workspace_id: other.id})
      {:ok, _} = Arbiter.Tasks.Dependencies.add(b.id, c.id, "blocks")

      body = conn |> get(~p"/api/dependencies") |> json_response(200)
      assert [%{"workspace_id" => ws}] = body["data"]
      assert ws == other.id
    end
  end

  describe "every workspace-scoped read accepts name or id, under either key" do
    for {path, params, echoes?} <- @routes do
      test "#{path}", %{conn: conn, other: other} do
        for key <- ["workspace", "workspace_id"], ref <- [other.name, other.id] do
          body =
            conn
            |> get(unquote(path), Map.put(unquote(Macro.escape(params)), key, ref))
            |> json_response(200)

          if unquote(echoes?),
            do: assert(body["workspace_id"] == other.id, "#{unquote(path)} ?#{key}=#{ref}")
        end

        assert %{"error" => %{"type" => "not_found"}} =
                 conn
                 |> get(
                   unquote(path),
                   Map.put(unquote(Macro.escape(params)), "workspace", "nope")
                 )
                 |> json_response(404)
      end
    end

    test "issues are narrowed to the named workspace", ctx do
      %{conn: conn, other: other, a: a, b: b} = ctx

      for ref <- [other.name, other.id] do
        ids =
          conn
          |> get(~p"/api/issues", %{"workspace" => ref})
          |> json_response(200)
          |> Map.get("data")

        assert b.id in Enum.map(ids, & &1["id"])
        refute a.id in Enum.map(ids, & &1["id"])
      end
    end

    test "GET /api/workspaces/:id takes a name", %{conn: conn, other: other} do
      assert %{"id" => id} = conn |> get(~p"/api/workspaces/emricare") |> json_response(200)
      assert id == other.id
    end

    test "GET /api/quota takes a name and echoes the workspace", %{conn: conn, other: other} do
      body = conn |> get(~p"/api/quota", %{"workspace" => "emricare"}) |> json_response(200)
      assert body["data"]["workspace_id"] == other.id
    end

    test "the loop's single-workspace writes resolve a name", %{conn: conn, other: other} do
      body =
        conn
        |> post(~p"/api/loop/propose/repo_doc_patch", %{
          "repo" => "r",
          "lesson" => "a lesson",
          "workspace" => "emricare"
        })
        |> json_response(200)

      assert body["pending"]["workspace_id"] == other.id
    end
  end

  describe "a coordinator token bound to a workspace" do
    test "is refused (403) when it names another workspace, on every route", ctx do
      %{conn: conn, default: default, other: other} = ctx
      bound_conn = bound(conn, other)

      for {path, params, _} <- @routes,
          ref <- [default.name, default.id],
          key <- ["workspace", "workspace_id"] do
        assert %{"error" => %{"type" => "unauthorized"}} =
                 bound_conn
                 |> get(path, Map.put(params, key, ref))
                 |> json_response(403),
               "#{path} ?#{key}=#{ref}"
      end
    end

    test "is refused when a write names another workspace", ctx do
      %{conn: conn, default: default, other: other} = ctx

      assert %{"error" => %{"type" => "unauthorized"}} =
               conn
               |> bound(other)
               |> post(~p"/api/issues", %{"title" => "x", "workspace" => default.name})
               |> json_response(403)

      assert %{"error" => %{"type" => "unauthorized"}} =
               conn
               |> bound(other)
               |> get(~p"/api/workspaces/#{default.id}")
               |> json_response(403)
    end

    test "naming nothing means its own workspace, reads and writes alike", ctx do
      %{conn: conn, other: other, a: a, b: b} = ctx
      bound_conn = bound(conn, other)

      body = bound_conn |> get(~p"/api/issues") |> json_response(200)
      assert body["workspace_id"] == other.id
      assert b.id in Enum.map(body["data"], & &1["id"])
      refute a.id in Enum.map(body["data"], & &1["id"])

      created = bound_conn |> post(~p"/api/issues", %{"title" => "mine"}) |> json_response(201)
      assert created["workspace_id"] == other.id
    end

    test "may still name its own workspace, by name or id", ctx do
      %{conn: conn, other: other} = ctx

      for ref <- [other.name, other.id] do
        assert %{"workspace_id" => id} =
                 conn
                 |> bound(other)
                 |> get(~p"/api/alerts", %{"workspace" => ref})
                 |> json_response(200)

        assert id == other.id
      end
    end
  end
end
