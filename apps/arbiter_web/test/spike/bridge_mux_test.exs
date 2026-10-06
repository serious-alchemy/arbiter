defmodule ArbiterWeb.Spike.BridgeMuxTest do
  @moduledoc """
  RW2 spike (bd-6tx1xv), docs/design/remote-workers.md **U3** and **U4**.

  U3: the bridge mux adds p99 <= 250 ms at 10 concurrent runs, replaying one
  SSE trace per run through `client -> node unix listener -> WS (Bandit, real
  TCP) -> primary channel -> primary unix listener -> fake upstream` and
  directly (`client -> primary unix listener`) as the control.

  U4: heartbeat jitter < 5 s on the same socket during a 5 MB push.

  Link shaping is applied from outside, so the numbers are labelled by the
  environment: run via `test/spike/run_netem.sh <rtt_ms> <rate> -- mix test ...`
  (a private user+net namespace; `tc netem` on its loopback). Each scenario
  prints `SPIKE_RESULT {json}` and appends it to `$SPIKE_RESULTS_FILE`.

  Excluded by default: `mix test --include spike_rw test/spike/bridge_mux_test.exs`.
  """
  use ExUnit.Case, async: false

  alias ArbiterWeb.Spike.AgentMux
  alias ArbiterWeb.Spike.Endpoint
  alias ArbiterWeb.Spike.Load
  alias ArbiterWeb.Spike.Upstream

  @moduletag :spike_rw
  @moduletag timeout: 900_000

  @runs String.to_integer(System.get_env("SPIKE_RUNS", "10"))
  @sse_seconds String.to_integer(System.get_env("SPIKE_SSE_SECONDS", "20"))
  @hb_ms 200
  @push_bytes 5 * 1024 * 1024

  setup do
    if System.get_env("SPIKE_LOG"), do: Logger.configure(level: :debug)
    dir = Path.join(System.tmp_dir!(), "rw2-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    upstreams =
      for i <- 1..@runs, into: %{}, do: {{"run#{i}", "proxy"}, Path.join(dir, "p#{i}.sock")}

    Application.put_env(:arbiter_web, :spike_upstreams, upstreams)
    on_exit(fn -> Application.delete_env(:arbiter_web, :spike_upstreams) end)

    listeners = for {{run, _}, path} <- upstreams, do: {run, Upstream.listen(path)}
    on_exit(fn -> for {_, l} <- listeners, do: :gen_tcp.close(l) end)

    start_supervised!({Phoenix.PubSub, name: ArbiterWeb.Spike.PubSub})
    # SPIKE_NODE_CAP overrides the design's 1 MiB per-node in-flight cap (both ends).
    node_cap = String.to_integer(System.get_env("SPIKE_NODE_CAP", "1048576"))
    Application.put_env(:arbiter_web, :spike_node_cap, node_cap)
    on_exit(fn -> Application.delete_env(:arbiter_web, :spike_node_cap) end)
    Endpoint.configure()
    start_supervised!(Endpoint)

    node_paths = for i <- 1..@runs, do: {"run#{i}", Path.join(dir, "n#{i}.sock")}

    agent =
      start_supervised!({
        AgentMux,
        # SPIKE_NODELAY=0 reproduces the Nagle/delayed-ACK stall the finding is about.
        # SPIKE_SOCKETS=K shards runs over K WebSockets (the lossy-link fallback).
        url: "ws://127.0.0.1:#{Endpoint.port()}/node/socket/websocket?vsn=2.0.0&token=spike-token",
        listeners: node_paths,
        transport_opts: if(System.get_env("SPIKE_NODELAY") == "0", do: [], else: [nodelay: true]),
        mux: [node_cap: node_cap],
        sockets: String.to_integer(System.get_env("SPIKE_SOCKETS", "1")),
        hb_ms: @hb_ms
      })

    trace_file = Path.join(dir, "trace.bin")
    File.write!(trace_file, :erlang.term_to_binary(Upstream.trace(@sse_seconds)))

    %{
      agent: agent,
      node_paths: Map.new(node_paths),
      direct_paths: Map.new(upstreams, fn {{run, _}, p} -> {run, p} end),
      trace_file: trace_file
    }
  end

  defp label, do: System.get_env("SPIKE_LABEL", "loopback")

  defp report(name, map) do
    line = Jason.encode!(Map.merge(%{scenario: name, label: label(), runs: @runs}, map))
    IO.puts("SPIKE_RESULT " <> line)
    if f = System.get_env("SPIKE_RESULTS_FILE"), do: File.write!(f, line <> "\n", [:append])
  end

  defp concurrent_sse(paths, trace_file) do
    paths
    |> Map.values()
    |> Task.async_stream(&Load.sse(&1, trace_file), timeout: :infinity, max_concurrency: @runs)
    |> Enum.flat_map(fn {:ok, {lat, _bytes}} -> lat end)
  end

  test "U3: SSE replay x10 runs — direct vs through the mux", ctx do
    :ok = AgentMux.stop_heartbeats(ctx.agent)
    cpu0 = Load.cpu_seconds()
    t0 = System.monotonic_time(:millisecond)
    direct = concurrent_sse(ctx.direct_paths, ctx.trace_file)
    direct_wall = System.monotonic_time(:millisecond) - t0
    cpu1 = Load.cpu_seconds()

    t1 = System.monotonic_time(:millisecond)
    muxed = concurrent_sse(ctx.node_paths, ctx.trace_file)
    mux_wall = System.monotonic_time(:millisecond) - t1
    cpu2 = Load.cpu_seconds()

    d = Load.summary(direct)
    m = Load.summary(muxed)

    report("u3_sse", %{
      events_direct: d.n,
      events_mux: m.n,
      direct: d,
      mux: m,
      added_p50_ms: Float.round(m.p50_ms - d.p50_ms, 2),
      added_p99_ms: Float.round(m.p99_ms - d.p99_ms, 2),
      beam_cpu_s_direct: Float.round(cpu1 - cpu0, 2),
      beam_cpu_s_mux: Float.round(cpu2 - cpu1, 2),
      wall_ms_direct: direct_wall,
      wall_ms_mux: mux_wall
    })

    assert m.n == d.n, "the mux dropped or duplicated SSE events"
  end

  test "U3: connection setup (CONNECT-sized round trips) — direct vs mux", ctx do
    :ok = AgentMux.stop_heartbeats(ctx.agent)

    one = fn paths ->
      paths
      |> Map.values()
      |> Task.async_stream(&Load.small(&1, 20), timeout: :infinity, max_concurrency: @runs)
      |> Enum.flat_map(fn {:ok, r} -> r end)
    end

    direct = one.(ctx.direct_paths)
    muxed = one.(ctx.node_paths)

    d = Load.summary(Enum.map(direct, & &1.ttfb_us))
    m = Load.summary(Enum.map(muxed, & &1.ttfb_us))

    report("u3_setup_ttfb", %{
      connections: length(muxed),
      direct: d,
      mux: m,
      added_p99_ms: Float.round(m.p99_ms - d.p99_ms, 2)
    })

    assert length(muxed) == @runs * 20
  end

  defp hb_stats(samples) do
    rtts = Enum.map(samples, fn {_sent, rtt, _ack} -> rtt * 1000 end)
    acks = Enum.map(samples, fn {_s, _r, ack} -> ack end)
    gaps = acks |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    %{
      samples: length(samples),
      rtt: if(rtts == [], do: nil, else: Load.summary(rtts)),
      max_ack_gap_ms: if(gaps == [], do: 0, else: Float.round(Enum.max(gaps) * 1.0, 1)),
      jitter_ms:
        if(gaps == [],
          do: 0,
          else: Float.round(Enum.max(for g <- gaps, do: abs(g - @hb_ms)) * 1.0, 1)
        )
    }
  end

  defp window(samples, from_ms, to_ms),
    do: Enum.filter(samples, fn {sent, _, _} -> sent >= from_ms and sent <= to_ms end)

  defp heartbeat_during(ctx, name, fun) do
    Process.sleep(3_000)
    idle = AgentMux.heartbeats(ctx.agent)
    start = System.monotonic_time(:microsecond) / 1000
    result = fun.()
    stop = System.monotonic_time(:microsecond) / 1000
    Process.sleep(1_000)
    all = AgentMux.heartbeats(ctx.agent)
    during = window(all, start, stop)
    sent_total = length(all)

    report(name, %{
      push_ms: round(stop - start),
      idle_hb: hb_stats(idle),
      during_hb: hb_stats(during),
      hb_sent_acked_total: sent_total,
      result: result
    })

    during
  end

  test "U4: heartbeat during a 5 MiB push node->primary", ctx do
    during =
      heartbeat_during(ctx, "u4_push_up", fn ->
        us = Load.push(ctx.node_paths["run1"], @push_bytes)
        %{mib_per_s: Float.round(@push_bytes / 1_048_576 / (us / 1_000_000), 2)}
      end)

    assert during != []
    assert hb_stats(during).rtt.max_ms < 5_000
  end

  test "U4: heartbeat during a 5 MiB pull primary->node (the hb_ack direction)", ctx do
    during =
      heartbeat_during(ctx, "u4_pull_down", fn ->
        us = Load.pull(ctx.node_paths["run1"], @push_bytes)
        %{mib_per_s: Float.round(@push_bytes / 1_048_576 / (us / 1_000_000), 2)}
      end)

    assert during != []
    assert hb_stats(during).rtt.max_ms < 5_000
  end

  test "U4: worst case — 5 MiB up + 5 MiB down + 8 SSE runs at once", ctx do
    during =
      heartbeat_during(ctx, "u4_worst_case", fn ->
        sse_paths = Map.drop(ctx.node_paths, ["run1", "run2"])
        sse = Task.async(fn -> concurrent_sse(sse_paths, ctx.trace_file) end)
        up = Task.async(fn -> Load.push(ctx.node_paths["run1"], @push_bytes) end)
        down = Task.async(fn -> Load.pull(ctx.node_paths["run2"], @push_bytes) end)
        events = length(Task.await(sse, :infinity))
        Task.await(up, :infinity)
        Task.await(down, :infinity)
        %{sse_events: events}
      end)

    assert during != []
    assert hb_stats(during).rtt.max_ms < 5_000
  end
end
