defmodule ArbiterCli.Cmd.DoctorSeverityTest do
  @moduledoc """
  bd-7pnat1 (#452): the severity model (ok / warn / fail / n/a), the short
  default output, the grouped `--all` output, applicability, and "never ok on
  unknown".
  """

  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Doctor
  alias ArbiterCli.Cmd.Doctor.Checks

  @workspace %{
    "id" => "ws-1",
    "name" => "default",
    "prefix" => "bd",
    "security_posture" => %{"provider" => "claude", "mode" => "auto"}
  }

  defp version_resp do
    %{
      "version" => ArbiterCli.Version.app_version(),
      "sha" => ArbiterCli.Version.git_sha_clean()
    }
  end

  @ok_jail %{
    "available" => true,
    "ssh" => %{"available" => true},
    "escape" => %{"available" => true},
    "reads" => %{"available" => true},
    "network" => %{"available" => true},
    "keyring" => %{"available" => true}
  }

  @scope_none %{
    "providers" => %{
      "claude" => %{"in_use" => true, "paused" => false},
      "codex" => %{"in_use" => false, "paused" => false},
      "gemini" => %{"in_use" => false, "paused" => false},
      "grok" => %{"in_use" => false, "paused" => false}
    },
    "podman_in_use" => false,
    "egress_enforced" => false
  }

  # Every endpoint the doctor reads, answering "healthy". `overrides` replaces
  # entries by `{method, path}`.
  defp healthy_routes(overrides) do
    base = [
      {{"get", "/api/workspaces"}, {%{"data" => [@workspace]}, 200}},
      {{"get", "/api/repos"}, {%{"data" => [%{"name" => "tonic", "path" => "/srv/tonic"}]}, 200}},
      {{"get", "/api/version"}, {version_resp(), 200}},
      {{"get", "/api/server/migrations"}, {%{"status" => "ok", "pending_count" => 0}, 200}},
      {{"get", "/api/server/bind_address"}, {%{"loopback" => true, "ip" => "127.0.0.1"}, 200}},
      {{"get", "/api/server/dashboard_auth"},
       {%{"impl" => "password", "mode" => "login", "trust_loopback" => false}, 200}},
      {{"get", "/"}, {%{}, 302}},
      {{"patch", "/api/workspaces/arb-doctor-anonymous-probe/config"}, {%{}, 401}},
      {{"get", "/api/issues"}, {%{}, 401}},
      {{"get", "/api/scheduler/status"},
       {%{"state" => "quiescent", "paused" => true, "safe_to_restart" => true, "in_flight" => []},
        200}},
      {{"get", "/api/server/agy_write_jail"}, {@ok_jail, 200}},
      {{"get", "/api/server/egress_jail"}, {%{"available" => true}, 200}},
      {{"get", "/api/server/guardrails"}, {%{"active" => false, "issues" => []}, 200}},
      {{"get", "/api/server/tmux"}, {%{"available" => true, "version" => "3.4"}, 200}},
      {{"get", "/api/server/podman_sandbox"}, {%{"installed" => false}, 200}},
      {{"get", "/api/server/worker_tmp"}, {%{"root" => "/var/tmp/arb"}, 200}},
      {{"get", "/api/server/worker_memory"},
       {%{
          "service_unit" => "arbiter.service",
          "oom_policy" => "continue",
          "capped" => true,
          "cap" => "12G"
        }, 200}},
      {{"get", "/api/server/claude_credentials"}, {%{"checked" => 1, "missing" => []}, 200}},
      {{"get", "/api/server/grok_auth"}, {%{"enabled" => false, "workspaces" => []}, 200}},
      {{"get", "/api/server/provider_accounts"},
       {%{"decision" => "on", "stranded_workspaces" => [], "server_env_token" => false}, 200}},
      {{"get", "/api/server/merge_routing"}, {%{"repos" => [], "problems" => []}, 200}},
      {{"get", "/api/nodes"}, {%{"nodes" => [], "public_url" => nil, "warnings" => []}, 200}},
      {{"get", "/api/providers/paused"}, {%{"paused" => []}, 200}},
      {{"get", "/api/server/doctor_scope"}, {@scope_none, 200}}
    ]

    keys = Enum.map(overrides, &elem(&1, 0))
    Enum.reject(base, fn {k, _} -> k in keys end) ++ overrides
  end

  defp stub_healthy(overrides \\ []), do: stub_routes(healthy_routes(overrides))

  # A scope in which every provider and sandbox backend is in use, so no check
  # is n/a.
  defp scope_all do
    @scope_none
    |> put_in(["providers", "gemini", "in_use"], true)
    |> Map.put("podman_in_use", true)
    |> Map.put("egress_enforced", true)
  end

  defp by_id(results, id), do: Enum.find(results, &(&1.id == id))

  describe "default output" do
    test "a healthy install prints a header, one summary line and nothing else" do
      stub_healthy()

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)

      assert exit_code == 0
      assert out =~ "arb doctor"
      assert out =~ ~r/\d+ ok · 0 warn · 0 fail/
      refute out =~ "[ ok ]"
      refute out =~ "phoenix reachable"
      # header + blank + summary, no per-check lines
      assert out |> String.split("\n", trim: true) |> length() <= 3
    end

    test "only warn and fail checks are listed, with their hint" do
      stub_healthy([
        {{"get", "/api/server/worker_tmp"},
         {%{"tmpfs" => true, "root" => "/tmp/arb", "fstype" => "tmpfs"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)

      assert exit_code == 0
      assert out =~ ~r/1 warn · 0 fail/
      assert out =~ "[warn] worker temp dir"
      assert out =~ "hint: Set ARBITER_WORKER_TMP_ROOT"
      refute out =~ "[ ok ]"
    end

    test "the header names the server version, the workspaces and the bind address" do
      stub_healthy()

      {out, _err, 0} = capture(fn -> Doctor.run([]) end)

      assert out =~ ArbiterCli.Version.app_version()
      assert out =~ "default"
      assert out =~ "127.0.0.1"
    end
  end

  describe "--all output" do
    test "prints every check grouped, with n/a for the ones that do not apply" do
      stub_healthy()

      {out, _err, 0} = capture(fn -> Doctor.run(["--all"]) end)

      for group <- ["core", "auth & providers", "sandboxes", "security posture"] do
        assert out =~ group
      end

      assert out =~ "[ ok ] phoenix reachable"
      assert out =~ "[ ok ] migrations up to date"
      assert out =~ ~r/\[n\/a \] grok auth/
      assert out =~ ~r/\[n\/a \] podman sandbox readiness/
      # group order
      {core, _} = :binary.match(out, "core")
      {auth, _} = :binary.match(out, "auth & providers")
      {sandboxes, _} = :binary.match(out, "sandboxes")
      {security, _} = :binary.match(out, "security posture")
      assert core < auth and auth < sandboxes and sandboxes < security
    end

    test "-v is an alias of --all" do
      stub_healthy()

      {all, _, 0} = capture(fn -> Doctor.run(["--all"]) end)
      {verbose, _, 0} = capture(fn -> Doctor.run(["-v"]) end)

      assert all == verbose
    end

    test "the agy jail collapses to one line when its sub-checks pass" do
      stub_healthy([
        {{"get", "/api/server/doctor_scope"},
         {put_in(@scope_none, ["providers", "gemini", "in_use"], true), 200}}
      ])

      {out, _err, 0} = capture(fn -> Doctor.run(["--all"]) end)

      assert out =~ ~r/\[ ok \] agy jail \(6 checks\)/
      refute out =~ "agy jail escape vectors"
    end

    test "the agy jail expands to the failing sub-check" do
      stub_healthy([
        {{"get", "/api/server/doctor_scope"},
         {put_in(@scope_none, ["providers", "gemini", "in_use"], true), 200}},
        {{"get", "/api/server/agy_write_jail"},
         {Map.put(@ok_jail, "network", %{
            "available" => false,
            "message" => "no socat",
            "fix" => "install socat"
          }), 200}}
      ])

      {out, _err, 0} = capture(fn -> Doctor.run(["--all"]) end)

      assert out =~ "[warn] agy jail network"
      assert out =~ "no socat"
      refute out =~ "agy jail (6 checks)"
    end
  end

  describe "severity and exit code" do
    test "the quota-policy advisory is a warn, not a fail, and exits 0" do
      ws =
        Map.put(@workspace, "config", %{"quota" => %{"weekly_threshold" => 0.95}})

      stub_healthy([
        {{"get", "/api/workspaces"}, {%{"data" => [ws]}, 200}},
        {{"get", "/api/quota"},
         {%{"data" => %{"policy_binding" => %{"weekly_threshold" => "account"}}}, 200}}
      ])

      results = Checks.run()
      assert by_id(results, "quota_policy").status == :warn

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 0
      assert out =~ "[warn] account/workspace quota policy"
      refute out =~ "[fail]"
    end

    test "any fail exits 1 and --json agrees" do
      stub_healthy([
        {{"get", "/api/server/migrations"}, {%{"status" => "warning", "pending_count" => 2}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] migrations up to date"

      {json, _err, json_exit} = capture(fn -> Doctor.run(["--json"]) end)
      assert json_exit == 1
      assert {:ok, payload} = Jason.decode(String.trim(json))
      assert payload["result"] == "fail"
      assert payload["exit_code"] == 1
      assert payload["ok"] == false
      assert payload["summary"]["fail"] == 1
    end

    test "--json on a warn-only install: ok, result warn, exit 0, every check has a severity" do
      stub_healthy([
        {{"get", "/api/scheduler/status"},
         {%{"state" => "running", "paused" => false, "in_flight" => []}, 200}}
      ])

      {json, _err, exit_code} = capture(fn -> Doctor.run(["--json"]) end)

      assert exit_code == 0
      assert {:ok, payload} = Jason.decode(String.trim(json))
      assert payload["result"] == "warn"
      assert payload["exit_code"] == 0
      assert payload["ok"] == true

      assert Enum.all?(payload["checks"], fn c ->
               c["severity"] in ["ok", "warn", "fail", "n/a"] and is_binary(c["id"]) and
                 c["group"] in ["core", "auth", "sandboxes", "security"]
             end)

      # n/a checks are in the payload too: --json is every check
      assert Enum.any?(payload["checks"], &(&1["severity"] == "n/a"))
    end

    test "an unreachable server fails and exits 1" do
      stub_transport_error(:get, "/api/workspaces", :econnrefused)

      {out, _err, exit_code} = capture(fn -> Doctor.run([]) end)
      assert exit_code == 1
      assert out =~ "[fail] phoenix reachable"
    end
  end

  describe "never ok on unknown" do
    @endpoint_checks [
      {"/api/server/migrations", "migrations"},
      {"/api/server/bind_address", "bind_address"},
      {"/api/server/agy_write_jail", "agy_write_jail"},
      {"/api/server/egress_jail", "egress_jail"},
      {"/api/server/guardrails", "guardrails"},
      {"/api/server/tmux", "tmux"},
      {"/api/server/podman_sandbox", "podman_sandbox"},
      {"/api/server/worker_tmp", "worker_tmp"},
      {"/api/server/worker_memory", "worker_memory"},
      {"/api/server/claude_credentials", "claude_worker_credentials"},
      {"/api/server/grok_auth", "grok_auth"},
      {"/api/server/provider_accounts", "provider_accounts"},
      {"/api/server/merge_routing", "merge_routing"},
      {"/api/nodes", "nodes"},
      {"/api/scheduler/status", "restart_safety"}
    ]

    for {path, id} <- @endpoint_checks, {status, label} <- [{404, "missing"}, {500, "erroring"}] do
      test "#{label} #{path} is a warn naming the reason, never ok (#{id})" do
        stub_healthy([
          {{"get", "/api/server/doctor_scope"}, {scope_all(), 200}},
          {{"get", unquote(path)}, {%{"error" => "nope"}, unquote(status)}}
        ])

        result = Checks.run() |> by_id(unquote(id))

        assert result, "no check with id #{unquote(id)}"
        assert result.status == :warn
        assert result.detail =~ "could not check"
      end
    end

    test "a transport error is a warn too" do
      stub_healthy([
        {{"get", "/api/server/worker_tmp"},
         fn conn -> Req.Test.transport_error(conn, :econnrefused) end}
      ])

      result = Checks.run() |> by_id("worker_tmp")
      assert result.status == :warn
      assert result.detail =~ "could not check"
    end

    test "no check ever reports ok with 'skipping' or 'could not' in its detail" do
      stub_routes([
        {{"get", "/api/workspaces"}, {%{"data" => [@workspace]}, 200}}
      ])

      for r <- Checks.run(), r.status == :ok do
        refute (r.detail || "") =~ "skipping", "#{r.id}: #{r.detail}"
        refute (r.detail || "") =~ "could not", "#{r.id}: #{r.detail}"
      end
    end
  end

  describe "safe to restart" do
    test "a running scheduler is a warn carrying the pause command, never ok" do
      stub_healthy([
        {{"get", "/api/scheduler/status"},
         {%{"state" => "running", "paused" => false, "in_flight" => []}, 200}}
      ])

      result = Checks.run() |> by_id("restart_safety")

      assert result.status == :warn
      assert result.detail =~ "not a safe restart point"
      assert (result.hint || "") =~ "arb scheduler pause"
    end

    test "never renders [ ok ] together with 'not a safe restart point'" do
      for state <- ["running", "draining", "quiescent", "bogus"] do
        stub_healthy([
          {{"get", "/api/scheduler/status"},
           {%{"state" => state, "in_flight" => [], "paused" => state != "running"}, 200}}
        ])

        {out, _err, _} = capture(fn -> Doctor.run(["--all"]) end)

        for line <- String.split(out, "\n"), line =~ "safe to restart" do
          refute line =~ "[ ok ]" and out =~ "not a safe restart point",
                 "state #{state}: #{line}"
        end

        refute out =~ ~r/\[ ok \] safe to restart[^\n]*\n[^\n]*not a safe restart point/
      end
    end

    test "paused and quiescent is ok" do
      stub_healthy()
      assert (Checks.run() |> by_id("restart_safety")).status == :ok
    end

    test "an unreadable scheduler status is a warn" do
      stub_healthy([{{"get", "/api/scheduler/status"}, {%{}, 404}}])
      assert (Checks.run() |> by_id("restart_safety")).status == :warn
    end
  end

  describe "applicability" do
    test "grok disabled everywhere: no grok line in default output, n/a under --all" do
      stub_healthy()

      assert (Checks.run() |> by_id("grok_auth")).status == :na

      {out, _err, 0} = capture(fn -> Doctor.run([]) end)
      refute out =~ "grok"

      {all, _err, 0} = capture(fn -> Doctor.run(["--all"]) end)
      assert all =~ "[n/a ] grok auth"
    end

    test "grok in use with a refused login is a fail" do
      stub_healthy([
        {{"get", "/api/server/grok_auth"},
         {%{
            "enabled" => true,
            "state" => "reauth_required",
            "workspaces" => ["default"],
            "fix" => "arb account login grok"
          }, 200}}
      ])

      result = Checks.run() |> by_id("grok_auth")
      assert result.status == :fail

      {out, _err, 1} = capture(fn -> Doctor.run([]) end)
      assert out =~ "[fail] grok auth"
    end

    test "agy not configured: the whole agy jail group is n/a" do
      stub_healthy()
      results = Checks.run()

      for id <- ~w(agy_write_jail agy_ssh_transport agy_jail_escape agy_jail_reads
                   agy_jail_network agy_jail_keyring) do
        assert by_id(results, id).status == :na, id
        assert by_id(results, id).parent == "agy_jail"
      end

      {out, _err, 0} = capture(fn -> Doctor.run(["--all"]) end)
      assert out =~ "[n/a ] agy jail"
    end

    test "agy paused: the agy jail group is n/a even though a workspace uses it" do
      scope = put_in(@scope_none, ["providers", "gemini"], %{"in_use" => true, "paused" => true})
      stub_healthy([{{"get", "/api/server/doctor_scope"}, {scope, 200}}])

      results = Checks.run()
      assert by_id(results, "agy_jail_escape").status == :na
      assert by_id(results, "agy_jail_escape").detail =~ "paused"
    end

    test "agy in use and not paused: the jail checks run" do
      scope = put_in(@scope_none, ["providers", "gemini", "in_use"], true)
      stub_healthy([{{"get", "/api/server/doctor_scope"}, {scope, 200}}])

      results = Checks.run()
      assert by_id(results, "agy_jail_escape").status == :ok
      assert by_id(results, "agy_write_jail").status == :ok
    end

    test "podman readiness is n/a when no workspace uses podman, and is not even probed" do
      test_pid = self()

      stub_healthy([
        {{"get", "/api/server/podman_sandbox"},
         fn conn ->
           send(test_pid, :podman_probed)
           Req.Test.json(conn, %{"installed" => false})
         end}
      ])

      assert (Checks.run() |> by_id("podman_sandbox")).status == :na
      refute_received :podman_probed
    end

    test "podman readiness runs and fails when a workspace uses podman and the host is not ready" do
      scope = Map.put(@scope_none, "podman_in_use", true)

      stub_healthy([
        {{"get", "/api/server/doctor_scope"}, {scope, 200}},
        {{"get", "/api/server/podman_sandbox"},
         {%{
            "ready" => false,
            "checks" => [
              %{"name" => "userns", "status" => "fail", "detail" => "no", "hint" => "fix it"}
            ]
          }, 200}}
      ])

      assert (Checks.run() |> by_id("podman_sandbox")).status == :fail
    end

    test "the egress jail is n/a when no workspace enforces an egress allowlist" do
      stub_healthy()
      assert (Checks.run() |> by_id("egress_jail")).status == :na
    end

    test "the egress jail fails when enforcement is wanted and the host cannot do it" do
      scope = Map.put(@scope_none, "egress_enforced", true)

      stub_healthy([
        {{"get", "/api/server/doctor_scope"}, {scope, 200}},
        {{"get", "/api/server/egress_jail"},
         {%{"available" => false, "message" => "no socat", "fix" => "install socat"}, 200}}
      ])

      assert (Checks.run() |> by_id("egress_jail")).status == :fail
    end

    test "an unreadable scope never hides a check: everything stays applicable" do
      stub_healthy([{{"get", "/api/server/doctor_scope"}, {%{"error" => "nope"}, 404}}])

      results = Checks.run()
      refute by_id(results, "agy_jail_escape").status == :na
      refute by_id(results, "podman_sandbox").status == :na
    end

    test "no workspace runs claude: the claude credential line is n/a" do
      stub_healthy([
        {{"get", "/api/server/claude_credentials"}, {%{"checked" => 0, "missing" => []}, 200}}
      ])

      assert (Checks.run() |> by_id("claude_worker_credentials")).status == :na
    end

    test "the legacy safe_defaults key check is gone" do
      stub_healthy()
      refute by_id(Checks.run(), "legacy_safe_defaults_key")
    end
  end

  describe "check inventory" do
    # Every check that existed before the cleanup, by id, minus the finished
    # one-shot migration check (`legacy safe_defaults key`).
    @expected_ids ~w(
      phoenix_reachable workspaces_exist active_workspace repos_resolved version
      last_deploy migrations bind_address anonymous_api dashboard_auth
      erlang_distribution restart_safety safe_default_categories agy_write_jail
      agy_jail_escape agy_jail_reads agy_jail_network agy_jail_keyring egress_jail
      guardrails agy_ssh_transport tmux podman_sandbox worker_tmp worker_memory
      claude_worker_credentials grok_auth provider_accounts quota_policy
      merge_routing nodes
    )

    test "every pre-existing check is still reachable by id, and ids are unique" do
      stub_healthy()
      ids = Checks.run() |> Enum.map(& &1.id)

      assert Enum.sort(ids) == Enum.sort(Enum.uniq(ids))
      assert @expected_ids -- ids == []
      assert ids -- @expected_ids == []
    end

    test "--json lists every check, n/a included" do
      stub_healthy()

      {json, _err, 0} = capture(fn -> Doctor.run(["--json"]) end)
      {:ok, payload} = Jason.decode(String.trim(json))

      assert payload["checks"] |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort(@expected_ids)
    end
  end
end
