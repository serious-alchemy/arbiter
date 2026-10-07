defmodule Arbiter.Tasks.Workspace.OperationsTest do
  @moduledoc """
  P-21: the workspace write operations every surface shares — worker env patch
  and atomic standing-order append/remove.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspace.Operations

  defp workspace(config \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "ops-#{n}", prefix: "op", config: config})
    ws
  end

  defp orders(id) do
    {:ok, ws} = Ash.get(Workspace, id)
    ws.config["standing_orders"]
  end

  describe "update/3" do
    test "writes attributes, secrets and worker_env in one call" do
      ws = workspace()

      assert {:ok, updated} =
               Operations.update(ws.id, %{
                 "name" => "renamed",
                 "description" => "d",
                 "secrets" => %{"tok" => "abc"},
                 "worker_env" => %{"A" => %{"value" => "1"}}
               })

      assert updated.name == "renamed"
      assert updated.description == "d"
      assert Workspace.secret_key_names(updated) == ["tok"]
      assert Workspace.worker_env_keys(updated) == [%{name: "A", secret?: false}]
    end

    test "an invalid prefix is an Ash error" do
      ws = workspace()
      assert {:error, %Ash.Error.Invalid{}} = Operations.update(ws, %{"prefix" => "Bad Prefix"})
    end
  end

  describe "patch_worker_env/3" do
    test "sets, flips the secret flag and removes through the one function" do
      ws = workspace()

      assert {:ok, ws} =
               Operations.patch_worker_env(ws, %{"TOKEN" => %{"value" => "s3cr3t", "secret" => true}})

      assert Workspace.worker_env_keys(ws) == [%{name: "TOKEN", secret?: true}]
      assert Workspace.worker_env_map(ws) == %{"TOKEN" => "s3cr3t"}

      assert {:ok, ws} = Operations.patch_worker_env(ws.id, %{"TOKEN" => %{"secret" => false}})
      assert Workspace.worker_env_keys(ws) == [%{name: "TOKEN", secret?: false}]
      assert Workspace.worker_env_map(ws) == %{"TOKEN" => "s3cr3t"}

      assert {:ok, ws} = Operations.patch_worker_env(ws.id, %{"TOKEN" => nil})
      assert Workspace.worker_env_keys(ws) == []
    end

    test "rejects an invalid name" do
      ws = workspace()
      assert {:error, _} = Operations.patch_worker_env(ws, %{"1BAD" => %{"value" => "x"}})
    end

    test "concurrent sets of different names both survive" do
      ws = workspace()

      results =
        1..6
        |> Enum.map(fn n ->
          Task.async(fn ->
            Operations.patch_worker_env(ws.id, %{"VAR_#{n}" => %{"value" => "v#{n}"}})
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      {:ok, fresh} = Ash.get(Workspace, ws.id)
      assert Enum.map(Workspace.worker_env_keys(fresh), & &1.name) == for(n <- 1..6, do: "VAR_#{n}")
    end
  end

  describe "standing orders" do
    test "add appends to a missing list and keeps sibling config" do
      ws = workspace(%{"merge" => %{"strategy" => "direct"}})

      assert {:ok, updated} = Operations.add_standing_order(ws, "first")
      assert updated.config["standing_orders"] == ["first"]
      assert updated.config["merge"] == %{"strategy" => "direct"}

      assert {:ok, _} = Operations.add_standing_order(ws.id, "second")
      assert orders(ws.id) == ["first", "second"]
    end

    test "add rejects blank text" do
      ws = workspace()
      assert {:error, {:invalid, _}} = Operations.add_standing_order(ws, "   ")
    end

    test "concurrent adds all survive" do
      ws = workspace()
      expected = for n <- 1..10, do: "order #{n}"

      results =
        expected
        |> Enum.map(fn text -> Task.async(fn -> Operations.add_standing_order(ws.id, text) end) end)
        |> Task.await_many(15_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Enum.sort(orders(ws.id)) == Enum.sort(expected)
    end

    test "remove by 1-based index and by exact text" do
      ws = workspace(%{"standing_orders" => ["a", "b", "c"]})

      assert {:ok, _} = Operations.remove_standing_order(ws, 2)
      assert orders(ws.id) == ["a", "c"]

      assert {:ok, _} = Operations.remove_standing_order(ws.id, "a")
      assert orders(ws.id) == ["c"]
    end

    test "remove accepts a numeric string as an index" do
      ws = workspace(%{"standing_orders" => ["a", "b"]})
      assert {:ok, _} = Operations.remove_standing_order(ws, "1")
      assert orders(ws.id) == ["b"]
    end

    test "remove reports an out-of-range index and an unmatched text" do
      ws = workspace(%{"standing_orders" => ["a"]})
      assert {:error, {:invalid, msg}} = Operations.remove_standing_order(ws, 5)
      assert msg =~ "out of range"
      assert {:error, {:not_found, _}} = Operations.remove_standing_order(ws, "nope")
    end

    test "remove on an empty list is not_found" do
      ws = workspace()
      assert {:error, {:not_found, _}} = Operations.remove_standing_order(ws, 1)
    end

    test "concurrent removes each drop their own entry" do
      ws = workspace(%{"standing_orders" => for(n <- 1..6, do: "o#{n}")})

      results =
        1..6
        |> Enum.map(fn n ->
          Task.async(fn -> Operations.remove_standing_order(ws.id, "o#{n}") end)
        end)
        |> Task.await_many(15_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert orders(ws.id) == []
    end

    test "repo-scoped add/remove touch only that repo's list, matching loosely" do
      ws =
        workspace(%{
          "repo_paths" => %{"my-repo" => %{"path" => "/tmp/x", "target_branch" => "main"}}
        })

      assert {:ok, updated} = Operations.add_standing_order(ws, "repo rule", repo: "my_repo")

      assert updated.config["repo_paths"]["my-repo"] == %{
               "path" => "/tmp/x",
               "target_branch" => "main",
               "standing_orders" => ["repo rule"]
             }

      assert updated.config["standing_orders"] == nil

      assert {:ok, updated} = Operations.remove_standing_order(ws.id, 1, repo: "my-repo")
      assert updated.config["repo_paths"]["my-repo"]["standing_orders"] == []
    end

    test "repo-scoped add refuses an unregistered repo" do
      ws = workspace()
      assert {:error, {:not_found, msg}} = Operations.add_standing_order(ws, "x", repo: "ghost")
      assert msg =~ "ghost"
    end

    test "a string repo_paths entry is promoted to a map" do
      ws = workspace(%{"repo_paths" => %{"r" => "/tmp/r"}})
      assert {:ok, updated} = Operations.add_standing_order(ws, "x", repo: "r")
      assert updated.config["repo_paths"]["r"] == %{"path" => "/tmp/r", "standing_orders" => ["x"]}
    end

    test "an unknown workspace id is not_found" do
      assert {:error, {:not_found, _}} =
               Operations.add_standing_order(Ash.UUID.generate(), "x")
    end
  end
end
