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
    # The default fixture is a plaintext-token gh login (the dir stays hidden).
    File.write!(Path.join(home, ".config/gh/hosts.yml"), plaintext_hosts())
    File.write!(Path.join(home, ".config/gh/config.yml"), "SECRET-gh-config")
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

  defp plaintext_hosts, do: "github.com:\n  user: op\n  oauth_token: SECRET-gh-token\n"
  defp keyring_hosts, do: "github.com:\n  user: op\n  git_protocol: ssh\n"

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

    test "gh: a plaintext-token hosts.yml keeps the whole dir hidden", %{fx: fx} do
      %{dirs: dirs, keep: keep} = Hide.paths(fx.opts)
      gh = Path.join(fx.home, ".config/gh")

      assert gh in dirs
      refute Path.join(gh, "hosts.yml") in keep
      refute Path.join(gh, "config.yml") in keep
    end

    test "gh: a keyring-backed hosts.yml (no oauth_token) and config.yml are kept", %{fx: fx} do
      gh = Path.join(fx.home, ".config/gh")
      File.write!(Path.join(gh, "hosts.yml"), keyring_hosts())

      %{dirs: dirs, keep: keep} = Hide.paths(fx.opts)

      assert gh in dirs
      assert Path.join(gh, "hosts.yml") in keep
      assert Path.join(gh, "config.yml") in keep
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

    test "gh keyring login: hosts.yml and config.yml stay readable, other files in the dir do not",
         %{fx: fx} do
      gh = Path.join(fx.home, ".config/gh")
      File.write!(Path.join(gh, "hosts.yml"), keyring_hosts())
      File.write!(Path.join(gh, "extra.yml"), "SECRET-extra")

      out =
        jailed(
          fx,
          ~s(cat "#{gh}/hosts.yml" "#{gh}/config.yml"; cat "#{gh}/extra.yml" 2>/dev/null; echo end)
        )

      assert out =~ "git_protocol: ssh"
      assert out =~ "SECRET-gh-config"
      refute out =~ "SECRET-extra"
      refute out =~ "oauth_token"
    end

    test "gh plaintext token: hosts.yml and config.yml read back empty", %{fx: fx} do
      gh = Path.join(fx.home, ".config/gh")
      out = reads(fx, [Path.join(gh, "hosts.yml"), Path.join(gh, "config.yml")])
      refute out =~ "SECRET"
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

    test "the egress bridge socket dir stays usable under a hidden parent", %{fx: fx} do
      # Sockets live under a dir that is itself masked: the network spec's own
      # tmpfs + ro-bind must come back on top of the hide masks.
      sockdir = Path.join(fx.log_root, "egress")
      File.mkdir_p!(sockdir)
      proxy = Path.join(sockdir, "proxy.sock")
      File.write!(proxy, "")

      if socat = System.find_executable("socat") do
        network = %{proxy_socket: proxy, proxy_port: 3128, bridges: [], socat: socat}
        out = jailed(fx, ~s(test -e "#{proxy}" && echo SOCK_OK), %{network: network})
        assert out =~ "SOCK_OK"
      end
    end

    test "git worktree + commit work inside the hidden jail under a hidden worktree root", %{
      fx: fx
    } do
      git_env = [
        {"GIT_AUTHOR_NAME", "t"},
        {"GIT_AUTHOR_EMAIL", "t@example.invalid"},
        {"GIT_COMMITTER_NAME", "t"},
        {"GIT_COMMITTER_EMAIL", "t@example.invalid"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"}
      ]

      host_git = fn args, dir ->
        assert {_, 0} = System.cmd("git", args, cd: dir, env: git_env, stderr_to_stdout: true)
      end

      File.rm_rf!(Path.join(fx.own_repo, ".git"))
      host_git.(["init", "-q", "-b", "main"], fx.own_repo)
      host_git.(["add", "README"], fx.own_repo)
      host_git.(["commit", "-q", "-m", "init"], fx.own_repo)

      wt = Path.join(fx.wt_root, "git-task")
      host_git.(["worktree", "add", "-q", "-b", "task", wt], fx.own_repo)
      fx = %{fx | wt: wt}

      {:ok, git} = Jail.git(wt)
      assert git.dot_git_file?
      assert git.worktrees_dir?

      out =
        jailed(
          fx,
          """
          echo change > "$0/new.txt" && git add new.txt && git commit -q -m jailed && git log --format=%s -1 && echo COMMIT_OK
          """,
          %{git: git, env: git_env}
        )

      assert out =~ "COMMIT_OK"
      assert out =~ "jailed"

      # The commit landed in the real repo's worktree gitdir, and the sibling
      # worktree is still hidden from the jailed process.
      {log, 0} = System.cmd("git", ["log", "--format=%s", "-1", "task"], cd: fx.own_repo)
      assert String.trim(log) == "jailed"
      refute jailed(fx, ~s(ls "#{fx.wt_root}"), %{git: git}) =~ "sibling-task"
    end

    # bd-4wy1w1: an agy run resuming in a git-layout-B private clone (a Claude
    # container worker made it). The clone borrows its main repo's objects,
    # which must stay readable under the repo masks, and its `commondir` guard
    # and alternates must not be writable from inside.
    test "a private clone commits inside the hidden jail, reading the history it borrows", %{
      fx: fx
    } do
      git_env = [
        {"GIT_AUTHOR_NAME", "t"},
        {"GIT_AUTHOR_EMAIL", "t@example.invalid"},
        {"GIT_COMMITTER_NAME", "t"},
        {"GIT_COMMITTER_EMAIL", "t@example.invalid"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"}
      ]

      gfx =
        Arbiter.Test.GitFixture.forge_and_checkout(%{"README.md" => "readme\n"},
          parent: Path.dirname(fx.wt_root)
        )

      {:ok, clone} = Arbiter.Worker.PrivateClone.create(gfx.checkout, "feature/jail-b", "main")
      {:ok, git} = Jail.git(clone)
      assert git.main_repo == gfx.checkout

      # The hide spec `Jail.wrap/2` builds for this clone: its main repo is the
      # own repo, every other one is masked.
      hide =
        Hide.paths(
          Keyword.merge(fx.opts,
            own_repo: git.main_repo,
            repos: [gfx.checkout, fx.other_repo]
          )
        )

      out =
        jailed(
          %{fx | wt: clone},
          """
          cd "$0" || exit 1
          git log --format=%s | grep -q init && echo HISTORY_OK
          echo change > new.txt && git add new.txt && git commit -q -m jailed && echo COMMIT_OK
          printf '/tmp/fake\\n' > .git/commondir 2>/dev/null; echo "commondir=$?"
          printf '/etc\\n' > .git/objects/info/alternates 2>/dev/null; echo "alternates=$?"
          cat "#{fx.other_repo}/README" 2>/dev/null; echo end
          """,
          %{git: git, env: git_env, hide: hide}
        )

      assert out =~ "HISTORY_OK"
      assert out =~ "COMMIT_OK"
      refute out =~ "commondir=0"
      refute out =~ "alternates=0"
      refute out =~ "SECRET-other-repo"
      assert File.read!(Path.join(clone, ".git/commondir")) == ".\n"
      assert {log, 0} = System.cmd("git", ["log", "--format=%s", "-1"], cd: clone)
      assert String.trim(log) == "jailed"
    end

    test "ssh reads ~/.ssh/config, known_hosts and the default identity under the masks", %{
      fx: fx
    } do
      ssh = Path.join(fx.home, ".ssh")
      key = Path.join(ssh, "id_ed25519")
      File.rm!(key)

      assert {_, 0} =
               System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key],
                 stderr_to_stdout: true
               )

      File.write!(
        Path.join(ssh, "config"),
        "Host github.com\n  ProxyCommand socat - UNIX-CONNECT:/run/egress.sock\n  IdentityFile #{key}\n  UserKnownHostsFile #{ssh}/known_hosts\n"
      )

      out =
        jailed(
          fx,
          """
          ssh -F "#{ssh}/config" -G github.com | grep -i -E '^(proxycommand|identityfile|userknownhostsfile) '
          ssh-keygen -y -f "#{key}" | cut -d' ' -f1
          cat "#{ssh}/known_hosts" >/dev/null && echo KNOWN_OK
          cat "#{ssh}/ci.id_ed25519" 2>/dev/null; echo end
          """
        )

      assert out =~ ~r/proxycommand socat/i
      assert out =~ "ssh-ed25519"
      assert out =~ "KNOWN_OK"
      refute out =~ "SECRET-.ssh/ci.id_ed25519"
    end

    test "Jail.wrap/2 with hide_reads: true hides the configured install DB inside a real jail",
         %{base: base} do
      # Not under /tmp (the jail already blanks that); put the DB next to the
      # scratch dir so only the hide set can hide it.
      db = Path.join(base, "install.sqlite3")
      File.write!(db, "SECRET-install-db")

      repo = Application.get_env(:arbiter, Arbiter.Repo)
      Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo, :database, db))
      on_exit(fn -> Application.put_env(:arbiter, Arbiter.Repo, repo) end)

      wt = Path.join(base, "wrap-wt")
      File.mkdir_p!(wt)

      script = ~s(cat "#{db}" 2>/dev/null; echo end)

      {:ok, [exec | args]} = Jail.wrap(["sh", "-c", script], worktree: wt, hide_reads: true)
      {out, 0} = System.cmd(exec, args, stderr_to_stdout: true)

      # Shadowed by /dev/null: nothing of the DB comes back.
      assert out == "end\n"
    end

    test "reads_probe/0 reports nothing reachable" do
      assert Jail.reads_probe() == :ok
      assert Jail.diagnose_reads() == nil
    end
  end
end
