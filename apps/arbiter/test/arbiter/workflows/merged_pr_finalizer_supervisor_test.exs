defmodule Arbiter.Workflows.MergedPRFinalizerSupervisorTest do
  # async: false — the MergedPRFinalizerSupervisor and its Registry are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.{MergedPRFinalizer, MergedPRFinalizerSupervisor}

  @registry Arbiter.Workflows.MergedPRFinalizerRegistry

  defp start(workspace, opts \\ []) do
    opts = Keyword.put_new(opts, :interval_ms, 600_000)
    result = MergedPRFinalizerSupervisor.start_finalizer(workspace, opts)

    on_exit(fn ->
      for {pid, _} <- Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]),
          is_pid(pid),
          Process.alive?(pid) do
        Arbiter.ProcessTeardown.stop_child(MergedPRFinalizerSupervisor, pid)
      end
    end)

    result
  end

  defp git_repo_with_origin(remote_url) do
    dir = Path.join(System.tmp_dir!(), "finalizer-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["-C", dir, "init", "-q"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", dir, "remote", "add", "origin", remote_url],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp keys_for_workspace(ws_id) do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(fn
      ^ws_id -> true
      key when is_binary(key) -> String.starts_with?(key, ws_id <> ":")
      _ -> false
    end)
    |> Enum.sort()
  end

  describe "start_finalizer/2 — github (regression)" do
    test "starts exactly one finalizer registered under the workspace id" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gh-#{System.unique_integer([:positive])}",
          prefix: "mfg#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "octo",
                "repo" => "widget",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            }
          }
        })

      assert {:ok, pid} = start(ws)
      assert MergedPRFinalizerSupervisor.whereis(ws.id) == pid
      assert MergedPRFinalizer.state(pid).repo == "octo/widget"
    end
  end

  describe "start_finalizer/2 — gitlab single-project workspace" do
    test "starts exactly one finalizer registered under the workspace id" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gl-single-#{System.unique_integer([:positive])}",
          prefix: "mfgs#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "gitlab",
              "config" => %{
                "host" => "gitlab.com",
                "project_id" => 12345,
                "credentials_ref" => "env:GITLAB_TOKEN"
              }
            }
          }
        })

      assert {:ok, pid} = start(ws)
      assert is_pid(pid) and Process.alive?(pid)

      assert MergedPRFinalizerSupervisor.whereis(ws.id) == pid
      assert keys_for_workspace(ws.id) == [ws.id]
      assert MergedPRFinalizer.state(pid).repo == "12345"
    end
  end

  describe "start_finalizer/2 — gitlab multi-repo workspace (emricare/vstim shape)" do
    test "starts one finalizer per repo, derived from repo_paths origin remotes" do
      repo_a = git_repo_with_origin("git@gitlab.com:emricare/tonic.git")
      repo_b = git_repo_with_origin("git@gitlab.com:emricare/tonic_device.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gl-multi-#{System.unique_integer([:positive])}",
          prefix: "mfgm#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "gitlab",
              "config" => %{
                "host" => "gitlab.com",
                "credentials_ref" => "env:GITLAB_TOKEN"
              }
            },
            "repo_paths" => %{"tonic" => repo_a, "tonic_device" => repo_b}
          }
        })

      assert {:ok, _pid} = start(ws)

      assert keys_for_workspace(ws.id) ==
               Enum.sort([
                 "#{ws.id}:emricare/tonic",
                 "#{ws.id}:emricare/tonic_device"
               ])
    end
  end

  describe "start_finalizer/2 — skips" do
    test "skips a workspace with no merge config (direct strategy)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-direct-#{System.unique_integer([:positive])}",
          prefix: "mfd#{System.unique_integer([:positive])}"
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end

    test "skips a gitlab workspace from which no repo can be derived" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gl-norepo-#{System.unique_integer([:positive])}",
          prefix: "mfgn#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "gitlab",
              "config" => %{"host" => "gitlab.com", "credentials_ref" => "env:GITLAB_TOKEN"}
            }
          }
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end
  end

  # bd-6dghdv: a finalizer is pinned to the owner/repo it was started for, and
  # only workspace create and boot used to start one — so after the repo move
  # changed merge.config.owner, the live finalizer kept querying the old repo
  # until a server restart. A workspace :update / :patch_config that changes
  # `config` now reconciles the workspace's finalizers against the new config.
  describe "reconcile on workspace update (bd-6dghdv)" do
    @stub_name Arbiter.Mergers.Github.HTTP

    setup do
      prior_token = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", "test-token-mfs")
      prior_auto_start = Application.fetch_env(:arbiter, :auto_start_refineries)

      on_exit(fn ->
        if prior_token,
          do: System.put_env("GITHUB_TOKEN", prior_token),
          else: System.delete_env("GITHUB_TOKEN")

        restore_auto_start(prior_auto_start)

        # The same update also reconciles the workspace's patrols (bd-7feiul),
        # which may start one for a repo with watched work — stop them.
        for sup <- [
              Arbiter.Workflows.PRPatrolSupervisor,
              Arbiter.Workflows.ReviewPatrolSupervisor
            ],
            {_, pid, _, _} <- DynamicSupervisor.which_children(sup),
            is_pid(pid) do
          Arbiter.ProcessTeardown.stop_child(sup, pid)
        end
      end)

      :ok
    end

    defp restore_auto_start({:ok, value}),
      do: Application.put_env(:arbiter, :auto_start_refineries, value)

    defp restore_auto_start(:error), do: Application.delete_env(:arbiter, :auto_start_refineries)

    # Create first, with auto-start off, so the create hooks (MergeQueue,
    # patrols, …) stay inert; only the update path runs with it on.
    defp github_workspace(merge_config, extra \\ %{}) do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-up-#{System.unique_integer([:positive])}",
          prefix: "mfu#{System.unique_integer([:positive])}",
          config: Map.merge(%{"merge" => github_merge(merge_config)}, extra)
        })

      ws
    end

    defp github_merge(merge_config) do
      %{
        "strategy" => "github",
        "config" => Map.put(merge_config, "credentials_ref", "env:GITHUB_TOKEN")
      }
    end

    defp enable_auto_start, do: Application.put_env(:arbiter, :auto_start_refineries, true)

    defp repos_for_workspace(ws_id) do
      ws_id
      |> keys_for_workspace()
      |> Enum.map(fn key -> MergedPRFinalizer.state(whereis_key(key)).repo end)
      |> Enum.sort()
    end

    defp whereis_key(key) do
      [{pid, _}] = Registry.lookup(@registry, key)
      pid
    end

    test ":update changing merge.config owner retargets the finalizer; its next tick queries the new repo" do
      ws = github_workspace(%{"owner" => "ryanrborn", "repo" => "arbiter"})
      assert {:ok, old_pid} = start(ws)
      assert MergedPRFinalizer.state(old_pid).repo == "ryanrborn/arbiter"

      {:ok, task} =
        Ash.create(Arbiter.Tasks.Issue, %{title: "has a PR", workspace_id: ws.id})

      {:ok, _task} = Ash.update(task, %{pr_ref: "7"}, action: :update)

      enable_auto_start()

      {:ok, ws} =
        Ash.update(
          ws,
          %{
            config: %{
              "merge" => github_merge(%{"owner" => "serious-alchemy", "repo" => "arbiter"})
            }
          },
          action: :update
        )

      new_pid = MergedPRFinalizerSupervisor.whereis(ws.id)
      assert is_pid(new_pid)
      assert new_pid != old_pid
      refute Process.alive?(old_pid)
      assert keys_for_workspace(ws.id) == [ws.id]
      assert MergedPRFinalizer.state(new_pid).repo == "serious-alchemy/arbiter"

      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, {:requested, conn.request_path})
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      Req.Test.allow(@stub_name, self(), new_pid)
      :ok = MergedPRFinalizer.tick(new_pid)

      assert_received {:requested, "/repos/serious-alchemy/arbiter/pulls/7"}
      refute_received {:requested, "/repos/ryanrborn/" <> _}
    end

    test ":patch_config changing merge.config owner retargets the finalizer" do
      ws = github_workspace(%{"owner" => "ryanrborn", "repo" => "arbiter"})
      assert {:ok, old_pid} = start(ws)

      enable_auto_start()

      {:ok, ws} =
        Ash.update(
          ws,
          %{patch: %{"merge" => %{"config" => %{"owner" => "serious-alchemy"}}}},
          action: :patch_config
        )

      new_pid = MergedPRFinalizerSupervisor.whereis(ws.id)
      assert is_pid(new_pid) and new_pid != old_pid
      assert MergedPRFinalizer.state(new_pid).repo == "serious-alchemy/arbiter"
    end

    test "a repo_paths change starts and stops per-repo finalizers to match" do
      repo_a = git_repo_with_origin("git@github.com:acme/alpha.git")
      repo_b = git_repo_with_origin("git@github.com:acme/beta.git")

      ws = github_workspace(%{"owner" => "acme"}, %{"repo_paths" => %{"alpha" => repo_a}})
      assert {:ok, _pid} = start(ws)
      assert keys_for_workspace(ws.id) == [ws.id]
      assert repos_for_workspace(ws.id) == ["acme/alpha"]

      enable_auto_start()

      {:ok, ws} =
        Ash.update(
          ws,
          %{
            config: %{
              "merge" => github_merge(%{"owner" => "acme"}),
              "repo_paths" => %{"alpha" => repo_a, "beta" => repo_b}
            }
          },
          action: :update
        )

      assert keys_for_workspace(ws.id) == ["#{ws.id}:acme/alpha", "#{ws.id}:acme/beta"]
      assert repos_for_workspace(ws.id) == ["acme/alpha", "acme/beta"]

      {:ok, ws} =
        Ash.update(
          ws,
          %{
            config: %{
              "merge" => github_merge(%{"owner" => "acme"}),
              "repo_paths" => %{"beta" => repo_b}
            }
          },
          action: :update
        )

      assert keys_for_workspace(ws.id) == [ws.id]
      assert repos_for_workspace(ws.id) == ["acme/beta"]
    end

    test "an update that drops the GitHub merge config stops the finalizer" do
      ws = github_workspace(%{"owner" => "ryanrborn", "repo" => "arbiter"})
      assert {:ok, old_pid} = start(ws)

      enable_auto_start()

      {:ok, ws} = Ash.update(ws, %{config: %{}}, action: :update)

      refute Process.alive?(old_pid)
      assert keys_for_workspace(ws.id) == []
    end

    test "an update that leaves config alone keeps the running finalizer" do
      ws = github_workspace(%{"owner" => "ryanrborn", "repo" => "arbiter"})
      assert {:ok, pid} = start(ws)

      enable_auto_start()

      {:ok, ws} = Ash.update(ws, %{description: "renamed"}, action: :update)

      assert MergedPRFinalizerSupervisor.whereis(ws.id) == pid
    end

    test "a config update with the same repo keeps the running finalizer" do
      ws = github_workspace(%{"owner" => "ryanrborn", "repo" => "arbiter"})
      assert {:ok, pid} = start(ws)

      enable_auto_start()

      {:ok, ws} =
        Ash.update(
          ws,
          %{
            config: %{
              "merge" => github_merge(%{"owner" => "ryanrborn", "repo" => "arbiter"}),
              "tracker" => %{"type" => "none"}
            }
          },
          action: :update
        )

      assert MergedPRFinalizerSupervisor.whereis(ws.id) == pid
    end
  end
end
