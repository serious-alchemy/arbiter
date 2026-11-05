defmodule Arbiter.Nodes.Bridge.StreamTlsTest do
  @moduledoc "`Stream` half-close over `:ssl`: the write side closes with a TLS `close_notify`."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbiter.NodeAgent.PodChannel.Cert
  alias Arbiter.NodeAgent.PodChannelKit
  alias Arbiter.Nodes.Bridge.Stream

  # A relay between client and listener that reports the bytes the server sends,
  # so a close_notify (bytes after the last data) is visible as TCP payload.
  defp start_tap(port) do
    me = self()
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, tap_port}} = :inet.sockname(l)

    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(l)
      {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true])
      :inet.setopts(c, active: true)
      tap_loop(c, s, me)
    end)

    tap_port
  end

  defp tap_loop(c, s, me) do
    receive do
      {:tcp, ^c, b} ->
        :gen_tcp.send(s, b)
        tap_loop(c, s, me)

      {:tcp, ^s, b} ->
        send(me, {:tap_from_server, byte_size(b)})
        :gen_tcp.send(c, b)
        tap_loop(c, s, me)

      {:tcp_closed, ^s} ->
        :gen_tcp.close(c)

      {:tcp_closed, ^c} ->
        :gen_tcp.close(s)
    end
  end

  defp flush_tap do
    receive do
      {:tap_from_server, _} -> flush_tap()
    after
      200 -> :ok
    end
  end

  for versions <- [[:"tlsv1.3", :"tlsv1.2"], [:"tlsv1.2"]] do
    describe "versions #{inspect(versions)}" do
      @describetag versions: versions

      test "egress-first close reaches a client that does not close first as a clean close",
           ctx do
        {stream, client} = connect(ctx)
        log = capture_log([level: :debug], fn -> close_and_drain(stream, client, 0) end)

        refute log =~ "decode_error"
        refute log =~ "Decode Error"
      end

      test "half-close sends a TLS close_notify, not only a TCP FIN", ctx do
        {stream, client} = connect(ctx, tap: true)
        flush_tap()
        Stream.shutdown_write(stream)
        assert_receive {:tap_from_server, n} when n > 0, 2_000
        assert {:error, :closed} = :ssl.recv(client, 0, 2_000)
      end

      test "a large reply followed by the close is delivered in full to a slow reader", ctx do
        {stream, client} = connect(ctx)
        payload = :crypto.strong_rand_bytes(2_000_000)
        Stream.write(stream, payload)
        assert_receive {:bridge_stream, :s, {:wrote, 2_000_000}}, 5_000
        Stream.shutdown_write(stream)

        got = slow_read(client, [])
        assert got == payload
        assert {:error, :closed} = :ssl.recv(client, 0, 2_000)
      end

      test "an egress-first close does not fail the stream", ctx do
        {stream, client} = connect(ctx)
        ref = Process.monitor(stream)
        Stream.write(stream, "reply")
        Stream.shutdown_write(stream)
        assert {:ok, "reply"} = :ssl.recv(client, 5, 2_000)
        assert {:error, :closed} = :ssl.recv(client, 0, 2_000)
        :ssl.close(client)

        assert_receive {:bridge_stream, :s, :eof}, 2_000
        assert_receive {:DOWN, ^ref, :process, ^stream, :normal}, 2_000
        refute_received {:bridge_stream, :s, {:failed, _}}
      end
    end
  end

  setup %{versions: versions} do
    ca = PodChannelKit.ca()
    now = DateTime.utc_now()

    leaf =
      Cert.leaf(ca, "run", "arb", DateTime.add(now, -60), DateTime.add(now, 3600))

    server_opts =
      PodChannelKit.server_opts(PodChannelKit.server_identity(ca), ca) ++
        [versions: versions, active: false, reuseaddr: true]

    {:ok, lsock} = :ssl.listen(0, Keyword.delete(server_opts, :versions) ++ [versions: versions])
    {:ok, {_, port}} = :ssl.sockname(lsock)
    on_exit(fn -> :ssl.close(lsock) end)

    client_opts =
      PodChannelKit.client_opts_leaf(leaf, ca, versions: versions, active: false, mode: :binary)

    %{lsock: lsock, port: port, client_opts: client_opts}
  end

  defp connect(%{lsock: lsock, port: port, client_opts: client_opts}, opts \\ []) do
    port = if opts[:tap], do: start_tap(port), else: port
    me = self()

    acceptor =
      Task.async(fn ->
        {:ok, t} = :ssl.transport_accept(lsock, 5_000)
        {:ok, s} = :ssl.handshake(t, 5_000)
        {:ok, pid} = Stream.start_link(owner: me, id: :s, socket: s, transport: :ssl)
        :ok = :ssl.controlling_process(s, pid)
        Stream.go(pid)
        pid
      end)

    {:ok, client} = :ssl.connect(~c"localhost", port, client_opts, 5_000)
    {Task.await(acceptor), client}
  end

  defp close_and_drain(stream, client, _) do
    Stream.shutdown_write(stream)
    assert {:error, :closed} = :ssl.recv(client, 0, 2_000)
    :ssl.close(client)
    assert_receive {:bridge_stream, :s, :eof}, 2_000
    refute_received {:bridge_stream, :s, {:failed, _}}
  end

  defp slow_read(client, acc) do
    case :ssl.recv(client, 0, 2_000) do
      {:ok, bytes} ->
        Process.sleep(1)
        slow_read(client, [acc, bytes])

      {:error, :closed} ->
        IO.iodata_to_binary(acc)
    end
  end
end
