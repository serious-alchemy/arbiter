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
      Application.put_env(:arbiter, :worker_jail_network_available, true)

      on_exit(fn ->
        Application.delete_env(:arbiter, :worker_jail_escape_available)
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
end
