defmodule Arbiter.Worker.ContainerSpawnTest do
  @moduledoc """
  bd-d2o3xb (P7): Claude under `sandbox.backend: podman`.

  Host-side and argv-level: `ContainerSpawn.prepare/1` and `wrap_port/1`
  against a real private clone and a stand-in egress run, and the
  `ClaudeSession` -> `Worker` path against a stand-in `podman` that runs the
  container's command on the host. The real-container half is
  `container_spawn_podman_test.exs` (`@moduletag :podman`).
  """
  # async: false: Application env, a shared Worker registry and Ports.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.PrivateClone

  @branch "feature/bd-p7-claude"
  @image "localhost/arb-test/claude:1"

  setup do
    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = PrivateClone.create(ctx.checkout, @branch, "main")

    dir = Path.join(ctx.root, "scratch")
    File.mkdir_p!(dir)

    # The stand-in egress run: two plain files where the sockets would be.
    proxy = Path.join(dir, "proxy.sock")
    bridge = Path.join(dir, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    real_claude = Path.join(dir, "claude-2.1.999")
    File.write!(real_claude, "#!/bin/sh\n")
    File.chmod!(real_claude, 0o755)
    claude_link = Path.join(dir, "claude")
    File.ln_s!("claude-2.1.999", claude_link)
    arb = Path.join(dir, "arb")
    File.write!(arb, "#!/bin/sh\n")

    tmp_dir = Path.join(dir, "run-tmp")
    File.mkdir_p!(tmp_dir)

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_container_image: nil
        ] do
      previous = Application.get_env(:arbiter, key)
      Application.put_env(:arbiter, key, value)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:arbiter, key),
          else: Application.put_env(:arbiter, key, previous)
      end)
    end

    # Free ports: the stand-in podman runs the in-container socat on the host,
    # where the live coordinator may already hold 4848 and 3128.
    proxy_port = free_port()
    arb_port = free_port()

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: proxy_port, bridges: [{arb_port, bridge}]], "rtest"}
    end

    base_opts = [
      policy: podman_policy(),
      worktree_path: clone,
      owner: self(),
      task_id: "bd-p7test",
      arb_token: "arb-secret-token",
      tmp_dir: tmp_dir,
      image: @image,
      podman: "/usr/bin/podman",
      claude_path: claude_link,
      arb_path: arb,
      egress: egress
    ]

    Map.merge(ctx, %{
      clone: clone,
      dir: dir,
      proxy: proxy,
      proxy_port: proxy_port,
      bridge: bridge,
      real_claude: real_claude,
      arb: arb,
      tmp_dir: tmp_dir,
      opts: base_opts
    })
  end

  defp podman_policy do
    SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})
  end

  defp port_args(ctx, request, env \\ []) do
    %{
      exec: "/bin/sh",
      argv: [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        ContainerSpawn.claude_path(),
        "--print",
        "the prompt"
      ],
      cd: ctx.clone,
      env: ContainerSpawn.apply_env(env, request),
      sandbox: request
    }
  end

  defp mounts(argv), do: for(["-v", spec] <- Enum.chunk_every(argv, 2, 1), do: spec)

  describe "prepare/1" do
    test "describes a rootless container over the private clone, bridges and per-run dirs",
         ctx do
      assert {:ok, request} = ContainerSpawn.prepare(ctx.opts)

      assert String.starts_with?(request.name, "arb-bd-p7test-")
      assert request.image == @image
      assert request.mounts[:worktree] == ctx.clone
      assert request.mounts[:git_dir] == Path.join(ctx.clone, ".git")
      assert request.mounts[:objects] != nil

      # The CLI mounts bind the resolved binary, not the symlink.
      assert {ctx.real_claude, "/opt/arbiter/cli/claude"} in request.cli_mounts
      assert {ctx.arb, "/opt/arbiter/cli/arb"} in request.cli_mounts

      assert request.home == Path.join(ctx.tmp_dir, "home")
      assert request.config_dir == Path.join(ctx.tmp_dir, "claude-config")
      assert File.dir?(request.home)
      assert File.dir?(request.config_dir)
      assert ctx.tmp_dir in request.writable_paths

      # Never a credential file, and none of the install-wide dir's history.
      refute File.exists?(Path.join(request.config_dir, ".credentials.json"))
      refute File.exists?(Path.join(request.config_dir, "projects"))
    end

    test "the container's own env carries the proxy, ARB_HOST and a proxied git ssh", ctx do
      assert {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      env = Map.new(request.env)

      assert env["HTTPS_PROXY"] =~ ~r{^http://127\.0\.0\.1:\d+$}
      assert env["NO_PROXY"]
      assert env["GIT_SSH_COMMAND"] =~ "ProxyCommand socat"
      assert env["ARB_HOST"] =~ ~r{^http://127\.0\.0\.1:\d+$}
    end

    test "an oversized prompt's temp file is carried read-only", ctx do
      tmp = Path.join(ctx.dir, "arb_prompt_123.txt")
      File.write!(tmp, "x")
      argv = ["sh", "-c", "script", "sh", tmp, "claude", "--print"]

      assert {:ok, request} = ContainerSpawn.prepare([argv: argv] ++ ctx.opts)
      assert request.prompt_paths == [tmp]
    end

    test "refuses a checkout that is not a private clone", ctx do
      plain = Path.join(ctx.dir, "plain")
      File.mkdir_p!(plain)

      assert {:error, {:not_a_private_clone, ^plain, _}} =
               ContainerSpawn.prepare(Keyword.put(ctx.opts, :worktree_path, plain))

      assert {:error, {:not_a_private_clone, _, _}} =
               ContainerSpawn.prepare(Keyword.put(ctx.opts, :worktree_path, ctx.checkout))
    end

    test "refuses a policy that is not podman", ctx do
      assert {:error, {:not_a_container_backend, _}} =
               ContainerSpawn.prepare(Keyword.put(ctx.opts, :policy, SecurityPolicy.base()))
    end

    test "refuses when the egress run cannot start, never falling back to the host network",
         ctx do
      opts = Keyword.put(ctx.opts, :egress, fn _ -> {:error, :listener_down} end)
      assert {:error, {:egress_unavailable, :listener_down}} = ContainerSpawn.prepare(opts)
    end

    test "refuses when the host cannot run containers or bridge sockets", ctx do
      Application.put_env(:arbiter, :worker_container_available, false)
      assert {:error, {:podman_unavailable, _}} = ContainerSpawn.prepare(ctx.opts)

      Application.put_env(:arbiter, :worker_container_available, true)
      Application.put_env(:arbiter, :worker_container_network_available, false)
      assert {:error, {:podman_network_unavailable, _}} = ContainerSpawn.prepare(ctx.opts)
    end

    test "refuses when there is no claude to mount", ctx do
      opts = Keyword.merge(ctx.opts, claude_path: nil, find_executable: fn _ -> nil end)
      assert {:error, {:executable_not_found, "claude"}} = ContainerSpawn.prepare(opts)
    end

    test "a host with no arb still gets a worker, minus the CLI", ctx do
      opts = Keyword.merge(ctx.opts, arb_path: nil, find_executable: fn _ -> nil end)
      assert {:ok, request} = ContainerSpawn.prepare(opts)
      assert [{_, "/opt/arbiter/cli/claude"}] = request.cli_mounts
    end

    test "needs the run's temp dir", ctx do
      assert {:error, :no_run_tmp_dir} =
               ContainerSpawn.prepare(Keyword.delete(ctx.opts, :tmp_dir))
    end
  end

  describe "wrap_port/1" do
    setup ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      %{request: request}
    end

    test "runs the command in a network-less container with only the named mounts", ctx do
      env = [
        {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-secret-value"},
        {"ARB_TOKEN", "arb-secret-token"},
        {"ARB_WORKER_BEAD_ID", "bd-p7test"},
        {"SOME_INHERITED_THING", false}
      ]

      assert {:ok, wrapped} = ContainerSpawn.wrap_port(port_args(ctx, ctx.request, env))
      assert wrapped.exec == "/usr/bin/podman"
      assert [podman, "run" | _] = wrapped.argv
      assert podman == "/usr/bin/podman"

      argv = wrapped.argv
      assert "--network=none" in argv
      assert "--read-only" in argv
      assert "--cap-drop=all" in argv
      assert "--userns=keep-id" in argv
      assert "label=disable" in argv
      assert ["--name", ctx.request.name] == Enum.slice(argv, 2, 2)

      mount_specs = mounts(argv)
      assert "#{ctx.clone}:#{ctx.clone}:rw" in mount_specs
      assert "#{ctx.real_claude}:/opt/arbiter/cli/claude:ro" in mount_specs
      assert "#{ctx.arb}:/opt/arbiter/cli/arb:ro" in mount_specs
      assert "#{ctx.proxy}:#{ctx.proxy}:ro" in mount_specs
      assert "#{ctx.bridge}:#{ctx.bridge}:ro" in mount_specs
      assert "#{ctx.tmp_dir}:#{ctx.tmp_dir}:rw" in mount_specs
      assert "#{ctx.request.home}:#{ctx.request.home}:rw" in mount_specs

      # Nothing of the operator's home is mounted, and every mount source is
      # one the spec named: the clone, its objects, the run dirs, the CLIs and
      # the sockets.
      home = System.user_home!()
      refute Enum.any?(mount_specs, &String.contains?(&1, Path.join(home, ".ssh")))
      refute Enum.any?(mount_specs, &String.contains?(&1, "/run/user"))
      refute Enum.any?(mount_specs, &String.contains?(&1, ".arbiter"))

      # The image, then the in-container socat wrapper around the inner argv.
      {_, after_image} = Enum.split_while(argv, &(&1 != @image))
      assert [@image, "sh", "-c", script, "sh", "socat" | rest] = after_image
      assert script =~ "TCP-LISTEN"
      assert "--" in rest
      assert ContainerSpawn.claude_path() in rest
      assert "the prompt" in rest
    end

    test "no secret reaches argv; the values travel in the client's env as -e NAME", ctx do
      env = [
        {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-secret-value"},
        {"ARB_TOKEN", "arb-secret-token"},
        {"GH_TOKEN", "gh-secret-value"},
        {"ANTHROPIC_API_KEY", false}
      ]

      assert {:ok, wrapped} = ContainerSpawn.wrap_port(port_args(ctx, ctx.request, env))

      joined = Enum.join(wrapped.argv, "\0")
      refute joined =~ "oauth-secret-value"
      refute joined =~ "arb-secret-token"
      refute joined =~ "gh-secret-value"

      for name <- ~w(CLAUDE_CODE_OAUTH_TOKEN ARB_TOKEN GH_TOKEN) do
        assert has_inherit?(wrapped.argv, name), "#{name} must be passed as -e NAME"
      end

      assert wrapped.env |> Map.new() |> Map.take(~w(CLAUDE_CODE_OAUTH_TOKEN ARB_TOKEN GH_TOKEN)) ==
               %{
                 "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-secret-value",
                 "ARB_TOKEN" => "arb-secret-token",
                 "GH_TOKEN" => "gh-secret-value"
               }

      # An unset is for a child that inherits; the container inherits nothing,
      # and the client keeps its own environment.
      refute Enum.any?(wrapped.env, fn {_, v} -> v == false end)
      refute has_inherit?(wrapped.argv, "ANTHROPIC_API_KEY")
    end

    test "names that steer the client are literals, not inherited", ctx do
      env = [{"PATH", "/custom/bin"}, {"XDG_RUNTIME_DIR", "/run/user/9"}]
      assert {:ok, wrapped} = ContainerSpawn.wrap_port(port_args(ctx, ctx.request, env))

      assert has_literal?(wrapped.argv, "PATH=/custom/bin")
      assert has_literal?(wrapped.argv, "XDG_RUNTIME_DIR=/run/user/9")
      assert has_literal?(wrapped.argv, "HTTPS_PROXY=http://127.0.0.1:#{ctx.proxy_port}")
      refute Enum.any?(wrapped.env, fn {k, _} -> k in ~w(PATH XDG_RUNTIME_DIR HTTPS_PROXY) end)
      assert has_literal?(wrapped.argv, "HOME=#{ctx.request.home}")
    end

    test "CLAUDE_CONFIG_DIR is the run's own dir on both sides", ctx do
      args = port_args(ctx, ctx.request, [{"CLAUDE_CONFIG_DIR", "/the/install/wide/dir"}])
      assert {"CLAUDE_CONFIG_DIR", ctx.request.config_dir} in args.env
      refute {"CLAUDE_CONFIG_DIR", "/the/install/wide/dir"} in args.env

      assert {:ok, wrapped} = ContainerSpawn.wrap_port(args)
      assert {"CLAUDE_CONFIG_DIR", ctx.request.config_dir} in wrapped.env
    end

    test "a spawn without a sandbox request is returned untouched", ctx do
      args = %{exec: "/bin/sh", argv: ["sh", "-c", "true"], cd: ctx.clone, env: []}
      assert ContainerSpawn.wrap_port(args) == {:ok, args}
    end

    test "a bridge socket that has vanished refuses the spawn", ctx do
      File.rm!(ctx.bridge)

      assert {:error, {:egress_socket_missing, _}} =
               ContainerSpawn.wrap_port(port_args(ctx, ctx.request))
    end

    test "a tampered clone is refused at prepare time", ctx do
      File.write!(Path.join(ctx.clone, ".git/commondir"), "/elsewhere\n")

      assert {:error, {:not_a_private_clone, _, {:tampered, _}}} =
               ContainerSpawn.prepare(ctx.opts)
    end
  end

  describe "teardown/1" do
    test "removes the container by name, and is a no-op for any other spawn" do
      test_pid = self()

      Application.put_env(:arbiter, :worker_container_runner, fn cmd, args, _opts ->
        send(test_pid, {:ran, cmd, args})
        {"", 0}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :worker_container_runner) end)

      assert :ok = ContainerSpawn.teardown(%{sandbox: %{name: "arb-bd-x-1234"}})

      assert_received {:ran, _podman,
                       ["rm", "--force", "--ignore", "--time", "0", "arb-bd-x-1234"]}

      assert :ok = ContainerSpawn.teardown(%{exec: "x"})
      assert :ok = ContainerSpawn.teardown(nil)
      refute_received {:ran, _, _}
    end
  end

  describe "through ClaudeSession and the Worker" do
    # A stand-in `podman`: drops everything up to the `--`, applies `-e NAME=v`
    # literals, skips the image and runs the rest on the host. The real
    # container half is the :podman test.
    defp fake_podman!(dir) do
      path = Path.join(dir, "podman")

      File.write!(path, ~S"""
      #!/bin/sh
      printf '%s\n' "$@" > "$FAKE_PODMAN_LOG"
      shift  # run
      while [ "$1" != "--" ]; do
        case "$1" in
          -e) case "$2" in *=*) export "$2";; esac; shift 2;;
          -w) cd "$2" || exit 97; shift 2;;
          *) shift;;
        esac
      done
      shift  # --
      shift  # image
      # A pid namespace of its own, as in the container: when the command
      # exits, so does the `socat` bridge it started.
      exec unshare --user --map-root-user --pid --fork --kill-child "$@"
      """)

      File.chmod!(path, 0o755)
      path
    end

    # Needs `socat` and an unprivileged pid namespace (some CI hosts refuse
    # one); the stand-in podman is only as faithful as that.
    @namespaces? System.find_executable("socat") != nil and
                   System.find_executable("unshare") != nil and
                   match?(
                     {_, 0},
                     System.cmd("unshare", ~w(--user --map-root-user --pid --fork true),
                       stderr_to_stdout: true
                     )
                   )

    if @namespaces? do
      test "a podman policy wraps the spawn, keeps the sandbox for respawns and tears down",
           ctx do
        log = Path.join(ctx.dir, "podman.log")
        System.put_env("FAKE_PODMAN_LOG", log)
        on_exit(fn -> System.delete_env("FAKE_PODMAN_LOG") end)

        test_pid = self()

        Application.put_env(:arbiter, :worker_container_runner, fn cmd, args, _opts ->
          send(test_pid, {:ran, cmd, args})
          {"", 0}
        end)

        on_exit(fn -> Application.delete_env(:arbiter, :worker_container_runner) end)

        task_id = "bd-p7e2e-#{System.unique_integer([:positive])}"
        {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")
        Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> task_id)

        inner = [
          "sh",
          "-c",
          ~s(echo "proxy=$HTTPS_PROXY"; echo "bead=$ARB_WORKER_BEAD_ID"; echo finished)
        ]

        assert {:ok, port} =
                 ClaudeSession.start(
                   [
                     owner: pid,
                     worktree_path: ctx.clone,
                     command: inner,
                     env: [{"ARB_WORKER_BEAD_ID", "bd-p7e2e"}],
                     security: podman_policy(),
                     provider: "claude",
                     podman: fake_podman!(ctx.dir)
                   ] ++
                     Keyword.take(ctx.opts, [:arb_token, :image, :claude_path, :arb_path, :egress])
                 )

        assert is_port(port)

        assert_receive {:worker_exited, ^task_id, 0}, 10_000
        assert_received {:worker_output, ^task_id, "proxy=http://127.0.0.1:" <> _}
        bead = "bead=#{task_id}"
        assert_received {:worker_output, ^task_id, ^bead}

        args = File.read!(log)
        assert args =~ "--network=none"
        assert args =~ ctx.clone

        # The stashed spawn keeps the request, so a nudge or resume re-wraps.
        assert %{sandbox: %{name: name}} = Worker.state(pid).meta.claude_spawn
        assert String.starts_with?(name, Container.name_for("bd-p7e2e"))

        GenServer.stop(pid, :normal)
        assert_received {:ran, _podman, ["rm", "--force", "--ignore", "--time", "0", ^name]}
      end
    end

    test "a podman policy whose checkout is not a private clone fails the start", ctx do
      {:ok, pid} =
        Worker.start(task_id: "bd-p7bad-#{System.unique_integer([:positive])}", repo: "arbiter")

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert {:error, {:not_a_private_clone, _, _}} =
               ClaudeSession.start(
                 [
                   owner: pid,
                   worktree_path: ctx.checkout,
                   command: ["sh", "-c", "echo should-not-run"],
                   security: podman_policy()
                 ] ++ Keyword.take(ctx.opts, [:image, :claude_path, :arb_path, :egress])
               )
    end

    test "a bwrap policy leaves the spawn exactly as it was", ctx do
      {:ok, pid} =
        Worker.start(task_id: "bd-p7bwrap-#{System.unique_integer([:positive])}", repo: "arbiter")

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      assert {:ok, _port} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: ctx.dir,
                 command: ["sh", "-c", "echo hi"],
                 security: SecurityPolicy.base()
               )

      refute Map.has_key?(Worker.state(pid).meta.claude_spawn, :sandbox)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp has_inherit?(argv, name),
    do: Enum.chunk_every(argv, 2, 1) |> Enum.any?(&(&1 == ["-e", name]))

  defp has_literal?(argv, pair), do: has_inherit?(argv, pair)
end
