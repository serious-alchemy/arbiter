defmodule ArbiterWeb.Spike.ServeSoakTest do
  @moduledoc """
  RW2 spike (bd-6tx1xv), docs/design/remote-workers.md **U1**: does the operator's
  real `tailscale serve` carry a Phoenix WebSocket on a non-dashboard path, keep
  a heartbeat-quiet socket alive, and does `--set-path` restrict the exposure?

  Needs a live tailnet, so it is driven by `serve_soak.sh` (which adds two
  throwaway `serve` ports, runs this, and removes them). Excluded by default:
  tag `:spike_serve`, env `SPIKE_SERVE_HOST`, `SPIKE_PORT`, `SPIKE_SOAK_SECONDS`.
  """
  use ExUnit.Case, async: false

  alias ArbiterWeb.Spike.Endpoint
  alias ArbiterWeb.Spike.WsClient

  @moduletag :spike_serve
  @moduletag timeout: 4_000_000

  @host System.get_env("SPIKE_SERVE_HOST")
  @full_port System.get_env("SPIKE_FULL_PORT", "8443")
  @path_port System.get_env("SPIKE_PATH_PORT", "8444")
  @soak_s String.to_integer(System.get_env("SPIKE_SOAK_SECONDS", "1800"))

  setup_all do
    if is_nil(@host), do: raise("set SPIKE_SERVE_HOST (use serve_soak.sh)")
    start_supervised!({Phoenix.PubSub, name: ArbiterWeb.Spike.PubSub})

    Endpoint.configure(
      http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.fetch_env!("SPIKE_PORT"))]
    )

    start_supervised!(Endpoint)
    :ok
  end

  defp report(key, map) do
    line = Jason.encode!(%{u1: key, detail: map})
    IO.puts("SPIKE_RESULT " <> line)
    if f = System.get_env("SPIKE_RESULTS_FILE"), do: File.write!(f, line <> "\n", [:append])
  end

  defp https(port, path), do: "https://#{@host}:#{port}#{path}"
  defp wss(port, path), do: "wss://#{@host}:#{port}#{path}?vsn=2.0.0&token=spike-token"

  defp get(url) do
    Req.get!(url, retry: false, redirect: false, receive_timeout: 15_000, decode_body: false)
  end

  test "plain HTTP through the whole-app mapping, and what identity headers serve adds" do
    resp = get(https(@full_port, "/nodes/ping"))
    assert resp.status == 200 and resp.body == "pong"

    seen = get(https(@full_port, "/nodes/headers")).body |> Jason.decode!()
    names = seen["headers"] |> Map.keys() |> Enum.sort()
    ts = Map.take(seen["headers"], Enum.filter(names, &String.starts_with?(&1, "tailscale-")))

    report("http_whole_app", %{
      peer: seen["peer"],
      request_path: seen["request_path"],
      tailscale_headers:
        Map.new(ts, fn {k, v} ->
          {k, if(k == "tailscale-user-login", do: v, else: "<present>")}
        end),
      x_forwarded_for: seen["headers"]["x-forwarded-for"],
      header_names: names
    })
  end

  test "a WebSocket on /node/socket joins, echoes JSON and 1 MiB of binary through serve (whole-app mapping)" do
    {:ok, c} = WsClient.start_link(url: wss(@full_port, "/node/socket/websocket"), owner: self())
    assert {:ok, _} = WsClient.join(c, "node:spike")
    WsClient.push(c, "node:spike", "hb", %{"seq" => 1, "t" => 0})
    assert_receive {:ws, :push, "node:spike", "hb_ack", %{"seq" => 1}}, 10_000

    payload = :crypto.strong_rand_bytes(1_000_000)
    WsClient.push(c, "node:spike", "echo_bin", {:binary, payload})
    assert_receive {:ws, :push, "node:spike", "echo_bin", {:binary, ^payload}}, 30_000
    report("ws_whole_app", %{joined: true, binary_bytes_echoed: byte_size(payload)})
  end

  test "--set-path exposes only /nodes and /node/socket" do
    assert get(https(@path_port, "/nodes/ping")).body == "pong"
    # `/` (the dashboard) and an unmapped websocket path are not served by this port.
    root = get(https(@path_port, "/"))
    other = get(https(@path_port, "/live"))
    assert root.status in [404, 502, 403] and root.body != "dashboard"
    assert other.status in [404, 502, 403]

    {:ok, c} = WsClient.start_link(url: wss(@path_port, "/node/socket/websocket"), owner: self())
    assert {:ok, _} = WsClient.join(c, "node:spike")

    Process.flag(:trap_exit, true)

    {:ok, c2} =
      WsClient.start_link(url: wss(@path_port, "/other/socket/websocket"), owner: self())

    ref = Process.monitor(c2)
    assert_receive {:ws, :closed, {:upgrade_rejected, status, _}}, 10_000
    assert status in [404, 403, 502]
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000

    # What path does the backend actually see? (--set-path strips or keeps the mount.)
    seen = get(https(@path_port, "/nodes/headers")).body |> Jason.decode!()

    report("set_path", %{
      root_status: root.status,
      live_status: other.status,
      other_socket_upgrade_status: status,
      backend_saw_path_for_nodes_headers: seen["request_path"]
    })
  end

  defp heartbeat_socket(url, hb_ms, seconds, label) do
    {:ok, c} = WsClient.start_link(url: url, owner: self(), transport_opts: [nodelay: true])
    {:ok, _} = WsClient.join(c, "node:spike")
    started = System.monotonic_time(:millisecond)
    deadline = started + seconds * 1000
    loop(c, hb_ms, deadline, 0, [], started, label)
  end

  defp loop(c, hb_ms, deadline, seq, rtts, started, label) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      WsClient.close(c)

      %{
        label: label,
        hb_ms: hb_ms,
        sent: seq,
        acked: length(rtts),
        alive_s: div(now - started, 1000),
        closed?: false,
        rtt_ms: rtt_summary(rtts)
      }
    else
      seq = seq + 1
      WsClient.push(c, "node:spike", "hb", %{"seq" => seq, "t" => now})
      # the Phoenix-level heartbeat as well, at its usual 30 s cadence
      if rem(seq * hb_ms, 30_000) < hb_ms, do: WsClient.heartbeat(c)

      receive do
        {:ws, :push, "node:spike", "hb_ack", %{"seq" => ^seq}} ->
          rtt = System.monotonic_time(:millisecond) - now
          wait = max(hb_ms - rtt, 0)
          drain_for(wait)
          loop(c, hb_ms, deadline, seq, [rtt | rtts], started, label)

        {:ws, :closed, reason} ->
          %{
            label: label,
            hb_ms: hb_ms,
            sent: seq,
            acked: length(rtts),
            alive_s: div(System.monotonic_time(:millisecond) - started, 1000),
            closed?: true,
            reason: inspect(reason)
          }
      after
        20_000 ->
          %{
            label: label,
            hb_ms: hb_ms,
            sent: seq,
            acked: length(rtts),
            alive_s: div(System.monotonic_time(:millisecond) - started, 1000),
            closed?: false,
            reason: "hb_ack timeout",
            rtt_ms: rtt_summary(rtts)
          }
      end
    end
  end

  defp drain_for(ms) do
    receive do
      {:ws, :closed, _} = m -> send(self(), m)
      {:ws, _, _, _, _} -> drain_for(ms)
      {:ws, _, _, _} -> drain_for(ms)
    after
      ms -> :ok
    end
  end

  defp rtt_summary([]), do: nil

  defp rtt_summary(rtts) do
    sorted = Enum.sort(rtts)

    %{
      min: hd(sorted),
      p50: Enum.at(sorted, div(length(sorted), 2)),
      p99: Enum.at(sorted, max(ceil(length(sorted) * 0.99) - 1, 0)),
      max: List.last(sorted)
    }
  end

  @tag timeout: 4_000_000
  test "soak: heartbeat-quiet sockets stay open through serve for #{@soak_s}s (10 s design heartbeat, and 50 s just under the 60 s server idle timeout)" do
    url = wss(@path_port, "/node/socket/websocket")

    tasks = [
      Task.async(fn -> heartbeat_socket(url, 10_000, @soak_s, "hb10s") end),
      Task.async(fn -> heartbeat_socket(url, 50_000, @soak_s, "hb50s") end),
      Task.async(fn ->
        heartbeat_socket(
          wss(@full_port, "/node/socket/websocket"),
          10_000,
          @soak_s,
          "hb10s-whole-app"
        )
      end)
    ]

    results = Task.await_many(tasks, (@soak_s + 120) * 1000)
    report("soak", %{seconds: @soak_s, sockets: results})

    for r <- results,
        do: refute(r.closed?, "socket #{r.label} was closed during the soak: #{inspect(r)}")

    for r <- results,
        do:
          assert(
            r.acked >= div(@soak_s * 1000, r.hb_ms) - 2,
            "socket #{r.label} missed heartbeats: #{inspect(r)}"
          )
  end
end
