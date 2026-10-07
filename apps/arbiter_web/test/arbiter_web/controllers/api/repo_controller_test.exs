defmodule ArbiterWeb.Api.RepoControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Workspace

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/repos" do
    test "returns a JSON list of repos", %{conn: conn} do
      conn = get(conn, ~p"/api/repos")
      assert %{"data" => data} = json_response(conn, 200)
      assert is_list(data)

      for repo <- data do
        assert Map.has_key?(repo, "name")
        assert Map.has_key?(repo, "path")
        assert Map.has_key?(repo, "source")
        assert Map.has_key?(repo, "workspace_id")
        assert Map.has_key?(repo, "workers")
        assert Map.has_key?(repo, "worktrees")
      end
    end

    test "surfaces a workspace's configured repo_paths", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "repo-ws",
          prefix: "rpw",
          config: %{"repo_paths" => %{"alpha" => "/tmp/does-not-exist-alpha"}}
        })

      conn = get(conn, ~p"/api/repos")
      assert %{"data" => data} = json_response(conn, 200)

      alpha = Enum.find(data, &(&1["name"] == "alpha"))
      assert alpha
      assert alpha["path"] == "/tmp/does-not-exist-alpha"
      assert alpha["source"] == "repo-ws"
      assert alpha["workspace_id"] == ws.id
      assert is_integer(alpha["workers"])
      assert is_integer(alpha["worktrees"])
    end

    test "two-workspace same-name fixture returns both entries", %{conn: conn} do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "repo-ws-1",
          prefix: "rw1",
          config: %{"repo_paths" => %{"shared" => "/tmp/shared-1"}}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "repo-ws-2",
          prefix: "rw2",
          config: %{"repo_paths" => %{"shared" => "/tmp/shared-2"}}
        })

      conn = get(conn, ~p"/api/repos")
      assert %{"data" => data} = json_response(conn, 200)

      shared = Enum.filter(data, &(&1["name"] == "shared"))
      assert length(shared) == 2
      assert Enum.map(shared, & &1["source"]) |> Enum.sort() == ["repo-ws-1", "repo-ws-2"]
      assert Enum.map(shared, & &1["path"]) |> Enum.sort() == ["/tmp/shared-1", "/tmp/shared-2"]
      assert Enum.map(shared, & &1["workspace_id"]) |> Enum.sort() == Enum.sort([ws1.id, ws2.id])
    end

    test "responds with JSON, not an HTML 404", %{conn: conn} do
      conn = get(conn, ~p"/api/repos")
      assert json_response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end
  end

  describe "GET /api/repos/:name" do
    test "returns repo details when repo exists", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "repo-ws",
          prefix: "rpw",
          config: %{"repo_paths" => %{"alpha" => "/tmp/does-not-exist-alpha"}}
        })

      conn = get(conn, ~p"/api/repos/alpha")
      assert repo = json_response(conn, 200)
      assert repo["name"] == "alpha"
      assert repo["path"] == "/tmp/does-not-exist-alpha"
      assert repo["source"] == "repo-ws"
      assert repo["workspace_id"] == ws.id
      assert is_integer(repo["workers"])
      assert is_integer(repo["worktrees"])
    end

    test "scopes to workspace when param provided", %{conn: conn} do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "repo-ws-1",
          prefix: "rw1",
          config: %{"repo_paths" => %{"alpha" => "/tmp/alpha-1"}}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "repo-ws-2",
          prefix: "rw2",
          config: %{"repo_paths" => %{"alpha" => "/tmp/alpha-2"}}
        })

      conn1 = get(conn, ~p"/api/repos/alpha?workspace=#{ws1.id}")
      assert repo1 = json_response(conn1, 200)
      assert repo1["path"] == "/tmp/alpha-1"
      assert repo1["source"] == "repo-ws-1"
      assert repo1["workspace_id"] == ws1.id

      conn2 = get(conn, ~p"/api/repos/alpha?workspace=#{ws2.name}")
      assert repo2 = json_response(conn2, 200)
      assert repo2["path"] == "/tmp/alpha-2"
      assert repo2["source"] == "repo-ws-2"
      assert repo2["workspace_id"] == ws2.id
    end

    test "returns 400 when repo is ambiguous without workspace qualification", %{conn: conn} do
      {:ok, _ws1} =
        Ash.create(Workspace, %{
          name: "repo-ws-1",
          prefix: "rw1",
          config: %{"repo_paths" => %{"twin" => "/tmp/twin-1"}}
        })

      {:ok, _ws2} =
        Ash.create(Workspace, %{
          name: "repo-ws-2",
          prefix: "rw2",
          config: %{"repo_paths" => %{"twin" => "/tmp/twin-2"}}
        })

      conn = get(conn, ~p"/api/repos/twin")
      assert %{"error" => error} = json_response(conn, 400)
      assert error["type"] == "invalid_request"
      assert error["message"] =~ "ambiguous"
    end

    test "returns 404 when repo does not exist", %{conn: conn} do
      conn = get(conn, ~p"/api/repos/nonexistent")
      assert %{"error" => error} = json_response(conn, 404)
      assert error["type"] == "not_found"
      assert error["message"] =~ "nonexistent"
    end
  end
end
