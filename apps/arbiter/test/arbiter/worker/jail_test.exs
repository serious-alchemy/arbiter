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
      Application.put_env(:arbiter, :worker_jail_bwrap, "/usr/bin/bwrap-stub")
      on_exit(fn -> restore_env(:worker_jail_bwrap, prev) end)
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

  # ---- real bwrap ----------------------------------------------------------

  describe "real bwrap with a stub command" do
    if @probe != :ok do
      @describetag skip: "bwrap write jail unavailable on this host: #{inspect(@probe)}"
    end

    @describetag :bwrap

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
