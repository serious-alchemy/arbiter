defmodule Arbiter.Worker.JailNetworkTest do
  @moduledoc """
  bd-cfktou (G6): the jail's network mode. `--unshare-net` leaves the namespace
  with only `lo`; `socat` bridges inside it reach the run's per-run Unix
  sockets (the G5 proxy, the Arbiter bridge, fixed tunnels), and the proxy env
  and `GIT_SSH_COMMAND` point the agent and git at them.

  The argv/wrap tests are pure. The `:bwrap` tests run the real `bwrap` and
  `socat` against stub commands and a local stand-in server (never agy, never
  the internet) and are skipped when the host cannot run them.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Jail

  @probe Jail.probe()
  @socat System.find_executable("socat")

  setup do
    uniq = "#{System.pid()}-#{System.unique_integer([:positive])}"
    # Not under /tmp: the jail mounts a private tmpfs over it.
    base = Path.join(Arbiter.Config.Paths.scratch_root(), "jail-net-test-#{uniq}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp flag_pairs(argv, flag) do
    argv
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [f | _] -> f == flag end)
    |> Enum.map(fn [_, a, b] -> {a, b} end)
  end

  @network %{
    proxy_socket: "/run/eg/r1.proxy.sock",
    proxy_port: 3128,
    bridges: [{4848, "/run/eg/r1.arb.sock"}, {5432, "/run/eg/r1.t1.sock"}],
    socat: "/usr/bin/socat"
  }

  defp spec(extra \\ %{}),
    do: Map.merge(%{bwrap: "/usr/bin/bwrap", worktree: "/w/wt", network: @network}, extra)

  describe "argv/2 with a network spec" do
    test "adds --unshare-net; a spec without one does not" do
      assert "--unshare-net" in Jail.argv(spec(), ["agy"])
      refute "--unshare-net" in Jail.argv(Map.delete(spec(), :network), ["agy"])
    end

    test "hides the egress socket dir behind a tmpfs and binds back only this run's sockets" do
      argv = Jail.argv(spec(), ["agy"])

      tmpfs =
        argv
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find_index(&(&1 == ["--tmpfs", "/run/eg"]))

      assert tmpfs

      ro = flag_pairs(argv, "--ro-bind")

      for sock <- ["/run/eg/r1.proxy.sock", "/run/eg/r1.arb.sock", "/run/eg/r1.t1.sock"] do
        assert {sock, sock} in ro
      end

      root = Enum.find_index(argv, &(&1 == "--ro-bind"))
      assert root < tmpfs
      first_sock = argv |> Enum.find_index(&(&1 == "/run/eg/r1.proxy.sock"))
      assert tmpfs < first_sock
    end

    test "starts one socat per listener ahead of the command, then execs it" do
      argv = Jail.argv(spec(), ["agy", "-p", "hi"])
      {_, ["--" | command]} = Enum.split_while(argv, &(&1 != "--"))

      assert ["sh", "-c", script, "sh", "/usr/bin/socat" | rest] = command
      assert script =~ "TCP-LISTEN"
      assert script =~ ~s(exec "$@")

      assert rest ==
               [
                 "3128",
                 "/run/eg/r1.proxy.sock",
                 "4848",
                 "/run/eg/r1.arb.sock",
                 "5432",
                 "/run/eg/r1.t1.sock",
                 "--",
                 "agy",
                 "-p",
                 "hi"
               ]
    end
  end

  describe "wrap/2 network mode" do
    setup %{base: base} do
      prev =
        for k <- [
              :worker_jail_bwrap,
              :worker_jail_ssh_config_path,
              :worker_jail_user_ssh_config_path
            ],
            do: {k, Application.get_env(:arbiter, k)}

      Application.put_env(:arbiter, :worker_jail_bwrap, "/usr/bin/bwrap-stub")

      Application.put_env(
        :arbiter,
        :worker_jail_ssh_config_path,
        Path.join(base, "no-ssh-config")
      )

      Application.put_env(
        :arbiter,
        :worker_jail_user_ssh_config_path,
        Path.join(base, "no-user-ssh-config")
      )

      on_exit(fn ->
        for {k, v} <- prev,
            do:
              if(is_nil(v),
                do: Application.delete_env(:arbiter, k),
                else: Application.put_env(:arbiter, k, v)
              )
      end)

      proxy = Path.join(base, "r1.proxy.sock")
      arb = Path.join(base, "r1.arb.sock")
      File.write!(proxy, "")
      File.write!(arb, "")

      {:ok,
       network: [
         proxy_socket: proxy,
         bridges: [{4848, arb}],
         socat: "/usr/bin/socat"
       ]}
    end

    test "sets the proxy env, keeps loopback off the proxy, and routes ssh through it", %{
      base: base,
      network: network
    } do
      assert {:ok, argv} = Jail.wrap(["git", "push"], worktree: base, network: network)
      env = Map.new(flag_pairs(argv, "--setenv"))

      for name <- ~w(HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy) do
        assert env[name] == "http://127.0.0.1:3128", name
      end

      assert env["NO_PROXY"] == "127.0.0.1,localhost,::1"
      assert env["no_proxy"] == env["NO_PROXY"]

      assert env["GIT_SSH_COMMAND"] ==
               "ssh -o 'ProxyCommand socat - PROXY:127.0.0.1:%h:%p,proxyport=3128'"
    end

    test "keeps the mirrored ssh config ahead of the ProxyCommand", %{
      base: base,
      network: network
    } do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, argv} = Jail.wrap(["git", "push"], worktree: base, network: network)
      env = Map.new(flag_pairs(argv, "--setenv"))
      assert {:ok, shadow} = Jail.ssh_shadow_config()

      assert env["GIT_SSH_COMMAND"] ==
               "ssh -F #{shadow} -o 'ProxyCommand socat - PROXY:127.0.0.1:%h:%p,proxyport=3128'"
    end

    test "an explicit :env still wins", %{base: base, network: network} do
      assert {:ok, argv} =
               Jail.wrap(["git"],
                 worktree: base,
                 network: network,
                 env: [{"GIT_SSH_COMMAND", "ssh -F /dev/null"}]
               )

      assert Map.new(flag_pairs(argv, "--setenv"))["GIT_SSH_COMMAND"] == "ssh -F /dev/null"
    end

    test "without :network nothing about the network changes", %{base: base} do
      assert {:ok, argv} = Jail.wrap(["git"], worktree: base)
      refute "--unshare-net" in argv
      refute Map.has_key?(Map.new(flag_pairs(argv, "--setenv")), "HTTPS_PROXY")
    end

    test "fails closed when the proxy socket is missing", %{base: base, network: network} do
      File.rm!(network[:proxy_socket])

      assert {:error, {:egress_socket_missing, path}} =
               Jail.wrap(["git"], worktree: base, network: network)

      assert path == network[:proxy_socket]
    end

    test "refuses two listeners on the same loopback port", %{base: base, network: network} do
      [{_, sock}] = network[:bridges]
      network = Keyword.put(network, :bridges, [{3128, sock}])

      assert {:error, {:duplicate_bridge_port, [3128]}} =
               Jail.wrap(["git"], worktree: base, network: network)
    end

    test "fails closed when socat is not installed", %{base: base, network: network} do
      network = Keyword.put(network, :socat, nil)
      prev = System.get_env("PATH")
      System.put_env("PATH", base)
      on_exit(fn -> System.put_env("PATH", prev) end)

      assert {:error, :socat_not_found} = Jail.wrap(["git"], worktree: base, network: network)
    end
  end

  describe "real bwrap with a stand-in egress run" do
    if @probe != :ok or is_nil(@socat) do
      @describetag skip: "bwrap jail or socat unavailable on this host: #{inspect(@probe)}"
    end

    @describetag :bwrap

    setup %{base: base} do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      server = spawn_link(fn -> echo_accept(listen) end)
      on_exit(fn -> :gen_tcp.close(listen) end)

      run_id = "jn#{System.unique_integer([:positive])}"
      dir = Path.join(base, "eg")

      {:ok, proxy} =
        Egress.start_run(run_id,
          dir: dir,
          owner: server,
          allow_local_dial: true,
          baseline: ["127.0.0.1:#{port}"],
          bridges: [arb: {"127.0.0.1", port}, t1: {"127.0.0.1", port}]
        )

      on_exit(fn -> Egress.stop_run(run_id) end)

      wt = Path.join(base, "wt")
      File.mkdir_p!(wt)

      network = [
        proxy_socket: proxy,
        bridges: [
          {4848, Egress.bridge_path(run_id, :arb, dir)},
          {5432, Egress.bridge_path(run_id, :t1, dir)}
        ]
      ]

      {:ok, port: port, wt: wt, network: network, dir: dir, run_id: run_id}
    end

    defp echo_accept(listen) do
      case :gen_tcp.accept(listen) do
        {:ok, sock} ->
          pid =
            spawn(fn ->
              receive do
                :go -> echo(sock)
              end
            end)

          :gen_tcp.controlling_process(sock, pid)
          send(pid, :go)
          echo_accept(listen)

        _ ->
          :ok
      end
    end

    defp echo(sock) do
      case :gen_tcp.recv(sock, 0) do
        {:ok, data} ->
          :gen_tcp.send(sock, data)
          echo(sock)

        _ ->
          :gen_tcp.close(sock)
      end
    end

    defp run_in_jail(wt, network, script, env \\ []) do
      {:ok, [exec | args]} =
        Jail.wrap(["sh", "-c", script], worktree: wt, network: network, env: env)

      System.cmd(exec, args, stderr_to_stdout: true)
    end

    test "the namespace has only lo and no route", %{wt: wt, network: network} do
      script = ~S"""
      awk -F'[: ]+' 'NR>2 {print "IF:" $2}' /proc/net/dev
      echo "ROUTES:$(awk 'NR>1' /proc/net/route | wc -l)"
      """

      {out, 0} = run_in_jail(wt, network, script)
      assert out =~ "IF:lo"
      assert String.split(out, "\n") |> Enum.filter(&String.starts_with?(&1, "IF:")) == ["IF:lo"]
      assert out =~ "ROUTES:0"
    end

    test "the Arbiter bridge and a tunnel answer on loopback ports; the proxy admits an allowed host, refuses a public-upload host",
         %{wt: wt, network: network, port: port} do
      script = ~s"""
      printf 'via-arb' | socat -d -d -t2 - TCP:127.0.0.1:4848
      echo
      printf 'via-tunnel' | socat -t1 - TCP:127.0.0.1:5432
      echo
      printf 'via-proxy' | socat -t1 - PROXY:127.0.0.1:127.0.0.1:#{port},proxyport=3128
      echo
      socat -t1 - PROXY:127.0.0.1:catbox.moe:443,proxyport=3128 </dev/null 2>&1
      echo "DENIED:$?"
      """

      {out, 0} = run_in_jail(wt, network, script)
      assert out =~ "via-arb"
      assert out =~ "via-tunnel"
      assert out =~ "via-proxy"
      assert out =~ "Forbidden"
      refute out =~ "DENIED:0"
    end

    test "nothing outside the bridges is reachable: a direct connect to the host's loopback fails",
         %{wt: wt, network: network, port: port} do
      script = ~s"""
      socat -t1 - TCP:127.0.0.1:#{port},connect-timeout=2 </dev/null 2>&1
      echo "DIRECT:$?"
      """

      {out, 0} = run_in_jail(wt, network, script)
      refute out =~ "DIRECT:0"
    end

    test "sockets of other runs in the same dir are not visible", %{
      wt: wt,
      network: network,
      dir: dir,
      run_id: run_id
    } do
      other = run_id <> "x"
      {:ok, _} = Egress.start_run(other, dir: dir)
      on_exit(fn -> Egress.stop_run(other) end)

      script = ~s(ls #{dir} | sort)
      {out, 0} = run_in_jail(wt, network, script)
      refute out =~ other
      assert out =~ "#{run_id}.proxy.sock"
    end

    test "a bridge that cannot start fails the spawn instead of running without it", %{
      wt: wt,
      network: network
    } do
      # A privileged port: the namespace's uid has no CAP_NET_BIND_SERVICE
      # once bwrap drops capabilities, so socat cannot bind it.
      bad = Keyword.put(network, :bridges, [{81, hd(network[:bridges]) |> elem(1)}])
      {out, status} = run_in_jail(wt, bad, "echo RAN")
      assert status != 0
      refute out =~ "RAN"
      assert out =~ "arbiter jail:"
    end
  end
end
