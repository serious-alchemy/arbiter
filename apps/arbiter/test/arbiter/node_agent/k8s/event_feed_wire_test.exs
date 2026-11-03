defmodule Arbiter.NodeAgent.K8s.EventFeedWireTest do
  @moduledoc """
  bd-db8ez4: the event feed over the real seam. The real entry wrapper
  (`PodScripts.entry/0`) runs a command under `sh`, its real `curl` ships the NDJSON file
  over mutual TLS to the real `PodServer` (`POST /events`), which hands it to a
  `LogFollower` in event mode; the frames that reach the run's sink are compared with the
  command's own output. No stand-in for curl, TLS or the plug.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.K8s.LogFollower
  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.NodeAgent.PodChannel.{PodServer, Runs}
  alias Arbiter.NodeAgent.PodChannelKit, as: Kit
  alias Arbiter.Nodes.{RunStreams, StdoutFrame}

  @loopback {127, 0, 0, 1}

  setup %{tmp_dir: dir} do
    ca = Kit.ca()
    runs = start_supervised!({Runs, ca: ca, name: nil})
    feeds = start_supervised!({Agent, fn -> %{} end}, id: :feeds)
    config = %Config{primary_url: "http://127.0.0.1:1", credential: "x", req_options: []}

    server =
      start_supervised!(
        {PodServer,
         identity: Kit.server_identity(ca),
         ca: ca,
         runs: runs,
         config: config,
         ip: @loopback,
         port: 0,
         notify: self(),
         events: fn run -> Agent.get(feeds, &Map.fetch(&1, run)) end}
      )

    %{files: files} = Kit.boot!(runs, Kit.spec!("run-1"), @loopback)

    run_dir = Path.join(dir, "run")
    File.mkdir_p!(Path.join(run_dir, "tls"))
    File.write!(Path.join(run_dir, "tls/control.crt"), files["tls/control.crt"])
    File.write!(Path.join(run_dir, "tls/control.key"), files["tls/control.key"])
    File.write!(Path.join(dir, "ca.crt"), pem(ca.der))

    env_file = Path.join(dir, "env")
    File.write!(env_file, "")
    script = Path.join(dir, "entry.sh")
    File.write!(script, String.replace(PodScripts.entry(), PodScripts.env_file(), env_file))

    me = self()

    {:ok, follower} =
      LogFollower.start(
        run: "run-1",
        pod: "pod",
        source: :events,
        client: nil,
        owner: me,
        window_bytes: 1_000_000,
        emit: fn f -> send(me, {:frame, f}) end
      )

    Agent.update(feeds, &Map.put(&1, "run-1", follower))
    on_exit(fn -> if Process.alive?(follower), do: LogFollower.stop(follower) end)

    %{port: PodServer.port(server), run_dir: run_dir, script: script, follower: follower}
  end

  defp pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  defp wrapper(ctx, argv, extra \\ []) do
    env =
      [
        {"ARB_EVENTS", "1"},
        {"ARB_EVENTS_DIR", Path.join(ctx.tmp_dir, "ev")},
        {"ARB_RUN_DIR", ctx.run_dir},
        {"ARB_CA_FILE", Path.join(ctx.tmp_dir, "ca.crt")},
        {"ARB_EVENTS_URL", "https://127.0.0.1:#{ctx.port}/events"}
      ] ++ extra

    System.cmd("sh", [ctx.script | argv], env: env, stderr_to_stdout: true)
  end

  # What the controller does when the worker has ended: tell the follower, wait for the drain.
  defp drained_frames(ctx) do
    LogFollower.finish(ctx.follower)
    assert_receive {:log_drained, "run-1", _}, 10_000
    frames()
  end

  defp drained_text(ctx), do: ctx |> drained_frames() |> Enum.map_join(&payload/1)

  defp frames(acc \\ []) do
    receive do
      {:frame, f} -> frames([f | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp payload(frame) do
    {:ok, "run-1", {:cursor, _}, bytes} = Arbiter.Nodes.StdoutFrame.decode(frame)
    bytes
  end

  test "the wrapper curl delivers the whole stream, done signal included", ctx do
    {out, 0} =
      wrapper(ctx, ["sh", "-c", ~S/echo one; echo two >&2; echo '{"type":"result"}'; echo done/])

    assert out == "one\ntwo\n{\"type\":\"result\"}\ndone\n"
    assert drained_text(ctx) == out
  end

  test "the primary stream takes every line of the run, the done signal last", ctx do
    {out, 0} =
      wrapper(ctx, [
        "sh",
        "-c",
        ~S/echo '{"type":"system"}'; echo '{"type":"result"}'; echo 'arb done'/
      ])

    table = RunStreams.open(%RunStreams{}, "run-1", :handle, self(), nil)

    {_table, effects} =
      Enum.reduce(drained_frames(ctx), {table, []}, fn frame, {table, seen} ->
        {:ok, "run-1", {:cursor, cursor}, bytes} = StdoutFrame.decode(frame)
        {table, effects} = RunStreams.data_cursor(table, "run-1", cursor, bytes)
        {table, seen ++ effects}
      end)

    lines = for {:send, _owner, {:handle, {:data, {:eol, line}}}} <- effects, do: line

    assert lines == String.split(String.trim(out), "\n")
    assert List.last(lines) == "arb done"
  end

  test "a large multi chunk stream of long lines arrives whole", ctx do
    script = ~S/i=0; while [ $i -lt 400 ]; do printf '%01500d\n' $i; i=$((i+1)); done; echo done/
    {out, 0} = wrapper(ctx, ["sh", "-c", script], [{"ARB_EVENTS_CHUNK", "100000"}])

    assert byte_size(out) > 600_000
    got = drained_text(ctx)
    assert got == out
  end

  # The worker's environment carries the agent's egress proxy (`Jail.network_env/1`:
  # HTTPS_PROXY=http://127.0.0.1:<port>, NO_PROXY=loopback) and the wrapper sources it. The
  # controller's address is not loopback, so a curl that honours the proxy sends its CONNECT
  # to the egress proxy, which is not the pod channel and refuses it: every chunk fails and
  # the primary sees no output. The feed must bypass the proxy.
  test "the feed bypasses the agent proxy environment", ctx do
    {:ok, proxy} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, proxy_port} = :inet.port(proxy)
    me = self()

    acceptor =
      spawn_link(fn ->
        for _ <- Stream.cycle([:accept]) do
          {:ok, sock} = :gen_tcp.accept(proxy)
          send(me, {:proxied, :gen_tcp.recv(sock, 0, 1_000)})
          :gen_tcp.close(sock)
        end
      end)

    url = "http://127.0.0.1:#{proxy_port}"

    proxy_env =
      for name <- ~w(HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy),
          do: {name, url}

    {out, 0} =
      wrapper(
        ctx,
        ["sh", "-c", "echo one; echo done"],
        proxy_env ++
          [
            {"NO_PROXY", "localhost,::1"},
            {"no_proxy", "localhost,::1"},
            {"ARB_EVENTS_FINAL_TRIES", "3"}
          ]
      )

    Process.unlink(acceptor)
    Process.exit(acceptor, :kill)
    :gen_tcp.close(proxy)

    assert out == "one\ndone\n"
    refute_received {:proxied, _}
    assert drained_text(ctx) == out
  end
end
