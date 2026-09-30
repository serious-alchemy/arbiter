defmodule Arbiter.Worker.JailTest do
  @moduledoc """
  bd-5gvqgc: the bubblewrap write jail for agy `:strict` workers.

  The argv tests are pure. The `:bwrap` tests at the bottom run the real
  `bwrap` against a **stub** command (never agy) and are skipped, with the
  probe's reason, on a host where `Jail.probe/0` fails.
  """

  # async: false — toggles Application env (the availability override and the
  # probe root) and the cached probe result, which other tests read.
  use ExUnit.Case, async: false
  import Bitwise

  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.OsProcess

  # Evaluated when this file compiles, i.e. at `mix test` time on the host
  # that runs the suite, not when the app is built.
  @probe Jail.probe()

  setup do
    uniq = "#{System.pid()}-#{System.unique_integer([:positive])}"

    # NOT under System.tmp_dir!(): the jail mounts a private tmpfs over /tmp,
    # so a path there would read as writable inside the jail and the EROFS
    # assertions would be meaningless.
    base = Path.join(Arbiter.Config.Paths.scratch_root(), "jail-test-#{uniq}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base}
  end

  defp restore_env(key, prev) do
    if is_nil(prev),
      do: Application.delete_env(:arbiter, key),
      else: Application.put_env(:arbiter, key, prev)
  end

  # A main repo plus one linked worktree, the shape every worker runs in.
  defp git_repo!(base) do
    main = Path.join(base, "main")
    wt = Path.join(base, "wt")
    git!(base, ["init", "-q", main])

    git!(main, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "i"
    ])

    git!(main, ["worktree", "add", "-q", wt, "-b", "jail-test"])

    %{
      main: main,
      wt: wt,
      common: Path.join(main, ".git"),
      gitdir: Path.join(main, ".git/worktrees/wt")
    }
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp flag_pairs(argv, flag) do
    argv
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [f | _] -> f == flag end)
    |> Enum.map(fn [_, a, b] -> {a, b} end)
  end

  defp index_of(argv, triple),
    do: argv |> Enum.chunk_every(3, 1) |> Enum.find_index(&(&1 == triple))

  describe "argv/2" do
    @spec_linked %{
      bwrap: "/usr/bin/bwrap",
      worktree: "/w/wt",
      home: "/h/agy",
      git: %{
        common_dir: "/w/main/.git",
        git_dir: "/w/main/.git/worktrees/wt",
        worktrees_dir?: true,
        dot_git_file?: true
      },
      writable_paths: ["/opt/cache"],
      env: [{"HEX_HOME", "/h/agy/.arbiter-jail/hex"}]
    }

    test "read-only root, private /tmp and /dev/shm, fresh /dev and /proc" do
      argv = Jail.argv(@spec_linked, ["agy", "-p", "hi"])

      assert ["/usr/bin/bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc" | _] =
               argv

      assert ["--tmpfs", "/tmp"] in Enum.chunk_every(argv, 2, 1)
      assert ["--tmpfs", "/dev/shm"] in Enum.chunk_every(argv, 2, 1)
    end

    test "only the worktree, the agy HOME, the git common dir and writable_paths are writable" do
      argv = Jail.argv(@spec_linked, ["agy", "-p", "hi"])

      rw = flag_pairs(argv, "--bind") ++ flag_pairs(argv, "--bind-try")

      assert Enum.sort(Enum.map(rw, &elem(&1, 0))) ==
               Enum.sort([
                 "/w/wt",
                 "/h/agy",
                 "/w/main/.git",
                 "/w/main/.git/worktrees/wt",
                 "/opt/cache"
               ])

      assert Enum.all?(rw, fn {src, dst} -> src == dst end)
      # A missing operator path must not break the spawn.
      assert {"/opt/cache", "/opt/cache"} in flag_pairs(argv, "--bind-try")
    end

    test "hooks, config, sibling worktree gitdirs, commondir and the .git file are re-bound read-only after every writable bind" do
      argv = Jail.argv(@spec_linked, ["agy", "-p", "hi"])
      ro = flag_pairs(argv, "--ro-bind") ++ flag_pairs(argv, "--ro-bind-try")

      for path <- [
            "/w/main/.git/hooks",
            "/w/main/.git/config",
            "/w/main/.git/worktrees",
            "/w/main/.git/worktrees/wt/commondir",
            "/w/wt/.git"
          ] do
        assert {path, path} in ro, "expected #{path} read-only in #{inspect(argv)}"
      end

      last_rw =
        [
          ["--bind", "/w/wt", "/w/wt"],
          ["--bind", "/h/agy", "/h/agy"],
          ["--bind-try", "/opt/cache", "/opt/cache"],
          ["--bind", "/w/main/.git", "/w/main/.git"]
        ]
        |> Enum.map(&index_of(argv, &1))
        |> Enum.max()

      # The own gitdir is re-opened on top of the read-only worktrees/ dir,
      # and its commondir pointer is closed again on top of that.
      assert index_of(argv, ["--ro-bind", "/w/main/.git/hooks", "/w/main/.git/hooks"]) > last_rw
      assert index_of(argv, ["--ro-bind", "/w/main/.git/config", "/w/main/.git/config"]) > last_rw
      wts = index_of(argv, ["--ro-bind", "/w/main/.git/worktrees", "/w/main/.git/worktrees"])
      own = index_of(argv, ["--bind", "/w/main/.git/worktrees/wt", "/w/main/.git/worktrees/wt"])

      commondir =
        index_of(argv, [
          "--ro-bind",
          "/w/main/.git/worktrees/wt/commondir",
          "/w/main/.git/worktrees/wt/commondir"
        ])

      assert wts < own and own < commondir
      assert index_of(argv, ["--ro-bind", "/w/wt/.git", "/w/wt/.git"]) > last_rw
    end

    test "a main checkout (no linked worktree) binds the common dir without gitdir/commondir/.git-file binds" do
      spec = %{
        @spec_linked
        | worktree: "/w/main",
          git: %{
            common_dir: "/w/main/.git",
            git_dir: nil,
            worktrees_dir?: false,
            dot_git_file?: false
          }
      }

      argv = Jail.argv(spec, ["agy"])

      ro =
        Enum.map(flag_pairs(argv, "--ro-bind") ++ flag_pairs(argv, "--ro-bind-try"), &elem(&1, 0))

      assert "/w/main/.git/hooks" in ro
      assert "/w/main/.git/config" in ro
      refute "/w/main/.git/worktrees" in ro
      refute Enum.any?(ro, &String.ends_with?(&1, "commondir"))
      refute "/w/main/.git" in ro
    end

    test "sets HOME to the bound agy HOME and every toolchain env pair" do
      argv = Jail.argv(@spec_linked, ["agy"])
      setenv = flag_pairs(argv, "--setenv")

      assert {"HOME", "/h/agy"} in setenv
      assert {"HEX_HOME", "/h/agy/.arbiter-jail/hex"} in setenv
    end

    test "pid namespace, die-with-parent, new session, chdir, then the command after --" do
      argv = Jail.argv(@spec_linked, ["agy", "-p", "hi", "--model", "m"])

      {jail, ["--" | command]} = Enum.split_while(argv, &(&1 != "--"))
      assert command == ["agy", "-p", "hi", "--model", "m"]
      assert "--unshare-pid" in jail
      assert "--die-with-parent" in jail
      assert "--new-session" in jail
      assert ["--chdir", "/w/wt"] in Enum.chunk_every(jail, 2, 1)
      # No "-p" anywhere in the jail prefix: the adapter's splice_prompt/2
      # finds the prompt slot as the first "-p", with agy right before it.
      refute "-p" in jail
    end

    test "no home and no git: just the worktree" do
      argv = Jail.argv(%{bwrap: "bwrap", worktree: "/w"}, ["true"])
      rw = flag_pairs(argv, "--bind")

      assert rw == [{"/w", "/w"}]
      refute Enum.any?(flag_pairs(argv, "--setenv"), &(elem(&1, 0) == "HOME"))
    end

    test "worktree_readonly: true ro-binds the worktree instead of binding it writable (bd-3s82pf)" do
      spec = Map.put(@spec_linked, :worktree_readonly, true)
      argv = Jail.argv(spec, ["agy", "-p", "hi"])

      refute {"/w/wt", "/w/wt"} in flag_pairs(argv, "--bind")
      assert {"/w/wt", "/w/wt"} in flag_pairs(argv, "--ro-bind")
      # Everything else (agy HOME, git common dir) is unaffected.
      assert {"/h/agy", "/h/agy"} in flag_pairs(argv, "--bind")
      assert ["--chdir", "/w/wt"] in Enum.chunk_every(argv, 2, 1)
    end
  end

  describe "escape-vector masks (bd-7o08mj)" do
    @masks ["/run/user/4242", "/run/dbus", "/run/systemd/resolve"]

    defp masked(argv), do: for(["--tmpfs", p] <- Enum.chunk_every(argv, 2, 1), do: p)

    test "every jail mode masks the runtime dir, the system bus and resolved" do
      base = %{bwrap: "bwrap", worktree: "/w/wt", mask_paths: @masks}

      for spec <- [
            base,
            Map.put(base, :worktree_readonly, true),
            Map.put(base, :writable_paths, ["/opt/cache"])
          ] do
        argv = Jail.argv(spec, ["agy"])
        for m <- @masks, do: assert(m in masked(argv))
        # after the read-only root, before the command
        assert index_of_flag(argv, "/run/dbus") > index_of_flag(argv, "/")
      end
    end

    test "the default masks resolve the uid at runtime and only name existing paths" do
      {:ok, %{uid: uid}} = File.stat("/proc/self")
      masks = Jail.mask_paths()

      assert Enum.all?(masks, &File.dir?/1)
      assert Enum.all?(masks, &(&1 in ["/run/user/#{uid}", "/run/dbus", "/run/systemd/resolve"]))
      argv = Jail.argv(%{bwrap: "bwrap", worktree: "/w"}, ["true"])
      assert masked(argv) -- ["/tmp", "/dev/shm"] == masks
    end

    test "masking /run/systemd/resolve re-binds the plain resolv.conf files read-only" do
      argv =
        Jail.argv(%{bwrap: "bwrap", worktree: "/w", mask_paths: ["/run/systemd/resolve"]}, [
          "true"
        ])

      for f <- ["/run/systemd/resolve/stub-resolv.conf", "/run/systemd/resolve/resolv.conf"],
          File.regular?(f) do
        assert {f, f} in flag_pairs(argv, "--ro-bind")

        assert Enum.find_index(argv, &(&1 == f)) >
                 Enum.find_index(argv, &(&1 == "/run/systemd/resolve"))
      end
    end

    test "keyring_usable?/0 needs both the proxy binary and a session bus" do
      old_env = Application.fetch_env(:arbiter, :xdg_dbus_proxy)
      old_bus = System.get_env("DBUS_SESSION_BUS_ADDRESS")

      on_exit(fn ->
        case old_env do
          {:ok, v} -> Application.put_env(:arbiter, :xdg_dbus_proxy, v)
          :error -> Application.delete_env(:arbiter, :xdg_dbus_proxy)
        end

        if old_bus,
          do: System.put_env("DBUS_SESSION_BUS_ADDRESS", old_bus),
          else: System.delete_env("DBUS_SESSION_BUS_ADDRESS")
      end)

      sock = Path.join(System.tmp_dir!(), "kr-#{System.unique_integer([:positive])}.sock")
      File.write!(sock, "")
      on_exit(fn -> File.rm(sock) end)

      System.put_env("DBUS_SESSION_BUS_ADDRESS", "unix:path=" <> sock)
      Application.put_env(:arbiter, :xdg_dbus_proxy, "/bin/sh")
      assert Jail.keyring_usable?()

      Application.put_env(:arbiter, :xdg_dbus_proxy, nil)
      refute Jail.keyring_usable?()

      Application.put_env(:arbiter, :xdg_dbus_proxy, "/bin/sh")
      System.delete_env("DBUS_SESSION_BUS_ADDRESS")
      refute Jail.keyring_usable?()
    end

    test "a keyring socket is bound over the bus path after the masks, read-only" do
      argv =
        Jail.argv(
          %{
            bwrap: "bwrap",
            worktree: "/w",
            mask_paths: @masks,
            keyring_socket: "/host/proxy.sock",
            keyring_bus_path: "/run/user/4242/bus"
          },
          ["true"]
        )

      assert {"/host/proxy.sock", "/run/user/4242/bus"} in flag_pairs(argv, "--ro-bind")

      assert index_of(argv, ["--ro-bind", "/host/proxy.sock", "/run/user/4242/bus"]) >
               index_of_flag(argv, "/run/systemd/resolve")
    end

    defp index_of_flag(argv, path), do: Enum.find_index(argv, &(&1 == path))
  end

  describe "writable_paths/1" do
    test "expands ~, drops relative and blank entries, dedupes" do
      home = System.user_home!()

      assert Jail.writable_paths(["~/.cache/rebar3", "/opt/x/", "rel/path", "", "/opt/x", 42]) ==
               [Path.join(home, ".cache/rebar3"), "/opt/x"]
    end

    test "a bare ~ or / is refused: that would re-open the whole filesystem" do
      assert Jail.writable_paths(["~", "/", "/opt/ok"]) == ["/opt/ok"]
    end
  end

  describe "git/1" do
    test "resolves a linked worktree's common dir, gitdir and .git file", %{base: base} do
      %{wt: wt, common: common, gitdir: gitdir} = git_repo!(base)

      assert {:ok, git} = Jail.git(wt)
      assert git.common_dir == common
      assert git.git_dir == gitdir
      assert git.worktrees_dir?
      assert git.dot_git_file?
    end

    test "a main checkout has no separate gitdir", %{base: base} do
      %{main: main, common: common} = git_repo!(base)

      assert {:ok, git} = Jail.git(main)
      assert git.common_dir == common
      assert git.git_dir == nil
      refute git.dot_git_file?
    end

    test "creates a missing hooks dir so it can be bound read-only", %{base: base} do
      %{wt: wt, common: common} = git_repo!(base)
      File.rm_rf!(Path.join(common, "hooks"))

      assert {:ok, _} = Jail.git(wt)
      assert File.dir?(Path.join(common, "hooks"))
    end

    test "not a git repo: nil (no git binds)", %{base: base} do
      assert Jail.git(base) == {:ok, nil}
    end
  end

  describe "wrap/2" do
    setup %{base: base} do
      prev = Application.get_env(:arbiter, :worker_jail_bwrap)
      prev_ssh_path = Application.get_env(:arbiter, :worker_jail_ssh_config_path)
      prev_user_ssh_path = Application.get_env(:arbiter, :worker_jail_user_ssh_config_path)
      Application.put_env(:arbiter, :worker_jail_bwrap, "/usr/bin/bwrap-stub")

      # No system or user ssh config to mirror, so these tests don't touch
      # the real host's /etc/ssh, ~/.ssh or ~/.cache/arbiter (bd-5d5mrs's
      # GIT_SSH_COMMAND default is covered by its own describe block below).
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
        restore_env(:worker_jail_bwrap, prev)
        restore_env(:worker_jail_ssh_config_path, prev_ssh_path)
        restore_env(:worker_jail_user_ssh_config_path, prev_user_ssh_path)
      end)

      {:ok, home: Path.join(base, "agy-home")}
    end

    test "requires a worktree" do
      assert Jail.wrap(["agy"], []) == {:error, :no_worktree}
      assert Jail.wrap(["agy"], worktree: "") == {:error, :no_worktree}
    end

    test "worktree_readonly: true threads through to a --ro-bind of the worktree", %{base: base} do
      assert {:ok, argv} = Jail.wrap(["agy"], worktree: base, worktree_readonly: true)

      refute {base, base} in flag_pairs(argv, "--bind")
      assert {base, base} in flag_pairs(argv, "--ro-bind")
    end

    test "defaults to a writable worktree", %{base: base} do
      assert {:ok, argv} = Jail.wrap(["agy"], worktree: base)

      assert {base, base} in flag_pairs(argv, "--bind")
    end

    test "builds the full argv and prepares per-worker toolchain dirs in the agy HOME", %{
      base: base,
      home: home
    } do
      %{wt: wt, common: common} = git_repo!(base)

      assert {:ok, argv} =
               Jail.wrap(["agy", "-p", "x"],
                 worktree: wt,
                 home: home,
                 writable_paths: ["~/.cache/rebar3", "relative"]
               )

      assert ["/usr/bin/bwrap-stub" | _] = argv
      assert Enum.take(argv, -3) == ["agy", "-p", "x"]
      assert {common, common} in flag_pairs(argv, "--bind")

      assert {Path.join(System.user_home!(), ".cache/rebar3"),
              Path.join(System.user_home!(), ".cache/rebar3")} in flag_pairs(argv, "--bind-try")

      setenv = Map.new(flag_pairs(argv, "--setenv"))

      for var <- ~w(HEX_HOME MIX_HOME XDG_CACHE_HOME) do
        dir = Map.fetch!(setenv, var)
        assert String.starts_with?(dir, home <> "/"), "#{var}=#{dir} is not per-worker"
        assert File.dir?(dir)
      end
    end

    test "per-worker MIX_HOME passes the operator's archives and rebar through read-only", %{
      base: base,
      home: home
    } do
      operator_mix = Path.join(base, "operator-mix")
      File.mkdir_p!(Path.join(operator_mix, "archives/hex-2.0.0"))
      File.mkdir_p!(Path.join(operator_mix, "elixir/1-18-otp-27"))
      prev = System.get_env("MIX_HOME")
      System.put_env("MIX_HOME", operator_mix)

      on_exit(fn ->
        if prev, do: System.put_env("MIX_HOME", prev), else: System.delete_env("MIX_HOME")
      end)

      assert {:ok, argv} = Jail.wrap(["agy"], worktree: base, home: home)
      mix_home = argv |> flag_pairs("--setenv") |> Map.new() |> Map.fetch!("MIX_HOME")

      assert {:ok, Path.join(operator_mix, "archives")} ==
               File.read_link(Path.join(mix_home, "archives"))

      assert {:ok, Path.join(operator_mix, "elixir")} ==
               File.read_link(Path.join(mix_home, "elixir"))
    end

    test "a symlink planted where the toolchain dir goes is replaced, never followed", %{
      base: base,
      home: home
    } do
      # The agy HOME is writable from inside the jail, and wrap/2 runs on the
      # host, unjailed. Following a planted link would let a jailed worker
      # steer the next spawn's host-side mkdir anywhere.
      target = Path.join(base, "elsewhere")
      File.mkdir_p!(target)
      File.mkdir_p!(home)
      File.ln_s!(target, Path.join(home, ".arbiter-jail"))

      assert {:ok, _} = Jail.wrap(["agy"], worktree: base, home: home)
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(home, ".arbiter-jail"))
      assert File.ls!(target) == []
    end
  end

  # bd-5d5mrs: bwrap's unprivileged userns maps only the calling uid, so a
  # root-owned ssh config reads back as `nobody` inside the jail and OpenSSH
  # refuses to load it. `ssh_shadow_config/0` copies the content to a
  # self-owned path instead of relying on `--ro-bind-data`/FD plumbing.
  describe "ssh_shadow_config/0" do
    setup %{base: base} do
      prev_path = Application.get_env(:arbiter, :worker_jail_ssh_config_path)
      prev_user_path = Application.get_env(:arbiter, :worker_jail_user_ssh_config_path)
      prev_root = Application.get_env(:arbiter, :worker_jail_ssh_shadow_root)
      shadow_root = Path.join(base, "shadow")
      Application.put_env(:arbiter, :worker_jail_ssh_shadow_root, shadow_root)

      # Isolate from the real operator ~/.ssh/config: without this, a host
      # that has one (as the reviewing host did) would fail every assertion
      # below that expects the mirror to contain only the fixture content.
      Application.put_env(
        :arbiter,
        :worker_jail_user_ssh_config_path,
        Path.join(base, "no-user-config")
      )

      on_exit(fn ->
        restore_env(:worker_jail_ssh_config_path, prev_path)
        restore_env(:worker_jail_user_ssh_config_path, prev_user_path)
        restore_env(:worker_jail_ssh_shadow_root, prev_root)
      end)

      {:ok, shadow_root: shadow_root}
    end

    test "no source config: {:ok, nil}, nothing written", %{base: base, shadow_root: shadow_root} do
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, Path.join(base, "missing"))

      assert Jail.ssh_shadow_config() == {:ok, nil}
      refute File.exists?(shadow_root)
    end

    test "mirrors content verbatim when there is nothing to Include", %{
      base: base,
      shadow_root: shadow_root
    } do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\n  ForwardAgent no\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      assert shadow == Path.join(shadow_root, String.trim_leading(source, "/"))
      assert File.read!(shadow) == File.read!(source)
    end

    test "rewrites an absolute Include glob to self-owned copies of the matched files", %{
      base: base
    } do
      confd = Path.join(base, "ssh_config.d")
      File.mkdir_p!(confd)
      File.write!(Path.join(confd, "10-a.conf"), "Ciphers aes256-ctr\n")
      File.write!(Path.join(confd, "20-b.conf"), "MACs hmac-sha2-256\n")

      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\nInclude #{confd}/*.conf\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      [_host_line, include_line] = shadow |> File.read!() |> String.split("\n", trim: true)

      assert ["Include", shadow_a, shadow_b] = String.split(include_line, " ")
      assert File.read!(shadow_a) == "Ciphers aes256-ctr\n"
      assert File.read!(shadow_b) == "MACs hmac-sha2-256\n"
      # Self-owned: written by this (the operator's) process.
      assert File.stat!(shadow_a).uid == File.stat!(source).uid
    end

    test "an Include glob that matches nothing drops the line", %{base: base} do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\nInclude #{base}/nonexistent-dir/*.conf\nPort 22\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      assert File.read!(shadow) == "Host *\n\nPort 22\n"
    end

    test "a relative Include target passes through unmirrored (known gap)", %{base: base} do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Include relative/ssh_config.d/*.conf\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      assert File.read!(shadow) == "Include relative/ssh_config.d/*.conf\n"
    end

    # bd-5d5mrs finding 2: `ssh -F` replaces *both* the system and per-user
    # config, so a jailed `git push` to a `Host` alias (or anything else
    # from the operator's own `~/.ssh/config`) would silently fail unless
    # that file is Included too.
    test "Includes the operator's own ssh config ahead of the mirrored system config", %{
      base: base
    } do
      system_source = Path.join(base, "ssh_config")
      File.write!(system_source, "Host *\n  ForwardAgent no\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, system_source)

      user_source = Path.join(base, "user_ssh_config")
      File.write!(user_source, "Host gh-work\n  HostName github.com\n  User git\n")
      Application.put_env(:arbiter, :worker_jail_user_ssh_config_path, user_source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()

      assert ["Include " <> ^user_source, "Include " <> system_shadow] =
               shadow |> File.read!() |> String.split("\n", trim: true)

      assert File.read!(system_shadow) == File.read!(system_source)
    end

    test "no wrapper is written when the operator has no ssh config of their own", %{
      base: base,
      shadow_root: shadow_root
    } do
      system_source = Path.join(base, "ssh_config")
      File.write!(system_source, "Host *\n  ForwardAgent no\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, system_source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      assert shadow == Path.join(shadow_root, String.trim_leading(system_source, "/"))
      assert File.read!(shadow) == File.read!(system_source)
    end

    # bd-5d5mrs finding 3: OpenSSH's Include ownership check rejects a
    # group/other-writable file even when it's self-owned. `File.write/2`
    # honours the process umask, so a permissive umask (a UPG dev shell's
    # 002, not the release's 022) would otherwise leave the mirror rejected;
    # `write_ssh_shadow/2` forces mode 0644 regardless.
    test "the mirror is written mode 0644", %{base: base} do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      assert (File.stat!(shadow).mode &&& 0o777) == 0o644
    end

    test "an unchanged mirror is left alone; a changed one is rewritten", %{base: base} do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      before = File.stat!(shadow)

      assert {:ok, ^shadow} = Jail.ssh_shadow_config()
      assert File.stat!(shadow).mtime == before.mtime

      File.write!(source, "Host *\n  ForwardAgent no\n")
      assert {:ok, ^shadow} = Jail.ssh_shadow_config()
      assert File.read!(shadow) == "Host *\n  ForwardAgent no\n"

      # The atomic rename leaves no `.tmp.*` siblings behind.
      refute Path.dirname(shadow) |> File.ls!() |> Enum.any?(&(&1 =~ ~r/\.tmp\./))
    end
  end

  describe "wrap/2 sets GIT_SSH_COMMAND from the ssh shadow" do
    setup %{base: base} do
      prev_bwrap = Application.get_env(:arbiter, :worker_jail_bwrap)
      prev_path = Application.get_env(:arbiter, :worker_jail_ssh_config_path)
      prev_user_path = Application.get_env(:arbiter, :worker_jail_user_ssh_config_path)
      prev_root = Application.get_env(:arbiter, :worker_jail_ssh_shadow_root)

      Application.put_env(:arbiter, :worker_jail_bwrap, "/usr/bin/bwrap-stub")
      Application.put_env(:arbiter, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))

      # Isolate from the real operator ~/.ssh/config; individual tests opt
      # a fixture back in where they need one.
      Application.put_env(
        :arbiter,
        :worker_jail_user_ssh_config_path,
        Path.join(base, "no-user-ssh-config")
      )

      on_exit(fn ->
        restore_env(:worker_jail_bwrap, prev_bwrap)
        restore_env(:worker_jail_ssh_config_path, prev_path)
        restore_env(:worker_jail_user_ssh_config_path, prev_user_path)
        restore_env(:worker_jail_ssh_shadow_root, prev_root)
      end)

      :ok
    end

    test "adds GIT_SSH_COMMAND pointing at the mirror when a system config exists", %{
      base: base
    } do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, argv} = Jail.wrap(["git", "push"], worktree: base)
      setenv = Map.new(flag_pairs(argv, "--setenv"))

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      assert setenv["GIT_SSH_COMMAND"] == "ssh -F #{shadow}"
    end

    test "adds nothing when there is no system or user ssh config", %{base: base} do
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, Path.join(base, "missing"))

      assert {:ok, argv} = Jail.wrap(["git", "push"], worktree: base)
      setenv = Map.new(flag_pairs(argv, "--setenv"))
      refute Map.has_key?(setenv, "GIT_SSH_COMMAND")
    end

    test "adds GIT_SSH_COMMAND pointing at a wrapper when only a user ssh config exists", %{
      base: base
    } do
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, Path.join(base, "missing"))

      user_source = Path.join(base, "user_ssh_config")
      File.write!(user_source, "Host gh-work\n  HostName github.com\n")
      Application.put_env(:arbiter, :worker_jail_user_ssh_config_path, user_source)

      assert {:ok, argv} = Jail.wrap(["git", "push"], worktree: base)
      setenv = Map.new(flag_pairs(argv, "--setenv"))

      assert {:ok, shadow} = Jail.ssh_shadow_config()
      assert setenv["GIT_SSH_COMMAND"] == "ssh -F #{shadow}"
      assert File.read!(shadow) == "Include #{user_source}\n"
    end

    test "an explicit :env GIT_SSH_COMMAND overrides the shadow default", %{base: base} do
      source = Path.join(base, "ssh_config")
      File.write!(source, "Host *\n")
      Application.put_env(:arbiter, :worker_jail_ssh_config_path, source)

      assert {:ok, argv} =
               Jail.wrap(["git", "push"],
                 worktree: base,
                 env: [{"GIT_SSH_COMMAND", "ssh -F /dev/null"}]
               )

      setenv = Map.new(flag_pairs(argv, "--setenv"))
      assert setenv["GIT_SSH_COMMAND"] == "ssh -F /dev/null"
    end
  end

  describe "available?/0 and status/0" do
    setup do
      prev = Application.get_env(:arbiter, :worker_jail_available)

      on_exit(fn ->
        restore_env(:worker_jail_available, prev)
        Jail.reset()
      end)

      :ok
    end

    test "honours the :worker_jail_available override without probing" do
      Application.put_env(:arbiter, :worker_jail_available, true)
      assert Jail.available?()
      Application.put_env(:arbiter, :worker_jail_available, false)
      refute Jail.available?()
    end

    test "a missing bwrap is reported, not raised, and cached" do
      Application.delete_env(:arbiter, :worker_jail_available)
      prev = Application.get_env(:arbiter, :worker_jail_bwrap)
      Application.put_env(:arbiter, :worker_jail_bwrap, "/nonexistent/bwrap")
      on_exit(fn -> restore_env(:worker_jail_bwrap, prev) end)
      Jail.reset()

      assert {:error, {:bwrap_not_found, "/nonexistent/bwrap"}} = Jail.status()
      refute Jail.available?()

      # Cached: a later change of executable does not re-probe until reset/0.
      Application.put_env(:arbiter, :worker_jail_bwrap, "/other/bwrap")
      assert {:error, {:bwrap_not_found, "/nonexistent/bwrap"}} = Jail.status()
    end

    test "a bwrap that runs but does not confine writes fails the probe", %{base: base} do
      # Binary presence is not enough: a stand-in that just execs the command
      # unjailed (what a broken userns / AppArmor setup degrades to in the
      # worst case) must not be reported as a jail.
      fake = Path.join(base, "fake-bwrap")

      File.write!(fake, """
      #!/bin/sh
      while [ "$1" != "--" ]; do shift; done
      shift
      exec "$@"
      """)

      File.chmod!(fake, 0o755)
      Application.delete_env(:arbiter, :worker_jail_available)
      prev_bwrap = Application.get_env(:arbiter, :worker_jail_bwrap)
      prev_root = Application.get_env(:arbiter, :worker_jail_probe_root)
      Application.put_env(:arbiter, :worker_jail_bwrap, fake)
      Application.put_env(:arbiter, :worker_jail_probe_root, Path.join(base, "probe"))

      on_exit(fn ->
        restore_env(:worker_jail_bwrap, prev_bwrap)
        restore_env(:worker_jail_probe_root, prev_root)
      end)

      assert {:error, {:outside_write_not_blocked, _}} = Jail.probe()
      # The probe cleans up after itself.
      assert File.ls!(Path.join(base, "probe")) == []
    end
  end

  # bd-8xy1mf: `arb server doctor` needs to tell a missing bwrap apart from a
  # disabled userns sysctl apart from Ubuntu's AppArmor restriction apart from
  # anything else, each with its own fix. The two sysctl-backed causes are
  # simulated via fixture files (no root needed, no real sysctl touched).
  describe "explain/1 and diagnose/0" do
    setup do
      prev = %{
        available: Application.get_env(:arbiter, :worker_jail_available),
        userns_path: Application.get_env(:arbiter, :worker_jail_max_userns_path),
        apparmor_path: Application.get_env(:arbiter, :worker_jail_apparmor_restrict_path)
      }

      on_exit(fn ->
        restore_env(:worker_jail_available, prev.available)
        restore_env(:worker_jail_max_userns_path, prev.userns_path)
        restore_env(:worker_jail_apparmor_restrict_path, prev.apparmor_path)
        Jail.reset()
      end)

      :ok
    end

    test "diagnose/0 is nil when the jail is available" do
      Application.put_env(:arbiter, :worker_jail_available, true)
      assert Jail.diagnose() == nil
    end

    test "bwrap missing" do
      assert %{cause: :bwrap_missing, fix: fix} = Jail.explain({:bwrap_not_found, "bwrap"})
      assert fix =~ "dnf install bubblewrap"
      assert fix =~ "apt install bubblewrap"
    end

    test "user.max_user_namespaces = 0 is distinguished from the AppArmor restriction", %{
      base: base
    } do
      userns_path = Path.join(base, "max_user_namespaces")
      apparmor_path = Path.join(base, "apparmor_restrict_unprivileged_userns")
      File.write!(userns_path, "0\n")
      File.write!(apparmor_path, "0\n")
      Application.put_env(:arbiter, :worker_jail_max_userns_path, userns_path)
      Application.put_env(:arbiter, :worker_jail_apparmor_restrict_path, apparmor_path)

      assert %{cause: :user_namespaces_disabled, fix: fix} =
               Jail.explain({:bwrap_failed, 1, "bwrap: Creating new namespace failed"})

      assert fix =~ "sysctl -w user.max_user_namespaces"
    end

    test "the Ubuntu AppArmor restriction is reported when user namespaces are otherwise enabled",
         %{base: base} do
      userns_path = Path.join(base, "max_user_namespaces")
      apparmor_path = Path.join(base, "apparmor_restrict_unprivileged_userns")
      File.write!(userns_path, "126539\n")
      File.write!(apparmor_path, "1\n")
      Application.put_env(:arbiter, :worker_jail_max_userns_path, userns_path)
      Application.put_env(:arbiter, :worker_jail_apparmor_restrict_path, apparmor_path)

      assert %{cause: :apparmor_restricted, fix: fix} =
               Jail.explain({:bwrap_failed, 1, "bwrap: Permission denied"})

      assert fix =~ "kernel.apparmor_restrict_unprivileged_userns=0"
    end

    test "anything else falls back to bwrap's own stderr", %{base: base} do
      userns_path = Path.join(base, "max_user_namespaces")
      apparmor_path = Path.join(base, "apparmor_restrict_unprivileged_userns")
      File.write!(userns_path, "126539\n")
      File.write!(apparmor_path, "0\n")
      Application.put_env(:arbiter, :worker_jail_max_userns_path, userns_path)
      Application.put_env(:arbiter, :worker_jail_apparmor_restrict_path, apparmor_path)

      assert %{cause: :other, message: message, fix: nil} =
               Jail.explain({:bwrap_failed, 1, "bwrap: some unrelated failure"})

      assert message =~ "bwrap: some unrelated failure"
    end
  end

  # ---- real bwrap ----------------------------------------------------------

  describe "real bwrap with a stub command" do
    if @probe != :ok do
      @describetag skip: "bwrap write jail unavailable on this host: #{inspect(@probe)}"
    end

    @describetag :bwrap

    # bd-5d5mrs finding 4: isolate from the operator's real
    # $XDG_CACHE_HOME/arbiter/jail-ssh-shadow — every `wrap/2` call below
    # writes the ssh mirror as a side effect, stub command or not.
    setup %{base: base} do
      prev_root = Application.get_env(:arbiter, :worker_jail_ssh_shadow_root)
      Application.put_env(:arbiter, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))
      on_exit(fn -> restore_env(:worker_jail_ssh_shadow_root, prev_root) end)
      :ok
    end

    test "the probe passes on this host" do
      assert Jail.probe() == :ok
    end

    test "writes inside the worktree, git objects and the agy HOME succeed; outside, hooks, config and host /tmp are blocked",
         %{base: base} do
      %{wt: wt, common: common, gitdir: gitdir} = git_repo!(base)
      home = Path.join(base, "agy-home")
      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)
      host_tmp_marker = "arbiter-jail-test-#{System.pid()}-#{System.unique_integer([:positive])}"

      stub = """
      set -u
      echo in > "$WT/inside.txt" && echo INSIDE_OK
      echo home > "$HOME/home.txt" && echo HOME_OK
      echo obj | git hash-object -w --stdin >/dev/null && echo OBJECT_OK
      echo out > "$OUTSIDE/outside.txt" 2>/dev/null || echo "OUTSIDE_DENIED"
      { echo out > "$OUTSIDE/outside.txt"; } 2>&1 | grep -qi 'read-only file system' && echo OUTSIDE_EROFS
      { echo x > "$COMMON/hooks/pre-commit"; } 2>&1 | grep -qi 'read-only file system' && echo HOOKS_EROFS
      git config --local jail.test yes 2>/dev/null || echo CONFIG_DENIED
      { echo x > "$GITDIR/commondir"; } 2>&1 | grep -qi 'read-only file system' && echo COMMONDIR_EROFS
      { echo x > "$WT/.git"; } 2>&1 | grep -qi 'read-only file system' && echo DOTGIT_EROFS
      echo t > "/tmp/$MARKER" && echo TMP_WRITE_OK
      exit 0
      """

      {:ok, argv} =
        Jail.wrap(["sh", "-c", stub], worktree: wt, home: home)

      [bwrap | args] = argv

      {out, status} =
        System.cmd(bwrap, args,
          stderr_to_stdout: true,
          env: [
            {"LC_ALL", "C"},
            {"WT", wt},
            {"OUTSIDE", outside},
            {"COMMON", common},
            {"GITDIR", gitdir},
            {"MARKER", host_tmp_marker}
          ]
        )

      assert status == 0, out

      for marker <-
            ~w(INSIDE_OK HOME_OK OBJECT_OK OUTSIDE_DENIED OUTSIDE_EROFS HOOKS_EROFS CONFIG_DENIED COMMONDIR_EROFS DOTGIT_EROFS TMP_WRITE_OK) do
        assert out =~ marker, "missing #{marker} in:\n#{out}"
      end

      assert File.read!(Path.join(wt, "inside.txt")) == "in\n"
      assert File.read!(Path.join(home, "home.txt")) == "home\n"
      refute File.exists?(Path.join(outside, "outside.txt"))
      refute File.exists?(Path.join(common, "hooks/pre-commit"))
      refute File.read!(Path.join(common, "config")) =~ "jail"
      # The jail's /tmp is a private tmpfs: nothing lands in the host's.
      refute File.exists?(Path.join(System.tmp_dir!(), host_tmp_marker))
    end

    test "worktree_readonly: true makes a write inside the worktree fail with EROFS too (bd-3s82pf)",
         %{base: base} do
      %{wt: wt} = git_repo!(base)

      stub =
        ~s({ echo x > "$WT/inside.txt"; } 2>&1 | grep -qi 'read-only file system' && echo INSIDE_EROFS)

      {:ok, argv} = Jail.wrap(["sh", "-c", stub], worktree: wt, worktree_readonly: true)
      [bwrap | args] = argv

      {out, status} =
        System.cmd(bwrap, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}, {"WT", wt}])

      assert status == 0, out
      assert out =~ "INSIDE_EROFS"
      refute File.exists?(Path.join(wt, "inside.txt"))
    end

    test "the exit status of the jailed command is propagated", %{base: base} do
      {:ok, [bwrap | args]} = Jail.wrap(["sh", "-c", "exit 7"], worktree: base)
      assert {_, 7} = System.cmd(bwrap, args, stderr_to_stdout: true)
    end

    test "killing the jail's outer bwrap process (OsProcess.kill_tree) leaves nothing in its pid namespace",
         %{base: base} do
      # A chain deeper than OsProcess's descendant walk (5 levels) plus a
      # setsid-detached grandchild: without the pid namespace, kill_tree
      # could not reach either. `ready` is written once the deepest level
      # is up.
      chain = Path.join(base, "chain.sh")

      File.write!(chain, """
      #!/bin/sh
      n=$1
      if [ "$n" -gt 0 ]; then
        "$0" $((n - 1)) &
      else
        setsid sleep 300 &
        echo up > "$READY"
      fi
      exec sleep 300
      """)

      File.chmod!(chain, 0o755)
      ready = Path.join(base, "ready")

      {:ok, [bwrap | args]} = Jail.wrap([chain, "8"], worktree: base)

      port =
        Port.open({:spawn_executable, bwrap}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          env: [{~c"READY", String.to_charlist(ready)}]
        ])

      {:os_pid, outer} = Port.info(port, :os_pid)
      assert wait_until(fn -> File.exists?(ready) end), "jailed chain never came up"

      [inner | _] = OsProcess.descendants(outer)
      {:ok, ns} = File.read_link("/proc/#{inner}/ns/pid")
      refute ns == elem(File.read_link("/proc/self/ns/pid"), 1)
      assert length(pids_in_ns(ns)) >= 10

      assert OsProcess.kill_tree(outer) == []
      assert_receive {^port, {:exit_status, _}}, 5_000

      assert wait_until(fn -> pids_in_ns(ns) == [] end),
             "processes survived in the jail's pid namespace: #{inspect(pids_in_ns(ns))}"
    end
  end

  describe "real bwrap: escape vectors (bd-7o08mj)" do
    if @probe != :ok do
      @describetag skip: "bwrap write jail unavailable on this host: #{inspect(@probe)}"
    end

    @describetag :bwrap

    test "systemd-run --user fails, no host write lands, name resolution fails under --unshare-net",
         %{base: base} do
      host_marker = Path.join(base, "escape-marker")
      wt = Path.join(base, "escape-wt")
      File.mkdir_p!(wt)
      # `base` is outside the worktree, so the jail mounts it read-only.
      script = """
      command -v systemd-run >/dev/null && systemd-run --user --wait --collect touch "$M" >/dev/null 2>&1 && echo SYSTEMD_RUN_OK
      touch "$M" 2>/dev/null && echo DIRECT_WRITE_OK
      getent hosts example.com >/dev/null 2>&1 && echo RESOLVED
      exit 0
      """

      {:ok, [bwrap | args]} = Jail.wrap(["sh", "-c", script], worktree: wt)
      {pre, [dashdash | cmd]} = Enum.split_while(args, &(&1 != "--"))

      {out, 0} =
        System.cmd(bwrap, pre ++ ["--unshare-net", dashdash | cmd],
          stderr_to_stdout: true,
          env: [{"M", host_marker}]
        )

      refute out =~ "SYSTEMD_RUN_OK"
      refute out =~ "DIRECT_WRITE_OK"
      refute out =~ "RESOLVED"
      refute File.exists?(host_marker)
    end

    test "keyring: true binds a filtered proxy bus; systemd-run still fails (needs xdg-dbus-proxy + a session bus)",
         %{base: base} do
      bus = System.get_env("DBUS_SESSION_BUS_ADDRESS") || ""

      if is_nil(Jail.dbus_proxy()) or not String.starts_with?(bus, "unix:path=") do
        :ok
      else
        wt = Path.join(base, "proxy-wt")
        File.mkdir_p!(wt)

        script =
          ~s(systemd-run --user true >/dev/null 2>&1 && echo SYSTEMD_RUN_OK; test -S "${DBUS_SESSION_BUS_ADDRESS#unix:path=}" && echo BUS_PRESENT; exit 0)

        {:ok, [exec | args]} = Jail.wrap(["sh", "-c", script], worktree: wt, keyring: true)
        {out, 0} = System.cmd(exec, args, stderr_to_stdout: true)
        assert out =~ "BUS_PRESENT"
        refute out =~ "SYSTEMD_RUN_OK"
      end
    end

    test "escape_probe/0 reports no reachable vector" do
      assert Jail.escape_probe() == :ok
      assert Jail.diagnose_escape() == nil
    end
  end

  # bd-5d5mrs: proves both the bug (bd-90kjvk) and the fix against this
  # host's real /etc/ssh/ssh_config — no fixture, since the bug only exists
  # because that file is root-owned, which we can't fabricate without root.
  describe "real bwrap: ssh config parse (bd-5d5mrs)" do
    if @probe != :ok do
      @describetag skip: "bwrap write jail unavailable on this host: #{inspect(@probe)}"
    end

    if is_nil(System.find_executable("ssh")) do
      @describetag skip: "no ssh executable on this host"
    end

    @describetag :bwrap

    # bd-5d5mrs finding 4: without this, these tests write into the
    # operator's real $XDG_CACHE_HOME/arbiter/jail-ssh-shadow, which a
    # concurrently running jailed ssh (another worker, or a parallel test
    # run) could read mid-write.
    setup %{base: base} do
      prev_root = Application.get_env(:arbiter, :worker_jail_ssh_shadow_root)
      Application.put_env(:arbiter, :worker_jail_ssh_shadow_root, Path.join(base, "shadow"))
      on_exit(fn -> restore_env(:worker_jail_ssh_shadow_root, prev_root) end)
      :ok
    end

    test "reproduces the bug: plain ssh -G fails inside the jail on the real system config" do
      {:ok, [bwrap | args]} = Jail.wrap(["ssh", "-G", "localhost"], worktree: System.tmp_dir!())
      # Force GIT_SSH_COMMAND's default back off so this exercises the bare,
      # unfixed transport agy hit in bd-90kjvk.
      args = drop_setenv(args, "GIT_SSH_COMMAND")

      {out, status} = System.cmd(bwrap, args, stderr_to_stdout: true)

      assert status != 0
      assert out =~ ~r/bad owner or permissions/i
    end

    test "the real ssh probe passes on this host" do
      assert Jail.ssh_probe() == :ok
    end

    test "wrap/2's GIT_SSH_COMMAND default makes ssh -G succeed inside the jail" do
      {:ok, [bwrap | args]} =
        Jail.wrap(["sh", "-c", "eval \"$GIT_SSH_COMMAND\" -G localhost"],
          worktree: System.tmp_dir!()
        )

      {out, status} = System.cmd(bwrap, args, stderr_to_stdout: true)

      assert status == 0, out
      refute out =~ ~r/bad owner or permissions/i
    end
  end

  defp drop_setenv(["--setenv", key, _ | rest], name) when key == name,
    do: drop_setenv(rest, name)

  defp drop_setenv([other | rest], name), do: [other | drop_setenv(rest, name)]
  defp drop_setenv([], _name), do: []

  defp pids_in_ns(ns) do
    "/proc"
    |> File.ls!()
    |> Enum.filter(&(&1 =~ ~r/^\d+$/))
    |> Enum.filter(fn pid -> File.read_link("/proc/#{pid}/ns/pid") == {:ok, ns} end)
  end

  # External OS processes give no message to wait on; poll with a bound.
  defp wait_until(fun, attempts \\ 250) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(20)
        {:cont, false}
      end
    end)
  end
end
