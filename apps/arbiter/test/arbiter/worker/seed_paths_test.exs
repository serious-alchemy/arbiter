defmodule Arbiter.Worker.SeedPathsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.SeedPaths

  defp ws(worker), do: %{config: %{"worker" => worker}}

  describe "resolve/2" do
    test "nil when nothing is configured at either level" do
      assert SeedPaths.resolve(nil, "arbiter") == nil
      assert SeedPaths.resolve(%{config: %{}}, "arbiter") == nil
      assert SeedPaths.resolve(%{config: nil}, "arbiter") == nil

      assert SeedPaths.resolve(
               ws(%{"repos" => %{"other" => %{"seed_paths" => ["x"]}}}),
               "arbiter"
             ) == nil
    end

    test "the workspace-level list applies to every repo" do
      workspace = ws(%{"seed_paths" => ["deps", "priv/plts"]})

      assert SeedPaths.resolve(workspace, "arbiter") == ["deps", "priv/plts"]
      assert SeedPaths.resolve(workspace, nil) == ["deps", "priv/plts"]
    end

    test "a per-repo list wins over the workspace-level one (replace, not extend)" do
      workspace =
        ws(%{
          "seed_paths" => ["deps"],
          "repos" => %{"arbiter" => %{"seed_paths" => ["_build/test/lib"]}}
        })

      assert SeedPaths.resolve(workspace, "arbiter") == ["_build/test/lib"]
      assert SeedPaths.resolve(workspace, "other") == ["deps"]
    end

    test "matches the repo key the way repo_paths keys match (owner/name -> name)" do
      workspace = ws(%{"repos" => %{"arbiter" => %{"seed_paths" => ["deps"]}}})

      assert SeedPaths.resolve(workspace, "acme/arbiter") == ["deps"]
    end

    test "an explicit empty list is a configured value: seed nothing" do
      workspace =
        ws(%{"seed_paths" => ["deps"], "repos" => %{"arbiter" => %{"seed_paths" => []}}})

      assert SeedPaths.resolve(workspace, "arbiter") == []
    end

    test "a malformed value reads as unset" do
      assert SeedPaths.resolve(ws(%{"seed_paths" => "deps"}), "arbiter") == nil
      assert SeedPaths.resolve(ws(%{"seed_paths" => ["deps", 3]}), "arbiter") == nil
    end
  end
end
