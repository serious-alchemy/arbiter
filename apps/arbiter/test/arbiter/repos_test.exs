defmodule Arbiter.ReposTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Repos
  alias Arbiter.Tasks.Workspace

  describe "list/1" do
    test "returns empty list when no repos are configured" do
      assert Repos.list() == []
    end

    test "two-workspace same-name fixture returns both entries" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"shared-repo" => "/tmp/repo-one"}}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"shared-repo" => "/tmp/repo-two"}}
        })

      repos = Repos.list()

      shared_entries = Enum.filter(repos, &(&1.name == "shared-repo"))
      assert length(shared_entries) == 2

      sources = Enum.map(shared_entries, & &1.source) |> Enum.sort()
      assert sources == ["ws-one", "ws-two"]

      paths = Enum.map(shared_entries, & &1.path) |> Enum.sort()
      assert paths == ["/tmp/repo-one", "/tmp/repo-two"]

      ws_ids = Enum.map(shared_entries, & &1.workspace_id) |> Enum.sort()
      assert ws_ids == Enum.sort([ws1.id, ws2.id])
    end

    test "filters by workspace_id when provided" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"repo-a" => "/tmp/repo-a"}}
        })

      {:ok, _ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"repo-b" => "/tmp/repo-b"}}
        })

      repos1 = Repos.list(workspace_id: ws1.id)
      assert length(repos1) == 1
      assert hd(repos1).name == "repo-a"
      assert hd(repos1).source == "ws-one"
    end

    test "includes app-env fallback unless configured in workspace" do
      old_env = Application.get_env(:arbiter, :repo_paths, %{})

      try do
        Application.put_env(:arbiter, :repo_paths, %{
          "app-only" => "/tmp/app-only",
          "overridden" => "/tmp/app-overridden"
        })

        {:ok, _ws} =
          Ash.create(Workspace, %{
            name: "ws-main",
            prefix: "wm",
            config: %{"repo_paths" => %{"overridden" => "/tmp/ws-overridden"}}
          })

        repos = Repos.list()

        app_only = Enum.find(repos, &(&1.name == "app-only"))
        assert app_only
        assert app_only.path == "/tmp/app-only"
        assert app_only.source == "(app)"

        overridden_entries = Enum.filter(repos, &(&1.name == "overridden"))
        assert length(overridden_entries) == 1
        assert hd(overridden_entries).source == "ws-main"
        assert hd(overridden_entries).path == "/tmp/ws-overridden"
      after
        Application.put_env(:arbiter, :repo_paths, old_env)
      end
    end
  end

  describe "get/2" do
    test "finds repo by name" do
      {:ok, _ws} =
        Ash.create(Workspace, %{
          name: "ws-main",
          prefix: "wm",
          config: %{"repo_paths" => %{"target-repo" => "/tmp/target-repo"}}
        })

      assert {:ok, repo} = Repos.get("target-repo")
      assert repo.name == "target-repo"
      assert repo.path == "/tmp/target-repo"
      assert repo.source == "ws-main"
    end

    test "returns not-found error for nonexistent repo" do
      assert {:error, {:not_found, msg}} = Repos.get("nonexistent")
      assert msg =~ "nonexistent"
    end

    test "scopes to workspace_id when provided" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "ws-one",
          prefix: "w1",
          config: %{"repo_paths" => %{"same-name" => "/tmp/ws1-path"}}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "ws-two",
          prefix: "w2",
          config: %{"repo_paths" => %{"same-name" => "/tmp/ws2-path"}}
        })

      assert {:ok, repo1} = Repos.get("same-name", workspace_id: ws1.id)
      assert repo1.path == "/tmp/ws1-path"
      assert repo1.source == "ws-one"

      assert {:ok, repo2} = Repos.get("same-name", workspace_id: ws2.id)
      assert repo2.path == "/tmp/ws2-path"
      assert repo2.source == "ws-two"
    end
  end
end
