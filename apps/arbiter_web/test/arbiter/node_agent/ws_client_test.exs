defmodule Arbiter.NodeAgent.WsClientTest do
  @moduledoc """
  The agent's Phoenix V2 WebSocket client against a real Phoenix endpoint under
  Bandit on a real loopback port (docs/design/remote-workers.md U2).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.NodeAgent.WsClient
  alias ArbiterWeb.FakeNode

  @token "arbn_fake.secret"

  setup do
    Application.put_env(:arbiter_web, :fake_node_token, @token)
    Application.put_env(:arbiter_web, :fake_node_test_pid, self())
    Application.put_env(:arbiter_web, :fake_node_hello_ok, %{"hb_interval" => 10})
    Application.delete_env(:arbiter_web, :fake_node_style)
    Application.delete_env(:arbiter_web, :fake_node_ack?)

    on_exit(fn ->
      for key <-
            ~w(fake_node_token fake_node_test_pid fake_node_hello_ok fake_node_style fake_node_ack?)a,
          do: Application.delete_env(:arbiter_web, key)
    end)

    start_supervised!({Phoenix.PubSub, name: ArbiterWeb.FakeNode.PubSub})
    start_supervised!(FakeNode.endpoint_spec())
    %{port: FakeNode.port()}
  end

  defp url(port, token \\ @token),
    do: "ws://127.0.0.1:#{port}/node/socket/websocket?vsn=2.0.0&token=#{token}&proto=1"

  test "connects, joins, pushes and gets the reply, and the owner is told about each", %{
    port: port
  } do
    {:ok, client} = WsClient.start(url: url(port), owner: self())
    assert_receive {:ws, ^client, :open}, 5_000

    join = WsClient.join(client, "node:fake", %{})
    assert_receive {:ws, ^client, :reply, ^join, "ok", %{}}, 5_000
    assert_receive {:fake_node, :joined, "node:fake"}

    ref = WsClient.push(client, "node:fake", "hello", %{"agent_version" => "9.9.9"})
    assert_receive {:ws, ^client, :reply, ^ref, "ok", %{"hb_interval" => 10}}, 5_000
    assert_receive {:fake_node, :hello, %{"agent_version" => "9.9.9"}}
  end

  test "a server push reaches the owner", %{port: port} do
    Application.put_env(:arbiter_web, :fake_node_style, :push)
    {:ok, client} = WsClient.start(url: url(port), owner: self())
    join = WsClient.join(client, "node:fake", %{})
    assert_receive {:ws, ^client, :reply, ^join, "ok", _}, 5_000

    WsClient.push(client, "node:fake", "hello", %{})
    assert_receive {:ws, ^client, :push, "node:fake", "hello_ok", %{"hb_interval" => 10}}, 5_000
  end

  test "calls made before the upgrade finishes are replayed in order", %{port: port} do
    {:ok, client} = WsClient.start(url: url(port), owner: self())
    join = WsClient.join(client, "node:fake", %{})
    ref = WsClient.push(client, "node:fake", "hello", %{})

    assert_receive {:ws, ^client, :reply, ^join, "ok", _}, 5_000
    assert_receive {:ws, ^client, :reply, ^ref, "ok", _}, 5_000
  end

  test "a wrong credential is refused at the upgrade and the owner is told", %{port: port} do
    {:ok, client} = WsClient.start(url: url(port, "arbn_fake.wrong"), owner: self())
    assert_receive {:ws, ^client, :closed, {:upgrade_rejected, 403, _}}, 5_000
  end

  test "nothing listening is an error from start/1, not a crash" do
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, closed_port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert {:error, _reason} = WsClient.start(url: url(closed_port), owner: self())
  end

  test "the server going away is reported as :closed", %{port: port} do
    {:ok, client} = WsClient.start(url: url(port), owner: self())
    join = WsClient.join(client, "node:fake", %{})
    assert_receive {:ws, ^client, :reply, ^join, "ok", _}, 5_000

    FakeNode.Endpoint.broadcast("node_socket:fake", "disconnect", %{})
    assert_receive {:ws, ^client, :closed, _reason}, 5_000
  end

  test "the client stops when its owner dies", %{port: port} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, client} = WsClient.start(url: url(port), owner: owner)
    ref = Process.monitor(client)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^client, _}, 5_000
  end

  test "phoenix-level heartbeats keep an otherwise idle socket open", %{port: port} do
    {:ok, client} = WsClient.start(url: url(port), owner: self(), phoenix_heartbeat_ms: 20)
    join = WsClient.join(client, "node:fake", %{})
    assert_receive {:ws, ^client, :reply, ^join, "ok", _}, 5_000

    # many heartbeat intervals pass; the client does not report them to the owner
    # and does not time out because every one is answered
    refute_receive {:ws, ^client, :closed, _}, 300
    refute_receive {:ws, ^client, :reply, _, _, _}, 10
  end

  describe "through an HTTP proxy" do
    test "connects through the proxy and a quiet heartbeat socket stays alive", %{port: port} do
      proxy_port = start_proxy(self())

      {:ok, client} =
        WsClient.start(
          url: url(port),
          owner: self(),
          proxy: {:http, "127.0.0.1", proxy_port, []},
          phoenix_heartbeat_ms: 20
        )

      assert_receive {:proxy_request, "GET http://127.0.0.1:" <> _}, 5_000
      assert_receive {:ws, ^client, :open}, 5_000
      join = WsClient.join(client, "node:fake", %{})
      assert_receive {:ws, ^client, :reply, ^join, "ok", _}, 5_000

      refute_receive {:ws, ^client, :closed, _}, 300
    end

    test "a proxy URL string is accepted", %{port: port} do
      proxy_port = start_proxy(self())

      {:ok, client} =
        WsClient.start(url: url(port), owner: self(), proxy: "http://127.0.0.1:#{proxy_port}")

      assert_receive {:proxy_request, "GET http://127.0.0.1:" <> _}, 5_000
      assert_receive {:ws, ^client, :open}, 5_000
    end

    test "a proxy nothing listens on is an error from start/1", %{port: port} do
      {:ok, listener} = :gen_tcp.listen(0, [])
      {:ok, dead} = :inet.port(listener)
      :gen_tcp.close(listener)

      assert {:error, _} =
               WsClient.start(
                 url: url(port),
                 owner: self(),
                 proxy: {:http, "127.0.0.1", dead, []}
               )
    end

    test "a malformed proxy is refused" do
      assert {:error, {:bad_proxy, _}} =
               WsClient.start(url: url(1), owner: self(), proxy: "socks5://127.0.0.1:1")
    end
  end

  describe "plain ws:// to a non-loopback host" do
    test "is refused, with or without a proxy" do
      assert {:error, {:insecure_url, _}} =
               WsClient.start(url: "ws://example.com/node/socket/websocket", owner: self())

      assert {:error, {:insecure_url, _}} =
               WsClient.start(
                 url: "ws://10.1.2.3/node/socket/websocket",
                 owner: self(),
                 proxy: {:http, "127.0.0.1", 1055, []}
               )
    end
  end

  # A minimal CONNECT proxy on loopback: reports the CONNECT line, then pipes bytes.
  defp start_proxy(test_pid) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, _} = Task.start_link(fn -> accept_loop(listen, test_pid) end)
    on_exit(fn -> :gen_tcp.close(listen) end)
    port
  end

  defp accept_loop(listen, test_pid) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        {:ok, pid} = Task.start(fn -> serve(sock, test_pid) end)
        _ = :gen_tcp.controlling_process(sock, pid)
        accept_loop(listen, test_pid)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, test_pid) do
    {:ok, head} = read_head(sock, "")
    [line | rest] = String.split(head, "\r\n")
    send(test_pid, {:proxy_request, line})
    opts = [:binary, active: false]

    up =
      case String.split(line, " ") do
        # a tunnel (what `wss://` through tailscale's proxy uses)
        ["CONNECT", target, _] ->
          [host, port] = String.split(target, ":")
          {:ok, up} = :gen_tcp.connect(String.to_charlist(host), String.to_integer(port), opts)
          :ok = :gen_tcp.send(sock, "HTTP/1.1 200 Connection established\r\n\r\n")
          up

        # Mint forwards plain-http targets (loopback `ws://`) instead of tunnelling
        [method, "http://" <> _ = absolute, version] ->
          %URI{host: host, port: port, path: path, query: query} = URI.parse(absolute)
          {:ok, up} = :gen_tcp.connect(String.to_charlist(host), port, opts)
          origin = "#{method} #{path}?#{query} #{version}"
          :ok = :gen_tcp.send(up, Enum.join([origin | rest], "\r\n"))
          up
      end

    :ok = :inet.setopts(sock, active: true)
    :ok = :inet.setopts(up, active: true)
    pipe(sock, up)
  end

  defp read_head(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, more} <- :gen_tcp.recv(sock, 0, 5_000), do: read_head(sock, acc <> more)
    end
  end

  defp pipe(a, b) do
    receive do
      {:tcp, ^a, data} ->
        _ = :gen_tcp.send(b, data)
        pipe(a, b)

      {:tcp, ^b, data} ->
        _ = :gen_tcp.send(a, data)
        pipe(a, b)

      _closed ->
        :ok
    end
  end
end
