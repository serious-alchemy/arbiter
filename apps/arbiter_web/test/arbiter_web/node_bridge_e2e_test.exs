defmodule ArbiterWeb.NodeBridgeE2ETest do
  @moduledoc """
  RW10 (bd-54ibeo, `docs/design/remote-workers.md` §8), end to end: the real
  agent (`Connection`, `Run`, `NodeAgent.Bridge`) on a stand-in `podman`, the real
  `NodeSocket`/`NodeChannel` over a Bandit listener, and on the primary a real
  `Arbiter.Worker.Egress` run (proxy + `arb` bridge) in front of the real
  `ArbiterWeb.Endpoint`.

  The point of the bridge is that **nothing on the primary changes**: so each
  scenario is run twice, once from a *local* run's own sockets and once from a
  *remote* run's sockets on the node (what the container's `socat` would hit),
  and the answers, the `BridgeIdentity` resolution behind them and the
  `egress_events` rows must be the same.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  require Ash.Query

  alias Arbiter.MCP.Scope
  alias Arbiter.NodeAgent.{Bridge, Config, Connection, PodChannel, RunSpec, Runs, Status}
  alias Arbiter.NodeAgent.PodChannel.{CA, CAStore}
  alias Arbiter.NodeAgent.PodChannelKit, as: Kit
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Egress.{Event, JailRun}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"

  setup %{tmp_dir: tmp_dir} do
    # Short, comma-free: unix socket paths are limited to ~100 bytes.
    root = Path.join(System.tmp_dir!(), "be-#{System.unique_integer([:positive])}")
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

    endpoint =
      start_supervised!(
        {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
        id: :arbiter_endpoint
      )

    {:ok, {_address, api_port}} = ThousandIsland.listener_info(endpoint)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "bridge-e2e"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    StubPodman.write_mode(stub, "hang")
    home = Path.join(root, "nh")
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
          # what `Arbiter.NodeAgent.Supervisor` wires
          bridges_fun: &Bridge.listen/2,
          bridges_release_fun: &Bridge.release/1
        ]
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)
    start_supervised!({Bridge, node_home: home})

    # K6: the k8s controller's pod channel in front of the same agent bridge
    start_supervised!(
      {PodChannel,
       name: nil,
       ca_store: {CAStore.Dir, Path.join(root, "ca")},
       config: config,
       ip: {127, 0, 0, 1},
       bridge_port: 0,
       boot_port: 0,
       server_names: ["arbiter-controller", "localhost"],
       server_ips: [{127, 0, 0, 1}]}
    )

    {:ok, pod_ca} = CA.load_or_create(PodChannel.ca_store())
    start_supervised!({Connection, config: config})

    assert_receive {:node_state, id, :online}, 10_000
    assert id == node.id

    ws =
      Ash.create!(Workspace, %{
        name: "be-#{System.unique_integer([:positive])}",
        prefix: "be#{System.unique_integer([:positive])}",
        config: %{}
      })

    task = Ash.create!(Issue, %{title: "mine", workspace_id: ws.id})
    sibling = Ash.create!(Issue, %{title: "sibling", workspace_id: ws.id})

    %{
      pod_ca: pod_ca,
      node: node,
      root: root,
      home: home,
      stub: stub,
      api_port: api_port,
      task: task,
      sibling: sibling,
      egress_dir: Path.join(root, "eg")
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

  # An egress run for `task` on the primary: the real proxy (enforcing, with
  # `allowed` as its whole baseline) and the real `arb` bridge to the endpoint.
  defp egress_run!(ctx, task, allowed) do
    owner = start_supervised!({Agent, fn -> :ok end}, id: make_ref())

    {:ok, _network, run} =
      JailRun.start(
        owner: owner,
        dir: ctx.egress_dir,
        arbiter_url: "http://127.0.0.1:#{ctx.api_port}/mcp",
        arb_token: Scope.mint_worker(task),
        task_id: task.id,
        enforce: true,
        infra: allowed,
        allow_local_dial: true
      )

    on_exit(fn -> Egress.stop_run(run) end)
    run
  end

  defp spec_for(ctx, run) do
    %{
      "version" => 1,
      "run" => run,
      "task" => ctx.task.id,
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
      "bridges" => [
        %{"name" => "proxy", "path" => Egress.socket_path(run, ctx.egress_dir)},
        %{"name" => "arb", "path" => Egress.bridge_path(run, "arb", ctx.egress_dir)}
      ],
      "command" => ["claude", "--print"]
    }
  end

  # The same run as seen from where its container would be: on the node, behind
  # the agent's listeners. Returns `{local, remote}` socket paths by bridge name.
  defp place!(ctx, run) do
    {:ok, prepared} = Executor.prepare(ctx.node.id, spec_for(ctx, run), owner: self())
    {:ok, handle} = Executor.open(prepared)

    dir = Path.join([ctx.home, "runs", run, "bridge"])

    %{
      handle: handle,
      local: %{
        "proxy" => Egress.socket_path(run, ctx.egress_dir),
        "arb" => Egress.bridge_path(run, "arb", ctx.egress_dir)
      },
      remote: %{"proxy" => Path.join(dir, "proxy.sock"), "arb" => Path.join(dir, "arb.sock")}
    }
  end

  # The same run as seen from a k8s pod (K6): placed on the node as above (the
  # primary neither knows nor cares what the node's channel is), assigned to the
  # controller's pod channel, and reached the way the pod's `socat` reaches it:
  # TLS to `:9443` with the run's leaf for that bridge, out of the `/boot` tar.
  # Returns the endpoints by bridge name, as `place!/2`'s `remote`.
  defp place_pod!(ctx, run) do
    placed = place!(ctx, run)
    {:ok, spec} = RunSpec.validate(spec_for(ctx, run))
    %{files: files} = Kit.boot!(PodChannel.Runs, spec, {127, 0, 0, 1})

    tls = fn name ->
      {:tls, PodChannel.ports().bridge, Kit.client_opts(files, name, ctx.pod_ca)}
    end

    Map.put(placed, :pod, %{"proxy" => tls.("proxy"), "arb" => tls.("arb")})
  end

  # ---- endpoints: a unix socket path, or `{:tls, port, ssl_opts}` ---------------

  defp connect(path) when is_binary(path) do
    {:ok, sock} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false])

    {:gen_tcp, sock}
  end

  defp connect({:tls, port, opts}) do
    {:ok, sock} = :ssl.connect({127, 0, 0, 1}, port, [:binary, active: false] ++ opts, 10_000)
    {:ssl, sock}
  end

  # ---- a tiny HTTP client ----------------------------------------------------

  defp http(path, method, url, opts \\ []) do
    body = if json = opts[:json], do: Jason.encode!(json), else: ""

    headers =
      [{"host", "127.0.0.1"}, {"connection", "close"}] ++
        if(json, do: [{"content-type", "application/json"}], else: []) ++
        Keyword.get(opts, :headers, [])

    head =
      Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "content-length: #{byte_size(body)}\r\n"

    {mod, sock} = connect(path)
    :ok = mod.send(sock, "#{method} #{url} HTTP/1.1\r\n#{head}\r\n#{body}")
    raw = recv_all({mod, sock}, "")
    mod.close(sock)
    parse(raw)
  end

  defp recv_all({mod, sock}, acc) do
    case mod.recv(sock, 0, 10_000) do
      {:ok, data} -> recv_all({mod, sock}, acc <> data)
      {:error, _} -> acc
    end
  end

  defp parse(""), do: %{status: nil, body: nil}

  defp parse(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    "HTTP/1.1 " <> rest = head
    {status, _} = Integer.parse(rest)
    %{status: status, body: decode(body)}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  # CONNECT through the proxy endpoint `path`; `{status, socket, rest}`.
  defp proxy_connect(path, authority) do
    {mod, sock} = conn = connect(path)
    :ok = mod.send(sock, "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n\r\n")
    {head, rest} = read_head(conn, "")
    "HTTP/1.1 " <> <<code::binary-size(3), _::binary>> = head
    {String.to_integer(code), conn, rest}
  end

  defp read_head({mod, sock} = conn, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, data} = mod.recv(sock, 0, 5_000)
        read_head(conn, acc <> data)
    end
  end

  defp read_exact(conn, n, acc \\ "")
  defp read_exact(_conn, n, acc) when byte_size(acc) >= n, do: acc

  defp read_exact({mod, sock} = conn, n, acc) do
    {:ok, data} = mod.recv(sock, 0, 10_000)
    read_exact(conn, n, acc <> data)
  end

  # What the primary recorded for `run`, minus what differs between runs.
  defp events(run) do
    Event
    |> Ash.Query.filter(run_id == ^run)
    |> Ash.read!()
    |> Enum.map(
      &{&1.host, &1.port, &1.decision, &1.policy_verdict, &1.mode, &1.reason, &1.task_id}
    )
    |> Enum.sort()
  end

  # ---- scenarios ---------------------------------------------------------------

  describe "the Arbiter bridge (arb and MCP)" do
    test "BridgeIdentity pins a tunnelled request to its run exactly as a local one", ctx do
      local_run = egress_run!(ctx, ctx.task, [])
      remote_run = egress_run!(ctx, ctx.task, [])
      local = %{"arb" => Egress.bridge_path(local_run, "arb", ctx.egress_dir)}
      remote = place!(ctx, remote_run).remote

      scenario = fn path ->
        coordinator = Scope.mint_coordinator(nil)

        %{
          own: http(path, "GET", "/api/issues/#{ctx.task.id}"),
          progress: http(path, "PATCH", "/api/issues/#{ctx.task.id}", json: %{"notes" => "n"}),
          sibling_write:
            http(path, "PATCH", "/api/issues/#{ctx.sibling.id}", json: %{"notes" => "no"}),
          list: http(path, "GET", "/api/issues"),
          coordinator_token_ignored:
            http(path, "GET", "/api/issues",
              headers: [{"authorization", "Bearer #{coordinator}"}]
            ),
          minting_refused: http(path, "POST", "/api/mcp/tokens", json: %{}),
          not_admitted: http(path, "GET", "/events"),
          mcp:
            http(path, "POST", "/mcp",
              json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
            )
        }
      end

      # A write changes the row's timestamps, so what is compared is the status
      # and, for a success, which row (an error's body is compared whole).
      outcome = fn
        %{status: 200, body: %{"id" => id}} -> {200, id}
        other -> other
      end

      run = fn path -> path |> scenario.() |> Map.new(fn {k, v} -> {k, outcome.(v)} end) end

      expected = run.(local["arb"])
      assert {200, id} = expected.own
      assert id == ctx.task.id
      assert %{status: 403} = expected.sibling_write
      assert %{status: 403} = expected.coordinator_token_ignored
      assert %{status: 403} = expected.minting_refused
      assert %{status: 403} = expected.not_admitted
      assert {200, 1} = expected.mcp

      assert run.(remote["arb"]) == expected
    end
  end

  describe "the egress proxy" do
    test "policy decisions and egress_events rows match a local run's", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      local_run = egress_run!(ctx, ctx.task, [allowed])
      remote_run = egress_run!(ctx, ctx.task, [allowed])
      local = Egress.socket_path(local_run, ctx.egress_dir)
      remote = place!(ctx, remote_run).remote["proxy"]

      assert {200, "hello through the tunnel", 403, 403} =
               expected = proxy_scenario(local, allowed)

      assert proxy_scenario(remote, allowed) == expected

      local_events = events(local_run)
      assert length(local_events) == 3
      assert events(remote_run) == local_events
    end

    test "a megabyte each way is relayed intact and credit-controlled", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      run = egress_run!(ctx, ctx.task, [allowed])
      path = place!(ctx, run).remote["proxy"]

      megabyte_round_trip(path, allowed)
    end
  end

  # K6 (bd-br4c8p, `docs/design/remote-workers.md` §16 K§9.3): a k8s pod reaches the
  # same primary-side egress run through the controller's TLS listener instead of
  # the agent's unix socket. Nothing on the primary may notice.
  describe "the k8s pod channel" do
    test "policy decisions and egress_events rows match a machine-node run's", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      machine_run = egress_run!(ctx, ctx.task, [allowed])
      pod_run = egress_run!(ctx, ctx.task, [allowed])
      machine = place!(ctx, machine_run).remote["proxy"]
      pod = place_pod!(ctx, pod_run).pod["proxy"]

      assert {200, "hello through the tunnel", 403, 403} =
               expected = proxy_scenario(machine, allowed)

      assert proxy_scenario(pod, allowed) == expected

      machine_events = events(machine_run)
      assert length(machine_events) == 3
      assert events(pod_run) == machine_events
    end

    test "BridgeIdentity pins a pod's request to its run exactly as a machine node's", ctx do
      machine_run = egress_run!(ctx, ctx.task, [])
      pod_run = egress_run!(ctx, ctx.task, [])
      machine = place!(ctx, machine_run).remote["arb"]
      pod = place_pod!(ctx, pod_run).pod["arb"]

      expected = arb_scenario(ctx, machine)
      assert {200, id} = expected.own
      assert id == ctx.task.id
      assert %{status: 403} = expected.sibling_write
      assert %{status: 403} = expected.coordinator_token_ignored
      assert {200, 1} = expected.mcp

      assert arb_scenario(ctx, pod) == expected
    end

    test "a megabyte each way is relayed intact over TLS", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      run = egress_run!(ctx, ctx.task, [allowed])

      megabyte_round_trip(place_pod!(ctx, run).pod["proxy"], allowed)
    end

    test "the end of a run closes its TLS streams", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      run = egress_run!(ctx, ctx.task, [allowed])
      placed = place_pod!(ctx, run)

      {200, {mod, sock}, _} = proxy_connect(placed.pod["proxy"], allowed)
      assert %{streams: [_]} = Bridge.info()

      assert :ok = Executor.stop(placed.handle)
      assert_eventually(fn -> Bridge.info().streams == [] end)

      # the pod's end saw the stream close
      assert {:error, _} = mod.recv(sock, 0, 5_000)
    end

    test "a run the controller has released is refused even with an unexpired leaf", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      run = egress_run!(ctx, ctx.task, [allowed])
      placed = place_pod!(ctx, run)

      :ok = PodChannel.release(run)

      {mod, sock} = connect(placed.pod["proxy"])
      assert {:error, _} = mod.recv(sock, 0, 5_000)
      assert Bridge.info().streams == []
    end

    test "egress_events are not written for a refused pod connection", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      run = egress_run!(ctx, ctx.task, [allowed])
      placed = place_pod!(ctx, run)
      :ok = PodChannel.release(run)

      {mod, sock} = connect(placed.pod["proxy"])
      assert {:error, _} = mod.recv(sock, 0, 5_000)
      assert events(run) == []
    end
  end

  describe "the end of a run" do
    test "its listeners and streams go with it", ctx do
      port = echo_server()
      allowed = "127.0.0.1:#{port}"
      run = egress_run!(ctx, ctx.task, [allowed])
      placed = place!(ctx, run)
      assert File.exists?(placed.remote["proxy"])

      {200, {mod, sock}, _} = proxy_connect(placed.remote["proxy"], allowed)
      assert %{streams: [_]} = Bridge.info()

      assert :ok = Executor.stop(placed.handle)

      assert_eventually(fn ->
        not File.exists?(placed.remote["proxy"]) and Bridge.info().streams == []
      end)

      # the container's end saw the stream close
      assert {:error, :closed} = mod.recv(sock, 0, 5_000)
    end
  end

  # ---- scenarios, run against any endpoint --------------------------------------

  defp proxy_scenario(endpoint, allowed) do
    {allowed_code, {mod, sock} = conn, _} = proxy_connect(endpoint, allowed)
    :ok = mod.send(sock, "hello through the tunnel")
    echoed = read_exact(conn, byte_size("hello through the tunnel"))
    mod.close(sock)

    {denied_code, {dmod, denied}, _} = proxy_connect(endpoint, "169.254.169.254:80")
    dmod.close(denied)
    {other_code, {omod, other}, _} = proxy_connect(endpoint, "evil.example:443")
    omod.close(other)

    {allowed_code, echoed, denied_code, other_code}
  end

  defp megabyte_round_trip(endpoint, allowed) do
    {200, {mod, sock} = conn, _} = proxy_connect(endpoint, allowed)
    payload = :crypto.strong_rand_bytes(1_048_576)

    sender = Task.async(fn -> mod.send(sock, payload) end)
    assert read_exact(conn, byte_size(payload)) == payload
    assert :ok = Task.await(sender, 10_000)
    mod.close(sock)
  end

  # A write changes the row's timestamps, so what is compared is the status
  # and, for a success, which row (an error's body is compared whole).
  defp arb_scenario(ctx, path) do
    coordinator = Scope.mint_coordinator(nil)

    %{
      own: http(path, "GET", "/api/issues/#{ctx.task.id}"),
      progress: http(path, "PATCH", "/api/issues/#{ctx.task.id}", json: %{"notes" => "n"}),
      sibling_write:
        http(path, "PATCH", "/api/issues/#{ctx.sibling.id}", json: %{"notes" => "no"}),
      list: http(path, "GET", "/api/issues"),
      coordinator_token_ignored:
        http(path, "GET", "/api/issues", headers: [{"authorization", "Bearer #{coordinator}"}]),
      minting_refused: http(path, "POST", "/api/mcp/tokens", json: %{}),
      not_admitted: http(path, "GET", "/events"),
      mcp:
        http(path, "POST", "/mcp",
          json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
        )
    }
    |> Map.new(fn
      {k, %{status: 200, body: %{"id" => id}}} -> {k, {200, id}}
      {k, other} -> {k, other}
    end)
  end

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
end
