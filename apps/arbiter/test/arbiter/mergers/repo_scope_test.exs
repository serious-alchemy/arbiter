defmodule Arbiter.Mergers.RepoScopeTest do
  @moduledoc """
  bd-73zv62: the per-repo merge override (`merge.repos.<repo>`) and the single
  resolver every merge-config reader goes through.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Mergers
  alias Arbiter.Tasks.Workspace

  defp ws(merge, repo_paths \\ %{}) do
    %Workspace{
      id: "ws-scope",
      name: "scope",
      config: %{"merge" => merge, "repo_paths" => repo_paths}
    }
  end

  @github %{
    "strategy" => "github",
    "auto_merge" => true,
    "branch_prefix" => "feature/",
    "config" => %{
      "owner" => "serious-alchemy",
      "repo" => "arbiter",
      "credentials_ref" => "env:GITHUB_TOKEN"
    },
    "repos" => %{
      "mesaana" => %{"strategy" => "direct"},
      "other" => %{"config" => %{"repo" => "other-repo"}, "auto_merge" => false}
    }
  }

  describe "merge_config/2" do
    test "a repo with no override resolves to the workspace-level merge block" do
      merge = Mergers.merge_config(ws(@github), "arbiter")

      assert merge["strategy"] == "github"
      assert merge["config"]["repo"] == "arbiter"
      refute Map.has_key?(merge, "repos")
    end

    test "a repo override replaces only the fields it sets" do
      merge = Mergers.merge_config(ws(@github), "mesaana")

      assert merge["strategy"] == "direct"
      # everything else falls back field by field
      assert merge["auto_merge"] == true
      assert merge["branch_prefix"] == "feature/"
    end

    test "a nested config override deep-merges over the workspace config" do
      merge = Mergers.merge_config(ws(@github), "other")

      assert merge["strategy"] == "github"
      assert merge["auto_merge"] == false

      assert merge["config"] == %{
               "owner" => "serious-alchemy",
               "repo" => "other-repo",
               "credentials_ref" => "env:GITHUB_TOKEN"
             }
    end

    test "matches the override the same way repo_paths keys match (slug-normalised)" do
      merge = %{"strategy" => "github", "repos" => %{"tonic_device" => %{"strategy" => "direct"}}}

      assert Mergers.merge_config(ws(merge), "tonic-device")["strategy"] == "direct"
      assert Mergers.merge_config(ws(merge), "acme/tonic_device")["strategy"] == "direct"
    end

    test "a nil repo is the workspace-level view, repos block included" do
      assert Mergers.merge_config(ws(@github), nil) == @github
    end

    test "tolerates a missing or malformed merge block" do
      assert Mergers.merge_config(%Workspace{config: nil}, "x") == %{}
      assert Mergers.merge_config(ws(%{"repos" => "nope"}), "x") == %{}
      assert Mergers.merge_config(ws(%{"repos" => %{"x" => "nope"}}), "x") == %{}
    end
  end

  describe "scope/2" do
    test "returns a workspace whose merge block is the repo's effective one" do
      scoped = Mergers.scope(ws(@github), "mesaana")

      assert Workspace.merger_strategy(scoped) == :direct
      assert scoped.config["repo_paths"] == %{}
      assert scoped.id == "ws-scope"
    end

    test "is idempotent — re-scoping a scoped workspace changes nothing" do
      scoped = Mergers.scope(ws(@github), "mesaana")
      assert Mergers.scope(scoped, "mesaana") == scoped
      assert Mergers.scope(scoped, "other") == scoped
    end

    test "a nil repo or nil workspace passes through unchanged" do
      assert Mergers.scope(ws(@github), nil) == ws(@github)
      assert Mergers.scope(nil, "mesaana") == nil
    end
  end

  describe "resolve/2 / for_repo/2 / strategy/2" do
    test "returns the adapter plus the effective config for each repo" do
      assert {Mergers.Direct, %{"strategy" => "direct"}} = Mergers.resolve(ws(@github), "mesaana")
      assert {Mergers.Github, %{"strategy" => "github"}} = Mergers.resolve(ws(@github), "arbiter")

      assert Mergers.for_repo(ws(@github), "mesaana") == Mergers.Direct
      assert Mergers.strategy(ws(@github), "mesaana") == :direct
      assert Mergers.strategy(ws(@github), "arbiter") == :github
    end

    test "a repo can opt into a forge while the workspace merges directly" do
      merge = %{"strategy" => "direct", "repos" => %{"svc" => %{"strategy" => "gitlab"}}}

      assert Mergers.strategy(ws(merge), "svc") == :gitlab
      assert Mergers.strategy(ws(merge), "anything-else") == :direct
    end
  end

  describe "for_task/1" do
    test "resolves from the task's workspace and repo" do
      task = %Arbiter.Tasks.Issue{repo: "mesaana", workspace: ws(@github)}
      assert {Mergers.Direct, %{"strategy" => "direct"}} = Mergers.for_task(task)

      task = %Arbiter.Tasks.Issue{repo: "arbiter", workspace: ws(@github)}
      assert {Mergers.Github, _} = Mergers.for_task(task)
    end
  end

  describe "repo_strategies/1" do
    test "maps every repo_paths key to its effective strategy" do
      workspace = ws(@github, %{"arbiter" => "/src/arbiter", "mesaana" => "/src/mesaana"})

      assert Mergers.repo_strategies(workspace) == %{"arbiter" => :github, "mesaana" => :direct}
    end

    test "is empty with no repo_paths" do
      assert Mergers.repo_strategies(ws(@github)) == %{}
    end
  end

  describe "forge?/1" do
    test "only github and gitlab have a forge" do
      assert Mergers.forge?(:github)
      assert Mergers.forge?(:gitlab)
      refute Mergers.forge?(:direct)
    end
  end
end
