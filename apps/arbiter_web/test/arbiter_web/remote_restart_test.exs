defmodule ArbiterWeb.RemoteRestartTest do
  @moduledoc """
  RW12 (`docs/design/remote-workers.md` §10.4–10.6), across the real halves: a remote
  run does not survive a primary restart. The primary's node sessions are torn
  down (the BEAM restarting: no run table, a new `boot_epoch`); the **real agent**
  reconnects, is told it does not know the run, quiesces it (stops the container,
  bundles the shadow and the transcripts locally, reports `retained`), and
  `Nodes.Recovery.await/1` pulls both into the home clone over real HTTP through the
  §9 quarantine. A node that was lost leaves its run interrupted as `:node_lost`;
  the reaper removes only what the live set and the install label allow.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.NodeAgent.{Config, Connection, Retained, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Recovery, RateLimit, Registry}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias Arbiter.Workers.Run
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"
  @branch "arbiter/e2e"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(System.tmp_dir!(), "rc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
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

    repo = Path.join(root, "primary-home")
    base = home!(repo)

    %{
      node: node,
      stub: stub,
      repo: repo,
      base: base,
      node_home: home,
      config_dir: Path.join(root, "primary-config"),
      agent_config: config,
      root: root,
      cli: cli
    }
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

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", args,
        cd: dir,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}],
        stderr_to_stdout: true
      )

    String.trim_trailing(out)
  end

  defp home!(repo) do
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "lib/a.txt"), "a\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    base = git!(repo, ["rev-parse", "HEAD"])
    git!(repo, ["checkout", "-q", "-b", @branch])
    base
  end

  defp spec(run) do
    %{
      "version" => 1,
      "run" => run,
      "task" => "bd-e2e",
      "name" => "arb-#{run}",
      "install" => Nodes.InstallId.get(),
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
      "checkout" => %{"branch" => @branch, "base" => "main"}
    }
  end

  defp context(ctx) do
    %{
      home: ctx.repo,
      branch: @branch,
      base: "main",
      seeded_paths: [],
      config_dir: ctx.config_dir
    }
  end

  defp place(ctx, run) do
    Executor.prepare(ctx.node.id, spec(run),
      owner: self(),
      checkout: context(ctx)
    )
  end

  # The primary restarting: every session is gone with its run table, and the new BEAM
  # draws a new boot_epoch.
  defp restart_primary! do
    old = Nodes.boot_epoch()

    for {pid, _} <- Registry.list(),
        do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)

    :persistent_term.erase({Nodes, :boot_epoch})
    refute Nodes.boot_epoch() == old
  end

  defp run_row!(node, run_id_label) do
    Ash.create!(Run, %{
      task_id: "bd-#{run_id_label}",
      base_task_id: "bd-#{run_id_label}",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: :working,
      node_id: node.id,
      config_dir: nil,
      started_at: DateTime.utc_now()
    })
  end

  defp assert_eventually(fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          25 -> assert_eventually(fun, tries - 1)
        end
    end
  end

  defp channel_of(session), do: :sys.get_state(session).channel

  defp calls(stub), do: File.read!(Path.join(stub, "calls"))

  # A real Worker whose spawn is placed on the node (`ClaudeSession.start/1` with `node:`),
  # the production path: the Run row, the handle's run id and the container all come from
  # it. The worktree is `ctx.repo` made a private clone (the markers `PrivateClone` reads),
  # so the run is placed with a checkout.
  defp start_remote_worker!(ctx) do
    alias Arbiter.Agents.SecurityPolicy
    alias Arbiter.Worker
    alias Arbiter.Worker.ClaudeSession

    git!(ctx.repo, ["config", "arbiter.mainRepo", ctx.repo])
    git!(ctx.repo, ["config", "arbiter.branch", @branch])

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true
        ] do
      put_env_restoring(:arbiter, key, value)
    end

    sockets = Path.join(ctx.root, "sockets")
    File.mkdir_p!(sockets)
    proxy = Path.join(sockets, "proxy.sock")
    bridge = Path.join(sockets, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: 38_001, bridges: [{38_002, bridge}]], "rtest"}
    end

    task_id = "bd-rw12-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")

    policy =
      SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})

    StubPodman.write_mode(ctx.stub, "hang")
    File.write!(Path.join(ctx.stub, "edit_at"), ctx.repo)

    assert {:ok, {:remote, _} = handle} =
             ClaudeSession.start(
               owner: pid,
               worktree_path: ctx.repo,
               command: ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", "/opt/arbiter/cli/claude"],
               env: [{"CLAUDE_CODE_OAUTH_TOKEN", "tok"}, {"ARB_WORKER_BEAD_ID", task_id}],
               security: policy,
               provider: "claude",
               image: "localhost/arbiter-dev/beam:abc123",
               claude_path: ctx.cli,
               arb_path: ctx.cli,
               egress: egress,
               arb_token: "arb-tok",
               node: %{id: ctx.node.id, capacity: %{}}
             )

    {pid, handle, task_id}
  end

  describe "a primary restart with a live Worker" do
    test "the Worker's shutdown leaves its remote run alone, and the node's retained run is taken back",
         ctx do
      alias Arbiter.Worker

      {pid, handle, _task_id} = start_remote_worker!(ctx)
      _ = Worker.advance(pid, :claude)
      %{run_id: run_id} = Worker.state(pid)
      {:remote, {node_id, node_run, _ref}} = handle

      # the primary's Run row and the node's run are the same run: the row names the node
      # (what Recovery looks runs up by) and the node knows the run by the row's id
      assert node_run == run_id
      assert node_id == ctx.node.id
      assert %{state: :working, node_id: ^node_id} = Ash.get!(Run, run_id)
      assert_eventually(fn -> Executor.live?(handle) end)

      # the application stops: the supervisor shuts the Worker down while the VM is going down
      put_env_restoring(:arbiter, :worker_node_stopping_override, true)
      :ok = GenServer.stop(pid, :shutdown)

      # the run is not written off, and the node was not told to stop it
      assert %{state: :working, outcome: nil, node_id: ^node_id} = Ash.get!(Run, run_id)
      refute calls(ctx.stub) =~ "rm --force"

      # the primary comes back: Recovery takes the retained run's work into the home clone
      restart_primary!()
      run_ctx = context(ctx)

      assert {:ok, %{^run_id => :collected}} =
               Recovery.await(
                 primary?: true,
                 node_timeout_ms: 20_000,
                 total_timeout_ms: 30_000,
                 context_fun: fn %Run{id: ^run_id} -> {:ok, run_ctx} end
               )

      assert File.read!(Path.join(ctx.repo, "edited.txt")) == "edited by the run\n"
      assert Ash.get!(Run, run_id).state == :working
    end
  end

  describe "a Worker stopped while the application keeps running" do
    test "is finalized as before: the run is cancelled on the node and written off", ctx do
      alias Arbiter.Worker

      {pid, handle, _task_id} = start_remote_worker!(ctx)
      %{run_id: run_id} = Worker.state(pid)
      _ = Worker.advance(pid, :claude)
      assert_eventually(fn -> Executor.live?(handle) end)

      put_env_restoring(:arbiter, :worker_node_stopping_override, false)
      :ok = GenServer.stop(pid, :shutdown)

      assert %{state: :finished, outcome: :interrupted, failure_reason: "server shutdown"} =
               Ash.get!(Run, run_id)

      assert_eventually(fn ->
        File.exists?(ctx.stub <> "/calls") and calls(ctx.stub) =~ "rm --force"
      end)
    end
  end

  describe "a primary restart" do
    test "the agent quiesces the run it was told is unknown, and Recovery lands its work in the home clone",
         ctx do
      row = run_row!(ctx.node, "rr1")
      id = row.id
      StubPodman.write_mode(ctx.stub, "hang")
      assert {:ok, prepared} = place(ctx, id)
      assert {:ok, handle} = Executor.open(prepared)
      assert_receive {^handle, {:data, {:eol, "line-1"}}}, 10_000
      refute File.exists?(Path.join(ctx.repo, "edited.txt"))

      restart_primary!()

      # The agent comes back (its backoff is tens of ms), is told "unknown" and quiesces;
      # Recovery is already waiting for it, as in the boot sweep.
      run_ctx = context(ctx)

      assert {:ok, report} =
               Recovery.await(
                 primary?: true,
                 node_timeout_ms: 20_000,
                 total_timeout_ms: 30_000,
                 context_fun: fn %Run{id: ^id} -> {:ok, run_ctx} end
               )

      assert report == %{id => :collected}

      # the container was stopped by name, not left to run against a primary that forgot it
      assert calls(ctx.stub) =~ "rm --force --ignore --time 0 arb-#{id}"

      # the work the run did on the node is in the home clone, uncommitted as it was
      assert File.read!(Path.join(ctx.repo, "edited.txt")) == "edited by the run\n"
      assert git!(ctx.repo, ["status", "--porcelain"]) =~ "edited.txt"
      refute File.exists?(Path.join(ctx.repo, ".mcp.json"))
      assert git!(ctx.repo, ["rev-parse", "refs/arbiter/checkpoint/#{id}"]) != ""

      # and the session JSONL is where `claude --resume` and the usage readers look
      assert File.read!(Path.join(ctx.config_dir, "projects/-work-tree/s1.jsonl")) =~ "summary"

      # the agent has nothing left to offer for it, and the row was left for the Reconciler
      assert Retained.list(ctx.agent_config) == []
      assert Ash.get!(Run, id).state == :working
      assert Runs.run_ids() == []
    end

    test "a run the primary still holds is not quiesced: only unknown runs are", ctx do
      row = run_row!(ctx.node, "rr2")
      StubPodman.write_mode(ctx.stub, "hang")
      assert {:ok, prepared} = place(ctx, row.id)
      assert {:ok, handle} = Executor.open(prepared)
      assert_receive {^handle, {:data, {:eol, "line-1"}}}, 10_000

      # a socket blip, not a restart: the session survives, the run is known
      [{pid, _}] = Registry.list()
      Process.exit(Process.info(pid) |> then(fn _ -> channel_of(pid) end), :kill)

      assert_receive {:node_connection, _, :down}, 5_000
      assert_receive {:node_connection, _, :up}, 10_000
      assert Executor.live?(handle)
      assert Retained.list(ctx.agent_config) == []
      refute calls(ctx.stub) =~ "rm --force"
    end
  end

  describe "reaping" do
    test "only this install's leftovers outside the live set are removed", ctx do
      put_env_restoring(:arbiter, :node_reaper, enabled: true, primary?: fn -> true end)
      install = Nodes.InstallId.get()
      node = ctx.node.id

      labelled = fn name, run, install ->
        %{
          "Names" => [name],
          "Labels" => %{
            "arbiter.run" => run,
            "arbiter.install" => install,
            "arbiter.node" => node
          }
        }
      end

      File.write!(
        Path.join(ctx.stub, "ps.json"),
        Jason.encode!([
          labelled.("arb-dead", "dead", install),
          labelled.("arb-live", "live", install),
          labelled.("arb-other-install", "dead", "another-install")
        ])
      )

      [{pid, _}] = Registry.list()
      assert :ok = Nodes.Session.reap(pid, ["live"])

      assert_eventually(fn ->
        File.exists?(Path.join(ctx.stub, "calls")) and calls(ctx.stub) =~ "arb-dead"
      end)

      assert calls(ctx.stub) =~ "rm --force --ignore --time 0 arb-dead"
      refute calls(ctx.stub) =~ "arb-live"
      refute calls(ctx.stub) =~ "arb-other-install"

      # the node says what it removed, and the primary records it
      assert_eventually(fn ->
        :reaped in Enum.map(Nodes.events(node_id: ctx.node.id), & &1.kind)
      end)
    end

    test "a primary that is not the single instance sends no reap", _ctx do
      put_env_restoring(:arbiter, :node_reaper, enabled: true, primary?: fn -> false end)
      [{pid, _}] = Registry.list()
      assert {:error, :disabled} = Nodes.Session.reap(pid, [])
    end
  end

  describe "a lost node" do
    test "a Worker whose node's session ends is interrupted as :node_lost and asks for its resume",
         ctx do
      alias Arbiter.Agents.SecurityPolicy
      alias Arbiter.Worker
      alias Arbiter.Worker.ClaudeSession

      test = self()

      put_env_restoring(:arbiter, :node_lost_resume,
        enabled: true,
        resume_fun: fn task_id -> send(test, {:resumed, task_id}) && {:ok, :stub} end
      )

      put_env_restoring(:arbiter, :worker_exit_grace_ms, 20)

      for {key, value} <- [
            worker_container_available: true,
            worker_container_network_available: true
          ] do
        put_env_restoring(:arbiter, key, value)
      end

      sockets = Path.join(ctx.root, "sockets")
      File.mkdir_p!(sockets)
      proxy = Path.join(sockets, "proxy.sock")
      bridge = Path.join(sockets, "arb.sock")
      File.write!(proxy, "")
      File.write!(bridge, "")

      egress = fn _opts ->
        {:ok, [proxy_socket: proxy, proxy_port: 38_001, bridges: [{38_002, bridge}]], "rtest"}
      end

      worktree = Path.join(ctx.root, "clone")
      File.mkdir_p!(worktree)

      task_id = "bd-rw12lost-#{System.unique_integer([:positive])}"
      {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")

      policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})

      StubPodman.write_mode(ctx.stub, "hang")

      assert {:ok, {:remote, _} = handle} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: worktree,
                 command: ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", "/opt/arbiter/cli/claude"],
                 env: [{"CLAUDE_CODE_OAUTH_TOKEN", "tok"}, {"ARB_WORKER_BEAD_ID", task_id}],
                 security: policy,
                 provider: "claude",
                 image: "localhost/arbiter-dev/beam:abc123",
                 claude_path: ctx.cli,
                 arb_path: ctx.cli,
                 egress: egress,
                 arb_token: "arb-tok",
                 node: %{id: ctx.node.id, capacity: %{}}
               )

      assert Executor.live?(handle)

      # the node is gone for good: its session gives up and ends (what `lost_after` does),
      # and with it every run on it, flagged node_lost?
      [{session, _}] = Registry.list()
      Nodes.Session.notify(session, {:disconnect, :lost})

      assert_eventually(fn -> match?(%{state: :finished}, Worker.state(pid)) end)
      snap = Worker.state(pid)
      assert snap.outcome == :interrupted
      assert snap.meta.stop_reason.category == :node_lost
      assert Map.get(snap.meta, :resume_attempts, 0) == 0
      assert_receive {:resumed, ^task_id}, 2_000

      run = Ash.get!(Run, snap.run_id)
      assert run.outcome == :interrupted and run.stop_category == "node_lost"

      GenServer.stop(pid, :normal)
    end
  end
end
