defmodule Arbiter.Worker.ContainerTest do
  @moduledoc """
  bd-bu4ye2 (P3): the pure podman argv builder, spec validation, teardown by
  name and the status gate. Every podman call is stubbed through `:runner`, so
  this runs on a host with no podman. The real-podman tests live in
  `container_podman_test.exs` (`@moduletag :podman`).
  """

  # async: false — toggles application env (availability overrides).
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Container
  alias Arbiter.Worker.Sandbox

  @image "localhost/arb-dev/beam:abc123"

  defp spec(overrides) do
    Map.merge(
      %{
        podman: "/usr/bin/podman",
        image: @image,
        name: "arb-run1",
        worktree: "/work/tree"
      },
      overrides
    )
  end

  defp argv(overrides \\ %{}, command \\ ["claude", "--print"]),
    do: Container.argv(spec(overrides), command)

  # The flags before the `--` boundary (everything podman parses).
  defp flags(argv), do: argv |> Enum.take_while(&(&1 != "--"))

  defp pairs(argv, flag),
    do:
      argv
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(&(hd(&1) == flag))
      |> Enum.map(&List.last/1)

  describe "argv/2: shape" do
    test "starts with `podman run`, names the container, and ends with `-- image command`" do
      argv = argv()
      assert Enum.take(argv, 2) == ["/usr/bin/podman", "run"]
      assert pairs(argv, "--name") == ["arb-run1"]
      assert Enum.take(argv, -4) == ["--", @image, "claude", "--print"]
    end

    test "has exactly one `--` boundary, before the image, even if the command has its own" do
      argv = argv(%{}, ["claude", "--", "prompt"])

      [before, after_] = [
        Enum.find_index(argv, &(&1 == "--")),
        Enum.find_index(argv, &(&1 == @image))
      ]

      assert before + 1 == after_
      assert Enum.count(flags(argv), &(&1 == "--")) == 0
    end

    test "is pure: the same spec gives the same argv" do
      assert argv() == argv()
    end

    test "never pulls at spawn time" do
      assert "--pull=never" in flags(argv())
    end
  end

  describe "argv/2: lifecycle flags (kill semantics, design §6.4)" do
    test "--init and --rm so SIGTERM stops PID 1 and the container is removed" do
      flags = flags(argv())
      assert "--init" in flags
      assert "--rm" in flags
    end
  end

  describe "argv/2: user namespace" do
    test "maps the host uid with --userns=keep-id and sets no other identity" do
      flags = flags(argv())
      assert "--userns=keep-id" in flags
      refute "--user" in flags
      refute "--privileged" in flags
      refute Enum.any?(flags, &String.starts_with?(&1, "--uidmap"))
    end
  end

  describe "argv/2: read-only root" do
    test "--read-only with tmpfs for /tmp and /dev/shm and nothing else writable" do
      argv = argv()
      assert "--read-only" in flags(argv)
      tmpfs = pairs(argv, "--tmpfs")
      assert Enum.any?(tmpfs, &String.starts_with?(&1, "/tmp"))
      assert Enum.any?(tmpfs, &String.starts_with?(&1, "/dev/shm"))
      assert pairs(argv, "-v") |> Enum.reject(&String.contains?(&1, "/work/tree")) == []
    end

    test "extra tmpfs paths are added" do
      assert Enum.any?(
               pairs(argv(%{tmpfs: ["/var/cache"]}), "--tmpfs"),
               &String.starts_with?(&1, "/var/cache:")
             )
    end
  end

  describe "argv/2: dropped capabilities" do
    test "drops every capability and forbids privilege gain" do
      argv = argv()
      assert "--cap-drop=all" in flags(argv)
      assert pairs(argv, "--security-opt") |> Enum.member?("no-new-privileges")
      refute Enum.any?(flags(argv), &String.starts_with?(&1, "--cap-add"))
    end
  end

  describe "argv/2: env allowlist" do
    test "no env is passed unless asked for" do
      assert pairs(argv(), "-e") == []
      refute "--env-host" in flags(argv())
    end

    test "inherit_env names become `-e NAME` with no value on argv" do
      argv = argv(%{inherit_env: ["CLAUDE_CODE_OAUTH_TOKEN", "ARB_TOKEN"]})
      assert pairs(argv, "-e") == ["CLAUDE_CODE_OAUTH_TOKEN", "ARB_TOKEN"]
    end

    test "literal env pairs become `-e NAME=value`" do
      assert pairs(argv(%{env: [{"ARB_HOST", "127.0.0.1:4848"}]}), "-e") == [
               "ARB_HOST=127.0.0.1:4848"
             ]
    end

    test "HOME is exported when a home is mounted" do
      argv = argv(%{home: "/work/home"})
      assert "HOME=/work/home" in pairs(argv, "-e")
    end
  end

  describe "argv/2: mounts" do
    test "the worktree is bound at the same path, read-write, and is the cwd" do
      argv = argv()
      assert "/work/tree:/work/tree:rw,Z" in pairs(argv, "-v")
      assert pairs(argv, "-w") == ["/work/tree"]
    end

    test "a read-only worktree is bound ro" do
      argv = argv(%{worktree_readonly: true})
      assert "/work/tree:/work/tree:ro" in pairs(argv, "-v")
    end

    test "the shared objects directory is an overlay mount (no relabel of the host)" do
      argv = argv(%{objects: "/repo/.git/objects"})
      assert "/repo/.git/objects:/repo/.git/objects:O" in pairs(argv, "-v")
    end

    test "home is a private read-write mount" do
      assert "/work/home:/work/home:rw,Z" in pairs(argv(%{home: "/work/home"}), "-v")
    end

    test "writable_paths are plain rw binds, never relabelled" do
      argv = argv(%{writable_paths: ["/var/arbiter/tmp"]})
      assert "/var/arbiter/tmp:/var/arbiter/tmp:rw" in pairs(argv, "-v")
    end

    test "nothing outside the declared set is mounted" do
      argv = argv(%{home: "/work/home", objects: "/repo/.git/objects"})

      assert Enum.sort(pairs(argv, "-v") |> Enum.map(&(&1 |> String.split(":") |> hd()))) ==
               ["/repo/.git/objects", "/work/home", "/work/tree"]
    end

    # bd-4wy1w1 (P5): a private clone's `.git` is a mount point of its own (so
    # it cannot be renamed away or replaced by a `gitdir:` file), with config,
    # hooks, commondir and alternates read-only on top: host-side git keeps
    # running in this checkout after the container has had it.
    test "a private clone's gitdir is its own private mount, after the worktree" do
      argv = argv(%{git_dir: "/work/tree/.git"})
      mounts = pairs(argv, "-v")

      assert "/work/tree/.git:/work/tree/.git:rw,Z" in mounts

      assert Enum.find_index(mounts, &String.starts_with?(&1, "/work/tree:")) <
               Enum.find_index(mounts, &String.starts_with?(&1, "/work/tree/.git:"))
    end

    test "readonly_paths are bound ro, after every writable mount" do
      ro = ["/work/tree/.git/config", "/work/tree/.git/hooks"]
      argv = argv(%{git_dir: "/work/tree/.git", writable_paths: ["/var/x"], readonly_paths: ro})
      mounts = pairs(argv, "-v")

      assert "/work/tree/.git/config:/work/tree/.git/config:ro" in mounts
      assert "/work/tree/.git/hooks:/work/tree/.git/hooks:ro" in mounts

      last_writable =
        mounts |> Enum.with_index() |> Enum.filter(&(elem(&1, 0) =~ ~r/:rw/)) |> List.last()

      first_ro =
        Enum.find_index(mounts, &(&1 == "/work/tree/.git/config:/work/tree/.git/config:ro"))

      assert elem(last_writable, 1) < first_ro
    end

    test "with the label disabled the gitdir is plain rw too" do
      argv = argv(%{git_dir: "/work/tree/.git", bridges: ["/run/arb/proxy.sock"]})
      assert "/work/tree/.git:/work/tree/.git:rw" in pairs(argv, "-v")
    end
  end

  describe "argv/2: network and label policy (design §5.3)" do
    test "network is none by default and the label stays enforced" do
      argv = argv()
      assert "--network=none" in flags(argv)
      refute "label=disable" in pairs(argv, "--security-opt")
    end

    test "network: :pasta is explicit" do
      assert "--network=pasta" in flags(argv(%{network: :pasta}))
    end

    test "bridges mount each socket read-only and disable the SELinux label" do
      argv = argv(%{bridges: ["/run/arb/proxy.sock", "/run/arb/arb.sock"]})
      assert "label=disable" in pairs(argv, "--security-opt")
      assert Enum.count(pairs(argv, "--security-opt"), &(&1 == "label=disable")) == 1
      assert "/run/arb/proxy.sock:/run/arb/proxy.sock:ro" in pairs(argv, "-v")
      assert "/run/arb/arb.sock:/run/arb/arb.sock:ro" in pairs(argv, "-v")
      assert "--network=none" in flags(argv)
    end

    test "with the label disabled no mount asks for a relabel" do
      argv = argv(%{bridges: ["/run/arb/proxy.sock"], home: "/work/home"})
      refute Enum.any?(pairs(argv, "-v"), &(&1 =~ ~r/[,:][zZ]$/))
      assert "/work/tree:/work/tree:rw" in pairs(argv, "-v")
    end

    test "without bridges the label is never disabled" do
      for overrides <- [%{}, %{home: "/h"}, %{network: :pasta}, %{objects: "/o"}] do
        refute "label=disable" in pairs(argv(overrides), "--security-opt")
      end
    end
  end

  describe "argv/2: stdin" do
    test "-i only when interactive" do
      refute "-i" in flags(argv())
      assert "-i" in flags(argv(%{interactive: true}))
    end
  end

  describe "wrap/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "container-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp opts(dir, extra \\ []) do
      Keyword.merge(
        [worktree: dir, name: "arb-t1", image: @image, podman: "/usr/bin/podman"],
        extra
      )
    end

    test "builds the same argv as argv/2 from keyword options", %{dir: dir} do
      assert {:ok, argv} =
               Container.wrap(
                 ["echo", "hi"],
                 opts(dir, home: dir <> "/h", inherit_env: ["ARB_TOKEN"])
               )

      assert pairs(argv, "--name") == ["arb-t1"]
      assert "ARB_TOKEN" in pairs(argv, "-e")
      assert Enum.take(argv, -3) == [@image, "echo", "hi"]
    end

    test "requires a worktree, an image and a name", %{dir: dir} do
      assert {:error, :no_worktree} = Container.wrap(["x"], Keyword.delete(opts(dir), :worktree))
      assert {:error, :no_image} = Container.wrap(["x"], Keyword.delete(opts(dir), :image))

      assert {:error, :no_container_name} =
               Container.wrap(["x"], Keyword.delete(opts(dir), :name))
    end

    test "container names must carry the arb- prefix and be a safe token", %{dir: dir} do
      for bad <- [
            "run1",
            "arb-",
            "arb-a b",
            "arb-a/b",
            "arb-;rm",
            "arb-" <> String.duplicate("a", 80)
          ] do
        assert {:error, {:bad_container_name, ^bad}} = Container.wrap(["x"], opts(dir, name: bad))
      end

      assert Container.name_for("0abc.def_1") == "arb-0abc.def_1"
    end

    test "env names are validated", %{dir: dir} do
      assert {:error, {:bad_env_name, "A B"}} =
               Container.wrap(["x"], opts(dir, inherit_env: ["A B"]))

      assert {:error, {:bad_env_name, "A=B"}} =
               Container.wrap(["x"], opts(dir, env: [{"A=B", "v"}]))

      assert {:error, {:bad_env_value, "A"}} =
               Container.wrap(["x"], opts(dir, env: [{"A", "v\0"}]))
    end

    test "mount paths must be absolute and free of mount-option syntax", %{dir: dir} do
      assert {:error, {:bad_mount_path, "rel/path"}} =
               Container.wrap(["x"], opts(dir, writable_paths: ["rel/path"]))

      assert {:error, {:bad_mount_path, "/a:b"}} =
               Container.wrap(["x"], opts(dir, writable_paths: ["/a:b"]))
    end

    test "bridges require network none, and a missing socket is refused", %{dir: dir} do
      sock = Path.join(dir, "p.sock")
      File.write!(sock, "")

      assert {:error, :bridges_require_network_none} =
               Container.wrap(["x"], opts(dir, bridges: [sock], network: :pasta))

      assert {:error, {:egress_socket_missing, "/nope/p.sock"}} =
               Container.wrap(["x"], opts(dir, bridges: ["/nope/p.sock"]))

      assert {:ok, argv} = Container.wrap(["x"], opts(dir, bridges: [sock]))
      assert "label=disable" in pairs(argv, "--security-opt")
    end

    # Podman creates a missing bind source, which for a guard file would leave
    # an empty `commondir` on the host that breaks every later git command.
    test "readonly_paths and git_dir must already exist", %{dir: dir} do
      git_dir = Path.join(dir, ".git")
      config = Path.join(git_dir, "config")
      File.mkdir_p!(git_dir)
      File.write!(config, "")
      missing = Path.join(git_dir, "commondir")

      assert {:error, {:readonly_path_missing, ^missing}} =
               Container.wrap(
                 ["x"],
                 opts(dir, git_dir: git_dir, readonly_paths: [config, missing])
               )

      assert {:error, {:bad_mount_path, "rel/.git"}} =
               Container.wrap(["x"], opts(dir, git_dir: "rel/.git"))

      assert {:error, {:git_dir_missing, "/nope/.git"}} =
               Container.wrap(["x"], opts(dir, git_dir: "/nope/.git"))

      assert {:ok, argv} =
               Container.wrap(["x"], opts(dir, git_dir: git_dir, readonly_paths: [config]))

      assert "#{config}:#{config}:ro" in pairs(argv, "-v")
      assert "#{git_dir}:#{git_dir}:rw,Z" in pairs(argv, "-v")
    end

    test "an unknown network mode is refused", %{dir: dir} do
      assert {:error, {:bad_network, :host}} = Container.wrap(["x"], opts(dir, network: :host))
    end

    test "podman missing from the host is an error, not an unsandboxed argv", %{dir: dir} do
      assert {:error, :podman_not_found} =
               Container.wrap(["x"], opts(dir, podman: nil, find_executable: fn _ -> nil end))
    end

    test "an empty command is refused", %{dir: dir} do
      assert {:error, :empty_command} = Container.wrap([], opts(dir))
    end
  end

  describe "teardown by name" do
    test "removes the container by name with force, ignore and no grace period" do
      test_pid = self()

      runner = fn cmd, args, _ ->
        send(test_pid, {:ran, cmd, args})
        {"", 0}
      end

      assert :ok = Container.stop("arb-run1", runner: runner, podman: "/usr/bin/podman")

      assert_received {:ran, "/usr/bin/podman",
                       ["rm", "--force", "--ignore", "--time", "0", "arb-run1"]}
    end

    test "teardown/1 takes the name, or the run map wrap callers keep" do
      test_pid = self()
      runner = fn cmd, args, _ -> send(test_pid, {:ran, cmd, args}) && {"", 0} end
      Application.put_env(:arbiter, :worker_container_runner, runner)
      on_exit(fn -> Application.delete_env(:arbiter, :worker_container_runner) end)

      assert :ok = Container.teardown("arb-a")
      assert :ok = Container.teardown(%{name: "arb-b"})
      assert_received {:ran, _, ["rm" | rest_a]}
      assert List.last(rest_a) == "arb-a"
      assert_received {:ran, _, ["rm" | rest_b]}
      assert List.last(rest_b) == "arb-b"
    end

    test "never removes a container Arbiter did not name" do
      test_pid = self()
      runner = fn cmd, args, _ -> send(test_pid, {:ran, cmd, args}) && {"", 0} end

      assert {:error, {:bad_container_name, "postgres"}} =
               Container.stop("postgres", runner: runner)

      assert {:error, {:bad_container_name, "--all"}} = Container.stop("--all", runner: runner)
      refute_received {:ran, _, _}
    end

    test "a failing podman is reported by stop/2 and swallowed by teardown/1" do
      runner = fn _, _, _ -> {"boom", 125} end
      assert {:error, {:podman_rm_failed, 125, "boom"}} = Container.stop("arb-x", runner: runner)

      Application.put_env(:arbiter, :worker_container_runner, runner)
      on_exit(fn -> Application.delete_env(:arbiter, :worker_container_runner) end)

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Container.teardown("arb-x") end)
      assert log =~ "arb-x"
    end

    test "teardown/1 of a ref it does not understand is a no-op" do
      assert :ok = Container.teardown(make_ref())
      assert :ok = Container.teardown(nil)
    end
  end

  describe "run/2: a podman-backed spawn tears down on every terminal outcome" do
    setup do
      dir = Path.join(System.tmp_dir!(), "container-run-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp recording_runner(test_pid, on_run) do
      fn cmd, args, run_opts ->
        send(test_pid, {:ran, cmd, args})

        case args do
          ["run" | _] -> on_run.(run_opts)
          ["rm" | _] -> {"", 0}
        end
      end
    end

    defp run_opts(dir, runner, extra \\ []) do
      [worktree: dir, name: "arb-r1", image: @image, podman: "/usr/bin/podman", runner: runner] ++
        extra
    end

    defp removed?(name) do
      receive do
        {:ran, _, ["rm" | rest]} -> List.last(rest) == name or removed?(name)
      after
        0 -> false
      end
    end

    test "success: returns the output and removes the container by name", %{dir: dir} do
      runner = recording_runner(self(), fn _ -> {"done\n", 0} end)
      assert {:ok, {"done\n", 0}} = Container.run(["echo"], run_opts(dir, runner))
      assert removed?("arb-r1")
    end

    test "non-zero exit: still returned, still removed", %{dir: dir} do
      runner = recording_runner(self(), fn _ -> {"bad\n", 3} end)
      assert {:ok, {"bad\n", 3}} = Container.run(["false"], run_opts(dir, runner))
      assert removed?("arb-r1")
    end

    test "a runner that raises: reported as an error, still removed", %{dir: dir} do
      runner = recording_runner(self(), fn _ -> raise "kaboom" end)
      assert {:error, {:crashed, message}} = Container.run(["x"], run_opts(dir, runner))
      assert message =~ "kaboom"
      assert removed?("arb-r1")
    end

    test "a timeout kills the spawn and removes the container", %{dir: dir} do
      test_pid = self()

      runner =
        recording_runner(test_pid, fn _ ->
          send(test_pid, {:running, self()})
          Process.sleep(:infinity)
        end)

      assert {:error, :timeout} = Container.run(["sleep"], run_opts(dir, runner, timeout: 50))
      assert_received {:running, pid}
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert removed?("arb-r1")
    end

    test "a refused wrap never starts anything, and removes nothing", %{dir: dir} do
      test_pid = self()
      runner = fn cmd, args, _ -> send(test_pid, {:ran, cmd, args}) && {"", 0} end

      assert {:error, :no_image} =
               Container.run(["x"], run_opts(dir, runner) |> Keyword.delete(:image))

      refute_received {:ran, _, _}
    end

    test "secret_env reaches the process env but never the argv", %{dir: dir} do
      test_pid = self()

      runner =
        recording_runner(test_pid, fn run_opts ->
          send(test_pid, {:env, Keyword.get(run_opts, :env)})
          {"", 0}
        end)

      assert {:ok, _} =
               Container.run(
                 ["x"],
                 run_opts(dir, runner, secret_env: [{"CLAUDE_CODE_OAUTH_TOKEN", "sk-secret"}])
               )

      assert_received {:env, env}
      assert {"CLAUDE_CODE_OAUTH_TOKEN", "sk-secret"} in env
      assert_received {:ran, _, ["run" | args]}
      assert "CLAUDE_CODE_OAUTH_TOKEN" in pairs(args, "-e")
      refute Enum.any?(args, &String.contains?(&1, "sk-secret"))
    end
  end

  describe "Sandbox behaviour" do
    test "declares the behaviour and implements every callback" do
      assert Sandbox in (Container.module_info(:attributes)
                         |> Keyword.get_values(:behaviour)
                         |> List.flatten())

      for {fun, arity} <- Sandbox.behaviour_info(:callbacks) do
        assert function_exported?(Container, fun, arity), "Container.#{fun}/#{arity} missing"
      end
    end

    test "status/0 and network_status/0 honour the availability overrides" do
      prev_a = Application.get_env(:arbiter, :worker_container_available)
      prev_n = Application.get_env(:arbiter, :worker_container_network_available)

      on_exit(fn ->
        restore(:worker_container_available, prev_a)
        restore(:worker_container_network_available, prev_n)
      end)

      Application.put_env(:arbiter, :worker_container_available, true)
      assert Container.status() == :ok
      Application.put_env(:arbiter, :worker_container_available, false)
      assert Container.status() == {:error, :disabled_by_config}

      Application.put_env(:arbiter, :worker_container_network_available, true)
      assert Container.network_status() == :ok
      Application.put_env(:arbiter, :worker_container_network_available, false)
      assert Container.network_status() == {:error, :disabled_by_config}
    end
  end

  defp restore(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore(key, value), do: Application.put_env(:arbiter, key, value)
end
