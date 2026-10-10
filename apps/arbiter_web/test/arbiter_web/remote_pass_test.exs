defmodule ArbiterWeb.RemotePassTest do
  @moduledoc """
  bd-bg87oz, end to end across the real halves: a **conflict pass** placed on a node.

  `ConflictResolver.resolve/1` places the pass (`worker.placement: prefer_remote`) on
  the joined node and cuts its home clone; the **real agent** seeds a shadow clone from
  it over real HTTP (`GET /nodes/runs/:run/seed.bundle`), a stand-in `podman` plays the
  agent's work in that shadow (rebase onto `origin/main`, resolve the conflict, commit:
  a script, since there is no Claude here), and the agent's snapshot comes back through
  the primary's quarantine (`PUT`, fsck, ref and path allowlist) into the home clone.
  The pass's `Worker` then pushes it with the lease pinned to the forge head the node
  was seeded from and judges it by the criterion a local pass gets: the pushed head
  must merge cleanly with the target's CURRENT tip.

  Real git throughout: a repo, a bare forge, and a third party who pushes behind the
  repo's back. What is not here: a real container (the `:node_agent` suite,
  `test/node_agent/`, needs real rootless podman) and a real Claude.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  require Ash.Query

  alias Arbiter.NodeAgent.{Config, Connection, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.RateLimit
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, ContainerSpawn, Watchdog, Worktree}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueue.ConflictResolver
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"

  @agent_work """
  D=$(dirname "$0")
  cd "$1" || exit 1
  git rev-parse HEAD > "$D/seen.head"
  git rev-parse refs/remotes/origin/main > "$D/seen.main"
  git config user.email t@e.com
  git config user.name T
  git config commit.gpgsign false
  git rebase refs/remotes/origin/main > /dev/null 2>&1
  printf 'resolved\\n' > README.md
  git add README.md
  GIT_EDITOR=true git rebase --continue > /dev/null 2>&1
  git rev-parse HEAD > "$D/result.head"
  """

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(System.tmp_dir!(), "rp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    put_env(:worktree_root, Path.join(root, "wt"))
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Nodes.Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "co-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    File.write!(Path.join(stub, "edit"), "")
    File.write!(Path.join(stub, "shadow_script"), @agent_work)
    home = Path.join(root, "node-home")
    rt = Path.join(root, "rt")
    File.mkdir_p!(home)
    File.mkdir_p!(rt)
    cli = Path.join(root, "claude")
    File.write!(cli, "#!/bin/sh\n")
    File.chmod!(cli, 0o755)

    {:ok, config} =
      Config.load(
        env: %{},
        primary_url: "http://127.0.0.1:#{NodeTestEndpoint.port()}",
        node_home: home,
        read_credential: fn _ -> {:ok, credential} end,
        version: @version,
        hb_interval_ms: 200,
        fence_after_ms: 60_000,
        backoff: [base: 20, max: 80],
        readiness_fun: fn -> %{ready: true, installed: true, checks: []} end,
        live_runs_fun: &Runs.inventory/0,
        run_opts: [
          podman: podman,
          runtime_dir: rt,
          require_tmpfs: false,
          image_fun: fn _image, _opts -> :ok end,
          files_fun: fn _sha, _name -> {:ok, cli} end,
          delegated_fun: fn -> ["memory", "pids", "cpu"] end,
          bridges_fun: fn _run, bridges -> {:ok, Enum.map(bridges, fn _ -> cli end)} end
        ]
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)
    start_supervised!({Connection, config: config})
    assert_receive {:node_state, _id, :online}, 10_000

    # The repo, its bare forge, and a ticket whose branch conflicts with main.
    repo = Path.join(root, "repo")
    forge = Path.join(root, "forge.git")
    File.mkdir_p!(repo)
    git!(root, ["init", "-q", "-b", "main", repo])
    configure!(repo)
    commit!(repo, "README.md", "hello\n", "i")
    git!(root, ["init", "-q", "--bare", "-b", "main", forge])
    git!(repo, ["remote", "add", "origin", forge])
    git!(repo, ["push", "-q", "origin", "main"])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rp-ws-#{System.unique_integer([:positive])}",
        prefix: "rpw#{System.unique_integer([:positive])}",
        config: %{
          "worker" => %{"placement" => "prefer_remote"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
        }
      })

    issue = conflicting_ticket(ws, repo)
    inert_lane!(issue)

    %{
      node: node,
      stub: stub,
      root: root,
      repo: repo,
      forge: forge,
      ws: ws,
      issue: issue,
      branch: BranchNamer.derive(issue)
    }
  end

  test "the node is seeded at the forge's tips, its commits come back, the primary pushes and judges them",
       ctx do
    {branch_head, main_tip} = third_party_push!(ctx)
    {stale_main, 0} = git(ctx.repo, ["rev-parse", "refs/remotes/origin/main"])
    refute String.trim(stale_main) == main_tip

    %{worker_pid: pid, worktree_path: wt} = pass!(ctx)
    assert %{meta: %{placed_node_id: id, conflict_start_head: ^branch_head}} = Worker.state(pid)
    assert id == ctx.node.id

    run_on_node!(ctx, pid, wt, "r1")

    # What the node's shadow clone was seeded with: the branch at the forge's
    # current head and origin/main at the forge's current tip, not the stale refs.
    assert seen(ctx, "seen.head") == branch_head
    assert seen(ctx, "seen.main") == main_tip

    # The agent's commit came back through the quarantine into the home clone.
    resolved = seen(ctx, "result.head")
    assert git_out(wt, ["rev-parse", "refs/heads/" <> ctx.branch]) == resolved
    refute resolved == branch_head
    # Nothing has been pushed yet: the primary does that, after `arb done`.
    assert Worktree.remote_head(ctx.repo, ctx.branch) == branch_head

    done!(pid)

    assert conflict_run!(ctx.issue.id).outcome == :succeeded
    assert Worktree.remote_head(ctx.repo, ctx.branch) == resolved
    # The same criterion a local pass is judged by: the pushed head merges cleanly
    # with where the target is now.
    assert Worktree.merge_conflict(ctx.repo, main_tip, resolved) == :clean
    assert Ash.get!(Issue, ctx.issue.id).state == :merging
  end

  test "a third party's push after the node was seeded makes the lease refuse", ctx do
    {branch_head, _main} = third_party_push!(ctx)
    %{worker_pid: pid, worktree_path: wt} = pass!(ctx)
    run_on_node!(ctx, pid, wt, "r2")

    # While the pass was on the node, somebody else pushed to the PR branch.
    intruder = push_to_branch!(ctx, "intruder.txt")
    refute intruder == branch_head

    done!(pid)

    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    assert conflict_run!(ctx.issue.id).failure_reason =~ "push_failed"
    assert Worktree.remote_head(ctx.repo, ctx.branch) == intruder
  end

  test "a pass whose pushed head still conflicts with the target's current tip is unresolved",
       ctx do
    third_party_push!(ctx)
    %{worker_pid: pid, worktree_path: wt} = pass!(ctx)
    run_on_node!(ctx, pid, wt, "r3")

    # main moves on after the seed, into the very lines the node resolved.
    other = clone_other!(ctx)
    commit!(other, "README.md", "main moved again\n", "main rewrites the line")
    git!(other, ["push", "-q", "origin", "main"])
    newest = git_out(other, ["rev-parse", "HEAD"])

    done!(pid)

    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    run = conflict_run!(ctx.issue.id)
    assert run.failure_reason =~ "still conflicts"
    assert run.failure_summary =~ String.slice(newest, 0, 8)
  end

  # ---- the pass and its run on the node ------------------------------------------------

  defp pass!(ctx) do
    row = %{
      id: ctx.node.id,
      name: "co-node",
      state: :online,
      health: :ready,
      labels: [],
      workspace_ids: [],
      live: 0,
      max: 2
    }

    {:ok, %{worker_pid: pid} = info} =
      ConflictResolver.resolve(%{
        task_id: ctx.issue.id,
        workspace_id: ctx.ws.id,
        repo_path: ctx.repo,
        repo: "test/repo",
        start_claude: false,
        slot_admitted: true,
        placement_opts: [nodes: [row], remote_available?: true]
      })

    on_exit(fn ->
      Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
    end)

    info
  end

  # What `ClaudeSession` does for a pass given a `:node`: place the run with the home
  # clone as its checkout; here with the agent's work scripted into the stub podman.
  defp run_on_node!(ctx, _pid, wt, run) do
    # The checkout the production handoff builds (`ClaudeSession` ->
    # `ContainerSpawn.prepare_remote/1`) from the opts `ConflictResolver` gives the
    # session: the pass's target rides in as `:base_branch`.
    assert {:ok, checkout} =
             ContainerSpawn.remote_checkout(
               [workspace: ctx.ws, repo: "test/repo", base_branch: "main"],
               wt,
               Path.join(ctx.root, "primary-config-#{run}")
             )

    assert %{home: ^wt, branch: branch, base: "main"} = checkout
    assert branch == ctx.branch

    spec = %{
      "version" => 1,
      "run" => run,
      "task" => ctx.issue.id,
      "name" => "arb-#{run}",
      "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
      "cwd" => "/work/tree",
      "mounts" => [
        %{"kind" => "worktree", "path" => "/work/tree"},
        %{"kind" => "home", "path" => "/work/home"},
        %{"kind" => "config_dir", "path" => "/work/config"},
        %{"kind" => "tmp", "path" => "/work/tmp"}
      ],
      "env" => %{},
      "secrets" => %{},
      "limits" => %{"memory" => "1g"},
      "command" => ["claude", "--print"],
      "checkout" => %{"branch" => ctx.branch, "base" => checkout.base}
    }

    assert {:ok, prepared} =
             Executor.prepare(ctx.node.id, spec, owner: self(), checkout: checkout)

    assert {:ok, handle} = Executor.open(prepared)
    assert 0 = await_exit(handle)
  end

  defp await_exit(handle) do
    receive do
      {^handle, {:exit_status, status}} -> status
      {^handle, _other} -> await_exit(handle)
    after
      30_000 -> flunk("no exit for #{inspect(handle)}")
    end
  end

  defp seen(ctx, file), do: ctx.stub |> Path.join(file) |> File.read!() |> String.trim()

  defp done!(pid) do
    ref = Process.monitor(pid)
    send(pid, {:__claude_session_done__, "sentinel"})
    _ = :sys.get_state(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      0 -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp conflict_run!(task_id) do
    [run] =
      Run
      |> Ash.Query.filter(task_id == ^task_id and kind == :conflict)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()

    run
  end

  # ---- fixtures ------------------------------------------------------------------------

  defp conflicting_ticket(ws, repo) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "conflicts", workspace_id: ws.id, acceptance: "- works"})

    branch = BranchNamer.derive(issue)
    git!(repo, ["checkout", "-q", "-b", branch])
    commit!(repo, "README.md", "branch side\n", "branch edit")
    git!(repo, ["push", "-q", "origin", branch])
    git!(repo, ["checkout", "-q", "main"])
    commit!(repo, "README.md", "main side\n", "main edit")
    git!(repo, ["push", "-q", "origin", "main"])

    issue
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)
    |> Ash.update!(%{pr_ref: "#77"}, action: :open_pr)
  end

  defp clone_other!(ctx) do
    other = Path.join(ctx.root, "other-#{System.unique_integer([:positive])}")
    git!(ctx.root, ["clone", "-q", ctx.forge, other])
    configure!(other)
    other
  end

  # Someone else pushes to the PR branch and to main, neither of which the repo has
  # fetched.
  defp third_party_push!(ctx) do
    other = clone_other!(ctx)
    git!(other, ["checkout", "-q", ctx.branch])
    commit!(other, "third.txt", "third party\n", "third party on the branch")
    git!(other, ["push", "-q", "origin", ctx.branch])
    branch_head = git_out(other, ["rev-parse", "HEAD"])

    git!(other, ["checkout", "-q", "main"])
    commit!(other, "NEWER.md", "newer\n", "main moved")
    git!(other, ["push", "-q", "origin", "main"])
    {branch_head, git_out(other, ["rev-parse", "HEAD"])}
  end

  defp push_to_branch!(ctx, file) do
    other = clone_other!(ctx)
    git!(other, ["checkout", "-q", ctx.branch])
    commit!(other, file, "intruder\n", "an intruder's commit")
    git!(other, ["push", "-q", "origin", ctx.branch])
    git_out(other, ["rev-parse", "HEAD"])
  end

  defp inert_lane!(issue) do
    lane = PullRequest.lane(adapter: StubMerger, interval_ms: 60_000, initial_delay_ms: 60_000)
    Ash.update!(Ash.get!(Issue, issue.id), %{merge_watch: lane}, action: :record_merge_watch)

    on_exit(fn ->
      case Watchdog.whereis(issue.id) do
        nil -> :ok
        pid -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, pid)
      end
    end)
  end

  defp put_env_restoring(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp git(dir, args) do
    System.cmd("git", args,
      cd: dir,
      env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}],
      stderr_to_stdout: true
    )
  end

  defp git!(dir, args) do
    {out, 0} = git(dir, args)
    String.trim_trailing(out)
  end

  defp git_out(dir, args), do: git!(dir, args)

  defp configure!(dir) do
    git!(dir, ["config", "user.email", "t@e.com"])
    git!(dir, ["config", "user.name", "T"])
    git!(dir, ["config", "commit.gpgsign", "false"])
  end

  defp commit!(dir, file, content, msg) do
    File.write!(Path.join(dir, file), content)
    git!(dir, ["add", file])
    git!(dir, ["commit", "-q", "-m", msg])
  end
end
