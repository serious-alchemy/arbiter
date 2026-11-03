defmodule ArbiterWeb.RemoteResearchReadTest do
  @moduledoc """
  bd-1fkwj9, end to end across the real halves (as `ArbiterWeb.RemoteGitCredentialTest`):
  a `research` ticket granted `research_read`, dispatched by the real
  `Worker.Dispatch.dispatch/2` under `worker.placement: prefer_remote`, is **placed on
  the node and runs there** (it used to be refused with
  `{:research_transcripts_unsupported, :remote_node}` and fall back to the primary).

  The node gets the grant the way every run does: the `research_read` claim in the
  run's worker token. The transcripts are not shipped: the run reads them through
  `GET /api/workers/:task/log`, a read-only route under the same claim, so nothing
  sensitive is ever stored on the node. Asserted, with the token as the node received it:

    * the run lists runs, reads usage events and reads a transcript of its workspace;
    * a write (`POST /api/workers/:task/stop`) is a 403;
    * a ticket without the permission, and a reviewer, are given no claim and read nothing;
    * the spec the node received and everything the node wrote hold no transcript, no
      `research-transcripts` mount and no `ARBITER_TRANSCRIPTS_DIR`.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.MCP.Scope
  alias Arbiter.NodeAgent.{Config, Connection, Run, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.{Dispatch, OutputLog, ResearchGrant}
  alias Arbiter.Workers.Run, as: WorkerRun
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"
  @repo "acme/research-repo"
  @marker "SENSITIVE-TRANSCRIPT-MARKER-4471"

  setup %{tmp_dir: tmp_dir} do
    # Short, comma-free: `Container` refuses a mount path with `,` or `:`.
    root = Path.join(System.tmp_dir!(), "rrr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    put_env_restoring(:arbiter, :worker_container_available, true)
    put_env_restoring(:arbiter, :worker_container_network_available, true)
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "research-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
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

    assert_receive {:node_state, id, :online}, 10_000
    assert id == node.id

    repo = Path.join(root, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "lib/a.txt"), "a\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    forge = Path.join(root, "forge.git")
    git!(root, ["init", "-q", "--bare", "-b", "main", forge])
    git!(repo, ["remote", "add", "origin", forge])
    git!(repo, ["push", "-q", "origin", "main"])

    put_env_restoring(:arbiter, :repo_paths, %{@repo => repo})
    put_env_restoring(:arbiter, :worktree_root, Path.join(root, "wt"))
    put_env_restoring(:arbiter, :output_log_root, Path.join(root, "logs"))
    put_env_restoring(:arbiter, :worker_deps_cache, false)

    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rrr-#{n}",
        prefix: "rr#{n}",
        config: %{
          "worker" => %{"placement" => "prefer_remote"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}},
          "guardrails" => %{"bindings" => %{"research_read" => %{}}}
        }
      })

    {:ok, other_ws} = Ash.create(Workspace, %{name: "rrr-other-#{n}", prefix: "ro#{n}"})

    %{
      node: node,
      stub: stub,
      home: home,
      rt: rt,
      root: root,
      ws: ws,
      other_ws: other_ws
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

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp research_ticket!(ws, permissions) do
    Ash.create!(
      Issue,
      %{
        title: "study arbiter",
        workspace_id: ws.id,
        issue_type: :research,
        acceptance: "- findings in notes",
        permissions: permissions
      },
      context: %{guardrail_authority: :coordinator, permission_actor: "t"}
    )
  end

  # A finished run of another ticket in the workspace, with a transcript on disk.
  defp past_run!(ws) do
    other =
      Ash.create!(Issue, %{title: "an earlier ticket", workspace_id: ws.id, issue_type: :task})

    run =
      Ash.create!(WorkerRun, %{
        task_id: other.id,
        workspace_id: ws.id,
        repo: @repo,
        started_at: DateTime.utc_now()
      })

    File.mkdir_p!(OutputLog.root())
    File.write!(OutputLog.path_for(run.id), "line one\n#{@marker}\nline three\n")
    {other, run}
  end

  # `Worker.Dispatch.dispatch/2` of `task`, with the node as the one placement may choose.
  defp dispatch_to_node(ctx, task) do
    row = %{
      id: ctx.node.id,
      name: "research-node",
      state: :online,
      health: :ready,
      max: 2,
      live: 0,
      workspace_ids: [],
      labels: [],
      caps: %{}
    }

    sockets = Path.join(ctx.root, "dispatch-sockets")
    File.mkdir_p!(sockets)
    proxy = Path.join(sockets, "proxy.sock")
    bridge = Path.join(sockets, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: 38_261, bridges: [{38_262, bridge}]], "rtest"}
    end

    Dispatch.dispatch(task.id,
      repo: @repo,
      force: true,
      start_driver: false,
      start_claude: true,
      preflight: false,
      nodes: [row],
      image: "localhost/arbiter-dev/beam:abc123",
      egress: egress
    )
  end

  defp placed_node(pid) do
    case Enum.find(Arbiter.Worker.Registry.live_dispatches(), &(&1.pid == pid)) do
      %{node_id: node_id} -> node_id
      nil -> flunk("no live dispatch for #{inspect(pid)}")
    end
  end

  # The live run's validated spec, exactly as the node received it.
  defp node_spec do
    assert_eventually(fn -> Runs.run_ids() != [] end)
    [run] = Runs.run_ids()
    :sys.get_state(GenServer.whereis(Run.via(run))).spec
  end

  # The token the node's container was handed: the identity of its API calls.
  defp node_token(spec) do
    Map.get(spec.secrets, "ARB_TOKEN") || Map.fetch!(spec.env, "ARB_TOKEN")
  end

  # Everything the node wrote, recorded or kept (the stand-in podman's records and the
  # node's home and runtime dir), as one string.
  defp node_side(ctx) do
    [ctx.stub, ctx.home, ctx.rt]
    |> Enum.flat_map(&files_under/1)
    |> Enum.reject(&(Path.basename(&1) == "podman"))
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp files_under(dir),
    do: dir |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)

  defp stop_worker(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  defp api(token, verb, path) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> Phoenix.ConnTest.dispatch(
      ArbiterWeb.Endpoint,
      verb,
      path,
      if(verb == :get, do: nil, else: "{}")
    )
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          50 -> assert_eventually(fun, tries - 1)
        end
    end
  end

  test "a research_read ticket under prefer_remote is placed on the node and reads Arbiter's data there",
       ctx do
    task = research_ticket!(ctx.ws, ["research_read"])
    {earlier, earlier_run} = past_run!(ctx.ws)
    StubPodman.write_mode(ctx.stub, "hang")

    assert {:ok, %{worker_pid: pid}} = dispatch_to_node(ctx, task)

    # Placed on the node, not refused and not run on the primary.
    assert placed_node(pid) == ctx.node.id

    spec = node_spec()
    token = node_token(spec)

    # The grant rode the token the node holds.
    assert {:ok, %Scope{tier: :worker} = scope} = Scope.from_token(token)
    assert Scope.permission?(scope, "research_read")

    # It lists runs...
    history = api(token, :get, "/api/workers/history")
    assert history.status == 200
    assert earlier_run.id in Enum.map(body(history)["data"], & &1["id"])

    # ...reads usage events...
    assert api(token, :get, "/api/usage/events").status == 200
    assert api(token, :get, "/api/usage?by=task").status == 200

    # ...and reads a transcript of its workspace through the API, not from a mount.
    log = api(token, :get, "/api/workers/#{earlier.id}/log?run_id=#{earlier_run.id}")
    assert log.status == 200
    assert %{"exists" => true, "lines" => lines} = body(log)["data"]
    assert @marker in lines

    # A write is refused under the same claim.
    assert api(token, :post, "/api/workers/#{earlier.id}/stop").status == 403
    assert api(token, :post, "/api/workers/dispatch").status == 403

    stop_worker(pid)
  end

  test "no transcript is sent to the node or left on it", ctx do
    task = research_ticket!(ctx.ws, ["research_read"])
    past_run!(ctx.ws)
    StubPodman.write_mode(ctx.stub, "hang")

    assert {:ok, %{worker_pid: pid}} = dispatch_to_node(ctx, task)
    assert placed_node(pid) == ctx.node.id

    spec = node_spec()
    sent = inspect(spec, limit: :infinity, printable_limit: :infinity)

    refute sent =~ @marker
    refute sent =~ "research-transcripts"
    refute sent =~ "ARBITER_TRANSCRIPTS_DIR"
    assert Enum.all?(spec.mounts, &(&1.kind in ~w(worktree home config_dir tmp cli prompt)))

    # The primary staged nothing for it either: no snapshot dir in the run's tmp dir.
    tmp = Enum.find_value(spec.mounts, &(&1.kind == "tmp" && &1.path))
    refute File.exists?(Path.join(tmp, "research-transcripts"))

    # Nothing the node recorded or wrote holds the transcript, while the run is live...
    refute node_side(ctx) =~ @marker
    stop_worker(pid)
    # ...nor once it is over.
    refute node_side(ctx) =~ @marker
  end

  test "a research ticket without the permission is placed on the node but is given no access",
       ctx do
    task = research_ticket!(ctx.ws, [])
    StubPodman.write_mode(ctx.stub, "hang")

    assert {:ok, %{worker_pid: pid}} = dispatch_to_node(ctx, task)
    assert placed_node(pid) == ctx.node.id

    token = node_token(node_spec())
    assert {:ok, scope} = Scope.from_token(token)
    refute Scope.permission?(scope, "research_read")

    for path <- ["/api/workers/history", "/api/usage/events", "/api/workers/#{task.id}/log"] do
      assert api(token, :get, path).status == 403, path
    end

    stop_worker(pid)
  end

  test "a reviewer is never given the claim, so its token reads nothing", ctx do
    task = research_ticket!(ctx.ws, ["research_read"])

    assert %{granted?: true} = ResearchGrant.resolve(task, ctx.ws, :implementer)
    assert %{granted?: false, claims: []} = ResearchGrant.resolve(task, ctx.ws, :reviewer)

    token = Scope.mint_worker(task, nil, permissions: [])
    assert api(token, :get, "/api/workers/history").status == 403
  end

  test "a granted run cannot read another workspace's data", ctx do
    task = research_ticket!(ctx.ws, ["research_read"])
    {foreign, foreign_run} = past_run!(ctx.other_ws)
    StubPodman.write_mode(ctx.stub, "hang")

    assert {:ok, %{worker_pid: pid}} = dispatch_to_node(ctx, task)
    token = node_token(node_spec())

    refute foreign_run.id in Enum.map(
             body(api(token, :get, "/api/workers/history"))["data"],
             & &1["id"]
           )

    log = api(token, :get, "/api/workers/#{foreign.id}/log?run_id=#{foreign_run.id}")
    assert log.status in [403, 404]
    refute log.resp_body =~ @marker

    stop_worker(pid)
  end
end
