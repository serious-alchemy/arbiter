defmodule ArbiterWeb.Spike.K11ProxyWsTest do
  @moduledoc """
  K1 spike (bd-6zl538), docs/design/remote-workers.md §16.15 **K11**: does Mint's `connect(proxy: …)` carry a Phoenix V2
  WebSocket through tailscale's **userspace HTTP proxy** (`tailscaled --tun=userspace-networking
  --outbound-http-proxy-listen`), over a real WireGuard path, and does a heartbeat-quiet socket survive 30 minutes?

  Driven by `docs/design/k8s-spike/60-k11-tailnet.sh` (disposable headscale + two userspace tailscaled nodes; no real
  tailnet is touched). Excluded by default: tag `:spike_k8s`. Env: `SPIKE_PROXY_PORT`, `SPIKE_TARGET_HOST`,
  `SPIKE_TARGET_PORT`, `SPIKE_CERTDIR`, `SPIKE_LISTEN_PORT`, `SPIKE_SOAK_SECONDS`.
  """
  use ExUnit.Case, async: false

  alias ArbiterWeb.Spike.Endpoint
  alias ArbiterWeb.Spike.WsClient

  @moduletag :spike_k8s
  @moduletag timeout: 4_000_000

  @proxy_port String.to_integer(System.get_env("SPIKE_PROXY_PORT", "18055"))
  @target_host System.get_env("SPIKE_TARGET_HOST", "100.64.0.2")
  @target_port System.get_env("SPIKE_TARGET_PORT", "8443")
  @listen_port String.to_integer(System.get_env("SPIKE_LISTEN_PORT", "19443"))
  @soak_s String.to_integer(System.get_env("SPIKE_SOAK_SECONDS", "60"))

  setup_all do
    certdir = System.fetch_env!("SPIKE_CERTDIR")
    start_supervised!({Phoenix.PubSub, name: ArbiterWeb.Spike.PubSub})

    Endpoint.configure(
      http: false,
      https: [
        ip: {127, 0, 0, 1},
        port: @listen_port,
        certfile: Path.join(certdir, "server.crt"),
        keyfile: Path.join(certdir, "server.key"),
        cipher_suite: :strong
      ]
    )

    start_supervised!(Endpoint)
    {:ok, certdir: certdir}
  end

  defp report(key, map) do
    line = Jason.encode!(%{k11: key, detail: map})
    IO.puts("SPIKE_RESULT " <> line)
    if f = System.get_env("SPIKE_RESULTS_FILE"), do: File.write!(f, line <> "\n", [:append])
  end

  defp tls(certdir),
    do: [nodelay: true, cacertfile: String.to_charlist(Path.join(certdir, "ca.crt"))]

  defp proxy(port \\ @proxy_port), do: {:http, "127.0.0.1", port, []}

  defp via_proxy_url,
    do: "wss://#{@target_host}:#{@target_port}/node/socket/websocket?vsn=2.0.0&token=spike-token"

  defp direct_url,
    do: "wss://127.0.0.1:#{@listen_port}/node/socket/websocket?vsn=2.0.0&token=spike-token"

  test "baseline: the same TLS WebSocket with no proxy (loopback)", %{certdir: certdir} do
    {:ok, c} = WsClient.start_link(url: direct_url(), owner: self(), transport_opts: tls(certdir))
    assert {:ok, _} = WsClient.join(c, "node:spike")
    WsClient.push(c, "node:spike", "hb", %{"seq" => 1, "t" => 0})
    assert_receive {:ws, :push, "node:spike", "hb_ack", %{"seq" => 1}}, 10_000
    report("baseline_direct", %{joined: true})
  end

  test "through tailscaled's userspace HTTP proxy: join, heartbeat, 1 MB binary echo byte-exact",
       %{certdir: certdir} do
    t0 = System.monotonic_time(:millisecond)

    {:ok, c} =
      WsClient.start_link(
        url: via_proxy_url(),
        owner: self(),
        transport_opts: tls(certdir),
        proxy: proxy()
      )

    assert {:ok, _} = WsClient.join(c, "node:spike")
    connect_ms = System.monotonic_time(:millisecond) - t0
    WsClient.push(c, "node:spike", "hb", %{"seq" => 1, "t" => 0})
    assert_receive {:ws, :push, "node:spike", "hb_ack", %{"seq" => 1}}, 10_000

    payload = :crypto.strong_rand_bytes(1_000_000)
    t1 = System.monotonic_time(:millisecond)
    WsClient.push(c, "node:spike", "echo_bin", {:binary, payload})
    assert_receive {:ws, :push, "node:spike", "echo_bin", {:binary, ^payload}}, 30_000

    report("proxy_ws", %{
      connect_join_ms: connect_ms,
      echo_1MB_ms: System.monotonic_time(:millisecond) - t1,
      byte_exact: true
    })
  end

  test "failure shapes: proxy port closed, and a CONNECT target nothing listens on" do
    Process.flag(:trap_exit, true)

    r1 =
      WsClient.start_link(
        url: via_proxy_url(),
        owner: self(),
        proxy: proxy(1),
        transport_opts: [nodelay: true]
      )

    r2 =
      WsClient.start_link(
        url: "wss://#{@target_host}:9/node/socket/websocket",
        owner: self(),
        proxy: proxy(),
        transport_opts: [nodelay: true]
      )

    report("proxy_failures", %{proxy_port_closed: inspect(r1), connect_target_closed: inspect(r2)})

    assert match?({:error, _}, r1)
    assert match?({:error, _}, r2)
  end

  defp heartbeat_socket(url, opts, hb_ms, seconds, label) do
    {:ok, c} = WsClient.start_link([url: url, owner: self()] ++ opts)
    {:ok, _} = WsClient.join(c, "node:spike")
    started = System.monotonic_time(:millisecond)
    loop(c, hb_ms, started + seconds * 1000, 0, [], started, label)
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
      if rem(seq * hb_ms, 30_000) < hb_ms, do: WsClient.heartbeat(c)

      receive do
        {:ws, :push, "node:spike", "hb_ack", %{"seq" => ^seq}} ->
          rtt = System.monotonic_time(:millisecond) - now
          drain_for(max(hb_ms - rtt, 0))
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
  test "soak: heartbeat-quiet sockets stay open through the proxy for #{@soak_s}s (10 s design heartbeat; 50 s just under the 60 s idle timeout)",
       %{certdir: certdir} do
    opts = [transport_opts: tls(certdir), proxy: proxy()]

    tasks = [
      Task.async(fn ->
        heartbeat_socket(via_proxy_url(), opts, 10_000, @soak_s, "hb10s-via-proxy")
      end),
      Task.async(fn ->
        heartbeat_socket(via_proxy_url(), opts, 50_000, @soak_s, "hb50s-via-proxy")
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
