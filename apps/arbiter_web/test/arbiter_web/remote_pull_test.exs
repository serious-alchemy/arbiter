defmodule ArbiterWeb.RemotePullTest do
  @moduledoc """
  SI4 (bd-8f3mcy, `docs/design/remote-workers.md` §21.2.1, §21.4), end to end across
  the real halves: a machine node runs a repo's **published image, pulled from a
  registry**, with no CLI file mounted.

    * **The primary** is real: the settings (`nodes.machine_image_source: auto`, the
      install-wide `nodes.registry` with its push login and its read-only pull login,
      Cloak-encrypted), `ContainerSpawn.prepare_remote/1` (the plan path, the per-run
      source choice, the reach rule, no shelved CLI), `remote_spec/3`,
      `Executor.Node`, `Nodes.Session` and the node channel. Only the publisher is
      stubbed, to the digest the registry holds.
    * **The node** is the real agent (`Connection`, `Runs`, `Run`, `ImagePull`,
      `Secrets`) in this VM, joined over a real WebSocket; the caps the primary chose
      by come from its real `hello`.
    * **The registry** is `ArbiterWeb.StandInRegistry` on a loopback port, behind
      Basic auth, recording every login presented to it.
    * **podman** is the stand-in (`stub_podman.sh`): its `pull` really fetches the
      manifest and config from the registry over HTTP with the login in the auth
      file it was handed; its `run` records the argv and prints three lines.

  The runtime directory is marked tmpfs by a stand-in mountinfo, so the agent's
  fail-closed tmpfs check really runs. What is not here: a container from real layers
  (that needs rootless podman: the `:node_agent` suite).
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.NodeAgent.{Config, Connection, PullAuth, Runs, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Overview, RateLimit, Session}
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias Arbiter.Worker.PrivateClone
  alias ArbiterWeb.{NodeTestEndpoint, StandInRegistry, StubPodman}

  @version "1.2.3"
  @push_password "PUSH-token-NEVER-ON-A-NODE-9f2c"
  @pull_password "PULL-token-read-only-4b7e"
  @cli_set "0a1b2c3d"
  @labels %{
    "arbiter.runtime-contract" => "1",
    "arbiter.cli-set" => @cli_set,
    "arbiter.cli-providers" => "claude",
    "arbiter.cli.claude.version" => "2.1.310",
    "arbiter.cli.claude.sha256" => String.duplicate("c", 64)
  }
  @digest String.duplicate("d", 64)

  setup %{tmp_dir: tmp_dir} do
    root =
      Path.join(Arbiter.Config.Paths.socket_root(), "rpl-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    put_env_restoring(:arbiter, :worker_container_available, true)
    put_env_restoring(:arbiter, :worker_container_network_available, true)
    put_env_restoring(:arbiter, :worker_container_image, nil)
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Nodes.Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)

    # The registry, holding the repo's published image under <nodes.registry>/vstim/worker.
    registry_agent =
      start_supervised!({Agent, fn -> StandInRegistry.state("reader", @pull_password) end})

    server =
      start_supervised!(
        {Bandit,
         plug: {StandInRegistry, agent: registry_agent},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0},
        id: :stand_in_registry
      )

    {:ok, {_ip, registry_port}} = ThousandIsland.listener_info(server)
    host = "127.0.0.1:#{registry_port}"
    digest = StandInRegistry.put_image(registry_agent, "e2e/vstim/worker", @labels)
    ref = "#{host}/e2e/vstim/worker@#{digest}"

    # The install's registry: a push login (the publisher's, never a node's) and a
    # read-only pull login. Plain HTTP (insecure), as the stand-in is.
    {:ok, _} = Settings.set_nodes_registry("#{host}/e2e")
    {:ok, _} = Settings.set_nodes_registry_insecure(true)
    {:ok, _} = Settings.set_nodes_registry_username("pusher")
    {:ok, _} = Settings.set_nodes_registry_password(@push_password)
    {:ok, _} = Settings.set_nodes_registry_pull_username("reader")
    {:ok, _} = Settings.set_nodes_registry_pull_password(@pull_password)

    # The node: the real agent, joined, against the stand-in podman.
    {:ok, %{token: join}} = Nodes.mint_join_token([name: "pull-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    File.write!(Path.join(stub, "image_absent"), "")
    File.write!(Path.join(stub, "registry_pull"), "")

    home = Path.join(root, "node-home")
    rt = Path.join(root, "rt")
    File.mkdir_p!(home)
    File.mkdir_p!(rt)
    mountinfo = Path.join(root, "mountinfo")

    File.write!(
      mountinfo,
      "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:30 / #{rt} rw,nosuid - tmpfs tmpfs rw\n"
    )

    socket = Path.join(root, "bridge.sock")
    File.write!(socket, "")
    test = self()

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
          require_tmpfs: true,
          mountinfo: mountinfo,
          deps_cache: false,
          files_fun: fn _sha, name ->
            send(test, {:cli_file_fetched, name})
            {:error, :no_cli_file_for_a_pull}
          end,
          delegated_fun: fn -> ["memory", "pids", "cpu"] end,
          bridges_fun: fn _run, bridges -> {:ok, Enum.map(bridges, fn _ -> socket end)} end
        ]
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)
    start_supervised!({Connection, config: config})
    assert_receive {:node_state, _id, :online}, 10_000

    # The repo and the private clone a remote run is placed from.
    git = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = PrivateClone.create(git.checkout, "feature/si4-pull", "main")
    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rpl-ws-#{n}",
        prefix: "rpl#{n}",
        config: %{
          "worker" => %{"placement" => "prefer_remote"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
        }
      })

    run_tmp = Path.join(root, "run-tmp")
    File.mkdir_p!(run_tmp)

    %{
      node: node,
      ref: ref,
      digest: digest,
      registry: registry_agent,
      stub: stub,
      home: home,
      rt: rt,
      root: root,
      clone: clone,
      ws: ws,
      run_tmp: run_tmp,
      socket: socket
    }
  end

  defp put_env_restoring(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  # The placement row the dispatch would hand `prepare_remote/1`: its caps are what the
  # agent's own hello advertised.
  defp row!(ctx) do
    row = Enum.find(Overview.node_rows(), &(&1.id == ctx.node.id))
    assert row, "the node has no placement row"
    row
  end

  defp prepare_opts(ctx, extra \\ []) do
    test = self()
    policy = SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})

    egress = fn _opts ->
      {:ok, [proxy_socket: ctx.socket, proxy_port: 3128, bridges: [{4848, ctx.socket}]], "e2e"}
    end

    Keyword.merge(
      [
        policy: policy,
        provider: "claude",
        node: row!(ctx),
        workspace: ctx.ws,
        repo: "vstim",
        worktree_path: ctx.clone,
        owner: self(),
        task_id: "bd-si4e2e",
        arb_token: "arb-secret-token",
        tmp_dir: ctx.run_tmp,
        egress: egress,
        plan: [resolver: fn _ref -> {:ok, "sha256:" <> @digest} end, arb_otp: "27.0"],
        publish: [
          stub: fn pctx ->
            send(test, {:published, pctx.repo})
            {:ok, %{ref: ctx.ref, cli_set: @cli_set}}
          end
        ]
      ],
      extra
    )
  end

  defp port_args(request) do
    argv = [
      "sh",
      "-c",
      ~s(exec "$@" < /dev/null),
      "sh",
      ContainerSpawn.claude_path(),
      "--print",
      "go"
    ]

    %{argv: argv, env: ContainerSpawn.apply_env([], request)}
  end

  defp collect(handle, acc \\ []) do
    receive do
      {^handle, {:data, {_kind, line}}} -> collect(handle, [{:line, line} | acc])
      {^handle, {:outcome, outcome}} -> collect(handle, [{:outcome, outcome} | acc])
      {^handle, {:exit_status, status}} -> Enum.reverse([{:exit, status} | acc])
    after
      30_000 -> flunk("no exit for #{inspect(handle)}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  # The container side of every `-v host:container[:opts]` the run was started with.
  defp mount_destinations(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["-v", spec] -> [spec |> String.split(":") |> Enum.at(1)]
      _ -> []
    end)
  end

  defp lines(stub, file),
    do: stub |> Path.join(file) |> File.read!() |> String.split("\n", trim: true)

  # Every regular file under `dir`, dotfiles included, as one string.
  defp everything_under(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp markers do
    [
      @pull_password,
      Base.encode64("reader:" <> @pull_password),
      @push_password,
      Base.encode64("pusher:" <> @push_password)
    ]
  end

  test "the node pulls the published image with a tmpfs credential and runs it with no CLI mount; " <>
         "neither credential reaches a log or the node's disk, and the push one never leaves the primary",
       ctx do
    {:ok, _} = Settings.set_nodes_machine_image_source("auto")
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    run_id = "si4-e2e-#{System.unique_integer([:positive])}"

    {events, log} =
      ExUnit.CaptureLog.with_log([level: :debug], fn ->
        assert {:ok, request} = ContainerSpawn.prepare_remote(prepare_opts(ctx))
        assert_received {:published, "vstim"}

        # the primary chose the pull: the published digest, no plan, no CLI file
        assert request.image.ref == ctx.ref
        assert request.image.plan == nil
        assert request.cli == []

        assert {:ok, spec} = ContainerSpawn.remote_spec(request, port_args(request), run_id)
        # The checkout round trip (seed bundle in, snapshot out) has suites of its own;
        # this run's worktree is a plain directory on the node.
        spec = Map.delete(spec, "checkout")

        assert %PullAuth{registry: registry, username: "reader"} = spec["pull_auth"]
        assert ctx.ref =~ registry

        body = Jason.encode!(spec)
        refute body =~ @push_password
        refute body =~ Base.encode64("pusher:" <> @push_password)

        assert {:ok, prepared} = Executor.prepare(row!(ctx), spec, owner: self())
        assert {:ok, handle} = Executor.open(prepared)
        collect(handle)
      end)

    # The run ran, from the pulled digest, with no CLI mounted or fetched.
    assert {:exit, 0} = List.last(events)
    assert for({:line, line} <- events, do: line) == ["line-1", "line-2", "line-3"]

    run_argv = lines(ctx.stub, "run.argv")
    assert ctx.ref in run_argv
    assert "--pull=never" in run_argv
    # the CLI the command names is the image's own: nothing is mounted under /opt/arbiter/cli
    refute Enum.any?(mount_destinations(run_argv), &String.starts_with?(&1, "/opt/arbiter/cli"))
    assert ContainerSpawn.claude_path() in run_argv
    refute_received {:cli_file_fetched, _}

    # The pull: the auth file was the run's own on the tmpfs, 0600, and is gone.
    authfile = Path.join([ctx.rt, "arbiter-node", run_id, "pull-auth.json"])
    assert lines(ctx.stub, "pull.authfile") == [authfile]
    assert lines(ctx.stub, "pull.authfile.mode") == ["600"]

    assert lines(ctx.stub, "pull.argv") == [
             "--quiet",
             "--authfile",
             authfile,
             "--tls-verify=false",
             ctx.ref
           ]

    # gone once the pull ended, before the container started
    assert lines(ctx.stub, "authfile.at_run") == ["absent"]
    refute File.exists?(authfile)
    refute File.exists?(Path.dirname(authfile))

    # The registry was read with the pull login, and never shown the push one.
    presented = StandInRegistry.presented(ctx.registry)
    assert {"reader", @pull_password} in presented
    refute Enum.any?(presented, &match?({_, @push_password}, &1))
    assert Enum.any?(StandInRegistry.served(ctx.registry), &(&1 =~ "/manifests/" <> ctx.digest))

    # No credential in any log line (every level), on the node's disk, or in anything
    # the stand-in podman recorded.
    for marker <- markers() do
      refute log =~ marker, "a credential reached the log"
      refute everything_under(ctx.home) =~ marker, "a credential reached the node's disk"
      refute Arbiter.NodeAgent.StubPodman.recorded(ctx.stub) =~ marker
    end
  end

  test "the default (build): the same node is sent the plan and its CLI files, and no credential",
       ctx do
    assert Settings.machine_image_source() == "build"

    opts = prepare_opts(ctx, publish: [stub: fn _ -> flunk("published under build") end])
    assert {:ok, request} = ContainerSpawn.prepare_remote(opts)

    assert request.image.plan != nil
    refute Map.has_key?(request.image, :ref)
    assert [_ | _] = request.cli

    assert {:ok, spec} = ContainerSpawn.remote_spec(request, port_args(request), "si4-build")
    refute Map.has_key?(spec, "pull_auth")
    body = Jason.encode!(spec)
    for marker <- markers(), do: refute(body =~ marker)
  end

  test "a node pinned to a workspace is never handed the install-wide pull credential", ctx do
    {:ok, _} = Settings.set_nodes_machine_image_source("auto")

    {:ok, _} =
      Nodes.update_node(ctx.node, %{workspace_ids: [ctx.ws.id]}, Arbiter.Actor.operator("test"))

    opts = prepare_opts(ctx, publish: [stub: fn _ -> flunk("published for a pinned node") end])
    assert {:ok, request} = ContainerSpawn.prepare_remote(opts)
    assert request.image.plan != nil
    refute Map.has_key?(request.image, :pull)
  end

  test "an assign that dies with the spec in its exit reason prints no credential", ctx do
    {:ok, _} = Settings.set_nodes_machine_image_source("auto")
    assert {:ok, request} = ContainerSpawn.prepare_remote(prepare_opts(ctx))
    assert {:ok, spec} = ContainerSpawn.remote_spec(request, port_args(request), "si4-dead")

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    reason = catch_exit(Session.assign(dead, "si4-dead", spec, self()))

    text =
      Exception.format_exit(reason) <>
        inspect(reason, limit: :infinity, printable_limit: :infinity)

    assert text =~ "pull_auth"
    for marker <- markers(), do: refute(text =~ marker)
  end
end
