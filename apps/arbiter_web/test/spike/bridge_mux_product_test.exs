defmodule ArbiterWeb.Spike.BridgeMuxProductTest do
  @moduledoc """
  RW10 (bd-54ibeo): RW2's **U3** and **U4** re-measured against the *product*
  bridge, not the spike prototype (`bridge_mux_test.exs`).

  Every hop is the shipped code: the agent's `Arbiter.NodeAgent.Bridge` listeners
  and `Connection` (heartbeat every 200 ms), a real WebSocket to the real
  `NodeSocket`/`NodeChannel`, the primary's `Arbiter.Nodes.Bridge`, and a unix
  listener where the primary's `Egress` listener would be (the fake far end of
  RW2's spike, `ArbiterWeb.Spike.Upstream`, replaying the same SSE trace and
  generating the same pushes). Each run's container side is a unix socket the
  agent listens on; the control is the same client straight at the upstream
  listener.

  The product's own heartbeat is every 10 s, fixed by the primary, which is too
  slow to measure a stall by: a probe process pushes an extra `hb` every 200 ms
  through the agent's own WebSocket (the same socket and queue the bridge uses).

  U3: `client -> node listener -> WS -> channel -> primary listener -> upstream`
  against the direct path, 10 concurrent runs, one 20 s SSE trace each; the
  added p99 must be <= 250 ms. U4: while 5 MiB goes up, 5 MiB comes down, and
  both with 8 SSE runs at once, neither the primary's view of the node's heartbeat
  (`Session.snapshot/1`'s `silence_ms`, node -> primary) nor the agent's of the
  `hb_ack` (`Connection.info/0`'s `last_ack`, primary -> node), both sampled every
  20 ms, may go 5 s without an update.

  Link shaping is applied from outside (`test/spike/run_netem.sh <rtt_ms> <rate>
  -- mix test ...`). Each scenario prints `SPIKE_RESULT {json}` and appends it to
  `$SPIKE_RESULTS_FILE`. A short `TMPDIR` is needed (unix socket paths).

  Excluded by default: `mix test --include spike_rw test/spike/bridge_mux_product_test.exs`.
  """
  use ArbiterWeb.ChannelCase, async: false

  alias Arbiter.NodeAgent.{Bridge, Config, Connection, Runs, Status, WsClient}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry, Session}
  alias Arbiter.Worker.Executor.Node, as: Executor
  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}
  alias ArbiterWeb.Spike.{Load, Upstream}

  @moduletag :spike_rw
  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: 900_000

  @runs String.to_integer(System.get_env("SPIKE_RUNS", "10"))
  @sse_seconds String.to_integer(System.get_env("SPIKE_SSE_SECONDS", "20"))
  @hb_ms 200
  @push_bytes 5 * 1024 * 1024
  @version "1.2.3"

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(System.tmp_dir!(), "bp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    Application.put_env(:arbiter, :node_primary_version, @version)
    Application.put_env(:arbiter_web, :node_session_opts, tick_ms: :infinity)

    on_exit(fn ->
      Application.delete_env(:arbiter, :node_primary_version)
      Application.delete_env(:arbiter_web, :node_session_opts)
    end)

    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "bridge-measure"], "operator:test")
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
        hb_interval_ms: @hb_ms,
        fence_after_ms: 600_000,
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
          bridges_fun: &Bridge.listen/2,
          bridges_release_fun: &Bridge.release/1
        ]
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)
    start_supervised!({Bridge, node_home: home})
    start_supervised!({Connection, config: config})

    assert_receive {:node_state, _id, :online}, 10_000
    session = Registry.lookup(node.id)

    client = :sys.get_state(Connection).client
    start_supervised!({Task, fn -> probe(client, "node:" <> node.id, 0) end})

    # One run per upstream: the primary's side of each is a listener the bridge dials.
    upstreams =
      for i <- 1..@runs, into: %{} do
        run = "run#{i}"
        path = Path.join(root, "u#{i}.sock")
        lsock = Upstream.listen(path)
        on_exit(fn -> :gen_tcp.close(lsock) end)
        {run, path}
      end

    for {run, path} <- upstreams do
      {:ok, prepared} = Executor.prepare(node.id, spec(run, path), owner: self())
      {:ok, _handle} = Executor.open(prepared)
    end

    trace_file = Path.join(root, "trace.bin")
    File.write!(trace_file, :erlang.term_to_binary(Upstream.trace(@sse_seconds)))

    %{
      session: session,
      trace_file: trace_file,
      direct: upstreams,
      node_paths:
        Map.new(upstreams, fn {run, _} ->
          {run, Path.join([home, "runs", run, "bridge", "proxy.sock"])}
        end)
    }
  end

  defp spec(run, upstream) do
    %{
      "version" => 1,
      "run" => run,
      "task" => "bd-measure",
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
      "bridges" => [%{"name" => "proxy", "path" => upstream}],
      "command" => ["claude", "--print"]
    }
  end

  defp label, do: System.get_env("SPIKE_LABEL", "loopback")

  defp report(name, map) do
    line =
      Jason.encode!(
        Map.merge(%{scenario: name, label: label(), runs: @runs, impl: "product"}, map)
      )

    IO.puts("SPIKE_RESULT " <> line)
    if f = System.get_env("SPIKE_RESULTS_FILE"), do: File.write!(f, line <> "\n", [:append])
  end

  defp concurrent_sse(paths, trace_file) do
    paths
    |> Map.values()
    |> Task.async_stream(&Load.sse(&1, trace_file), timeout: :infinity, max_concurrency: @runs)
    |> Enum.flat_map(fn {:ok, {lat, _bytes}} -> lat end)
  end

  # An extra heartbeat every `@hb_ms`, on the agent's own socket.
  defp probe(client, topic, seq) do
    WsClient.push(client, topic, "hb", %{"seq" => seq})
    Process.sleep(@hb_ms)
    probe(client, topic, seq + 1)
  end

  # The longest, while `fun` ran, the primary went without a heartbeat from the
  # node and the node without an `hb_ack`: `{%{primary_ms:, agent_ms:}, result}`.
  defp max_silence(session, fun) do
    parent = self()

    sampler =
      spawn_link(fn ->
        receive do
          :go -> sample(session, parent, %{primary_ms: 0, agent_ms: 0})
        end
      end)

    send(sampler, :go)
    result = fun.()
    send(sampler, :stop)

    receive do
      {:max_silence, max} -> {max, result}
    after
      5_000 -> flunk("sampler never reported")
    end
  end

  defp sample(session, parent, max) do
    receive do
      :stop -> send(parent, {:max_silence, max})
    after
      20 ->
        agent_ms = System.monotonic_time(:millisecond) - Connection.info().last_ack

        sample(session, parent, %{
          primary_ms: max(max.primary_ms, Session.snapshot(session).silence_ms),
          agent_ms: max(max.agent_ms, agent_ms)
        })
    end
  end

  test "U3: SSE replay x10 runs, direct vs through the product bridge", ctx do
    cpu0 = Load.cpu_seconds()
    direct = concurrent_sse(ctx.direct, ctx.trace_file)
    cpu1 = Load.cpu_seconds()
    muxed = concurrent_sse(ctx.node_paths, ctx.trace_file)
    cpu2 = Load.cpu_seconds()

    d = Load.summary(direct)
    m = Load.summary(muxed)
    added_p99 = Float.round(m.p99_ms - d.p99_ms, 2)

    report("u3_sse", %{
      direct: d,
      mux: m,
      added_p50_ms: Float.round(m.p50_ms - d.p50_ms, 2),
      added_p99_ms: added_p99,
      beam_cpu_s_direct: Float.round(cpu1 - cpu0, 2),
      beam_cpu_s_mux: Float.round(cpu2 - cpu1, 2)
    })

    assert m.n == d.n, "the bridge dropped or duplicated SSE events"
    assert added_p99 <= 250, "U3: added p99 #{added_p99} ms > 250 ms"
  end

  test "U3: connection setup, direct vs through the product bridge", ctx do
    one = fn paths ->
      paths
      |> Map.values()
      |> Task.async_stream(&Load.small(&1, 20), timeout: :infinity, max_concurrency: @runs)
      |> Enum.flat_map(fn {:ok, r} -> r end)
    end

    d = Load.summary(Enum.map(one.(ctx.direct), & &1.ttfb_us))
    m = Load.summary(Enum.map(one.(ctx.node_paths), & &1.ttfb_us))

    report("u3_setup_ttfb", %{
      direct: d,
      mux: m,
      added_p99_ms: Float.round(m.p99_ms - d.p99_ms, 2)
    })

    assert m.n == @runs * 20
  end

  test "U4: heartbeat while 5 MiB goes up, 5 MiB comes down, and 8 SSE runs stream", ctx do
    session = ctx.session
    {idle, :ok} = max_silence(session, fn -> Process.sleep(3_000) end)

    {up_silence, up_us} =
      max_silence(session, fn -> Load.push(ctx.node_paths["run1"], @push_bytes) end)

    {down_silence, down_us} =
      max_silence(session, fn -> Load.pull(ctx.node_paths["run1"], @push_bytes) end)

    {worst, events} =
      max_silence(session, fn ->
        sse_paths = Map.drop(ctx.node_paths, ["run1", "run2"])
        sse = Task.async(fn -> concurrent_sse(sse_paths, ctx.trace_file) end)
        up = Task.async(fn -> Load.push(ctx.node_paths["run1"], @push_bytes) end)
        down = Task.async(fn -> Load.pull(ctx.node_paths["run2"], @push_bytes) end)
        events = length(Task.await(sse, :infinity))
        Task.await(up, :infinity)
        Task.await(down, :infinity)
        events
      end)

    mib_s = fn us -> Float.round(@push_bytes / 1_048_576 / (us / 1_000_000), 2) end

    report("u4_heartbeat", %{
      hb_probe_ms: @hb_ms,
      idle: idle,
      push: up_silence,
      pull: down_silence,
      worst_case: worst,
      push_mib_per_s: mib_s.(up_us),
      pull_mib_per_s: mib_s.(down_us),
      worst_case_sse_events: events
    })

    for {name, gaps} <- [push: up_silence, pull: down_silence, worst_case: worst],
        {side, ms} <- gaps do
      assert ms < 5_000, "U4 #{name}: #{side} went #{ms} ms without a heartbeat"
    end
  end
end
