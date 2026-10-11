defmodule Arbiter.Agents.Qwen.JailTest do
  # async: false — PATH and the jail / home Application env are global.
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Agents.Qwen
  alias Arbiter.Agents.Qwen.ConfigDir
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Test.ScriptedOpenAI

  @moduletag :capture_log

  # The jail's availability is pinned through `:worker_jail_available`: the
  # `bwrap` and `socat` on PATH are stubs that are never run, so this covers the
  # argv and the host-side egress run on any machine. What bwrap itself does
  # with the argv is `jail_bwrap_test.exs` (tagged :bwrap).
  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "qwen-jail-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(base, "bin")
    worktree = Path.join(base, "wt")
    File.mkdir_p!(bin)
    File.mkdir_p!(worktree)

    for name <- ~w(qwen bwrap socat) do
      File.write!(Path.join(bin, name), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, name), 0o755)
    end

    keys =
      ~w(worker_qwen_home_root worker_jail_available worker_jail_bwrap
         worker_jail_network_available worker_jail_network worker_qwen_egress_enforce)a

    prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})
    old_path = System.get_env("PATH")

    Application.put_env(:arbiter, :worker_qwen_home_root, Path.join(base, "homes"))
    Application.put_env(:arbiter, :worker_jail_available, true)
    Application.put_env(:arbiter, :worker_jail_network_available, true)
    Application.delete_env(:arbiter, :worker_jail_network)
    Application.delete_env(:arbiter, :worker_qwen_egress_enforce)
    Application.put_env(:arbiter, :worker_jail_bwrap, Path.join(bin, "bwrap"))
    System.put_env("PATH", bin)

    on_exit(fn ->
      System.put_env("PATH", old_path)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:arbiter, k)
        {k, v} -> Application.put_env(:arbiter, k, v)
      end)

      File.rm_rf!(base)
    end)

    {:ok, base: base, worktree: worktree, bwrap: Path.join(bin, "bwrap")}
  end

  defp policy(mode \\ :bypass, extra \\ %{}) do
    SecurityPolicy.merge(SecurityPolicy.base(), Map.merge(%{permissions: %{mode: mode}}, extra))
  end

  defp review_policy do
    SecurityPolicy.merge(SecurityPolicy.base(), %{
      permissions: %{mode: :bypass, deny: ["Edit", "Write", "NotebookEdit"]}
    })
  end

  defp argv!(opts) do
    opts = opts |> Keyword.put_new(:owner, self()) |> Keyword.put_new(:security, policy())
    assert {:ok, argv} = Qwen.default_argv("do the thing", opts)
    argv
  end

  # sh -c <script> sh <bwrap ...jail...> -- [network wrapper] qwen ...
  defp split_jail(argv) do
    assert ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | rest] = argv
    {jail, ["--" | command]} = Enum.split_while(rest, &(&1 != "--"))

    case command do
      ["sh", "-c", _script, "sh", _socat | listeners] ->
        {listeners, ["--" | real]} = Enum.split_while(listeners, &(&1 != "--"))
        {jail, listeners, real}

      _ ->
        {jail, [], command}
    end
  end

  defp pairs(argv, flag) do
    argv
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [f | _] -> f == flag end)
    |> Enum.map(fn [_, a, b] -> {a, b} end)
  end

  describe "capabilities" do
    test "a jail-capable host reports security enforced and an OS jail with network confinement" do
      assert Qwen.security_enforced?()
      assert Qwen.write_confinement(policy(:strict)) == :os_jail
      assert Qwen.write_confinement(policy(:bypass)) == :os_jail
      assert Qwen.egress_confinement(policy()) == :os_jail
      assert Qwen.write_jail_warning(policy()) == nil
    end

    test "without a usable jail the confinement is :none and the warning says what to fix" do
      Application.put_env(:arbiter, :worker_jail_available, false)

      assert Qwen.write_confinement(policy()) == :none
      assert Qwen.egress_confinement(policy()) == :none
      assert Qwen.write_jail_warning(policy(:strict)) =~ ":strict dispatches of qwen are refused"
      assert Qwen.write_jail_warning(policy(:bypass)) =~ "not confined to the worktree"
    end

    test "a policy that turned the sandbox off on purpose gets no warning and no jail" do
      off = policy(:bypass, %{sandbox: %{enabled: false}})
      assert Qwen.write_confinement(off) == :none
      assert Qwen.write_jail_warning(off) == nil
    end

    test "network mode off keeps the filesystem jail but reports no egress confinement" do
      Application.put_env(:arbiter, :worker_jail_network_available, false)
      assert Qwen.write_confinement(policy()) == :os_jail
      assert Qwen.egress_confinement(policy()) == :none
    end
  end

  describe "the jailed argv" do
    test "wraps qwen in bwrap with the worktree and the per-worker home writable", %{
      worktree: wt,
      bwrap: bwrap
    } do
      {jail, _listeners, command} = split_jail(argv!(worktree: wt))
      home = ConfigDir.path(worktree: wt)

      assert [^bwrap, "--ro-bind", "/", "/" | _] = jail
      assert {wt, wt} in pairs(jail, "--bind")
      assert {home, home} in pairs(jail, "--bind")
      assert "--unshare-net" in jail
      assert [qwen, "-p", "do the thing" | flags] = command
      assert Path.basename(qwen) == "qwen"
      assert "--yolo" in flags
    end

    test "the system settings dir is bound read-only over the writable home", %{worktree: wt} do
      {jail, _, _} = split_jail(argv!(worktree: wt))
      dir = ConfigDir.system_settings_dir(worktree: wt)

      assert {dir, dir} in pairs(jail, "--ro-bind-try")
      home = ConfigDir.path(worktree: wt)
      assert Enum.find_index(jail, &(&1 == dir)) > Enum.find_index(jail, &(&1 == home))
    end

    test "QWEN_HOME and the settings path are fixed inside the jail too", %{worktree: wt} do
      {jail, _, _} = split_jail(argv!(worktree: wt))
      setenv = pairs(jail, "--setenv") |> Map.new()

      assert setenv["QWEN_HOME"] == ConfigDir.qwen_home(worktree: wt)

      assert setenv["QWEN_CODE_SYSTEM_SETTINGS_PATH"] ==
               ConfigDir.system_settings_path(worktree: wt)
    end

    test "an implementer's worktree is writable, a reviewer's is read-only", %{worktree: wt} do
      {impl, _, _} = split_jail(argv!(worktree: wt))
      assert {wt, wt} in pairs(impl, "--bind")
      refute {wt, wt} in pairs(impl, "--ro-bind")

      {review, _, _} = split_jail(argv!(worktree: wt, security: review_policy()))
      assert {wt, wt} in pairs(review, "--ro-bind")
      refute {wt, wt} in pairs(review, "--bind")
      # ... while its own home stays writable for qwen's session files
      home = ConfigDir.path(worktree: wt)
      assert {home, home} in pairs(review, "--bind")
    end

    test "a reviewer's write tools are removed in the read-only system settings", %{worktree: wt} do
      argv!(worktree: wt, security: review_policy())

      settings =
        [worktree: wt] |> ConfigDir.system_settings_path() |> File.read!() |> Jason.decode!()

      assert Enum.sort(settings["tools"]["exclude"]) == ["edit", "write_file"]
    end

    test "the deny rules are written for every spawn, whatever the jail does", %{worktree: wt} do
      argv!(worktree: wt)

      settings =
        [worktree: wt] |> ConfigDir.system_settings_path() |> File.read!() |> Jason.decode!()

      deny = settings["permissions"]["deny"]
      assert "Bash(gh pr create *)" in deny
      assert "Read(~/.ssh/**)" in deny
    end

    test "a large prompt still goes through stdin, outside the jail", %{worktree: wt} do
      big = String.duplicate("x", 140_000)

      assert {:ok, argv} =
               Qwen.default_argv(big, owner: self(), security: policy(), worktree: wt)

      assert ["sh", "-c", _script, "sh", file, bwrap | _] = argv
      assert Qwen.prompt_tmpfile(argv) == file
      assert Path.basename(bwrap) == "bwrap"
      File.rm(file)
    end

    test "a :strict spawn with no worktree to jail is refused" do
      assert {:error, {:write_jail_unavailable, :no_worktree}} =
               Qwen.default_argv("p", owner: self(), security: policy(:strict))
    end
  end

  describe "jail availability" do
    setup do
      Application.put_env(:arbiter, :worker_jail_available, false)
    end

    test ":strict fails closed", %{worktree: wt} do
      assert {:error, {:write_jail_unavailable, _}} =
               Qwen.default_argv("p", owner: self(), security: policy(:strict), worktree: wt)
    end

    test "other modes run unjailed, with the HOME isolation still in force", %{worktree: wt} do
      for mode <- [:bypass, :auto] do
        assert {:ok, ["sh", "-c", _, "sh", qwen, "-p", "p" | _]} =
                 Qwen.default_argv("p", owner: self(), security: policy(mode), worktree: wt)

        assert Path.basename(qwen) == "qwen"
      end

      env = Qwen.spawn_env(worktree: wt)
      assert {"HOME", ConfigDir.path(worktree: wt)} in env
    end

    test "a backend with no implementation is refused in every mode", %{worktree: wt} do
      for mode <- [:bypass, :strict] do
        p = policy(mode, %{sandbox: %{backend: :podman}})
        assert {:error, _} = Qwen.default_argv("p", owner: self(), security: p, worktree: wt)
      end
    end
  end

  describe "egress tunnels for a local endpoint" do
    setup do
      server = ScriptedOpenAI.start_supervised!([{:text, "pong"}])
      {:ok, server: server}
    end

    test "the endpoint's port is a fixed-destination bridge, listening on the same port inside",
         %{worktree: wt, server: server} do
      {_jail, listeners, _command} =
        split_jail(argv!(worktree: wt, endpoint: %{base_url: server.url, api_key: "k"}))

      port = Integer.to_string(server.port)
      # proxy, arb, then the endpoint tunnel: <local port> <host-side socket>
      assert ["3128", _proxy, _arb_port, _arb_sock, ^port, sock | _] = listeners
      assert sock =~ ".t1.sock"
    end

    test "a request through the bridge reaches the OpenAI-compatible endpoint on the host",
         %{worktree: wt, server: server} do
      {_jail, listeners, _command} =
        split_jail(argv!(worktree: wt, endpoint: %{base_url: server.url, api_key: "k"}))

      port = Integer.to_string(server.port)
      assert [_, _, _, _, ^port, sock | _] = listeners

      body = Jason.encode!(%{"model" => "m", "messages" => []})

      {:ok, client} =
        :gen_tcp.connect({:local, String.to_charlist(sock)}, 0, [:binary, active: false], 2_000)

      :ok =
        :gen_tcp.send(
          client,
          "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\n" <>
            "Content-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n" <>
            "Connection: close\r\n\r\n" <> body
        )

      response = recv_all(client, "")
      :gen_tcp.close(client)

      assert response =~ "HTTP/1.1 200"
      assert response =~ "pong"
      assert [%{path: "/v1/chat/completions"}] = ScriptedOpenAI.requests(server)
    end

    test "another host port is not bridged: only the endpoint's is", %{
      worktree: wt,
      server: server
    } do
      {_jail, listeners, _command} =
        split_jail(argv!(worktree: wt, endpoint: %{base_url: server.url, api_key: "k"}))

      ports = listeners |> Enum.drop(4) |> Enum.take_every(2)
      assert ports == [Integer.to_string(server.port)]
    end
  end

  describe "everything else is denied and recorded" do
    setup %{worktree: wt} do
      server = ScriptedOpenAI.start_supervised!([])
      argv = argv!(worktree: wt, task_id: "bd-qwen-egress", endpoint: %{base_url: server.url})
      {jail, _, _} = split_jail(argv)
      sock = Enum.find(jail, &String.ends_with?(&1, ".proxy.sock"))
      {:ok, sock: sock, run_id: Path.basename(sock, ".proxy.sock")}
    end

    test "a CONNECT to a host outside the baseline is refused with 403", %{sock: sock} do
      response = connect(sock, "example.org:443")
      assert response =~ "HTTP/1.1 403"
      assert response =~ "X-Arbiter-Egress: not_granted"
    end

    test "the paste hosts stay denied", %{sock: sock} do
      assert connect(sock, "catbox.moe:443") =~ "HTTP/1.1 403"
    end

    test "the denial is an egress event for the task, and the stream classifies as :egress_denied",
         %{sock: sock, run_id: run_id} do
      response = connect(sock, "example.org:443")

      assert [%{task_id: "bd-qwen-egress", host: "example.org", decision: :deny}] =
               Arbiter.Worker.Egress.Event
               |> Ash.Query.filter(run_id == ^run_id)
               |> Ash.read!()

      # What qwen prints for that 403, then the exit: the stop reason names it.
      lines = ["qwen error: Proxy response (403) !== 200 when HTTP Tunneling", response]
      assert %{category: :egress_denied} = Arbiter.Worker.StopReason.classify(1, lines, "qwen")
    end

    test "the control: with enforcement switched off the same CONNECT is dialled, not refused",
         %{worktree: wt} do
      Application.put_env(:arbiter, :worker_qwen_egress_enforce, false)
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {jail, _, _} = split_jail(argv!(worktree: wt, owner: owner))
      sock = Enum.find(jail, &String.ends_with?(&1, ".proxy.sock"))

      # `.invalid` never resolves, so learn mode answers 502 for the failed dial.
      refute connect(sock, "denied.invalid:443") =~ "HTTP/1.1 403"
    end
  end

  describe "egress failure modes" do
    test "a jailed spawn with no owner is refused rather than bound to the caller", %{
      worktree: wt
    } do
      assert {:error, {:egress_unavailable, :no_owner}} =
               Qwen.default_argv("p", security: policy(), worktree: wt)
    end

    test "a host without network mode still gets the filesystem jail, on the shared network",
         %{worktree: wt, bwrap: bwrap} do
      Application.put_env(:arbiter, :worker_jail_network_available, false)

      assert ["sh", "-c", _, "sh", ^bwrap, "--ro-bind", "/", "/" | rest] =
               argv!(worktree: wt)

      refute "--unshare-net" in rest
    end

    test "a hosted endpoint adds no tunnel", %{worktree: wt} do
      {_jail, listeners, _command} =
        split_jail(argv!(worktree: wt, endpoint: %{base_url: "https://api.example.com/v1"}))

      # only the proxy and the Arbiter endpoint
      assert length(listeners) == 4
    end
  end

  defp connect(sock, target) do
    {:ok, client} =
      :gen_tcp.connect({:local, String.to_charlist(sock)}, 0, [:binary, active: false], 2_000)

    :ok = :gen_tcp.send(client, "CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(client, 0, 2_000)
    :gen_tcp.close(client)
    response
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, _} -> acc
    end
  end
end
