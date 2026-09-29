defmodule Arbiter.Mergers.RoutingCheckTest do
  @moduledoc """
  bd-73zv62 AC6: doctor flags a repo whose effective strategy is a forge but
  whose checkout has no remote (the mesaana situation), or whose remote is a
  different repository than the effective `owner/repo`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.RoutingCheck
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
    do: %Workspace{
      id: "ws-rc",
      name: "default",
      config: %{"merge" => merge, "repo_paths" => repo_paths}
    }

  defp by_repo(entries), do: Map.new(entries, &{&1.repo, &1})

  test "the mesaana situation: a remote-less repo under the workspace's github strategy", %{
    tmp_dir: dir
  } do
    workspace =
      ws(
        %{
          "strategy" => "github",
          "config" => %{"owner" => "serious-alchemy", "repo" => "arbiter"}
        },
        %{
          "arbiter" => checkout(dir, "arbiter", "git@github.com:serious-alchemy/arbiter.git"),
          "mesaana" => checkout(dir, "mesaana", nil)
        }
      )

    entries = by_repo(RoutingCheck.check_workspace(workspace))

    assert %{strategy: "github", problem: nil, remote: "serious-alchemy/arbiter"} =
             entries["arbiter"]

    assert %{strategy: "github", problem: :no_remote, remote: nil} = entries["mesaana"]
    assert entries["mesaana"].fix =~ "arb config set merge.repos.mesaana.strategy direct"
    assert entries["mesaana"].workspace == "default"
  end

  test "the fix — a direct override — clears it", %{tmp_dir: dir} do
    workspace =
      ws(
        %{
          "strategy" => "github",
          "config" => %{"owner" => "serious-alchemy", "repo" => "arbiter"},
          "repos" => %{"mesaana" => %{"strategy" => "direct"}}
        },
        %{
          "arbiter" => checkout(dir, "arbiter", "https://github.com/serious-alchemy/arbiter"),
          "mesaana" => checkout(dir, "mesaana", nil)
        }
      )

    entries = by_repo(RoutingCheck.check_workspace(workspace))
    assert %{strategy: "direct", problem: nil} = entries["mesaana"]
    assert %{strategy: "github", problem: nil} = entries["arbiter"]
  end

  test "a repo whose remote is a different repository than the pinned owner/repo", %{
    tmp_dir: dir
  } do
    workspace =
      ws(
        %{
          "strategy" => "github",
          "config" => %{"owner" => "serious-alchemy", "repo" => "arbiter"}
        },
        %{"infra" => checkout(dir, "infra", "git@github.com:serious-alchemy/infra.git")}
      )

    assert [entry] = RoutingCheck.check_workspace(workspace)
    assert entry.problem == :remote_mismatch
    assert entry.expected == "serious-alchemy/arbiter"
    assert entry.remote == "serious-alchemy/infra"
    assert entry.fix =~ "merge.repos.infra"
  end

  test "owner/repo comparison ignores case", %{tmp_dir: dir} do
    workspace =
      ws(
        %{
          "strategy" => "github",
          "config" => %{"owner" => "Serious-Alchemy", "repo" => "Arbiter"}
        },
        %{"arbiter" => checkout(dir, "arbiter", "git@github.com:serious-alchemy/arbiter.git")}
      )

    assert [%{problem: nil}] = RoutingCheck.check_workspace(workspace)
  end

  test "an unpinned github workspace derives owner/repo from each remote — only a missing remote is a problem",
       %{tmp_dir: dir} do
    workspace =
      ws(%{"strategy" => "github", "config" => %{"owner" => "octo"}}, %{
        "a" => checkout(dir, "a", "https://github.com/octo/a.git"),
        "b" => checkout(dir, "b", nil)
      })

    entries = by_repo(RoutingCheck.check_workspace(workspace))
    assert entries["a"].problem == nil
    assert entries["b"].problem == :no_remote
  end

  test "a gitlab repo with no remote is flagged; direct repos never are", %{tmp_dir: dir} do
    workspace =
      ws(
        %{
          "strategy" => "gitlab",
          "config" => %{"project_id" => 5},
          "repos" => %{"local" => %{"strategy" => "direct"}}
        },
        %{"tonic" => checkout(dir, "tonic", nil), "local" => checkout(dir, "local", nil)}
      )

    entries = by_repo(RoutingCheck.check_workspace(workspace))
    assert entries["tonic"].problem == :no_remote
    assert entries["local"].problem == nil
  end

  test "a workspace with no repo_paths has nothing to check" do
    assert RoutingCheck.check_workspace(ws(%{"strategy" => "github"}, %{})) == []
  end
end
