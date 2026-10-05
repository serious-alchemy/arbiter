defmodule Arbiter.Agents.GeminiTest do
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Agents.Gemini
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.Jail

  # A jailed spawn needs the worker pid its egress run is bound to (bd-cfktou);
  # the test process stands in for it unless a test names another.
  defp default_argv(prompt, opts),
    do: Gemini.default_argv(prompt, Keyword.put_new(opts, :owner, self()))

  describe "behaviour" do
    test "module declares the Agent behaviour" do
      behaviours =
        Gemini.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
    end

    test "provider/0 returns \"gemini\"" do
      assert Gemini.provider() == "gemini"
    end

    test "done_sentinel/0 matches `arb done`" do
      assert Regex.match?(Gemini.done_sentinel(), "work finished\narb done")
      refute Regex.match?(Gemini.done_sentinel(), "I am done — arb done")
      refute Regex.match?(Gemini.done_sentinel(), "arb doneness")
    end
  end

  # bd-5gvqgc: agy under :strict runs inside the bwrap write jail on a host
  # that passes `Arbiter.Worker.Jail`'s probe. Everything here pins the jail's
  # availability through `:worker_jail_available` and never execs bwrap or agy
  # (the stubs on PATH are never run).
  describe "the :strict write jail (bd-5gvqgc)" do
    setup do
      base =
        Path.join(
          System.tmp_dir!(),
          "gemini-jail-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      bin = Path.join(base, "bin")
      worktree = Path.join(base, "wt")
      File.mkdir_p!(bin)
      File.mkdir_p!(worktree)

      for name <- ~w(agy bwrap socat) do
        File.write!(Path.join(bin, name), "#!/bin/sh\nexit 0\n")
        File.chmod!(Path.join(bin, name), 0o755)
      end

      keys =
        ~w(worker_isolate_config worker_agy_home_root worker_jail_available worker_jail_bwrap
           worker_jail_network_available worker_jail_network)a

      prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})
      old_path = System.get_env("PATH")

      Application.put_env(:arbiter, :worker_isolate_config, true)
      Application.put_env(:arbiter, :worker_agy_home_root, Path.join(base, "homes"))
      Application.put_env(:arbiter, :worker_jail_available, true)
      Application.put_env(:arbiter, :worker_jail_network_available, true)
      Application.delete_env(:arbiter, :worker_jail_network)
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

      {:ok,
       base: base,
       bin: bin,
       worktree: worktree,
       agy: Path.join(bin, "agy"),
       bwrap: Path.join(bin, "bwrap")}
    end

    defp policy(mode, sandbox \\ %{}),
      do:
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          permissions: %{mode: mode},
          sandbox: sandbox
        })

    defp jail_and_command(argv) do
      assert ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | rest] = argv
      {jail, ["--" | command]} = Enum.split_while(rest, &(&1 != "--"))

      # Network mode (bd-cfktou) starts the bridges in a small wrapper, then
      # execs the real command after its own `--`.
      case command do
        ["sh", "-c", _script, "sh", _socat | listeners] ->
          {_, ["--" | real]} = Enum.split_while(listeners, &(&1 != "--"))
          {jail, real}

        _ ->
          {jail, command}
      end
    end

    defp jail_argv_only(argv) do
      {jail, _} = jail_and_command(argv)
      jail
    end

    test "write_confinement/1 is :os_jail under :strict for agy on a jail-capable host" do
      assert Gemini.write_confinement(policy(:strict)) == :os_jail
    end

    test "write_confinement/1 is :os_jail in every mode on a jail-capable host (bd-3s82pf)" do
      assert Gemini.write_confinement(policy(:bypass)) == :os_jail
      assert Gemini.write_confinement(policy(:auto)) == :os_jail
    end

    test "write_confinement/1 is :none outside :strict when the host can't jail: no refusal, just unconfined" do
      Application.put_env(:arbiter, :worker_jail_available, false)
      assert Gemini.write_confinement(policy(:bypass)) == :none
      assert Gemini.write_confinement(policy(:auto)) == :none
    end

    test "write_confinement/1 is :none when the host fails the jail probe" do
      Application.put_env(:arbiter, :worker_jail_available, false)
      assert Gemini.write_confinement(policy(:strict)) == :none
    end

    test "write_confinement/1 is :none without the isolated agy HOME (nothing writable to bind)" do
      Application.put_env(:arbiter, :worker_isolate_config, false)
      assert Gemini.write_confinement(policy(:strict)) == :none
    end

    test "write_confinement/1 is :none when the policy turns the sandbox off" do
      assert Gemini.write_confinement(policy(:strict, %{enabled: false})) == :none
    end

    test "write_confinement/1 is :none for the upstream gemini CLI", %{bin: bin} do
      File.rm!(Path.join(bin, "agy"))
      File.write!(Path.join(bin, "gemini"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, "gemini"), 0o755)

      assert Gemini.write_confinement(policy(:strict)) == :none
    end

    test "write_jail_warning/1 is nil on a jail-capable host in every mode" do
      for mode <- [:bypass, :auto, :strict] do
        assert Gemini.write_jail_warning(policy(mode)) == nil
      end
    end

    test "write_jail_warning/1 warns outside :strict when the host can't jail (bd-3s82pf)" do
      Application.put_env(:arbiter, :worker_jail_available, false)

      for mode <- [:bypass, :auto, :strict] do
        assert Gemini.write_jail_warning(policy(mode)) =~ "agy write jail unavailable"
      end
    end

    # bd-8xy1mf finding: the warning text must not claim writes run
    # unconfined for a `:strict` policy — `:strict` refuses the dispatch
    # instead (`jail_blocker/1`), it never falls back to unconfined.
    test "write_jail_warning/1 names refusal for :strict, unconfined writes otherwise" do
      Application.put_env(:arbiter, :worker_jail_available, false)

      assert Gemini.write_jail_warning(policy(:strict)) =~ ":strict dispatches of agy are refused"
      refute Gemini.write_jail_warning(policy(:strict)) =~ "writes are not confined"

      for mode <- [:bypass, :auto] do
        assert Gemini.write_jail_warning(policy(mode)) =~
                 "writes are not confined to the worktree outside :strict"

        refute Gemini.write_jail_warning(policy(mode)) =~ "dispatches of agy are refused"
      end
    end

    test "write_jail_warning/1 is nil when the policy opts the sandbox off (nothing to warn about)" do
      Application.put_env(:arbiter, :worker_jail_available, false)
      assert Gemini.write_jail_warning(policy(:bypass, %{enabled: false})) == nil
    end

    test "write_confinement/1 is :none and the warning says dispatch is refused under podman" do
      podman = policy(:bypass, %{backend: :podman})

      assert Gemini.write_confinement(podman) == :none
      assert Gemini.write_jail_warning(podman) =~ "podman"
      assert Gemini.write_jail_warning(podman) =~ "refused in every mode"
      # Unchanged for the default backend.
      assert Gemini.write_confinement(policy(:strict)) == :os_jail
    end

    test "write_jail_warning/1 is nil for the upstream gemini CLI (nothing to jail)", %{bin: bin} do
      Application.put_env(:arbiter, :worker_jail_available, false)
      File.rm!(Path.join(bin, "agy"))
      File.write!(Path.join(bin, "gemini"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, "gemini"), 0o755)

      assert Gemini.write_jail_warning(policy(:bypass)) == nil
    end

    test "Agents' :strict gate now admits agy on a jail-capable host" do
      assert Arbiter.Agents.strict_eligible_provider(:gemini, policy(:strict), [:gemini],
               explicit: true
             ) == {:ok, :gemini}
    end

    test "default_argv/2 under :strict runs agy inside bwrap, inside the sh wrapper", %{
      worktree: worktree,
      agy: agy,
      bwrap: bwrap
    } do
      assert {:ok, argv} =
               default_argv("the prompt",
                 security: policy(:strict, %{writable_paths: ["/opt/extra"]}),
                 worktree_path: worktree
               )

      {jail, command} = jail_and_command(argv)
      home = Arbiter.Agents.Gemini.ConfigDir.path(worktree_path: worktree)

      assert [^bwrap, "--ro-bind", "/", "/" | _] = jail
      assert ["--bind", worktree, worktree] in Enum.chunk_every(jail, 3, 1)
      assert ["--bind", home, home] in Enum.chunk_every(jail, 3, 1)
      assert ["--setenv", "HOME", home] in Enum.chunk_every(jail, 3, 1)
      assert ["--bind-try", "/opt/extra", "/opt/extra"] in Enum.chunk_every(jail, 3, 1)
      assert "--unshare-pid" in jail
      assert [^agy, "-p", "the prompt" | _] = command
      refute "--sandbox" in command
      refute "--dangerously-skip-permissions" in command
    end

    # bd-cfktou (G6): agy's jail runs in a network namespace whose only way
    # out is the run's proxy and bridges.
    test "a jailed agy runs with --unshare-net, the proxy env and the loopback bridges", %{
      worktree: worktree
    } do
      assert {:ok, argv} =
               default_argv("p", security: policy(:bypass), worktree_path: worktree)

      jail = jail_argv_only(argv)
      assert "--unshare-net" in jail

      env =
        jail
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.filter(&(hd(&1) == "--setenv"))
        |> Map.new(fn [_, k, v] -> {k, v} end)

      assert env["HTTPS_PROXY"] == "http://127.0.0.1:3128"
      assert env["NO_PROXY"] =~ "127.0.0.1"
      assert env["GIT_SSH_COMMAND"] =~ "ProxyCommand socat - PROXY:127.0.0.1:%h:%p,proxyport=3128"

      assert ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | rest] = argv

      {_, ["--", "sh", "-c", _script, "sh", socat | listeners]} =
        Enum.split_while(rest, &(&1 != "--"))

      assert Path.basename(socat) == "socat"
      assert ["3128", proxy_sock, arb_port, arb_sock | _] = listeners
      assert proxy_sock =~ ".proxy.sock"
      assert String.to_integer(arb_port) > 0
      assert arb_sock =~ ".arb.sock"
    end

    test "a workspace's egress tunnel becomes a fixed-destination t1 bridge", %{
      worktree: worktree
    } do
      assert {:ok, argv} =
               default_argv("p",
                 security: policy(:bypass, %{egress_tunnels: ["5432:127.0.0.1:5432"]}),
                 worktree_path: worktree
               )

      assert ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | rest] = argv

      {_, ["--", "sh", "-c", _script, "sh", _socat | listeners]} =
        Enum.split_while(rest, &(&1 != "--"))

      # proxy, arb, then the tunnel: <local port> <host-side socket>
      assert ["3128", _proxy, _arb_port, _arb_sock, "5432", tunnel_sock | _] = listeners
      assert tunnel_sock =~ ".t1.sock"
    end

    test "the spawn's task id keys the egress events its proxy records", %{worktree: worktree} do
      assert {:ok, argv} =
               default_argv("p",
                 security: policy(:bypass),
                 worktree_path: worktree,
                 task_id: "bd-gem-task"
               )

      sock = argv |> jail_argv_only() |> Enum.find(&String.ends_with?(&1, ".proxy.sock"))
      run_id = Path.basename(sock, ".proxy.sock")

      {:ok, client} =
        :gen_tcp.connect({:local, String.to_charlist(sock)}, 0, [:binary, active: false], 2_000)

      :ok = :gen_tcp.send(client, "CONNECT catbox.moe:443 HTTP/1.1\r\n\r\n")
      assert {:ok, "HTTP/1.1 403" <> _} = :gen_tcp.recv(client, 0, 2_000)
      :gen_tcp.close(client)

      assert [%{task_id: "bd-gem-task", host: "catbox.moe"}] =
               Arbiter.Worker.Egress.Event
               |> Ash.Query.filter(run_id == ^run_id)
               |> Ash.read!()
    end

    test "a jailed spawn with no owner is refused rather than bound to the caller", %{
      worktree: worktree
    } do
      assert {:error, {:egress_unavailable, :no_owner}} =
               Gemini.default_argv("p", security: policy(:bypass), worktree_path: worktree)
    end

    test "the egress run is started for the spawn's owner and ends with it", %{worktree: worktree} do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, argv} =
               default_argv("p",
                 security: policy(:bypass),
                 worktree_path: worktree,
                 owner: owner
               )

      jail = jail_argv_only(argv)

      sock = Enum.find(jail, &String.ends_with?(&1, ".proxy.sock"))
      assert File.exists?(sock)

      [{sup, _}] =
        Registry.lookup(
          Arbiter.Worker.Egress.Registry,
          {Path.basename(sock, ".proxy.sock"), :sup}
        )

      ref = Process.monitor(sup)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sup, _}, 2_000
      refute File.exists?(sock)
    end

    test "a spawn whose egress cannot start is refused in every mode, never run on the shared network",
         %{worktree: worktree} do
      prev = Application.get_env(:arbiter, Arbiter.MCP)
      Application.put_env(:arbiter, Arbiter.MCP, url: "https://arbiter.example.com/mcp")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbiter, Arbiter.MCP, prev),
          else: Application.delete_env(:arbiter, Arbiter.MCP)
      end)

      for mode <- [:bypass, :auto, :strict] do
        assert {:error, {:egress_unavailable, {:arbiter_endpoint, :not_loopback}}} =
                 default_argv("p", security: policy(mode), worktree_path: worktree)
      end
    end

    test "a host without network mode still gets the filesystem jail, on the shared network",
         %{worktree: worktree, bwrap: bwrap} do
      Application.put_env(:arbiter, :worker_jail_network_available, false)
      previous = Logger.level()
      Logger.configure(level: :warning)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, argv} =
                   default_argv("p", security: policy(:bypass), worktree_path: worktree)

          {jail, _} = jail_and_command(argv)
          assert [^bwrap, "--ro-bind", "/", "/" | _] = jail
          refute "--unshare-net" in jail
        end)

      assert log =~ "network mode unavailable"
    end

    test "the network jail can be switched off", %{worktree: worktree} do
      Application.put_env(:arbiter, :worker_jail_network, false)

      assert {:ok, argv} =
               default_argv("p", security: policy(:bypass), worktree_path: worktree)

      refute "--unshare-net" in jail_argv_only(argv)
    end

    test "splice_prompt/2 still swaps the prompt and adds --conversation on a jailed argv", %{
      worktree: worktree,
      agy: agy
    } do
      {:ok, argv} =
        default_argv("first", security: policy(:strict), worktree_path: worktree)

      {jail, _} = jail_and_command(argv)

      assert {:ok, nudged} = Gemini.splice_prompt(argv, ["nudge"])
      assert {^jail, [^agy, "-p", "nudge" | _]} = jail_and_command(nudged)

      assert {:ok, resumed} = Gemini.splice_prompt(argv, ["--resume", "conv-1", "go on"])

      assert {^jail, [^agy, "-p", "go on", "--conversation", "conv-1" | _]} =
               jail_and_command(resumed)
    end

    test "default_argv/2 under :bypass and :auto is jailed too (bd-3s82pf: default-on in every mode)",
         %{worktree: worktree, agy: agy, bwrap: bwrap} do
      for mode <- [:bypass, :auto] do
        assert {:ok, argv} =
                 default_argv("p", security: policy(mode), worktree_path: worktree)

        {jail, command} = jail_and_command(argv)
        assert [^bwrap, "--ro-bind", "/", "/" | _] = jail
        assert ["--bind", worktree, worktree] in Enum.chunk_every(jail, 3, 1)
        assert [^agy, "-p", "p" | _] = command
      end
    end

    test "default_argv/2 outside :strict falls back unjailed when the host can't jail: no refusal",
         %{worktree: worktree, agy: agy} do
      Application.put_env(:arbiter, :worker_jail_available, false)

      for mode <- [:bypass, :auto] do
        assert {:ok, ["sh", "-c", _, "sh", ^agy, "-p", "p" | _]} =
                 default_argv("p", security: policy(mode), worktree_path: worktree)
      end
    end

    test "default_argv/2 outside :strict is not jailed when sandbox.enabled is false (the opt-out)",
         %{worktree: worktree, agy: agy} do
      for mode <- [:bypass, :auto, :strict] do
        result =
          default_argv("p",
            security: policy(mode, %{enabled: false}),
            worktree_path: worktree
          )

        case mode do
          :strict ->
            assert {:error, {:write_jail_unavailable, _}} = result

          _ ->
            assert {:ok, ["sh", "-c", _, "sh", ^agy, "-p", "p" | _]} = result
        end
      end
    end

    test "default_argv/2 for a worktree-backed review dispatch ro-binds the worktree (bd-3s82pf)",
         %{worktree: worktree} do
      review_policy =
        Arbiter.Worker.Dispatch.review_security_policy(policy(:bypass),
          review_checkout: %{path: worktree}
        )

      assert {:ok, argv} =
               default_argv("p", security: review_policy, worktree_path: worktree)

      {jail, _command} = jail_and_command(argv)
      refute ["--bind", worktree, worktree] in Enum.chunk_every(jail, 3, 1)
      assert ["--ro-bind", worktree, worktree] in Enum.chunk_every(jail, 3, 1)
    end

    test "default_argv/2 for a non-review dispatch keeps the worktree writable", %{
      worktree: worktree
    } do
      assert {:ok, argv} =
               default_argv("p", security: policy(:bypass), worktree_path: worktree)

      {jail, _command} = jail_and_command(argv)
      assert ["--bind", worktree, worktree] in Enum.chunk_every(jail, 3, 1)
      refute ["--ro-bind", worktree, worktree] in Enum.chunk_every(jail, 3, 1)
    end

    test "default_argv/2 under :strict fails closed when the host cannot jail", %{
      worktree: worktree
    } do
      Application.put_env(:arbiter, :worker_jail_available, false)

      assert {:error, {:write_jail_unavailable, _reason}} =
               default_argv("p", security: policy(:strict), worktree_path: worktree)
    end

    test "default_argv/2 under :strict fails closed with no worktree to confine to" do
      assert {:error, {:write_jail_unavailable, :no_worktree}} =
               default_argv("p", security: policy(:strict))
    end

    test "default_argv/2 outside :strict with no worktree falls back unjailed rather than erroring",
         %{agy: agy} do
      assert {:ok, ["sh", "-c", _, "sh", ^agy, "-p", "p" | _]} =
               default_argv("p", security: policy(:bypass))
    end

    test "default_argv/2 under :strict refuses the upstream gemini CLI", %{
      bin: bin,
      worktree: worktree
    } do
      File.rm!(Path.join(bin, "agy"))
      File.write!(Path.join(bin, "gemini"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, "gemini"), 0o755)

      assert {:error, {:write_jail_unavailable, _}} =
               default_argv("p", security: policy(:strict), worktree_path: worktree)
    end

    # bd-btcdrf (P2): the spawn goes through `Arbiter.Worker.Sandbox`; the
    # default backend (bwrap) must leave the argv exactly what `Jail.wrap/2`
    # builds for the same command and options.
    test "with the default backend the jailed argv is byte-identical to a direct Jail.wrap/2",
         %{worktree: worktree} do
      Application.put_env(:arbiter, :worker_jail_network, false)

      for mode <- [:strict, :bypass, :auto] do
        pol = policy(mode, %{writable_paths: ["/opt/extra"]})
        assert pol.sandbox.backend == :bwrap

        assert {:ok, argv} = default_argv("the prompt", security: pol, worktree_path: worktree)
        assert ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | jailed] = argv
        {_jail, ["--" | command]} = Enum.split_while(jailed, &(&1 != "--"))

        assert {:ok, ^jailed} =
                 Jail.wrap(command,
                   worktree: worktree,
                   home: Arbiter.Agents.Gemini.ConfigDir.path(worktree_path: worktree),
                   writable_paths: ["/opt/extra"],
                   worktree_readonly: false,
                   keyring: Arbiter.Agents.Gemini.ConfigDir.keyring_available?(),
                   hide_reads: true
                 )

        # An explicit `backend: :bwrap` is the same policy as the default.
        explicit = policy(mode, %{writable_paths: ["/opt/extra"], backend: :bwrap})

        assert {:ok, ^argv} =
                 default_argv("the prompt", security: explicit, worktree_path: worktree)
      end
    end

    # bd-3q2djr (G3): the agy spawn asks for the hidden read paths; the data
    # dir (`~/.arbiter`, the install DB) is one of them.
    test "an agy spawn hides the install data dir behind a tmpfs", %{worktree: worktree} do
      Application.put_env(:arbiter, :worker_jail_network, false)
      data_dir = Path.join(worktree, "../hide-data-#{System.unique_integer([:positive])}")
      File.mkdir_p!(data_dir)
      data_dir = Arbiter.Worker.Jail.Hide.real(data_dir)
      prev = Application.get_env(:arbiter, :data_dir)
      Application.put_env(:arbiter, :data_dir, data_dir)

      on_exit(fn ->
        File.rm_rf!(data_dir)

        if prev,
          do: Application.put_env(:arbiter, :data_dir, prev),
          else: Application.delete_env(:arbiter, :data_dir)
      end)

      pol = policy(:strict, %{})
      assert {:ok, argv} = default_argv("the prompt", security: pol, worktree_path: worktree)
      assert Enum.chunk_every(argv, 2, 1) |> Enum.member?(["--tmpfs", data_dir])
    end

    test "backend: podman refuses agy in every mode and never spawns it unjailed", %{
      worktree: worktree
    } do
      for mode <- [:strict, :bypass, :auto] do
        assert {:error, {:sandbox_backend_unavailable, :podman, message}} =
                 default_argv("p",
                   security: policy(mode, %{backend: :podman}),
                   worktree_path: worktree
                 )

        assert message =~ "podman"
      end

      # Even a host that cannot jail at all does not fall back to unjailed.
      Application.put_env(:arbiter, :worker_jail_available, false)

      assert {:error, {:sandbox_backend_unavailable, :podman, _}} =
               default_argv("p",
                 security: policy(:bypass, %{backend: :podman}),
                 worktree_path: worktree
               )
    end
  end

  describe "backend: podman on the upstream gemini CLI (bd-btcdrf)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-podman-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "gemini"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(tmp, "gemini"), 0o755)
      old_path = System.get_env("PATH")
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "is refused in every mode, though the upstream CLI is never jailed" do
      for mode <- [:strict, :bypass, :auto] do
        policy =
          SecurityPolicy.merge(SecurityPolicy.base(), %{
            permissions: %{mode: mode},
            sandbox: %{backend: :podman}
          })

        assert {:error, {:sandbox_backend_unavailable, :podman, _}} =
                 Arbiter.Agents.Gemini.default_argv("p", security: policy)
      end
    end
  end

  describe "resolved_model/1" do
    setup do
      Arbiter.Agents.Gemini.Config.clear()
      on_exit(&Arbiter.Agents.Gemini.Config.clear/0)

      # resolved_model/1 now branches on which executable would actually run
      # (bd-2fzwlc round 3), so these tests must not depend on whether the
      # host machine happens to have `agy` on PATH — pin PATH to a stub
      # `gemini` binary so they exercise the resolve_model/1 fallback chain
      # deterministically, the same way the default_argv/2 tests below do.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-resolved-model-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "uses an explicit :model override verbatim" do
      assert Gemini.resolved_model(model: "gemini-2.5-flash") == "gemini-2.5-flash"
    end

    test "resolves a :model_tier to a concrete model" do
      assert Gemini.resolved_model(model_tier: "premium") == "gemini-2.5-pro"
      assert Gemini.resolved_model(model_tier: "economy") == "gemini-2.5-flash-lite"
    end

    test "falls back to the gemini-cli default model when nothing is configured" do
      # No explicit model, no tier, no workspace active_model → the gemini-cli's
      # own DEFAULT_GEMINI_MODEL, so the usage ledger still lands a concrete id.
      assert Gemini.resolved_model([]) == "gemini-2.5-pro"
    end

    test "resolves a model for agy the same way as gemini (bd-d2yut8): no more forced nil",
         %{tmp: tmp} do
      # agy does accept `--model` (bd-d2yut8 retires the "agy accepts no
      # model" assumption), so resolution now runs the same explicit →
      # tier → workspace active_model chain as the gemini branch. With
      # nothing configured there is still no known agy-CLI default to fall
      # back to, so that case alone stays nil.
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert Gemini.resolved_model([]) == nil
      assert Gemini.resolved_model(model: "gemini-2.5-flash") == "gemini-2.5-flash"
      assert Gemini.resolved_model(model_tier: "premium") == "gemini-3.1-pro-high"
    end
  end

  describe "default_argv/2 executable resolution" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-gemini-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp, old_path: old_path}
    end

    test "returns {:error, ...} when neither `agy` nor `gemini` is on PATH", %{old_path: old_path} do
      System.put_env("PATH", "/nonexistent-dir-for-test")

      try do
        assert {:error, {:executable_not_found, "agy or gemini"}} =
                 default_argv("hello", [])
      after
        System.put_env("PATH", old_path)
      end
    end

    test "favors `agy` when both `agy` and `gemini` exist", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)
      File.chmod!(gemini_stub, 0o755)

      # Default policy is :bypass — skip-permissions flag IS included.
      assert {:ok, argv} = default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--dangerously-skip-permissions" in rest
      refute "--skip-trust" in rest
    end

    test "agy: :bypass security mode includes --dangerously-skip-permissions", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      bypass_policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})

      assert {:ok, argv} = default_argv("the prompt", security: bypass_policy)
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--dangerously-skip-permissions" in rest
    end

    test "falls back to `gemini` when `agy` is missing", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      # Default policy is :bypass — skip-trust IS included.
      assert {:ok, argv} = default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--skip-trust" in rest
      assert "-y" in rest
      refute "--dangerously-skip-permissions" in rest
    end

    test "gemini: :bypass security mode includes --skip-trust -y", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      bypass_policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})

      assert {:ok, argv} = default_argv("the prompt", security: bypass_policy)
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--skip-trust" in rest
      assert "-y" in rest
    end

    test "passes an explicit :model opt through as --model on the agy branch", %{tmp: tmp} do
      # bd-d2yut8: agy does accept `--model` — retire the old assumption
      # that it doesn't and pass the flag through like the gemini branch.
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert {:ok, argv} = default_argv("the prompt", model: "gemini-flash")
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "gemini-flash" in rest
    end

    test "resolves :model_tier to a concrete model on the agy branch via the agy tier map",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      for {tier, model} <- [
            {"economy", "gemini-3.8-flash-low"},
            {"standard", "gemini-3.8-flash-medium"},
            {"premium", "gemini-3.1-pro-high"},
            {"flagship", "claude-opus-4-6-thinking"}
          ] do
        {:ok, argv} = default_argv("the prompt", model_tier: tier)
        assert "--model" in argv
        assert model in argv
      end
    end

    test "omits --model on the agy branch when nothing resolves", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = default_argv("the prompt", [])
      refute "--model" in argv
    end

    test "passes through `:model` opt as `--model <name>` on the gemini branch", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = default_argv("the prompt", model: "gemini-flash")
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "the prompt" | rest] = argv
      assert "--model" in rest
      assert "gemini-flash" in rest
    end

    test "resolves :model_tier to a concrete Gemini model via the default tier map on the gemini branch",
         %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      for {tier, model} <- [
            {"premium", "gemini-2.5-pro"},
            {"standard", "gemini-2.5-flash"},
            {"economy", "gemini-2.5-flash-lite"}
          ] do
        {:ok, argv} = default_argv("the prompt", model_tier: tier)
        assert "--model" in argv
        assert model in argv
      end
    end

    test ":model wins over :model_tier when both are set", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      {:ok, argv} =
        default_argv("the prompt", model: "custom-model", model_tier: "economy")

      assert "custom-model" in argv
      refute "gemini-2.5-flash-lite" in argv
    end

    test ":model_tier can be overridden per-workspace via tier_models config", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      Gemini.Config.put_active(%{
        "tier_models" => %{"premium" => "gemini-ultra"}
      })

      on_exit(fn -> Gemini.Config.clear() end)

      {:ok, argv} = default_argv("the prompt", model_tier: "premium")
      assert "gemini-ultra" in argv
      refute "gemini-2.5-pro" in argv
    end

    test ":thinking opt maps to --effort <level> by default", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = default_argv("the prompt", thinking: "high")
      assert "--effort" in argv
      assert chunk_after(argv, "--effort") == "high"
    end

    test ":thinking none maps to no argv", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = default_argv("the prompt", thinking: "none")
      refute "--effort" in argv
    end

    test ":thinking xhigh/max clamp to --effort high", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      for level <- ["xhigh", "max"] do
        {:ok, argv} = default_argv("the prompt", thinking: level)
        assert chunk_after(argv, "--effort") == "high"
      end
    end

    test "gemini branch never emits --effort (Finding 1: upstream CLI rejects it)", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      for level <- ["low", "medium", "high", "xhigh", "max"] do
        {:ok, argv} = default_argv("the prompt", thinking: level)
        refute "--effort" in argv
      end
    end

    test "agy branch omits --effort when the resolved model already carries an effort suffix (Finding 2)",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      # Every non-flagship agy tier model carries a "-low"/"-medium"/"-high"
      # suffix. Passing a :thinking level that disagrees with the tier's own
      # suffix must still omit --effort — the operator decision is "never
      # both", so the id's own suffix always wins and there is no way to
      # emit two conflicting effort signals.
      {:ok, argv} = default_argv("the prompt", model_tier: "premium", thinking: "low")
      assert "--model" in argv
      assert "gemini-3.1-pro-high" in argv
      refute "--effort" in argv
    end

    test "agy branch emits --effort for a suffix-free flagship model", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = default_argv("the prompt", model_tier: "flagship", thinking: "high")
      assert "--model" in argv
      assert "claude-opus-4-6-thinking" in argv
      assert "--effort" in argv
      assert chunk_after(argv, "--effort") == "high"
    end

    test ":thinking argv can be overridden per-workspace via thinking_argv config",
         %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      Gemini.Config.put_active(%{
        "thinking_argv" => %{"medium" => ["--thinking-budget", "8192"]}
      })

      on_exit(fn -> Gemini.Config.clear() end)

      {:ok, argv} = default_argv("the prompt", thinking: "medium")
      assert "--thinking-budget" in argv
      assert "8192" in argv
    end

    test "gemini CLI path opts into --output-format stream-json", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = default_argv("the prompt", [])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub | rest] = argv
      assert "--output-format" in rest
      assert "stream-json" in rest
      # The two are adjacent, in order.
      assert chunk_after(rest, "--output-format") == "stream-json"
    end

    test "agy CLI path also adds --output-format stream-json (bd-2fzwlc: agy supports it)", %{
      tmp: tmp
    } do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert {:ok, argv} = default_argv("the prompt", [])
      assert "--output-format" in argv
      assert "stream-json" in argv
      assert chunk_after(argv, "--output-format") == "stream-json"
    end
  end

  defp chunk_after(list, flag) do
    list
    |> Enum.drop_while(&(&1 != flag))
    |> Enum.at(1)
  end

  describe "default_argv/2 :timeout_ms → --print-timeout (bd-1xss5z)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-print-timeout-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "agy branch: :timeout_ms is passed through as --print-timeout in seconds", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = default_argv("the prompt", timeout_ms: 1_800_000)
      assert "--print-timeout" in argv
      assert chunk_after(argv, "--print-timeout") == "1800s"
    end

    test "agy branch: no --print-timeout flag when :timeout_ms is absent", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      {:ok, argv} = default_argv("the prompt", [])
      refute "--print-timeout" in argv
    end

    test "gemini (upstream) branch ignores :timeout_ms — flag is agy-only", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      {:ok, argv} = default_argv("the prompt", timeout_ms: 1_800_000)
      refute "--print-timeout" in argv
    end
  end

  describe "spawn_env/1" do
    setup do
      on_exit(fn -> Gemini.Config.clear() end)
      :ok
    end

    test "exports GEMINI_API_KEY and GOOGLE_GENAI_API_KEY from `opts[:api_key]`" do
      assert Gemini.spawn_env(api_key: "my-token") == [
               {"GEMINI_API_KEY", "my-token"},
               {"GOOGLE_GENAI_API_KEY", "my-token"}
             ]
    end

    test "exports GEMINI_THINKING_LEVEL for low/medium/high :thinking" do
      for level <- ["low", "medium", "high"] do
        env = Gemini.spawn_env(thinking: level)

        assert {"GEMINI_THINKING_LEVEL", ^level} =
                 Enum.find(env, &match?({"GEMINI_THINKING_LEVEL", _}, &1))
      end
    end

    test "clamps above-ladder levels to Gemini's own ceiling instead of dropping them" do
      # #1519: D4/D5 route "max" (and workspaces route "xhigh"). Gemini has no
      # level above "high", and the old whitelist silently emitted NO env var
      # for anything it did not recognise — a Gemini workspace would have LOST
      # its reasoning budget at the top of the scale.
      for level <- ["xhigh", "max"] do
        env = Gemini.spawn_env(thinking: level)

        assert {"GEMINI_THINKING_LEVEL", "high"} in env,
               "expected #{level} to clamp to high, got #{inspect(env)}"
      end
    end

    test "omits GEMINI_THINKING_LEVEL when :thinking is none / nil" do
      refute Enum.any?(
               Gemini.spawn_env(thinking: "none"),
               &match?({"GEMINI_THINKING_LEVEL", _}, &1)
             )

      refute Enum.any?(Gemini.spawn_env([]), &match?({"GEMINI_THINKING_LEVEL", _}, &1))
    end

    test "composes thinking + api key" do
      env = Gemini.spawn_env(api_key: "k", thinking: "high")

      assert {"GEMINI_API_KEY", "k"} in env
      assert {"GOOGLE_GENAI_API_KEY", "k"} in env
      assert {"GEMINI_THINKING_LEVEL", "high"} in env
    end
  end

  describe "splice_prompt/2 — resume (bd-b7e33c)" do
    test "agy branch: translates --resume into --conversation <id> and preserves --print-timeout/--model/--effort" do
      argv = [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        "/usr/local/bin/agy",
        "-p",
        "ORIGINAL TASK PROMPT",
        "--dangerously-skip-permissions",
        "--model",
        "gemini-3.1-pro",
        "--effort",
        "high",
        "--output-format",
        "stream-json",
        "--print-timeout",
        "300s"
      ]

      assert {:ok, out} =
               Gemini.splice_prompt(argv, ["--resume", "sess-abc", "CONTINUE PROMPT"])

      idx = Enum.find_index(out, &(&1 == "-p"))
      assert Enum.slice(out, idx, 2) == ["-p", "CONTINUE PROMPT"]
      refute "ORIGINAL TASK PROMPT" in out

      assert chunk_after(out, "--conversation") == "sess-abc"
      assert chunk_after(out, "--model") == "gemini-3.1-pro"
      assert chunk_after(out, "--effort") == "high"
      assert chunk_after(out, "--print-timeout") == "300s"
      assert "--dangerously-skip-permissions" in out
      assert "--output-format" in out and "stream-json" in out
    end

    test "upstream gemini branch: --resume is rejected with an explicit error, not a bogus invocation" do
      argv = [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        "/usr/local/bin/gemini",
        "-p",
        "ORIGINAL TASK PROMPT",
        "--skip-trust",
        "-y",
        "--model",
        "gemini-2.5-pro",
        "--output-format",
        "stream-json"
      ]

      assert {:error, :resume_unsupported} =
               Gemini.splice_prompt(argv, ["--resume", "sess-abc", "CONTINUE PROMPT"])
    end

    test "nudge: swaps only the prompt, leaving every flag (agy or upstream) untouched" do
      argv = [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        "/usr/local/bin/agy",
        "-p",
        "ORIGINAL TASK PROMPT",
        "--model",
        "gemini-3.1-pro",
        "--output-format",
        "stream-json"
      ]

      assert {:ok, out} = Gemini.splice_prompt(argv, ["nudge prompt"])

      idx = Enum.find_index(out, &(&1 == "-p"))
      assert Enum.slice(out, idx, 2) == ["-p", "nudge prompt"]
      refute "ORIGINAL TASK PROMPT" in out
      refute "--conversation" in out
      assert chunk_after(out, "--model") == "gemini-3.1-pro"
    end

    test "errors when there is no -p slot (custom command / fixture)" do
      assert {:error, :no_print_slot} =
               Gemini.splice_prompt(["sh", "-c", "echo hi; exit 0"], ["nudge"])

      assert {:error, :no_print_slot} =
               Gemini.splice_prompt(["sh", "-c", "echo hi; exit 0"], [
                 "--resume",
                 "sid",
                 "prompt"
               ])
    end
  end

  # bd-7s29yq (T6b): the agy security seam. `Gemini.Security` owns the
  # policy -> agy vocabulary mapping and is unit-tested in
  # `gemini/security_test.exs`; these cover the *wiring* — that the adapter
  # actually emits it.
  describe "agy security wiring (bd-7s29yq)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gemini-sec-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      agy = Path.join(tmp, "agy")
      File.write!(agy, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy, 0o755)
      old_path = System.get_env("PATH")
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, agy: agy}
    end

    test ":auto emits neither flag — the generated settings carry the posture", %{agy: agy} do
      policy = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :auto}})

      assert {:ok, argv} = default_argv("p", security: policy)
      assert ["sh", "-c", _exec, "sh", ^agy, "-p", "p" | rest] = argv
      refute "--sandbox" in rest
      refute "--dangerously-skip-permissions" in rest
    end
  end

  describe "security_enforced?/0 (bd-7s29yq AC3)" do
    test "is false when the isolated agy HOME is switched off — nothing is enforced then" do
      prev = Application.get_env(:arbiter, :worker_isolate_config)
      Application.put_env(:arbiter, :worker_isolate_config, false)
      on_exit(fn -> Application.put_env(:arbiter, :worker_isolate_config, prev) end)

      refute Gemini.security_enforced?()
    end

    test "is true only for the agy CLI with isolation on — upstream gemini has no seam" do
      prev = Application.get_env(:arbiter, :worker_isolate_config)
      Application.put_env(:arbiter, :worker_isolate_config, true)
      tmp = Path.join(System.tmp_dir!(), "gemini-enf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH")

      on_exit(fn ->
        Application.put_env(:arbiter, :worker_isolate_config, prev)
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      gemini = Path.join(tmp, "gemini")
      File.write!(gemini, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini, 0o755)
      System.put_env("PATH", tmp)
      refute Gemini.security_enforced?()

      agy = Path.join(tmp, "agy")
      File.write!(agy, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy, 0o755)
      assert Gemini.security_enforced?()
    end
  end

  describe "spawn_env/1 — isolated agy HOME (bd-7s29yq AC2)" do
    test "injects HOME so the operator's ~/.gemini memory, skills and plugins cannot load" do
      base = Path.join(System.tmp_dir!(), "gemini-home-#{System.unique_integer([:positive])}")
      prev_enabled = Application.get_env(:arbiter, :worker_isolate_config)
      prev_root = Application.get_env(:arbiter, :worker_agy_home_root)
      Application.put_env(:arbiter, :worker_isolate_config, true)
      Application.put_env(:arbiter, :worker_agy_home_root, Path.join(base, "homes"))

      # home_env/1 only fires for the resolved `agy` executable — stub one onto
      # PATH so this test doesn't depend on the host actually having agy installed.
      bin = Path.join(base, "bin")
      File.mkdir_p!(bin)
      agy = Path.join(bin, "agy")
      File.write!(agy, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy, 0o755)
      old_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> old_path)

      on_exit(fn ->
        Application.put_env(:arbiter, :worker_isolate_config, prev_enabled)

        if is_nil(prev_root),
          do: Application.delete_env(:arbiter, :worker_agy_home_root),
          else: Application.put_env(:arbiter, :worker_agy_home_root, prev_root)

        System.put_env("PATH", old_path)
        File.rm_rf!(base)
      end)

      env = Gemini.spawn_env(worktree: Path.join(base, "wt"))
      assert {"HOME", home} = Enum.find(env, &match?({"HOME", _}, &1))
      assert home != System.user_home()
      assert File.regular?(Path.join(home, ".gemini/GEMINI.md"))
      assert File.regular?(Path.join(home, ".gemini/antigravity-cli/settings.json"))
    end

    test "injects no HOME when isolation is off (unchanged inherited behaviour)" do
      prev = Application.get_env(:arbiter, :worker_isolate_config)
      Application.put_env(:arbiter, :worker_isolate_config, false)
      on_exit(fn -> Application.put_env(:arbiter, :worker_isolate_config, prev) end)

      refute Enum.any?(Gemini.spawn_env(api_key: "k"), &match?({"HOME", _}, &1))
    end
  end

  # bd-481sz7 AC3: the preflight probe must request structured output so its
  # usage_events row carries real token counts (previously it ran `-p ping`
  # with no `--output-format`, so `Arbiter.Agents.Gemini.Stream` had nothing
  # to parse and every agy preflight row landed with zero tokens).
  describe "auth_probe_argv/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-probe-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "requests stream-json structured output for agy", %{tmp: tmp} do
      agy_stub = Path.join(tmp, "agy")
      File.write!(agy_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(agy_stub, 0o755)

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert ["sh", "-c", _exec, "sh", ^agy_stub, "-p", "ping" | rest] = argv
      assert "--output-format" in rest

      assert Enum.at(rest, Enum.find_index(rest, &(&1 == "--output-format")) + 1) ==
               "stream-json"
    end

    test "requests stream-json structured output for upstream gemini", %{tmp: tmp} do
      gemini_stub = Path.join(tmp, "gemini")
      File.write!(gemini_stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(gemini_stub, 0o755)

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert ["sh", "-c", _exec, "sh", ^gemini_stub, "-p", "ping" | rest] = argv
      assert "--output-format" in rest
    end

    test "returns {:error, ...} when neither CLI is on PATH" do
      System.put_env("PATH", "/nonexistent-dir-for-test")
      assert {:error, {:executable_not_found, "agy or gemini"}} = Gemini.auth_probe_argv([])
    end
  end

  # bd-svczq4: the pre-flight probe used to be a bare `agy -p ping` — plain-text
  # print mode with no self-timeout, tools on, rooted in the live checkout. It
  # took 102s against a 30s harness watchdog and refused a valid dispatch.
  # bd-481sz7 gave it `--output-format stream-json` (asserted here as a
  # regression guard); what this ticket adds is `--print-timeout`, derived from
  # the harness watchdog so agy yields *first* and a real exit status is always
  # observed instead of agy's own 5-minute default.
  describe "auth_probe_argv/1 (bd-svczq4)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-probe-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    defp stub_exec(tmp, name) do
      path = Path.join(tmp, name)
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
      path
    end

    defp flag_value(argv, flag) do
      case Enum.find_index(argv, &(&1 == flag)) do
        nil -> nil
        idx -> Enum.at(argv, idx + 1)
      end
    end

    test "agy: asks for a structured result", %{tmp: tmp} do
      agy = stub_exec(tmp, "agy")

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert ["sh", "-c", _script, "sh", ^agy, "-p", "ping" | _rest] = argv
      assert flag_value(argv, "--output-format") == "stream-json"
    end

    test "agy: bounds its own turn strictly inside the harness watchdog", %{tmp: tmp} do
      _agy = stub_exec(tmp, "agy")

      assert {:ok, argv} = Gemini.auth_probe_argv(timeout_ms: 120_000)
      assert value = flag_value(argv, "--print-timeout")
      assert {seconds, "s"} = Integer.parse(value)
      assert seconds > 0
      # Strictly inside: agy must yield and report an exit status before the
      # harness gives up, which is the whole point of the flag.
      assert seconds * 1000 < 120_000
    end

    test "agy: bounds itself even when the caller names no watchdog", %{tmp: tmp} do
      _agy = stub_exec(tmp, "agy")

      assert {:ok, argv} = Gemini.auth_probe_argv([])
      assert value = flag_value(argv, "--print-timeout")
      assert {seconds, "s"} = Integer.parse(value)
      assert seconds > 0
      # Never agy's own 5-minute print-mode default.
      assert seconds < 300
    end

    test "upstream gemini: structured output, but no agy-only --print-timeout", %{tmp: tmp} do
      gemini = stub_exec(tmp, "gemini")

      assert {:ok, argv} = Gemini.auth_probe_argv(timeout_ms: 120_000)
      assert ["sh", "-c", _script, "sh", ^gemini, "-p", "ping" | _rest] = argv
      assert flag_value(argv, "--output-format") == "stream-json"
      refute "--print-timeout" in argv
    end
  end

  # bd-8btihu: agy 1.2.16 cannot authenticate from legacy file-seeded credentials.
  # When no keyring/D-Bus session bus is reachable for an agy worker, fail at preflight
  # with a clear error ("agy needs a keyring (D-Bus) or its own login on this host").
  describe "auth_probe/1 (bd-8btihu)" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "arbiter-gemini-probe-stub-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        Application.delete_env(:arbiter, :worker_gemini_keyring_available)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "agy: when keyring is available, auth_probe/1 returns :skipped to fall through to argv probe",
         %{tmp: tmp} do
      _agy = stub_exec(tmp, "agy")

      assert :skipped = Gemini.auth_probe(keyring: true)
    end

    test "agy: when keyring is unavailable (opt: keyring: false), fails with explicit error", %{
      tmp: tmp
    } do
      _agy = stub_exec(tmp, "agy")

      assert {:error, %Arbiter.Worker.StopReason{} = reason} =
               Gemini.auth_probe(keyring: false)

      assert reason.category == :auth_expired
      assert reason.summary == "agy needs a keyring (D-Bus) or its own login on this host"
    end

    test "agy: when keyring path is forced unavailable via app env, auth_probe/1 fails loudly", %{
      tmp: tmp
    } do
      _agy = stub_exec(tmp, "agy")
      Application.put_env(:arbiter, :worker_gemini_keyring_available, false)

      assert {:error, %Arbiter.Worker.StopReason{} = reason} = Gemini.auth_probe([])
      assert reason.category == :auth_expired
      assert reason.summary == "agy needs a keyring (D-Bus) or its own login on this host"
    end

    test "agy: Preflight.check/2 fails loudly when keyring is unavailable", %{tmp: tmp} do
      _agy = stub_exec(tmp, "agy")

      assert {:error, %Arbiter.Worker.StopReason{} = reason} =
               Arbiter.Agents.Preflight.check(Gemini, keyring: false)

      assert reason.category == :auth_expired
      assert reason.summary == "agy needs a keyring (D-Bus) or its own login on this host"
    end

    test "agy: a session bus with no xdg-dbus-proxy still passes (unjailed agy finds the bus)",
         %{tmp: tmp} do
      _agy = stub_exec(tmp, "agy")
      File.write!(Path.join(tmp, "bus"), "")

      old = for k <- ~w(XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS), do: {k, System.get_env(k)}
      System.put_env("XDG_RUNTIME_DIR", tmp)
      System.delete_env("DBUS_SESSION_BUS_ADDRESS")
      Application.put_env(:arbiter, :xdg_dbus_proxy, nil)

      on_exit(fn ->
        Application.delete_env(:arbiter, :xdg_dbus_proxy)

        for {k, v} <- old do
          if v, do: System.put_env(k, v), else: System.delete_env(k)
        end
      end)

      assert :skipped = Gemini.auth_probe([])
    end

    test "upstream gemini: returns :skipped regardless of keyring status", %{tmp: tmp} do
      _gemini = stub_exec(tmp, "gemini")

      assert :skipped = Gemini.auth_probe(keyring: false)
    end

    test "returns {:error, :crashed} when neither CLI is on PATH" do
      System.put_env("PATH", "/nonexistent-dir-for-test")

      assert {:error, %Arbiter.Worker.StopReason{} = reason} = Gemini.auth_probe([])
      assert reason.category == :crashed
      assert reason.summary =~ "not found on PATH"
    end
  end

  describe "async_tool_instruction" do
    test "async_tool_instruction/0 renders reviewer instruction without Claude tools or disproven flags" do
      text = Gemini.async_tool_instruction()

      assert text =~ "your VERDICT"
      assert text =~ "WaitMsBeforeAsync"
      refute text =~ "Monitor"
      refute text =~ "ScheduleWakeup"
      refute text =~ "TaskOutput"
      refute text =~ "Blocking"
      refute text =~ "COMMIT correct work BEFORE"
    end

    test "async_tool_instruction/3 respects completion signal, coda, and commit_first option" do
      work_text =
        Gemini.async_tool_instruction("`arb done`", "extra explanation", commit_first: true)

      assert work_text =~ "COMMIT correct work BEFORE"
      assert work_text =~ "before you print `arb done` —\nextra explanation."
      refute work_text =~ "Monitor"
      refute work_text =~ "ScheduleWakeup"
      assert work_text =~ "WaitMsBeforeAsync"

      no_commit = Gemini.async_tool_instruction("`arb done`", nil, commit_first: false)
      refute no_commit =~ "COMMIT correct work BEFORE"
      assert no_commit =~ "before you print `arb done`."
    end

    # bd-bxwsvo: the bd-apq1g6 re-run on agy 1.2.12 found `Blocking` is not a
    # run_command parameter at all (silently dropped) and `WaitMsBeforeAsync`
    # caps at 10000 ms — while headless agy now keeps the session alive for up
    # to 30m after the turn ends and wakes the agent with a completion system
    # message. The old text ("keep calling `manage_task status` … NEVER end
    # your turn") is what made bd-90kjvk's worker poll ~440 times and burn 84%
    # of a Gemini 5h window on one D1.
    test "launch, end the turn, resume on the completion message — never poll" do
      for text <- [
            Gemini.async_tool_instruction(),
            Gemini.async_tool_instruction("`arb done`", nil)
          ] do
        # the disproven flag and the polling loop are gone
        refute text =~ "Blocking"
        refute text =~ ~r/keep calling `manage_task status`/
        refute text =~ ~r/NEVER end your turn/i
        refute text =~ "WaitMsBeforeAsync: 10000"
        refute text =~ ~r/"WaitMsBeforeAsync": 0/

        # the verified 1.2.12 behaviour, pinned to the version it was seen on
        assert text =~ "agy 1.2.12"
        assert text =~ "end your turn"
        assert text =~ "system message"
        assert text =~ "finished with result"
        assert text =~ ~r/Do NOT poll/
        assert text =~ "manage_task"
        assert text =~ "sleep"

        # the long commands the ticket names
        assert text =~ "mix test"
        assert text =~ "mix precommit"
        assert text =~ "dialyzer"
        assert text =~ "git push"

        # the CLI's own background-wait cap
        assert text =~ "30 minutes"

        # the shared continuation rule ("a turn with no tool call ENDS the
        # session") still holds when nothing is running — the block must say
        # the exception is only while a launched task is still running.
        assert text =~ "exception"
        assert text =~ ~r/nothing (is )?running/i
      end
    end
  end
end
