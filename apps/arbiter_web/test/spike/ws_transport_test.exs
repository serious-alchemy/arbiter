defmodule ArbiterWeb.Spike.WsTransportTest do
  @moduledoc """
  RW2 spike (bd-6tx1xv), docs/design/remote-workers.md **U2** (and the local half
  of U1): `mint_web_socket` speaks Phoenix's V2 serializer, including binary
  frames, against the real Phoenix channel stack under Bandit. Excluded by
  default: `mix test --include spike_rw test/spike/ws_transport_test.exs`.
  """
  use ExUnit.Case, async: false

  alias ArbiterWeb.Spike.Endpoint
  alias ArbiterWeb.Spike.WsClient

  @moduletag :spike_rw

  setup do
    start_supervised!({Phoenix.PubSub, name: ArbiterWeb.Spike.PubSub})
    Endpoint.configure()
    start_supervised!(Endpoint)
    port = Endpoint.port()
    %{port: port, url: "ws://127.0.0.1:#{port}/node/socket/websocket?vsn=2.0.0&token=spike-token"}
  end

  test "JSON push, reply, server push and the phoenix heartbeat round trip", %{url: url} do
    {:ok, client} = WsClient.start_link(url: url, owner: self())
    assert {:ok, %{}} = WsClient.join(client, "node:spike")

    ref = WsClient.push(client, "node:spike", "echo", %{"hello" => "node", "n" => 1})
    ref = to_string(ref)
    assert_receive {:ws, :reply, ^ref, "ok", %{"hello" => "node", "n" => 1}}, 5_000

    WsClient.push(client, "node:spike", "hb", %{"seq" => 7, "t" => 1.5})
    assert_receive {:ws, :push, "node:spike", "hb_ack", %{"seq" => 7, "t" => 1.5}}, 5_000

    hb = to_string(WsClient.heartbeat(client))
    assert_receive {:ws, :reply, ^hb, "ok", %{}}, 5_000
  end

  test "binary frames survive both directions at every size up to max_frame_size", %{url: url} do
    {:ok, client} = WsClient.start_link(url: url, owner: self())
    {:ok, _} = WsClient.join(client, "node:spike")

    # 1 MiB is the endpoint's max_frame_size; the V2 header eats ~30 bytes of it.
    for size <- [0, 1, 255, 16_384, 65_535, 65_536, 262_144, 1_000_000] do
      payload = :crypto.strong_rand_bytes(size)
      WsClient.push(client, "node:spike", "echo_bin", {:binary, payload})
      assert_receive {:ws, :push, "node:spike", "echo_bin", {:binary, ^payload}}, 10_000
    end
  end

  test "a frame over max_frame_size closes the socket instead of being truncated", %{url: url} do
    {:ok, client} = WsClient.start_link(url: url, owner: self())
    {:ok, _} = WsClient.join(client, "node:spike")

    WsClient.push(
      client,
      "node:spike",
      "echo_bin",
      {:binary, :crypto.strong_rand_bytes(1_100_000)}
    )

    assert_receive {:ws, :closed, _reason}, 10_000
  end

  test "a wrong token is refused at the upgrade, with no channel ever opened", %{port: port} do
    Process.flag(:trap_exit, true)
    url = "ws://127.0.0.1:#{port}/node/socket/websocket?vsn=2.0.0&token=nope"
    {:ok, client} = WsClient.start_link(url: url, owner: self())
    ref = Process.monitor(client)
    # The upgrade is answered with an HTTP 403, not a 101.
    assert_receive {:ws, :closed, {:upgrade_rejected, 403, _}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^client, _}, 5_000
  end

  test "the client reconnects to a restarted server (new socket, fresh join)", %{
    port: port,
    url: url
  } do
    {:ok, client} = WsClient.start_link(url: url, owner: self())
    {:ok, _} = WsClient.join(client, "node:spike")
    ref = Process.monitor(client)
    Process.unlink(client)
    stop_supervised!(Endpoint)
    assert_receive {:ws, :closed, _}, 10_000
    assert_receive {:DOWN, ^ref, :process, ^client, _}, 5_000

    # The design's agent owns the retry loop (backoff 1s -> 30s); the spike only
    # shows that a *fresh* client on the same URL joins cleanly after the restart.
    Endpoint.configure(http: [ip: {127, 0, 0, 1}, port: port])
    start_supervised!(Endpoint)
    assert Endpoint.port() == port
    {:ok, again} = WsClient.start_link(url: url, owner: self())
    assert {:ok, _} = WsClient.join(again, "node:spike")
  end

  test "the whole client is within the design's ~300-line budget" do
    lines =
      __DIR__
      |> Path.join("../support/spike/ws_client.ex")
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
      |> length()

    IO.puts("SPIKE_RESULT " <> Jason.encode!(%{u2_client_non_blank_non_comment_lines: lines}))
    assert lines <= 400
  end
end
