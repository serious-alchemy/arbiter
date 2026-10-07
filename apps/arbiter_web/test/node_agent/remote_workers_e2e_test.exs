defmodule ArbiterWeb.NodeAgent.RemoteWorkersE2ETest do
  @moduledoc """
  RW13 (bd-afcoop, `docs/design/remote-workers.md` §18 row 13): the remote-workers
  feature end to end with **nothing stood in for**.

    * the node agent is a separate OS process, `ARB_ROLE=agent` (`ArbiterWeb.RealAgent`),
      configured by the `agent.env` the **real join script** wrote;
    * it reaches the primary over a real WebSocket and real HTTP: the real
      `NodeSocket`/`NodeChannel`/`Nodes.Session` and `/nodes/*` routes, served by
      Bandit on a loopback port (`ArbiterWeb.NodeTestEndpoint`);
    * the containers are real rootless `podman` containers, hardened by the real
      `Container.wrap/2`, from a local image;
    * the checkout and the bridges are the real thing: a git bundle over HTTP into
      the §9 quarantine, and `socat` inside a network-less container reaching the
      primary's real egress proxy and `arb` bridge through the node channel.

  What it covers, in the order a node lives it: join → hello → placement → run →
  bridge traffic → bundle ingest → primary restart → recovery, plus drain and revoke.

  ## Running it

  Tagged `:node_agent` and **excluded by default** (`mix test` and CI never run it:
  it needs a rootless podman, a local image and `mix`, and it boots a second BEAM).
  Run it deliberately, memory-capped, from `apps/arbiter_web`:

      systemd-run --user --scope -p MemoryMax=3G \\
        mix test --include node_agent test/node_agent/remote_workers_e2e_test.exs

  The container image is the first local image that has `sh` and `socat`:
  `ARB_E2E_IMAGE` names one explicitly (the toolchain's `localhost/arbiter-dev/base`
  qualifies). Every container is named `arb-<run>` and removed by exact name; the
  agent is stopped by exact pid.

  async: false: the node sessions, the Bandit request processes and the agent's
  uploads all share the one sandbox connection.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :node_agent
  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: 300_000

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Overview, Placement, RateLimit, Recovery, Registry}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Egress.{Event, JailRun}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias Arbiter.Workers.Run
  alias ArbiterWeb.{NodeFixtures, NodeTestEndpoint, RealAgent}

  @operator Actor.operator("e2e")
  @branch "arbiter/e2e"
  @online_timeout 120_000

  # ---- the rig ---------------------------------------------------------------------

  setup_all do
    podman = System.find_executable("podman") || flunk("the :node_agent suite needs podman")
    {:ok, podman: podman, image: image!(podman)}
  end

  setup %{tmp_dir: tmp_dir, image: image} = ctx do
    # Short and comma/colon-free: unix socket paths cap at ~100 bytes and `Container`
    # refuses a mount path with `,` or `:`; a `:tmp_dir` is named after the test.
    root = Path.join(System.tmp_dir!(), "na-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    NodeFixtures.install_release!(Path.join(tmp_dir, "data"))
    NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)
    port = NodeTestEndpoint.port()
    url = "http://127.0.0.1:#{port}"
    {:ok, _} = Arbiter.Settings.set_nodes_public_url(url)
    on_exit(fn -> Arbiter.Settings.set_nodes_public_url(nil) end)

    api =
      start_supervised!(
        {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
        id: :arbiter_endpoint
      )

    {:ok, {_address, api_port}} = ThousandIsland.listener_info(api)

    joined = join!(root, url)
    agent = RealAgent.start(Path.join(root, "agent"), joined.agent_env)
    on_exit(fn -> RealAgent.stop(agent) end)

    online = await_online(agent, joined.node.id)
    flush_connection_events()

    repo = Path.join(root, "primary-home")
    base = home!(repo)

    ws =
      Ash.create!(Workspace, %{
        name: "na-#{System.unique_integer([:positive])}",
        prefix: "na#{System.unique_integer([:positive])}",
        config: %{}
      })

    task = Ash.create!(Issue, %{title: "mine", workspace_id: ws.id})

    Map.merge(ctx, %{
      root: root,
      url: url,
      port: port,
      api_port: api_port,
      image: image,
      node: joined.node,
      join: joined,
      agent: agent,
      hello: online,
      repo: repo,
      base: base,
      config_dir: Path.join(root, "primary-config"),
      egress_dir: Path.join(root, "eg"),
      task: task,
      workspace: ws
    })
  end

  # The first local image with `sh` and `socat`, or `ARB_E2E_IMAGE`.
  defp image!(podman) do
    candidates =
      case System.get_env("ARB_E2E_IMAGE") do
        image when image in [nil, ""] ->
          {out, 0} = System.cmd(podman, ["images", "--format", "{{.Repository}}:{{.Tag}}"])

          out
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.contains?(&1, "<none>"))
          |> Enum.sort_by(&(not String.starts_with?(&1, "localhost/arbiter-dev/base:")))

        image ->
          [image]
      end

    Enum.find(candidates, fn image ->
      match?(
        {_, 0},
        System.cmd(
          podman,
          ["run", "--rm", "--network=none", image, "sh", "-c", "command -v socat"],
          stderr_to_stdout: true
        )
      )
    end) ||
      flunk(
        "no local podman image has `sh` and `socat` (tried #{inspect(candidates)}); " <>
          "pull or build one, or set ARB_E2E_IMAGE"
      )
  end

  # ---- join: the real script ---------------------------------------------------------

  # Runs the real `/nodes/join` script with bash and the host's real curl, tar,
  # podman and cgroup files, against the real endpoint. Only what would change this
  # machine is a stub: `systemctl`, `loginctl`, `sudo`. Returns the node, the script
  # output and the environment its unit would give the agent (`agent.env`).
  defp join!(root, url) do
    bin = Path.join(root, "bin")
    home = Path.join(root, "home")
    run = Path.join(root, "run")
    log = Path.join(root, "stub.log")
    for d <- [bin, home, run], do: File.mkdir_p!(d)
    File.chmod!(run, 0o700)
    File.write!(log, "")

    stubs = %{
      "systemctl" => "exit 0\n",
      "loginctl" => ~S"""
      [ "$1" = show-user ] && echo yes
      exit 0
      """,
      "sudo" => "echo SUDO >> \"$STUB_LOG\"; exit 1\n"
    }

    for {name, body} <- stubs do
      path = Path.join(bin, name)

      File.write!(
        path,
        "#!/bin/sh\nprintf '%s %s\\n' \"$(basename \"$0\")\" \"$*\" >> \"$STUB_LOG\"\n" <> body
      )

      File.chmod!(path, 0o755)
    end

    script = Path.join(root, "join.sh")
    {_, 0} = System.cmd("curl", ["-fsS", "-o", script, url <> "/nodes/join"])

    {:ok, %{token: token}} = Nodes.mint_join_token([], @operator)
    token_file = Path.join(root, "token")
    File.write!(token_file, token <> "\n")
    File.chmod!(token_file, 0o600)

    # setsid: no controlling terminal, so the script can never block on /dev/tty.
    {out, status} =
      System.cmd("setsid", ["--wait", "bash", script],
        env: [
          {"PATH", bin <> ":" <> System.get_env("PATH", "/usr/bin:/bin")},
          {"HOME", home},
          {"XDG_RUNTIME_DIR", run},
          {"TMPDIR", run},
          {"STUB_LOG", log},
          {"ARB_JOIN_TOKEN_FILE", token_file},
          {"ARB_NODE_NAME", "e2e-node"},
          {"ARB_NODE_MAX_WORKERS", "2"},
          {"ARB_JOIN_TOKEN", nil},
          {"ARB_JOIN_CHECK_ONLY", nil},
          {"ARB_NODE_LABELS", nil}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "the join script failed (#{status}):\n#{out}"

    agent_env = parse_env(File.read!(Path.join(home, ".config/arbiter-node/agent.env")))
    credential = File.read!(agent_env["ARB_NODE_CREDENTIAL_FILE"]) |> String.trim()
    assert {:ok, node} = Nodes.authenticate(credential)

    %{
      node: node,
      out: out,
      home: home,
      stub_log: log,
      agent_env: agent_env,
      token: token,
      credential: credential
    }
  end

  # `KEY="value"` lines, as systemd's EnvironmentFile reads them.
  defp parse_env(body) do
    for line <- String.split(body, "\n", trim: true),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {key, String.trim(value, "\"")}
  end

  defp await_online(agent, node_id) do
    receive do
      {:node_state, ^node_id, :online} -> :ok
    after
      @online_timeout ->
        flunk(
          "the agent never came online.\nstatus: #{inspect(RealAgent.status(agent))}\n" <>
            RealAgent.log_tail(agent)
        )
    end

    Overview.get(node_id)
  end

  # `:node_connection` up/down from the first attach must not satisfy a later assert_receive.
  defp flush_connection_events do
    receive do
      {:node_connection, _, _} -> flush_connection_events()
    after
      0 -> :ok
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

  # ---- helpers -----------------------------------------------------------------------

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

  defp spec(ctx, run, command, overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "run" => run,
        "task" => ctx.task.id,
        "name" => "arb-#{run}",
        "install" => Nodes.InstallId.get(),
        "image" => %{"tag" => ctx.image, "plan" => nil},
        "cwd" => "/work/tree",
        "mounts" => [
          %{"kind" => "worktree", "path" => "/work/tree"},
          %{"kind" => "home", "path" => "/work/home"},
          %{"kind" => "config_dir", "path" => "/work/config"},
          %{"kind" => "tmp", "path" => "/work/tmp"}
        ],
        "env" => %{},
        "secrets" => %{},
        "limits" => %{"memory" => "512m"},
        "command" => ["sh", "-c", command]
      },
      overrides
    )
  end

  defp checkout_context(ctx) do
    %{
      home: ctx.repo,
      branch: @branch,
      base: "main",
      seeded_paths: [],
      config_dir: ctx.config_dir
    }
  end

  defp checkout_spec(extra \\ %{}),
    do: Map.merge(%{"checkout" => %{"branch" => @branch, "base" => "main"}}, extra)

  defp open!(ctx, spec, opts \\ []) do
    assert {:ok, prepared} = Executor.prepare(ctx.node.id, spec, [owner: self()] ++ opts),
           "refused; agent log:\n" <> RealAgent.log_tail(ctx.agent)

    assert {:ok, handle} = Executor.open(prepared)
    handle
  end

  # Every message of the run up to its exit: lines, the outcome, the exit status.
  defp collect(ctx, handle, acc \\ []) do
    receive do
      {^handle, {:data, {_kind, line}}} -> collect(ctx, handle, [{:line, line} | acc])
      {^handle, {:outcome, outcome}} -> collect(ctx, handle, [{:outcome, outcome} | acc])
      {^handle, {:exit_status, status}} -> Enum.reverse([{:exit, status} | acc])
    after
      60_000 ->
        flunk(
          "no exit for #{inspect(handle)}; got #{inspect(Enum.reverse(acc))}\n" <>
            RealAgent.log_tail(ctx.agent)
        )
    end
  end

  # The lines of a run, in order, up to and including `target`.
  defp gather(handle, target, acc \\ []) do
    receive do
      {^handle, {:data, {_kind, ^target}}} -> Enum.reverse([target | acc])
      {^handle, {:data, {_kind, line}}} -> gather(handle, target, [line | acc])
    after
      60_000 -> flunk("never saw #{target}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp lines(events), do: for({:line, line} <- events, do: line)

  defp container_exists?(ctx, name) do
    match?(
      {_, 0},
      System.cmd(ctx.podman, ["container", "exists", name], stderr_to_stdout: true)
    )
  end

  defp inspect_container(ctx, name, format) do
    {out, 0} = System.cmd(ctx.podman, ["inspect", "--format", format, name])
    String.trim(out)
  end

  defp assert_eventually(fun, tries \\ 400) do
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

  # ---- join and hello ------------------------------------------------------------------

  describe "join and hello" do
    test "the real join script enrols the node and installs what the agent boots from", ctx do
      out = ctx.join.out
      assert out =~ "enrolled as e2e-node"
      assert out =~ "checksum verified"

      env = ctx.join.agent_env
      assert env["ARB_ROLE"] == "agent"
      assert env["ARB_NODE_URL"] == ctx.url

      # the credential is the only secret the node keeps, in a 0600 file, never on an argv
      assert File.stat!(env["ARB_NODE_CREDENTIAL_FILE"]).mode |> Bitwise.band(0o777) == 0o600
      refute out =~ ctx.join.credential
      refute out =~ ctx.join.token

      # the script changed nothing on this machine but through its two stubs: no sudo
      log = File.read!(ctx.join.stub_log)
      assert log =~ "systemctl --user enable arbiter-node.service"
      refute log =~ "SUDO"

      # the token was single use
      assert {:error, :invalid_token} =
               Nodes.redeem_join_token(ctx.join.token, %{"name" => "another-node"})

      assert [_] = Nodes.events(kind: :enrolled)
    end

    test "the agent is a separate OS process that said hello over the real channel", ctx do
      assert RealAgent.alive?(ctx.agent)
      refute to_string(ctx.agent.os_pid) == System.pid()

      status = RealAgent.status(ctx.agent)
      assert status["node_id"] == ctx.node.id
      assert status["pid"] == to_string(ctx.agent.os_pid)

      # the primary has the node online, with the readiness the agent measured on a
      # real podman and a worker ceiling it suggested
      row = ctx.hello
      assert row.state == :online
      assert row.health == :ready
      assert is_integer(row.max) and row.max > 0
      assert [{_pid, id}] = Registry.list()
      assert id == ctx.node.id
    end
  end

  # ---- placement and a run ---------------------------------------------------------------

  defp request(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: ctx.task.id,
        workspace_id: ctx.workspace.id,
        kind: :implementer,
        provider: :claude,
        layout: :private_clone,
        mode: :remote_only
      },
      attrs
    )
  end

  describe "placement" do
    test "an eligible run is placed on the joined node and its slot is reserved", ctx do
      assert {:ok, {:node, row}} = Placement.place(request(ctx))
      assert row.id == ctx.node.id
      assert [%{task_id: task_id}] = Placement.reservations()
      assert task_id == ctx.task.id
      assert :ok = Placement.release(ctx.task.id)
    end

    test "drain stops new placement and leaves the node connected; revoke ends the connection",
         ctx do
      assert {:ok, _} = Nodes.drain(ctx.node, @operator)

      assert {:error, {:no_node_capacity, _}} =
               Placement.place(request(ctx))

      assert {:ok, _} = Nodes.undrain(ctx.node, @operator)
      assert {:ok, {:node, _}} = Placement.place(request(ctx))
      Placement.release(ctx.task.id)

      assert {:ok, _} = Nodes.revoke(ctx.node, @operator)
      assert_receive {:node_revoked, id}, 5_000
      assert id == ctx.node.id

      # the session is closed, and the real agent's retries are refused: it never comes back
      assert_eventually(fn -> Registry.lookup(ctx.node.id) == nil end)

      assert_eventually(fn ->
        match?(%{"state" => "backoff"}, RealAgent.status(ctx.agent))
      end)

      assert RealAgent.alive?(ctx.agent)
      assert Registry.lookup(ctx.node.id) == nil
      assert {:error, _} = Nodes.authenticate(ctx.join.credential)

      assert {:error, {:no_node_capacity, _}} =
               Placement.place(request(ctx))
    end
  end

  describe "a run on the node" do
    test "runs in a real hardened container: stdout, a secret it never stores, and the exit",
         ctx do
      command = ~S"""
      echo hello-from-podman
      echo "secret=$E2E_SECRET"
      echo "uid=$(id -u) cwd=$(pwd)"
      (touch /rootfs-probe 2>/dev/null && echo rootfs-writable) || echo rootfs-readonly
      (socat -T1 - TCP:127.0.0.1:9 </dev/null >/dev/null 2>&1 && echo net-up) || echo net-none
      sleep 3
      exit 3
      """

      handle =
        open!(
          ctx,
          spec(ctx, "n1", command, %{"secrets" => %{"E2E_SECRET" => "s3cr3t-e2e-marker"}})
        )

      # while it runs: the container is the one `Container.wrap/2` builds, not an ad hoc argv
      assert_receive {^handle, {:data, {:eol, "hello-from-podman"}}}, 60_000
      assert inspect_container(ctx, "arb-n1", "{{.HostConfig.ReadonlyRootfs}}") == "true"
      assert inspect_container(ctx, "arb-n1", "{{.HostConfig.NetworkMode}}") == "none"

      assert inspect_container(ctx, "arb-n1", "{{.HostConfig.SecurityOpt}}") =~
               "no-new-privileges"

      refute inspect_container(ctx, "arb-n1", "{{.Config.Env}}") =~ "s3cr3t-e2e-marker"
      assert Executor.live?(handle)

      events = collect(ctx, handle)
      out = lines(events)
      assert "secret=s3cr3t-e2e-marker" in out
      assert "rootfs-readonly" in out
      assert "net-none" in out
      assert Enum.any?(out, &(&1 =~ "cwd=/work/tree"))

      assert {:outcome, %{exit_code: 3, oom?: false, cancelled?: false}} =
               Enum.find(events, &match?({:outcome, _}, &1))

      assert {:exit, 3} = List.last(events)

      # the node cleaned up after itself: no container, and the secret reached no disk it owns
      assert_eventually(fn -> not container_exists?(ctx, "arb-n1") end)

      {found, _} =
        System.cmd("grep", ["-rl", "s3cr3t-e2e-marker", ctx.join.agent_env["ARB_NODE_HOME"]])

      assert found == ""
    end

    test "stop/1 removes the container by name and the owner hears a cancelled exit", ctx do
      handle = open!(ctx, spec(ctx, "n2", "echo up; sleep 600"))
      assert_receive {^handle, {:data, {:eol, "up"}}}, 60_000
      assert container_exists?(ctx, "arb-n2")

      assert :ok = Executor.stop(handle)
      events = collect(ctx, handle)
      assert {:outcome, %{cancelled?: true}} = Enum.find(events, &match?({:outcome, _}, &1))
      assert_eventually(fn -> not container_exists?(ctx, "arb-n2") end)
    end

    test "a spec asking for a flag no spec may pass is refused by the agent before any container",
         ctx do
      bad = spec(ctx, "n3", "true", %{"extra_args" => ["--privileged"]})

      assert {:error, {:refused, _code, _detail}} =
               Executor.prepare(ctx.node.id, bad, owner: self())

      refute container_exists?(ctx, "arb-n3")
    end
  end

  # ---- the bridges -------------------------------------------------------------------------

  # A TCP server on loopback that echoes everything back.
  defp echo_server do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    spawn_link(fn -> accept(lsock) end)
    on_exit(fn -> :gen_tcp.close(lsock) end)
    port
  end

  defp accept(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        pid = spawn(fn -> receive do: (:go -> echo(sock)) end)
        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept(lsock)

      {:error, _} ->
        :ok
    end
  end

  defp echo(sock) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} ->
        _ = :gen_tcp.send(sock, data)
        echo(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  defp events(run) do
    Event
    |> Ash.Query.filter(run_id == ^run)
    |> Ash.read!()
    |> Enum.map(&{&1.host, &1.port, &1.decision, &1.mode, &1.task_id})
    |> Enum.sort()
  end

  describe "bridged egress" do
    test "a network-less container reaches the primary's proxy and arb bridge, and policy still applies",
         ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      owner = start_supervised!({Agent, fn -> :ok end}, id: make_ref())

      # the primary's own egress run for the task: nothing about it knows the container is remote
      {:ok, _network, run} =
        JailRun.start(
          owner: owner,
          dir: ctx.egress_dir,
          arbiter_url: "http://127.0.0.1:#{ctx.api_port}/mcp",
          arb_token: Scope.mint_worker(ctx.task),
          task_id: ctx.task.id,
          enforce: true,
          infra: [allowed],
          allow_local_dial: true
        )

      on_exit(fn -> Egress.stop_run(run) end)

      proxy = Egress.socket_path(run, ctx.egress_dir)
      arb = Egress.bridge_path(run, "arb", ctx.egress_dir)

      command = """
      req() { printf "$1" | socat -t3 - UNIX-CONNECT:"$2" | tr -d '\\r' | sed "s/^/$3: /"; echo; }
      req 'GET /api/issues/#{ctx.task.id} HTTP/1.1\\r\\nhost: x\\r\\nconnection: close\\r\\n\\r\\n' #{arb} ARB
      req 'GET /api/issues HTTP/1.1\\r\\nhost: x\\r\\nconnection: close\\r\\n\\r\\n' #{arb} LIST
      req 'CONNECT #{allowed} HTTP/1.1\\r\\nHost: #{allowed}\\r\\n\\r\\nping-through-the-tunnel\\n' #{proxy} OK
      req 'CONNECT 169.254.169.254:80 HTTP/1.1\\r\\nHost: 169.254.169.254:80\\r\\n\\r\\n' #{proxy} META
      echo bridged-done
      """

      handle =
        open!(
          ctx,
          spec(ctx, run, command, %{
            "bridges" => [
              %{"name" => "proxy", "path" => proxy},
              %{"name" => "arb", "path" => arb}
            ]
          })
        )

      events = collect(ctx, handle)
      out = lines(events)
      assert "bridged-done" in out, "got #{inspect(out)}\n" <> RealAgent.log_tail(ctx.agent)
      assert {:exit, 0} = List.last(events)

      # the arb bridge: the worker token's own task is readable, and only that
      assert "ARB: HTTP/1.1 200 OK" in out
      assert Enum.any?(out, &(&1 =~ "ARB:" and &1 =~ ctx.task.id))
      assert Enum.any?(out, &String.starts_with?(&1, "LIST: HTTP/1.1 403"))

      # the egress proxy: an allowed destination relays bytes both ways; the metadata endpoint
      # is refused by the primary's policy, which never left the primary
      assert Enum.any?(
               out,
               &(&1 == "OK: HTTP/1.1 200 Connection established" or &1 =~ "OK: HTTP/1.1 200")
             )

      assert "OK: ping-through-the-tunnel" in out
      assert Enum.any?(out, &String.starts_with?(&1, "META: HTTP/1.1 403"))

      # and the primary recorded each decision on its own side
      assert [
               {"127.0.0.1", ^port, allowed_decision, _, task_id},
               {"169.254.169.254", 80, denied_decision, _, task_id}
             ] = Enum.sort_by(events(run), fn {host, _, _, _, _} -> host end)

      assert task_id == ctx.task.id
      assert to_string(allowed_decision) =~ "allow"
      assert to_string(denied_decision) =~ "den"

      # the node's listeners went with the run
      assert_eventually(fn ->
        not File.exists?(
          Path.join([ctx.join.agent_env["ARB_NODE_HOME"], "runs", run, "bridge", "proxy.sock"])
        )
      end)
    end
  end

  # ---- bundle ingest -------------------------------------------------------------------------

  describe "checkout sync" do
    test "the node seeds a shadow clone from the primary and the run's work is ingested through the quarantine",
         ctx do
      command = ~S"""
      echo seeded: $(cat /work/tree/lib/a.txt)
      echo "edited by a real container" > /work/tree/edited.txt
      echo '{}' > /work/tree/.mcp.json
      echo done
      """

      handle =
        open!(ctx, spec(ctx, "k1", command, checkout_spec()), checkout: checkout_context(ctx))

      events = collect(ctx, handle)

      # the container saw the primary's tree
      assert "seeded: a" in lines(events)
      assert {:exit, 0} = List.last(events)

      # its work came back as a bundle, through fsck, the ref allowlist and the path filter
      assert File.read!(Path.join(ctx.repo, "edited.txt")) == "edited by a real container\n"
      assert git!(ctx.repo, ["status", "--porcelain"]) =~ "edited.txt"
      assert git!(ctx.repo, ["rev-parse", @branch]) == ctx.base
      refute File.exists?(Path.join(ctx.repo, ".mcp.json"))
      assert git!(ctx.repo, ["rev-parse", "refs/arbiter/checkpoint/k1"]) != ""
    end

    test "collect/2 checkpoints a live run into the home clone before it ends", ctx do
      command = ~S"""
      echo "mid-run" > /work/tree/mid.txt
      echo up
      sleep 600
      """

      handle =
        open!(ctx, spec(ctx, "k2", command, checkout_spec()), checkout: checkout_context(ctx))

      assert_receive {^handle, {:data, {:eol, "up"}}}, 60_000

      refute File.exists?(Path.join(ctx.repo, "mid.txt"))
      assert {:ok, %{head: head}} = Executor.collect(handle, :checkout)
      assert head == ctx.base
      assert File.read!(Path.join(ctx.repo, "mid.txt")) == "mid-run\n"
      assert Executor.live?(handle)
      assert :ok = Executor.stop(handle)
      collect(ctx, handle)
    end
  end

  # ---- primary restart and recovery ----------------------------------------------------------

  defp run_row!(node, label) do
    Ash.create!(Run, %{
      task_id: "bd-#{label}",
      base_task_id: "bd-#{label}",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: :working,
      node_id: node.id,
      config_dir: nil,
      started_at: DateTime.utc_now()
    })
  end

  # The primary restarting, as far as a node can tell: the listener goes away (every
  # node socket drops), the sessions and their run tables are gone, the new BEAM draws
  # a new boot_epoch, and the same port comes back.
  defp restart_primary!(ctx) do
    old = Nodes.boot_epoch()
    stop_supervised!(NodeTestEndpoint)

    for {pid, _} <- Registry.list(),
        do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)

    :persistent_term.erase({Nodes, :boot_epoch})
    refute Nodes.boot_epoch() == old

    NodeTestEndpoint.configure(port: ctx.port)
    start_supervised!(NodeTestEndpoint)
    :ok
  end

  describe "a primary restart" do
    test "the real agent quiesces a run the new primary does not know, and Recovery lands its work",
         ctx do
      row = run_row!(ctx.node, "rr1")
      id = row.id

      command = ~S"""
      echo "survived nothing" > /work/tree/edited.txt
      echo up
      sleep 600
      """

      handle =
        open!(ctx, spec(ctx, id, command, checkout_spec()), checkout: checkout_context(ctx))

      assert_receive {^handle, {:data, {:eol, "up"}}}, 60_000
      assert container_exists?(ctx, "arb-#{id}")
      refute File.exists?(Path.join(ctx.repo, "edited.txt"))

      restart_primary!(ctx)

      # The agent reconnects with its backoff, is told the run is unknown and quiesces it;
      # Recovery is already waiting for it, as in the boot sweep.
      run_ctx = checkout_context(ctx)

      assert {:ok, report} =
               Recovery.await(
                 primary?: true,
                 node_timeout_ms: 90_000,
                 total_timeout_ms: 120_000,
                 context_fun: fn %Run{id: ^id} -> {:ok, run_ctx} end
               ),
             "recovery failed; agent log:\n" <> RealAgent.log_tail(ctx.agent)

      assert report == %{id => :collected}

      # the real container was stopped, not left running against a primary that forgot it
      refute container_exists?(ctx, "arb-#{id}")

      # the work the run did on the node is in the home clone, uncommitted as it was
      assert File.read!(Path.join(ctx.repo, "edited.txt")) == "survived nothing\n"
      assert git!(ctx.repo, ["status", "--porcelain"]) =~ "edited.txt"
      assert git!(ctx.repo, ["rev-parse", "refs/arbiter/checkpoint/#{id}"]) != ""

      # the row is left for the Reconciler to resume, as for a local interrupted run
      assert Ash.get!(Run, id).state == :working

      # and the agent is still the same process, online again, holding nothing for it
      assert RealAgent.alive?(ctx.agent)
      assert [{_pid, node_id}] = Registry.list()
      assert node_id == ctx.node.id
      assert Executor.live?(handle) == false
    end

    test "a run the primary still holds survives a socket blip: the container is untouched and no output is lost",
         ctx do
      row = run_row!(ctx.node, "rr2")
      command = "i=0; while true; do echo tick-$i; i=$((i+1)); sleep 1; done"
      handle = open!(ctx, spec(ctx, row.id, command))
      # reads in order, so a gap or a duplicate shows
      before = gather(handle, "tick-1")
      assert before == ["tick-0", "tick-1"]

      # a blip, not a restart: the transport closes, the session survives
      assert :ok = ArbiterWeb.NodeSocket.disconnect(ctx.node.id)
      assert_receive {:node_connection, _, :down}, 10_000
      assert_receive {:node_connection, _, :up}, 90_000
      assert [{_session, _}] = Registry.list()
      assert Executor.live?(handle)
      assert container_exists?(ctx, "arb-#{row.id}")

      # output goes on from where it was, and what the agent held back across the blip
      # arrives once: the ticks are a gapless, duplicate-free sequence
      after_blip = gather(handle, "tick-6")
      assert after_blip == for(i <- 2..6, do: "tick-#{i}")
      assert :ok = Executor.stop(handle)

      assert {:outcome, %{cancelled?: true}} =
               ctx |> collect(handle) |> Enum.find(&match?({:outcome, _}, &1))
    end
  end
end
