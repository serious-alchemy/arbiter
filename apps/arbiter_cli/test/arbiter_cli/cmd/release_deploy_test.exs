defmodule ArbiterCli.Cmd.ReleaseDeployTest do
  # async: false — these tests mutate global env (ARB_DATA_HOME, ARB_RELEASE_REPO,
  # ARB_HOST, GITHUB_TOKEN) and route through the shared process-dict seams.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.ReleaseDeploy

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}
  @empty %{"data" => []}
  @no_workers %{"data" => []}

  @repo "acme/arbiter"
  @vsn "v2026.7.0"

  # Every real arbiter release ships migrations, and an empty set now means
  # "detection broke" (bd-bksulf round 2), so the default fixtures ship one.
  @m_base "20250101000000_create_base"

  setup do
    home = Path.join(System.tmp_dir!(), "arb-rel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    System.put_env("ARB_DATA_HOME", home)
    Process.delete(:bd2_deploy_status_path)
    System.put_env("ARB_RELEASE_REPO", @repo)
    # A green deploy self-updates the CLI; never let a test write the real one.
    System.put_env("ARB_INSTALL_BIN", Path.join(home, "bin/arb"))
    System.delete_env("DATABASE_PATH")
    System.delete_env("ARB_DEPLOY_BACKUP_RETAIN")
    System.delete_env("ARB_HOST")
    System.delete_env("GITHUB_TOKEN")
    System.delete_env("ARB_WORKER_BEAD_ID")
    System.delete_env("ARB_GITHUB_API")

    on_exit(fn ->
      System.delete_env("ARB_DATA_HOME")
      System.delete_env("ARB_RELEASE_REPO")
      System.delete_env("ARB_INSTALL_BIN")
      File.rm_rf(home)
    end)

    # Sleep + TCP-port-free seams so restart/wait loops run instantly in tests.
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    Process.put(:bd2_port_check, fn _port -> true end)

    {:ok, home: home}
  end

  # ---- fixtures ----------------------------------------------------------

  # A real, compressed OTP-release-shaped tarball with the single top-level
  # `arbiter/` dir the release workflow produces. Returned as raw bytes.
  defp release_tarball(tag, migrations \\ [@m_base]) do
    path =
      Path.join(System.tmp_dir!(), "rel-#{tag}-#{System.unique_integer([:positive])}.tar.gz")

    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
    :ok = :erl_tar.add(tar, "#!/bin/sh\necho arbiter #{tag}\n", ~c"arbiter/bin/arbiter", [])
    :ok = :erl_tar.add(tar, "release marker", ~c"arbiter/releases/RELEASE", [])

    # Migrations land where a mix release actually packages them:
    # lib/<app>-<vsn>/priv/repo/migrations/*.exs.
    Enum.each(migrations, fn name ->
      path_in_tar =
        "arbiter/lib/arbiter-#{String.trim_leading(tag, "v")}/priv/repo/migrations/#{name}.exs"

      :ok = :erl_tar.add(tar, "defmodule M do end", String.to_charlist(path_in_tar), [])
    end)

    :ok = :erl_tar.close(tar)

    bytes = File.read!(path)
    File.rm(path)
    bytes
  end

  # One build, one checksum: `:erl_tar.add/4` stamps the current time as each
  # entry's mtime, so two `release_tarball/1` calls straddling a second
  # boundary yield different bytes. Always hash the bytes that get served.
  defp release_tarball_with_sha(tag) do
    tarball = release_tarball(tag)
    {tarball, "#{sha256_hex(tarball)}  x\n"}
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tarball_path(tag), do: "/dl/arbiter-#{tag}-linux.tar.gz"
  defp sha_path(tag), do: tarball_path(tag) <> ".sha256"
  defp arb_path(tag), do: "/dl/#{tag}/arb"
  defp arb_bytes(tag), do: "#!/usr/bin/env escript\n% fake arb #{tag}\n"

  # The GitHub release JSON for `tag`, with assets pointing at our stub paths.
  defp release_json(tag) do
    name = "arbiter-#{tag}-linux.tar.gz"

    %{
      "tag_name" => tag,
      "assets" => [
        %{"name" => name, "browser_download_url" => "https://dl.test#{tarball_path(tag)}"},
        %{
          "name" => name <> ".sha256",
          "browser_download_url" => "https://dl.test#{sha_path(tag)}"
        },
        %{"name" => "arb", "browser_download_url" => "https://dl.test#{arb_path(tag)}"},
        %{
          "name" => "arb.sha256",
          "browser_download_url" => "https://dl.test#{arb_path(tag)}.sha256"
        }
      ]
    }
  end

  defp raw_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/octet-stream")
    |> Plug.Conn.send_resp(status, body)
  end

  # Wire the GitHub API + asset downloads + local API for a full deploy.
  # `workspaces` controls doctor greenness (use @empty to force a red stack).
  defp stub_release(tag, tarball, sha_text, opts \\ []) do
    workspaces = Keyword.get(opts, :workspaces, @green)
    latest? = Keyword.get(opts, :latest, true)
    version_resp = Keyword.get(opts, :version_resp)
    arb_body = Keyword.get(opts, :arb_body, arb_bytes(tag))
    arb_sha_text = Keyword.get(opts, :arb_sha_text, "#{sha256_hex(arb_bytes(tag))}  arb\n")

    api_path =
      if latest?,
        do: "/repos/#{@repo}/releases/latest",
        else: "/repos/#{@repo}/releases/tags/#{tag}"

    version_route =
      if version_resp, do: [{{"get", "/api/version"}, {version_resp, 200}}], else: []

    stub_routes(
      [
        {{"get", api_path}, {release_json(tag), 200}},
        {{"get", tarball_path(tag)}, fn conn -> raw_response(conn, 200, tarball) end},
        {{"get", sha_path(tag)}, fn conn -> raw_response(conn, 200, sha_text) end},
        {{"get", arb_path(tag)}, fn conn -> raw_response(conn, 200, arb_body) end},
        {{"get", arb_path(tag) <> ".sha256"},
         fn conn -> raw_response(conn, 200, arb_sha_text) end},
        {{"get", "/api/workspaces"}, {workspaces, 200}},
        {{"get", "/api/repos"},
         {%{"data" => [%{"name" => "tonic", "source" => "acme", "path" => "/srv/tonic"}]}, 200}},
        {{"get", "/api/workers"}, {@no_workers, 200}}
      ] ++ version_route
    )
  end

  # Cmd runner covering the reused restart lifecycle. `systemd: false` makes
  # `Restart.perform/2` take its SIGTERM-then-start fallback so the stop/start
  # ordering is directly observable.
  defp stub_cmds(opts \\ []) do
    test_pid = self()
    systemd? = Keyword.get(opts, :systemd, true)
    # Fires the instant the restart actually happens (systemctl restart, or
    # the SIGTERM/start pair) — lets a cold-to-green test flip its
    # `/api/workspaces` stub from down to up at exactly that point, rather
    # than guessing how many green-wait polls happen first.
    on_restart = Keyword.get(opts, :on_restart, fn -> :ok end)

    Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})

      case {cmd, args} do
        # systemd unit present → restart delegates to systemctl.
        {"systemctl", ["--user", "cat", "arbiter.service"]} ->
          if systemd?, do: {"", 0}, else: {"Unit arbiter.service could not be found.", 1}

        {"systemctl", ["--user", "restart", "arbiter.service"]} ->
          on_restart.()
          {"", 0}

        # Non-systemd path: one listener to SIGTERM before the fresh start.
        {"lsof", _} ->
          {"4242\n", 0}

        _ ->
          on_restart.()
          {"", 0}
      end
    end)
  end

  # Every `{cmd, args}` the deploy ran, in invocation order.
  defp drain_cmds(acc \\ []) do
    receive do
      {:cmd, cmd, args} -> drain_cmds([{cmd, args} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Stubs the local-API routes a deploy's doctor/restart checks hit,
  # regardless of source (GitHub or `--local`). No GitHub routes here — the
  # `--local` flow never touches the Releases API.
  defp stub_local_apis(opts \\ []) do
    workspaces = Keyword.get(opts, :workspaces, @green)

    stub_routes([
      {{"get", "/api/workspaces"}, {workspaces, 200}},
      {{"get", "/api/repos"},
       {%{"data" => [%{"name" => "tonic", "source" => "acme", "path" => "/srv/tonic"}]}, 200}},
      {{"get", "/api/workers"}, {@no_workers, 200}}
    ])
  end

  # A real, compressed OTP-release-shaped tarball with no leading top-level
  # directory — matching exactly what `.github/workflows/release.yml` packages
  # (`tar -czf … -C _build/prod/rel/arbiter .`), for `--local <tarball>`.
  defp flat_release_tarball(marker \\ "local") do
    path =
      Path.join(System.tmp_dir!(), "local-rel-#{System.unique_integer([:positive])}.tar.gz")

    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
    :ok = :erl_tar.add(tar, "#!/bin/sh\necho arbiter #{marker}\n", ~c"bin/arbiter", [])

    :ok =
      :erl_tar.add(
        tar,
        "defmodule M do end",
        ~c"lib/arbiter-0.0.0/priv/repo/migrations/#{@m_base}.exs",
        []
      )

    :ok = :erl_tar.close(tar)

    bytes = File.read!(path)
    File.rm(path)
    bytes
  end

  # An already-unpacked local release *directory* (e.g. `_build/prod/rel/arbiter`),
  # for `--local <dir>`.
  defp local_release_dir(marker \\ "local", migrations \\ [@m_base]) do
    dir = Path.join(System.tmp_dir!(), "local-rel-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/arbiter"), "#!/bin/sh\necho arbiter #{marker}\n")

    migrations_dir = Path.join(dir, "lib/arbiter-0.0.0/priv/repo/migrations")
    File.mkdir_p!(migrations_dir)

    Enum.each(migrations, fn name ->
      File.write!(Path.join(migrations_dir, name <> ".exs"), "defmodule M do end")
    end)

    dir
  end

  defp seed_release(home, tag, migrations \\ [@m_base]) do
    dir = Path.join([home, "releases", tag])
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/arbiter"), "old")

    if migrations != [] do
      migrations_dir =
        Path.join(dir, "lib/arbiter-#{String.trim_leading(tag, "v")}/priv/repo/migrations")

      File.mkdir_p!(migrations_dir)

      Enum.each(migrations, fn name ->
        File.write!(Path.join(migrations_dir, name <> ".exs"), "defmodule M do end")
      end)
    end

    dir
  end

  defp point_current(home, target_dir) do
    link = Path.join(home, "current")
    File.rm(link)
    File.ln_s!(target_dir, link)
    link
  end

  # ---- happy path --------------------------------------------------------

  describe "release deploy (happy path)" do
    test "downloads, verifies, unpacks, swaps symlink, restarts", %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Deployed release #{@vsn}"
      assert out =~ "Arbiter restarted"
      assert out =~ "[ ok ] phoenix reachable"

      # The release was unpacked with the leading `arbiter/` stripped.
      target = Path.join([home, "releases", @vsn])
      assert File.exists?(Path.join(target, "bin/arbiter"))

      # current symlink now resolves to the new release.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn

      # Migrations are the new release's boot-time job (Arbiter.Boot.Migrator),
      # never a pre-swap eval against the still-running old server.
      refute_received {:cmd, _bin, ["eval", "Arbiter.Release.migrate"]}
      assert_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end

    test "retains the pristine tarball and its checksum beside the unpacked tree (RW4)",
         %{home: home} do
      tarball = release_tarball(@vsn)
      sha = sha256_hex(tarball)
      stub_release(@vsn, tarball, "#{sha}  arbiter-#{@vsn}-linux.tar.gz\n")
      stub_cmds()

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run([]) end)

      retained = Path.join([home, "releases", @vsn <> ".tar.gz"])
      assert File.read!(retained) == tarball
      assert File.read!(retained <> ".sha256") |> String.split() |> hd() == sha
      # a tarball is not a release directory: it must not be mistaken for one
      assert {:ok, _} = File.stat(Path.join([home, "releases", @vsn]))
    end

    test "deploys cleanly (no rollback) when the only workspace isn't named \"default\"" do
      # Regression for bd-8ix2tw: Workspace.resolve/0 used to require a
      # workspace literally named "default", so an install whose sole
      # workspace was named anything else made the (then-fatal) "active
      # workspace resolves" doctor check permanently red — timing out the
      # green-wait and auto-rolling-back every deploy regardless of whether
      # the new release was healthy.
      only_workspace = %{
        "data" => [%{"id" => "ws-acme", "name" => "acme", "prefix" => "ax"}]
      }

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: only_workspace)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Deployed release #{@vsn}"
      refute out =~ "Rolled back"
      assert out =~ "[ ok ] active workspace resolves"
    end

    test "--json emits a single object describing the deploy" do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["version"] == @vsn
      assert payload["deployed"] == true
      assert payload["rolled_back"] == false
      assert payload["ok"] == true
    end

    test "--version targets a specific tag via the tags endpoint" do
      tag = "v2026.6.5"
      tarball = release_tarball(tag)
      sha = "#{sha256_hex(tarball)}  arbiter-#{tag}-linux.tar.gz\n"
      stub_release(tag, tarball, sha, latest: false)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--version", tag]) end)

      assert code == 0
      assert out =~ "Deployed release #{tag}"
    end

    test "idempotent: already on the target release is a no-op", %{home: home} do
      target = seed_release(home, @vsn)
      point_current(home, target)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Already on release #{@vsn}"
      # Never touched migrate or restart.
      refute_received {:cmd, _bin, ["eval", "Arbiter.Release.migrate"]}
      refute_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end
  end

  # ---- --local -------------------------------------------------------------

  describe "arb server deploy --local" do
    test "installs a local tarball through the same unpack/swap/restart path", %{home: home} do
      tarball_bytes = flat_release_tarball()
      path = Path.join(System.tmp_dir!(), "local-#{System.unique_integer([:positive])}.tar.gz")
      File.write!(path, tarball_bytes)
      on_exit(fn -> File.rm(path) end)

      stub_local_apis()
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--local", path]) end)

      assert code == 0
      assert out =~ "Deployed release local-"
      assert out =~ "Arbiter restarted"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) |> String.starts_with?("local-")
      assert File.exists?(Path.join(link_target, "bin/arbiter"))

      # Shares the install machinery with the GitHub flow — no separate swap.
      assert_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end

    test "retains a local tarball too, so a node can fetch exactly what was deployed (RW4)",
         %{home: home} do
      bytes = flat_release_tarball()
      path = Path.join(System.tmp_dir!(), "local-#{System.unique_integer([:positive])}.tar.gz")
      File.write!(path, bytes)
      on_exit(fn -> File.rm(path) end)
      stub_local_apis()
      stub_cmds()

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run(["--local", path]) end)

      {:ok, link_target} = File.read_link(Path.join(home, "current"))
      retained = link_target <> ".tar.gz"
      assert File.read!(retained) == bytes
      assert File.read!(retained <> ".sha256") |> String.split() |> hd() == sha256_hex(bytes)
    end

    test "a local directory retains no tarball (the primary packs an allowlist on demand)",
         %{home: home} do
      dir = local_release_dir()
      on_exit(fn -> File.rm_rf(dir) end)
      stub_local_apis()
      stub_cmds()

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run(["--local", dir]) end)

      assert Path.wildcard(Path.join([home, "releases", "*.tar.gz*"])) == []
    end

    test "installs a local release directory (no tarball)", %{home: home} do
      dir = local_release_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      stub_local_apis()
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--local", dir]) end)

      assert code == 0
      assert out =~ "Deployed release local-"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert File.exists?(Path.join(link_target, "bin/arbiter"))
      # The source directory is untouched (copied, not moved).
      assert File.exists?(Path.join(dir, "bin/arbiter"))
    end

    test "does not require ARB_RELEASE_REPO to be set" do
      System.delete_env("ARB_RELEASE_REPO")
      dir = local_release_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      stub_local_apis()
      stub_cmds()

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run(["--local", dir]) end)

      assert code == 0
    end

    test "failed health check rolls back to the prior release", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      dir = local_release_dir()
      on_exit(fn -> File.rm_rf(dir) end)

      # Empty workspace list → doctor never goes green → health check times out.
      stub_local_apis(workspaces: @empty)
      stub_cmds()

      {out, _err, code} =
        capture(fn -> ReleaseDeploy.run(["--local", dir, "--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back green"
      assert out =~ "Rolled back to #{prior_tag}"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "--allow-cross-migration-rollback is honored for a local deploy", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_base])
      point_current(home, prior)

      dir = local_release_dir("local", [@m_base, "20260202000000_add_thing"])
      on_exit(fn -> File.rm_rf(dir) end)

      stub_local_apis(workspaces: @empty)
      stub_cmds()

      {out, _err, code} =
        capture(fn ->
          ReleaseDeploy.run([
            "--local",
            dir,
            "--timeout",
            "1",
            "--allow-cross-migration-rollback"
          ])
        end)

      assert code == 1

      assert out =~
               "this rollback crossed 1 migration(s) (--allow-cross-migration-rollback was passed)"

      assert out =~ "Rolled back to #{prior_tag}"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "without the override, a crossed-migration local deploy refuses to roll back", %{
      home: home
    } do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_base])
      point_current(home, prior)

      dir = local_release_dir("local", [@m_base, "20260202000000_add_thing"])
      on_exit(fn -> File.rm_rf(dir) end)

      stub_local_apis(workspaces: @empty)
      stub_cmds()

      {out, _err, code} =
        capture(fn -> ReleaseDeploy.run(["--local", dir, "--timeout", "1"]) end)

      assert code == 1
      assert out =~ "Refused to roll back to #{prior_tag}"

      # current still points at the (unhealthy) new local release.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      refute Path.basename(link_target) == prior_tag
    end

    test "a nonexistent --local path aborts with a clear error" do
      stub_local_apis()
      stub_cmds()

      {_out, err, code} =
        capture(fn -> ReleaseDeploy.run(["--local", "/no/such/path"]) end)

      assert code == 1
      assert err =~ "/no/such/path"
    end
  end

  # ---- checksum verification ---------------------------------------------

  describe "checksum verification" do
    test "aborts on sha256 mismatch before swapping the symlink", %{home: home} do
      tarball = release_tarball(@vsn)
      bad_sha = "#{String.duplicate("0", 64)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, bad_sha)
      stub_cmds()

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "checksum mismatch"
      # Nothing was migrated, swapped, or restarted.
      refute File.exists?(Path.join(home, "current"))
      refute_received {:cmd, _bin, ["eval", "Arbiter.Release.migrate"]}
      refute_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end
  end

  # ---- auto-rollback -----------------------------------------------------

  describe "auto-rollback on failed health check" do
    test "re-points current to the prior release and restarts, exits 1", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      # Empty workspace list → doctor never goes green → health check times out.
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back green"
      assert out =~ "Rolled back to #{prior_tag}"

      # current symlink restored to the prior release.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "no prior release: reports the stack is down, exits 1", %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "No prior release to roll back to"
      # The (failed) new release is still what current points at.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "rollback report flags a fatal check that was already red before the deploy started",
         %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      # Zero workspaces → "at least one workspace exists" (fatal) is already
      # red before this deploy touches anything, and stays red throughout —
      # the green-wait times out on that pre-existing condition, not on
      # anything caused by @vsn.
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"
      assert out =~ "note:"
      assert out =~ "at least one workspace exists"
      assert out =~ "already failing before this deploy started"

      # The pre-flight warning itself routes through `log/1` → `Start.log_text/1`,
      # a no-op in tests (bd2_sleep is stubbed in setup/0) — assert its exact
      # content directly rather than relying on it reaching stdout/stderr.
      assert ReleaseDeploy.preflight_warning(["at least one workspace exists"], @vsn) =~
               "warning: 1 readiness-blocking health check(s) already failing before this " <>
                 "deploy started (at least one workspace exists). Run `arb doctor` to " <>
                 "investigate — if this deploy times out waiting for green, that " <>
                 "pre-existing condition, not release #{@vsn}, may be why."
    end

    test "restart reports success but /api/version still shows the prior release (failed swap): rolls back, exits 1",
         %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"

      # Doctor goes green (Phoenix reachable, workspaces exist) — Restart.perform
      # reports {:ok, ...} — but /api/version never moved off the prior release,
      # i.e. the symlink swap/restart silently didn't take.
      stale_version_resp = %{
        "version" => "0.0.2",
        "sha" => "unknown",
        "built_at" => "2023-01-01T00:00:00Z",
        "booted_at" => "2023-01-01T00:01:00Z"
      }

      stub_release(@vsn, tarball, sha, version_resp: stale_version_resp)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert out =~ "still reports 0.0.2"
      assert out =~ "Rolled back to #{prior_tag}"

      # current symlink restored to the prior release — the deploy must not be
      # reported as successful when the server never actually moved.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end
  end

  # ---- cold deploy: server was already down before the deploy began -------
  #
  # bd-5zvux5: the pre-flight doctor snapshot distinguishes "the stack was
  # already down before this deploy touched anything" (first-ever deploy, or
  # a planned-downtime deploy like a DB move where the operator stops the
  # server on purpose) from "this deploy broke a healthy server". Only the
  # latter should ever auto-roll-back — rolling back when there was nothing
  # healthy to preserve just relabels "stack is down" as this deploy's fault.
  describe "cold deploy (server unreachable before the deploy began)" do
    # Unlike `stub_release/4` (whose `/api/workspaces` route is a static
    # 200/fixture), this keeps `/api/workspaces` transport-erroring for every
    # request — before the swap, during the green-wait, and after — so
    # `Restart.perform/2`'s pre-restart `Doctor.reachable?()` sample (which
    # `ReleaseDeploy` uses to tell cold from warm) is genuinely false, the
    # same as a truly stopped server.
    defp stub_release_stack_down(tag, tarball, sha) do
      api_path = "/repos/#{@repo}/releases/latest"

      stub_routes([
        {{"get", api_path}, {release_json(tag), 200}},
        {{"get", tarball_path(tag)}, fn conn -> raw_response(conn, 200, tarball) end},
        {{"get", sha_path(tag)}, fn conn -> raw_response(conn, 200, sha) end},
        {{"get", "/api/workspaces"},
         fn conn -> Req.Test.transport_error(conn, :econnrefused) end},
        {{"get", "/api/workers"}, {@no_workers, 200}}
      ])
    end

    test "no prior release, still unreachable after restart: deploys without rolling back",
         %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release_stack_down(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      refute out =~ "Rolled back"
      refute out =~ "No prior release to roll back to"
      assert out =~ @vsn
      assert out =~ "was already down before this deploy began"

      # current still points at the new release — nothing was rolled back.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
      assert_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end

    test "a prior release exists (planned-downtime deploy, e.g. a DB move): still does not roll back",
         %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release_stack_down(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      refute out =~ "Rolled back to #{prior_tag}"
      assert out =~ "was already down before this deploy began"

      # current still points at the new release, not back at the prior one.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "--json reports cold_deploy: true, deployed: true, rolled_back: false", %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release_stack_down(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} =
        capture(fn -> ReleaseDeploy.run(["--timeout", "1", "--json"]) end)

      assert code == 1
      payload = Jason.decode!(out)

      assert payload["cold_deploy"] == true
      assert payload["deployed"] == true
      assert payload["rolled_back"] == false
      assert payload["version"] == @vsn
      assert payload["ok"] == false

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end
  end

  # ---- cold deploy that goes green (server was down, new release comes up) -
  #
  # bd-5zvux5 round 2: the main case the pre-flight/cold-restart machinery
  # exists for — the stack was down, the new release starts and this time
  # actually comes up green, and the deploy reports a plain success with no
  # rollback and no "the stack is down" framing. `/api/workspaces` transport-
  # errors until the moment the restart actually fires (flipped from
  # `stub_cmds`'s `on_restart` hook), then serves green — the same shape a
  # real "systemctl start" bringing Phoenix up would produce.
  describe "cold deploy that goes green" do
    defp stub_release_cold_to_green(tag, tarball, sha, opts \\ []) do
      latest? = Keyword.get(opts, :latest, true)

      api_path =
        if latest?,
          do: "/repos/#{@repo}/releases/latest",
          else: "/repos/#{@repo}/releases/tags/#{tag}"

      Process.put(:cold_deploy_up, false)

      stub_routes([
        {{"get", api_path}, {release_json(tag), 200}},
        {{"get", tarball_path(tag)}, fn conn -> raw_response(conn, 200, tarball) end},
        {{"get", sha_path(tag)}, fn conn -> raw_response(conn, 200, sha) end},
        {{"get", "/api/workspaces"}, &cold_deploy_workspaces_response/1},
        {{"get", "/api/workers"}, {@no_workers, 200}}
      ])
    end

    defp stub_local_apis_cold_to_green do
      Process.put(:cold_deploy_up, false)

      stub_routes([
        {{"get", "/api/workspaces"}, &cold_deploy_workspaces_response/1},
        {{"get", "/api/workers"}, {@no_workers, 200}}
      ])
    end

    defp cold_deploy_workspaces_response(conn) do
      if Process.get(:cold_deploy_up) do
        conn |> Plug.Conn.put_status(200) |> Req.Test.json(@green)
      else
        Req.Test.transport_error(conn, :econnrefused)
      end
    end

    defp go_up_on_restart, do: fn -> Process.put(:cold_deploy_up, true) end

    test "--version vX: unpacks, swaps, starts, and reports green with no rollback",
         %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release_cold_to_green(@vsn, tarball, sha, latest: false)
      stub_cmds(on_restart: go_up_on_restart())

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--version", @vsn]) end)

      assert code == 0
      assert out =~ "Deployed release #{@vsn}"
      refute out =~ "Rolled back"
      refute out =~ "was already down before this deploy began"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "default (latest) source: unpacks, swaps, starts, and reports green with no rollback",
         %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release_cold_to_green(@vsn, tarball, sha)
      stub_cmds(on_restart: go_up_on_restart())

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Deployed release #{@vsn}"
      refute out =~ "Rolled back"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "--local <tarball>: unpacks, swaps, starts, and reports green with no rollback",
         %{home: home} do
      tarball_bytes = flat_release_tarball()
      path = Path.join(System.tmp_dir!(), "local-#{System.unique_integer([:positive])}.tar.gz")
      File.write!(path, tarball_bytes)
      on_exit(fn -> File.rm(path) end)

      stub_local_apis_cold_to_green()
      stub_cmds(on_restart: go_up_on_restart())

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--local", path]) end)

      assert code == 0
      assert out =~ "Deployed release local-"
      refute out =~ "Rolled back"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) |> String.starts_with?("local-")
    end
  end

  # ---- transient restart-time blip is not a cold deploy (bd-5zvux5 round 2) -
  #
  # `Restart.perform/2`'s "was it running before?" sample is a single GET with
  # no retry (`client.ex`), so a healthy server that merely stalls (GC pause,
  # busy DB) for that one request can sample false even though the pre-flight
  # snapshot, taken moments earlier, saw it green. Treating that alone as
  # "cold" would skip auto-rollback on a deploy that broke a genuinely healthy
  # server — this must still roll back exactly as before bd-5zvux5.
  describe "restart-time sample errors despite a green pre-flight" do
    # 1st /api/workspaces call is the pre-flight snapshot (green). 2nd is
    # `Restart.perform/2`'s own pre-restart sample (the transient blip). Every
    # call after that is the green-wait loop, which we keep red so the deploy
    # times out and reaches the rollback decision under test.
    defp workspaces_transient_blip_response(conn) do
      n = Process.get(:ws_call_count, 0) + 1
      Process.put(:ws_call_count, n)

      case n do
        1 -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(@green)
        2 -> Req.Test.transport_error(conn, :econnrefused)
        _ -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(@empty)
      end
    end

    defp stub_release_transient_blip(tag, tarball, sha) do
      api_path = "/repos/#{@repo}/releases/latest"
      Process.put(:ws_call_count, 0)

      stub_routes([
        {{"get", api_path}, {release_json(tag), 200}},
        {{"get", tarball_path(tag)}, fn conn -> raw_response(conn, 200, tarball) end},
        {{"get", sha_path(tag)}, fn conn -> raw_response(conn, 200, sha) end},
        {{"get", "/api/workspaces"}, &workspaces_transient_blip_response/1},
        {{"get", "/api/workers"}, {@no_workers, 200}}
      ])
    end

    test "still rolls back — a single errored sample does not make this a cold deploy",
         %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release_transient_blip(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"
      refute out =~ "was already down before this deploy began"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end
  end

  # ---- migration ordering (bd-bksulf) ------------------------------------

  describe "migration ordering" do
    @m_old "20260101000000_create_things"
    @m_new "20260202000000_add_flag_to_things"

    test "never evals Arbiter.Release.migrate — not even when the new release adds migrations",
         %{home: home} do
      prior = seed_release(home, "v0.0.2", [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_new])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      cmds = drain_cmds()
      # Acceptance 1: no migration runs while the previous server is serving.
      # The only lifecycle command is the stop-then-start systemd restart; the
      # new release migrates on its own boot, after the old one is gone.
      refute Enum.any?(cmds, fn {_cmd, args} ->
               match?(["eval", "Arbiter.Release.migrate"], args)
             end)

      assert {"systemctl", ["--user", "restart", "arbiter.service"]} in cmds
    end

    test "non-systemd path orders stop → start with no migrate in between", %{home: home} do
      prior = seed_release(home, "v0.0.2", [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_new])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds(systemd: false)

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      cmds = drain_cmds()

      refute Enum.any?(cmds, fn {_cmd, args} ->
               match?(["eval", "Arbiter.Release.migrate"], args)
             end)

      kill_at = Enum.find_index(cmds, fn {cmd, _args} -> cmd == "kill" end)

      start_at =
        Enum.find_index(cmds, fn {cmd, args} ->
          cmd == "sh" and match?(["-c", _], args) and hd(tl(args)) =~ "phx.server"
        end)

      assert is_integer(kill_at), "expected the old server to be SIGTERMed"
      assert is_integer(start_at), "expected a fresh server start"
      assert kill_at < start_at, "the old server must be stopped before the new one starts"
    end

    test "warns up-front that the deploy crosses migrations and rollback is off" do
      plan = %{prior_target: "/rel/v0.0.2", crossed: [@m_new], allow_crossed: false}

      notice = ReleaseDeploy.cross_migration_notice(plan, @vsn)

      assert notice =~ "release #{@vsn} adds 1 migration(s)"
      assert notice =~ @m_new
      assert notice =~ "They apply during the new release's boot."
      assert notice =~ "Automatic rollback is therefore disabled for this deploy."
    end

    test "warns up-front that a forced cross-migration rollback is armed" do
      plan = %{prior_target: "/rel/v0.0.2", crossed: [@m_new], allow_crossed: true}

      notice = ReleaseDeploy.cross_migration_notice(plan, @vsn)

      assert notice =~ "--allow-cross-migration-rollback was passed"
      assert notice =~ "onto the migrated schema"
      refute notice =~ "Automatic rollback is therefore disabled"
    end
  end

  # ---- cross-migration rollback (bd-bksulf) -------------------------------

  describe "cross-migration rollback guard" do
    @m_old "20260101000000_create_things"
    @m_a "20260202000000_add_flag_to_things"
    @m_b "20260303000000_drop_legacy"

    test "refuses to auto-roll back when the new release added migrations", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a, @m_b])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back green"
      assert out =~ "Refused to roll back"
      # The migrations are named, so the operator knows what is stranded.
      assert out =~ @m_a
      assert out =~ @m_b
      # The release booted (Boot.Migrator runs before the endpoint opens), it
      # just never went green — so the schema really did move.
      assert out =~ "already been applied to the database"
      assert out =~ "--allow-cross-migration-rollback"
      refute out =~ "Rolled back to #{prior_tag}"

      # current stays on the new release — old code must not boot against the
      # migrated schema behind the operator's back.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "--allow-cross-migration-rollback rolls back anyway, loudly", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} =
        capture(fn ->
          ReleaseDeploy.run(["--timeout", "1", "--allow-cross-migration-rollback"])
        end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"
      assert out =~ "this rollback crossed 1 migration(s)"
      assert out =~ "is now running against a newer schema"
      assert out =~ @m_a

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "identical migration sets: automatic rollback is unchanged", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old, @m_a])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"
      refute out =~ "Refused to roll back"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "a failed swap (stale /api/version) also refuses a cross-migration rollback", %{
      home: home
    } do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"

      stale_version_resp = %{
        "version" => "0.0.2",
        "sha" => "unknown",
        "built_at" => "2023-01-01T00:00:00Z",
        "booted_at" => "2023-01-01T00:01:00Z"
      }

      stub_release(@vsn, tarball, sha, version_resp: stale_version_resp)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert out =~ "still reports 0.0.2"
      assert out =~ "Refused to roll back"
      assert out =~ @m_a
      refute out =~ "Rolled back to #{prior_tag}"

      # The swap did not take, so the new release never booted and its
      # migrations may never have run. Refuse anyway (we cannot prove the
      # rollback is safe), but do not assert a schema change as fact.
      refute out =~ "already been applied to the database"
      assert out =~ "cannot be determined from here"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "--json reports the refusal and names the crossed migrations", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1", "--json"]) end)

      assert code == 1
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["rolled_back"] == false
      assert payload["rollback_refused"] == true
      assert payload["crossed_migrations"] == [@m_a]
      assert payload["rolled_back_to"] == nil
    end

    test "--json on a same-schema rollback reports no refusal", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1", "--json"]) end)

      assert code == 1
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["rolled_back"] == true
      assert payload["rollback_refused"] == false
      assert payload["crossed_migrations"] == []
      assert payload["rolled_back_to"] == prior_tag
      assert payload["migrations_detected"] == true
    end
  end

  # ---- detection must fail closed (bd-bksulf review round 1, finding 2) ----

  describe "migration detection failure" do
    @m_old "20260101000000_create_things"

    test "a release whose migrations cannot be found refuses to auto-roll back", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      # The new release ships nothing at lib/*/priv/repo/migrations — the shape
      # a relocated `priv/` would produce. An arbiter release always ships
      # migrations, so this is broken detection, not a migration-free deploy,
      # and it must not silently re-arm the rollback.
      tarball = release_tarball(@vsn, [])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "Refused to roll back"
      assert out =~ "no migrations could be found in release #{@vsn}"
      assert out =~ "--allow-cross-migration-rollback"
      refute out =~ "Rolled back to #{prior_tag}"

      # current stays on the new release rather than putting the prior release
      # on a schema we cannot vouch for.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "--json distinguishes 'nothing crossed' from 'detection failed'", %{home: home} do
      prior = seed_release(home, "v0.0.2", [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1", "--json"]) end)

      assert code == 1
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["rolled_back"] == false
      assert payload["rollback_refused"] == true
      assert payload["crossed_migrations"] == []
      # …and the empty list above is explained, not mistaken for "safe".
      assert payload["migrations_detected"] == false
    end

    test "--allow-cross-migration-rollback still overrides a detection failure", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} =
        capture(fn ->
          ReleaseDeploy.run(["--timeout", "1", "--allow-cross-migration-rollback"])
        end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "warns up-front that migration detection came back empty" do
      plan = %{
        prior_target: "/rel/v0.0.2",
        crossed: [],
        detected: false,
        allow_crossed: false
      }

      notice = ReleaseDeploy.migration_notice(plan, @vsn)

      assert notice =~ "found no migrations packaged in release #{@vsn}"
      assert notice =~ "lib/*/priv/repo/migrations/*.exs"
      assert notice =~ "Automatic rollback is therefore disabled for this deploy."
    end

    test "no notice at all when detection worked and nothing crossed" do
      plan = %{
        prior_target: "/rel/v0.0.2",
        crossed: [],
        detected: true,
        allow_crossed: false
      }

      assert ReleaseDeploy.migration_notice(plan, @vsn) == nil
    end
  end

  # ---- pruning -----------------------------------------------------------

  describe "pruning old releases" do
    test "retains current + 3 most-recent priors, deletes older", %{home: home} do
      # Six pre-existing releases with increasing mtimes; current points at the
      # newest of them.
      old_tags = ~w(v1 v2 v3 v4 v5 v6)

      Enum.each(Enum.with_index(old_tags), fn {tag, i} ->
        dir = seed_release(home, tag)
        # mtime increasing with index so :desc sort is v6 > v5 > … > v1.
        File.touch!(dir, {{2026, 1, 1 + i}, {0, 0, 0}})
      end)

      prior = Path.join([home, "releases", "v6"])
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Pruned"

      remaining =
        Path.join(home, "releases")
        |> File.ls!()
        |> Enum.sort()

      # Kept: new (@vsn) + prior (v6) + 3 newest others (v5, v4, v3).
      # Pruned: v1, v2.
      assert @vsn in remaining
      assert "v6" in remaining
      assert "v5" in remaining
      assert "v4" in remaining
      assert "v3" in remaining
      refute "v2" in remaining
      refute "v1" in remaining
    end
  end

  # ---- config errors -----------------------------------------------------

  describe "configuration errors" do
    test "no resolvable release repo aborts with a hint" do
      System.delete_env("ARB_RELEASE_REPO")
      Process.put(:bd2_build_release_repo, false)

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "ARB_RELEASE_REPO"
    end

    test "no matching release (404) aborts" do
      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {%{"message" => "Not Found"}, 404}},
        {{"get", "/api/workers"}, {@no_workers, 200}},
        {{"get", "/api/workspaces"}, {@green, 200}}
      ])

      stub_cmds()

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "no latest release found"
    end
  end

  # ---- PATH refresh -------------------------------------------------------

  describe "PATH refresh in arbiter.env" do
    test "deploy writes the deploying shell's PATH into arbiter.env", %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      prior_path = System.get_env("PATH")
      System.put_env("PATH", "/deploy/shell/bin:/usr/bin")

      on_exit(fn ->
        if prior_path, do: System.put_env("PATH", prior_path), else: System.delete_env("PATH")
      end)

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      env_file = Path.join(home, "arbiter.env")
      assert File.exists?(env_file)
      contents = File.read!(env_file)
      assert contents =~ "PATH=/deploy/shell/bin:/usr/bin"
    end

    test "deploy overwrites a stale PATH in arbiter.env with the deploying shell's PATH", %{
      home: home
    } do
      # Pre-seed a corrupted arbiter.env (simulating test pollution or a
      # previous bad deploy).
      env_file = Path.join(home, "arbiter.env")
      File.write!(env_file, "GITHUB_TOKEN=tok\nPATH=/second/path:/usr/bin\n")

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      prior_path = System.get_env("PATH")
      System.put_env("PATH", "/correct/bin:/usr/local/bin:/usr/bin")

      on_exit(fn ->
        if prior_path, do: System.put_env("PATH", prior_path), else: System.delete_env("PATH")
      end)

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      contents = File.read!(env_file)
      # The stale placeholder is gone; the correct PATH is in place.
      refute contents =~ "/second/path"
      assert contents =~ "PATH=/correct/bin:/usr/local/bin:/usr/bin"
      # Unrelated keys are preserved.
      assert contents =~ "GITHUB_TOKEN=tok"
    end
  end

  # ---- worker guard ------------------------------------------------------

  describe "active-work guard" do
    test "refuses deploy when workers are actively working (no --force)" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/workers"},
         {%{"data" => [%{"task_id" => "bd-xyz", "kind" => "implement", "state" => "working"}]},
          200}}
      ])

      stub_cmds()

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "worker"
      assert err =~ "bd-xyz"
    end
  end

  # ---- pre-swap database backup + restore (bd-6umf7z) ----------------------

  describe "pre-swap database backup" do
    @magic "SQLite format 3\0"
    @m_old "20260101000000_create_things"
    @m_new "20260202000000_add_flag_to_things"

    alias ArbiterCli.Cmd.ReleaseDeploy.Status

    defp db_file(home), do: Path.join(home, "arbiter.sqlite3")
    defp write_db(home, content), do: File.write!(db_file(home), @magic <> content)
    defp read_db(home), do: File.read!(db_file(home))

    # Stand in for `bin/arbiter eval Arbiter.Release.Backup.eval_from_env()`: a
    # real one copies the live DB (VACUUM INTO) to ARB_BACKUP_DEST. The copy is
    # made at the moment of the eval, so the swap/restart order is observable.
    defp stub_backup(home, opts \\ []) do
      base = Process.get(:bd2_cmd_runner)
      test_pid = self()

      Process.put(:bd2_cmd_runner, fn cmd, args, run_opts ->
        case args do
          ["eval", "Arbiter.Release.Backup.eval_from_env()"] ->
            env = Map.new(run_opts[:env])
            send(test_pid, {:backup_eval, File.read_link(Path.join(home, "current")), cmd, env})

            if Keyword.get(opts, :fail, false) do
              {"integrity_check: row 3 missing from index", 1}
            else
              File.mkdir_p!(Path.dirname(env["ARB_BACKUP_DEST"]))
              File.cp!(env["ARB_BACKUP_SRC"], env["ARB_BACKUP_DEST"])
              {Jason.encode!(%{ok: true}), 0}
            end

          _ ->
            send(test_pid, {:ran, cmd, args})
            base.(cmd, args, run_opts)
        end
      end)
    end

    # restart #1 is the new release booting (it migrates the DB, then never goes
    # green); restart #2 is the prior release coming back, green.
    defp migrating_restarts(home) do
      fn ->
        n = (Process.get(:restarts) || 0) + 1
        Process.put(:restarts, n)

        case n do
          1 -> write_db(home, "migrated-by-new-release")
          _ -> stub_local_apis(workspaces: @green)
        end
      end
    end

    defp tagged_release(tag, migrations) do
      tarball = release_tarball(tag, migrations)
      {tarball, "#{sha256_hex(tarball)}  arbiter-#{tag}-linux.tar.gz\n"}
    end

    defp prior_release(home, migrations) do
      prior = seed_release(home, "v0.0.2", migrations)
      point_current(home, prior)
      prior
    end

    test "snapshots the live DB before the swap and reports the path in text and JSON",
         %{home: home} do
      prior_release(home, [@m_old])
      write_db(home, "live-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old])
      stub_release(@vsn, tarball, sha)
      stub_cmds()
      stub_backup(home)

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      path = payload["backup"]["path"]
      assert Path.dirname(path) == Path.join(home, "snapshots")
      assert Path.basename(path) =~ ~r/\Aarbiter-pre-#{@vsn}-\d{8}T\d{6}Z\.sqlite3\z/
      assert File.read!(path) == @magic <> "live-data"
      assert payload["backup"]["bytes"] == byte_size(@magic <> "live-data")

      # Taken *before* the swap: `current` still pointed at the prior release.
      assert_received {:backup_eval, {:ok, before_swap}, bin, env}
      assert Path.basename(before_swap) == "v0.0.2"
      assert bin == Path.join([home, "releases", @vsn, "bin/arbiter"])
      assert env["ARB_BACKUP_SRC"] == db_file(home)

      # …and then the swap happened.
      assert {:ok, link} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link) == @vsn
    end

    test "text output names the backup", %{home: home} do
      prior_release(home, [@m_old])
      write_db(home, "live-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old])
      stub_release(@vsn, tarball, sha)
      stub_cmds()
      stub_backup(home)

      {out, _err, 0} = capture(fn -> ReleaseDeploy.run([]) end)
      assert out =~ "Database backup:"
      assert out =~ "snapshots/arbiter-pre-#{@vsn}-"
    end

    test "no database yet (a fresh host) skips the backup and says so", %{home: home} do
      {tarball, sha} = tagged_release(@vsn, [@m_old])
      stub_release(@vsn, tarball, sha)
      stub_cmds()
      stub_backup(home)

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["backup"] == nil
      refute_received {:backup_eval, _, _, _}
    end

    test "a failed backup or integrity check aborts before anything is swapped",
         %{home: home} do
      prior = prior_release(home, [@m_old])
      write_db(home, "live-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old, @m_new])
      stub_release(@vsn, tarball, sha)
      stub_cmds()
      stub_backup(home, fail: true)

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "database backup failed"
      assert err =~ "integrity_check"

      # Nothing swapped, nothing restarted, the database untouched.
      assert {:ok, link} = File.read_link(Path.join(home, "current"))
      assert link == prior
      refute_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
      assert read_db(home) == @magic <> "live-data"

      assert %{"state" => "failed", "tag" => @vsn, "message" => msg} = Status.read()
      assert msg =~ "backup"
    end

    test "a failed health check of a release with migrations restores the backup and the " <>
           "previous release comes back green",
         %{home: home} do
      prior = prior_release(home, [@m_old])
      write_db(home, "v0.0.2-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old, @m_new])
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds(on_restart: migrating_restarts(home))
      stub_backup(home)

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back green"
      assert out =~ "Rolled back to v0.0.2"
      assert out =~ "Restored the database"
      refute out =~ "Refused to roll back"

      # The migrated database is gone from the live path; the backup is in it.
      assert read_db(home) == @magic <> "v0.0.2-data"

      # …but nothing was deleted: the migrated one is kept aside, named in the output.
      [failed] = Path.wildcard(Path.join(home, "snapshots/arbiter-failed-#{@vsn}-*.sqlite3"))
      assert File.read!(failed) == @magic <> "migrated-by-new-release"
      assert out =~ failed

      # `current` is back on the prior release, which came back green.
      assert {:ok, link} = File.read_link(Path.join(home, "current"))
      assert link == prior
      assert out =~ "[ ok ] phoenix reachable"
      assert out =~ "[ ok ] active workspace resolves"

      # Order: stop (database safe to touch) → restore → swap/restart.
      cmds = drain_cmds()
      assert Enum.member?(cmds, {"systemctl", ["--user", "stop", "arbiter.service"]})

      restarts =
        Enum.filter(cmds, &(&1 == {"systemctl", ["--user", "restart", "arbiter.service"]}))

      assert length(restarts) == 2

      assert %{
               "state" => "rolled_back",
               "rolled_back_to" => "v0.0.2",
               "restored_database" => true
             } =
               Status.read()
    end

    test "--json reports the restore", %{home: home} do
      prior_release(home, [@m_old])
      write_db(home, "v0.0.2-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old, @m_new])
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds(on_restart: migrating_restarts(home))
      stub_backup(home)

      {out, _err, 1} = capture(fn -> ReleaseDeploy.run(["--timeout", "1", "--json"]) end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["rolled_back"] == true
      assert payload["rollback_refused"] == false
      assert payload["restored_database"] == true
      assert payload["crossed_migrations"] == [@m_new]
      assert payload["backup_path"] =~ "arbiter-pre-#{@vsn}-"
      assert payload["failed_database_path"] =~ "arbiter-failed-#{@vsn}-"
    end

    test "a failed release that adds no migrations rolls back WITHOUT touching the database",
         %{home: home} do
      prior_release(home, [@m_old])
      write_db(home, "v0.0.2-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old])
      stub_release(@vsn, tarball, sha, workspaces: @empty)

      # The new release writes to the database while it is up (it is serving).
      stub_cmds(on_restart: fn -> write_db(home, "written-while-new-release-ran") end)
      stub_backup(home)

      {out, _err, 1} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert out =~ "Rolled back to v0.0.2"
      refute out =~ "Restored the database"
      # Restoring would throw those writes away for no schema benefit.
      assert read_db(home) == @magic <> "written-while-new-release-ran"
      refute_received {:ran, "systemctl", ["--user", "stop", "arbiter.service"]}
      assert %{"state" => "rolled_back", "restored_database" => false} = Status.read()
    end

    test "--allow-cross-migration-rollback still restores rather than rolling back onto the " <>
           "migrated schema",
         %{home: home} do
      prior_release(home, [@m_old])
      write_db(home, "v0.0.2-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old, @m_new])
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds(on_restart: migrating_restarts(home))
      stub_backup(home)

      {out, _err, 1} =
        capture(fn ->
          ReleaseDeploy.run(["--timeout", "1", "--allow-cross-migration-rollback"])
        end)

      assert out =~ "Restored the database"
      refute out =~ "is now running against a newer schema"
      assert read_db(home) == @magic <> "v0.0.2-data"
    end

    test "a swap that did not take (stale /api/version) never restores: the old release " <>
           "kept serving and its writes would be lost",
         %{home: home} do
      prior_release(home, [@m_old])
      write_db(home, "v0.0.2-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old, @m_new])

      stale = %{"version" => "0.0.2", "sha" => "x", "built_at" => "x", "booted_at" => "x"}
      stub_release(@vsn, tarball, sha, version_resp: stale)
      stub_cmds(on_restart: fn -> write_db(home, "old-release-still-writing") end)
      stub_backup(home)

      {out, _err, 1} = capture(fn -> ReleaseDeploy.run([]) end)

      assert out =~ "Refused to roll back"
      assert read_db(home) == @magic <> "old-release-still-writing"
      refute_received {:ran, "systemctl", ["--user", "stop", "arbiter.service"]}
    end

    test "a stop that fails leaves the database alone and refuses", %{home: home} do
      prior_release(home, [@m_old])
      write_db(home, "v0.0.2-data")
      {tarball, sha} = tagged_release(@vsn, [@m_old, @m_new])
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds(on_restart: migrating_restarts(home))

      base = Process.get(:bd2_cmd_runner)

      Process.put(:bd2_cmd_runner, fn cmd, args, opts ->
        if {cmd, args} == {"systemctl", ["--user", "stop", "arbiter.service"]},
          do: {"Failed to stop", 1},
          else: base.(cmd, args, opts)
      end)

      stub_backup(home)

      {out, _err, 1} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert out =~ "Refused to roll back"
      assert out =~ "could not stop"
      assert read_db(home) == @magic <> "migrated-by-new-release"
    end

    test "old snapshots are pruned to the configured count after a green deploy", %{home: home} do
      System.put_env("ARB_DEPLOY_BACKUP_RETAIN", "2")
      prior_release(home, [@m_old])
      write_db(home, "live")
      snapshots = Path.join(home, "snapshots")
      File.mkdir_p!(snapshots)

      for i <- 1..4,
          do:
            File.write!(
              Path.join(snapshots, "arbiter-pre-v0.0.#{i}-2026010#{i}T000000Z.sqlite3"),
              @magic
            )

      {tarball, sha} = tagged_release(@vsn, [@m_old])
      stub_release(@vsn, tarball, sha)
      stub_cmds()
      stub_backup(home)

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run([]) end)

      names = snapshots |> File.ls!() |> Enum.sort()
      assert length(names) == 2
      assert Enum.any?(names, &String.contains?(&1, "arbiter-pre-#{@vsn}-"))
    end
  end

  # ---- deploy status file (bd-6umf7z) --------------------------------------

  describe "deploy status record" do
    alias ArbiterCli.Cmd.ReleaseDeploy.Status

    test "a green deploy records success, the tag and no secrets", %{home: home} do
      System.put_env("GITHUB_TOKEN", "ghp_supersecrettokenvalue123")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      {tarball, sha} = release_tarball_with_sha(@vsn)
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run([]) end)

      assert %{"state" => "succeeded", "tag" => @vsn, "finished_at" => _} = Status.read()
      refute File.read!(Status.path()) =~ "ghp_supersecrettokenvalue123"
      _ = home
    end

    test "an early failure (bad checksum) is recorded as failed, not left running" do
      tarball = release_tarball(@vsn)
      stub_release(@vsn, tarball, String.duplicate("0", 64) <> "  x\n")
      stub_cmds()

      {_out, _err, 1} = capture(fn -> ReleaseDeploy.run([]) end)

      assert %{"state" => "failed", "tag" => @vsn, "message" => msg} = Status.read()
      assert msg =~ "checksum"
    end

    test "an active-worker refusal is recorded as failed, with the reason" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/workers"},
         {%{"data" => [%{"task_id" => "bd-xyz", "kind" => "implement", "state" => "working"}]},
          200}}
      ])

      stub_cmds()

      {_out, _err, 1} = capture(fn -> ReleaseDeploy.run(["--version", @vsn]) end)

      assert %{"state" => "failed", "tag" => @vsn, "message" => msg, "finished_at" => _} =
               Status.read()

      assert msg =~ "actively working"
    end

    test "a release lookup failure is recorded as failed, with the reason" do
      stub_routes([{{"get", "/api/workspaces"}, {@green, 200}}])
      stub_cmds()

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run(["--version", "v404.0.0"]) end)

      assert code != 0
      assert %{"state" => "failed", "tag" => "v404.0.0", "message" => msg} = Status.read()
      assert is_binary(msg) and msg != ""
    end

    test "a refused rollback is recorded as refused", %{home: home} do
      prior = seed_release(home, "v0.0.2", [@m_base])
      point_current(home, prior)
      tarball = release_tarball(@vsn, [@m_base, "20260202000000_x"])
      stub_release(@vsn, tarball, "#{sha256_hex(tarball)}  x\n", workspaces: @empty)
      stub_cmds()

      {_out, _err, 1} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert %{"state" => "refused", "tag" => @vsn} = Status.read()
    end

    test "an already-current deploy leaves a prior record untouched", %{home: home} do
      point_current(home, seed_release(home, @vsn))
      Status.start("v0.0.1", %{})
      Status.finish("succeeded", %{})
      tarball = release_tarball(@vsn)
      stub_release(@vsn, tarball, "#{sha256_hex(tarball)}  x\n")
      stub_cmds()

      {_out, _err, 0} = capture(fn -> ReleaseDeploy.run([]) end)

      assert %{"tag" => "v0.0.1"} = Status.read()
    end
  end

  # ---- no secrets in output or logs (bd-6umf7z) -----------------------------

  describe "secrets" do
    @token "ghp_supersecrettokenvalue123"

    setup do
      System.put_env("GITHUB_TOKEN", @token)
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)
    end

    defp everything_printed(fun) do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(self(), {:result, capture(fun)})
        end)

      assert_received {:result, {out, err, code}}
      {out <> err <> log, code}
    end

    test "a green deploy prints and logs no token", %{home: home} do
      write_db_for_secrets(home)
      {tarball, sha} = release_tarball_with_sha(@vsn)
      stub_release(@vsn, tarball, sha)
      stub_cmds()
      stub_backup(home)

      {printed, 0} = everything_printed(fn -> ReleaseDeploy.run(["--json"]) end)

      refute printed =~ @token
      refute File.read!(ArbiterCli.Cmd.ReleaseDeploy.Status.path()) =~ @token
    end

    test "a failed backup whose eval output echoes the token is redacted", %{home: home} do
      write_db_for_secrets(home)
      {tarball, sha} = release_tarball_with_sha(@vsn)
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      base = Process.get(:bd2_cmd_runner)

      Process.put(:bd2_cmd_runner, fn cmd, args, opts ->
        case args do
          ["eval", "Arbiter.Release.Backup.eval_from_env()"] ->
            {"crashed with GITHUB_TOKEN=#{@token}", 1}

          _ ->
            base.(cmd, args, opts)
        end
      end)

      File.write!(Path.join(home, "arbiter.env"), "GITHUB_TOKEN=#{@token}\n")

      {printed, 1} = everything_printed(fn -> ReleaseDeploy.run([]) end)

      assert printed =~ "database backup failed"
      refute printed =~ @token
      refute File.read!(ArbiterCli.Cmd.ReleaseDeploy.Status.path()) =~ @token
    end

    defp write_db_for_secrets(home),
      do: File.write!(Path.join(home, "arbiter.sqlite3"), "SQLite format 3\0")
  end

  # ---- matching CLI after a green deploy (bd-6umf7z) -----------------------

  describe "CLI self-update after a green deploy" do
    test "installs the escript for the same tag and reports it", %{home: home} do
      {tarball, sha} = release_tarball_with_sha(@vsn)
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert %{"updated" => true, "version" => @vsn} = payload["cli_update"]
      assert File.read!(Path.join(home, "bin/arb")) == arb_bytes(@vsn)
    end

    test "text output says the CLI was updated", %{home: home} do
      {tarball, sha} = release_tarball_with_sha(@vsn)
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, 0} = capture(fn -> ReleaseDeploy.run([]) end)

      assert out =~ "Updated arb to #{@vsn}"
      assert File.exists?(Path.join(home, "bin/arb"))
    end

    test "--no-self-update leaves the CLI alone", %{home: home} do
      {tarball, sha} = release_tarball_with_sha(@vsn)
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, 0} = capture(fn -> ReleaseDeploy.run(["--json", "--no-self-update"]) end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["cli_update"] == nil
      refute File.exists?(Path.join(home, "bin/arb"))
    end

    test "a failing self-update does not fail the (already healthy) deploy", %{home: home} do
      tarball = release_tarball(@vsn)

      # The escript download no longer matches its published checksum.
      stub_release(@vsn, tarball, "#{sha256_hex(tarball)}  x\n",
        arb_body: "tampered",
        arb_sha_text: "#{sha256_hex("the real one")}  arb\n"
      )

      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["deployed"] == true
      assert payload["ok"] == true
      assert payload["cli_update"]["updated"] == false
      assert payload["cli_update"]["error"] =~ "checksum"
      refute File.exists?(Path.join(home, "bin/arb"))
    end

    test "--local deploys do not touch the CLI (a local build has no matching release)",
         %{home: home} do
      stub_local_apis()
      stub_cmds()

      {_out, _err, 0} =
        capture(fn -> ReleaseDeploy.run(["--local", local_release_dir()]) end)

      refute File.exists?(Path.join(home, "bin/arb"))
    end

    test "the output names the release repo and where it was resolved from" do
      {tarball, sha} = release_tarball_with_sha(@vsn)
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, err, 0} = capture(fn -> ReleaseDeploy.run(["--json"]) end)

      assert err =~ "Release source: #{@repo} (from ARB_RELEASE_REPO)"
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["release_repo"] == @repo
      assert payload["release_repo_source"] == "env"
    end
  end
end
