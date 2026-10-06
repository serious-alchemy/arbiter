defmodule ArbiterCli.Cmd.DoctorTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Doctor
  alias ArbiterCli.Cmd.Doctor.Checks

  @workspaces_resp %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  @repos_resp %{
    "data" => [
      %{"name" => "tonic", "source" => "default", "path" => "/srv/tonic"}
    ]
  }

  defp legacy_workspaces_resp do
    %{
      "data" => [
        %{
          "id" => "ws-1",
          "name" => "default",
          "prefix" => "bd",
          "config" => %{"rig_paths" => %{"tonic" => "/srv/tonic"}}
        }
      ]
    }
  end

  # Use the actual compiled CLI version so the version check passes in all-green tests.
  defp matching_version_resp do
    %{
      "version" => ArbiterCli.Version.app_version(),
      "sha" => ArbiterCli.Version.git_sha_clean(),
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }
  end

  test "all-green when Phoenix responds with a workspace named default" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[ ok ] active workspace resolves"
    assert out =~ "[ ok ] version"
    assert out =~ "[ ok ] migrations up to date"
  end

  test "pending migrations shows [fail] with count in detail" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "warning", "pending_count" => 3}, 200}}
    ])

    {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
    assert out =~ "[fail] migrations up to date"
    assert out =~ "3 pending"
  end

  test "unreachable DB or DB error shows [fail] with 'could not check'" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"},
       {%{"status" => "unknown", "pending_count" => nil, "error" => "unreachable"}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] migrations up to date"
    assert out =~ "could not check"
    refute out =~ "[ ok ] migrations up to date"
  end

  # bd-337f2i round 1 regression: a server predating the migrations endpoint
  # returns 404, landing exactly in the mid-deploy version-skew window this
  # check exists for — that must not be a hard [fail], consistent with how
  # check_versions/0 treats server errors.
  test "server without the migrations endpoint (404) does not fail doctor" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{}, 404}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] migrations up to date"
  end

  test "unexpected migrations response shape does not crash doctor" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"unexpected" => "shape"}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] migrations up to date"
  end

  test "connection refused → all fail with actionable hint" do
    stub_transport_error(:get, "/api/workspaces", :econnrefused)

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 1
    assert out =~ "[fail] phoenix reachable"
    assert out =~ "mix phx.server"
  end

  test "connection refused on a release install hints at the service manager, not mix phx.server" do
    Process.put(:bd2_dev_build, false)
    stub_transport_error(:get, "/api/workspaces", :econnrefused)

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 1
    assert out =~ "[fail] phoenix reachable"
    refute out =~ "mix phx.server"
    assert out =~ "systemctl --user start arbiter"
  end

  test "no workspaces → workspace check fails with hint" do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => []}, 200}},
      {{"get", "/api/repos"}, {%{"data" => []}, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 1
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[fail] at least one workspace exists"
    assert out =~ "seeds.exs"
  end

  test "--json emits structured payload" do
    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run(["--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"ok" => true, "checks" => checks}} = Jason.decode(String.trim(out))
    assert is_list(checks)
    assert length(checks) == 30
  end

  test "version mismatch is non-fatal (exit 0 but shows [fail])" do
    mismatched_version_resp = %{
      "version" => "9.9.9",
      "sha" => "mismatched_sha",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {mismatched_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[ ok ] active workspace resolves"
    assert out =~ "[fail] version"
    assert out =~ "server 9.9.9"
    assert out =~ "CLI #{ArbiterCli.Version.app_version()}"
    refute out =~ "CLI and server match"
  end

  test "version mismatch does not block arb start readiness" do
    mismatched_version_resp = %{
      "version" => "9.9.9",
      "sha" => "mismatched_sha",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {mismatched_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    assert Doctor.green?() == true
  end

  test "release build (SHA unavailable) with matching version shows [ ok ]" do
    # When the server is an OTP release, it may report sha: "unknown" because
    # no git process is available at runtime. If the semantic version matches
    # the CLI, the check should pass — this is the expected state after
    # `arb server deploy`.
    release_version_resp = %{
      "version" => ArbiterCli.Version.app_version(),
      "sha" => "unknown",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {release_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[ ok ] version"
    assert out =~ "CLI and server match"
  end

  test "release build (SHA unavailable) with matching version is fully green" do
    release_version_resp = %{
      "version" => ArbiterCli.Version.app_version(),
      "sha" => "unknown",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {release_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    assert Doctor.green?() == true
  end

  test "release build (SHA unavailable) with mismatched version shows [fail] but is non-fatal" do
    # Regression for the false-green bug: both CLI and server report
    # sha: "unknown" in this scenario (neither has git at runtime), so a SHA
    # comparison alone would spuriously report a match. The version numbers
    # must actually be compared.
    release_version_resp = %{
      "version" => "0.0.1",
      "sha" => "unknown",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {release_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] version"
    assert out =~ "server 0.0.1"
    assert out =~ "CLI #{ArbiterCli.Version.app_version()}"
    refute out =~ "CLI and server match"
    assert Doctor.green?() == true
  end

  test "dev/source install with server version newer than CLI hints to rebuild and reinstall CLI" do
    # When the server is newer than the CLI (e.g. server 0.1.68, CLI 0.1.67),
    # hint should tell operator to rebuild and reinstall the arb CLI, not restart the server.
    res = Checks.check_versions("0.1.67", "41474cae", "0.1.68", "41474cae")
    assert res.status == :fail
    assert res.hint =~ "rebuild and reinstall the `arb` CLI"
    refute res.hint =~ "restart the server"

    # Also test with different SHAs where CLI sha is ancestor of server sha
    res_sha = Checks.check_versions("0.1.67", "f21bdd4d", "0.1.68", "41474cae")
    assert res_sha.status == :fail
    assert res_sha.hint =~ "rebuild and reinstall the `arb` CLI"
    refute res_sha.hint =~ "restart the server"

    # And verify via Doctor.run with a newer server version (same major)
    Process.put(:bd2_app_version, "0.1.67")

    server_version_resp = %{
      "version" => "0.1.68",
      "sha" => "unknown",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {server_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
    assert out =~ "[fail] version"
    assert out =~ "rebuild and reinstall the `arb` CLI"
    refute out =~ "restart the server"
  end

  test "dev/source install with server version older than CLI hints to restart the server" do
    # When the server is older than the CLI (e.g. server 0.1.64, CLI 0.1.68),
    # hint should keep the restart-the-server instruction.
    res = Checks.check_versions("0.1.68", "41474cae", "0.1.64", "41474cae")
    assert res.status == :fail
    assert res.hint =~ "The server's compiled version is stale — restart the server"
    refute res.hint =~ "rebuild and reinstall"

    # Also test with server sha older than CLI sha (CLI has newer sha)
    res_sha = Checks.check_versions("0.1.68", "41474cae", "0.1.67", "f21bdd4d")
    assert res_sha.status == :fail
    assert res_sha.hint =~ "The server's compiled version is stale — restart the server"
    refute res_sha.hint =~ "rebuild and reinstall"

    # And verify via Doctor.run
    Process.put(:bd2_app_version, "0.1.68")

    mismatched_version_resp = %{
      "version" => "0.1.64",
      "sha" => "eb0c8690",
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {mismatched_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
    assert out =~ "[fail] version"
    refute out =~ "reinstall the CLI from"
    refute out =~ "rebuild and reinstall"
    assert out =~ "The server's compiled version is stale — restart the server"
  end

  test "workspace resolution failure is an operator-actionable exit 1, but must not block deploy readiness" do
    prev = System.get_env("ARB_WORKSPACE")
    System.delete_env("ARB_WORKSPACE")
    on_exit(fn -> if prev, do: System.put_env("ARB_WORKSPACE", prev) end)

    ambiguous_workspaces = %{
      "data" => [
        %{"id" => "ws-a", "name" => "alpha", "prefix" => "al"},
        %{"id" => "ws-b", "name" => "beta", "prefix" => "be"}
      ]
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {ambiguous_workspaces, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {matching_version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    # `arb doctor` still exits non-zero — this is an operator-actionable
    # misconfiguration, same as any other broken `Workspace.resolve/0` caller.
    assert exit_code == 1
    assert out =~ "[ ok ] phoenix reachable"
    assert out =~ "[ ok ] at least one workspace exists"
    assert out =~ "[fail] active workspace resolves"
    # ...but it must never gate `arb server deploy`'s auto-rollback wait
    # (bd-8ix2tw): an unresolvable workspace selector says nothing about
    # whether the deployed server itself is healthy.
    assert Doctor.green?() == true
  end

  test "server on the same SHA the CLI's own build carries, but a different version, is a real mismatch" do
    # Guards the exact bug: `cli_sha == server_sha` (e.g. both literally
    # "unknown") must never by itself imply the versions match.
    same_sha_diff_version_resp = %{
      "version" => "9.9.9",
      "sha" => ArbiterCli.Version.git_sha_clean(),
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {same_sha_diff_version_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] version"
    refute out =~ "CLI and server match"
  end

  test "surfaces a failed-swap mismatch: server still on the pre-deploy version" do
    # The failed-swap case from the ticket: the CLI has just been upgraded to
    # the version being deployed, but the server's /api/version shows the
    # swap/restart never actually took (still reporting the prior release).
    just_deployed_vsn = ArbiterCli.Version.app_version()

    stale_server_resp = %{
      "version" => "0.0.1",
      "sha" => "unknown",
      "built_at" => "2023-01-01T00:00:00Z",
      "booted_at" => "2023-01-01T00:01:00Z"
    }

    stub_routes([
      {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
      {{"get", "/api/repos"}, {@repos_resp, 200}},
      {{"get", "/api/version"}, {stale_server_resp, 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
    ])

    {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
    assert exit_code == 0
    assert out =~ "[fail] version"
    assert out =~ "server 0.0.1"
    assert out =~ "CLI #{just_deployed_vsn}"
    refute out =~ "CLI and server match"
    # Non-fatal: a version check on its own must not gate `arb server deploy`'s
    # auto-rollback — only Phoenix/workspace reachability does.
    assert Doctor.green?() == true
  end

  # ---- repo config check (bd-3pqzsa) --------------------------------------
  #
  # v0.1.56 dropped the `rig_paths` fallback, so an un-migrated install
  # resolved zero repos while doctor stayed 5/5 green. Zero repos is now an
  # explicit, failing line.

  describe "repos resolved check" do
    test "reports the repo count on a healthy install" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] repos resolved"
      assert out =~ "1 repo(s)"
    end

    test "zero repos with a workspace present is a failing, actionable line" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] repos resolved"
      assert out =~ "no repos registered"
      assert out =~ "repo_paths"
    end

    test "zero repos names the legacy rig_paths key when a workspace still carries it" do
      stub_routes([
        {{"get", "/api/workspaces"}, {legacy_workspaces_resp(), 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] repos resolved"
      assert out =~ "rig_paths"
      assert out =~ "arbiter.migrate_rig_paths"
    end

    # `/api/repos` aggregates across every workspace (plus the app-env
    # fallback), so a count-only check goes green the moment *anything* supplies
    # repos — while the un-migrated workspace still dispatches nothing.
    test "a workspace on rig_paths fails even when other workspaces supply repos" do
      mixed = %{
        "data" => [
          %{"id" => "ws-1", "name" => "migrated", "prefix" => "bd", "config" => %{}},
          %{
            "id" => "ws-2",
            "name" => "acme",
            "prefix" => "ac",
            "config" => %{"rig_paths" => %{"tonic" => "/srv/tonic"}}
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {mixed, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] repos resolved"
      assert out =~ "1 workspace still on the retired `rig_paths` key: acme"
    end

    # A release install has no Mix, so the mix task cannot be the lead
    # instruction — `arb server restart` works everywhere.
    test "the rig_paths hint leads with a remediation that works on a release install" do
      stub_routes([
        {{"get", "/api/workspaces"}, {legacy_workspaces_resp(), 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "arb server restart"
      assert out =~ "Arbiter.Release.migrate_config"

      [hint] = Regex.run(~r/hint: .*/, out)
      restart_at = :binary.match(hint, "arb server restart") |> elem(0)
      mix_at = :binary.match(hint, "mix arbiter.migrate_rig_paths") |> elem(0)
      assert restart_at < mix_at
    end

    # Only a map under `rig_paths` is a migration candidate, so only a map is
    # worth reporting — otherwise doctor pins red on junk no migration clears.
    test "a non-map rig_paths value is not reported as the legacy key" do
      junk = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"rig_paths" => "x"}
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {junk, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] repos resolved"
    end

    test "zero repos is not a deploy-rollback signal" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      # An empty repo map says nothing about whether the *deployed server* is
      # healthy — it must never auto-roll-back a deploy (cf. bd-8ix2tw).
      assert Doctor.green?() == true
    end

    test "no workspaces at all does not double-report as a repo failure" do
      stub_routes([
        {{"get", "/api/workspaces"}, {%{"data" => []}, 200}},
        {{"get", "/api/repos"}, {%{"data" => []}, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] repos resolved"
      assert out =~ "no workspaces"
    end
  end

  # ---- bind address check (bd-1c4pg3) --------------------------------------
  #
  # The dashboard's auth model is "a loopback peer is trusted; there is no
  # login" — a server bound off-loopback exposes unauthenticated pages to
  # anyone who can reach the port. This check warns (never fails the exit
  # code) when that's the case.

  # bd-asawcq: `/api` refuses anonymous callers on loopback too. Doctor proves
  # it with harmless anonymous probes and fails if the server takes them.
  describe "anonymous /api access check" do
    @probe_write "/api/workspaces/arb-doctor-anonymous-probe/config"

    defp anon_green_routes do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ]
    end

    # Answers like the server: 401 for a request with no Authorization header,
    # `accepted` for one that carries a token (the probe must never send one).
    defp probe_route(method, path, accepted) do
      {{method, path},
       fn conn ->
         case Plug.Conn.get_req_header(conn, "authorization") do
           [] ->
             conn
             |> Plug.Conn.put_status(401)
             |> Req.Test.json(%{
               "error" => %{"message" => "Authorization: Bearer <token> required"}
             })

           _ ->
             {body, status} = accepted
             conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
         end
       end}
    end

    test "green when the server refuses the anonymous probes, and they carry no token" do
      # A token is on hand (minted over the operator socket, or ARB_TOKEN in
      # a worker shell); the probes must still go out without one.
      ArbiterCli.FakeOperatorSocket.start!(%{"token" => "operator-tok", "tier" => "coordinator"})

      stub_routes(
        anon_green_routes() ++
          [
            probe_route("patch", @probe_write, {%{"error" => "not found"}, 404}),
            probe_route("get", "/api/issues", {%{"data" => []}, 200})
          ]
      )

      result = Checks.check_anonymous_api()
      assert result.status == :ok
      assert result.name == "anonymous /api access refused"
    end

    test "fails, fatally, when an anonymous loopback write is accepted" do
      stub_routes(
        anon_green_routes() ++
          [
            # A validation error means the request got past auth.
            {{"patch", @probe_write}, {%{"error" => %{"message" => "invalid"}}, 422}},
            probe_route("get", "/api/issues", {%{"data" => []}, 200})
          ]
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)

      assert exit_code == 1
      assert out =~ "[fail] anonymous /api access refused"
      assert out =~ "PATCH #{@probe_write} → 422"
    end

    test "fails when an anonymous read of every workspace's tickets is accepted" do
      stub_routes(
        anon_green_routes() ++
          [
            probe_route("patch", @probe_write, {%{}, 404}),
            {{"get", "/api/issues"}, {%{"data" => []}, 200}}
          ]
      )

      result = Checks.check_anonymous_api()
      assert result.status == :fail
      assert result.fatal
      refute result.blocks_readiness
      assert result.detail =~ "GET /api/issues → 200"
    end

    test "an unreachable server is left to the reachability check" do
      stub_transport_error(:patch, @probe_write, :econnrefused)

      assert Checks.check_anonymous_api().status == :ok
    end
  end

  describe "bind address check" do
    test "loopback bind is green" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/bind_address"}, {%{"ip" => "127.0.0.1", "loopback" => true}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] bind address is loopback"
      assert out =~ "127.0.0.1"
    end

    test "non-loopback bind shows [fail] but is non-fatal and does not block deploy readiness" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/bind_address"}, {%{"ip" => "0.0.0.0", "loopback" => false}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] bind address is loopback"
      assert out =~ "0.0.0.0"
      assert out =~ "no login"
      assert out =~ "ARB_BIND_ADDRESS"
      assert Doctor.green?() == true
    end

    # A server predating this check (or an unreachable one) returns something
    # this check can't interpret — must never spuriously fail doctor over it.
    test "server without the bind_address endpoint (404) does not fail doctor" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/bind_address"}, {%{}, 404}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] bind address is loopback"
    end
  end

  # bd-9fgg04: "is it safe to restart?" is what doctor is reached for.
  describe "restart safety check" do
    defp stub_with_scheduler(scheduler_resp) do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/scheduler/status"}, scheduler_resp}
      ])
    end

    test "paused and draining is [fail], lists the work, but is non-fatal and never blocks readiness" do
      stub_with_scheduler(
        {%{
           "state" => "draining",
           "paused" => true,
           "safe_to_restart" => false,
           "in_flight" => [
             %{"kind" => "conflict_resolver", "task_id" => "vs-3fpek0", "state" => "working"}
           ]
         }, 200}
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)

      assert exit_code == 0
      assert out =~ "[fail] safe to restart"
      assert out =~ "conflict_resolver"
      assert out =~ "vs-3fpek0"
      assert out =~ "arb scheduler wait"
      assert Doctor.green?() == true
    end

    test "paused and quiescent is green and says so" do
      stub_with_scheduler(
        {%{
           "state" => "quiescent",
           "paused" => true,
           "safe_to_restart" => true,
           "in_flight" => []
         }, 200}
      )

      {out, _err, 0} = capture(fn -> Doctor.run([]) end)

      assert out =~ "[ ok ] safe to restart"
      assert out =~ "paused, quiescent"
    end

    test "a running scheduler is green, with how to reach a safe point" do
      stub_with_scheduler(
        {%{
           "state" => "running",
           "paused" => false,
           "safe_to_restart" => false,
           "in_flight" => []
         }, 200}
      )

      {out, _err, 0} = capture(fn -> Doctor.run([]) end)

      assert out =~ "[ ok ] safe to restart"
      assert out =~ "arb scheduler pause && arb scheduler wait"
    end

    test "an unreadable scheduler status never fails doctor" do
      stub_with_scheduler({%{}, 404})

      {out, _err, 0} = capture(fn -> Doctor.run([]) end)

      assert out =~ "[ ok ] safe to restart"
      assert out =~ "could not determine"
    end
  end

  # bd-4420va: a pinned `safe_defaults` list used to silently resolve fewer
  # categories than the workspace default the moment a new one shipped
  # (vstim missed :no_public_upload after v0.1.78 added it). The legacy key
  # is now inert, so this only fires on an explicit `safe_defaults_exclude` —
  # but that should be visible in `arb doctor`, not just discoverable live.
  describe "workspace safe-default categories check" do
    test "green when no workspace excludes a current default category" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] workspace safe-default categories"
    end

    test "names the workspace and the missing categories when one excludes a default" do
      workspaces_with_gap = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "vs",
            "config" => %{},
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => ["no_destructive_fs", "no_force_push"],
              "safe_defaults_exclude" => ["no_public_upload"],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true}
            }
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspaces_with_gap, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      # Non-fatal: named, but does not block readiness or fail the exit code.
      assert exit_code == 0
      assert out =~ "[fail] workspace safe-default categories"
      assert out =~ "default: no_public_upload"
    end
  end

  # bd-4420va: `permissions.safe_defaults` no longer has any effect once
  # `safe_defaults_exclude` exists, so a workspace that opted a category out
  # with the old key (e.g. `safe_defaults: []`) now silently resolves every
  # category again. Flag any workspace whose config still carries the key.
  describe "legacy safe_defaults key check" do
    test "green when no workspace config carries the legacy key" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] legacy safe_defaults key"
    end

    test "names a workspace whose config still sets the inert legacy key" do
      workspaces_with_legacy_key = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "vs",
            "config" => %{
              "agent" => %{
                "security" => %{
                  "permissions" => %{
                    "safe_defaults" => ["no_destructive_fs", "no_force_push"]
                  }
                }
              }
            },
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => [],
              "safe_defaults_exclude" => [],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true}
            }
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspaces_with_legacy_key, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] legacy safe_defaults key"
      assert out =~ "default"
      assert out =~ "safe_defaults_exclude"
    end
  end

  # bd-3s82pf: outside :strict, a host that can't jail agy just runs it
  # unconfined instead of refusing, so `security_posture.write_jail_warning`
  # (Arbiter.Agents.Gemini.write_jail_warning/1) is the only place that
  # degradation is visible.
  describe "agy write jail check" do
    test "green when no workspace has a write_jail_warning" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy write jail"
    end

    # bd-8xy1mf: outside :strict the gap is real but never fatal (agy just
    # runs unconfined), so this is informational — [ ok ], not [fail] — even
    # though the cause and fix are still named in the detail line.
    test "names the workspace and the warning, but stays green, outside :strict" do
      workspaces_with_warning = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "vs",
            "config" => %{},
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => [],
              "safe_defaults_exclude" => [],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true},
              "write_jail_warning" =>
                "agy write jail unavailable (bwrap (bwrap) not found on PATH — Install " <>
                  "bubblewrap: `dnf install bubblewrap` (Fedora/RHEL 8+/AL2023) or " <>
                  "`apt install bubblewrap` (Debian/Ubuntu).) — writes are not confined to " <>
                  "the worktree outside :strict"
            }
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspaces_with_warning, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy write jail"
      assert out =~ "default: agy write jail unavailable"
      assert out =~ "dnf install bubblewrap"
    end

    # bd-8xy1mf: a `:strict` workspace can't fall back to running agy
    # unconfined, so the same gap is fatal here — [fail], non-zero exit.
    test "fails, and exits non-zero, when a :strict workspace can't jail" do
      workspaces_with_warning = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "vs",
            "config" => %{},
            "security_posture" => %{
              "mode" => "strict",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => [],
              "safe_defaults_exclude" => [],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true},
              "write_jail_warning" =>
                "agy write jail unavailable (unprivileged user namespaces are disabled) — " <>
                  "writes are not confined to the worktree outside :strict"
            }
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspaces_with_warning, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] agy write jail"
      assert out =~ "default: agy write jail unavailable"
      assert out =~ "hint:"
    end

    # bd-99emmd: Codex reports its own `write_jail_warning` (bypass default and
    # strict). Neither is about the bwrap jail, and a `:strict` Codex workspace
    # is not fatal (the pool substitutes a strict-capable provider), so the agy
    # check must ignore both.
    for {mode, warning} <- [
          {"bypass", "codex runs with --dangerously-bypass-approvals-and-sandbox: ..."},
          {"strict",
           ":strict dispatches of codex are skipped or refused (no worktree write confinement)"}
        ] do
      test "ignores a codex #{mode} write_jail_warning" do
        workspaces = %{
          "data" => [
            %{
              "id" => "ws-1",
              "name" => "codexws",
              "prefix" => "vs",
              "config" => %{},
              "security_posture" => %{
                "provider" => "codex",
                "mode" => unquote(mode),
                "allow" => [],
                "deny" => [],
                "safe_defaults" => [],
                "safe_defaults_exclude" => [],
                "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true},
                "write_jail_warning" => unquote(warning),
                "repos" => %{
                  "r" => %{"mode" => unquote(mode), "write_jail_warning" => unquote(warning)}
                }
              }
            }
          ]
        }

        stub_routes([
          {{"get", "/api/workspaces"}, {workspaces, 200}},
          {{"get", "/api/repos"}, {@repos_resp, 200}},
          {{"get", "/api/version"}, {matching_version_resp(), 200}},
          {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
        ])

        {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
        assert exit_code == 0
        assert out =~ "[ ok ] agy write jail"
        refute out =~ "codex runs with"
        refute out =~ "skipped or refused"
        refute out =~ "[fail] agy write jail"
      end
    end

    # bd-8xy1mf AC1: the host's own can-jail-agy answer must show even when no
    # workspace/repo currently needs it — that's the whole point of exposing
    # `Jail.diagnose/0` via `/api/server/agy_write_jail` rather than only
    # reading it back out of a workspace posture.
    test "reports the host can jail agy when no workspace has a warning" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"}, {%{"available" => true}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy write jail"
      assert out =~ "host can jail agy — agy is :strict-eligible"
    end

    test "reports the host cannot jail agy, informationally, when no workspace needs it" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"},
         {%{
            "available" => false,
            "cause" => "user_namespaces_disabled",
            "message" =>
              "unprivileged user namespaces are disabled (`user.max_user_namespaces = 0`)",
            "fix" => "Enable them: `sysctl -w user.max_user_namespaces=<N>`."
          }, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy write jail"
      assert out =~ "cannot jail agy: unprivileged user namespaces are disabled"
      assert out =~ "informational only"
    end

    # bd-8xy1mf finding: a repo-level `agent.security.repos.<repo>` override
    # can resolve `:strict` while the workspace default doesn't — the
    # workspace-level `write_jail_warning` alone never sees that, so this
    # would previously print `[ ok ]` even though every agy dispatch against
    # that repo is refused.
    test "fails when a repo override resolves :strict and the host can't jail" do
      workspace_with_repo_override = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "vs",
            "config" => %{},
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => [],
              "safe_defaults_exclude" => [],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true},
              "write_jail_warning" => nil,
              "repos" => %{
                "tonic" => %{
                  "mode" => "strict",
                  "write_jail_warning" =>
                    "agy write jail unavailable (unprivileged user namespaces are disabled) — " <>
                      ":strict dispatches of agy are refused"
                }
              }
            }
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspace_with_repo_override, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] agy write jail"
      assert out =~ "default (repo tonic): agy write jail unavailable"
      assert out =~ "hint:"
    end
  end

  # bd-5d5mrs: `ssh -G` inside the jail is a separate probe from the write
  # jail's — a host can jail writes fine while this regresses (a changed
  # `/etc/ssh/ssh_config`, no `ssh` on `PATH`), and that would otherwise
  # only surface as a jailed worker's `git push` quietly failing.
  describe "agy ssh transport" do
    test "ok when the host's ssh probe passes" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"},
         {%{"available" => true, "ssh" => %{"available" => true}}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy ssh transport"
    end

    test "fails, with the cause and a hint, when the host's ssh probe fails" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"},
         {%{
            "available" => true,
            "ssh" => %{
              "available" => false,
              "cause" => "other",
              "message" => "ssh still rejected the mirrored config inside the jail: boom",
              "fix" => "Check the ownership of Jail.ssh_shadow_config/0's output."
            }
          }, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      # Not fatal and doesn't block readiness on its own.
      assert exit_code == 0
      assert out =~ "[fail] agy ssh transport"
      assert out =~ "ssh still rejected the mirrored config"
      assert out =~ "hint:"
      assert out =~ "Check the ownership of Jail.ssh_shadow_config/0's output."
    end

    test "ok (skipped) when the server predates the ssh key" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"}, {%{"available" => true}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy ssh transport"
    end
  end

  describe "agy jail escape vectors (bd-7o08mj)" do
    defp escape_routes(jail_body) do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"}, {jail_body, 200}}
      ])
    end

    test "ok when no escape vector is reachable" do
      escape_routes(%{"available" => true, "escape" => %{"available" => true}})
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy jail escape vectors"
      assert out =~ "xdg-dbus-proxy not installed"
    end

    test "FAILs with the vectors named when one is reachable" do
      escape_routes(%{
        "available" => true,
        "escape" => %{
          "available" => false,
          "message" => "jail escape vector(s) reachable: systemd-run --user",
          "fix" => "mask /run/user/<uid>"
        }
      })

      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[fail] agy jail escape vectors"
      assert out =~ "systemd-run --user"
      assert out =~ "mask /run/user/<uid>"
    end

    test "ok (skipped) when the server predates the escape key" do
      escape_routes(%{"available" => true})
      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] agy jail escape vectors"
    end
  end

  describe "agy jail hidden reads (bd-3q2djr)" do
    defp reads_routes(jail_body) do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"}, {jail_body, 200}}
      ])
    end

    test "ok when the jail cannot read the install DB or other workspaces" do
      reads_routes(%{"available" => true, "reads" => %{"available" => true}})
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy jail hidden reads"
    end

    test "FAILs with the paths named, without blocking readiness" do
      reads_routes(%{
        "available" => true,
        "reads" => %{
          "available" => false,
          "message" => "sensitive path(s) readable inside the jail: /h/.arbiter/arbiter.sqlite3",
          "fix" => "hide these"
        }
      })

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] agy jail hidden reads"
      assert out =~ "/h/.arbiter/arbiter.sqlite3"
      assert out =~ "hide these"
    end

    test "ok (skipped) when the server predates the reads key" do
      reads_routes(%{"available" => true})
      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] agy jail hidden reads"
    end
  end

  describe "agy jail network mode (bd-cfktou)" do
    defp network_routes(jail_body) do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"}, {jail_body, 200}}
      ])
    end

    test "ok when the host can run the jail in a network namespace" do
      network_routes(%{"available" => true, "network" => %{"available" => true}})
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy jail network"
    end

    test "FAILs with the cause and fix when it cannot, without blocking readiness" do
      network_routes(%{
        "available" => true,
        "network" => %{
          "available" => false,
          "cause" => "socat_missing",
          "message" => "no `socat` on PATH",
          "fix" => "Install socat"
        }
      })

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] agy jail network"
      assert out =~ "no `socat` on PATH"
      assert out =~ "Install socat"
    end

    test "ok (skipped) when the server predates the network key" do
      network_routes(%{"available" => true})
      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] agy jail network"
    end
  end

  describe "agy jail keyring proxy (bd-c9fqsk)" do
    test "ok when the proxy comes up under a per-run TMPDIR" do
      network_routes(%{"available" => true, "keyring" => %{"available" => true}})
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] agy jail keyring proxy"
    end

    test "FAILs with the cause, without blocking readiness" do
      network_routes(%{
        "available" => true,
        "keyring" => %{"available" => false, "message" => "proxy down", "fix" => "shorten it"}
      })

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] agy jail keyring proxy"
      assert out =~ "proxy down"
    end
  end

  describe "egress jail self-test (bd-5yydxh)" do
    defp egress_routes(egress_resp, status \\ 200) do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/agy_write_jail"}, {%{"available" => true}, 200}},
        {{"get", "/api/server/egress_jail"}, {egress_resp, status}}
      ])
    end

    test "ok, naming 1 allow and 1 deny, when the proxy and jail work" do
      egress_routes(%{"available" => true, "allowed" => 1, "denied" => 1})
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] egress jail"
      assert out =~ "1 allow"
      assert out =~ "1 deny"
    end

    test "FAILs naming the missing package, without blocking readiness" do
      egress_routes(%{
        "available" => false,
        "cause" => "socat_missing",
        "message" => "no `socat` on PATH: the jail's network mode bridges its loopback with it",
        "fix" => "Install socat (`dnf install socat` / `apt install socat`)."
      })

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] egress jail"
      assert out =~ "no `socat` on PATH"
      assert out =~ "dnf install socat"
    end

    test "ok (skipped) when the server predates the endpoint" do
      egress_routes(%{"error" => "not found"}, 404)
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] egress jail"
      assert out =~ "skipping"
    end
  end

  describe "guardrail profiles (bd-anwb0u, G11)" do
    defp guardrail_routes(resp, status \\ 200) do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/guardrails"}, {resp, status}}
      ])
    end

    test "ok and says guardrails are off when nothing is configured" do
      guardrail_routes(%{"active" => false, "rules" => 0, "workspaces" => [], "issues" => []})
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] guardrail profiles"
      assert out =~ "guardrails are off"
    end

    test "ok, reporting each workspace's effective tiers" do
      guardrail_routes(%{
        "active" => true,
        "rules" => 2,
        "issues" => [],
        "workspaces" => [
          %{
            "workspace" => "default",
            "subjects" => [
              %{"provider" => "claude", "model" => "opus", "tier" => "privileged"},
              %{"provider" => "antigravity", "model" => nil, "tier" => "quarantine"}
            ]
          }
        ]
      })

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] guardrail profiles"
      assert out =~ "default: claude/opus=privileged, antigravity=quarantine"
    end

    test "FAILs naming inconsistent config, without blocking readiness" do
      guardrail_routes(%{
        "active" => true,
        "rules" => 1,
        "workspaces" => [%{"workspace" => "default", "subjects" => []}],
        "issues" => [
          %{
            "kind" => "unmatched_subject",
            "workspace" => "default",
            "message" => "codex matches no subject rule, so it runs as quarantine"
          }
        ]
      })

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] guardrail profiles"
      assert out =~ "codex matches no subject rule"
    end

    test "ok (skipped) when the server predates the endpoint" do
      guardrail_routes(%{"error" => "not found"}, 404)
      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] guardrail profiles"
      assert out =~ "skipping"
    end
  end

  describe "account/workspace quota policy check (bd-c7ll4t)" do
    test "green when no workspace configures its own quota settings" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] account/workspace quota policy"
    end

    # bd-5ps98m: a workspace explicitly configured `paced`/no ceiling, but the
    # account's own flat, stricter setting was the one actually binding —
    # invisible until this check.
    test "names the workspace when the account overrides its own quota config" do
      workspace_with_quota_config = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"quota" => %{"threshold_mode" => "paced"}}
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspace_with_quota_config, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/quota"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "data" => %{
               "policy_binding" => %{
                 "throttle_threshold" => "account",
                 "weekly_threshold" => "account"
               }
             }
           })
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      # Non-fatal: named, but does not block readiness or fail the exit code.
      assert exit_code == 0
      assert out =~ "[fail] account/workspace quota policy"
      assert out =~ "default: account overrides its own throttle_threshold"
      assert out =~ "default: account overrides its own weekly_threshold"
    end

    test "quiet when the workspace's own config is the side that binds" do
      workspace_with_quota_config = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"quota" => %{"throttle_threshold" => 0.5}}
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspace_with_quota_config, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/quota"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "data" => %{
               "policy_binding" => %{
                 "throttle_threshold" => "workspace",
                 "weekly_threshold" => "default"
               }
             }
           })
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] account/workspace quota policy"
    end

    # bd-c7ll4t (review finding 3): a workspace that only set
    # `throttle_threshold` never expressed an opinion about the weekly
    # window, so the account binding that window must not be reported as an
    # override — there is nothing of the workspace's own being overridden.
    test "does not flag a window the workspace never configured" do
      workspace_with_quota_config = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"quota" => %{"throttle_threshold" => 0.7}}
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspace_with_quota_config, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/quota"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "data" => %{
               "policy_binding" => %{
                 "throttle_threshold" => "account",
                 "weekly_threshold" => "account"
               }
             }
           })
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] account/workspace quota policy"
      assert out =~ "default: account overrides its own throttle_threshold"
      refute out =~ "weekly_threshold"
    end

    # bd-c7ll4t (review finding 3): a `quota` map that only sets an unrelated
    # key (no flat key of its own, no `threshold_mode: "paced"`) expressed no
    # opinion about either window, so the account binding both is not an
    # override of anything.
    test "stays ok when the workspace's quota config sets only an unrelated key" do
      workspace_with_quota_config = %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"quota" => %{"weekly_warning_policy" => "hold"}}
          }
        ]
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {workspace_with_quota_config, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/quota"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "data" => %{
               "policy_binding" => %{
                 "throttle_threshold" => "account",
                 "weekly_threshold" => "account"
               }
             }
           })
         end}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] account/workspace quota policy"
    end
  end

  # bd-80ecol: a Claude workspace with no setup token of its own used to be
  # handed a copy of the operator's `.credentials.json` (mode B), whose
  # refresh-token rotation locked the operator out. Dispatch for it is now
  # held; doctor lists every such workspace with the command that fixes it.
  describe "claude worker credentials check" do
    defp base_routes do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ]
    end

    test "ok when every Claude workspace has a credential of its own" do
      stub_routes(
        base_routes() ++
          [{{"get", "/api/server/claude_credentials"}, {%{"checked" => 2, "missing" => []}, 200}}]
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] claude worker credentials"
      assert out =~ "2 Claude workspace(s)"
    end

    test "fails, exits non-zero, and names each workspace/provider and its fix" do
      missing = %{
        "workspace_id" => "ws-9",
        "workspace" => "no-token-ws",
        "provider" => "claude",
        "account" => "bare",
        "reason" => "no_credential",
        "summary" =>
          "no Claude setup token resolves for workspace no-token-ws: account claude:bare " <>
            "has no active CLAUDE_CODE_OAUTH_TOKEN",
        "fix" =>
          "`arb account rotate claude:bare --kind oauth_token --env-var " <>
            "CLAUDE_CODE_OAUTH_TOKEN --secret <token from `claude setup-token`>`"
      }

      stub_routes(
        base_routes() ++
          [
            {{"get", "/api/server/claude_credentials"},
             {%{"checked" => 3, "missing" => [missing]}, 200}}
          ]
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] claude worker credentials"
      assert out =~ "no-token-ws (claude)"
      assert out =~ "arb account rotate claude:bare"
    end

    test "never blocks readiness — a held workspace is not a broken server" do
      stub_routes(
        base_routes() ++
          [
            {{"get", "/api/server/claude_credentials"},
             {%{
                "checked" => 1,
                "missing" => [
                  %{"workspace" => "w", "provider" => "claude", "summary" => "s", "fix" => "f"}
                ]
              }, 200}}
          ]
      )

      result = Enum.find(Checks.run(), &(&1.name == "claude worker credentials"))
      assert result.status == :fail
      refute result.blocks_readiness
    end

    test "grok auth: silent-ok when disabled, reports state when enabled" do
      stub_routes(
        base_routes() ++
          [{{"get", "/api/server/grok_auth"}, {%{"enabled" => false, "workspaces" => []}, 200}}]
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] grok auth"
      assert out =~ "not enabled"

      stub_routes(
        base_routes() ++
          [
            {{"get", "/api/server/grok_auth"},
             {%{"enabled" => true, "workspaces" => ["w1"], "state" => "logged_in"}, 200}}
          ]
      )

      {out, _err, 0} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] grok auth"
      assert out =~ "logged in (w1)"
    end

    test "grok auth: a missing login fails with the fix and never blocks readiness" do
      stub_routes(
        base_routes() ++
          [
            {{"get", "/api/server/grok_auth"},
             {%{
                "enabled" => true,
                "workspaces" => ["w1"],
                "state" => "not_logged_in",
                "fix" => "Run `grok login --device-code` on the Arbiter host."
              }, 200}}
          ]
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] grok auth"
      assert out =~ "grok login --device-code"
      result = Enum.find(Checks.run(), &(&1.name == "grok auth"))
      refute result.blocks_readiness
    end

    test "a server that predates the check is reported as unknown, not as a failure" do
      stub_routes(base_routes())

      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] claude worker credentials"
      assert out =~ "could not check"
    end
  end

  describe "worker temp dir check" do
    defp worker_tmp_routes(body) do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/worker_tmp"}, {body, 200}}
      ]
    end

    test "warns when the temp root is on tmpfs" do
      stub_routes(worker_tmp_routes(%{"root" => "/tmp/w", "fstype" => "tmpfs", "tmpfs" => true}))

      result = Enum.find(Checks.run(), &(&1.name == "worker temp dir"))
      assert result.status == :warn
      assert result.detail =~ "RAM-backed"
      refute result.blocks_readiness
    end

    test "warns when the temp root is over its size threshold" do
      stub_routes(
        worker_tmp_routes(%{
          "root" => "/d/w",
          "tmpfs" => false,
          "over_threshold" => true,
          "size_bytes" => 9,
          "threshold_bytes" => 5
        })
      )

      result = Enum.find(Checks.run(), &(&1.name == "worker temp dir"))
      assert result.status == :warn
    end

    test "is ok for a small disk-backed root" do
      stub_routes(
        worker_tmp_routes(%{"root" => "/d/w", "tmpfs" => false, "over_threshold" => false})
      )

      result = Enum.find(Checks.run(), &(&1.name == "worker temp dir"))
      assert result.status == :ok
    end
  end

  # bd-6zuoo6: one worker's runaway process must not be able to stop the server.
  describe "worker memory check" do
    defp worker_memory_routes(body) do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/worker_memory"}, {body, 200}}
      ]
    end

    defp memory_body(overrides) do
      Map.merge(
        %{
          "enabled" => true,
          "capped" => true,
          "available" => true,
          "cap" => "40%",
          "unavailable_reason" => nil,
          "service_unit" => "arbiter.service",
          "service_manager" => "user",
          "oom_policy" => "continue",
          "memory_max" => "infinity"
        },
        overrides
      )
    end

    defp memory_result(body) do
      stub_routes(worker_memory_routes(body))
      Enum.find(Checks.run(), &(&1.name == "worker memory cap"))
    end

    test "warns loudly for OOMPolicy=stop with no per-worker cap" do
      result =
        memory_result(
          memory_body(%{"oom_policy" => "stop", "capped" => false, "enabled" => false})
        )

      assert result.status == :warn
      assert result.detail =~ "OOMPolicy=stop"
      assert result.detail =~ "no per-worker memory cap"
      assert result.hint =~ "OOMPolicy=continue"
      refute result.blocks_readiness
    end

    test "an unreadable OOMPolicy is reported as unknown, not as OOMPolicy=stop" do
      result = memory_result(memory_body(%{"oom_policy" => nil}))

      assert result.status == :warn
      assert result.detail =~ "could not read OOMPolicy for arbiter.service"
      refute result.detail =~ "OOMPolicy=stop"
      refute result.blocks_readiness
    end

    test "says why an enabled cap is not in force" do
      result =
        memory_result(
          memory_body(%{
            "oom_policy" => "stop",
            "capped" => false,
            "available" => false,
            "unavailable_reason" => "cgroup v2 (unified hierarchy) is not mounted"
          })
        )

      assert result.status == :warn
      assert result.detail =~ "cgroup v2"
    end

    test "still warns for OOMPolicy=stop when workers are capped" do
      result = memory_result(memory_body(%{"oom_policy" => "stop"}))

      assert result.status == :warn
      assert result.detail =~ "capped at 40%"
      assert result.hint =~ "OOMPolicy=continue"
    end

    test "is ok with OOMPolicy=continue and a cap in force" do
      result = memory_result(memory_body(%{}))

      assert result.status == :ok
      assert result.detail =~ "40%"
    end

    test "warns about a missing cap even with OOMPolicy=continue" do
      result = memory_result(memory_body(%{"capped" => false, "enabled" => false}))

      assert result.status == :warn
      assert result.detail =~ "no per-worker memory cap"
    end

    test "a server that is not a systemd service has no OOM policy to judge" do
      result =
        memory_result(
          memory_body(%{"service_unit" => nil, "service_manager" => nil, "oom_policy" => nil})
        )

      assert result.status == :ok
      assert result.detail =~ "not running as a systemd service"
    end

    test "an unreachable or older server is skipped, not failed" do
      stub_routes(
        List.keydelete(worker_memory_routes(%{}), {"get", "/api/server/worker_memory"}, 0)
      )

      result = Enum.find(Checks.run(), &(&1.name == "worker memory cap"))
      assert result.status == :ok
      assert result.detail =~ "skipping"
    end
  end

  # bd-c99hys: the dashboard login relay drives each provider CLI's login inside
  # a hidden tmux session, so a host without tmux cannot log an account in.
  describe "tmux check" do
    defp tmux_routes(body) do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/tmux"}, {body, 200}}
      ]
    end

    test "reports tmux present, with its version" do
      stub_routes(
        tmux_routes(%{"available" => true, "path" => "/usr/bin/tmux", "version" => "tmux 3.4"})
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] tmux"
      assert out =~ "tmux 3.4"
    end

    test "reports tmux missing, informationally, with the fix" do
      stub_routes(
        tmux_routes(%{
          "available" => false,
          "message" => "tmux is not installed",
          "fix" => "Install tmux (e.g. `sudo dnf install tmux`)"
        })
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[fail] tmux"
      assert out =~ "tmux is not installed"
      assert out =~ "sudo dnf install tmux"

      result = Enum.find(Checks.run(), &(&1.name == "tmux"))
      refute result.blocks_readiness
    end

    test "skips quietly when the server predates the endpoint" do
      stub_routes(tmux_routes(%{}) |> List.keydelete({"get", "/api/server/tmux"}, 0))

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] tmux"
      assert out =~ "predates this check"
    end
  end

  # bd-73zv62: a repo whose effective merge strategy is a forge but whose
  # checkout has no origin remote (or the wrong one) can never open its PR.
  describe "merge routing check" do
    defp routing_routes(body) do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/merge_routing"}, {body, 200}}
      ]
    end

    @arbiter_ok %{
      "workspace" => "default",
      "repo" => "arbiter",
      "strategy" => "github",
      "remote" => "serious-alchemy/arbiter",
      "problem" => nil
    }

    test "ok, naming each repo's effective strategy" do
      mesaana = %{
        "workspace" => "default",
        "repo" => "mesaana",
        "strategy" => "direct",
        "problem" => nil
      }

      stub_routes(routing_routes(%{"repos" => [@arbiter_ok, mesaana], "problems" => []}))

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] merge routing"
      assert out =~ "default/arbiter: github"
      assert out =~ "default/mesaana: direct"
    end

    test "fails on a remote-less repo under a forge strategy, with the fix" do
      flagged = %{
        "workspace" => "default",
        "repo" => "mesaana",
        "strategy" => "github",
        "remote" => nil,
        "problem" => "no_remote",
        "fix" => "`arb config set merge.repos.mesaana.strategy direct --workspace default`"
      }

      stub_routes(routing_routes(%{"repos" => [@arbiter_ok, flagged], "problems" => [flagged]}))

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] merge routing"
      assert out =~ "default/mesaana"
      assert out =~ "no origin remote"
      assert out =~ "arb config set merge.repos.mesaana.strategy direct"

      result = Enum.find(Checks.run(), &(&1.name == "merge routing"))
      refute result.blocks_readiness
    end

    test "fails on a remote that is not the effective owner/repo" do
      flagged = %{
        "workspace" => "default",
        "repo" => "infra",
        "strategy" => "github",
        "remote" => "serious-alchemy/infra",
        "expected" => "serious-alchemy/arbiter",
        "problem" => "remote_mismatch",
        "fix" => "set merge.repos.infra.config.owner/repo"
      }

      stub_routes(routing_routes(%{"repos" => [flagged], "problems" => [flagged]}))

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "serious-alchemy/arbiter"
      assert out =~ "serious-alchemy/infra"
    end

    test "an old server without the endpoint is not a failure" do
      stub_routes(Enum.drop(routing_routes(%{}), -1))

      result = Enum.find(Checks.run(), &(&1.name == "merge routing"))
      assert result.status == :ok
      assert result.detail =~ "could not check"
    end
  end

  # bd-cvvb02 / P13 (bd-9gqj8e): provider accounts are always on. An
  # un-migrated install still carrying legacy credentials cannot spawn in
  # those workspaces (MissingCredentialError) and its server-env token is
  # read by nothing; doctor is where the operator is told, and pointed at the
  # runbook.
  describe "provider accounts check" do
    defp accounts_routes(status) do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/provider_accounts"},
         {Map.merge(
            %{
              "decision" => "no_legacy_credentials",
              "stranded_workspaces" => [],
              "server_env_token" => false,
              "runbook" => "docs/provider-accounts-release-runbook.md"
            },
            status
          ), 200}}
      ]
    end

    test "ok on a fresh or migrated install" do
      stub_routes(accounts_routes(%{"decision" => "migrated"}))

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] provider accounts"
      assert out =~ "on (migrated)"
    end

    test "ok on a migrated install with a leftover server-env token, telling the operator to remove it" do
      stub_routes(accounts_routes(%{"decision" => "migrated", "server_env_token" => true}))

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] provider accounts"
      assert out =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert out =~ "ignored"
    end

    test "fails, pointing at the runbook, on un-migrated legacy credentials" do
      stub_routes(
        accounts_routes(%{
          "decision" => "unmigrated_legacy_credentials",
          "stranded_workspaces" => ["default", "emricare"],
          "server_env_token" => true
        })
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] provider accounts"
      assert out =~ "default, emricare"
      assert out =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert out =~ "docs/provider-accounts-release-runbook.md"
      # There is no legacy chain to keep any more, so no switch is offered.
      refute out =~ "ARBITER_PROVIDER_ACCOUNTS"
      refute out =~ "held OFF"

      result = Enum.find(Checks.run(), &(&1.name == "provider accounts"))
      refute result.blocks_readiness
    end

    test "fails when a workspace would raise MissingCredentialError" do
      stub_routes(
        accounts_routes(%{
          "decision" => "migrated",
          "stranded_workspaces" => ["straggler"]
        })
      )

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] provider accounts"
      assert out =~ "straggler"
      assert out =~ "MissingCredentialError"
    end

    test "a server that predates the check is reported as unknown, not as a failure" do
      stub_routes(accounts_routes(%{}) |> List.delete_at(-1))

      {out, _err, _exit_code} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[ ok ] provider accounts"
      assert out =~ "could not check"
    end
  end

  describe "erlang distribution check (bd-51m9ba)" do
    @describetag :tmp_dir

    defp green_routes do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}}
      ]
    end

    test "an exposed epmd and a world-readable cookie fail doctor with exit 1", %{tmp_dir: dir} do
      tcp = Path.join(dir, "tcp")

      File.write!(tcp, [
        "  sl  local_address rem_address   st\n",
        "  27: 00000000:1111 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 7 1 0 100 0 0 10 0\n"
      ])

      cookie = Path.join(dir, "COOKIE")
      File.write!(cookie, "secret")
      File.chmod!(cookie, 0o644)

      Process.put(:bd2_distribution_probe,
        proc_net: [tcp],
        epmd_port: nil,
        epmd_listen_port: 4369,
        cookie_paths: [cookie]
      )

      stub_routes(green_routes())

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] erlang distribution is loopback-only"
      assert out =~ "epmd listens on 0.0.0.0:4369"
      assert out =~ "#{cookie} is 0644"
    end

    test "is part of every doctor run and green when nothing is exposed" do
      stub_routes(green_routes())

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[ ok ] erlang distribution is loopback-only"
    end
  end

  # bd-46xndf: the rootless-podman readiness check. Probes run server-side and
  # are stubbed in the arbiter app's PodmanReadinessTest; this covers rendering.
  describe "podman sandbox readiness check" do
    defp podman_routes(body) do
      [
        {{"get", "/api/workspaces"}, {@workspaces_resp, 200}},
        {{"get", "/api/repos"}, {@repos_resp, 200}},
        {{"get", "/api/version"}, {matching_version_resp(), 200}},
        {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
        {{"get", "/api/server/podman_sandbox"}, {body, 200}}
      ]
    end

    defp find_podman, do: Enum.find(Checks.run(), &(&1.name == "podman sandbox readiness"))

    test "ok, surfacing warnings in the detail" do
      stub_routes(
        podman_routes(%{
          "ready" => true,
          "installed" => true,
          "checks" => [
            %{"id" => "podman", "name" => "podman", "status" => "ok", "detail" => "podman 4.9"},
            %{
              "id" => "cgroups",
              "name" => "cgroups",
              "status" => "warn",
              "detail" => "cgroups v1"
            }
          ]
        })
      )

      result = find_podman()
      assert result.status == :ok
      assert result.detail =~ "cgroups: cgroups v1"
      refute result.blocks_readiness
    end

    test "fails with each failed check's hint, without blocking readiness" do
      stub_routes(
        podman_routes(%{
          "ready" => false,
          "installed" => true,
          "checks" => [
            %{
              "id" => "subid",
              "name" => "subuid/subgid",
              "status" => "fail",
              "detail" => "ryan lacks a range",
              "hint" => "Run usermod."
            },
            %{
              "id" => "socket_bridge",
              "name" => "socket bridge",
              "status" => "fail",
              "detail" => "denied",
              "hint" => "Use label=disable."
            }
          ]
        })
      )

      result = find_podman()
      assert result.status == :fail
      assert result.detail =~ "subuid/subgid: ryan lacks a range"
      assert result.hint =~ "Run usermod."
      assert result.hint =~ "Use label=disable."
      refute result.fatal
      refute result.blocks_readiness
    end

    test "podman not installed is not a failure" do
      stub_routes(
        podman_routes(%{
          "ready" => false,
          "installed" => false,
          "checks" => [%{"id" => "podman", "status" => "fail", "detail" => "missing"}]
        })
      )

      result = find_podman()
      assert result.status == :ok
      assert result.detail =~ "not installed"
      assert result.hint =~ "Install podman"
    end

    test "a timed-out probe request is a failure, not a skip" do
      routes =
        podman_routes(%{})
        |> Enum.reject(&match?({{_, "/api/server/podman_sandbox"}, _}, &1))

      stub_routes([
        {{"get", "/api/server/podman_sandbox"},
         fn conn -> Req.Test.transport_error(conn, :timeout) end}
        | routes
      ])

      result = find_podman()
      assert result.status == :fail
      assert result.detail =~ "did not complete"
      assert result.hint =~ "podman run"
      refute result.blocks_readiness
    end

    test "a server that predates the check is skipped" do
      stub_routes(
        podman_routes(%{})
        |> Enum.reject(&match?({{_, "/api/server/podman_sandbox"}, _}, &1))
      )

      assert find_podman().status == :ok
    end
  end
end
