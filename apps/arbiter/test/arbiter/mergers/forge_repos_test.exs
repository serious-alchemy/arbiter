defmodule Arbiter.Mergers.ForgeReposTest do
  @moduledoc """
  bd-73zv62: the forge repos a workspace patrols / finalizes, per repo — a
  `merge.repos.<repo>` override on `direct` contributes none, an override onto
  a forge in a `direct` workspace contributes its own.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.ForgeRepos
  alias Arbiter.Tasks.Workspace

  @moduletag :tmp_dir

  defp checkout(dir, name, origin) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: path)

    if origin, do: {_, 0} = System.cmd("git", ["remote", "add", "origin", origin], cd: path)

    path
  end

  defp ws(merge, repo_paths),
    do: %Workspace{id: "ws-forge", name: "forge", config: %{"merge" => merge, "repo_paths" => repo_paths}}

  describe "slugs/2" do
    test "a direct-override repo contributes nothing to a github workspace", %{tmp_dir: dir} do
      paths = %{
        "arbiter" => checkout(dir, "arbiter", "https://github.com/octo/arbiter.git"),
        "infra" => checkout(dir, "infra", "https://github.com/octo/infra.git"),
        "mesaana" => checkout(dir, "mesaana", nil)
      }

      merge = %{"strategy" => "github", "repos" => %{"infra" => %{"strategy" => "direct"}}}

      assert ForgeRepos.slugs(ws(merge, paths)) == ["octo/arbiter"]
    end

    test "a pinned workspace owner/repo is unchanged by a direct-override sibling", %{tmp_dir: dir} do
      paths = %{"arbiter" => checkout(dir, "arbiter", nil), "mesaana" => checkout(dir, "m", nil)}

      merge = %{
        "strategy" => "github",
        "config" => %{"owner" => "serious-alchemy", "repo" => "arbiter"},
        "repos" => %{"mesaana" => %{"strategy" => "direct"}}
      }

      assert ForgeRepos.slugs(ws(merge, paths)) == ["serious-alchemy/arbiter"]
    end

    test "every repo of a direct workspace overridden to direct resolves to none", %{tmp_dir: dir} do
      paths = %{"mesaana" => checkout(dir, "mesaana", nil)}
      merge = %{"strategy" => "github", "repos" => %{"mesaana" => %{"strategy" => "direct"}}}

      assert ForgeRepos.slugs(ws(merge, paths)) == []
    end

    test "a forge override in a direct workspace contributes its own repo", %{tmp_dir: dir} do
      paths = %{
        "local" => checkout(dir, "local", "https://github.com/octo/local.git"),
        "svc" => checkout(dir, "svc", nil)
      }

      merge = %{
        "strategy" => "direct",
        "repos" => %{
          "svc" => %{"strategy" => "github", "config" => %{"owner" => "octo", "repo" => "svc"}}
        }
      }

      assert [%{slug: "octo/svc", repo_key: "svc", strategy: :github}] =
               ForgeRepos.list(ws(merge, paths))
    end

    test "a workspace with no repo_paths keeps the workspace-level pinned repo" do
      merge = %{"strategy" => "github", "config" => %{"owner" => "o", "repo" => "r"}}
      assert ForgeRepos.slugs(ws(merge, %{})) == ["o/r"]

      assert ForgeRepos.slugs(ws(%{"strategy" => "gitlab", "config" => %{"project_id" => 7}}, %{})) ==
               ["7"]

      assert ForgeRepos.slugs(ws(%{"strategy" => "direct"}, %{})) == []
    end

    test "gitlab prefers the pinned project_id unless asked for remotes first", %{tmp_dir: dir} do
      paths = %{"tonic" => checkout(dir, "tonic", "git@gitlab.com:acme/tonic.git")}
      merge = %{"strategy" => "gitlab", "config" => %{"project_id" => 111}}

      assert ForgeRepos.slugs(ws(merge, paths)) == ["111"]
      assert ForgeRepos.slugs(ws(merge, paths), gitlab: :remote_first) == ["acme/tonic"]
    end

    test "remote_first gitlab falls back to the pinned project when no remote resolves",
         %{tmp_dir: dir} do
      paths = %{"tonic" => checkout(dir, "tonic", nil)}
      merge = %{"strategy" => "gitlab", "config" => %{"project_id" => 111}}

      assert ForgeRepos.slugs(ws(merge, paths), gitlab: :remote_first) == ["111"]
    end
  end

  describe "scope/3" do
    test "narrows the workspace to the repo a forge slug belongs to", %{tmp_dir: dir} do
      paths = %{
        "local" => checkout(dir, "local", nil),
        "svc" => checkout(dir, "svc", "https://github.com/octo/svc-renamed.git")
      }

      merge = %{"strategy" => "direct", "repos" => %{"svc" => %{"strategy" => "github"}}}

      scoped = ForgeRepos.scope(ws(merge, paths), "octo/svc-renamed")
      assert Workspace.merger_strategy(scoped) == :github
    end

    test "an unknown slug leaves the workspace unchanged", %{tmp_dir: dir} do
      workspace = ws(%{"strategy" => "github"}, %{"a" => checkout(dir, "a", nil)})
      assert ForgeRepos.scope(workspace, "x/y") == workspace
    end
  end
end
