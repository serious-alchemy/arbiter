defmodule ArbiterWeb.Api.ServerControllerTest do
  @moduledoc """
  bd-1c4pg3: `arb server doctor` needs a way to ask a (possibly remote, via
  ARB_HOST) server what it's actually bound to, since the CLI has no
  filesystem/OS access of its own to inspect the listening socket.
  """
  use ArbiterWeb.ConnCase, async: false

  test "GET /api/server/bind_address reports loopback for the default 127.0.0.1 bind", %{
    conn: conn
  } do
    original = Application.get_env(:arbiter_web, ArbiterWeb.Endpoint)
    http = Keyword.put(original[:http] || [], :ip, {127, 0, 0, 1})
    Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, Keyword.put(original, :http, http))
    on_exit(fn -> Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, original) end)

    resp = conn |> get("/api/server/bind_address") |> json_response(200)

    assert resp["ip"] == "127.0.0.1"
    assert resp["loopback"] == true
  end

  test "GET /api/server/bind_address reports non-loopback for an overridden 0.0.0.0 bind", %{
    conn: conn
  } do
    original = Application.get_env(:arbiter_web, ArbiterWeb.Endpoint)
    http = Keyword.put(original[:http] || [], :ip, {0, 0, 0, 0})
    Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, Keyword.put(original, :http, http))
    on_exit(fn -> Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, original) end)

    resp = conn |> get("/api/server/bind_address") |> json_response(200)

    assert resp["ip"] == "0.0.0.0"
    assert resp["loopback"] == false
  end

  # bd-8xy1mf: `arb server doctor` needs the host's own can-jail-agy answer
  # even when no workspace currently resolves `:strict` — this endpoint
  # exposes `Arbiter.Worker.Jail.diagnose/0` for that.
  describe "GET /api/server/agy_write_jail" do
    setup do
      prev = Application.get_env(:arbiter, :worker_jail_available)
      prev_ssh = Application.get_env(:arbiter, :worker_jail_ssh_available)

      # Deterministic regardless of this test-runner host's real ssh setup
      # (bd-5d5mrs): the "ssh" sub-key is covered by its own describe block.
      Application.put_env(:arbiter, :worker_jail_ssh_available, true)
      Application.put_env(:arbiter, :worker_jail_escape_available, true)
      Application.put_env(:arbiter, :worker_jail_reads_available, true)
      Application.put_env(:arbiter, :worker_jail_network_available, true)

      on_exit(fn ->
        Application.delete_env(:arbiter, :worker_jail_escape_available)
        Application.delete_env(:arbiter, :worker_jail_reads_available)
        Application.delete_env(:arbiter, :worker_jail_network_available)

        case prev do
          nil -> Application.delete_env(:arbiter, :worker_jail_available)
          v -> Application.put_env(:arbiter, :worker_jail_available, v)
        end

        case prev_ssh do
          nil -> Application.delete_env(:arbiter, :worker_jail_ssh_available)
          v -> Application.put_env(:arbiter, :worker_jail_ssh_available, v)
        end

        Arbiter.Worker.Jail.reset()
      end)

      :ok
    end

    test "reports available: true when the host can jail agy", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_available, true)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)

      assert %{"available" => true, "ssh" => %{"available" => true}} = resp
      assert resp["escape"] == %{"available" => true}
    end

    # bd-7o08mj
    test "reports escape available: false when a jail escape vector is reachable", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_available, true)
      Application.put_env(:arbiter, :worker_jail_escape_available, false)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)

      assert resp["escape"]["available"] == false
      assert resp["escape"]["message"] =~ "escape vector"
    end

    # bd-3q2djr
    test "reports reads available: false when a sensitive path is readable in the jail", %{
      conn: conn
    } do
      Application.put_env(:arbiter, :worker_jail_available, true)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)
      assert resp["reads"] == %{"available" => true}

      Application.put_env(:arbiter, :worker_jail_reads_available, false)
      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)
      assert resp["reads"]["available"] == false
      assert resp["reads"]["message"] =~ "readable inside the jail"
    end

    # bd-cfktou: network mode (--unshare-net + socat) is its own diagnosis.
    test "reports network available: true, or false with cause/message/fix", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_available, true)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)
      assert resp["network"] == %{"available" => true}

      Application.put_env(:arbiter, :worker_jail_network_available, false)
      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)
      assert resp["network"]["available"] == false
      assert is_binary(resp["network"]["cause"])
      assert is_binary(resp["network"]["message"])
    end

    test "reports available: false with cause/message/fix when it can't", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_available, false)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)

      assert resp["available"] == false
      assert is_binary(resp["cause"])
      assert is_binary(resp["message"])
    end

    # bd-5d5mrs: the ssh config parse diagnosis is independent of the write
    # jail's — a host can jail writes fine while this regresses.
    test "reports ssh available: false with cause/message/fix when the ssh probe fails", %{
      conn: conn
    } do
      Application.put_env(:arbiter, :worker_jail_available, true)
      Application.put_env(:arbiter, :worker_jail_ssh_available, false)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)

      assert resp["available"] == true
      assert resp["ssh"]["available"] == false
      assert is_binary(resp["ssh"]["cause"])
      assert is_binary(resp["ssh"]["message"])
    end
  end

  # bd-80ecol: `arb server doctor` lists every Claude workspace that has no
  # credential of its own — the ones that used to fall into copying the
  # operator's `.credentials.json` (mode B), and whose dispatch is now held.
  describe "GET /api/server/grok_auth" do
    test "grok is off by default: nothing enabled, no auth state", %{conn: conn} do
      resp = conn |> get("/api/server/grok_auth") |> json_response(200)
      assert resp["enabled"] == false
      refute Map.has_key?(resp, "state")
    end
  end

  # bd-7pnat1: what `arb server doctor` reads to report a check as n/a.
  describe "GET /api/server/doctor_scope" do
    test "answers which providers and sandbox backends this install uses", %{conn: conn} do
      resp = conn |> get("/api/server/doctor_scope") |> json_response(200)

      assert Map.keys(resp["providers"]) |> Enum.sort() == ~w(claude codex gemini grok)

      for {_type, entry} <- resp["providers"] do
        assert is_boolean(entry["in_use"])
        assert is_boolean(entry["paused"])
        assert is_list(entry["workspaces"])
      end

      assert is_boolean(resp["podman_in_use"])
      assert is_boolean(resp["egress_enforced"])
    end
  end

  # bd-8t4yui: the end-to-end canary spawn. Agent CLIs are stubs on PATH.
  describe "POST /api/server/spawn_canary" do
    alias Arbiter.Doctor.SpawnCanary
    alias Arbiter.MCP.Scope

    setup do
      SpawnCanary.reset_cache()

      dir =
        Path.join(
          Arbiter.Config.Paths.scratch_root(),
          "canary-web-#{System.unique_integer([:positive])}"
        )

      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)

      for name <- ~w(claude agy gemini codex grok) do
        path = Path.join(bin, name)
        File.write!(path, "#!/bin/sh\necho \"#{name} 9.9.9\"\n")
        File.chmod!(path, 0o755)
      end

      prev_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> prev_path)

      prev_root = Application.get_env(:arbiter, :worker_tmp_root)
      Application.put_env(:arbiter, :worker_tmp_root, Path.join(dir, "tmp"))
      File.mkdir_p!(Path.join(dir, "tmp"))

      on_exit(fn ->
        System.put_env("PATH", prev_path)

        if prev_root,
          do: Application.put_env(:arbiter, :worker_tmp_root, prev_root),
          else: Application.delete_env(:arbiter, :worker_tmp_root)

        SpawnCanary.reset_cache()
        File.rm_rf(dir)
      end)

      Ash.create!(Arbiter.Tasks.Workspace, %{name: "canary-web", config: %{}})
      :ok
    end

    defp as(token) do
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
    end

    test "runs the canary and returns the per-provider report, cached for the boot", %{conn: conn} do
      assert %{"report" => nil} = conn |> get("/api/server/spawn_canary") |> json_response(200)

      resp = conn |> post("/api/server/spawn_canary", %{}) |> json_response(200)

      assert %{"ok" => true, "ran_at" => _, "providers" => providers} = resp["report"]

      assert %{"status" => "ok", "spawned" => true, "reached_agent" => true, "exit_code" => 0} =
               Enum.find(providers, &(&1["provider"] == "claude"))

      assert %{"status" => "n/a", "spawned" => false} =
               Enum.find(providers, &(&1["provider"] == "codex"))

      assert %{"report" => cached} = conn |> get("/api/server/spawn_canary") |> json_response(200)
      assert cached == resp["report"]
    end

    test "a concurrent canary is refused with 409", %{conn: conn} do
      parent = self()

      holder =
        Task.async(fn ->
          true = :global.set_lock({SpawnCanary, self()}, [node()], 0)
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)

      assert_receive :locked, 5_000

      resp = conn |> post("/api/server/spawn_canary", %{}) |> json_response(409)
      assert resp["error"] == "busy"

      send(holder.pid, :release)
      Task.await(holder)
    end

    test "a worker token is refused (403), as are refine and anonymous callers" do
      worker = as(Scope.mint_worker(%{id: "bd-1", workspace_id: "ws-1"}))
      assert post(worker, "/api/server/spawn_canary", %{}).status == 403
      assert get(worker, "/api/server/spawn_canary").status == 403

      refine = as(Scope.mint_refine("sess-1", "ws-1", "bd-1"))
      assert post(refine, "/api/server/spawn_canary", %{}).status in [401, 403]

      anonymous = build_conn() |> put_req_header("content-type", "application/json")
      assert post(anonymous, "/api/server/spawn_canary", %{}).status == 401

      assert SpawnCanary.cached() == nil
    end
  end

  describe "GET /api/server/claude_credentials" do
    setup do
      prev_env =
        for v <- ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY),
            into: %{},
            do: {v, System.get_env(v)}

      Enum.each(prev_env, fn {v, _} -> System.delete_env(v) end)

      on_exit(fn ->
        Enum.each(prev_env, fn
          {v, nil} -> System.delete_env(v)
          {v, val} -> System.put_env(v, val)
        end)
      end)

      :ok
    end

    test "names each Claude workspace with no setup token, with the fix", %{conn: conn} do
      {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "no-token-ws"})

      resp = conn |> get("/api/server/claude_credentials") |> json_response(200)

      assert resp["checked"] >= 1
      assert [entry] = Enum.filter(resp["missing"], &(&1["workspace_id"] == ws.id))
      assert entry["workspace"] == "no-token-ws"
      assert entry["provider"] == "claude"
      assert entry["reason"] == "no_account"
      assert entry["fix"] =~ "arb account attach #{ws.id} claude"
      assert entry["summary"] =~ "no Claude setup token"
    end
  end

  # bd-cvvb02 / P13 (bd-9gqj8e): provider accounts are always on. An
  # un-migrated install carrying legacy credentials is named at boot; the
  # doctor needs the server's own answer to report it (and to name any
  # workspace a spawn would raise MissingCredentialError for).
  describe "GET /api/server/provider_accounts" do
    setup do
      prev_resolution = Application.get_env(:arbiter, :provider_accounts_resolution)
      prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        if is_nil(prev_resolution),
          do: Application.delete_env(:arbiter, :provider_accounts_resolution),
          else: Application.put_env(:arbiter, :provider_accounts_resolution, prev_resolution)

        if prev_token,
          do: System.put_env("CLAUDE_CODE_OAUTH_TOKEN", prev_token),
          else: System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
      end)

      :ok
    end

    test "reports an install with un-migrated legacy credentials", %{conn: conn} do
      {:ok, _ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "legacy-ws",
          worker_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "t", "secret" => true}}
        })

      ExUnit.CaptureLog.capture_log(fn -> Arbiter.Accounts.Enablement.resolve() end)

      resp = conn |> get("/api/server/provider_accounts") |> json_response(200)

      assert resp["decision"] == "unmigrated_legacy_credentials"
      assert resp["stranded_workspaces"] == ["legacy-ws"]
      assert resp["server_env_token"] == false
      assert resp["runbook"] == "docs/provider-accounts-release-runbook.md"
      # There is no flag left to report.
      refute Map.has_key?(resp, "configured")
      refute Map.has_key?(resp, "enabled")
    end

    test "reports a fresh install", %{conn: conn} do
      Arbiter.Accounts.Enablement.resolve()

      resp = conn |> get("/api/server/provider_accounts") |> json_response(200)

      assert resp["decision"] == "no_legacy_credentials"
      assert resp["stranded_workspaces"] == []
    end
  end

  # bd-73zv62: `arb server doctor` lists each repo's effective merge strategy and
  # flags a forge strategy on a checkout with no `origin` remote.
  describe "GET /api/server/merge_routing" do
    @tag :tmp_dir
    test "reports each repo's effective strategy and flags a remote-less forge repo", %{
      conn: conn,
      tmp_dir: dir
    } do
      mesaana = Path.join(dir, "mesaana")
      infra = Path.join(dir, "infra")

      for path <- [mesaana, infra] do
        File.mkdir_p!(path)
        {_, 0} = System.cmd("git", ["init", "-q"], cd: path)
      end

      {:ok, ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "merge-routing-#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"},
              "repos" => %{"infra" => %{"strategy" => "direct"}}
            },
            "repo_paths" => %{"mesaana" => mesaana, "infra" => infra}
          }
        })

      resp = conn |> get("/api/server/merge_routing") |> json_response(200)
      mine = Enum.filter(resp["repos"], &(&1["workspace_id"] == ws.id))

      assert [
               %{"repo" => "infra", "strategy" => "direct", "problem" => nil},
               %{"repo" => "mesaana", "strategy" => "github", "problem" => "no_remote"} = flagged
             ] = mine

      assert flagged["fix"] =~ "merge.repos.mesaana.strategy direct"

      assert Enum.any?(
               resp["problems"],
               &(&1["workspace_id"] == ws.id and &1["repo"] == "mesaana")
             )

      refute Enum.any?(resp["problems"], &(&1["workspace_id"] == ws.id and &1["repo"] == "infra"))
    end
  end

  describe "GET /api/server/worker_memory" do
    test "reports whether the cap is in force and the server unit's OOM policy", %{conn: conn} do
      resp = conn |> get("/api/server/worker_memory") |> json_response(200)

      assert %{
               "enabled" => enabled,
               "capped" => capped,
               "available" => available,
               "oom_policy" => _,
               "service_unit" => _
             } = resp

      assert is_boolean(enabled) and is_boolean(capped) and is_boolean(available)
      # config/test.exs turns the cap off, so a test run never reports it active.
      refute capped
    end
  end

  describe "GET /api/server/worker_tmp" do
    test "reports the worker temp root, its filesystem and size", %{conn: conn} do
      resp = conn |> get("/api/server/worker_tmp") |> json_response(200)

      assert %{
               "root" => root,
               "tmpfs" => tmpfs,
               "size_bytes" => size,
               "threshold_bytes" => threshold,
               "over_threshold" => over
             } = resp

      assert is_binary(root) and is_boolean(tmpfs) and is_boolean(over)
      assert is_integer(size) and is_integer(threshold)
    end
  end

  # bd-46xndf: the podman readiness probes are stubbed so no real container runs.
  describe "GET /api/server/podman_sandbox" do
    setup do
      Application.put_env(:arbiter, :podman_readiness_opts,
        runner: fn _cmd, _args, _opts -> {"nope", 127} end
      )

      on_exit(fn -> Application.delete_env(:arbiter, :podman_readiness_opts) end)
    end

    test "reports the readiness checks as JSON", %{conn: conn} do
      resp = conn |> get("/api/server/podman_sandbox") |> json_response(200)

      assert %{"ready" => false, "installed" => false, "checks" => [check]} = resp
      assert %{"id" => "podman", "status" => "fail", "hint" => hint} = check
      assert is_binary(hint)
    end
  end

  # bd-c99hys: `arb server doctor` reports whether tmux is installed, since the
  # dashboard login relay runs each provider CLI login inside it.
  describe "GET /api/server/tmux" do
    test "reports availability, path and version from the host", %{conn: conn} do
      resp = conn |> get("/api/server/tmux") |> json_response(200)

      if System.find_executable("tmux") do
        assert %{"available" => true, "path" => path, "version" => "tmux" <> _} = resp
        assert path == System.find_executable("tmux")
      else
        assert %{"available" => false, "message" => _, "fix" => fix} = resp
        assert fix =~ "tmux"
      end
    end
  end

  # bd-5yydxh (G10): the doctor's "egress jail" self-test. The jail-presence
  # half is the `:worker_jail_network_available` override, so these run the
  # real proxy and local stand-in on any host.
  describe "GET /api/server/egress_jail" do
    setup do
      on_exit(fn -> Application.delete_env(:arbiter, :worker_jail_network_available) end)
      :ok
    end

    test "reports available with 1 allow and 1 deny when the jail and proxy work", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_network_available, true)

      resp = conn |> get("/api/server/egress_jail") |> json_response(200)

      assert resp["available"] == true
      assert resp["allowed"] == 1
      assert resp["denied"] == 1
    end

    test "reports cause, message and fix when the jail prerequisites are missing", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_network_available, false)

      resp = conn |> get("/api/server/egress_jail") |> json_response(200)

      assert resp["available"] == false
      assert is_binary(resp["cause"])
      assert is_binary(resp["message"])
      assert Map.has_key?(resp, "fix")
    end
  end

  # bd-anwb0u (G11): the doctor's guardrail posture.
  describe "GET /api/server/guardrails" do
    test "is inactive with no issues when nothing is configured", %{conn: conn} do
      resp = conn |> get("/api/server/guardrails") |> json_response(200)

      assert resp["active"] == false
      assert resp["issues"] == []
      assert is_list(resp["workspaces"])
    end

    test "reports each workspace's tiers and flags an inert block", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "gr-doctor",
          prefix: "grd",
          config: %{
            "guardrails" => %{
              "subjects" => [%{"match" => %{"provider" => "claude"}, "max_tier" => "probation"}]
            }
          }
        })

      resp = conn |> get("/api/server/guardrails") |> json_response(200)

      assert Enum.any?(
               resp["issues"],
               &(&1["kind"] == "inert_block" and &1["workspace"] == ws.name)
             )
    end
  end
end
