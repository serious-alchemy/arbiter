defmodule ArbiterWeb.RemoteResumeTest do
  @moduledoc """
  bd-4ic681, end to end across the real halves: a **session resume placed on a node**,
  of a run that another node was working when the primary restarted.

    1. Node A runs the ticket's implementer: it commits in its shadow clone, leaves
       work uncommitted and writes the session transcript (a stand-in `podman` plays
       the agent, `agent_script`).
    2. The primary restarts. The real agent reconnects and is told to `hold` the run;
       a resume asked for now is **held** (AC3): the work is still on node A.
    3. `Nodes.Recovery.await/1` collects the run over real HTTP: its commits and
       uncommitted work land in the ticket's home clone through the §9 quarantine,
       its transcript in the run's config dir. The Reconciler settles the row.
    4. The same agent comes back as **node B** (another credential, another node home).
       `Dispatch.resume_session/2` places the resume there (`prefer_remote`): node B's
       shadow is seeded from the home clone, uncommitted work included (AC4), its
       first open runs `claude --resume <sid>`, and the transcript it continues is
       fetched, redacted, to the slug of the run's cwd (AC2). The fake agent continues
       it, and the next checkpoint brings the longer transcript back.

  Real git and a real `Arbiter.Worker`; what is not here is a real container (the
  `:node_agent` suite, `test/node_agent/`, needs real rootless podman) and a real Claude.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.NodeAgent.{Config, Connection, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Recovery, Registry}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Dispatch, Worktree}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias Arbiter.Workers.{Reconciler, Run}
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"
  @repo "test/resume-repo"
  @sid "7d0c3a8e-1f4b-4e6a-9b2d-5c8f1e3a7b90"
  @secret "tok_WORKSPACE_SECRET_4ic681"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(System.tmp_dir!(), "rz-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    put_env_restoring(:arbiter, :worktree_root, Path.join(root, "wt"))
    put_env_restoring(:arbiter, :output_log_root, Path.join(root, "logs"))

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_deps_cache: false
        ],
        do: put_env_restoring(:arbiter, key, value)

    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    StubPodman.write_mode(stub, "hang")
    cli = Path.join(root, "claude")
    File.write!(cli, "#!/bin/sh\n")
    File.chmod!(cli, 0o755)

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: Path.join(root, "agent-status.json")})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)

    # The repo and the ticket: a podman workspace that prefers nodes, its home clone a
    # private clone at the ticket's worktree path, the ticket In progress.
    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "lib/a.txt"), "a\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    forge = Path.join(root, "forge.git")
    git!(root, ["init", "-q", "--bare", "-b", "main", forge])
    git!(repo, ["remote", "add", "origin", forge])
    git!(repo, ["push", "-q", "origin", "main"])
    put_env_restoring(:arbiter, :repo_paths, %{@repo => repo})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rz-#{System.unique_integer([:positive])}",
        prefix: "rz#{System.unique_integer([:positive])}",
        config: %{
          "worker" => %{"placement" => "prefer_remote"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
        },
        worker_env: %{"API_TOKEN" => %{"value" => @secret, "secret" => true}}
      })

    {:ok, issue} = Ash.create(Issue, %{title: "resume me", workspace_id: ws.id})
    {:ok, issue} = Issue.start_work(issue)
    branch = BranchNamer.derive(issue)
    {:ok, home} = Worktree.create(repo, branch, "main", layout: :private_clone)

    # what `Dispatch` would need to resume a Claude session
    {:ok, _} =
      Ash.create(UsageEvent, %{
        task_id: issue.id,
        workspace_id: ws.id,
        repo: @repo,
        step: :work,
        provider: "claude",
        session_id: @sid,
        occurred_at: DateTime.utc_now()
      })

    %{
      root: root,
      stub: stub,
      podman: podman,
      cli: cli,
      ws: ws,
      issue: issue,
      branch: branch,
      home: home,
      node_a: enroll!("node-a"),
      node_b: enroll!("node-b")
    }
  end

  test "a session resume lands on another node with the collected work and the transcript it continues",
       ctx do
    connect_agent!(ctx, ctx.node_a, "home-a")

    # 1. Node A works the ticket.
    r1 = run_row!(ctx)
    write_agent_script!(ctx, node_a_work())
    assert {:ok, prepared} = place_on_a(ctx, r1)
    assert {:ok, handle} = Executor.open(prepared)
    assert_receive {^handle, {:data, {:eol, "line-1"}}}, 15_000
    node_a_commit = seen(ctx, "node_a.head")

    # 2. The primary restarts. The agent reconnects and is told to hold the run.
    restart_primary!()
    await_hold!(ctx.node_a.id, r1.id)

    # AC3: the work is still on node A, so a resume waits for its collect.
    assert {:error, {:no_node_capacity, held}} =
             Dispatch.resume_session(ctx.issue.id, resume_opts(ctx))

    assert held.reason == :awaiting_collect
    assert [%{run: run_id, node: "node-a"}] = held.runs
    assert run_id == r1.id
    assert Worker.whereis(ctx.issue.id) == nil

    # 3. Recovery takes the run back into the home clone; the Reconciler settles its row.
    # A held run whose container still runs would be adopted by a new Worker instead
    # (bd-4p1vui; the next test): this is the run adoption does not take (switched off
    # here, as for an agent without `run_adopt` or a container that stopped).
    assert {:ok, %{^run_id => :collected}} =
             Recovery.await(
               primary?: true,
               adopt?: false,
               node_timeout_ms: 20_000,
               total_timeout_ms: 30_000
             )

    assert git!(ctx.home, ["rev-parse", "refs/heads/" <> ctx.branch]) == node_a_commit
    assert File.read!(Path.join(ctx.home, "wip-a.txt")) == "uncommitted on node A\n"
    assert {:ok, prior} = ClaudeSessionFile.locate(r1.config_dir, @sid)
    assert File.read!(prior) =~ @secret
    assert {:ok, _} = Reconciler.reconcile_orphaned_runs(primary?: true)
    assert %{state: :finished} = Ash.get!(Run, r1.id)

    # 4. The same machine comes back as node B; the resume is placed there.
    stop_supervised!(Connection)
    connect_agent!(ctx, ctx.node_b, "home-b")
    write_agent_script!(ctx, node_b_resume())

    assert {:ok, %{worker_pid: pid}} = Dispatch.resume_session(ctx.issue.id, resume_opts(ctx))
    stop_worker_first!(pid)
    # The fake agent's last write: what it wrote before is whole (a redirect creates its
    # file before the command has written to it).
    assert_eventually(fn -> File.exists?(Path.join(ctx.stub, "r2.done")) end)

    %{run_id: r2_id} = Worker.state(pid)
    r2 = Ash.get!(Run, r2_id)
    assert r2.node_id == ctx.node_b.id

    # AC2: `claude --resume <sid>` ...
    argv = ctx.stub |> Path.join("r2.argv") |> File.read!() |> String.split("\n")
    assert ["--resume", @sid | _] = Enum.drop_while(argv, &(&1 != "--resume"))

    # ... in the primary's worktree path, where the transcript sits at its slug, secret-free
    assert seen(ctx, "r2.cwd") == ctx.home
    transcript = File.read!(Path.join(ctx.stub, "r2.transcript"))
    assert transcript =~ "start the task"
    refute transcript =~ @secret
    assert transcript =~ "[REDACTED]"

    # AC4: node B's shadow holds node A's commit, and its uncommitted work, uncommitted
    assert node_a_commit in String.split(File.read!(Path.join(ctx.stub, "r2.log")), "\n")
    assert File.read!(Path.join(ctx.stub, "r2.status")) =~ "wip-a.txt"

    # The fake agent continued the conversation; a checkpoint brings it back to the
    # primary, into the resumed run's own config dir.
    assert {:ok, _} = Executor.collect({:remote, {ctx.node_b.id, r2_id, make_ref()}}, :checkout)

    assert_eventually(fn ->
      case ClaudeSessionFile.locate(Ash.get!(Run, r2_id).config_dir, @sid) do
        {:ok, path} -> File.read!(path) =~ "continued on node B"
        :not_found -> false
      end
    end)
  end

  # bd-4p1vui composes with the wait for collect: with adoption on (the default), the run
  # node A held across the restart goes to a new Worker through the real
  # `Dispatch.adopt/2`, which the resume's hold does not block. A resume asked before
  # that is held; one asked after is refused, since the ticket's run is live under its
  # new Worker. Nothing is placed anywhere else.
  test "a held run a new Worker adopts is never raced by a resume", ctx do
    connect_agent!(ctx, ctx.node_a, "home-a")
    r1 = run_row!(ctx)
    run_id = r1.id
    write_agent_script!(ctx, node_a_work())
    assert {:ok, prepared} = place_on_a(ctx, r1)
    assert {:ok, handle} = Executor.open(prepared)
    assert_receive {^handle, {:data, {:eol, "line-1"}}}, 15_000

    restart_primary!()
    await_hold!(ctx.node_a.id, run_id)

    assert {:error, {:no_node_capacity, %{reason: :awaiting_collect, phrase: phrase}}} =
             Dispatch.resume_session(ctx.issue.id, resume_opts(ctx))

    assert phrase =~ "(held); it is adopted or collected first"

    adopt = fn run, opts -> Dispatch.adopt(run, Keyword.merge(resume_opts(ctx), opts)) end

    assert {:ok, %{^run_id => :adopted}} =
             Recovery.await(
               primary?: true,
               adopt_fun: adopt,
               node_timeout_ms: 20_000,
               total_timeout_ms: 30_000
             )

    adopter = Worker.whereis(ctx.issue.id)
    stop_worker_first!(adopter)
    assert %{run_id: ^run_id} = Worker.state(adopter)

    # The run is its Worker's now, not a node's claim; a resume is refused as active work.
    assert Recovery.pending_collect(ctx.issue.id, gate_open?: true) == []

    assert {:error, {:worker_active, _}} =
             Dispatch.resume_session(ctx.issue.id, resume_opts(ctx))

    assert Worker.whereis(ctx.issue.id) == adopter
    assert [%{id: ^run_id}] = Ash.read!(Run) |> Enum.filter(&(&1.task_id == ctx.issue.id))
    assert container_starts(ctx) == 1
    assert Arbiter.NodeAgent.Run.info(run_id)["state"] == "running"
  end

  # Stops `worker` before the agent connection, the node endpoint and the run table
  # (all `start_supervised`) are torn down, not after: ExUnit stops the test
  # supervisor first and runs `on_exit` callbacks after it, so a Worker stopped from
  # `on_exit` spends its last moments reacting to the node vanishing underneath it,
  # writing its run row while the test is already over. This guard is started after
  # all of them, so the supervisor shuts it down first, and it stops the Worker (a
  # quiesced `terminate/2`, the run row finalised) while everything it talks to is
  # still up. `on_exit` stays as a backstop for a Worker the guard never saw.
  defp stop_worker_first!(worker) do
    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, worker) end)

    start_supervised!(%{
      id: {:worker_guard, worker},
      start: {__MODULE__, :start_worker_guard, [worker]},
      shutdown: 20_000
    })
  end

  @doc false
  def start_worker_guard(worker),
    do: :proc_lib.start_link(__MODULE__, :worker_guard, [self(), worker])

  @doc false
  def worker_guard(parent, worker) do
    Process.flag(:trap_exit, true)
    :proc_lib.init_ack(parent, {:ok, self()})

    receive do
      {:EXIT, ^parent, reason} ->
        ref = Process.monitor(worker)
        Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, worker)

        receive do
          {:DOWN, ^ref, :process, ^worker, _} -> :ok
        after
          20_000 -> :ok
        end

        exit(reason)
    end
  end

  defp container_starts(ctx) do
    ctx.stub
    |> Path.join("calls")
    |> File.read!()
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "run "))
  end

  # ---- node A's run ------------------------------------------------------------------

  # The live row a remote implementer has: on node A, its session's transcript in its
  # own config dir on the primary (where the node's uploads land).
  defp run_row!(ctx) do
    Ash.create!(Run, %{
      task_id: ctx.issue.id,
      task_title: ctx.issue.title,
      repo: @repo,
      kind: :implement,
      provider: "claude",
      state: :working,
      node_id: ctx.node_a.id,
      session_id: @sid,
      config_dir: Path.join(ctx.root, "r1-config/claude-config"),
      started_at: DateTime.utc_now()
    })
  end

  # What `ClaudeSession` hands node A for its run: the home clone as the checkout, the
  # primary's paths in the container.
  defp place_on_a(ctx, %Run{} = run) do
    {:ok, checkout} = Recovery.context(run)

    spec = %{
      "version" => 1,
      "run" => run.id,
      "task" => ctx.issue.id,
      "name" => "arb-#{run.id}",
      "install" => Nodes.InstallId.get(),
      "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
      "cwd" => ctx.home,
      "mounts" => [
        %{"kind" => "worktree", "path" => ctx.home},
        %{"kind" => "home", "path" => Path.join(ctx.root, "r1-config/home")},
        %{"kind" => "config_dir", "path" => run.config_dir},
        %{"kind" => "tmp", "path" => Path.join(ctx.root, "r1-config")}
      ],
      "env" => %{},
      "secrets" => %{},
      "limits" => %{"memory" => "1g"},
      "command" => ["claude", "--print", "work the task"],
      "checkout" => %{"branch" => ctx.branch, "base" => "main"}
    }

    Executor.prepare(ctx.node_a.id, spec, owner: self(), checkout: checkout)
  end

  defp node_a_work do
    """
    wt="$1"; cf="$2"; cwd="$3"; D=$(dirname "$0")
    cd "$wt" || exit 1
    git config user.email a@node; git config user.name nodeA; git config commit.gpgsign false
    printf 'committed on node A\\n' > node-a.txt
    git add node-a.txt && git commit -q -m "work by node A"
    git rev-parse HEAD > "$D/node_a.head"
    printf 'uncommitted on node A\\n' > wip-a.txt
    slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
    mkdir -p "$cf/projects/$slug"
    printf '%s\\n' '{"type":"user","message":"start the task"}' \
      '{"type":"assistant","message":"export API_TOKEN=#{@secret}"}' > "$cf/projects/$slug/#{@sid}.jsonl"
    """
  end

  # ---- node B's resume ---------------------------------------------------------------

  defp node_b_resume do
    """
    wt="$1"; cf="$2"; cwd="$3"; D=$(dirname "$0")
    cp "$D/run.argv" "$D/r2.argv"
    printf '%s\\n' "$cwd" > "$D/r2.cwd"
    slug=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
    t="$cf/projects/$slug/#{@sid}.jsonl"
    if [ -f "$t" ]; then
      cp "$t" "$D/r2.transcript"
      printf '%s\\n' '{"type":"assistant","message":"continued on node B"}' >> "$t"
    fi
    git -C "$wt" log --format=%H > "$D/r2.log"
    git -C "$wt" status --porcelain > "$D/r2.status"
    : > "$D/r2.done"
    """
  end

  defp resume_opts(ctx) do
    row = %{
      id: ctx.node_b.id,
      name: "node-b",
      state: :online,
      health: :ready,
      max: 2,
      live: 0,
      workspace_ids: [],
      labels: [],
      caps: %{}
    }

    egress = fn _opts ->
      sockets = Path.join(ctx.root, "sockets")
      File.mkdir_p!(sockets)
      File.write!(Path.join(sockets, "proxy.sock"), "")
      File.write!(Path.join(sockets, "arb.sock"), "")

      {:ok,
       [
         proxy_socket: Path.join(sockets, "proxy.sock"),
         proxy_port: 38_021,
         bridges: [{38_022, Path.join(sockets, "arb.sock")}]
       ], "rtest"}
    end

    [
      repo: @repo,
      start_driver: false,
      preflight: false,
      nodes: [row],
      image: "localhost/arbiter-dev/beam:abc123",
      egress: egress,
      claude_path: ctx.cli,
      arb_path: ctx.cli
    ]
  end

  # ---- the agent and the primary -----------------------------------------------------

  defp enroll!(name) do
    {:ok, %{token: join}} = Nodes.mint_join_token([name: name], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)
    %{id: node.id, credential: credential}
  end

  defp connect_agent!(ctx, node, home_name) do
    home = Path.join(ctx.root, home_name)
    rt = Path.join(ctx.root, home_name <> "-rt")
    File.mkdir_p!(home)
    File.mkdir_p!(rt)

    {:ok, config} =
      Config.load(
        env: %{},
        primary_url: "http://127.0.0.1:#{NodeTestEndpoint.port()}",
        node_home: home,
        read_credential: fn _ -> {:ok, node.credential} end,
        version: @version,
        hb_interval_ms: 200,
        fence_after_ms: 60_000,
        backoff: [base: 20, max: 80],
        readiness_fun: fn -> %{ready: true, installed: true, checks: []} end,
        live_runs_fun: &Runs.inventory/0,
        run_opts: [
          podman: ctx.podman,
          runtime_dir: rt,
          require_tmpfs: false,
          image_fun: fn _image, _opts -> :ok end,
          files_fun: fn _sha, _name -> {:ok, ctx.cli} end,
          delegated_fun: fn -> ["memory", "pids", "cpu"] end,
          bridges_fun: fn _run, bridges -> {:ok, Enum.map(bridges, fn _ -> ctx.cli end)} end
        ]
      )

    node_id = node.id
    start_supervised!({Connection, config: config})
    assert_receive {:node_state, ^node_id, :online}, 10_000
  end

  # The primary restarting: every session is gone with its run table, and the new BEAM
  # draws a new boot_epoch.
  defp restart_primary! do
    for {pid, _} <- Registry.list(),
        do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)

    :persistent_term.erase({Nodes, :boot_epoch})
  end

  defp await_hold!(node_id, run_id) do
    assert_eventually(fn ->
      with pid when is_pid(pid) <- Registry.lookup(node_id),
           %{^run_id => _} <- Arbiter.Nodes.Session.claims(pid) do
        true
      else
        _ -> false
      end
    end)
  end

  defp write_agent_script!(ctx, script),
    do: File.write!(Path.join(ctx.stub, "agent_script"), script)

  defp seen(ctx, file), do: ctx.stub |> Path.join(file) |> File.read!() |> String.trim()

  defp assert_eventually(fun, tries \\ 400) do
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
end
