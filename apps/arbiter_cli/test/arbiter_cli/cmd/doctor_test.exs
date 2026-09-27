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
    assert length(checks) == 11
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
             %{"kind" => "conflict_resolver", "task_id" => "vs-3fpek0", "status" => "running"}
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
end
