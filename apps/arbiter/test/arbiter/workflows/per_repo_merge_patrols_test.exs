defmodule Arbiter.Workflows.PerRepoMergePatrolsTest do
  @moduledoc """
  bd-73zv62 AC5: PRPatrol, ReviewPatrol and MergedPRFinalizer run only for
  repos whose **effective** merge strategy has a forge. A repo on a
  `merge.repos.<repo>.strategy = "direct"` override spawns none of them, even
  with watched work open against it; a repo overridden onto a forge inside a
  `direct` workspace gets its own.
  """
  # async: false — the three supervisors and their registries are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace

  alias Arbiter.Workflows.{
    MergedPRFinalizerSupervisor,
    PRPatrol,
    PRPatrolSupervisor,
    ReviewPatrolSupervisor
  }

  @supervisors [
    {PRPatrolSupervisor, Arbiter.Workflows.PRPatrolRegistry},
    {ReviewPatrolSupervisor, Arbiter.Workflows.ReviewPatrolRegistry},
    {MergedPRFinalizerSupervisor, Arbiter.Workflows.MergedPRFinalizerRegistry}
  ]

  setup do
    on_exit(fn ->
      for {sup, registry} <- @supervisors,
          {pid, _} <- Registry.select(registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]),
          is_pid(pid),
          Process.alive?(pid) do
        Arbiter.ProcessTeardown.stop_child(sup, pid)
      end
    end)

    :ok
  end

  defp checkout(origin) do
    dir = Path.join(System.tmp_dir!(), "per-repo-merge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["-C", dir, "init", "-q"], stderr_to_stdout: true)

    if origin do
      {_, 0} =
        System.cmd("git", ["-C", dir, "remote", "add", "origin", origin], stderr_to_stdout: true)
    end

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp workspace!(merge, repo_paths) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "per-repo-#{System.unique_integer([:positive])}",
        prefix: "pr#{System.unique_integer([:positive])}",
        config: %{"merge" => merge, "repo_paths" => repo_paths}
      })

    ws
  end

  # Watched work for every lazy-start gate: an open fleet PR (PRPatrol), an
  # open review engagement (ReviewPatrol). The finalizer has no gate.
  defp watched_work!(ws, pr_ref) do
    task =
      issue_without_repo!(%{
        title: "authored-#{System.unique_integer([:positive])}",
        description: "d",
        issue_type: :feature,
        tracker_type: :none,
        workspace_id: ws.id
      })

    {:ok, _} = Ash.update(task, %{pr_ref: pr_ref}, action: :update)

    issue_without_repo!(%{
      title: "eng-#{System.unique_integer([:positive])}",
      tracker_type: :none,
      source_pr: pr_ref,
      review_only: true,
      workspace_id: ws.id
    })
  end

  defp start_all(ws) do
    %{
      pr_patrol: PRPatrolSupervisor.start_patrol(ws, interval_ms: 600_000),
      review_patrol: ReviewPatrolSupervisor.start_patrol(ws, interval_ms: 600_000),
      finalizer: MergedPRFinalizerSupervisor.start_finalizer(ws, interval_ms: 600_000)
    }
  end

  defp repos_running(ws_id) do
    Map.new(@supervisors, fn {sup, registry} ->
      repos =
        registry
        |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.filter(fn {key, _} ->
          is_binary(key) and (key == ws_id or String.starts_with?(key, ws_id <> ":"))
        end)
        |> Enum.map(fn {_key, repo} -> repo end)
        |> Enum.sort()

      {sup, repos}
    end)
  end

  test "a direct-override repo gets no patrol or finalizer; its forge sibling does" do
    ws =
      workspace!(
        %{
          "strategy" => "github",
          "config" => %{"owner" => "octo", "credentials_ref" => "env:GITHUB_TOKEN"},
          "repos" => %{
            "infra" => %{"strategy" => "direct"},
            "mesaana" => %{"strategy" => "direct"}
          }
        },
        %{
          "arbiter" => checkout("https://github.com/octo/arbiter.git"),
          # has a GitHub remote, but merges directly
          "infra" => checkout("https://github.com/octo/infra.git"),
          # remote-less
          "mesaana" => checkout(nil)
        }
      )

    watched_work!(ws, "octo/arbiter#1")
    watched_work!(ws, "octo/infra#1")

    assert %{pr_patrol: {:ok, _}, review_patrol: {:ok, _}, finalizer: {:ok, _}} = start_all(ws)

    assert repos_running(ws.id) == %{
             PRPatrolSupervisor => ["octo/arbiter"],
             ReviewPatrolSupervisor => ["octo/arbiter"],
             MergedPRFinalizerSupervisor => ["octo/arbiter"]
           }
  end

  test "a workspace whose every repo is overridden to direct starts nothing" do
    ws =
      workspace!(
        %{
          "strategy" => "github",
          "config" => %{"owner" => "octo", "repo" => "infra", "credentials_ref" => "x"},
          "repos" => %{"infra" => %{"strategy" => "direct"}}
        },
        %{"infra" => checkout("https://github.com/octo/infra.git")}
      )

    watched_work!(ws, "#1")

    assert %{pr_patrol: :skip, review_patrol: :skip, finalizer: :skip} = start_all(ws)

    assert repos_running(ws.id) == %{
             PRPatrolSupervisor => [],
             ReviewPatrolSupervisor => [],
             MergedPRFinalizerSupervisor => []
           }
  end

  test "a forge-override repo in a direct workspace is patrolled against its own repo" do
    ws =
      workspace!(
        %{
          "strategy" => "direct",
          "repos" => %{
            "svc" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "svc", "credentials_ref" => "x"}
            }
          }
        },
        %{"local" => checkout(nil), "svc" => checkout(nil)}
      )

    watched_work!(ws, "#1")

    assert %{pr_patrol: {:ok, pid}, review_patrol: {:ok, _}, finalizer: {:ok, _}} = start_all(ws)
    assert PRPatrol.state(pid).repo == "octo/svc"

    assert repos_running(ws.id) == %{
             PRPatrolSupervisor => ["octo/svc"],
             ReviewPatrolSupervisor => ["octo/svc"],
             MergedPRFinalizerSupervisor => ["octo/svc"]
           }
  end
end
