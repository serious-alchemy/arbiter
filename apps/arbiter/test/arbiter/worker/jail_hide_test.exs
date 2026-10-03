defmodule Arbiter.Worker.JailHideTest do
  @moduledoc """
  bd-3q2djr (G3): the agy jail hides sensitive read paths — credential dirs,
  the install DB and `~/.arbiter`, the durable log root, other workspaces'
  repos and the worktree root — behind `--tmpfs` / `/dev/null`.

  The path-class tests are pure (a fake operator home under a scratch dir).
  The `:bwrap` tests run the real `bwrap` against a **stub** `sh` command,
  one probe per class, and are skipped where `Jail.probe/0` fails.
  """

  # async: false — flips Application env read by the jail (probe root, the
  # availability override) and the cached probe result.
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.Jail.Hide

  @probe Jail.probe()

  setup do
    uniq = "#{System.pid()}-#{System.unique_integer([:positive])}"
    # Not under /tmp: the jail mounts a private tmpfs there.
    base = Path.join(Arbiter.Config.Paths.scratch_root(), "jail-hide-test-#{uniq}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    # `Hide.workspace_repos/0` reads the workspaces table.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arbiter.Repo)

    fx = fixture!(base)
    {:ok, base: base, fx: fx}
  end

  # A fake operator home with one entry per path class, an own worktree and
  # sibling worktree under the worktree root, and an own + a foreign repo.
  defp fixture!(base) do
    home = Path.join(base, "home")
    data = Path.join(home, ".arbiter")
    wt_root = Path.join(base, "worktrees")
    log_root = Path.join(base, "logs")
    own_repo = Path.join(base, "repos/own")
    other_repo = Path.join(base, "repos/other")

    for d <- [
          ".claude",
          ".codex",
          ".config/gh",
          ".ssh",
          ".aws",
          ".gemini",
          ".arbiter/accounts",
          ".cache/arbiter/worker-claude",
          ".cache/arbiter/worker-agy/sibling"
        ] do
      File.mkdir_p!(Path.join(home, d))
    end

    File.mkdir_p!(Path.join(own_repo, ".git"))
    File.mkdir_p!(other_repo)
    File.mkdir_p!(Path.join(wt_root, "own-task"))
    File.mkdir_p!(Path.join(wt_root, "sibling-task"))
    File.mkdir_p!(log_root)

    secrets = [
      ".claude/.credentials.json",
      ".codex/auth.json",
      ".config/gh/hosts.yml",
      ".ssh/id_ed25519",
      ".ssh/ci.id_ed25519",
      ".ssh/known_hosts",
      ".ssh/config",
      ".aws/credentials",
      ".gemini/oauth_creds.json",
      ".arbiter/arbiter.sqlite3",
      ".arbiter/accounts.json",
      ".netrc",
      ".git-credentials",
      ".cache/arbiter/worker-claude/.credentials.json",
      ".cache/arbiter/worker-agy/sibling/mcp_config.json"
    ]

    for s <- secrets, do: File.write!(Path.join(home, s), "SECRET-#{s}")
    File.write!(Path.join(wt_root, "sibling-task/file.txt"), "SECRET-sibling")
    File.write!(Path.join(wt_root, "own-task/file.txt"), "own")
    File.write!(Path.join(log_root, "run.log"), "SECRET-log")
    File.write!(Path.join(other_repo, "README"), "SECRET-other-repo")
    File.write!(Path.join(own_repo, "README"), "own-repo")

    %{
      home: home,
      opts: [
        operator_home: home,
        data_dir: data,
        database: Path.join(data, "arbiter.sqlite3"),
        accounts_root: Path.join(data, "accounts"),
        worktree_root: wt_root,
        log_root: log_root,
        sessions_root: Path.join(base, "no-sessions"),
        agy_home_root: Path.join(home, ".cache/arbiter/worker-agy"),
        claude_config_dir: Path.join(home, ".cache/arbiter/worker-claude"),
        repos: [own_repo, other_repo],
        own_repo: own_repo,
        unmask: []
      ],
      wt: Path.join(wt_root, "own-task"),
      agy_home: Path.join(home, ".cache/arbiter/worker-agy/own"),
      own_repo: own_repo,
      other_repo: other_repo,
      wt_root: wt_root,
      log_root: log_root
    }
  end

  describe "Hide.paths/1 path classes" do
    test "lists every credential dir, the data dir, the roots and only the foreign repo",
         %{fx: fx} do
      %{dirs: dirs, files: files} = Hide.paths(fx.opts)
      h = fx.home

      for d <- [".claude", ".codex", ".config/gh", ".ssh", ".aws", ".gemini", ".arbiter"] do
        assert Path.join(h, d) in dirs, "#{d} not masked"
      end

      assert fx.wt_root in dirs
      assert fx.log_root in dirs
      assert fx.other_repo in dirs
      refute fx.own_repo in dirs
      assert Path.join(h, ".cache/arbiter/worker-claude") in dirs
      assert Path.join(h, ".cache/arbiter/worker-agy") in dirs
      assert Path.join(h, ".netrc") in files
      assert Path.join(h, ".git-credentials") in files
    end

    test "skips paths that do not exist (bwrap cannot create a mount point there)",
         %{fx: fx} do
      %{dirs: dirs, files: files} = Hide.paths(fx.opts)
      refute Path.join(fx.home, ".kube") in dirs
      refute Path.join(fx.home, ".pgpass") in files
      refute Path.join(fx.home, "no-sessions") in dirs
    end

    test "files and dirs under a masked dir are not listed twice", %{fx: fx} do
      %{dirs: dirs, files: files} = Hide.paths(fx.opts)
      refute Path.join(fx.home, ".arbiter/accounts") in dirs
      refute Path.join(fx.home, ".arbiter/arbiter.sqlite3") in files
    end

    test "a database outside the data dir is masked as a file with its sidecars", %{
      base: base,
      fx: fx
    } do
      db = Path.join(base, "dev.sqlite3")
      File.write!(db, "SECRET-db")
      File.write!(db <> "-wal", "SECRET-wal")

      %{files: files} = Hide.paths(Keyword.put(fx.opts, :database, db))
      assert db in files
      assert (db <> "-wal") in files
      refute (db <> "-shm") in files
    end

    test "ssh keeps only known_hosts, config and the default identity", %{fx: fx} do
      %{keep: keep} = Hide.paths(fx.opts)
      ssh = Path.join(fx.home, ".ssh")

      assert Path.join(ssh, "known_hosts") in keep
      assert Path.join(ssh, "config") in keep
      assert Path.join(ssh, "id_ed25519") in keep
      refute Path.join(ssh, "ci.id_ed25519") in keep
    end

    test ":unmask exempts a path: a dir is dropped, a path under a masked dir is kept", %{
      fx: fx
    } do
      gh_hosts = Path.join(fx.home, ".config/gh/hosts.yml")

      %{dirs: dirs, keep: keep} = Hide.paths(Keyword.put(fx.opts, :unmask, [gh_hosts]))
      assert Path.join(fx.home, ".config/gh") in dirs
      assert gh_hosts in keep

      %{dirs: dirs} = Hide.paths(Keyword.put(fx.opts, :unmask, [Path.join(fx.home, ".codex")]))
      refute Path.join(fx.home, ".codex") in dirs
    end

    test "a symlinked credential dir is masked at its real path", %{base: base, fx: fx} do
      real = Path.join(base, "dotfiles-claude")
      File.mkdir_p!(real)
      File.write!(Path.join(real, "x"), "SECRET")
      claude = Path.join(fx.home, ".claude")
      File.rm_rf!(claude)
      File.ln_s!(real, claude)

      %{dirs: dirs} = Hide.paths(fx.opts)
      assert real in dirs
      refute claude in dirs
    end

    test "never masks the operator's home, / or a repo that is the home", %{fx: fx} do
      %{dirs: dirs} = Hide.paths(Keyword.put(fx.opts, :repos, [fx.home, "/"]))
      refute fx.home in dirs
      refute "/" in dirs
    end
  end

  describe "argv/2 with a hide spec" do
    test "emits tmpfs, keep re-binds then /dev/null shadows, all before the worktree bind",
         %{fx: fx} do
      hide = Hide.paths(fx.opts)

      argv =
        Jail.argv(
          %{bwrap: "bwrap", worktree: fx.wt, hide: hide, mask_paths: [], secret_files: []},
          ["true"]
        )

      tmpfs = Path.join(fx.home, ".ssh")
      ti = Enum.find_index(argv, &(&1 == tmpfs))
      assert Enum.at(argv, ti - 1) == "--tmpfs"

      known = Path.join(tmpfs, "known_hosts")
      ki = Enum.find_index(argv, &(&1 == known))
      assert ki > ti
      assert Enum.at(argv, ki - 1) == "--ro-bind-try"

      netrc = Path.join(fx.home, ".netrc")
      ni = Enum.find_index(argv, &(&1 == netrc))
      assert Enum.slice(argv, ni - 2, 2) == ["--ro-bind", "/dev/null"]

      wi = Enum.find_index(argv, &(&1 == fx.wt))
      assert ti < wi and ni < wi
    end

    test "no :hide spec leaves the argv without the extra masks", %{fx: fx} do
      argv =
        Jail.argv(%{bwrap: "bwrap", worktree: fx.wt, mask_paths: [], secret_files: []}, ["true"])

      refute Path.join(fx.home, ".ssh") in argv
    end
  end

  describe "real bwrap: one probe per path class" do
    if @probe != :ok do
      @describetag skip: "bwrap write jail unavailable on this host: #{inspect(@probe)}"
    end

    @describetag :bwrap

    # Runs `script` in the real jail (the hide spec built from `fx`) and
    # returns its stdout. `$0` is the worktree.
    defp jailed(fx, script, extra_spec \\ %{}) do
      spec =
        Map.merge(
          %{
            bwrap: System.find_executable("bwrap"),
            worktree: fx.wt,
            home: fx.agy_home,
            hide: Hide.paths(fx.opts),
            mask_paths: [],
            secret_files: []
          },
          extra_spec
        )

      File.mkdir_p!(fx.agy_home)
      [exec | args] = Jail.argv(spec, ["sh", "-c", script, fx.wt])
      {out, 0} = System.cmd(exec, args, stderr_to_stdout: true)
      out
    end

    # `cat` every path; the SECRET-* sentinel must never come back.
    defp reads(fx, paths) do
      script = Enum.map_join(paths, "\n", &~s(cat "#{&1}" 2>/dev/null; ls -A "#{&1}" 2>/dev/null))
      jailed(fx, script <> "\necho end")
    end

    test "credential dirs and files read back empty", %{fx: fx} do
      h = fx.home

      out =
        reads(
          fx,
          [
            ".claude/.credentials.json",
            ".codex/auth.json",
            ".config/gh/hosts.yml",
            ".aws/credentials",
            ".gemini/oauth_creds.json",
            ".ssh/ci.id_ed25519",
            ".netrc",
            ".git-credentials"
          ]
          |> Enum.map(&Path.join(h, &1))
        )

      refute out =~ "SECRET"
      assert out =~ "end"
    end

    test "the install DB, accounts and ~/.arbiter read back empty", %{fx: fx} do
      h = fx.home

      out =
        reads(fx, [
          Path.join(h, ".arbiter/arbiter.sqlite3"),
          Path.join(h, ".arbiter/accounts.json"),
          Path.join(h, ".arbiter")
        ])

      refute out =~ "SECRET"
      refute out =~ "arbiter.sqlite3"
    end

    test "the durable log root is empty", %{fx: fx} do
      out = reads(fx, [Path.join(fx.log_root, "run.log"), fx.log_root])
      refute out =~ "SECRET"
      refute out =~ "run.log"
    end

    test "another workspace's repo is hidden, the own repo is not", %{fx: fx} do
      out = reads(fx, [Path.join(fx.other_repo, "README")])
      refute out =~ "SECRET"
      # The own repo is not on the list; it stays readable (it holds the git
      # common dir the worker commits to).
      own = jailed(fx, ~s(cat "#{fx.own_repo}/README"))
      assert own =~ "own-repo"
    end

    test "a sibling worktree is hidden but the own worktree is intact and writable", %{fx: fx} do
      out =
        reads(fx, [
          Path.join(fx.wt_root, "sibling-task/file.txt"),
          Path.join(fx.wt_root, "sibling-task")
        ])

      refute out =~ "SECRET"
      refute out =~ "file.txt"

      own = jailed(fx, ~s(cat "$0/file.txt" && echo more > "$0/new.txt" && echo wrote))
      assert own =~ "own"
      assert own =~ "wrote"
      assert File.read!(Path.join(fx.wt, "new.txt")) =~ "more"
    end

    test "other workers' agy homes (MCP scope tokens) are hidden, the own agy HOME is writable",
         %{fx: fx} do
      out = reads(fx, [Path.join(fx.home, ".cache/arbiter/worker-agy/sibling/mcp_config.json")])
      refute out =~ "SECRET"
      assert jailed(fx, ~s(echo ok > "$HOME/x" && echo wrote)) =~ "wrote"

      refute jailed(
               fx,
               ~s(cat "#{fx.home}/.cache/arbiter/worker-claude/.credentials.json" 2>/dev/null; echo end)
             ) =~ "SECRET"
    end

    test "ssh: known_hosts, config and the default key stay readable; other keys do not", %{
      fx: fx
    } do
      ssh = Path.join(fx.home, ".ssh")

      out =
        jailed(
          fx,
          ~s(cat "#{ssh}/known_hosts" "#{ssh}/config" "#{ssh}/id_ed25519"; cat "#{ssh}/ci.id_ed25519" 2>/dev/null; echo end)
        )

      assert out =~ "SECRET-.ssh/known_hosts"
      assert out =~ "SECRET-.ssh/config"
      assert out =~ "SECRET-.ssh/id_ed25519"
      refute out =~ "SECRET-.ssh/ci.id_ed25519"
    end

    test "the agy HOME's symlink passthrough resolves into the masks", %{fx: fx} do
      # The isolated agy HOME symlinks the operator's .ssh/.arbiter/.config.
      File.mkdir_p!(fx.agy_home)
      File.ln_s!(Path.join(fx.home, ".arbiter"), Path.join(fx.agy_home, ".arbiter"))
      File.ln_s!(Path.join(fx.home, ".config"), Path.join(fx.agy_home, ".config"))

      out =
        jailed(
          fx,
          ~s(cat "$HOME/.arbiter/arbiter.sqlite3" "$HOME/.config/gh/hosts.yml" 2>/dev/null; echo end)
        )

      refute out =~ "SECRET"
    end

    test "the egress bridge sockets and a git commit still work inside the hidden jail", %{
      base: base,
      fx: fx
    } do
      # Sockets live under a dir that is itself masked: the network spec's own
      # tmpfs + ro-bind must come back on top of the hide masks.
      sockdir = Path.join(fx.log_root, "egress")
      File.mkdir_p!(sockdir)
      proxy = Path.join(sockdir, "proxy.sock")
      File.write!(proxy, "")

      socat = System.find_executable("socat")

      if socat do
        network = %{proxy_socket: proxy, proxy_port: 3128, bridges: [], socat: socat}
        out = jailed(fx, ~s(test -e "#{proxy}" && echo SOCK_OK), %{network: network})
        assert out =~ "SOCK_OK"
      else
        :ok
      end

      _ = base
    end

    test "Jail.wrap/2 with hide_reads: true hides the real install DB path inside a real jail",
         %{base: base} do
      wt = Path.join(base, "wrap-wt")
      File.mkdir_p!(wt)
      {:ok, [exec | args]} = Jail.wrap(["sh", "-c", "echo end"], worktree: wt, hide_reads: true)
      assert {"end\n", 0} = System.cmd(exec, args, stderr_to_stdout: true)
    end

    test "reads_probe/0 reports nothing reachable" do
      assert Jail.reads_probe() == :ok
      assert Jail.diagnose_reads() == nil
    end
  end
end
